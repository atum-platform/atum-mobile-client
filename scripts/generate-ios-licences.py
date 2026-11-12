#!/usr/bin/env python3
"""Index complete bundled legal texts without copying upstream author identifiers."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "ios/App/Resources/ThirdPartyLicences.json"
NOTICES = "ios/App/Resources/ThirdPartyNotices/"
SOURCES = [
    ("Atum original contributions — source terms", "LICENSE"),
    ("Matrix Rust SDK and Element X notification service — Apache License 2.0\n"
     "Element X: Copyright 2022, 2023 New Vector Ltd.\n"
     "Modifications: Copyright 2026 Anka Ventures Vietnam Company Limited.",
     "ios/App/Resources/MatrixRustSDK-LICENSE.txt"),
    ("Hermes Agent", "LICENSES/Hermes-Agent-MIT.txt"),
    ("Sentry Cocoa", NOTICES + "Sentry-LICENSE.txt"),
    ("Sentry Cocoa third-party licences", NOTICES + "Sentry-THIRD_PARTY_NOTICES.txt"),
    ("Textual", NOTICES + "Textual-LICENSE.txt"),
    ("SwiftUI Math", NOTICES + "SwiftUIMath-LICENSE.txt"),
    ("Swift Concurrency Extras", NOTICES + "ConcurrencyExtras-LICENSE.txt"),
    ("Prism", NOTICES + "Prism-LICENSE.txt"),
    ("Math fonts — copyright and licence notices", NOTICES + "MathFonts-EmbeddedNotices.txt"),
    ("Math fonts — MIT License", NOTICES + "MathFonts-MIT-LICENSE.txt"),
    ("Math fonts — SIL Open Font License", NOTICES + "MathFonts-OFL.txt"),
    ("Math fonts — GUST Font License", NOTICES + "MathFonts-GUST-FONT-LICENSE.txt"),
    ("Math fonts — LaTeX Project Public License", NOTICES + "MathFonts-LPPL-1.3c.txt"),
    ("Cormorant Garamond", "ios/Vendor/AtumDesign/fonts/CormorantGaramond-native-OFL.txt"),
]


def render():
    # The app already bundles upstream texts with their original filenames.
    # Reuse them verbatim instead of creating duplicate copies of legal notices.
    entries = [
        dict(title=title,
             bundle="design" if path.startswith("ios/Vendor/AtumDesign/") else "app",
             resource=path.removeprefix("ios/Vendor/AtumDesign/")
             if path.startswith("ios/Vendor/AtumDesign/") else Path(path).name)
        for title, path in SOURCES
    ]
    return json.dumps(entries, ensure_ascii=False, indent=2) + "\n"


if __name__ == "__main__":
    OUTPUT.write_bytes(render().encode("utf-8"))
