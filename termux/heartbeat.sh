#!/data/data/com.termux/files/usr/bin/bash
# heartbeat.sh — dead-man's switch for healthchecks.io.
# Pings $HC_URL when the recorder looks alive, $HC_URL/fail (with the reason in
# the body) when it does not. Healthy means: the newest ring segment was
# written less than HB_MAX_SEG_AGE seconds ago AND the detector ffmpeg runs.
# If healthchecks never hears from us at all, the tablet itself is down and
# healthchecks.io alerts on the missing ping.
#
# Sourceable for tests; main only runs when executed directly. Never exits
# non-zero because of the network, and never prints HC_URL (it is a secret).

hb_defaults() {
  WORKDIR=${WORKDIR:-$HOME/tapo}
  RING=${RING:-$WORKDIR/ring}
  CLIPS=${CLIPS:-$WORKDIR/clips}
  HELD=${HELD:-$WORKDIR/held}
  LOG=${LOG:-$WORKDIR/tapo.log}
  HB_MAX_SEG_AGE=${HB_MAX_SEG_AGE:-60}
}

hb_log() { echo "$(date '+%F %T') | $*" >>"${LOG:-/dev/null}"; }

hb_now() { echo "${NOW_EPOCH:-$(date +%s)}"; }

# mtime in epoch seconds: GNU stat first (Termux), BSD fallback (macOS tests).
hb_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Age in seconds of the newest ring segment; fails if there is none.
hb_newest_seg_age() {
  local f m newest=0
  for f in "$RING"/seg_*.ts; do
    [[ -e $f ]] || continue
    m=$(hb_mtime "$f") || continue
    ((m > newest)) && newest=$m
  done
  ((newest > 0)) || return 1
  echo $(($(hb_now) - newest))
}

# ERE matching the watcher's detector ffmpeg (see detector_cmd_args in
# tapo-watch.sh): the scene filter is unique to it, the segmenter has none.
hb_detector_pattern() { echo "select='gt\\(scene,"; }

# Overridable in tests.
hb_detector_running() { pgrep -f "$(hb_detector_pattern)" >/dev/null 2>&1; }

hb_count_mp4() {
  local f n=0
  for f in "$1"/*.mp4; do [[ -e $f ]] && n=$((n + 1)); done
  echo "$n"
}

hb_status_line() {
  local age free
  age=$(hb_newest_seg_age) && age="${age}s" || age=none
  free=$(df -Pk "$WORKDIR" 2>/dev/null | awk 'NR==2{printf "%.1fG", $4/1048576}')
  echo "seg_age=$age clips=$(hb_count_mp4 "$CLIPS") held=$(hb_count_mp4 "$HELD") disk_free=${free:-?}"
}

# hb_check: rc 0 healthy; rc 1 unhealthy with the reason in REPLY.
hb_check() {
  local age
  if ! age=$(hb_newest_seg_age); then
    REPLY="no segments in the ring"; return 1
  fi
  if ((age > HB_MAX_SEG_AGE)); then
    REPLY="newest segment is ${age}s old (max ${HB_MAX_SEG_AGE}s)"; return 1
  fi
  if ! hb_detector_running; then
    REPLY="detector ffmpeg is not running"; return 1
  fi
  REPLY=ok
}

# hb_ping URL BODY. curl's stderr is dropped: it can echo the URL.
hb_ping() {
  curl -fsS -m 10 --retry 3 --data-raw "$2" "$1" </dev/null >/dev/null 2>&1
}

heartbeat_run() {
  [[ -n "${HC_URL:-}" ]] || return 0
  local url=$HC_URL body
  if hb_check; then
    body=$(hb_status_line)
  else
    body="UNHEALTHY: $REPLY | $(hb_status_line)"
    url="${HC_URL%/}/fail"
    hb_log "heartbeat: no saludable ($REPLY)"
  fi
  hb_ping "$url" "$body" || hb_log "heartbeat: ping fallido (red o healthchecks)"
  return 0
}

hb_main() {
  set -u
  if [[ -z "${HC_URL:-}" && -r "$HOME/.tapo_env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$HOME/.tapo_env" 2>/dev/null
    set +a
  fi
  hb_defaults
  heartbeat_run
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then hb_main "$@"; fi
