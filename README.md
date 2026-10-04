# tapo-nvr

**A tiny, self-hosted NVR for a TP-Link Tapo camera that runs entirely on an Android tablet.**
It records only what matters (people and vehicles that actually move), keeps a few
seconds of pre-roll, uploads the clips to Google Drive, and emails you a daily summary.
No Tapo Care subscription, no server, no cloud AI.

```
motion on the street ──► 2K clip with 5 s of pre-roll ──► YOLO: did a person/vehicle move?
                                                            ├─ yes ─► Google Drive ─► daily email
                                                            └─ no  ─► deleted on the tablet
```

---

## Why

Pixel-based motion detection on a camera that faces a street fires all day: shadows,
lighting changes, the IR switch at dusk, dogs sleeping on the sidewalk, parked cars.
Uploading all of that buries the two clips a day you actually care about.

`tapo-nvr` keeps cheap pixel motion as the *trigger* and adds an object detector as a
*gate* before anything leaves the device. A detection only counts if it **overlaps
motion**, so a dog sleeping in frame or a parked car never passes on its own.

## Features

- **Pre-roll** – a rolling buffer of 2K segments means each clip starts ~5 s *before* the trigger.
- **Motion-gated object detection** – YOLO11n (ONNX) on 8 frames per clip, ~1.5 s per clip on a Snapdragon 8 Gen 2.
- **Fail-safe by design** – if the detector crashes, the clip is *held* locally: never uploaded, never deleted.
- **Unattended** – starts on boot (Termux:Boot), supervises itself, survives camera/Wi-Fi drops and IP changes.
- **Dead-man's switch** – a [healthchecks.io](https://healthchecks.io) heartbeat emails you if recording stops.
- **Daily email** – counts, detections and a link to every clip, sent by a Google Apps Script in your own account.
- **Retention** – clips older than 60 days are purged from Drive (for real, not to the trash).
- **Tested** – bash and Python test suites, `shellcheck`-clean.

## Architecture

```mermaid
flowchart LR
  cam[Tapo C520WS]
  subgraph tablet[Android tablet · Termux]
    det[detector ffmpeg<br/>stream2 640x360<br/>scene score]
    seg[segmenter ffmpeg<br/>stream1 2K<br/>ring buffer]
    hit[hit counter<br/>MIN_HITS in WINDOW]
    cap[capture<br/>concat pre-roll + clip]
    gate{gate<br/>YOLO + motion}
    hk[housekeeper<br/>heartbeat · summary]
  end
  drive[(Google Drive)]
  hc[healthchecks.io]
  gas[Apps Script]
  mail[[your inbox]]

  cam -- RTSP --> det --> hit --> cap
  cam -- RTSP --> seg --> cap
  cap --> gate
  gate -- person / vehicle moving --> drive
  gate -- nothing --> trash[deleted locally]
  gate -- error --> held[held locally]
  hk -- ping every 5 min --> hc -- missed pings --> mail
  hk -- daily JSON --> drive --> gas --> mail
```

The camera accepts two simultaneous RTSP connections: one for detection, one for
the ring buffer. If the ring is incomplete, capture falls back to a direct recording
without pre-roll.

## Repository layout

| Path | What it is |
|------|------------|
| `tapo-watch.sh` | The recorder: detector, segmenter, capture, upload, purge |
| `gate/detect.py` | Motion-gated YOLO clip gate (stdlib + numpy + onnxruntime + ffmpeg) |
| `gate/run-gate.sh` | Termux-safe entry point for the gate |
| `gate/get-model.sh` | How the ONNX model is exported (the model itself is not committed) |
| `termux/boot-tapo.sh` | Termux:Boot launcher: wake lock, single-instance supervisor |
| `termux/housekeeper.sh` | Runs the heartbeat and the daily summary |
| `termux/heartbeat.sh` | healthchecks.io ping, only when the camera is really recording |
| `termux/daily-summary.py` | Turns the last 24 h of the log into JSON |
| `apps-script/Code.gs` | Google Apps Script that emails the daily summary |
| `tests/` | Bash and Python tests |

## Quick start

### 1. Camera

In the Tapo app: camera → Settings → Advanced settings → **Camera account**. This
enables RTSP at `rtsp://USER:PASS@CAMERA_IP:554/stream1` (2K) and `/stream2` (360p).

### 2. Tablet (Termux)

