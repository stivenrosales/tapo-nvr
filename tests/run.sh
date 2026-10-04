#!/usr/bin/env bash
# Plain-bash test runner (no bats). Run with bash >= 5:
#   /opt/homebrew/bin/bash tests/run.sh
# Every function named test_* runs in its own subshell with a fresh temp dir
# and PATH-stubbed ffmpeg/rclone.
# shellcheck disable=SC2034,SC2329,SC1091
# (vars are consumed by the sourced script; stubs are invoked indirectly)
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/tapo-watch.sh"

# ---------- helpers ----------
fail() { echo "  FAIL: $*"; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-assert_eq}: expected [$1] got [$2]"; }
assert_rc() { # expected_rc actual_rc msg
  [[ "$1" == "$2" ]] || fail "${3:-rc}: expected rc=$1 got rc=$2"
}
assert_file() { [[ -e "$1" ]] || fail "missing file $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "unexpected file $1"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "${3:-contains}: [$1] lacks [$2]"; }

make_stubs() {
  mkdir -p "$T/bin"
  cat >"$T/bin/ffmpeg" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/ffmpeg.calls"
prev=""
for a in "$@"; do
  if [[ "$prev" == "-i" && "$*" == *"-f concat"* ]]; then cp "$a" "$STUB_DIR/ffmpeg.concat"; fi
  prev=$a
done
last="${*: -1}"
case "$last" in *.mp4) echo fakevideo > "$last" ;; esac
[[ -n "${STUB_FFMPEG_FAIL:-}" ]] && exit 1
exit 0
STUB
  cat >"$T/bin/rclone" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/rclone.calls"
if [ -t 0 ]; then echo TTY > "$STUB_DIR/rclone.stdin"; else cat > "$STUB_DIR/rclone.stdin"; fi
[[ -n "${STUB_RCLONE_FAIL:-}" ]] && exit 1
[[ "$1" == move && -f "$2" ]] && rm -f "$2"
exit 0
STUB
  chmod +x "$T/bin/ffmpeg" "$T/bin/rclone"
}

setup() {
  T=$(mktemp -d)
  export STUB_DIR=$T
  make_stubs
  export PATH="$T/bin:$PATH"
  export WORKDIR="$T/work"
  export RTSP_LO="rtsp://stub/stream2" RTSP_HI="rtsp://stub/stream1"
  unset GATE_CMD STUB_FFMPEG_FAIL STUB_RCLONE_FAIL
  apply_defaults
  mkdir -p "$CLIPS" "$HELD" "$RING"
  log() { echo "$*" >> "$T/log"; }   # quiet logger for tests
}

hit() { # hit PTS_TIME -> feeds a pts line then a score line; rc of the score line
  hit_feed_line "[Parsed_metadata_1 @ 0xabc] frame:1  pts:1 pts_time:$1"
  hit_feed_line "[Parsed_metadata_1 @ 0xabc] lavfi.scene_score=0.012345"
}
hit_lines() { # emit the two raw ffmpeg lines for a hit
  echo "[Parsed_metadata_1 @ 0xabc] frame:1  pts:1 pts_time:$1"
  echo "[Parsed_metadata_1 @ 0xabc] lavfi.scene_score=0.012345"
}

# ---------- unit 1: detector + capture fixes ----------
test_pts_to_ms() {
  pts_to_ms 167.628733; assert_eq 167628 "$REPLY"
  pts_to_ms 5; assert_eq 5000 "$REPLY"
  pts_to_ms 0.5; assert_eq 500 "$REPLY"
  pts_to_ms 12.07; assert_eq 12070 "$REPLY"
}

test_hits_trigger_within_window() {
  setup; MIN_HITS=4; WINDOW=3; hit_reset
  hit 10.0; assert_rc 1 $? "hit1"
  hit 10.5; assert_rc 1 $? "hit2"
  hit 11.0; assert_rc 1 $? "hit3"
  hit 11.5; assert_rc 0 $? "hit4 must trigger"
}

test_hits_stale_burst_does_not_trigger() {
  setup; MIN_HITS=4; WINDOW=3; hit_reset
  local n=0 t
  # 10 queued lines flushed at once, but frames are 2s apart in stream time
  for t in 0.0 2.0 4.0 6.0 8.0 10.0 12.0 14.0 16.0 18.0; do
    hit "$t" && n=$((n + 1))
  done
  assert_eq 0 "$n" "triggers on stale burst"
}

