"""Native auth samples retain the frozen provider's exact binding dispositions."""
import json
import runpy
import unittest
from pathlib import Path

from test_native_api_projection import ROOT

auth = runpy.run_path(str(ROOT / "scripts/generate-native-auth-fixtures.py"))
PACK = ROOT / "docs/contracts/provider/mobile-native-api/v1"


@unittest.skipUnless((ROOT / "docs/contracts/provider/mobile-native-api/v1").is_dir(), "full provider pack is intentionally unshipped; retained public push projection remains covered")
class NativeAuthProjectionTests(unittest.TestCase):
    def test_registration_binding_and_domain_samples_retain_provider_bytes(self):
        output = auth["generate"]()
        manifest = json.loads(output["manifest.json"])
        contract = json.loads((PACK / "contract.json").read_bytes())
        selected = [x for x in contract["fixtures"] if x.get("message") in auth["MESSAGES"] or x.get("machine") == "domain_grant"]
        self.assertEqual({x["file"] for x in manifest["fixtures"]}, {Path(x["file"]).name for x in selected})
        for source in selected:
            name = Path(source["file"]).name
            self.assertEqual(output[name], (PACK / source["file"]).read_bytes())
            retained = next(x for x in manifest["fixtures"] if x["file"] == name)
            for key in ["message", "machine", "expect", "violation"]:
                self.assertEqual(retained.get(key), source.get(key))

    def test_auth_and_api_consumers_share_one_accepted_pack_pin(self):
        manifest = json.loads(auth["generate"]()["manifest.json"])
        api = json.loads((ROOT / "ios/Sources/AtumPrototype/Fixtures/provider-native-v1/manifest.json").read_bytes())
        self.assertEqual(manifest["packSHA256"], api["packSHA256"])
        self.assertTrue(any(x.get("expect") == "reject" and x.get("message") == "binding.facts" for x in manifest["fixtures"]))


if __name__ == "__main__":
    unittest.main()
