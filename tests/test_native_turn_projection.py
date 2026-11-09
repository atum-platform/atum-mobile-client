"""Contract-c projection retains upstream outcomes and rejects pack drift."""
import json
import runpy
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_native_api_projection import projection, ROOT

turns = runpy.run_path(str(ROOT / "scripts/generate-native-turn-fixtures.py"))
PACK = ROOT / "docs/contracts/provider/agent-turns/v1"


@unittest.skipUnless((ROOT / "docs/contracts/provider/agent-turns/v1").is_dir(), "full provider pack is intentionally unshipped; retained public push projection remains covered")
class NativeTurnProjectionTests(unittest.TestCase):
    def test_exact_content_and_client_machine_fixtures_keep_dispositions(self):
        output = turns["generate"]()
        manifest = json.loads(output["manifest.json"])
        contract = json.loads((PACK / "contract.json").read_bytes())
        selected = [x for x in contract["fixtures"] if x.get("message") in turns["MESSAGES"] or x.get("machine") == "client_turn"]
        self.assertEqual({x["file"] for x in manifest["fixtures"]}, {Path(x["file"]).name for x in selected})
        for source in selected:
            name = Path(source["file"]).name
            self.assertEqual(output[name], (PACK / source["file"]).read_bytes())
            retained = next(x for x in manifest["fixtures"] if x["file"] == name)
            for key in ["message", "machine", "expect", "violation"]:
                self.assertEqual(retained.get(key), source.get(key))

    def test_unselected_cloud_fixture_drift_also_refuses_projection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pack = root / "docs/contracts/provider/agent-turns/v1"
            shutil.copytree(PACK, pack)
            with patch.object(projection, "ROOT", root):
                projection.generate(pack, turns["MESSAGES"], frozenset({"client_turn"}))
                contract = json.loads((pack / "contract.json").read_bytes())
                candidate = next(x for x in contract["fixtures"] if x.get("message") not in turns["MESSAGES"] and x.get("machine") != "client_turn")
                file = pack / candidate["file"]
                file.write_bytes(file.read_bytes() + b"\n")
                with self.assertRaisesRegex(ValueError, "immutable provider pin"):
                    projection.generate(pack, turns["MESSAGES"], frozenset({"client_turn"}))


if __name__ == "__main__":
    unittest.main()
