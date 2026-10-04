#!/data/data/com.termux/files/usr/bin/bash
# tapo-watch.sh — vigila stream2 (640x360), graba stream1 (2K) al detectar
# movimiento, sube a Google Drive y purga lo mas viejo que RETENTION_DAYS.
#
# Sourceable for tests: all logic lives in functions, main() only runs when
# the file is executed directly.

apply_defaults() {
  CLIP_SECS=${CLIP_SECS:-30}       # duracion del clip grabado (despues del disparo)
  PREROLL_SECS=${PREROLL_SECS:-5}  # segundos de pre-roll tomados del ring buffer
  SEG_SECS=${SEG_SECS:-5}          # duracion nominal de cada segmento del ring
  RING_SECS=${RING_SECS:-120}      # el pruner borra segmentos mas viejos que esto
  RING_WAIT_SECS=${RING_WAIT_SECS:-$((SEG_SECS * 3 + 5))}  # espera maxima por el ultimo segmento
  SCENE=${SCENE:-0.005}            # umbral por frame (ruido de fondo: mediana 0.0007)
  DEBOUNCE=${DEBOUNCE:-40}         # segundos minimos entre disparos (reloj de pared)
  RETENTION_DAYS=${RETENTION_DAYS:-60}
  # Persistencia: exige MIN_HITS detecciones dentro de WINDOW segundos
  # (de tiempo de STREAM, pts_time de ffmpeg — no reloj de pared).
  MIN_HITS=${MIN_HITS:-4}
  WINDOW=${WINDOW:-3}
  REMOTE=${REMOTE:-drive-tapo:Camara}
  WORKDIR=${WORKDIR:-$HOME/tapo}
  CLIPS="$WORKDIR/clips"
  HELD="$WORKDIR/held"
  RING="$WORKDIR/ring"
  LOG="$WORKDIR/tapo.log"
  STAMP="$WORKDIR/.last_purge"
  # Input options for every RTSP read; overridable only for offline tests.
  read -ra IN_OPTS_A <<<"${IN_OPTS:--rtsp_transport tcp}"
}

log() {
  echo "$(date '+%F %T') | $*" >>"${LOG:-/dev/null}"
  echo "$(date '+%H:%M:%S') | $*"
}

# --- La IP puede cambiar por DHCP: verificar y, si hace falta, redescubrir. ---
# Sonda TCP sin dependencias externas: bash trae /dev/tcp de fabrica.
alive() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/554" 2>/dev/null; }

