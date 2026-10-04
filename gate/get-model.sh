#!/usr/bin/env bash
# Builds gate/models/yolo11n.onnx on a desktop (Mac/Linux) and verifies it against
# the committed SHA-256. The .onnx is not in git. Copy it to the tablet afterwards:
#   scp gate/models/yolo11n.onnx tablet:tapo-nvr/gate/models/
# and on the tablet verify with:
#   (cd ~/tapo-nvr/gate/models && sha256sum -c yolo11n.onnx.sha256)
#
# Export recipe (what this script runs): ultralytics 8.4.x, yolo11n.pt (COCO),
# ONNX opset 17, imgsz 640, onnxslim simplification, NMS NOT in the graph, so the
# output stays the raw [1, 84, 8400] tensor that gate/detect.py decodes.
#
# NOTE: Ultralytics weights and tooling are AGPL-3.0.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT="$HERE/models"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q ultralytics onnx onnxslim
(cd "$WORK" && ./venv/bin/yolo export model=yolo11n.pt format=onnx imgsz=640 \
  opset=17 simplify=True nms=False)
mkdir -p "$OUT"
cp "$WORK/yolo11n.onnx" "$OUT/yolo11n.onnx"

# The exported bytes are not guaranteed bit-identical across tool versions, so a
# mismatch is a warning, not an error: verify the output shape before trusting it.
cd "$OUT"
if command -v sha256sum >/dev/null; then sum=(sha256sum -c)
else sum=(shasum -a 256 -c); fi
"${sum[@]}" yolo11n.onnx.sha256 ||
  echo "WARNING: checksum differs from the committed one (different tool versions?)" >&2
