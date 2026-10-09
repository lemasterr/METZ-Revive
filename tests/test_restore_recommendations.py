"""Rollback safety checks use a local fake ADB, never the TV."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = "Metz/Metz_EU/shinagawa:11/RTO9.250817.002/13948470:user/release-keys"
PACKAGES = ["com.google.android.tvrecommendations", "tv.anoki.acr.controller"]


class RestoreTests(unittest.TestCase):
    def run_restore(self, args, state="device", fingerprint=FINGERPRINT, packages=PACKAGES):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            fake = root / "adb"
            fake.write_text("#!/usr/bin/env python3\n"
                            "import json, os, sys\n"
                            "args=sys.argv[1:]\n"
                            "with open(os.environ['TEST_ADB_LOG'], 'a') as f: f.write(json.dumps(args)+'\\n')\n"
                            "assert args[:2]==['-s','test-device']\n"
                            "cmd=args[2:]\n"
                            "if cmd==['get-state']: print(os.environ['TEST_ADB_STATE'])\n"
                            "elif cmd==['shell','getprop','ro.build.fingerprint']: print(os.environ['TEST_ADB_BUILD'])\n"
                            "elif cmd==['shell','pm','list','packages','--user','0']: print(os.environ['TEST_ADB_PACKAGES'])\n"
                            "elif cmd[:3]==['shell','pm','default-state']: print('default')\n"
                            "else: sys.exit(3)\n")
            fake.chmod(0o700)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       TEST_ADB_LOG=str(log), TEST_ADB_STATE=state, TEST_ADB_BUILD=fingerprint,
                       TEST_ADB_PACKAGES="\n".join("package:" + p for p in packages))
            result = subprocess.run(["sh", str(ROOT / "scripts/restore_recommendations.sh")] + args,
                                    env=env, capture_output=True, text=True)
            calls = [json.loads(line)[2:] for line in log.read_text().splitlines()] if log.exists() else []
            writes = [call for call in calls if call[:3] == ["shell", "pm", "default-state"]]
            return result, writes

    def test_dry_run_has_no_writes(self):
        result, writes = self.run_restore(["test-device"])
        self.assertEqual(result.returncode, 0)
        self.assertIn("Dry run", result.stdout)
        self.assertEqual(writes, [])

    def test_unauthorized_and_changed_build_have_no_writes(self):
        for overrides in [{"state": "unauthorized"}, {"fingerprint": "different-build"}]:
            with self.subTest(overrides=overrides):
                result, writes = self.run_restore(["test-device", "--apply"], **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(writes, [])

    def test_all_packages_checked_before_any_write(self):
        result, writes = self.run_restore(["test-device", "--apply"], packages=PACKAGES[:1])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(writes, [])

    def test_apply_restores_only_the_two_original_default_states(self):
        result, writes = self.run_restore(["test-device", "--apply"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(writes, [["shell", "pm", "default-state", "--user", "0", p] for p in PACKAGES])

    def test_missing_serial_and_invalid_flag_have_no_writes(self):
        for args in [[], [""], ["test-device", "--force"], ["-d"]]:
            with self.subTest(args=args):
                result, writes = self.run_restore(args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(writes, [])


if __name__ == "__main__":
    unittest.main()
