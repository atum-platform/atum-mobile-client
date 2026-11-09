"""Fixture provenance must cover the entire provider pack, not just UI samples."""
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_api_projection", ROOT / "scripts/generate-native-api-fixtures.py")
projection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(projection)


@unittest.skipUnless((projection.PACK).is_dir(), "full provider pack is intentionally unshipped; retained public push projection remains covered")
class NativeAPIProjectionTests(unittest.TestCase):
    def test_selected_fixtures_are_exact_provider_bytes_and_retain_dispositions(self):
        output = projection.generate()
        manifest = json.loads(output["manifest.json"])
        contract = json.loads((projection.PACK / "contract.json").read_bytes())
        selected = [x for x in contract["fixtures"] if x.get("message") in projection.MESSAGES]
        self.assertEqual({x["file"] for x in manifest["fixtures"]}, {Path(x["file"]).name for x in selected})
        for source in selected:
            name = Path(source["file"]).name
            self.assertEqual(output[name], (projection.PACK / source["file"]).read_bytes())
            retained = next(x for x in manifest["fixtures"] if x["file"] == name)
            self.assertEqual(retained["message"], source["message"])
            self.assertEqual(retained["expect"], source["expect"])

    def test_tampering_selected_or_unselected_pack_file_refuses_projection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = root / "docs/contracts/provider/mobile-native-api/v1"
            shutil.copytree(projection.PACK, pack)
            with patch.object(projection, "ROOT", root), patch.object(projection, "PACK", pack):
                projection.generate()
                for name in ["fixtures/wallet.response.json", "fixtures/ios-domain-client.registration.json", "README.md"]:
                    with self.subTest(file=name):
                        path = pack / name
                        original = path.read_bytes()
                        path.write_bytes(original + b"\n")
                        with self.assertRaisesRegex(ValueError, "immutable provider pin"):
                            projection.generate()
                        path.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
