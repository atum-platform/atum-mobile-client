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
# lands in the pin; add one only if its reader already guards it or gains a guard.
PENDING = {
    "src.matrix.mobile-device-copy.mobileDeviceCopy.dictationListening",
    "src.matrix.model-picker-copy.COPY.taglineEveryday",
    "src.matrix.model-picker-copy.COPY.taglineHard",
    "src.matrix.model-picker-copy.COPY.taglineFlagship",

    # App panel pages
    "src.matrix.app-bots.panel.panelCopy.failed",
    "src.matrix.app-bots.panel.panelCopy.noScreens",
    "src.matrix.app-bots.panel.panelCopy.openIn",

    # Team Space Activity, Drafts, pinned messages, and saved messages
    "src.matrix.team-space.activity-copy.copy.all",
    "src.matrix.team-space.activity-copy.copy.emptyAllBody",
    "src.matrix.team-space.activity-copy.copy.emptyAllTitle",
    "src.matrix.team-space.activity-copy.copy.emptyMentionsBody",
    "src.matrix.team-space.activity-copy.copy.emptyMentionsTitle",
    "src.matrix.team-space.activity-copy.copy.failed",
    "src.matrix.team-space.activity-copy.copy.filterLabel",
    "src.matrix.team-space.activity-copy.copy.loadMore",
    "src.matrix.team-space.activity-copy.copy.mention",
    "src.matrix.team-space.activity-copy.copy.mentions",
    "src.matrix.team-space.activity-copy.copy.open",
    "src.matrix.team-space.activity-copy.copy.someone",
    "src.matrix.team-space.activity-copy.copy.threadReply",
    "src.matrix.team-space.activity-copy.copy.title",
    "src.matrix.team-space.activity-copy.copy.unread",
    "src.matrix.team-space.drafts-copy.copy.emptyBody",
    "src.matrix.team-space.drafts-copy.copy.emptyTitle",
    "src.matrix.team-space.drafts-copy.copy.failed",
    "src.matrix.team-space.drafts-copy.copy.open",
    "src.matrix.team-space.drafts-copy.copy.roomDraft",
    "src.matrix.team-space.drafts-copy.copy.threadDraft",
    "src.matrix.team-space.drafts-copy.copy.title",
    "src.matrix.team-space.pinned-copy.copy.noPinnedMessages",
    "src.matrix.team-space.pinned-copy.copy.pinnedMessageCount.one",
    "src.matrix.team-space.pinned-copy.copy.pinnedMessageCount.other",
    "src.matrix.team-space.pinned-copy.copy.pinnedMessageUnavailable",
    "src.matrix.team-space.pinned-copy.copy.pinnedMessages",
    "src.matrix.team-space.saved-messages-copy.copy.emptyBody",
    "src.matrix.team-space.saved-messages-copy.copy.emptyTitle",
    "src.matrix.team-space.saved-messages-copy.copy.failed",
    "src.matrix.team-space.saved-messages-copy.copy.title",
    "src.matrix.team-space.saved-messages-copy.copy.unavailable",
    "src.matrix.team-space.saved-messages-copy.copy.unavailableBody",
    "src.matrix.team-space.saved-messages-copy.copy.you",

    # Company and room threads
    "src.matrix.team-space.company-threads-copy.copy.actionFailed",
    "src.matrix.team-space.company-threads-copy.copy.emptyFollowingBody",
    "src.matrix.team-space.company-threads-copy.copy.emptyFollowingTitle",
    "src.matrix.team-space.company-threads-copy.copy.emptyRecentBody",
    "src.matrix.team-space.company-threads-copy.copy.emptyRecentTitle",
    "src.matrix.team-space.company-threads-copy.copy.emptyUnreadBody",
    "src.matrix.team-space.company-threads-copy.copy.emptyUnreadTitle",
    "src.matrix.team-space.company-threads-copy.copy.filterLabel",
    "src.matrix.team-space.company-threads-copy.copy.follow",
    "src.matrix.team-space.company-threads-copy.copy.following",
    "src.matrix.team-space.company-threads-copy.copy.lastReply",
    "src.matrix.team-space.company-threads-copy.copy.loadMore",
    "src.matrix.team-space.company-threads-copy.copy.markRead",
    "src.matrix.team-space.company-threads-copy.copy.noPreview",
    "src.matrix.team-space.company-threads-copy.copy.open",
    "src.matrix.team-space.company-threads-copy.copy.recent",
    "src.matrix.team-space.company-threads-copy.copy.replies.one",
    "src.matrix.team-space.company-threads-copy.copy.replies.other",
    "src.matrix.team-space.company-threads-copy.copy.title",
    "src.matrix.team-space.company-threads-copy.copy.unfollow",
    "src.matrix.team-space.company-threads-copy.copy.unread",
    "src.matrix.thread-copy.copy.lastReply",
    "src.matrix.thread-copy.copy.reply",
    "src.matrix.thread-copy.copy.thread",
    "src.matrix.thread-copy.copy.threadOptions",

    # Drive folder search
    "src.matrix.mobile-copy.mobilePhoneCopy.drive.searchFolderOnly",
}

# These fallback tables declare their keys separately from their guarded readers.
PENDING_TABLE_READERS = {
    ROOT / "ios/App/Company/TeamSpacePendingCopy.swift": ROOT / "ios/App/Company/TeamSpaceCopy.swift",
    ROOT / "ios/App/Company/TeamSpaceThreadsPendingCopy.swift": ROOT / "ios/App/Company/CompanyThreadsCopy.swift",
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
                reader = PENDING_TABLE_READERS.get(path, path)
                source = reader.read_text()
                if reader != path:
                    self.assertIn(f"{path.stem}.tables[", source,
                                  f"{reader.relative_to(ROOT)} no longer uses {path.name}")
                self.assertIn("copy.contains(", source,
                              f"{key} is pending but {reader.relative_to(ROOT)} never checks the pin")

    def test_the_phone_does_not_reference_retired_work_copy(self):
        work = "src.matrix.mobile-copy.mobileScreensCopy.work."
        plan_row = work + "planRow"
        consent = work + "consent"
        references = [
            f"{path.relative_to(ROOT)}:{number}: {key}"
            for key, path, number in key_literals()
            if key == plan_row or key == consent or key.startswith(consent + ".")
        ]
        self.assertEqual(references, [], "retired Work copy is unavailable in the desktop export")

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
