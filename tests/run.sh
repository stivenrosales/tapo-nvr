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
  RING_WAIT_SECS=0
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

# ---------- unit 2: pre-roll ring buffer ----------
seg_names() { local e; for e in "$@"; do echo "seg_$e.ts"; done; }

test_select_segments_range() {
  setup; SEG_SECS=5
  # [112,128]: seg 110 covers 110-115 (contains 112); 125 covers up to 130
  local got
  got=$(seg_names 100 105 110 115 120 125 130 135 | select_segments 112 128 | tr '\n' ' ')
  assert_eq "seg_110.ts seg_115.ts seg_120.ts seg_125.ts " "$got"
}

test_select_segments_edges_and_junk() {
  setup; SEG_SECS=5
  local got
  # seg 105 ends exactly at 110 == start -> excluded; seg 130 starts at end -> included
  got=$( { echo junk.txt; echo seg_abc.ts; seg_names 130 105 110; } | select_segments 110 130 | tr '\n' ' ')
  assert_eq "seg_110.ts seg_130.ts " "$got" "sorted numerically, junk ignored"
  got=$(seg_names 90 95 | select_segments 110 130)
  assert_eq "" "$got" "nothing in range"
}

test_segments_closed_through() {
  setup
  seg_names 120 125 | segments_closed_through 128; assert_rc 1 $? "still writing last seg"
  seg_names 120 125 130 | segments_closed_through 128; assert_rc 0 $? "a newer seg exists"
  : | segments_closed_through 128; assert_rc 1 $? "empty ring"
}

test_ring_coverage_ok() {
  setup; SEG_SECS=5
  : | ring_coverage_ok 128; assert_rc 1 $? "empty selection"
  seg_names 110 115 120 125 | ring_coverage_ok 128; assert_rc 0 $? "reaches the end"
  seg_names 100 105 | ring_coverage_ok 128; assert_rc 1 $? "segmenter died early"
}

test_select_prune() {
  setup; RING_SECS=120
  local got
  got=$(seg_names 800 879 880 900 1000 | select_prune 1000 | tr '\n' ' ')
  assert_eq "seg_800.ts seg_879.ts " "$got" "only older than RING_SECS"
}

test_prune_ring_deletes_only_old_segments() {
  setup; RING_SECS=120
  touch "$RING/seg_100.ts" "$RING/seg_950.ts" "$RING/keep.txt"
  prune_ring 1000
  assert_no_file "$RING/seg_100.ts"
  assert_file "$RING/seg_950.ts"
  assert_file "$RING/keep.txt"
}

test_segmenter_command_line() {
  setup; SEG_SECS=7
  local args; args=" $(segmenter_cmd_args | tr '\n' ' ')"
  local want
  for want in " -nostdin " " -fflags +genpts " " -i rtsp://stub/stream1 " " -c:v copy " \
              " -c:a aac " " -f segment " " -segment_time 7 " " -reset_timestamps 1 " \
              " -strftime 1 " "/seg_%s.ts"; do
    assert_contains "$args" "$want"
  done
  # genpts must be an INPUT option (before -i)
  [[ "${args%%-fflags*}" != *" -i "* ]] || fail "-fflags +genpts after -i"
}

test_segmenter_is_supervised() {
  setup
  ( n=0; sleep() { n=$((n + 1)); ((n >= 3)) && exit 0; }; segmenter_loop </dev/null ) >/dev/null
  assert_eq 3 "$(wc -l <"$T/ffmpeg.calls" | tr -d ' ')" "segmenter restarted after each exit"
}

test_clip_built_from_ring_with_preroll() {
  setup; SEG_SECS=5; PREROLL_SECS=5; CLIP_SECS=10
  local e; for e in 1690 1695 1700 1705 1710 1715 1720; do touch "$RING/seg_$e.ts"; done
  capture 1700 >/dev/null
  # window [1695, 1710]: 1690 ends at 1695 (excluded); 1695..1710 included
  assert_eq "file '$RING/seg_1695.ts'
file '$RING/seg_1700.ts'
file '$RING/seg_1705.ts'
file '$RING/seg_1710.ts'" "$(<"$T/ffmpeg.concat")" "concat list"
  local call; call=$(rg 'concat' "$T/ffmpeg.calls")
  assert_contains "$call" "-nostdin"
  assert_contains "$call" "-c copy"
  assert_contains "$call" "-bsf:a aac_adtstoasc"
  assert_contains "$call" "-movflags +faststart"
  assert_contains "$call" "mov_"
  assert_eq 1 "$(wc -l <"$T/ffmpeg.calls" | tr -d ' ')" "no direct recording when the ring is enough"
  assert_contains "$(<"$T/rclone.calls")" "move $CLIPS/mov_"
  assert_no_file "$RING/concat_1710_$$.txt"
}

