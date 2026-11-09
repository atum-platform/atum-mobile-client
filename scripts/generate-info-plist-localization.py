#!/usr/bin/env python3
"""Project the exported permission explanations into InfoPlist.xcstrings."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ios/Vendor/AtumDesign/Localizable.xcstrings"
OUTPUT = ROOT / "ios/App/InfoPlist.xcstrings"
COPY_KEY = "src.matrix.mobile-copy.mobilePhoneCopy.photoLibraryAddUsage"
PLIST_KEY = "NSPhotoLibraryAddUsageDescription"
# Composer dictation (2026-10-24): exported with the phone copy; projected when
# present in the export.
PENDING_COPY_KEYS = {
    "NSMicrophoneUsageDescription": "src.matrix.mobile-copy.mobilePhoneCopy.microphoneUsage",
    "NSSpeechRecognitionUsageDescription": "src.matrix.mobile-copy.mobilePhoneCopy.speechRecognitionUsage",
}


def projected_catalog(source: dict) -> dict:
    strings = {PLIST_KEY: source["strings"][COPY_KEY]}
    for plist_key, copy_key in PENDING_COPY_KEYS.items():
        if copy_key in source["strings"]:
            strings[plist_key] = source["strings"][copy_key]
    return {
        "sourceLanguage": source["sourceLanguage"],
        "strings": strings,
        "version": "1.0",
    }


def main() -> None:
    source = json.loads(SOURCE.read_text())
    value = projected_catalog(source)
    OUTPUT.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
