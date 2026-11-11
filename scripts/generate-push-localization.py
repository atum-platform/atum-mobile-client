#!/usr/bin/env python3
"""Bind APNs and rich notification keys to imported desktop-owned copy."""
import argparse
import hashlib
import json
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "ios/Vendor/AtumDesign"
OUTPUT = ROOT / "ios/App/PushLocalizations/Localizable.xcstrings"
COPY_KEY = "src.matrix.mobile-copy.mobilePhoneCopy.genericNotification"
LOCALES = {"en": "en", "vi": "vi", "ja": "ja", "zh": "zh-Hans", "zh-Hant": "zh-Hant"}


def generate():
    # Reuse accepted full-pack digest validation, not a second schema engine.
    projected = runpy.run_path(str(ROOT / "scripts/generate-native-push-fixtures.py"))["generate"]()
    fixture = json.loads(projected["pusher-set-prod.request.json"])
    key = fixture["data"]["default_payload"]["aps"]["alert"]["loc-key"]
    manifest = json.loads((VENDOR / "manifest.json").read_bytes())
    for name in ["Localizable.xcstrings", "copy-contract.json"]:
        if hashlib.sha256((VENDOR / name).read_bytes()).hexdigest() != manifest["files"][name]:
            raise ValueError("Imported desktop copy digest differs")
    if set(manifest["locales"]) != set(LOCALES):
        raise ValueError("Notification locale coverage differs from imported copy")
    if json.loads((VENDOR / "copy-contract.json").read_bytes())["parameters"][COPY_KEY] != []:
        raise ValueError("Generic notification must need no sender/content arguments")
    source = json.loads((VENDOR / "Localizable.xcstrings").read_bytes())["strings"][COPY_KEY]
    localizations = {}
    for original, native in LOCALES.items():
        unit = source["localizations"][original]["stringUnit"]
        if unit["state"] != "translated" or not unit["value"] or "%" in unit["value"]:
            raise ValueError("Generic notification copy is incomplete or parameterized")
        localizations[native] = {"stringUnit": unit}
    result = {"sourceLanguage": "en", "version": "1.0", "strings": {key: {
        "comment": "Generated from pinned desktop copy: " + COPY_KEY,
        "extractionState": "manual", "localizations": localizations}}}
    rich_keys = {
        "ATUM_PUSH_UNNAMED": "src.matrix.conversation-copy.copies.unnamed",
        **{"ATUM_PUSH_" + kind.upper(): "src.matrix.mobile-copy.mobileChatCopy.home.preview." + source
           for kind, source in {"image": "photo", "video": "video", "audio": "audio", "file": "file",
                                "sticker": "sticker", "invite": "invite"}.items()},
    }
    catalog = json.loads((VENDOR / "Localizable.xcstrings").read_bytes())["strings"]
    parameters = json.loads((VENDOR / "copy-contract.json").read_bytes())["parameters"]
    for key, source_key in rich_keys.items():
        if parameters[source_key] != []:
            raise ValueError("Rich notification copy must need no arguments")
        translations = {}
        for original, native in LOCALES.items():
            unit = catalog[source_key]["localizations"][original]["stringUnit"]
            if unit["state"] != "translated" or not unit["value"] or "%" in unit["value"]:
                raise ValueError("Rich notification copy is incomplete or parameterized")
            translations[native] = {"stringUnit": unit}
        result["strings"][key] = {"comment": "Generated from pinned desktop copy: " + source_key,
                                  "extractionState": "manual", "localizations": translations}
    return (json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = generate()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_bytes() != output:
            raise SystemExit("Native notification localization differs from accepted contract/imported copy")
        print("PASS · APNs key and five-locale desktop copy binding")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_bytes(output)
        print("Generated main-app generic notification localization from existing copy")
