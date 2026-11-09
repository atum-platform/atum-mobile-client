import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/generate-info-plist-localization.py"
SPEC = importlib.util.spec_from_file_location("info_plist_localization", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class InfoPlistLocalizationTests(unittest.TestCase):
    def test_generated_catalog_is_exact_projection_of_export(self):
        source = json.loads(MODULE.SOURCE.read_text())
        generated = json.loads(MODULE.OUTPUT.read_text())
        self.assertEqual(generated, MODULE.projected_catalog(source))
        self.assertEqual(
            set(generated["strings"][MODULE.PLIST_KEY]["localizations"]),
            {"en", "vi", "ja", "zh", "zh-Hant"},
        )

    def test_dictation_permission_strings_are_projected_once_exported(self):
        source = {
            "sourceLanguage": "vi",
            "strings": {
                MODULE.COPY_KEY: {"localizations": {}},
                MODULE.PENDING_COPY_KEYS["NSMicrophoneUsageDescription"]: {"localizations": {"vi": {}}},
            },
        }
        projected = MODULE.projected_catalog(source)
        self.assertEqual(
            set(projected["strings"]), {MODULE.PLIST_KEY, "NSMicrophoneUsageDescription"}
        )

    def test_info_plist_declares_dictation_permissions(self):
        plist = (ROOT / "ios/App/Info.plist").read_text()
        for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
            self.assertIn(f"<key>{key}</key>", plist)


if __name__ == "__main__":
    unittest.main()
