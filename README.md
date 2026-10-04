# tapo-nvr

Motion-triggered recorder for a TP-Link Tapo C520WS, built to run in Termux on
an old Android tablet. It watches the camera's low-res stream, records the
2K stream with a few seconds of **pre-roll** when something moves, uploads the
clip to Google Drive and purges old ones.

Single script (`tapo-watch.sh`), bash 5, no dependencies beyond
`ffmpeg`, `rclone`, coreutils and awk.

## Pipeline

```
                 stream2 (640x360)                    scene score, pts_time
 camera ───────────────────────────► detector ffmpeg ─────────────┐
   │                                                              ▼
   │ stream1 (2K)                                     hit counter (MIN_HITS in
   │                                                  WINDOW s of stream time)
   ▼                                                              │ trigger @ T
 segmenter ffmpeg ─► ring/seg_<epoch>.ts  (pruned > RING_SECS)    │ (+DEBOUNCE)
 (copy video, AAC)            │                                   ▼
                              └──────────► capture (background): wait T+CLIP,
                                           concat [T-PREROLL, T+CLIP] -> mp4
                                                              │
                                                              ▼
                                                   clip_gate ($GATE_CMD)
                                          0 upload │ 1 discard │ other: hold
                                                   ▼
                              rclone move -> drive-tapo:Camara/YYYY-MM/
```

The camera allows two simultaneous RTSP connections: one for the detector, one
for the segmenter. If the ring is incomplete (segmenter down) the capture falls
back to a direct recording without pre-roll.

## Install (Termux)

```sh
pkg install ffmpeg rclone termux-api
termux-wake-lock
```

- Install **Termux:Boot** and put a launcher in `~/.termux/boot/` that runs
  `~/tapo-nvr/tapo-watch.sh`.
- Disable battery optimization for Termux, Termux:Boot and Termux:API.
- Keep the tablet plugged in permanently.
- `rclone config`: create a remote named `drive-tapo` (see gotchas below).
- `cp tapo_env.example ~/.tapo_env && chmod 600 ~/.tapo_env`, then edit it.

## Config

Credentials and tunables live in `~/.tapo_env` (see `tapo_env.example` for every
variable and its default). If the camera IP stops answering, the script scans
the /24 for port 554 and tells you the new `CAM_IP`.

## Tuning

```sh
./tapo-watch.sh --calibrar 30   # move in front of the camera for 30 s
```

Prints the background-noise median and your motion peak and suggests a `SCENE`
value. Hit counting uses the frame timestamps (`pts_time`), not wall clock, so a
backlog of buffered lines can never fake a detection.

## Clip gate (`GATE_CMD`)

Between producing the clip and uploading it the script calls
`clip_gate <file>`. With `GATE_CMD` unset every clip is uploaded. With it set,
`"$GATE_CMD" <file.mp4>` runs and its exit code decides:

| exit code | action |
|-----------|--------|
| 0 | upload |
| 1 | discard (deleted locally, logged "descartado por filtro") |
| anything else (crash, 127, timeout...) | **hold**: moved to `$WORKDIR/held/`, never uploaded, never deleted |

Fail-safe by design: a broken detector never loses a clip and never leaks one.
`flush_pending` only retries `clips/`, never `held/`. This is the plug-in point
for detectors; the bundled one is described below. Whatever the gate prints on
stdout/stderr is appended to the watcher log.

### Bundled gate: `gate/detect.py`

Uploads a clip only if a **person or vehicle MOVES** in it. A plain "is there a
dog/car in the frame" check would pass every clip here (sleeping dogs, parked
cars), so a detection only counts if it overlaps motion.

1. Pick `GATE_FRAMES` frames evenly across the clip (ffmpeg decodes at 2 fps,
   downscaled and letterboxed to 640x640, rgb24 on a pipe).
2. Background = per-pixel median of those frames (grayscale). Motion mask per
   frame = `|gray - median| > GATE_DIFF_THRESH`, cleaned with 8x8 block pooling
   (a block needs >= 25% changed pixels).
3. YOLO11n (ONNX, COCO, raw `[1, 84, 8400]` output) runs on every sampled frame;
   decoding and NMS are plain numpy.
4. A detection qualifies if its class is in `GATE_CLASSES`, conf >=
   `GATE_CONF`, and the share of motion pixels inside its box >=
   `GATE_MOTION_FRAC`.

