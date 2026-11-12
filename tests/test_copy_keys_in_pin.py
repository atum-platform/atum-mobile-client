"""Every copy key the phone names must be in the pinned export.

`LiveDesign.text` stops the app on a key the pin does not carry, and `AtumCopy.text`
needs the key in both `Localizable.xcstrings` and the `copy-contract.json`
parameters. Swift tests only reach the enums they list; this reads every key literal
in the shipped Swift sources, so a mistyped or not-yet-exported key fails CI.
A literal ending in "." is a prefix completed at run time; it cannot be checked here
and stays the job of its own Swift test or `copy.contains` guard.
"""

from pathlib import Path
import json
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "ios/Vendor/AtumDesign"
SOURCES = [ROOT / "ios/App", ROOT / "ios/Sources", ROOT / "ios/Notifications"]
KEY = re.compile(r'"((?:desktop|src|shared)\.[A-Za-z0-9_.\-=]+)"')

# Keys the pin does not carry yet. Each is read only after `design.copy.contains`
# says it is there, with a fallback or nothing shown. Remove an entry once the key
# lands in the pin; add one only together with that guard.
PENDING = {
    "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationListening",
    "src.matrix.model-picker-copy.COPY.taglineEveryday",
    "src.matrix.model-picker-copy.COPY.taglineHard",
    "src.matrix.model-picker-copy.COPY.taglineFlagship",
}


def pinned_keys():
    strings = json.loads((VENDOR / "Localizable.xcstrings").read_text())["strings"]
    parameters = json.loads((VENDOR / "copy-contract.json").read_text())["parameters"]
    return set(strings) & set(parameters)


def key_literals():
    for directory in SOURCES:
        for path in sorted(directory.rglob("*.swift")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for match in KEY.finditer(line):
                    yield match.group(1), path, number


def missing(pinned, literals):
    """Literals that would stop the app: neither pinned, a root of pinned keys
    (`root + ".consent"`), nor a guarded pending key. Prefixes ending in "." are skipped."""
    found = []
    for key, path, number in literals:
        if key.endswith("."):
            continue
        if key in pinned or key in PENDING or any(k.startswith(key + ".") for k in pinned):
            continue
        found.append(f"{path.relative_to(ROOT)}:{number}: {key}")
    return found


class CopyKeysInPinTests(unittest.TestCase):
    def test_every_copy_key_in_the_app_is_in_the_pinned_export(self):
        literals = list(key_literals())
        self.assertGreater(len(literals), 100, "found too few copy keys; is the pattern stale?")
        self.assertEqual(missing(pinned_keys(), literals), [],
                         "copy keys missing from ios/Vendor/AtumDesign; add them to the atum-desktop "
                         "export and re-pin, or fix the key")

    def test_pending_keys_are_read_behind_a_contains_guard(self):
        files = {}
        for key, path, _ in key_literals():
            if key in PENDING:
                files.setdefault(key, set()).add(path)
        self.assertEqual(set(files), PENDING, "a PENDING key is no longer named in the app")
        for key, paths in files.items():
            for path in paths:
                self.assertIn("copy.contains(", path.read_text(),
                              f"{key} is pending but {path.relative_to(ROOT)} never checks the pin")

    def test_a_missing_key_is_reported(self):
        pinned = {"src.matrix.group-picker-copy.copies.block.full"}
        path = ROOT / "ios/App/Home/HomeScreen.swift"
        self.assertEqual(
            missing(pinned, [("src.matrix.group-picker-copy.copies.full", path, 1)]),
            ["ios/App/Home/HomeScreen.swift:1: src.matrix.group-picker-copy.copies.full"],
        )
        self.assertEqual(
            missing(pinned, [("src.matrix.group-picker-copy.copies.block.full", path, 1),
                             ("src.matrix.group-picker-copy.copies.", path, 2),
                             ("src.matrix.group-picker-copy.copies.block", path, 3),
                             ("src.matrix.unexported-copy.", path, 4)]),
            [],
        )


if __name__ == "__main__":
    unittest.main()
