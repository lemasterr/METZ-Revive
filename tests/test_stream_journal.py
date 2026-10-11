import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("stream_journal", Path(__file__).parents[1] / "scripts/analyze_stream_journal.py")
journal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journal)


class StreamJournalAnalysisCheck(unittest.TestCase):
    def test_stage_matching_zero_samples_and_incomplete_tail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            summary = root / "session-fixture-summary.json"
            summary.write_text(json.dumps({"target_fps": 30, "ended": True, "last": {"raw_replaced": 800}}))
            lines = [
                {"event": "start", "segment": 0},
                {"event": "sample", "capture_fps": 60, "admission_fps": 15, "interval_s": 1,
                 "peer_pin": "must-never-appear", "t_ms": 1000},
                {"event": "sample", "capture_fps": 0, "admission_fps": 0, "interval_s": 1},
                {"event": "sample", "capture_fps": 15, "admission_fps": 10, "interval_s": 2},
                {"event": "tvFrame", "stage": 0, "pts_us": 100, "receiver_elapsed_us": 10_000},
                {"event": "tvFrame", "stage": 1, "pts_us": 100, "receiver_elapsed_us": 20_000},
                {"event": "tvFrame", "stage": 0, "pts_us": 200, "receiver_elapsed_us": 30_000},
                {"event": "tvFrame", "stage": 1, "pts_us": 200, "receiver_elapsed_us": 60_000},
            ]
            (root / "session-fixture-0.jsonl").write_text("\n".join(json.dumps(line) for line in lines) + '\n{"truncated":')
            result = journal.analyze(summary)
            self.assertEqual(result["high_capture_samples"], 1)
            self.assertEqual(result["rates"]["admission_fps"]["mean"], 8.75)
            self.assertEqual(result["rates"]["admission_fps"]["min"], 0)
            self.assertEqual(result["high_capture_rates"]["admission_fps"]["mean"], 15)
            self.assertEqual(result["worst_seconds"][0]["admission_fps"], 0)
            self.assertTrue(any(sample["capture_fps"] == 15 for sample in result["worst_seconds"]))
            self.assertEqual(result["timings"]["decode_ms"]["max"], 30)
            self.assertEqual(result["timings"]["tv_output_interval_ms"]["max"], 40)
            self.assertIsNone(result["rates"]["surface_fps"])
            self.assertEqual(result["damaged_lines"], 1)
            self.assertEqual(result["totals"]["raw_replaced"], 800)
            self.assertNotIn("must-never-appear", json.dumps(result))

    def test_absent_decoder_details_are_unknown(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "session-fixture-summary.json"
            path.write_text('{"target_fps":60,"ended":false,"last":{}}')
            result = journal.analyze(path)
            self.assertFalse(result["ended"])
            self.assertEqual(result["samples_retained"], 0)
            self.assertIsNone(result["timings"]["decode_ms"])

    def test_corrupt_summary_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "session-fixture-summary.json"
            path.write_text("[]")
            with self.assertRaises(ValueError):
                journal.analyze(path)

    def test_paced_stream_does_not_report_repeats_as_new_capture(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            summary = root / "session-fixture-summary.json"
            summary.write_text(json.dumps({"target_fps": 60, "last": {
                "capture_frames": 25, "fresh_encoded": 25, "repeated_encoded": 35, "pacing_skipped": 2}}))
            lines = [{"event": "start", "segment": 0},
                     {"event": "sample", "capture_fps": 25, "admission_fps": 60, "interval_s": 1},
                     {"event": "pace", "late_ms": 1.5}, {"event": "pace", "late_ms": 5},
                     {"event": "capture", "delivery_ms": 3.25}]
            (root / "session-fixture-0.jsonl").write_text("\n".join(json.dumps(line) for line in lines))
            result = journal.analyze(summary)
            self.assertEqual(result["rates"]["capture_fps"]["mean"], 25)
            self.assertEqual(result["totals"]["fresh_encoded"], 25)
            self.assertEqual(result["totals"]["repeated_encoded"], 35)
            self.assertEqual(result["totals"]["pacing_skipped"], 2)
            self.assertEqual(result["timings"]["pace_late_ms"]["max"], 5)
            self.assertEqual(result["timings"]["capture_delivery_ms"]["p95"], 3.25)


if __name__ == "__main__":
    unittest.main()
