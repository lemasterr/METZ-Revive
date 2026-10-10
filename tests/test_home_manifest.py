from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


MANIFEST = Path(__file__).resolve().parents[1] / "metz-home/src/main/AndroidManifest.xml"
ANDROID = "{http://schemas.android.com/apk/res/android}"


class HomeComponentSafety(unittest.TestCase):
    def setUp(self):
        self.manifest = ET.parse(MANIFEST).getroot()

    def test_home_eligibility_is_an_explicit_alias(self):
        candidates = []
        for component in self.manifest.findall("./application/*"):
            categories = [item.get(ANDROID + "name") for item in component.findall("./intent-filter/category")]
            if "android.intent.category.HOME" in categories:
                candidates.append(component)
                self.assertEqual(component.tag, "activity-alias")
                self.assertEqual(component.get(ANDROID + "name"), ".HomeEntry")
                self.assertEqual(component.get(ANDROID + "targetActivity"), ".HomeActivity")
        self.assertEqual(len(candidates), 1)

    def test_preview_remains_accessible_from_stock_tv_launcher(self):
        activities = self.manifest.findall("./application/activity")
        self.assertTrue(any(
            activity.get(ANDROID + "exported") == "true"
            and activity.get(ANDROID + "enabled", "true") == "true"
            and any(category.get(ANDROID + "name") == "android.intent.category.LEANBACK_LAUNCHER"
                    for category in activity.findall("./intent-filter/category"))
            for activity in activities
        ))

    def test_launcher_has_only_protected_request_components(self):
        self.assertFalse(self.manifest.findall("uses-permission"))
        self.assertFalse(self.manifest.findall("./application/provider"))
        receivers = self.manifest.findall("./application/receiver")
        self.assertEqual({r.get(ANDROID + "name") for r in receivers}, {".CatalogReceiver", ".AppearanceReceiver"})
        for receiver in receivers:
            self.assertEqual(receiver.get(ANDROID + "permission"), "android.permission.DUMP")
            self.assertFalse(receiver.findall("intent-filter"))
        services = self.manifest.findall("./application/service")
        self.assertEqual(len(services), 1)
        self.assertEqual(services[0].get(ANDROID + "name"), ".MacKeyboard")
        self.assertEqual(services[0].get(ANDROID + "permission"), "android.permission.BIND_INPUT_METHOD")
        actions = [a.get(ANDROID + "name") for a in services[0].findall("./intent-filter/action")]
        self.assertEqual(actions, ["android.view.InputMethod"])


if __name__ == "__main__":
    unittest.main()
