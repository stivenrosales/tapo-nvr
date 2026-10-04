#!/data/data/com.termux/files/usr/bin/bash
# housekeeper.sh — one-minute loop next to tapo-watch.sh:
#   - heartbeat.sh every HB_EVERY seconds (healthchecks.io dead-man's switch)
#   - send-summary.sh once per local day, from SUMMARY_AT (HH:MM) on. The
#     stamp file makes it reboot-proof: a tablet that was off at SUMMARY_AT
#     still sends today's summary as soon as it is back.
# Reads ~/.tapo_env (HC_URL, REMOTE, HB_*, SUMMARY_AT) and exports it to the
# scripts it launches.
#
# Sourceable for tests; every time-dependent function takes the epoch as an
# argument (NOW_EPOCH overrides the clock in hk_now).

hk_defaults() {
  HK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  WORKDIR=${WORKDIR:-$HOME/tapo}
  LOG=${LOG:-$WORKDIR/tapo.log}
  TAPO_ENV=${TAPO_ENV:-$HOME/.tapo_env}
  HB_EVERY=${HB_EVERY:-300}
  SUMMARY_AT=${SUMMARY_AT:-20:55}
  SUMMARY_RETRY=${SUMMARY_RETRY:-900}   # min seconds between failed summary attempts
  HK_INTERVAL=${HK_INTERVAL:-60}
  STAMP_SUMMARY=${STAMP_SUMMARY:-$WORKDIR/.last_summary}
  HEARTBEAT_CMD=${HEARTBEAT_CMD:-$HK_DIR/heartbeat.sh}
  SUMMARY_CMD=${SUMMARY_CMD:-$HK_DIR/send-summary.sh}
}

hk_log() { echo "$(date '+%F %T') | $*" >>"${LOG:-/dev/null}"; }

hk_now() { REPLY=${NOW_EPOCH:-$(date +%s)}; }

# Export everything the env file defines (HC_URL, REMOTE...) to our children.
hk_load_env() {
  [[ -r "$TAPO_ENV" ]] || return 0
  set -a
  # shellcheck source=/dev/null
  source "$TAPO_ENV" 2>/dev/null
  set +a
  return 0
}

hk_init() { # hk_init NOW — first heartbeat after HB_EVERY, not at boot (ring is empty then)
  HK_LAST_HB=$1
  HK_LAST_SUM_TRY=0
}

hk_tick() { # hk_tick NOW
  local now=$1 today hhmm
  printf -v today '%(%F)T' "$now"
  printf -v hhmm '%(%H:%M)T' "$now"

  if ((now - HK_LAST_HB >= HB_EVERY)); then
    HK_LAST_HB=$now
    "$HEARTBEAT_CMD" </dev/null >>"${LOG:-/dev/null}" 2>&1
  fi

  local stamp=""
  [[ -r "$STAMP_SUMMARY" ]] && stamp=$(<"$STAMP_SUMMARY")
  if [[ ! "$hhmm" < "$SUMMARY_AT" && "$stamp" != "$today" ]] \
     && ((now - HK_LAST_SUM_TRY >= SUMMARY_RETRY)); then
    HK_LAST_SUM_TRY=$now
    if "$SUMMARY_CMD" </dev/null >>"${LOG:-/dev/null}" 2>&1; then
      echo "$today" >"$STAMP_SUMMARY"
    else
      hk_log "housekeeper: resumen diario fallo, reintento en ${SUMMARY_RETRY}s"
    fi
  fi
}

hk_loop() {
  hk_now; hk_init "$REPLY"
  while true; do
    sleep "$HK_INTERVAL"
    hk_now; hk_tick "$REPLY"
  done
}

hk_main() {
  set -u
  hk_defaults
  hk_load_env
  hk_defaults   # env file may have set SUMMARY_AT/HB_EVERY: re-resolve derived paths
  mkdir -p "$WORKDIR"
  hk_log "housekeeper: activo (heartbeat cada ${HB_EVERY}s, resumen desde ${SUMMARY_AT})"
  hk_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then hk_main "$@"; fi