Exit codes: `0` a qualifying detection exists (upload), `1` none (discard),
`2` any error: missing model, ffmpeg failure, fewer than 3 decodable frames,
bad env value (the watcher holds the clip). One JSON line goes to stdout:

```json
{"clip":"cam_02.mp4","frames":8,"detections":[{"frame":1,"class":"person","conf":0.711,"motion_frac":0.168}],"decision":"upload","elapsed_ms":573}
```

| variable | default | meaning |
|----------|---------|---------|
| `GATE_MODEL` | `gate/models/yolo11n.onnx` | ONNX model path |
| `GATE_FRAMES` | 8 | frames sampled per clip |
| `GATE_THREADS` | 4 | onnxruntime intra-op threads |
| `GATE_CLASSES` | person,bicycle,car,motorcycle,bus,truck | comma-separated COCO names |
| `GATE_CONF` | 0.4 | min detection confidence |
| `GATE_MOTION_FRAC` | 0.15 | min motion share inside the box |
| `GATE_DIFF_THRESH` | 25 | gray-level diff that counts as motion |

Install on Termux (needs only python, numpy, onnxruntime, ffmpeg):

```sh
pkg install python python-numpy python-onnxruntime ffmpeg
# on a desktop: gate/get-model.sh builds gate/models/yolo11n.onnx; then
scp gate/models/yolo11n.onnx tablet:tapo-nvr/gate/models/
cd ~/tapo-nvr/gate/models && sha256sum -c yolo11n.onnx.sha256
echo 'GATE_CMD=$HOME/tapo-nvr/gate/detect.py' >> ~/.tapo_env
```

Try it by hand: `gate/detect.py clip.mp4; echo $?`.

Tuning notes:
- Missed a real mover (exit 1)? Lower `GATE_CONF` (0.3) or `GATE_MOTION_FRAC`
  (0.08). People who stand still for most of the clip become part of the median
  background and can be missed; raise `GATE_FRAMES` to 12 for a sharper median.
- Too many uploads? Camera pans/exposure changes light up the whole frame and
  make everything "moving"; raise `GATE_DIFF_THRESH` or `GATE_MOTION_FRAC`.
- Other animals never qualify unless you add them to `GATE_CLASSES`.
- Cost: about 0.6-1.2 s per 25 s 2K clip on an Apple-silicon Mac; expect a few
  times that on the tablet (decode of 2560x1440 h264 dominates).

**Licensing:** Ultralytics YOLO weights and tooling are AGPL-3.0. That is fine
for this private, personal setup. If you ever need a permissive license, use an
Apache-2.0 detector (e.g. YOLOX or RT-DETR from other projects) exported to the
same `[1, 84, N]`-style output, or adapt `decode()` to its layout.

**Android 12+ phantom process killer:** the watcher, segmenter, detector ffmpeg
and the gate are several child processes of Termux, and Android may kill them
silently. On Android 14+ enable *Developer options > Disable child process
restrictions*. On Android 12/13 run from a computer:
`adb shell settings put global settings_enable_monitor_phantom_procs false`
(on 12L/13 `device_config put activity_manager max_phantom_processes 2147483647`
is the alternative).

## Tests

```sh
/opt/homebrew/bin/bash tests/run.sh   # needs bash >= 5 (macOS /bin/bash is 3.2)
shellcheck tapo-watch.sh tests/*.sh gate/*.sh
python -m unittest                    # gate; needs numpy (+ onnxruntime for model tests)
GATE_TEST_CLIP=/path/clip.mp4 python -m unittest   # also runs the real-clip test
```

For offline runs `RTSP_LO`/`RTSP_HI` can be set to local files together with
`IN_OPTS="-re -stream_loop -1"`; this skips `~/.tapo_env` and camera discovery.

## Known gotchas

- **Audio is `pcm_alaw`**: MP4 rejects it, so audio is transcoded to AAC
  (`-c:a aac`); video is always `-c:v copy`.
- **rclone's shared `client_id` is being retired.** Create your own Google OAuth
  client, and set the consent screen to **Published** (not *Testing*) or the
  refresh token dies after 7 days.
- **`rclone delete` without `--drive-use-trash=false`** moves files to the Drive
  trash, where they keep consuming quota. The purge uses the flag; do the same
  in any manual cleanup.
- The camera's timestamps are not always monotonic (`non monotonically
  increasing dts` warnings); the segmenter uses `-fflags +genpts` to mitigate.
