#!/usr/bin/env python3
"""Daily summary of tapo.log for the last 24 h, as JSON (stdlib only).

Usage: daily-summary.py TAPO.LOG [--out FILE] [--end "YYYY-MM-DD HH:MM[:SS]"] [--hours 24]

All times are America/Lima (UTC-05:00, no DST). Window = [end - hours, end).
Never crashes on a bad line: python warnings, ffmpeg noise and old entries are
simply ignored.
"""
import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

LIMA = timezone(timedelta(hours=-5))
MAX_INCIDENTS = 20

LINE_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \| (.*)$")
CLIP_RE = re.compile(r"(mov_(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)-(\d\d)\.mp4)")
UPLOADED_RE = re.compile(r"subido: (mov_\S+\.mp4) \(([^)]*)\)")
INCIDENT_MARKERS = ("monitor cayo", "segmentador cayo", "ERROR")


def parse_local(text):
    text = text.strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(text, fmt).replace(tzinfo=LIMA)
        except ValueError:
            pass
    raise ValueError("bad time (want YYYY-MM-DD HH:MM[:SS]): " + text)


def clip_time(name):
    m = CLIP_RE.search(name or "")
    if not m:
        return None
    try:
        return datetime.strptime(f"{m.group(2)} {m.group(3)}:{m.group(4)}:{m.group(5)}",
                                 "%Y-%m-%d %H:%M:%S").replace(tzinfo=LIMA)
    except ValueError:
        return None


def gate_record(line):
    """Return the gate JSON dict if the line is one, else None."""
    if not line.startswith("{"):
        return None
    try:
        rec = json.loads(line)
    except ValueError:
        return None
    if isinstance(rec, dict) and isinstance(rec.get("clip"), str):
        return rec
    return None


def merge_labels(detections):
    best = {}
    for d in detections:
        try:
            cls, conf = str(d["class"]), float(d["conf"])
        except (KeyError, TypeError, ValueError):
            continue
        if cls not in best or conf > best[cls]:
            best[cls] = conf
    return [{"class": c, "conf": v} for c, v in sorted(best.items(), key=lambda kv: -kv[1])]


def summarize(log_path, end, hours=24):
    start = end - timedelta(hours=hours)
    out = {"date": end.strftime("%Y-%m-%d"), "window_start": start.isoformat(),
           "window_end": end.isoformat(), "events": 0, "uploaded": 0, "discarded": 0,
           "held": 0, "gate_errors": 0, "restarts": 0, "incidents": [],
           "incidents_total": 0, "clips": []}
    detections = {}   # clip name -> [detections]
    gate_err = set()  # clip names with decision == error, inside the window
    uploaded = {}     # clip name -> size (dedupe)
    try:
        lines = Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        lines = []

    for raw in lines:
        line = raw.rstrip("\r")
        rec = gate_record(line)
        if rec is not None:
            name = rec["clip"]
            dets = rec.get("detections")
            if isinstance(dets, list):
                detections.setdefault(name, []).extend(d for d in dets if isinstance(d, dict))
            t = clip_time(name)
            if rec.get("decision") == "error" and t and start <= t < end:
                gate_err.add(name)
            continue
        m = LINE_RE.match(line)
        if not m:
            continue
        try:
            ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=LIMA)
        except ValueError:
            continue
        if not (start <= ts < end):
            continue
        msg = m.group(2)
        hhmm = ts.strftime("%H:%M")
        if "MOVIMIENTO" in msg:
            out["events"] += 1
        if "vigilancia activa" in msg:
            out["restarts"] += 1
        if "descartado por filtro" in msg:
            out["discarded"] += 1
        if "retenido localmente" in msg:
            out["held"] += 1
        up = UPLOADED_RE.search(msg)
        if up and up.group(1) not in uploaded:
            uploaded[up.group(1)] = up.group(2)
        if any(k in msg for k in INCIDENT_MARKERS):
            out["incidents_total"] += 1
            if len(out["incidents"]) < MAX_INCIDENTS:
                out["incidents"].append({"time": hhmm, "msg": msg})

    out["gate_errors"] = len(gate_err)
    out["uploaded"] = len(uploaded)
    clips = []
    for name, size in uploaded.items():
        t = clip_time(name)
        if t is None:
            continue
        clips.append((t, {"time": t.strftime("%H:%M"), "file": name,
                          "folder": t.strftime("%Y-%m"), "size": size,
                          "labels": merge_labels(detections.get(name, []))}))
    out["clips"] = [c for _, c in sorted(clips, key=lambda x: x[0])]
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log")
    ap.add_argument("--out", help="write JSON here (default: stdout)")
    ap.add_argument("--end", help="window end, local time (default: now)")
    ap.add_argument("--hours", type=float, default=24)
    args = ap.parse_args(argv)
    try:
        end = parse_local(args.end) if args.end else datetime.now(LIMA)
    except ValueError as e:
        print(e, file=sys.stderr)
        return 2
    text = json.dumps(summarize(args.log, end, args.hours), ensure_ascii=False, indent=2)
    if args.out:
        p = Path(args.out)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(text + "\n", encoding="utf-8")
        tmp.replace(p)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
