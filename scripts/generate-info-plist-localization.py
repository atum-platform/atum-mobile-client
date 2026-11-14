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

# Phone approvals slice 2b (docs/ports/phone-approvals-2b.md): PENDING-COPY.
# The export key is proposed; until the export carries it, the phone's five
# locales below (en and vi from the UX document, the rest phone-written,
# mirrored in PhoneApprovalPendingCopy.faceIDUsage) are projected instead.
FACE_ID_COPY_KEY = "src.matrix.mobile-device-copy.mobileDeviceCopy.approvalFaceIDUsage"
FACE_ID_PENDING = {
    "en": "Atum uses Face ID so only you can approve what your assistants ask to do.",
    "ja": "アシスタントが求める操作をあなただけが許可できるよう、Atum は Face ID を使用します。",
    "vi": "Atum dùng Face ID để chỉ bạn mới có thể cho phép những việc trợ lý xin làm.",
    "zh": "Atum 使用面容 ID，确保只有你能批准助手请求执行的操作。",
    "zh-Hant": "Atum 使用 Face ID，確保只有你能核准助理請求執行的操作。",
}


def pending_entry(values: dict) -> dict:
    return {"localizations": {locale: {"stringUnit": {"state": "translated", "value": value}}
                              for locale, value in values.items()}}


def projected_catalog(source: dict) -> dict:
    strings = {PLIST_KEY: source["strings"][COPY_KEY]}
    for plist_key, copy_key in PENDING_COPY_KEYS.items():
        if copy_key in source["strings"]:
            strings[plist_key] = source["strings"][copy_key]
    strings["NSFaceIDUsageDescription"] = source["strings"].get(FACE_ID_COPY_KEY) or pending_entry(FACE_ID_PENDING)
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