Install **Termux** and **Termux:Boot** from F-Droid or GitHub (not Play Store), open
Termux:Boot once, exclude Termux from battery optimization, and keep the tablet plugged in.

```sh
pkg install ffmpeg rclone python python-numpy python-onnxruntime curl util-linux
git clone https://github.com/<you>/tapo-nvr ~/tapo-nvr
cp ~/tapo-nvr/tapo_env.example ~/.tapo_env && chmod 600 ~/.tapo_env   # then edit it
rclone config                                                          # remote named drive-tapo
```

Build the model on a desktop and copy it over (see `gate/get-model.sh`), then verify it:

```sh
cd ~/tapo-nvr/gate/models && sha256sum -c yolo11n.onnx.sha256
```

Install the launcher and start it (it also starts on every boot):

```sh
mkdir -p ~/.termux/boot && install -m 755 ~/tapo-nvr/termux/boot-tapo.sh ~/.termux/boot/
~/.termux/boot/boot-tapo.sh &
```

> **Android 12+:** the "phantom process killer" can silently kill Termux's child
> processes. On Android 14+ enable *Developer options → Disable child process
> restrictions*, or from a computer:
> `adb shell settings put global settings_enable_monitor_phantom_procs false`.

> **After a reboot** Android does not run any app code until the device is unlocked
> once (file-based encryption). Unlock the tablet after a power cut.

### 3. Monitoring

