#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot launcher. Install as ~/.termux/boot/boot-tapo.sh (chmod +x).
# Runs once per device boot: grabs the wake lock, starts sshd (localhost
# only, see README), keeps tapo-watch.sh alive forever and supervises the
# housekeeper (heartbeat + daily summary) next to it.
set -u

APP=${APP:-$HOME/tapo-nvr/tapo-watch.sh}
HK=${HK:-$HOME/tapo-nvr/termux/housekeeper.sh}
LOG="$HOME/tapo/boot.log"
RESTART_DELAY=${RESTART_DELAY:-30}

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') | $*" >> "$LOG"; }

termux-wake-lock
pgrep -x sshd >/dev/null 2>&1 || sshd

# Only one supervisor at a time (Termux:Boot can fire again after an app update).
exec 9>"$HOME/tapo/.boot.lock"
flock -n 9 || { log "supervisor already running, exiting"; exit 0; }

# kill_tree PID: supervisor first (so it cannot respawn), then its children.
kill_tree() {
  local c kids=""
  command -v pgrep >/dev/null && kids=$(pgrep -P "$1" 2>/dev/null)
  kill "$1" 2>/dev/null
  for c in $kids; do kill_tree "$c"; done
}

supervise_housekeeper() {
  local pid
  trap '[[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null; exit 0' TERM INT
  while true; do
    "$HK" </dev/null >>"$LOG" 2>&1 &
    pid=$!
    wait "$pid"
    log "housekeeper exited with code $?, restarting in ${RESTART_DELAY}s"
    sleep "$RESTART_DELAY" & wait $!
  done
}

HK_SUP="" APP_PID=""
cleanup() {
  trap - EXIT INT TERM
  [[ -n "$HK_SUP" ]] && kill_tree "$HK_SUP"
  [[ -n "$APP_PID" ]] && kill_tree "$APP_PID"
  exit 0
}
trap cleanup EXIT INT TERM

log "boot: starting supervisor"
supervise_housekeeper & HK_SUP=$!
while true; do
  # background + wait so a TERM to this launcher is handled immediately
  "$APP" </dev/null >>"$LOG" 2>&1 &
  APP_PID=$!
  wait "$APP_PID"
  log "tapo-watch exited with code $?, restarting in ${RESTART_DELAY}s"
  sleep "$RESTART_DELAY"
done
