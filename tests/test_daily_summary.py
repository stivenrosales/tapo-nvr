"""Tests for termux/daily-summary.py. Run: python -m unittest (from the repo root)."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "termux" / "daily-summary.py"
FIXTURE = ROOT / "tests" / "fixtures" / "tapo.log"

spec = importlib.util.spec_from_file_location("daily_summary", SCRIPT)
ds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ds)

END = "2026-10-04 20:55:00"


def summarize(path=FIXTURE, end=END):
    return ds.summarize(Path(path), ds.parse_local(end), 24)


class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.s = summarize()

    def test_window_and_date(self):
        self.assertEqual(self.s["date"], "2026-10-04")
        self.assertEqual(self.s["window_start"], "2026-10-03T20:55:00-05:00")
        self.assertEqual(self.s["window_end"], "2026-10-04T20:55:00-05:00")

    def test_counts(self):
        # events: 20:55:00 (start, inclusive) .. 11:51:02; the bogus date and the line AT end do not count
        self.assertEqual(self.s["events"], 5)
        self.assertEqual(self.s["uploaded"], 3)
        self.assertEqual(self.s["discarded"], 1)
        self.assertEqual(self.s["held"], 1)
        self.assertEqual(self.s["gate_errors"], 1)
        self.assertEqual(self.s["restarts"], 1)

    def test_clips_chronological_uploaded_only_with_labels(self):
        c = self.s["clips"]
        self.assertEqual([x["file"] for x in c], [
            "mov_2026-10-03_20-55-00.mp4",
            "mov_2026-10-03_21-10-05.mp4",
            "mov_2026-10-04_11-51-02.mp4"])
        self.assertEqual(c[1], {
            "time": "21:10", "file": "mov_2026-10-03_21-10-05.mp4", "folder": "2026-10",
            "size": "6.3M",
            "labels": [{"class": "person", "conf": 0.842}, {"class": "car", "conf": 0.7}]})
        self.assertEqual(c[0]["labels"], [{"class": "car", "conf": 0.55}])

    def test_incidents(self):
        inc = self.s["incidents"]
        self.assertEqual([i["time"] for i in inc], ["02:00", "02:10", "03:00"])
        self.assertIn("monitor cayo", inc[0]["msg"])
        self.assertIn("segmentador cayo", inc[1]["msg"])
        self.assertIn("ERROR grabando", inc[2]["msg"])
        self.assertEqual(self.s["incidents_total"], 3)

    def test_out_of_window_and_garbage_ignored(self):
        files = [x["file"] for x in self.s["clips"]]
        self.assertNotIn("mov_2026-10-03_20-30-10.mp4", files)
        self.assertNotIn("mov_2026-08-17_09-12-40.mp4", files)
        self.assertNotIn("mov_2026-10-04_20-55-00.mp4", files)


class RobustnessTest(unittest.TestCase):
    def write(self, data: bytes):
        d = tempfile.mkdtemp()
        p = Path(d) / "tapo.log"
        p.write_bytes(data)
        return p

    def test_empty_log(self):
        s = summarize(self.write(b""))
        self.assertEqual((s["events"], s["uploaded"], s["clips"], s["incidents"]), (0, 0, [], []))

    def test_binary_garbage_does_not_crash(self):
        s = summarize(self.write(b"\xff\xfe\x00\x01\n2026-10-04 10:00:00 | MOVIMIENTO ->\n\x80\x81"))
        self.assertEqual(s["events"], 1)

    def test_incidents_capped_at_20(self):
        lines = "".join(f"2026-10-04 10:{m:02d}:00 | ERROR boom {m}\n" for m in range(30))
        s = summarize(self.write(lines.encode()))
        self.assertEqual(len(s["incidents"]), 20)
        self.assertEqual(s["incidents_total"], 30)

    def test_uploaded_without_gate_json_has_empty_labels(self):
        s = summarize(self.write(
            b"2026-10-04 10:00:46 | subido: mov_2026-10-04_10-00-05.mp4 (3.2M)\n"))
        self.assertEqual(s["clips"][0]["labels"], [])

    def test_missing_log_gives_empty_summary(self):
        s = summarize(Path(tempfile.mkdtemp()) / "nope.log")
        self.assertEqual(s["events"], 0)


class CliTest(unittest.TestCase):
    def test_writes_json_to_out(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "sub" / "x.json"
            r = subprocess.run([sys.executable, str(SCRIPT), str(FIXTURE), "--out", str(out),
                                "--end", END], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(json.loads(out.read_text())["uploaded"], 3)

    def test_default_end_is_now(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "x.json"
            r = subprocess.run([sys.executable, str(SCRIPT), str(FIXTURE), "--out", str(out)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            j = json.loads(out.read_text())
            self.assertTrue(j["window_end"].endswith("-05:00"))
            self.assertEqual(j["date"], datetime.now(ds.LIMA).strftime("%Y-%m-%d"))


if __name__ == "__main__":
    unittest.main()