test_hits_reset_after_trigger() {
  setup; MIN_HITS=2; WINDOW=3; hit_reset
  hit 1.0; hit 1.1; assert_rc 0 $? "second hit triggers"
  hit 1.2; assert_rc 1 $? "counter restarted after trigger"
}

test_hits_ignore_noise_lines() {
  setup; MIN_HITS=2; WINDOW=3; hit_reset
  hit_feed_line "Input #0, rtsp, from 'rtsp://x':"; assert_rc 1 $?
  hit_feed_line "frame=  100 fps= 15 q=-0.0 size=N/A"; assert_rc 1 $?
  hit 1.0; hit 1.1; assert_rc 0 $? "still triggers"
}

test_hits_pts_going_backwards_resets() {
  setup; MIN_HITS=4; WINDOW=3; hit_reset
  hit 100.0; hit 100.1; hit 100.2
  hit 5.0; assert_rc 1 $? "restart point"
  hit 5.1; assert_rc 1 $? "stale pre-restart hits must not count"
}

test_every_ffmpeg_call_uses_nostdin() {
  setup; CLIP_SECS=1
  capture 1700000000 >/dev/null
  assert_file "$T/ffmpeg.calls"
  local line
  while IFS= read -r line; do
    assert_contains "$line" "-nostdin" "ffmpeg call without -nostdin"
  done <"$T/ffmpeg.calls"
  # detector command line too
  detector_cmd_args | rg -q -- '-nostdin' || fail "detector without -nostdin"
}

test_rclone_gets_closed_stdin() {
  setup
  echo "line that must not be eaten" | upload_clip "$CLIPS/x.mp4" 2026-10
  assert_eq "" "$(<"$T/rclone.stdin")" "rclone stdin must be /dev/null"
}

test_reader_never_blocks_on_capture() {
  setup; MIN_HITS=4; WINDOW=3; DEBOUNCE=40; hit_reset
  capture() { sleep 2; echo ran >> "$T/cap"; }
  local t0=$EPOCHREALTIME t1
  detector_reader < <(for t in 1.0 1.1 1.2 1.3; do hit_lines "$t"; done)
  t1=$EPOCHREALTIME
  (( $(awk -v a="$t0" -v b="$t1" 'BEGIN{print (b-a<1.0)}') )) || fail "reader blocked on capture"
  assert_no_file "$T/cap"
  wait
  assert_eq 1 "$(wc -l <"$T/cap" | tr -d ' ')" "capture ran once in background"
}

test_debounce_is_wall_clock_and_blocks_burst_retrigger() {
  setup; MIN_HITS=2; WINDOW=3; DEBOUNCE=40; hit_reset
  capture() { echo ran >> "$T/cap"; }
  detector_reader < <(for t in 1.0 1.1 1.2 1.3 1.4 1.5; do hit_lines "$t"; done)
  wait
  assert_eq 1 "$(wc -l <"$T/cap" | tr -d ' ')" "only one capture inside DEBOUNCE"
}

test_stale_burst_through_reader_no_capture() {
  setup; MIN_HITS=4; WINDOW=3; DEBOUNCE=40; hit_reset
  capture() { echo ran >> "$T/cap"; }
  detector_reader < <(for t in 0 2 4 6 8 10 12 14 16 18 20 22; do hit_lines "$t"; done)
  wait
  assert_no_file "$T/cap"
}

test_capture_records_and_uploads() {
  setup; CLIP_SECS=1
  capture 1700000000 >/dev/null
  assert_contains "$(<"$T/rclone.calls")" "move $CLIPS/mov_"
  assert_contains "$(<"$T/rclone.calls")" "drive-tapo:Camara/2023-11/"
}

test_flush_pending_uploads_clips_dir() {
  setup
  echo x > "$CLIPS/old.mp4"
  flush_pending
  assert_contains "$(<"$T/rclone.calls")" "move $CLIPS "
}

# ---------- driver ----------
main_tests() {
  local filter=${1:-} pass=0 failn=0 t out
  for t in $(declare -F | awk '{print $3}' | rg '^test_'); do
    [[ -z "$filter" || "$t" == *"$filter"* ]] || continue
    if out=$( ( "$t" ) 2>&1 ); then
      echo "ok   $t"; pass=$((pass + 1))
    else
      echo "FAIL $t"; echo "     ${out//$'\n'/$'\n'     }"; failn=$((failn + 1))
    fi
  done
  echo "--- $pass passed, $failn failed"
  [[ $failn -eq 0 ]]
}
main_tests "${1:-}"
