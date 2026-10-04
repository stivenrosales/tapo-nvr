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
for a future person/vehicle detector.

## Tests

```sh
/opt/homebrew/bin/bash tests/run.sh   # needs bash >= 5 (macOS /bin/bash is 3.2)
shellcheck tapo-watch.sh tests/*.sh
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
