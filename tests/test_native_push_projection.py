"""Selected iOS push samples must preserve the accepted provider bytes/dispositions."""
import json
import runpy
import unittest
from pathlib import Path

from test_native_api_projection import ROOT

push = runpy.run_path(str(ROOT / "scripts/generate-native-push-fixtures.py"))
PACK = ROOT / "docs/contracts/provider/mobile-push/v1"


class NativePushProjectionTests(unittest.TestCase):
    def test_system_localization_keeps_provider_key_and_every_source_locale(self):
        binding = runpy.run_path(str(ROOT / "scripts/generate-push-localization.py"))
        generated = json.loads(binding["generate"]())
        fixture = json.loads((PACK / "fixtures/pusher-set-prod.request.json").read_bytes())
        key = fixture["data"]["default_payload"]["aps"]["alert"]["loc-key"]
        # The provider's generic key, plus the rich-notification phrases the
        # extension shows once it has decrypted the event (all pinned desktop copy).
        rich = {"ATUM_PUSH_" + kind for kind in
                ["UNNAMED", "IMAGE", "VIDEO", "AUDIO", "FILE", "STICKER", "INVITE"]}
        self.assertEqual(set(generated["strings"]), {key} | rich)
        for rich_key in rich:
            self.assertEqual(set(generated["strings"][rich_key]["localizations"]), set(binding["LOCALES"].values()))
        source = json.loads((ROOT / "ios/Vendor/AtumDesign/Localizable.xcstrings").read_bytes())["strings"][binding["COPY_KEY"]]
        target = generated["strings"][key]["localizations"]
        self.assertEqual(set(target), set(binding["LOCALES"].values()))
        for original, native in binding["LOCALES"].items():
            self.assertEqual(target[native]["stringUnit"], source["localizations"][original]["stringUnit"])

    def test_projection_preserves_provider_bytes_and_dispositions(self):
        output = push["generate"]()
        manifest = json.loads(output["manifest.json"])
        contract = json.loads((PACK / "contract.json").read_bytes())
        selected = [x for x in contract["fixtures"] if x.get("message") in push["MESSAGES"]]
        self.assertEqual({x["file"] for x in manifest["fixtures"]}, {Path(x["file"]).name for x in selected})
        self.assertEqual(manifest["packSHA256"], (PACK / "PINNED-SHA256").read_text().strip())
        for source in selected:
            name = Path(source["file"]).name
            self.assertEqual(output[name], (PACK / source["file"]).read_bytes())
            retained = next(x for x in manifest["fixtures"] if x["file"] == name)
            for key in ["message", "expect", "violation"]:
                self.assertEqual(retained.get(key), source.get(key))


if __name__ == "__main__":
    unittest.main()
