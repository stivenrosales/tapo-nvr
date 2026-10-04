#!/data/data/com.termux/files/usr/bin/bash
# GATE_CMD entry point. Termux:Boot starts processes without termux-exec, so
# "#!/usr/bin/env python3" in detect.py cannot be resolved there; this wrapper
# uses Termux's absolute bash path and calls python explicitly.
exec "${PYTHON:-python3}" "$(dirname "$0")/detect.py" "$@"
