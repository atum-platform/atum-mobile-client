"""Deletion resource fixtures retain the accepted pack bytes and dispositions."""
import json
import runpy
import unittest
from pathlib import Path

from test_native_api_projection import ROOT

deletion = runpy.run_path(str(ROOT / "scripts/generate-native-deletion-fixtures.py"))
PACK = ROOT / "docs/contracts/provider/account-deletion/v1"


@unittest.skipUnless((ROOT / "docs/contracts/provider/account-deletion/v1").is_dir(), "full provider pack is intentionally unshipped; retained public push projection remains covered")
class NativeDeletionProjectionTests(unittest.TestCase):
    def test_selected_wire_samples_preserve_provider_bytes_and_dispositions(self):
        output = deletion["generate"]()
        manifest = json.loads(output["manifest.json"])
        contract = json.loads((PACK / "contract.json").read_bytes())
        selected = [x for x in contract["fixtures"] if x.get("message") in deletion["MESSAGES"]]
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
