import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/maintenance_report.py"
SPEC = importlib.util.spec_from_file_location("maintenance", SCRIPT)
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)


def result(output):
    return {"returncode": 0, "timed_out": False, "truncated": False, "stdout": output, "stderr": ""}


def fixture():
    enabled = [key for key, _, _ in maintenance.PACKAGES if key != "com.google.android.tvrecommendations"]
    disabled = ["com.google.android.tvrecommendations"]
    def listing(packages):
        return "".join("package:" + key + "\n" for key in packages)
    return {"profile": "maintenance", "collection_complete": True, "expected_commands": 6,
            "started_utc": "2026-10-09T19:00:00+00:00", "results": {
                "memory": result("MemTotal: 929000 kB\nMemAvailable: 180000 kB\n"),
                "data_storage": result("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/PRIVATE 1000000 600000 400000 60% /data\n"),
                "packages_installed": result(listing(enabled + disabled)),
                "packages_enabled": result(listing(enabled)),
                "packages_disabled": result(listing(disabled)),
                "home_version": result("  versionName=0.3.0\n"),
            }}


class ReportTests(unittest.TestCase):
    def test_confirmed_facts_and_no_improvement_claim(self):
        report = maintenance.build_report(fixture())
        self.assertTrue(report["collection_complete"])
        self.assertEqual(report["memory"]["available_kib"], 180000)
        self.assertEqual(report["data_storage"]["available_kib"], 400000)
        self.assertEqual(report["home_version"], "0.3.0")
        states = {item["name"]: item["state"] for item in report["packages"]}
        self.assertEqual(states["Recommendations"], "disabled")
        self.assertEqual(states["Штатный HOME"], "enabled")
        self.assertIn("Один срез не подтверждает", maintenance.markdown(report))

    def test_failed_truncated_stderr_and_missing_commands_are_unknown(self):
        for alteration in ({"returncode": 1}, {"truncated": True}, {"timed_out": True}, {"stderr": "PRIVATE"}):
            snapshot = fixture()
            snapshot["results"]["memory"].update(alteration)
            snapshot["results"]["packages_enabled"].update(alteration)
            report = maintenance.build_report(snapshot)
            self.assertIsNone(report["memory"]["available_kib"])
            self.assertTrue(all(item["state"] == "unknown" for item in report["packages"]))
            self.assertTrue(any(item["status"] == "limited" for item in report["commands"]))
        snapshot = fixture()
        del snapshot["results"]["packages_installed"]
        self.assertFalse(maintenance.build_report(snapshot)["collection_complete"])
        self.assertTrue(all(item["state"] == "unknown" for item in maintenance.build_report(snapshot)["packages"]))

    def test_mismatched_and_legacy_completion_is_not_passed(self):
        for key, value in [("expected_commands", 5), ("expected_commands", True), ("collection_complete", False)]:
            snapshot = fixture()
            snapshot[key] = value
            self.assertFalse(maintenance.build_report(snapshot)["collection_complete"])
        snapshot = fixture()
        del snapshot["collection_complete"]
        self.assertFalse(maintenance.build_report(snapshot)["collection_complete"])

    def test_inconsistent_package_lists_do_not_claim_state(self):
        snapshot = fixture()
        snapshot["results"]["packages_disabled"]["stdout"] += "package:com.google.android.tvlauncher\n"
        report = maintenance.build_report(snapshot)
        self.assertEqual(report["packages"][0]["state"], "unknown")
        self.assertIn("packages", report["unrecognized_fields"])
        snapshot["results"]["packages_enabled"]["stdout"] = "Error: PRIVATE\n"
        self.assertTrue(all(item["state"] == "unknown" for item in maintenance.build_report(snapshot)["packages"]))

    def test_android_package_and_actual_data_mount_format(self):
        snapshot = fixture()
        for key in ("packages_installed", "packages_enabled"):
            snapshot["results"][key]["stdout"] += "package:android\n"
        snapshot["results"]["data_storage"]["stdout"] = snapshot["results"]["data_storage"]["stdout"].replace(" /data\n", " /data/user/0\n")
        report = maintenance.build_report(snapshot)
        self.assertEqual(report["packages"][0]["state"], "enabled")
        self.assertEqual(report["data_storage"]["available_kib"], 400000)
        self.assertEqual(report["unrecognized_fields"], [])

    def test_empty_installed_list_does_not_claim_all_packages_removed(self):
        snapshot = fixture()
        for key in ("packages_installed", "packages_enabled", "packages_disabled"):
            snapshot["results"][key]["stdout"] = ""
        report = maintenance.build_report(snapshot)
        self.assertTrue(all(item["state"] == "unknown" for item in report["packages"]))
        self.assertIn("packages", report["unrecognized_fields"])

    def test_protected_package_absence_and_no_space_require_manual_review(self):
        snapshot = fixture()
        for key in ("packages_installed", "packages_enabled"):
            snapshot["results"][key]["stdout"] = snapshot["results"][key]["stdout"].replace("package:com.kick.mobile\n", "")
        snapshot["results"]["data_storage"]["stdout"] = "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/X 100 100 0 100% /data\n"
        report = maintenance.build_report(snapshot)
        self.assertEqual(next(item for item in report["packages"] if item["name"] == "Kick")["state"], "absent")
        self.assertTrue(any("Kick:" in item for item in report["recommendations"]))
        self.assertTrue(any("нет доступного места" in item for item in report["recommendations"]))

    def test_duplicate_malformed_or_implausible_numeric_facts_are_unknown(self):
        for memory in ("MemTotal: 100 kB\nMemAvailable: 200 kB\n", "MemTotal: 100 kB\nMemAvailable: 20 kB\nMemAvailable: 30 kB\n"):
            snapshot = fixture()
            snapshot["results"]["memory"]["stdout"] = memory
            self.assertIsNone(maintenance.build_report(snapshot)["memory"]["available_kib"])
        for storage in ("PRIVATE 100 20 80 20% /data", "Filesystem 1K-blocks Used Available Use% Mounted on\nPRIVATE 100 90 80 90% /data"):
            self.assertIsNone(maintenance.storage_values(storage))

    def test_arbitrary_raw_text_and_identity_never_reach_report(self):
        snapshot = fixture()
        snapshot.update({"label": "SECRET-LABEL", "serial": "SECRET-SERIAL", "started_utc": "SECRET-DATE"})
        snapshot["results"]["home_version"]["stdout"] = "  versionName=SECRET-VERSION\nAccount=SECRET-ACCOUNT\n"
        snapshot["results"]["packages_installed"]["stdout"] += "package:com.SECRET.APP\n"
        snapshot["results"]["memory"]["stdout"] += "SSID=SECRET-NETWORK\n"
        report = maintenance.build_report(snapshot)
        for output in (json.dumps(report), maintenance.markdown(report)):
            self.assertNotIn("SECRET", output)
            self.assertNotIn("PRIVATE", output)
        self.assertIsNone(report["home_version"])

    def test_wrong_profile_and_unknown_command_rejected(self):
        for snapshot in ({}, {"profile": "audio"}, {"profile": "maintenance", "results": {"SECRET": result("")}}):
            with self.assertRaises(ValueError):
                maintenance.build_report(snapshot)

    def test_private_file_boundary_size_and_output_preservation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            private = root / "local/diagnostics"
            private.mkdir(parents=True)
            source = private / "sample.json"
            source.write_text(json.dumps(fixture()))
            outside = root / "outside.json"
            outside.write_text("PRIVATE")
            linked = private / "link.json"
            linked.symlink_to(source)
            with patch.object(maintenance, "ROOT", root):
                self.assertEqual(maintenance.load_snapshot(source)["profile"], "maintenance")
                for rejected in (outside, linked):
                    with self.assertRaises(ValueError):
                        maintenance.load_snapshot(rejected)
                with patch.object(maintenance, "MAX_FILE_BYTES", 10):
                    with self.assertRaises(ValueError):
                        maintenance.load_snapshot(source)
                output = root / "report.md"
                output.write_text("original")
                with patch.object(sys, "argv", [str(SCRIPT), str(source), "--output", str(output)]), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        maintenance.main()
                self.assertEqual(output.read_text(), "original")
                output.unlink()
                with patch.object(sys, "argv", [str(SCRIPT), str(source), "--output", str(output)]):
                    maintenance.main()
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
