# CLAUDE.md

Guidance for AI agents working in this repository. Read README.md for the full picture;
this file covers what is easy to get wrong.

## What this is

A self-hosted NVR for a Tapo camera that runs in **Termux on an Android tablet**
(bash 5, python 3, ffmpeg, rclone). Development and tests happen on a Mac; the tablet
only runs the code. Pipeline: pixel-motion trigger → 2K clip with pre-roll → YOLO
clip gate → Google Drive. A housekeeper sends a healthchecks.io heartbeat and a daily
summary JSON that a Google Apps Script (`apps-script/Code.gs`) emails.

## Layout

| Path | Role |
|------|------|
| `tapo-watch.sh` | Recorder. All logic in functions, `main` behind a `BASH_SOURCE` guard so tests can source it |
| `gate/detect.py` | Motion-gated YOLO gate. Runtime deps: stdlib, numpy, onnxruntime, ffmpeg binary only |
| `gate/run-gate.sh` | The `GATE_CMD` entry point on the tablet |
| `termux/` | Boot launcher, housekeeper, heartbeat, daily summary |
| `apps-script/Code.gs` | Lives in the owner's Google account; the repo copy is the source of truth |
| `docs/` | Illustration and its generator (`make-illustration.py`) |
| `tests/` | `run.sh` (bash) and `test_*.py` (unittest) |

## Commands

```sh
/opt/homebrew/bin/bash tests/run.sh      # macOS /bin/bash is 3.2 — always use bash 5
python -m unittest                       # needs numpy + onnxruntime (use a venv)
shellcheck tapo-watch.sh tests/*.sh gate/*.sh termux/*.sh
```

All three must pass before a commit. Work test-first. Keep shellcheck clean.

## Hard rules

- **Never commit secrets.** The camera user and password, `HC_URL`, and rclone tokens
  live only in `~/.tapo_env` (chmod 600) on each machine. No real IPs, MACs or emails
  in code, tests, docs or commit messages either. This repo is **public**.
- **Never print an RTSP URL unmasked.** ffmpeg command lines contain the password.
  Pipe any process listing through `sed -E 's#rtsp://[^ ]*#rtsp://***#g'`, and never
  `cat ~/.tapo_env`. List variable names with `grep -o '^[A-Z_]*=' ~/.tapo_env`.
- **Production scripts may not depend on rg/fd/jq.** Only bash, coreutils, awk, curl,
  rclone, util-linux `flock` and the python stdlib, plus numpy/onnxruntime for the
  gate. Tests may use rg/fd.
- **Termux shebangs.** Termux:Boot starts processes without termux-exec, so
  `#!/usr/bin/env ...` fails with "bad interpreter". Executables that run on the
  tablet use `#!/data/data/com.termux/files/usr/bin/bash`, or are called through an
  explicit interpreter (`python3 script.py`, as `run-gate.sh` does).
- **Every ffmpeg call uses `-nostdin`.** It runs inside `while read` loops and would
  otherwise swallow their input.
- **Log lines are Spanish and are a contract.** `termux/daily-summary.py` parses
  `MOVIMIENTO`, `subido:`, `descartado por filtro`, `retenido localmente`,
  `monitor cayo` and `vigilancia activa`. Change both sides together, with tests.
- **The gate is fail-safe.** Exit 0 means upload, 1 means discard, anything else means
  hold. Never make an error path delete or upload a clip.
- Conventional commits. No AI attribution or Co-Authored-By trailers.

## Deploying to the tablet

The tablet runs `sshd` bound to `127.0.0.1` with key-only auth, so you reach it over
USB with adb. Its paths: code in `~/tapo-nvr`, work dir and logs in `~/tapo`
(`tapo.log`, `boot.log`, `ring/`, `clips/`, `held/`, `summaries/`), and the launcher
installed at `~/.termux/boot/boot-tapo.sh`.

```sh
adb forward tcp:8022 tcp:8022
T(){ ssh -i ~/.ssh/<tablet-key> -p 8022 -o BatchMode=yes localhost "$@"; }

# ship the committed tree (the .onnx model is not in git; scp it separately if it changed)
git archive --format=tar HEAD | T 'tar -xf - -C ~/tapo-nvr && chmod +x ~/tapo-nvr/tapo-watch.sh ~/tapo-nvr/gate/*.sh ~/tapo-nvr/termux/*'
T 'install -m 755 ~/tapo-nvr/termux/boot-tapo.sh ~/.termux/boot/boot-tapo.sh'

# restart (stop the launcher by PID; it stops its own children)
T 'for p in $(pgrep -f "home/.termux/boot/boot-tapo.sh"); do [ "$p" != "$$" ] && kill -TERM "$p"; done'
T 'setsid nohup ~/.termux/boot/boot-tapo.sh >/dev/null 2>&1 </dev/null & disown'
```

Gotcha: `pkill -f boot-tapo.sh` sent through ssh also matches the remote `bash -c`
whose command line contains that pattern, and kills your own session. Kill by PID
and skip `$$`, as above.

After a deploy, check `tail ~/tapo/boot.log ~/tapo/tapo.log`, confirm two ffmpeg
processes are running (detector and segmenter), and walk past the camera to see a
full trigger → gate → upload cycle.

## Testing against the real camera from the Mac

`~/.tapo_env` on the Mac holds the same variables. To exercise the recorder without
uploading anything, put stub `rclone` and `timeout` (from `gtimeout`) scripts first on
`PATH` and point `WORKDIR` at a scratch directory.

## Known limits

- Vehicles have not yet been validated on real footage. Night (IR) footage has not
  been checked against the gate either.
- A person who stands still for most of a clip becomes part of the median background.
- After a reboot nothing runs until the tablet is unlocked once (Android file-based
  encryption).
