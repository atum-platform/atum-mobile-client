"""Public d1 text integrity and owner-approved local StoreKit configuration."""
import json
import runpy
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
purchases = runpy.run_path(str(ROOT / "scripts/verify-native-purchase-contract.py"))


class NativePurchaseContractTests(unittest.TestCase):
    def test_public_contract_checksums_and_no_projected_fixtures(self):
        purchases["verify"]()
        self.assertFalse((ROOT / "ios/Tests/Fixtures/mobile-purchases-v1").exists())

    def test_modified_contract_text_is_rejected(self):
        for name in ["README.md", "contract.json"]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                pack = Path(tmp) / "pack"
                shutil.copytree(purchases["PACK"], pack)
                with (pack / name).open("ab") as stream:
                    stream.write(b"\nchanged\n")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    purchases["verify"](pack)

    def test_full_pack_digest_cannot_be_used_as_public_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            pack = Path(tmp)
            (pack / "PINNED-SHA256").write_text("0" * 64 + "\n")
            with self.assertRaisesRegex(ValueError, "checksum manifest"):
                purchases["verify"](pack)

    def test_private_fixture_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            pack = Path(tmp) / "pack"
            shutil.copytree(purchases["PACK"], pack)
            (pack / "fixtures").mkdir()
            with self.assertRaisesRegex(ValueError, "remain private"):
                purchases["verify"](pack)

    def test_storekit_config_has_final_prices_consumables_and_vietnam_storefront(self):
        config = json.loads((ROOT / "ios/StoreKit/ProtonPacks.storekit").read_bytes())
        self.assertEqual({p["productID"]: p["displayPrice"] for p in config["products"]}, {
            "com.atum.mobile.protons.100k": "95000", "com.atum.mobile.protons.500k": "395000"})
        self.assertTrue(all(p["type"] == "Consumable" and not p["familyShareable"]
                            for p in config["products"]))
        self.assertEqual(config["settings"]["_storefront"], "VNM")
        self.assertEqual(config["settings"]["_locale"], "vi_VN")
        self.assertEqual(config["subscriptionGroups"], [])


if __name__ == "__main__":
    unittest.main()
