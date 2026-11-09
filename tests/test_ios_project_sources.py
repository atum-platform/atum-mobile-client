"""Focused check that every App Swift source is in the generated Sources phase."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "ios/App"
PROJECT = ROOT / "ios/AtumMobile.xcodeproj/project.pbxproj"


class IOSProjectSourcesTests(unittest.TestCase):
    def test_every_app_swift_file_is_a_source_build_file(self):
        project = PROJECT.read_text()
        files = sorted(path for path in APP.rglob("*.swift") if path.is_file())
        self.assertTrue(files)
        missing = []
        for path in files:
            name = path.name
            reference = re.search(
                rf"\b[0-9A-F]{{24}} /\* {re.escape(name)} \*/ = \{{isa = PBXFileReference;",
                project,
            )
            build = re.search(
                rf"\b[0-9A-F]{{24}} /\* {re.escape(name)} in Sources \*/ = \{{isa = PBXBuildFile;",
                project,
            )
            membership = re.search(
                rf"\b[0-9A-F]{{24}} /\* {re.escape(name)} in Sources \*/,",
                project,
            )
            if not (reference and build and membership):
                missing.append(str(path.relative_to(ROOT)))
        self.assertEqual(missing, [], "App Swift files missing from generated Sources phase")

    def test_new_founder_raven_view_is_in_the_committed_project(self):
        project = PROJECT.read_text()
        self.assertIn("FounderRavenAvatar.swift in Sources", project)
        self.assertIn("FounderRavenAvatar.swift */ = {isa = PBXFileReference;", project)


if __name__ == "__main__":
    unittest.main()