1. Create a check on [healthchecks.io](https://healthchecks.io) with **Period 5 min, Grace 15 min**
   and add `HC_URL=<ping url>` to `~/.tapo_env`.
2. Create a project at [script.google.com](https://script.google.com), paste
   `apps-script/Code.gs`, run `setup` once and accept the permissions. It schedules the
   daily email (21:00–22:00 local time) and sends one right away.

## Configuration

Everything lives in `~/.tapo_env`, which is sourced by every script. See
[`tapo_env.example`](tapo_env.example) for every variable and its default.
**Never commit that file:** it holds the camera password and the heartbeat URL.

| Variable | Default | Meaning |
|----------|---------|---------|
| `CAM_IP`, `CAM_USER`, `CAM_PASS` | – | Camera address and RTSP account. If the IP changes, the script rescans the /24 for port 554 |
| `SCENE` | `0.005` | Per-frame scene-change threshold |
| `MIN_HITS` / `WINDOW` | `4` / `3` | Hits needed within `WINDOW` seconds of *stream time* to trigger |
| `PREROLL_SECS` / `CLIP_SECS` | `5` / `30` | Seconds before / after the trigger |
| `DEBOUNCE` | `40` | Minimum seconds between triggers |
| `RETENTION_DAYS` | `60` | Drive retention |
| `GATE_CMD` | unset | Gate executable; unset = upload everything |
| `HC_URL` | unset | healthchecks.io ping URL; unset = no heartbeat |
| `SUMMARY_AT` | `20:55` | Local time of the daily summary |

Calibrate the motion threshold against your own scene:

```sh
~/tapo-nvr/tapo-watch.sh --calibrar 30   # walk in front of the camera for 30 s
```

## The clip gate

Between producing a clip and uploading it, the recorder runs `"$GATE_CMD" clip.mp4`
and acts on the exit code:

| Exit code | Action |
|-----------|--------|
| `0` | upload |
| `1` | discard (deleted locally) |
| anything else | **hold** in `held/`: never uploaded, never deleted |

The bundled gate, `gate/detect.py`:

1. Samples `GATE_FRAMES` frames evenly across the clip, letterboxed to 640x640.
2. Builds a background as the per-pixel **median** of those frames; motion mask =
   `|frame − median| > GATE_DIFF_THRESH`. Anything that never moved, such as a sleeping dog, is background.
3. Runs YOLO11n on every frame (decoding and NMS in plain numpy).
4. Keeps a detection only if its class is allowed, its confidence ≥ `GATE_CONF`, and
   the share of moving pixels inside its box ≥ `GATE_MOTION_FRAC`.

It prints one JSON line per clip, which ends up in the log:

```json
{"clip":"mov_2026-10-04_11-51-02.mp4","frames":8,"detections":[{"frame":7,"class":"person","conf":0.842,"motion_frac":0.543}],"decision":"upload","elapsed_ms":1965}
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `GATE_CLASSES` | `person,bicycle,car,motorcycle,bus,truck` | COCO classes that count |
| `GATE_CONF` | `0.4` | Minimum confidence |
| `GATE_MOTION_FRAC` | `0.15` | Minimum share of moving pixels inside the box |
| `GATE_DIFF_THRESH` | `25` | Grey-level difference that counts as motion |
| `GATE_FRAMES` | `8` | Frames sampled per clip |
| `GATE_THREADS` | `4` | onnxruntime threads |

**Tuning.** Missing real movers? Lower `GATE_CONF` or `GATE_MOTION_FRAC`. A person who
stands still for more than half the clip becomes part of the median background; raise
`GATE_FRAMES`. Too many uploads? Camera pans and exposure jumps light up the whole frame,
so raise `GATE_DIFF_THRESH` or `GATE_MOTION_FRAC`.

## Monitoring

**Heartbeat.** Every 5 minutes `heartbeat.sh` checks that the newest ring segment is
fresh and that the detector is running. If both hold, it pings `HC_URL`; otherwise it
pings `HC_URL/fail` with the reason. If the tablet itself dies, the pings stop and
healthchecks.io emails you.

**Daily summary.** At `SUMMARY_AT` the housekeeper turns the last 24 h of `tapo.log`
into `resumenes/YYYY-MM-DD.json` on Drive. The Apps Script mails it:

```
📹 Cámara — dom 4 oct · 3 subido(s), 20 descartado(s)
  eventos 23 · subidos 3 · descartados 20 · retenidos 0 · reinicios 1
  11:51  person (0.84)  ▶ ver
  15:20  car (0.71)     ▶ ver
```

If the file is missing, you get a warning email instead: the tablet did not report.

<details>
<summary>Summary JSON contract</summary>

```json
{"date":"2026-10-04","window_start":"2026-10-03T20:55:00-05:00","window_end":"2026-10-04T20:55:00-05:00",
 "events":5,"uploaded":3,"discarded":1,"held":1,"gate_errors":1,"restarts":1,
 "incidents":[{"time":"02:00","msg":"monitor cayo (red o camara) — reintento en 15s"}],
 "incidents_total":3,
 "clips":[{"time":"21:10","file":"mov_2026-10-03_21-10-05.mp4","folder":"2026-10","size":"6.3M",
           "labels":[{"class":"person","conf":0.842},{"class":"car","conf":0.7}]}]}
```

- `events` counts triggers; `clips` lists uploaded clips only, in chronological order.
- `labels` are gate detections deduplicated by class (max confidence).
- `incidents` is capped at 20; `incidents_total` is the real count.
- Log lines are Spanish (`MOVIMIENTO`, `subido`, `descartado por filtro`, …) and the parser matches them.

</details>

## Tests

```sh
bash tests/run.sh                 # bash >= 5 (on macOS: brew install bash)
python -m unittest                # needs numpy; onnxruntime for the model tests
GATE_TEST_CLIP=clip.mp4 python -m unittest   # also runs the real-clip test
shellcheck tapo-watch.sh tests/*.sh gate/*.sh termux/*.sh
```

To run the recorder offline, set `RTSP_LO`/`RTSP_HI` to local files with
`IN_OPTS="-re -stream_loop -1"`. That skips `~/.tapo_env` and camera discovery.

## Gotchas learned the hard way

- **Audio is G.711 A-law.** MP4 rejects it, so audio is transcoded to AAC and video is always stream-copied.
- **ffmpeg inside a `while read` loop eats the loop's stdin.** Every ffmpeg call uses `-nostdin`.
- **A blocking capture inside the read loop self-retriggers.** Buffered detector lines come in a burst afterwards. Capture runs in the background, and hits are counted on `pts_time`, not the wall clock.
- **Termux:Boot starts processes without termux-exec**, so `#!/usr/bin/env python3` fails with "bad interpreter". Use absolute Termux shebangs, as in `gate/run-gate.sh`.
- **rclone's shared Google `client_id` is being retired.** Create your own OAuth client and **publish** the consent screen; in *Testing* the refresh token dies after 7 days.
- **`rclone delete` sends files to the Drive trash**, where they still use quota. Use `--drive-use-trash=false`.
- **ONVIF PullPoint events do not work** on the C520WS firmware. Subscriptions are created, but pulling them is refused. Motion has to come from the video itself.

## License note

The YOLO11 weights and the Ultralytics export tooling are **AGPL-3.0**. The model is not
included here. If you need a permissive stack, swap in an Apache-2.0 detector (for
example YOLOX or RT-DETR) and adapt `decode()` in `gate/detect.py` to its output layout.
