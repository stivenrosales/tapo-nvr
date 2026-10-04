"""Tests for gate/detect.py. Run: python -m unittest (from the repo root)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "gate"))
import detect  # noqa: E402

MODEL = ROOT / "gate" / "models" / "yolo11n.onnx"
REAL_CLIP = os.environ.get("GATE_TEST_CLIP", "")
SIZE = 640


def yolo_tensor(dets, n=8400):
    """Build a raw [1, 84, n] tensor. dets: (cx, cy, w, h, cls, score)."""
    out = np.zeros((1, 84, n), dtype=np.float32)
    for i, (cx, cy, w, h, cls, score) in enumerate(dets):
        out[0, 0:4, i] = (cx, cy, w, h)
        out[0, 4 + cls, i] = score
    return out


class DecodeNmsTest(unittest.TestCase):
    def test_decode_filters_by_conf_and_converts_to_xyxy(self):
        t = yolo_tensor([(100, 100, 40, 20, 0, 0.9), (300, 300, 10, 10, 2, 0.2)])
        boxes, scores, cls = detect.decode(t, conf=0.4)
        self.assertEqual(len(boxes), 1)
        np.testing.assert_allclose(boxes[0], [80, 90, 120, 110])
        self.assertAlmostEqual(float(scores[0]), 0.9, places=5)
        self.assertEqual(int(cls[0]), 0)

    def test_decode_picks_best_class(self):
        t = yolo_tensor([(50, 50, 20, 20, 2, 0.7)])
        t[0, 4 + 0, 0] = 0.5
        _, scores, cls = detect.decode(t, conf=0.4)
        self.assertEqual(int(cls[0]), 2)
        self.assertAlmostEqual(float(scores[0]), 0.7, places=5)

    def test_decode_empty(self):
        boxes, scores, cls = detect.decode(yolo_tensor([]), conf=0.4)
        self.assertEqual((len(boxes), len(scores), len(cls)), (0, 0, 0))

    def test_nms_suppresses_overlap_keeps_best_and_distinct(self):
        boxes = np.array([[0, 0, 100, 100], [5, 5, 105, 105], [300, 300, 400, 400]], dtype=np.float32)
        scores = np.array([0.8, 0.9, 0.6], dtype=np.float32)
        keep = detect.nms(boxes, scores, iou_thr=0.45)
        self.assertEqual(sorted(keep), [1, 2])

    def test_nms_is_class_aware(self):
        boxes = np.array([[0, 0, 100, 100], [0, 0, 100, 100]], dtype=np.float32)
        scores = np.array([0.8, 0.9], dtype=np.float32)
        cls = np.array([0, 2])
        self.assertEqual(sorted(detect.nms(boxes, scores, 0.45, cls)), [0, 1])

    def test_nms_empty(self):
        self.assertEqual(len(detect.nms(np.zeros((0, 4)), np.zeros(0), 0.45)), 0)


class MotionTest(unittest.TestCase):
    def test_identical_frames_have_no_motion(self):
        g = np.full((SIZE, SIZE), 100, dtype=np.uint8)
        masks = detect.motion_masks([g, g.copy(), g.copy()], thresh=25)
        self.assertFalse(any(m.any() for m in masks))

    def test_moving_block_is_marked_only_where_it_differs(self):
        frames = []
        for x in (50, 300, 500):
            g = np.full((SIZE, SIZE), 100, dtype=np.uint8)
            g[200:280, x:x + 80] = 220
            frames.append(g)
        masks = detect.motion_masks(frames, thresh=25)
        self.assertTrue(masks[0][200:280, 50:130].mean() > 0.9)
        self.assertFalse(masks[0][200:280, 300:380].any())

    def test_specks_are_dropped(self):
        frames = [np.full((SIZE, SIZE), 100, dtype=np.uint8) for _ in range(3)]
        frames[0][10, 10] = 255
        self.assertFalse(detect.motion_masks(frames, thresh=25)[0].any())

    def test_motion_fraction(self):
        m = np.zeros((SIZE, SIZE), dtype=bool)
        m[0:50, 0:100] = True
        self.assertAlmostEqual(detect.motion_fraction(m, (0, 0, 100, 100)), 0.5)
        self.assertEqual(detect.motion_fraction(m, (200, 200, 300, 300)), 0.0)

    def test_motion_fraction_clips_and_handles_degenerate_boxes(self):
        m = np.ones((SIZE, SIZE), dtype=bool)
        self.assertEqual(detect.motion_fraction(m, (-50, -50, 50, 50)), 1.0)
        self.assertEqual(detect.motion_fraction(m, (10, 10, 10, 10)), 0.0)


def fake_detector(box_for_frame, cls=2, score=0.9):
    """Detector stub: returns box_for_frame(i) (or None) for the i-th call."""
    calls = {"i": -1}

    def run(_rgb):
        calls["i"] += 1
        b = box_for_frame(calls["i"])
        if b is None:
            return np.zeros((0, 4)), np.zeros(0), np.zeros(0, dtype=int)
        return (np.array([b], dtype=np.float32), np.array([score], dtype=np.float32),
                np.array([cls]))
    return run


def scene(n, x_for_frame):
    """Gray-background frames with a bright 80x80 object at x_for_frame(i)."""
    out = []
    for i in range(n):
        g = np.full((SIZE, SIZE), 100, dtype=np.uint8)
        x = x_for_frame(i)
        g[200:280, x:x + 80] = 220
        out.append(g)
    return out


class QualifyTest(unittest.TestCase):
    cfg = detect.Config(classes=frozenset({"person", "car"}), conf=0.4, motion_frac=0.15,
                        diff_thresh=25, frames=8, threads=1, model="")

    def test_static_object_does_not_qualify(self):
        grays = scene(8, lambda i: 300)
        det = fake_detector(lambda i: (300, 200, 380, 280))
        self.assertEqual(detect.evaluate(grays, [None] * 8, det, self.cfg), [])

    def test_moving_object_qualifies(self):
        xs = [20, 100, 180, 260, 340, 420, 500, 540]
        grays = scene(8, lambda i: xs[i])
        det = fake_detector(lambda i: (xs[i], 200, xs[i] + 80, 280))
        q = detect.evaluate(grays, [None] * 8, det, self.cfg)
        self.assertTrue(q)
        self.assertEqual(q[0]["class"], "car")
        self.assertGreaterEqual(q[0]["motion_frac"], 0.15)
        self.assertIn("frame", q[0])

    def test_disallowed_class_does_not_qualify(self):
        xs = [20, 100, 180, 260, 340, 420, 500, 540]
        grays = scene(8, lambda i: xs[i])
        det = fake_detector(lambda i: (xs[i], 200, xs[i] + 80, 280), cls=16)  # dog
        self.assertEqual(detect.evaluate(grays, [None] * 8, det, self.cfg), [])

    def test_low_confidence_does_not_qualify(self):
        xs = [20, 100, 180, 260, 340, 420, 500, 540]
        grays = scene(8, lambda i: xs[i])
        det = fake_detector(lambda i: (xs[i], 200, xs[i] + 80, 280), score=0.3)
        self.assertEqual(detect.evaluate(grays, [None] * 8, det, self.cfg), [])

    def test_class_names(self):
        self.assertEqual(detect.COCO[0], "person")
        self.assertEqual(detect.COCO[2], "car")
        self.assertEqual(detect.COCO[16], "dog")
        self.assertEqual(len(detect.COCO), 80)


class ConfigTest(unittest.TestCase):
    def test_defaults(self):
        c = detect.Config.from_env({})
        self.assertEqual(c.frames, 8)
        self.assertEqual(c.threads, 4)
        self.assertEqual(c.conf, 0.4)
        self.assertEqual(c.motion_frac, 0.15)
        self.assertEqual(c.classes, frozenset(
            {"person", "bicycle", "car", "motorcycle", "bus", "truck"}))
        self.assertTrue(c.model.endswith(os.path.join("gate", "models", "yolo11n.onnx")))

    def test_env_overrides(self):
        c = detect.Config.from_env({"GATE_CLASSES": "person, dog", "GATE_CONF": "0.5",
                                    "GATE_FRAMES": "5", "GATE_MODEL": "/x.onnx"})
        self.assertEqual(c.classes, frozenset({"person", "dog"}))
        self.assertEqual((c.conf, c.frames, c.model), (0.5, 5, "/x.onnx"))

    def test_unknown_class_is_an_error(self):
        with self.assertRaises(ValueError):
            detect.Config.from_env({"GATE_CLASSES": "unicorn"})


class ExitCodeTest(unittest.TestCase):
    def run_gate(self, args, env):
        e = {k: v for k, v in os.environ.items() if not k.startswith("GATE_")}
        e.update(env)
        return subprocess.run([sys.executable, str(ROOT / "gate" / "detect.py"), *args],
                              capture_output=True, text=True, env=e)

    def test_missing_model_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            clip = Path(d) / "c.mp4"
            clip.write_bytes(b"x")
            r = self.run_gate([str(clip)], {"GATE_MODEL": str(Path(d) / "nope.onnx")})
        self.assertEqual(r.returncode, 2)
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1])["decision"], "error")

    def test_missing_clip_exits_2(self):
        r = self.run_gate(["/nonexistent/clip.mp4"], {})
        self.assertEqual(r.returncode, 2)

    def test_no_args_exits_2(self):
        self.assertEqual(self.run_gate([], {}).returncode, 2)

    def test_bad_env_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            clip = Path(d) / "c.mp4"
            clip.write_bytes(b"x")
            r = self.run_gate([str(clip)], {"GATE_CONF": "abc"})
        self.assertEqual(r.returncode, 2)

    @unittest.skipUnless(MODEL.exists(), "model not installed")
    def test_unreadable_clip_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            clip = Path(d) / "c.mp4"
            clip.write_bytes(b"this is not a video")
            r = self.run_gate([str(clip)], {})
        self.assertEqual(r.returncode, 2)
        self.assertEqual(json.loads(r.stdout.strip().splitlines()[-1])["decision"], "error")


@unittest.skipUnless(MODEL.exists(),
                     "model not installed")
class IntegrationTest(unittest.TestCase):
    @unittest.skipUnless(REAL_CLIP and Path(REAL_CLIP).exists(), "set GATE_TEST_CLIP")
    def test_real_clip_emits_json_and_valid_exit(self):
        r = subprocess.run([sys.executable, str(ROOT / "gate" / "detect.py"), REAL_CLIP],
                           capture_output=True, text=True)
        self.assertIn(r.returncode, (0, 1))
        j = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(j["decision"], "upload" if r.returncode == 0 else "discard")
        self.assertIn("elapsed_ms", j)


if __name__ == "__main__":
    unittest.main()
