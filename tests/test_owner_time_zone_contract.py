import hashlib
import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "docs/contracts/provider/owner-time-zone/v1"
SOURCE = ROOT / "ios/Sources/AtumNativeAPI/OwnerTimeZone.swift"


class OwnerTimeZoneContractTests(unittest.TestCase):
    def test_vendored_pack_matches_its_frozen_length_prefixed_digest(self):
        contract = json.loads((PACK / "contract.json").read_bytes())
        files = contract["pack_files"]
        self.assertEqual(files, sorted(set(files)))
        digest = hashlib.sha256()
        for relative in files:
            path = Path(relative)
            self.assertFalse(path.is_absolute())
            self.assertNotIn("..", path.parts)
            name = relative.encode()
            body = (PACK / relative).read_bytes()
            digest.update(len(name).to_bytes(4, "big"))
            digest.update(name)
            digest.update(len(body).to_bytes(8, "big"))
            digest.update(body)
        self.assertEqual(
            digest.hexdigest(),
            (PACK / "PINNED-SHA256").read_text().strip(),
        )
        self.assertEqual(contract["contract_id"], "atum.owner-time-zone")
        self.assertEqual(contract["version"], 1)
        self.assertEqual(contract["status"], "frozen")
        self.assertIn("mobile", contract["consumers"])

    def test_phone_constants_match_the_vendored_headers_bound_and_pattern(self):
        contract = json.loads((PACK / "contract.json").read_bytes())
        zone = contract["types"]["iana_time_zone"]
        source = SOURCE.read_text()
        self.assertIn('requestHeader = "Atum-Time-Zone"', source)
        self.assertIn('acknowledgementHeader = "Atum-Time-Zone-Ack"', source)
        self.assertIn(f"maximumLength = {zone['max']}", source)
        self.assertIn(zone["pattern"], source)

        pattern = re.compile(zone["pattern"])
        accepted = ["Asia/Ho_Chi_Minh", "Asia/Saigon", "UTC"]
        refused = ["", "+07:00", "asia/ho_chi_minh", "A" * 65]
        for value in accepted:
            self.assertLessEqual(len(value.encode()), zone["max"])
            self.assertIsNotNone(pattern.fullmatch(value), value)
        for value in refused:
            self.assertTrue(
                len(value.encode()) > zone["max"] or pattern.fullmatch(value) is None,
                value,
            )

    def test_report_vectors_keep_retry_and_change_id_semantics(self):
        vectors = json.loads((PACK / "fixtures/report.vectors.json").read_bytes())["vectors"]
        self.assertGreaterEqual(len(vectors), 5)
        same = next(value for value in vectors if value["sent"] == value["stored"])
        self.assertTrue(same["result"])
        self.assertFalse(same["write"])
        self.assertEqual(same["changeIdDelta"], 0)
        unknown = next(value for value in vectors if value["sent"] == "Mars/Olympus")
        self.assertFalse(unknown["result"])
        self.assertFalse(unknown["write"])
        self.assertEqual(unknown["changeIdDelta"], 0)


if __name__ == "__main__":
    unittest.main()
