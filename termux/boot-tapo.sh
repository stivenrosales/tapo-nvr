#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot launcher. Install as ~/.termux/boot/boot-tapo.sh (chmod +x).
# Runs once per device boot: grabs the wake lock, starts sshd (localhost
# only, see README) and keeps tapo-watch.sh alive forever.
set -u

APP="$HOME/tapo-nvr/tapo-watch.sh"
LOG="$HOME/tapo/boot.log"
RESTART_DELAY=${RESTART_DELAY:-30}

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') | $*" >> "$LOG"; }

termux-wake-lock
pgrep -x sshd >/dev/null 2>&1 || sshd

# Only one supervisor at a time (Termux:Boot can fire again after an app update).
exec 9>"$HOME/tapo/.boot.lock"
flock -n 9 || { log "supervisor already running, exiting"; exit 0; }

log "boot: starting supervisor"
while true; do
  "$APP" </dev/null >>"$LOG" 2>&1
  log "tapo-watch exited with code $?, restarting in ${RESTART_DELAY}s"
  sleep "$RESTART_DELAY"
done
