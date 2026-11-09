"""Static provenance tests for the isolated LC4 phone SDK source pack."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "prepare_matrix_sdk", ROOT / "scripts/prepare-matrix-sdk.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PhoneSDKSourceTests(unittest.TestCase):
    def setUp(self):
        self.pack = ROOT / "sdk/phone-26.10.15"
        self.manifest = self.pack / "source.json"
        self.pin = json.loads(self.manifest.read_text())

    def test_custody_remains_default_and_phone_pack_is_static(self):
        self.assertEqual(MODULE.MANIFEST, ROOT / "sdk/custody/source.json")
        self.assertEqual(MODULE.MANIFESTS, {
            "custody": ROOT / "sdk/custody/source.json",
            "phone-26.10.15": self.manifest,
        })
        project = (ROOT / "ios/project.yml").read_text()
        self.assertEqual(
            project.count(
                "    url: https://github.com/atum-platform/atum-matrix-rust-components-swift.git\n"
                "    revision: 66c18d378d44d9ad61946f08b926514cccb14fb5\n"
            ),
            1,
        )
        self.assertNotIn("phone-26.10.15", project)

    def test_phone_patch_license_and_target_provenance_are_exact(self):
        self.assertFalse(self.pin["runtimeSelected"])
        self.assertEqual(self.pin["status"], "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED")
        self.assertEqual(
            self.pin["upstreamRevision"],
            "97a1589b70bd122c1d66e0d68ea008d8554076a5",
        )
        self.assertEqual(self.pin["swiftDistribution"]["release"], "26.10.15")
        self.assertEqual(
            self.pin["swiftDistribution"]["officialBinarySHA256"],
            "38a5321ebaeea65bc162b838330c70812f967e1a5fd878c649ce9ff3d6dbc853",
        )
        self.assertEqual(digest(ROOT / self.pin["patch"]), self.pin["patchSHA256"])
        self.assertEqual(digest(self.pack / "LICENSE"), self.pin["licenseSHA256"])

    def test_patch_scope_is_bounded_and_every_changed_file_is_hashed(self):
        patch = (ROOT / self.pin["patch"]).read_text()
        changed = {
            line.removeprefix("+++ b/")
            for line in patch.splitlines()
            if line.startswith("+++ b/")
        }
        self.assertEqual(changed, set(self.pin["preimageSHA256"]))
        self.assertEqual(changed, set(self.pin["patchedSHA256"]))
        self.assertEqual(changed, {
            "bindings/matrix-sdk-ffi/src/room/mod.rs",
            "crates/matrix-sdk-ui/src/room_list_service/mod.rs",
            "crates/matrix-sdk-ui/tests/integration/room_list_service.rs",
            "crates/matrix-sdk/src/error.rs",
            "crates/matrix-sdk/tests/integration/send_queue.rs",
        })
        self.assertIn("io.atum.conversation", patch)
        self.assertIn("io.atum.app_bot.dm", patch)
        self.assertIn("account_data_raw", patch)
        self.assertIn("520..=529", patch)
        self.assertNotIn('["*", "*"]', patch)


if __name__ == "__main__":
    unittest.main()
