#!/usr/bin/env python3
"""Project immutable contract-a resource fixtures into the P2-only package.

The full pack digest uses the provider's length-prefixed algorithm at
7759bc63:spec/_tools/contract_pack.py. This is provenance, not a schema engine.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "docs/contracts/provider/mobile-native-api/v1"
OUTPUT = ROOT / "ios/Sources/AtumPrototype/Fixtures/provider-native-v1"
MESSAGES = frozenset({
    "agents.response", "wallet.response", "wallet.history.response",
    "alias.lookup.response", "alias.current.response", "alias.check.response",
    "alias.claim.request", "alias.claim.response", "error.response",
})


def generate(pack=None, messages=None, machines=frozenset()):
    pack = PACK if pack is None else pack
    messages = MESSAGES if messages is None else messages
    contract = json.loads((pack / "contract.json").read_bytes())
    files = contract["pack_files"]
    if files != sorted(set(files)):
        raise ValueError("Provider pack file order/uniqueness differs")
    digest = hashlib.sha256()
    for relative in files:
        if Path(relative).is_absolute() or any(x in ("", ".", "..") for x in relative.split("/")) or "\\" in relative:
            raise ValueError("Unsafe provider path")
        name = relative.encode()
        body = (pack / relative).read_bytes()
        digest.update(len(name).to_bytes(4, "big")); digest.update(name)
        digest.update(len(body).to_bytes(8, "big")); digest.update(body)
    pin = (pack / "PINNED-SHA256").read_text().strip()
    # Public projections attest only the retained pack bytes, not excluded private acceptance.
    receipt = {"packCommit": "sanitised-public-pack-v1"}
    if digest.hexdigest() != pin:
        raise ValueError("Public pack bytes differ from immutable provider pin")
    output = {}
    entries = []
    for fixture in contract["fixtures"]:
        if fixture.get("message") not in messages and fixture.get("machine") not in machines:
            continue
        name = Path(fixture["file"]).name
        if name in output:
            raise ValueError("Duplicate fixture basename")
        body = (pack / fixture["file"]).read_bytes()
        output[name] = body
        entries.append({**fixture, "file": name, "sha256": hashlib.sha256(body).hexdigest()})
    if {x["message"] for x in entries if "message" in x} != messages or {x["machine"] for x in entries if "machine" in x} != machines:
        raise ValueError("Missing selected resource-message fixtures")
    manifest = {"schemaVersion": 1, "contractId": contract["contract_id"], "version": contract["version"],
                "providerCommit": receipt["packCommit"], "packSHA256": pin, "fixtures": entries}
    output["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return output


def write_or_check(output, destination, check):
    if check:
        actual = {x.name: x.read_bytes() for x in destination.glob("*") if x.is_file()}
        if actual != output:
            raise SystemExit("Native provider fixtures differ from frozen pack. Regenerate.")
        print("PASS · provider pin and exact selected fixture bytes")
    else:
        destination.mkdir(parents=True, exist_ok=True)
        if {x.name for x in destination.iterdir()} - output.keys():
            raise SystemExit("Unexpected fixture projection files; reconcile before regeneration")
        for name, body in output.items():
            (destination / name).write_bytes(body)
        print("Generated selected native fixtures from frozen provider pack")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = generate()
    write_or_check(output, OUTPUT, args.check)
