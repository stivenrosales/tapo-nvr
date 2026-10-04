#!/usr/bin/env python3
"""Clip gate for tapo-nvr: upload a clip only if a person/vehicle MOVES in it.

Contract with tapo-watch.sh (GATE_CMD):  detect.py CLIP.mp4
  exit 0 = upload, 1 = discard, 2 = error (the watcher then holds the clip).
One JSON line summarizing the decision goes to stdout.

Depends only on python3 stdlib + numpy + onnxruntime + the ffmpeg binary.
"""
import json
import os
import subprocess
import sys
import time
import warnings
from dataclasses import dataclass
from pathlib import Path

import numpy as np

# onnxruntime warns at import time on Android/Termux; the platform works fine.
# Must be registered before onnxruntime is imported (see make_detector).
warnings.filterwarnings("ignore", message=r"Unsupported platform \(android\)",
                        category=UserWarning)

SIZE = 640
POOL = 8  # block size used to drop motion specks
PAD_GRAY = "0x727272"
SAMPLE_FPS = 2  # decode rate; N frames are then picked evenly from these
MIN_FRAMES = 3  # a median background needs at least this many frames
DEFAULT_CLASSES = "person,bicycle,car,motorcycle,bus,truck"

COCO = (
    "person bicycle car motorcycle airplane bus train truck boat traffic_light "
    "fire_hydrant stop_sign parking_meter bench bird cat dog horse sheep cow "
    "elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee "
    "skis snowboard sports_ball kite baseball_bat baseball_glove skateboard "
    "surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl banana "
    "apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch "
    "potted_plant bed dining_table toilet tv laptop mouse remote keyboard "
    "cell_phone microwave oven toaster sink refrigerator book clock vase "
    "scissors teddy_bear hair_drier toothbrush"
).split()


@dataclass(frozen=True)
class Config:
    classes: frozenset
    conf: float
    motion_frac: float
    diff_thresh: int
    frames: int
    threads: int
    model: str

    @classmethod
    def from_env(cls, env):
        names = frozenset(c.strip() for c in
                          env.get("GATE_CLASSES", DEFAULT_CLASSES).split(",") if c.strip())
        unknown = names - set(COCO)
        if unknown:
            raise ValueError("unknown COCO class(es): " + ", ".join(sorted(unknown)))
        default_model = Path(__file__).resolve().parent / "models" / "yolo11n.onnx"
        return cls(
            classes=names,
            conf=float(env.get("GATE_CONF", "0.4")),
            motion_frac=float(env.get("GATE_MOTION_FRAC", "0.15")),
            diff_thresh=int(env.get("GATE_DIFF_THRESH", "25")),
            frames=int(env.get("GATE_FRAMES", "8")),
            threads=int(env.get("GATE_THREADS", "4")),
            model=env.get("GATE_MODEL", str(default_model)),
        )


# --- YOLO output decoding ----------------------------------------------------
def decode(output, conf):
    """Raw YOLOv8/11 output [1, 84, N] -> (xyxy boxes, scores, class ids), score >= conf."""
    p = np.asarray(output)[0].T  # [N, 84]
    cls_scores = p[:, 4:]
    ids = cls_scores.argmax(axis=1)
    scores = cls_scores[np.arange(len(p)), ids]
    keep = scores >= conf
    p, ids, scores = p[keep], ids[keep], scores[keep]
    cx, cy, w, h = p[:, 0], p[:, 1], p[:, 2], p[:, 3]
    boxes = np.stack([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], axis=1)
    return boxes.astype(np.float32), scores.astype(np.float32), ids


def nms(boxes, scores, iou_thr, classes=None):
    """Greedy NMS (class-aware when `classes` is given). Returns kept indices."""
    boxes = np.asarray(boxes, dtype=np.float32)
    if len(boxes) == 0:
        return []
    if classes is not None:
        boxes = boxes + (np.asarray(classes, dtype=np.float32) * 4096.0)[:, None]
    x1, y1, x2, y2 = boxes.T
    areas = (x2 - x1) * (y2 - y1)
    order = np.argsort(-np.asarray(scores))
    keep = []
    while len(order):
        i = int(order[0])
        keep.append(i)
        rest = order[1:]
        iw = np.maximum(0, np.minimum(x2[i], x2[rest]) - np.maximum(x1[i], x1[rest]))
        ih = np.maximum(0, np.minimum(y2[i], y2[rest]) - np.maximum(y1[i], y1[rest]))
        inter = iw * ih
        iou = inter / np.maximum(areas[i] + areas[rest] - inter, 1e-9)
        order = rest[iou <= iou_thr]
    return keep


