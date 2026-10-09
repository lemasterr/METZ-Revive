import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "collect_diagnostics.py"
SPEC = importlib.util.spec_from_file_location("collector", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class CaptureTests(unittest.TestCase):
    def test_output_is_bounded_for_both_streams(self):
        result = collector.capture([
            sys.executable, "-c",
            "import sys; sys.stdout.write('a' * 400000); sys.stderr.write('b' * 400000)",
        ])
        self.assertEqual(result["returncode"], 0)
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["stdout"]), collector.MAX_BYTES)
        self.assertEqual(len(result["stderr"]), collector.MAX_BYTES)

    def test_timeout_preserves_partial_evidence(self):
        result = collector.capture([
            sys.executable, "-c", "import time; print('before', flush=True); time.sleep(2)",
        ], timeout=0.3)
        self.assertTrue(result["timed_out"])
        self.assertIsNone(result["returncode"])
        self.assertIn("before", result["stdout"])
        self.assertLess(result["duration_seconds"], 1.5)


class CollectionGuards(unittest.TestCase):
    def run_main(self, root, state, label="sample", profile="audio"):
        patches = [
            patch.object(collector, "ROOT", Path(root)),
            patch.object(collector.shutil, "which", return_value="adb"),
            patch.object(sys, "argv", [str(SCRIPT), "--serial", "test-device", "--profile", profile, "--label", label]),
            patch.object(collector, "capture", return_value=state),
        ]
        with contextlib.ExitStack() as stack:
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            for item in patches[:-1]:
                stack.enter_context(item)
            mocked = stack.enter_context(patches[-1])
            self.capture_mock = mocked
            collector.main()
            return mocked

    def test_unauthorized_target_stops_before_collecting(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(SystemExit):
                self.run_main(folder, {"returncode": 1, "stdout": "unauthorized"})
            self.assertEqual(self.capture_mock.call_count, 1)
            self.assertFalse((Path(folder) / "local").exists())

    def test_existing_snapshot_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "local" / "diagnostics" / "sample.json"
            destination.parent.mkdir(parents=True)
            destination.write_text("original", encoding="utf-8")
            with self.assertRaises(SystemExit):
                self.run_main(folder, {"returncode": 0, "stdout": "device"})
            self.assertEqual(destination.read_text(encoding="utf-8"), "original")

    def test_snapshot_is_private_and_shell_target_is_explicit(self):
        with tempfile.TemporaryDirectory() as folder:
            state = {"returncode": 0, "stdout": "device", "timed_out": False, "truncated": False}
            old_umask = collector.os.umask(0o077)
            try:
                mocked = self.run_main(folder, state)
            finally:
                collector.os.umask(old_umask)
            destination = Path(folder) / "local" / "diagnostics" / "sample.json"
            snapshot = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(len(snapshot["results"]), len(collector.AUDIO))
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            for call in mocked.call_args_list[1:]:
                self.assertEqual(call.args[0][:4], ["adb", "-s", "test-device", "shell"])

    def test_label_cannot_escape_private_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(SystemExit):
                self.run_main(folder, {"returncode": 0, "stdout": "device"}, "../public")
            self.assertFalse((Path(folder) / "local").exists())

    def test_remote_snapshot_does_not_inject_input_or_reset_frame_history(self):
        with tempfile.TemporaryDirectory() as folder:
            old_umask = collector.os.umask(0o077)
            try:
                mocked = self.run_main(folder, {
                    "returncode": 0, "stdout": "device", "timed_out": False, "truncated": False,
                }, profile="remote")
            finally:
                collector.os.umask(old_umask)
            commands = [call.args[0][4] for call in mocked.call_args_list[1:]]
            self.assertIn("dumpsys input", commands)
            self.assertTrue(any("pidof dev.vodik7.atvtoolsserver:i" in command for command in commands))
            for command in commands:
                self.assertNotRegex(command, r"(^|[;&|]\s*)(input\s|am\s|reboot\b|logcat\s+-c\b)")
                self.assertNotIn("reset", command)
            snapshot = json.loads((Path(folder) / "local/diagnostics/sample.json").read_text())
            self.assertEqual(snapshot["profile"], "remote")
            self.assertIn("input_dispatch", snapshot["results"])
            self.assertIn("home_frames", snapshot["results"])

    def test_cast_snapshot_reads_services_without_starting_a_session(self):
        with tempfile.TemporaryDirectory() as folder:
            old_umask = collector.os.umask(0o077)
            try:
                mocked = self.run_main(folder, {
                    "returncode": 0, "stdout": "device", "timed_out": False, "truncated": False,
                }, profile="cast")
            finally:
                collector.os.umask(old_umask)
            commands = [call.args[0][4] for call in mocked.call_args_list[1:]]
            self.assertIn("dumpsys activity services com.google.android.apps.mediashell", commands)
            self.assertIn("ss -ltn", commands)
            for command in commands:
                self.assertNotRegex(command, r"(^|[;&|]\s*)(input\s|am\s|reboot\b|logcat\s+-c\b|pm\s+(disable|enable)|cmd\s+.*start)")
            snapshot = json.loads((Path(folder) / "local/diagnostics/sample.json").read_text())
            self.assertEqual(snapshot["profile"], "cast")
            self.assertIn("cast_services", snapshot["results"])


if __name__ == "__main__":
    unittest.main()
