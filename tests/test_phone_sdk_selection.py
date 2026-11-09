"""The app source pins the exact reviewed phone SDK producer commit everywhere."""
import hashlib
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
URL = "https://github.com/atum-platform/atum-matrix-rust-components-swift.git"
IDENTITY = "atum-matrix-rust-components-swift"
TAG = "26.10.15-atum.2"
REVISION = "66c18d378d44d9ad61946f08b926514cccb14fb5"
CHECKSUM = "0367555a1b7a1f0e775037ba1db2b9d93320255eb4919bcf781b32d3a9ada9c2"
ORIGIN_HASH = "302b1b7213daa6903d5744d40bd8d07b727059d6dc1905d3119b634cfd38dbac"
STOCK_URL = "matrix-org/matrix-rust-components-swift"
STOCK_REVISION = "55650a2320cc6e3264c1d5508a5094f8dd7e51a5"
PROJECT = ROOT / "ios/AtumMobile.xcodeproj"


class PhoneSDKSelectionTests(unittest.TestCase):
    def test_project_manifest_pins_the_reviewed_producer_by_revision(self):
        manifest = (ROOT / "ios/project.yml").read_text()
        self.assertIn(f"  MatrixRustSDK:\n    url: {URL}\n    revision: {REVISION}\n", manifest)
        self.assertNotIn(STOCK_URL, manifest)
        self.assertNotIn(STOCK_REVISION, manifest)

    def test_generated_project_has_one_matrix_reference_at_the_same_pin(self):
        pbx = (PROJECT / "project.pbxproj").read_text()
        references = re.findall(
            r'(\w{24}) /\* XCRemoteSwiftPackageReference "([^"]+)" \*/ = \{\n'
            r"\t\t\tisa = XCRemoteSwiftPackageReference;\n"
            r'\t\t\trepositoryURL = "([^"]+)";\n'
            r"\t\t\trequirement = \{\n\t\t\t\tkind = (\w+);\n\t\t\t\trevision = (\w+);",
            pbx,
        )
        matrix = [item for item in references if "matrix" in item[2]]
        self.assertEqual(len(matrix), 1)
        identifier, name, url, kind, revision = matrix[0]
        self.assertEqual((name, url, kind, revision), (IDENTITY, URL, "revision", REVISION))
        product = re.search(
            r"/\* MatrixRustSDK \*/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
            r"\t\t\tpackage = (\w{24}) ", pbx)
        self.assertEqual(product.group(1), identifier)
        self.assertNotIn(STOCK_URL, pbx)
        self.assertNotIn(STOCK_REVISION, pbx)

    def test_resolved_file_pins_the_same_revision_and_identity(self):
        resolved = json.loads((
            PROJECT / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        ).read_text())
        matrix = [pin for pin in resolved["pins"] if "matrix" in pin["location"]]
        self.assertEqual(len(matrix), 1)
        self.assertEqual(matrix[0]["identity"], IDENTITY)
        self.assertEqual(matrix[0]["location"], URL)
        self.assertEqual(matrix[0]["state"], {"revision": REVISION})

    def test_notices_name_the_selected_pin_and_the_bundled_license_matches(self):
        root = (ROOT / "NOTICE").read_bytes()
        self.assertEqual(root, (ROOT / "ios/App/Resources/NOTICE").read_bytes())
        text = root.decode()
        pack = json.loads((ROOT / "sdk/phone-26.10.15-founder/source.json").read_text())
        for value in (IDENTITY, TAG, REVISION, CHECKSUM, pack["upstreamRevision"],
                      pack["patchSHA256"], pack["swiftDistribution"]["revision"]):
            self.assertIn(value, text)
        self.assertNotIn(STOCK_REVISION, text)
        license_bytes = (ROOT / "ios/App/Resources/MatrixRustSDK-LICENSE.txt").read_bytes()
        self.assertEqual(hashlib.sha256(license_bytes).hexdigest(), pack["licenseSHA256"])


    def test_founder_reconciliation_uses_the_selected_authoritative_fetch(self):
        runtime = (ROOT / "ios/App/MatrixLiveRuntime.swift").read_text()
        model = (ROOT / "ios/App/LiveAppModel.swift").read_text()
        self.assertIn("room.fetchGlobalAccountDataRaw(", runtime)
        self.assertIn("fetchFounderChatMarker(roomID: roomID)", model)

    def test_product_high_entropy_migration_stays_disabled(self):
        for path in (ROOT / "ios/App").rglob("*.swift"):
            self.assertNotIn(".highEntropyPassphrase", path.read_text(), str(path))


if __name__ == "__main__":
    unittest.main()
