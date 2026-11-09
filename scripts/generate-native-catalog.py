#!/usr/bin/env python3
"""Promote the approved P1 catalog to typed, source-owned native fixtures.

No Vendor bytes are modified. Product strings resolve through the committed
desktop copy export; proposal IDs and developer behavior notes never enter UI.
The staged producer map is a migration input that also carries phone copy used
under stable keys outside this catalog, so it may hold proposals beyond the
catalog as long as every catalog proposal stays covered and value-verified.
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/design/screen-catalog.json"
VENDOR = ROOT / "ios/Vendor/AtumDesign"
OUTPUT = ROOT / "ios/Sources/AtumPrototype/Fixtures/native-catalog.json"


def generate():
    source_bytes = SOURCE.read_bytes()
    source = json.loads(source_bytes)
    promotion = json.loads((VENDOR / "phone-copy-map.json").read_bytes())
    strings = json.loads((VENDOR / "Localizable.xcstrings").read_bytes())["strings"]
    contracts = json.loads((VENDOR / "copy-contract.json").read_bytes())["parameters"]
    locales = json.loads((VENDOR / "manifest.json").read_bytes())["locales"]
    ids = {screen["id"] for screen in source["screens"]}
    if len(ids) != len(source["screens"]):
        raise ValueError("Duplicate screen ID")
    missing = set(source["copyProposals"]) - set(promotion["mapping"])
    if missing:
        raise ValueError(f"Approved source proposals missing from migration mapping: {sorted(missing)[:8]}")
    for proposal, values in source["copyProposals"].items():
        key = promotion["mapping"][proposal]
        for locale, value in values.items():
            if strings[key]["localizations"][locale]["stringUnit"]["value"] != value:
                raise ValueError(f"Proposal text differs from promoted source: {proposal}/{locale}")

    def text(value, args=()):
        key = promotion["mapping"].get(value, value)
        if key.startswith("proposal."):
            raise ValueError(f"Unpromoted copy: {key}")
        if key in strings:
            parameters = contracts[key]
            if len(parameters) != len(args):
                raise ValueError(f"Incorrect argument count: {key}")
            for argument, parameter in zip(args, parameters):
                actual = "string" if isinstance(argument, str) else "number" if type(argument) is int else None
                if actual != parameter["kind"] or parameter["nullable"]:
                    raise ValueError(f"Unsupported argument contract: {key}")
            for locale in locales:
                if locale not in strings[key]["localizations"]:
                    raise ValueError(f"Missing locale: {key}/{locale}")
            return {"key": key, "arguments": list(args)}
        if key.startswith(("desktop.", "src.", "shared.")) or args:
            raise ValueError(f"Missing source-owned copy: {key}")
        return {"literal": key}

    def row(value):
        route = value["route"]
        if route and route not in ids:
            raise ValueError(f"Unknown route: {route}")
        return {
            "label": text(value["label"], value.get("args", [])),
            "detail": text(value.get("detail", "")),
            "value": text({
                "On": "desktop.common.on", "Off": "desktop.common.off",
                "You": "src.matrix.roster-copy.copies.you",
                "Member": "shared.matrix-company-copy.copy.member",
                "Selected": "src.matrix.mobile-device-copy.mobileDeviceCopy.uiSelected",
            }.get(value.get("value", ""), value.get("value", ""))),
            "route": route,
            "style": value.get("style", ""),
        }

    result = {
        "schemaVersion": 1,
        "approvedDesignCommit": promotion["approvedDesignCommit"],
        "sourceSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "uiCopy": {name: text(key) for name, key in source["uiCopy"].items()},
        "screens": [{
            "id": screen["id"], "family": screen["family"], "kind": screen["kind"],
            "title": text(screen["title"]), "body": text(screen["body"]),
            "rows": [row(value) for value in screen["rows"]],
            "inputs": [row(value) for value in screen["inputs"]],
            "actions": [row(value) for value in screen["actions"]],
            "states": [{"id": state["id"], "studyLabel": state["label"],
                        "text": text(state["text"]), "actions": [row(value) for value in state["actions"]]}
                       for state in screen["states"]],
        } for screen in source["screens"]],
    }
    return (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generated = generate()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_bytes() != generated:
            raise SystemExit("Native catalog differs from approved source/pinned copy. Regenerate it.")
        print("PASS · exact source-to-native catalog and five-locale argument contracts")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_bytes(generated)
        print("Generated native catalog from approved source and pinned copy")
