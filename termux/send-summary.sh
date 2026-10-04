#!/data/data/com.termux/files/usr/bin/bash
# send-summary.sh — build the 24 h summary JSON from tapo.log, keep it in
# $WORKDIR/summaries/YYYY-MM-DD.json and upload it to $REMOTE/resumenes/.
# A Google Apps Script on the Drive side reads it and sends the email.
#
# Sourceable for tests; main only runs when executed directly.
# SUMMARY_END="YYYY-MM-DD HH:MM[:SS]" overrides the window end (tests/backfill).

sm_defaults() {
  WORKDIR=${WORKDIR:-$HOME/tapo}
  LOG=${LOG:-$WORKDIR/tapo.log}
  REMOTE=${REMOTE:-drive-tapo:Camara}
  SUMMARY_KEEP=${SUMMARY_KEEP:-30}
  SM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  SUMMARY_PY=${SUMMARY_PY:-$SM_DIR/daily-summary.py}
  PYTHON=${PYTHON:-python3}
}

sm_log() { echo "$(date '+%F %T') | $*" >>"${LOG:-/dev/null}"; }

# Delete all but the newest SUMMARY_KEEP files (names sort chronologically).
sm_prune() {
  local f files=()
  for f in "$WORKDIR/summaries"/*.json; do [[ -e $f ]] && files+=("$f"); done
  local extra=$((${#files[@]} - SUMMARY_KEEP)) i
  for ((i = 0; i < extra; i++)); do rm -f "${files[i]}"; done
}

send_summary() {
  local day out args=()
  if [[ -n "${SUMMARY_END:-}" ]]; then
    day=${SUMMARY_END%% *}; args=(--end "$SUMMARY_END")
  else
    day=$(date +%F)
  fi
  out="$WORKDIR/summaries/$day.json"
  mkdir -p "$WORKDIR/summaries"
  if ! "$PYTHON" "$SUMMARY_PY" "$LOG" --out "$out" "${args[@]}" </dev/null 2>>"${LOG:-/dev/null}"; then
    sm_log "resumen diario: ERROR generando $day.json"
    return 1
  fi
  sm_prune
  if rclone copyto "$out" "$REMOTE/resumenes/$day.json" </dev/null >>"${LOG:-/dev/null}" 2>&1; then
    sm_log "resumen diario: subido $day.json"
  else
    sm_log "resumen diario: ERROR subiendo $day.json — queda local"
    return 1
  fi
}

sm_main() {
  set -u
  sm_defaults
  send_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then sm_main "$@"; fi
