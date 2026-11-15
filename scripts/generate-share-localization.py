#!/usr/bin/env python3
"""Bind the share extension's picker words to imported desktop-owned copy.

The extension cannot load the app's 3 MB design bundle, so this projects only
the exported keys the picker uses into `ios/Share/ShareLocalizable.xcstrings`
(five locales, verbatim string units and plural variations). Words the export
does not have yet stay in `SharePendingCopy` (PENDING-COPY).

  generate-share-localization.py          regenerate the table
  generate-share-localization.py --check  fail if it differs from the pinned copy
"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "ios/Vendor/AtumDesign"
OUTPUT = ROOT / "ios/Share/ShareLocalizable.xcstrings"
LOCALES = {"en": "en", "vi": "vi", "ja": "ja", "zh": "zh-Hans", "zh-Hant": "zh-Hant"}
# Key -> the parameter kinds the picker passes (must equal the copy contract).
KEYS = {
    "src.matrix.chat-copy.copies.cancel": [],
    "src.matrix.chat-copy.copies.forwardSend": [],
    "src.matrix.chat-copy.copies.forwardSearch": [],
    "src.matrix.chat-copy.copies.forwardEmpty": [],
    "src.matrix.group-picker-copy.copies.recent": [],
    "src.matrix.group-picker-copy.copies.selected": ["number"],
    "desktop.atum.roster.title": [],
    "desktop.common.done": [],
    "src.matrix.mobile-copy.mobileChatCopy.photo": [],
    "src.matrix.mobile-copy.mobileChatCopy.media.kind.video": [],
    "src.matrix.mobile-copy.mobileChatCopy.file": [],
}


def generate():
    manifest = json.loads((VENDOR / "manifest.json").read_bytes())
    for name in ["Localizable.xcstrings", "copy-contract.json"]:
        if hashlib.sha256((VENDOR / name).read_bytes()).hexdigest() != manifest["files"][name]:
            raise ValueError("Imported desktop copy digest differs")
    if set(manifest["locales"]) != set(LOCALES):
        raise ValueError("Share locale coverage differs from imported copy")
    catalog = json.loads((VENDOR / "Localizable.xcstrings").read_bytes())["strings"]
    parameters = json.loads((VENDOR / "copy-contract.json").read_bytes())["parameters"]
    strings = {}
    for key, kinds in sorted(KEYS.items()):
        if [p["kind"] for p in parameters[key]] != kinds:
            raise ValueError(f"{key}: parameters differ from the picker's use")
        localizations = {}
        for original, native in LOCALES.items():
            unit = catalog[key]["localizations"][original]
            value = unit["stringUnit"]
            if value["state"] != "translated" or not value["value"]:
                raise ValueError(f"{key} ({original}) is not translated")
            if not kinds and "%" in value["value"]:
                raise ValueError(f"{key} ({original}) is unexpectedly parameterized")
            localizations[native] = unit
        strings[key] = {"comment": "Generated from pinned desktop copy: " + key,
                        "extractionState": "manual", "localizations": localizations}
    result = {"sourceLanguage": "en", "version": "1.0", "strings": strings}
    return (json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = generate()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_bytes() != output:
            raise SystemExit("Share picker localization differs from the imported copy")
        print(f"PASS · {len(KEYS)} share picker keys bound to five-locale desktop copy")
    else:
        OUTPUT.write_bytes(output)
        print(f"Generated {OUTPUT.relative_to(ROOT)} ({len(KEYS)} keys)")
