from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


MANIFEST = Path(__file__).resolve().parents[1] / "metz-home/src/main/AndroidManifest.xml"
ANDROID = "{http://schemas.android.com/apk/res/android}"


class HomePreviewSafety(unittest.TestCase):
    def setUp(self):
        self.manifest = ET.parse(MANIFEST).getroot()

    def test_install_cannot_add_an_enabled_home_candidate(self):
        candidates = []
        for component in self.manifest.findall("./application/*"):
            categories = [item.get(ANDROID + "name") for item in component.findall("./intent-filter/category")]
            if "android.intent.category.HOME" in categories:
                candidates.append(component)
                self.assertEqual(component.get(ANDROID + "enabled"), "false")
        self.assertTrue(candidates, "HOME entry must exist for explicit later opt-in")

    def test_preview_remains_accessible_from_stock_tv_launcher(self):
        activities = self.manifest.findall("./application/activity")
        self.assertTrue(any(
            activity.get(ANDROID + "exported") == "true"
            and activity.get(ANDROID + "enabled", "true") == "true"
            and any(category.get(ANDROID + "name") == "android.intent.category.LEANBACK_LAUNCHER"
                    for category in activity.findall("./intent-filter/category"))
            for activity in activities
        ))

    def test_launcher_has_no_permissions_or_background_components(self):
        self.assertFalse(self.manifest.findall("uses-permission"))
        for name in ["service", "receiver", "provider"]:
            self.assertFalse(self.manifest.findall("./application/" + name))


if __name__ == "__main__":
    unittest.main()
