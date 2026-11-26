"""Every app environment key reaches the transcript's hosted rows, or says why not.

P4 hosts each chat row in its own UIKit collection cell. A cell's SwiftUI graph
does not inherit the chat screen's environment, so `TranscriptRowEnvironment`
(ios/App/Chat/Views/TranscriptView.swift) copies a fixed list of keys into it. A
new `@Entry` that a row reads but the list omits would silently fall back to its
default inside the transcript. This test fails when an `@Entry` declared under
ios/App is neither forwarded nor exempted below with a reason.

Standard library only.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
TRANSCRIPT = ROOT / "ios/App/Chat/Views/TranscriptView.swift"

# Keys that no transcript row reads, with the reason.
EXEMPT = {
    "showsConnectionGlyph": "the connection glyph is chat-screen chrome above the transcript",
    "protonTopUp": "Home's listing hire flow only",
}

_ENTRY = re.compile(r"@Entry\s+var\s+(\w+)")
_FORWARDED_BLOCK = re.compile(r"// forwarded-keys:begin(.*?)// forwarded-keys:end", re.S)
_KEY_PATH = re.compile(r"\\\.(\w+)")


def declared_entries():
    names = {}
    for path in sorted((ROOT / "ios/App").rglob("*.swift")):
        for name in _ENTRY.findall(path.read_text(encoding="utf-8")):
            names[name] = path.relative_to(ROOT).as_posix()
    return names


def forwarded_keys():
    block = _FORWARDED_BLOCK.search(TRANSCRIPT.read_text(encoding="utf-8"))
    if block is None:
        raise AssertionError("TranscriptView.swift lost its forwarded-keys markers")
    return set(_KEY_PATH.findall(block.group(1)))


class TranscriptRowEnvironmentTests(unittest.TestCase):
    def test_every_entry_is_forwarded_or_exempt(self):
        forwarded = forwarded_keys()
        missing = {
            name: where for name, where in declared_entries().items()
            if name not in forwarded and name not in EXEMPT
        }
        self.assertEqual(missing, {}, "forward these keys in TranscriptRowEnvironment.forwarded "
                                      "or exempt them here with a reason")

    def test_exemptions_are_still_declared_and_not_forwarded(self):
        declared = declared_entries()
        forwarded = forwarded_keys()
        for name in EXEMPT:
            self.assertIn(name, declared, f"{name} is exempt but no longer declared")
            self.assertNotIn(name, forwarded, f"{name} is both forwarded and exempt")

    def test_core_chat_keys_are_forwarded(self):
        forwarded = forwarded_keys()
        for name in ("chatTheme", "chatActions", "messageActions", "chatRowInteractions",
                     "chatMediaNamespace", "colorScheme", "dynamicTypeSize", "openURL"):
            self.assertIn(name, forwarded)


if __name__ == "__main__":
    unittest.main()