# --- motion ------------------------------------------------------------------
def motion_masks(grays, thresh):
    """Per-frame boolean motion masks vs. the per-pixel median of all frames."""
    stack = np.stack(grays).astype(np.int16)
    bg = np.median(stack, axis=0)
    masks = []
    for g in stack:
        m = (np.abs(g - bg) > thresh).astype(np.float32)
        h, w = m.shape
        hh, ww = h - h % POOL, w - w % POOL
        pooled = m[:hh, :ww].reshape(hh // POOL, POOL, ww // POOL, POOL).mean(axis=(1, 3))
        blocks = pooled >= 0.25  # drop specks: a block needs >= 25% changed pixels
        out = np.zeros((h, w), dtype=bool)
        out[:hh, :ww] = np.repeat(np.repeat(blocks, POOL, axis=0), POOL, axis=1)
        masks.append(out)
    return masks


def motion_fraction(mask, box):
    """Fraction of motion pixels inside box (x1, y1, x2, y2), clipped to the mask."""
    h, w = mask.shape
    x1, y1 = max(0, int(box[0])), max(0, int(box[1]))
    x2, y2 = min(w, int(round(box[2]))), min(h, int(round(box[3])))
    if x2 <= x1 or y2 <= y1:
        return 0.0
    return float(mask[y1:y2, x1:x2].mean())


def evaluate(grays, rgbs, detector, cfg):
    """Return the qualifying detections (allowed class, conf, overlapping motion)."""
    masks = motion_masks(grays, cfg.diff_thresh)
    found = []
    for i, (mask, rgb) in enumerate(zip(masks, rgbs)):
        boxes, scores, ids = detector(rgb)
        for box, score, cid in zip(boxes, scores, ids):
            name = COCO[int(cid)]
            if name not in cfg.classes or score < cfg.conf:
                continue
            frac = motion_fraction(mask, box)
            if frac >= cfg.motion_frac:
                found.append({"frame": i, "class": name, "conf": round(float(score), 3),
                              "motion_frac": round(frac, 3)})
    return found


# --- I/O ---------------------------------------------------------------------
def read_frames(clip, n):
    """Decode ~SAMPLE_FPS frames/s via ffmpeg, letterboxed to 640x640 RGB; pick n evenly."""
    vf = (f"fps={SAMPLE_FPS},scale={SIZE}:{SIZE}:force_original_aspect_ratio=decrease,"
          f"pad={SIZE}:{SIZE}:(ow-iw)/2:(oh-ih)/2:color={PAD_GRAY}")
    p = subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", clip, "-an",
                        "-vf", vf, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg failed: " + p.stderr.decode(errors="replace")[-200:])
    size = SIZE * SIZE * 3
    count = len(p.stdout) // size
    if count < MIN_FRAMES:
        raise RuntimeError(f"only {count} decodable frame(s), need {MIN_FRAMES}")
    arr = np.frombuffer(p.stdout, dtype=np.uint8, count=count * size).reshape(count, SIZE, SIZE, 3)
    idx = np.unique(np.linspace(0, count - 1, min(n, count)).round().astype(int))
    return [arr[i] for i in idx]


def to_gray(rgb):
    return (rgb.astype(np.float32) @ np.array([0.299, 0.587, 0.114], np.float32)).astype(np.uint8)


def make_detector(cfg):
    if not os.path.isfile(cfg.model):
        raise FileNotFoundError("model not found: " + cfg.model)
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = cfg.threads
    sess = ort.InferenceSession(cfg.model, so, providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name

    def run(rgb):
        x = (rgb.astype(np.float32) / 255.0).transpose(2, 0, 1)[None]
        out = sess.run(None, {name: np.ascontiguousarray(x)})[0]
        boxes, scores, ids = decode(out, cfg.conf)
        keep = nms(boxes, scores, 0.45, ids)
        return boxes[keep], scores[keep], ids[keep]
    return run


def main(argv, env=None):
    t0 = time.monotonic()
    report = {"clip": Path(argv[1]).name if len(argv) > 1 else None}
    try:
        if len(argv) != 2:
            raise ValueError("usage: detect.py CLIP.mp4")
        cfg = Config.from_env(os.environ if env is None else env)
        if not os.path.isfile(argv[1]):
            raise FileNotFoundError("clip not found: " + argv[1])
        detector = make_detector(cfg)
        rgbs = read_frames(argv[1], cfg.frames)
        found = evaluate([to_gray(f) for f in rgbs], rgbs, detector, cfg)
        report.update(frames=len(rgbs), detections=found,
                      decision="upload" if found else "discard")
        code = 0 if found else 1
    except Exception as e:  # any failure is exit 2, never 0/1
        print(f"gate error: {e}", file=sys.stderr)
        report.update(decision="error", error=str(e))
        code = 2
    report["elapsed_ms"] = int((time.monotonic() - t0) * 1000)
    print(json.dumps(report, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
