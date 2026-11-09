"""The application icon must bind actual, verified desktop-exported artwork."""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "ios/Vendor/AtumDesign"
CATALOG = ROOT / "ios/App/Assets.xcassets/AppIcon.appiconset"


class AppIconTests(unittest.TestCase):
    def test_universal_icon_is_the_verified_export(self):
        catalog = json.loads((CATALOG / "Contents.json").read_text())
        entries = [item for item in catalog["images"]
                   if item.get("idiom") == "universal"
                   and item.get("platform") == "ios"
                   and item.get("size") == "1024x1024"]
        self.assertEqual(len(entries), 1)
        filename = entries[0]["filename"]
        self.assertEqual(Path(filename).name, filename)
        installed = (CATALOG / filename).read_bytes()
        resource = "app-icon/atum-app-icon-1024.png"
        exported = (VENDOR / resource).read_bytes()
        manifest = json.loads((VENDOR / "manifest.json").read_text())
        provenance = json.loads((VENDOR / "app-icon/atum-app-icon-1024.json").read_text())
        self.assertEqual(installed, exported)
        digest = hashlib.sha256(installed).hexdigest()
        self.assertEqual(digest, manifest["files"][resource])
        self.assertEqual(digest, provenance["resource"]["sha256"])
        self.assertEqual(provenance["source"]["path"], "apps/desktop/assets/icon-mac.svg")

    def test_icon_is_1024_rgb_without_alpha(self):
        data = (CATALOG / "atum-app-icon-1024.png").read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(data[12:16], b"IHDR")
        self.assertEqual(int.from_bytes(data[16:20], "big"), 1024)
        self.assertEqual(int.from_bytes(data[20:24], "big"), 1024)
        self.assertEqual(data[24], 8)
        self.assertEqual(data[25], 2, "iOS application artwork must be RGB, not RGBA")

    def test_generated_project_and_source_spec_select_app_icon(self):
        spec = (ROOT / "ios/project.yml").read_text()
        project = (ROOT / "ios/AtumMobile.xcodeproj/project.pbxproj").read_text()
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon", spec)
        self.assertIn("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;", project)
        self.assertIn("Assets.xcassets in Resources", project)


if __name__ == "__main__":
    unittest.main()
