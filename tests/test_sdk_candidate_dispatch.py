"""The derived candidate dispatcher never crosses SDK source authorities."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "build_p2_sdk_candidate", ROOT / "scripts/build-p2-sdk-candidate.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CandidateAuthorityDispatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.artifact = Path(self.temp.name) / "custody-artifact"
        self.artifact.mkdir()
        (self.artifact / "LICENSE").write_bytes((ROOT / "sdk/custody/LICENSE").read_bytes())
        (self.artifact / "Package.swift").write_text("// synthetic custody package\n")
        inventory = {str(path.relative_to(self.artifact)): digest(path)
                     for path in self.artifact.rglob("*") if path.is_file()}
        manifest = ROOT / "sdk/custody/source.json"
        pin = json.loads(manifest.read_text())
        self.receipt = {
            "status": "APPLE_LIBRARY_AND_SWIFT_COMPILED",
            "source": {
                "status": "SOURCE_PREPARED",
                "sourceManifestSHA256": digest(manifest),
                "consumerHasUncommittedChanges": False,
                "upstreamRevision": pin["upstreamRevision"],
                "consumerRevision": "a" * 40,
            },
            "artifactSHA256": inventory,
        }
        (self.artifact / "atum-build-receipt.json").write_text(json.dumps(self.receipt))

    def test_custody_artifact_is_default_only_and_longpoll_dispatch_refuses_it(self):
        receipt, receipt_digest, manifest, _ = MODULE.candidate_authority(
            self.artifact, unselected_longpoll=False)
        self.assertEqual(receipt, self.receipt)
        self.assertEqual(len(receipt_digest), 64)
        self.assertEqual(manifest, ROOT / "sdk/custody/source.json")
        with self.assertRaises(ValueError):
            MODULE.candidate_authority(self.artifact, unselected_longpoll=True)

    def test_signed_receipt_inventory_includes_nested_live_app_sources(self):
        values = {
            str(path.relative_to(ROOT))
            for path in MODULE.candidate_source_files([], ROOT / "ios/project.yml")
        }
        self.assertIn("ios/App/Product/LiveProductModels.swift", values)
        self.assertIn("ios/App/AppRoot.swift", values)
        self.assertIn("ios/App/LiveMatrixSession.swift", values)
        self.assertIn("ios/App/AtumMobile.entitlements", values)
        self.assertIn("ios/App/PushLocalizations/Localizable.xcstrings", values)

    def test_signed_receipt_inventory_includes_every_linked_package_target(self):
        values = {
            str(path.relative_to(ROOT))
            for path in MODULE.candidate_source_files([], ROOT / "ios/project.yml")
        }
        for prefix in ("ios/Sources/AtumNativeAPI/", "ios/Sources/AtumChat/",
                       "ios/Sources/AtumDesign/", "ios/Vendor/AtumDesign/"):
            self.assertTrue(any(v.startswith(prefix) for v in values), prefix)
        self.assertFalse(any(v.startswith("ios/Sources/AtumPrototype/") for v in values),
                         "the app no longer links the prototype")


if __name__ == "__main__":
    unittest.main()
