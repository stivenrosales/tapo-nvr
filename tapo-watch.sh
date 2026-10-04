#!/data/data/com.termux/files/usr/bin/bash
# tapo-watch.sh — vigila stream2 (640x360), graba stream1 (2K) al detectar
# movimiento, sube a Google Drive y purga lo mas viejo que RETENTION_DAYS.
set -uo pipefail

source "$HOME/.tapo_env" 2>/dev/null || { echo "falta ~/.tapo_env"; exit 1; }

# --- La IP puede cambiar por DHCP: verificar y, si hace falta, redescubrir. ---
# Sonda TCP sin dependencias externas: bash trae /dev/tcp de fabrica.
alive() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/554" 2>/dev/null; }

find_camera() {
  alive "$CAM_IP" && { echo "$CAM_IP"; return; }
  echo "IP $CAM_IP no responde, escaneando la red..." >&2
  local base found
  base=$(echo "$CAM_IP" | cut -d. -f1-3)
  found=$(for ip in $(seq 1 254); do
            ( timeout 1 bash -c "exec 3<>/dev/tcp/$base.$ip/554" 2>/dev/null \
              && echo "$base.$ip" ) &
          done; wait)
  found=$(echo "$found" | head -1)
  [ -n "$found" ] || return 1
  echo "camara encontrada en $found (actualiza CAM_IP en ~/.tapo_env)" >&2
  echo "$found"
}

CAM_IP=$(find_camera) || { echo "camara no encontrada en la red"; exit 1; }

RTSP_LO="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:554/stream2"
RTSP_HI="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:554/stream1"

REMOTE="drive-tapo:Camara"
WORKDIR="$HOME/tapo"
CLIPS="$WORKDIR/clips"
LOG="$WORKDIR/tapo.log"
STAMP="$WORKDIR/.last_purge"

CLIP_SECS=${CLIP_SECS:-30}       # duracion del clip grabado
SCENE=${SCENE:-0.005}            # umbral por frame (ruido de fondo: mediana 0.0007)
DEBOUNCE=${DEBOUNCE:-40}         # segundos minimos entre disparos
RETENTION_DAYS=${RETENTION_DAYS:-60}
# Persistencia: exige MIN_HITS detecciones dentro de WINDOW segundos.
# Un pico de ruido (keyframe, cambio de luz, insecto) es 1 frame aislado;
# una persona caminando produce decenas seguidos. Esto separa lo que
# el umbral solo no puede: el ruido llega tan alto como el movimiento.
MIN_HITS=${MIN_HITS:-4}
WINDOW=${WINDOW:-3}

mkdir -p "$CLIPS"
log() { echo "$(date '+%F %T') | $*" >> "$LOG"; echo "$(date '+%H:%M:%S') | $*"; }

# --- modo calibracion: muestra los scores en vivo para ajustar SCENE ---
if [ "${1:-}" = "--calibrar" ]; then
  SEGS=${2:-30}
  echo "Muevete frente a la camara durante ${SEGS}s. Analizando..."
  ffmpeg -loglevel info -rtsp_transport tcp -i "$RTSP_LO" -t "$SEGS" \
    -vf "select='gte(scene\,0)',metadata=print" -an -f null - 2>&1 \
    | grep -o 'lavfi.scene_score=[0-9.]*' | cut -d= -f2 | sort -g | awk '
      {v[NR]=$1; s+=$1}
      END {
        if (NR==0) { print "sin datos: revisa la conexion a la camara"; exit }
        p50=v[int(NR*0.50)]; p95=v[int(NR*0.95)]; p99=v[int(NR*0.99)]; max=v[NR]
        printf "\n  muestras : %d\n", NR
        printf "  mediana  : %.6f   (ruido de fondo)\n", p50
        printf "  p95      : %.6f\n", p95
        printf "  p99      : %.6f\n", p99
        printf "  MAXIMO   : %.6f   (tu movimiento)\n", max
        # Media geometrica entre el ruido de fondo y el pico de movimiento:
        # cae en medio de ambos en escala logaritmica, que es como se
        # distribuyen estos scores. NUNCA puede superar el maximo observado.
        sug = sqrt(p50 * max)
        if (sug < 0.002) sug = 0.002
        if (sug > max * 0.6) sug = max * 0.6
        printf "\n  >>> SCENE sugerido: %.4f", sug
        printf "   (ruido x%.0f, y %.0f%% bajo tu pico)\n", sug/p50, (1-sug/max)*100
        printf "  Usa:  SCENE=%.4f ./tapo-watch.sh\n\n", sug
      }'
  exit 0
fi

command -v termux-wake-lock >/dev/null && termux-wake-lock

cleanup() {
  log "deteniendo"
  command -v termux-wake-unlock >/dev/null && termux-wake-unlock
  pkill -P $$ ffmpeg 2>/dev/null
  exit 0
}
trap cleanup INT TERM

purge_drive() {
  local today; today=$(date +%F)
  [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$today" ] && return
  log "purgando clips de mas de ${RETENTION_DAYS} dias"
  rclone delete "$REMOTE" --min-age "${RETENTION_DAYS}d" --drive-use-trash=false \
    >>"$LOG" 2>&1 && echo "$today" > "$STAMP"
}

capture() {
  local ts name size
  ts=$(date '+%Y-%m-%d_%H-%M-%S')
  name="$CLIPS/mov_${ts}.mp4"
  log "MOVIMIENTO -> grabando ${CLIP_SECS}s"

  if ffmpeg -y -loglevel error -rtsp_transport tcp -i "$RTSP_HI" \
       -t "$CLIP_SECS" -c:v copy -c:a aac "$name" >>"$LOG" 2>&1; then
    size=$(du -h "$name" | cut -f1)
    if rclone move "$name" "$REMOTE/$(date +%Y-%m)/" >>"$LOG" 2>&1; then
      log "subido: mov_${ts}.mp4 ($size)"
    else
      log "ERROR subiendo — queda local, se reintenta despues"
    fi
  else
    log "ERROR grabando — descarto"; rm -f "$name"
  fi
  purge_drive
}

flush_pending() {
  local n; n=$(find "$CLIPS" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] || return
  log "reintentando $n clip(s) pendientes"
  rclone move "$CLIPS" "$REMOTE/$(date +%Y-%m)/" --include '*.mp4' >>"$LOG" 2>&1
}

log "=== vigilancia activa | umbral=$SCENE persistencia=${MIN_HITS}hits/${WINDOW}s clip=${CLIP_SECS}s debounce=${DEBOUNCE}s retencion=${RETENTION_DAYS}d ==="
flush_pending
purge_drive

while true; do
  ffmpeg -loglevel info -rtsp_transport tcp -i "$RTSP_LO" \
         -vf "select='gt(scene,$SCENE)',metadata=print" -an -f null - 2>&1 \
  | {
      last=0; hits=0; win_start=0
      while IFS= read -r line; do
        case "$line" in
          *lavfi.scene_score*)
            now=$(date +%s)
            # Ventana deslizante: si expiro, reiniciar el conteo.
            if [ $((now - win_start)) -gt "$WINDOW" ]; then
              hits=0; win_start=$now
            fi
            hits=$((hits + 1))
            if [ "$hits" -ge "$MIN_HITS" ] && [ $((now - last)) -ge "$DEBOUNCE" ]; then
              last=$now; hits=0
              capture
            fi
            ;;
        esac
      done
    }
  log "monitor cayo (red o camara) — reintento en 15s"
  sleep 15
done