find_camera() {
  alive "$CAM_IP" && { echo "$CAM_IP"; return; }
  echo "IP $CAM_IP no responde, escaneando la red..." >&2
  local base found ip
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

# --- modo calibracion: muestra los scores en vivo para ajustar SCENE ---
calibrate() {
  local segs=${1:-30}
  echo "Muevete frente a la camara durante ${segs}s. Analizando..."
  ffmpeg -nostdin -loglevel info "${IN_OPTS_A[@]}" -i "$RTSP_LO" -t "$segs" \
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
}

# --- hit counter based on the stream clock (pts_time) -----------------------
# ffmpeg metadata=print emits, per selected frame:
#   [Parsed_metadata_1 @ 0x..] frame:141  pts:15086586 pts_time:167.628733
#   [Parsed_metadata_1 @ 0x..] lavfi.scene_score=0.012345
# Counting on pts_time makes the window immune to bursts of queued lines.
HIT_MS=()
HIT_CUR_MS=0
HIT_LAST_MS=-1

hit_reset() { HIT_MS=(); HIT_CUR_MS=0; HIT_LAST_MS=-1; }

# pts_to_ms SECONDS[.FRAC] -> REPLY (integer milliseconds)
pts_to_ms() {
  local t=${1//[^0-9.]/} int frac=""
  int=${t%%.*}
  [[ $t == *.* ]] && frac=${t#*.}
  frac="${frac}000"; frac=${frac:0:3}
  REPLY=$((10#${int:-0} * 1000 + 10#$frac))
}

# hit_feed_line LINE: returns 0 when this line completes MIN_HITS within
# WINDOW seconds of stream time (and clears the counter); 1 otherwise.
hit_feed_line() {
  local line=$1 t cutoff i keep=()
  case $line in
    *pts_time:*)
      t=${line##*pts_time:}; t=${t%%[!0-9.]*}
      [[ -n $t ]] && { pts_to_ms "$t"; HIT_CUR_MS=$REPLY; }
      return 1 ;;
    *lavfi.scene_score*) ;;
    *) return 1 ;;
  esac
  # Stream clock went backwards (reconnect): old hits are meaningless.
  if ((HIT_CUR_MS < HIT_LAST_MS)); then HIT_MS=(); fi
  HIT_LAST_MS=$HIT_CUR_MS
  cutoff=$((HIT_CUR_MS - WINDOW * 1000))
  for i in "${HIT_MS[@]}"; do
    if ((i >= cutoff)); then keep+=("$i"); fi
  done
  keep+=("$HIT_CUR_MS")
  HIT_MS=("${keep[@]}")
  if ((${#HIT_MS[@]} >= MIN_HITS)); then HIT_MS=(); return 0; fi
  return 1
}

# --- upload / purge ---------------------------------------------------------
purge_drive() {
  local today; today=$(date +%F)
  [ -f "$STAMP" ] && [ "$(<"$STAMP")" = "$today" ] && return
  log "purgando clips de mas de ${RETENTION_DAYS} dias"
  rclone delete "$REMOTE" --min-age "${RETENTION_DAYS}d" --drive-use-trash=false \
    </dev/null >>"${LOG:-/dev/null}" 2>&1 && echo "$today" >"$STAMP"
}

# upload_clip FILE YYYY-MM
upload_clip() {
  local file=$1 month=$2 size
  size=$(du -h "$file" | cut -f1)
  if rclone move "$file" "$REMOTE/$month/" </dev/null >>"${LOG:-/dev/null}" 2>&1; then
    log "subido: ${file##*/} ($size)"
  else
    log "ERROR subiendo — queda local, se reintenta despues"
  fi
}

# v1 path: record stream1 directly (no pre-roll).
record_direct() {
  ffmpeg -nostdin -y -loglevel error "${IN_OPTS_A[@]}" -i "$RTSP_HI" \
    -t "$CLIP_SECS" -c:v copy -c:a aac "$1" </dev/null >>"${LOG:-/dev/null}" 2>&1
}

# --- pre-roll ring buffer ---------------------------------------------------
# A long-running ffmpeg segments stream1 into seg_<epoch>.ts (mpegts). The
# camera audio is PCM A-law, which MP4 rejects, hence -c:a aac. On trigger we
# concat the segments covering [T-PREROLL, T+CLIP] into an mp4 (no re-encode).

ring_list() {
  local f
  for f in "$RING"/seg_*.ts; do
    [[ -e $f ]] && echo "${f##*/}"
  done
}

segmenter_cmd_args() {
  printf '%s\n' ffmpeg -nostdin -loglevel error -fflags +genpts "${IN_OPTS_A[@]}" \
    -i "$RTSP_HI" -c:v copy -c:a aac -f segment -segment_time "$SEG_SECS" \
    -reset_timestamps 1 -strftime 1 -segment_format mpegts "$RING/seg_%s.ts"
}

# select_segments START END: names on stdin -> names covering [START,END],
# sorted by time. A segment seg_E.ts nominally spans [E, E+SEG_SECS).
select_segments() {
  local start=$1 end=$2 n e
  while IFS= read -r n; do
    [[ $n =~ ^seg_([0-9]+)\.ts$ ]] || continue
    e=$((10#${BASH_REMATCH[1]}))
    if ((e + SEG_SECS > start && e <= end)); then echo "$e $n"; fi
  done | sort -n | cut -d' ' -f2
}

# segments_closed_through END: names on stdin; 0 when a segment that starts
# after END exists, i.e. the one containing END is finished being written.
segments_closed_through() {
  local end=$1 n
  while IFS= read -r n; do
    [[ $n =~ ^seg_([0-9]+)\.ts$ ]] || continue
    if ((10#${BASH_REMATCH[1]} > end)); then return 0; fi
  done
  return 1
}

# ring_coverage_ok END: selected names on stdin; fails when the selection is
# empty or stops long before END (segmenter down).
ring_coverage_ok() {
  local end=$1 n last=-1
  while IFS= read -r n; do
    [[ $n =~ ^seg_([0-9]+)\.ts$ ]] && last=$((10#${BASH_REMATCH[1]}))
  done
  ((last >= 0 && last + 2 * SEG_SECS >= end))
}

# select_prune NOW: names on stdin -> names older than RING_SECS.
select_prune() {
  local now=$1 n
  while IFS= read -r n; do
    [[ $n =~ ^seg_([0-9]+)\.ts$ ]] || continue
    if ((10#${BASH_REMATCH[1]} < now - RING_SECS)); then echo "$n"; fi
  done
}

prune_ring() {
  local n
  while IFS= read -r n; do rm -f "${RING:?}/$n"; done \
    < <(ring_list | select_prune "${1:-$(date +%s)}")
}

segmenter_loop() {
  local cmd=()
  while true; do
    mapfile -t cmd < <(segmenter_cmd_args)
    "${cmd[@]}" </dev/null >>"${LOG:-/dev/null}" 2>&1
    log "segmentador cayo — reintento en 15s"
    sleep 15
  done
}

pruner_loop() {
  while true; do sleep 30; prune_ring; done
}

# Wait until END is fully segmented (bounded by RING_WAIT_SECS).
wait_for_ring() {
  local end=$1 now waited=0
  now=$(date +%s)
  if ((end > now)); then sleep $((end - now)); fi
  while ! ring_list | segments_closed_through "$end"; do
    if ((waited >= RING_WAIT_SECS)); then return 1; fi
    sleep 1; waited=$((waited + 1))
  done
}

# build_clip_from_ring START END OUT
build_clip_from_ring() {
  local start=$1 end=$2 out=$3 sel list n rc
  wait_for_ring "$end" || log "ring: ultimo segmento incompleto, uso lo disponible"
  sel=$(ring_list | select_segments "$start" "$end")
  ring_coverage_ok "$end" <<<"$sel" || return 1
  list="$RING/concat_${end}_${BASHPID}.txt"
  while IFS= read -r n; do echo "file '$RING/$n'"; done <<<"$sel" >"$list"
  ffmpeg -nostdin -y -loglevel error -f concat -safe 0 -i "$list" -c copy \
    -bsf:a aac_adtstoasc -movflags +faststart "$out" </dev/null >>"${LOG:-/dev/null}" 2>&1
  rc=$?
  rm -f "$list"
  return $rc
}

# capture T: runs in the background, T = epoch seconds of the trigger.
capture() {
  local t=${1:-$(date +%s)} ts month name
  printf -v ts '%(%Y-%m-%d_%H-%M-%S)T' "$t"
  printf -v month '%(%Y-%m)T' "$t"
  name="$CLIPS/mov_${ts}.mp4"
  log "MOVIMIENTO -> clip con ${PREROLL_SECS}s de pre-roll + ${CLIP_SECS}s"
  if ! build_clip_from_ring $((t - PREROLL_SECS)) $((t + CLIP_SECS)) "$name"; then
    log "ring incompleto — grabacion directa (sin pre-roll)"
    rm -f "$name"
    record_direct "$name" || { log "ERROR grabando — descarto"; rm -f "$name"; purge_drive; return; }
  fi
  upload_clip "$name" "$month"
  purge_drive
}

flush_pending() {
  local n; n=$(find "$CLIPS" -name '*.mp4' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] || return 0
  log "reintentando $n clip(s) pendientes"
  rclone move "$CLIPS" "$REMOTE/$(date +%Y-%m)/" --include '*.mp4' \
    </dev/null >>"${LOG:-/dev/null}" 2>&1
}

# --- detector ---------------------------------------------------------------
detector_cmd_args() {
  printf '%s\n' ffmpeg -nostdin -loglevel info "${IN_OPTS_A[@]}" -i "$RTSP_LO" \
    -vf "select='gt(scene,$SCENE)',metadata=print" -an -f null -
}

# Reads ffmpeg output on stdin. NEVER blocks: captures go to the background.
detector_reader() {
  local line last=0 now
  hit_reset
  while IFS= read -r line; do
    if hit_feed_line "$line"; then
      now=$(date +%s)
      if ((now - last >= DEBOUNCE)); then
        last=$now
        capture "$now" </dev/null &
      fi
    fi
  done
}

detector_loop() {
  while true; do
    ffmpeg -nostdin -loglevel info "${IN_OPTS_A[@]}" -i "$RTSP_LO" \
      -vf "select='gt(scene,$SCENE)',metadata=print" -an -f null - 2>&1 \
      | detector_reader
    log "monitor cayo (red o camara) — reintento en 15s"
    sleep 15
  done
}

# --- process management -----------------------------------------------------
CHILD_PIDS=()

kill_tree() {
  local c
  if command -v pgrep >/dev/null; then
    for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  fi
  kill "$1" 2>/dev/null
}

cleanup() {
  trap - INT TERM
  log "deteniendo"
  command -v termux-wake-unlock >/dev/null && termux-wake-unlock
  local p
  for p in "${CHILD_PIDS[@]}"; do kill_tree "$p"; done
  exit 0
}

main() {
  set -uo pipefail
  if [[ -z "${RTSP_LO:-}" || -z "${RTSP_HI:-}" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.tapo_env" 2>/dev/null || { echo "falta ~/.tapo_env"; exit 1; }
    CAM_IP=$(find_camera) || { echo "camara no encontrada en la red"; exit 1; }
    RTSP_LO="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:554/stream2"
    RTSP_HI="rtsp://${CAM_USER}:${CAM_PASS}@${CAM_IP}:554/stream1"
  fi
  apply_defaults
  mkdir -p "$CLIPS" "$HELD" "$RING"
  rm -f "$RING"/seg_*.ts "$RING"/concat_*.txt

  if [ "${1:-}" = "--calibrar" ]; then
    calibrate "${2:-30}"
    exit 0
  fi

  command -v termux-wake-lock >/dev/null && termux-wake-lock
  trap cleanup INT TERM

  log "=== vigilancia activa | umbral=$SCENE persistencia=${MIN_HITS}hits/${WINDOW}s clip=${PREROLL_SECS}s+${CLIP_SECS}s ring=${RING_SECS}s debounce=${DEBOUNCE}s retencion=${RETENTION_DAYS}d ==="
  flush_pending
  purge_drive

  segmenter_loop </dev/null & CHILD_PIDS+=($!)
  pruner_loop </dev/null & CHILD_PIDS+=($!)
  detector_loop </dev/null & CHILD_PIDS+=($!)
  wait
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