test_capture_falls_back_to_direct_when_ring_empty() {
  setup; CLIP_SECS=3
  capture 1700 >/dev/null
  local call; call=$(<"$T/ffmpeg.calls")
  assert_contains "$call" "-i rtsp://stub/stream1"
  assert_contains "$call" "-t 3"
  assert_contains "$(<"$T/rclone.calls")" "move $CLIPS/mov_"
}

test_capture_falls_back_when_segmenter_died_midclip() {
  setup; SEG_SECS=5; PREROLL_SECS=5; CLIP_SECS=30
  touch "$RING/seg_1690.ts" "$RING/seg_1695.ts"   # then nothing: segmenter died
  capture 1700 >/dev/null
  assert_contains "$(<"$T/ffmpeg.calls")" "-i rtsp://stub/stream1"
}

# ---------- unit 3: clip gate ----------
make_gate() { # make_gate EXIT_CODE -> sets GATE_CMD to a script that records its arg
  cat >"$T/gate.sh" <<GATE
#!/usr/bin/env bash
echo "\$1" >> "$T/gate.args"
exit $1
GATE
  chmod +x "$T/gate.sh"; export GATE_CMD="$T/gate.sh"
}

test_gate_map_code() {
  local c
  gate_map_code 0; assert_rc 0 $? "0 -> upload"
  gate_map_code 1; assert_rc 1 $? "1 -> discard"
  for c in 2 3 126 127 130 139; do
    gate_map_code "$c"; assert_rc 2 $? "$c -> hold (fail-safe)"
  done
}

test_clip_gate_default_uploads() {
  setup
  clip_gate "$CLIPS/x.mp4"; assert_rc 0 $?
}

test_clip_gate_runs_cmd_with_file_and_maps() {
  setup
  make_gate 0; clip_gate "$CLIPS/x.mp4"; assert_rc 0 $? "exit 0"
  assert_eq "$CLIPS/x.mp4" "$(<"$T/gate.args")" "gate receives the file"
  make_gate 1; clip_gate "$CLIPS/x.mp4"; assert_rc 1 $? "exit 1"
  make_gate 7; clip_gate "$CLIPS/x.mp4"; assert_rc 2 $? "other -> hold"
  GATE_CMD="$T/does-not-exist"; clip_gate "$CLIPS/x.mp4"; assert_rc 2 $? "missing cmd -> hold"
}

test_clip_gate_appends_gate_stdout_to_log() {
  setup
  cat >"$T/gate.sh" <<'GATE'
#!/usr/bin/env bash
echo '{"clip":"x.mp4","decision":"discard"}'
exit 1
GATE
  chmod +x "$T/gate.sh"; export GATE_CMD="$T/gate.sh"
  LOG="$T/watch.log"
  clip_gate "$CLIPS/x.mp4"; assert_rc 1 $? "exit 1 -> discard"
  assert_contains "$(<"$T/watch.log")" '"decision":"discard"' "gate JSON line in the log"
}

test_capture_gate_pass_uploads() {
  setup; make_gate 0
  capture 1700000000 >/dev/null
  assert_contains "$(<"$T/rclone.calls")" "move $CLIPS/mov_"
}

test_capture_gate_discard_deletes_and_logs() {
  setup; make_gate 1
  capture 1700000000 >/dev/null
  assert_no_file "$T/rclone.move"
  [[ ! -f "$T/rclone.calls" ]] || ! rg -q '^move ' "$T/rclone.calls" || fail "discarded clip was uploaded"
  assert_eq 0 "$(fd -e mp4 . "$CLIPS" "$HELD" | wc -l | tr -d ' ')" "no clip left anywhere"
  assert_contains "$(<"$T/log")" "descartado por filtro"
}

test_capture_gate_hold_keeps_in_held_dir() {
  setup; make_gate 9
  capture 1700000000 >/dev/null
  [[ ! -f "$T/rclone.calls" ]] || ! rg -q '^move ' "$T/rclone.calls" || fail "held clip was uploaded"
  assert_eq 1 "$(fd -e mp4 . "$HELD" | wc -l | tr -d ' ')" "clip kept in held/"
  assert_eq 0 "$(fd -e mp4 . "$CLIPS" | wc -l | tr -d ' ')" "not left in the upload queue"
  assert_contains "$(<"$T/log")" "retenido"
}

test_flush_pending_never_uploads_held() {
  setup
  echo x > "$HELD/held.mp4"
  flush_pending
  [[ ! -f "$T/rclone.calls" ]] || fail "flush touched rclone with only held clips"
  echo y > "$CLIPS/pending.mp4"
  flush_pending
  assert_contains "$(<"$T/rclone.calls")" "move $CLIPS "
  [[ "$(<"$T/rclone.calls")" != *"$HELD"* ]] || fail "held dir referenced"
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
