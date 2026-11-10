#!/usr/bin/env python3
"""Verify upstream Store/admission pins and project synthetic Store wire fixtures."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("native_fixtures", ROOT / "scripts/generate-native-api-fixtures.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
PACK = ROOT / "docs/contracts/provider/store/v1.1"
OUTPUT = ROOT / "ios/Tests/Fixtures/store-v1.1"
MESSAGES = frozenset({"catalog.response", "entitlements.response", "purchases.response", "purchase.result", "purchase.request", "cancel.result"})
PINS = {
    "store/v1.1": "77b3dc62b8b7ab3a9332c0a8c0eb493df1035dabb76eff2b21764629dc8707f0",
    "mobile-native-api/v1.1": "aa7c9df2c736bbb0e34ccfcba4de5b5e26a4048bd3b7857c866479dbc11432ef",
    "mobile-purchases/v1.1": "6342cbb5d7b1046e93e253ffaa5a5b0895521b630fa1d4a9964676e53814a9bb",
}


def generate():
    for path, expected in PINS.items():
        pack = ROOT / "docs/contracts/provider" / path
        contract = json.loads((pack / "contract.json").read_bytes())
        digest = hashlib.sha256()
        for relative in contract["pack_files"]:
            name = relative.encode()
            data = (pack / relative).read_bytes()
            digest.update(len(name).to_bytes(4, "big")); digest.update(name)
            digest.update(len(data).to_bytes(8, "big")); digest.update(data)
        if digest.hexdigest() != expected or (pack / "PINNED-SHA256").read_text().strip() != expected:
            raise ValueError("Frozen provider pack differs: " + path)
    output = helper.generate(pack=PACK, messages=MESSAGES)
    manifest = json.loads(output["manifest.json"])
    manifest["providerCommit"] = "7df04652c7c1ce39f757891e01e0d14951db31bb"
    manifest["admissionPins"] = PINS
    output["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    helper.write_or_check(generate(), OUTPUT, args.check)
