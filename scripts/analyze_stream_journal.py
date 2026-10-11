#!/usr/bin/env python3
"""Read numeric Manager traces locally; no device/network/UI actions or video files."""
import argparse
import json
import math
from pathlib import Path


DEFAULT = Path.home() / "Library/Application Support/METZ/StreamSessions.noindex"


def percentile(values, fraction=0.95):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)]


def number(record, key):
    if not isinstance(record, dict):
        return None
    value = record.get(key)
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None


def analyze(summary_path):
    summary = json.loads(summary_path.read_text())
    if not isinstance(summary, dict):
        raise ValueError("Invalid journal summary")
    prefix = summary_path.name.removesuffix("-summary.json")
    segments = []
    damaged_lines = 0
    for path in summary_path.parent.glob(prefix + "-?.jsonl"):
        if path.is_symlink() or path.stat().st_size > 2 * 1024 * 1024:
            continue
        with path.open() as stream:
            first = stream.readline(8192)
        try:
            header = json.loads(first)
            segment = int(header["segment"])
        except (ValueError, KeyError, TypeError):
            continue
        segments.append((segment, path))
    samples, raw_wait, encode, send_wait, ack, decode, pace_late, capture_delivery = [], [], [], [], [], [], [], []
    stage_times = {0: [], 1: [], 2: []}
    input_times = {}
    trace_omitted = 0
    for _, path in sorted(segments):
        with path.open() as stream:
            for line in stream:
                if len(line) > 8192:
                    damaged_lines += 1
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, TypeError):
                    damaged_lines += 1
                    continue
                if not isinstance(record, dict):
                    damaged_lines += 1
                    continue
                event = record.get("event")
                if event == "sample":
                    samples.append(record)
                for kind, key, values in [("encode", "raw_wait_ms", raw_wait), ("encoded", "encode_ms", encode),
                                          ("send", "wait_ms", send_wait), ("admission", "ack_ms", ack),
                                          ("pace", "late_ms", pace_late), ("capture", "delivery_ms", capture_delivery)]:
                    value = number(record, key)
                    if event == kind and value is not None:
                        values.append(value)
                if event == "tvReport":
                    trace_omitted = max(trace_omitted, number(record, "trace_omitted") or 0)
                if event == "tvFrame":
                    stage, pts, timestamp = [number(record, key) for key in ("stage", "pts_us", "receiver_elapsed_us")]
                    if stage not in stage_times or pts is None or timestamp is None:
                        continue
                    stage_times[stage].append(timestamp)
                    if stage == 0:
                        input_times[pts] = timestamp
                        if len(input_times) > 512:
                            del input_times[next(iter(input_times))]
                    elif stage == 1:
                        submitted = input_times.pop(pts, None)
                        if submitted is not None and timestamp >= submitted:
                            decode.append((timestamp - submitted) / 1000)
    target = number(summary, "target_fps") or 30
    # Capture throughput cannot tell a static desktop from a stalled capture.
    # Keep every sample in the main report, including zeros and severe dips.
    high_capture = [sample for sample in samples if (number(sample, "capture_fps") or 0) >= max(10, target * 0.8)]
    def rates_for(records):
        result = {}
        for key in ("capture_fps", "encoded_fps", "admission_fps", "output_fps", "surface_fps", "video_mbps"):
            pairs = [(number(sample, key), number(sample, "interval_s") or 1) for sample in records]
            pairs = [(value, interval) for value, interval in pairs if value is not None and interval > 0]
            result[key] = {"mean": sum(value * interval for value, interval in pairs) / sum(interval for _, interval in pairs),
                           "min": min(value for value, _ in pairs), "max": max(value for value, _ in pairs)} if pairs else None
        return result
    timings = {}
    for key, values in [("raw_wait_ms", raw_wait), ("encode_ms", encode), ("send_wait_ms", send_wait),
                        ("ack_ms", ack), ("decode_ms", decode), ("pace_late_ms", pace_late), ("capture_delivery_ms", capture_delivery)]:
        timings[key] = {"p95": percentile(values), "max": max(values), "count": len(values)} if values else None
    for stage, name in [(0, "tv_input_interval_ms"), (1, "tv_output_interval_ms"), (2, "surface_interval_ms")]:
        ordered = sorted(stage_times[stage])
        intervals = [(b - a) / 1000 for a, b in zip(ordered, ordered[1:])]
        timings[name] = {"p95": percentile(intervals), "max": max(intervals), "count": len(intervals)} if intervals else None
    worst = sorted(samples, key=lambda item: number(item, "admission_fps") or 0)[:5]
    # Output whitelist: never echo arbitrary strings, paths, keys or error messages.
    return {
        "started_unix_s": number(summary, "started_unix_s"), "width": number(summary, "width"),
        "height": number(summary, "height"), "target_fps": target, "audio": number(summary, "audio"),
        "ended": summary.get("ended") is True, "samples_retained": len(samples), "high_capture_samples": len(high_capture),
        "history_rotations": number(summary, "history_rotations"), "omitted_events": number(summary, "omitted_events"),
        "tv_trace_omitted": trace_omitted, "damaged_lines": damaged_lines,
        "rates": rates_for(samples), "high_capture_rates": rates_for(high_capture), "timings": timings,
        "totals": {key: number(summary.get("last", {}), key) for key in
                   ("capture_frames", "selected_frames", "selection_skipped", "raw_replaced", "codec_dropped", "admitted_frames",
                    "fresh_selected", "repeated_selected", "fresh_encoded", "repeated_encoded", "pacing_skipped")},
        "worst_seconds": [{key: number(sample, key) for key in
                           ("t_ms", "capture_fps", "encoded_fps", "admission_fps", "output_fps", "video_mbps", "tv_report_age_s",
                            "capture_complete", "capture_idle", "capture_other",
                            "raw_queue_p95_ms", "encode_p95_ms", "ack_p95_ms")} for sample in worst],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=DEFAULT)
    parser.add_argument("--last", type=int, default=3)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    paths = sorted((path for path in args.directory.glob("session-*-summary.json") if not path.is_symlink()),
                   key=lambda path: path.stat().st_mtime, reverse=True)[:max(1, min(8, args.last))]
    reports = []
    for path in reversed(paths):
        if path.stat().st_size > 8192:
            continue
        try:
            reports.append(analyze(path))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if args.json:
        print(json.dumps(reports, ensure_ascii=False, indent=2, allow_nan=False))
        return
    if not reports:
        print("Журналов пока нет. Запустите экран в Manager с автоматической записью.")
    for report in reports:
        print(f"{report['width']}×{report['height']} / {report['target_fps']} FPS; звук={bool(report['audio'])}; завершён={report['ended']}")
        print(f"Выборок в сохранённом участке: {report['samples_retained']}; ротаций: {report['history_rotations']}")
        for key, values in report["rates"].items():
            print(f"  {key}: {values['mean']:.1f}, min={values['min']:.1f}, max={values['max']:.1f}" if values else f"  {key}: нет данных")
        for key, values in report["timings"].items():
            if values:
                print(f"  {key}: p95={values['p95']:.1f}, max={values['max']:.1f}")
        print("  Суммарные счётчики:", json.dumps(report["totals"], ensure_ascii=False))


if __name__ == "__main__":
    main()
