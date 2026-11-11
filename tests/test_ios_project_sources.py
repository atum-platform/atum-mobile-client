"""Focused check that every App Swift source is in the generated Sources phase."""

from pathlib import Path
import fnmatch
import importlib.util
import json
import plistlib
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "ios/App"
PROJECT = ROOT / "ios/AtumMobile.xcodeproj/project.pbxproj"


class IOSProjectSourcesTests(unittest.TestCase):
    @staticmethod
    def objects():
        return dict(re.findall(
            r"\t\t([0-9A-F]{24}) /\* .*? \*/ = \{\n(.*?)\n\t\t\};",
            PROJECT.read_text(), re.S,
        ))

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

    def test_release_excludes_debug_hosts_and_has_no_scripted_flags(self):
        objects = self.objects()
        target = next(value for value in objects.values()
                      if "isa = PBXNativeTarget;" in value and "name = AtumMobile;" in value)
        config_id = re.search(r"buildConfigurationList = ([0-9A-F]{24})", target)[1]
        release_id = re.search(r"([0-9A-F]{24}) /\* Release \*/", objects[config_id])[1]
        release = objects[release_id]
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS = "";', release)
        excluded = re.search(r"EXCLUDED_SOURCE_FILE_NAMES = \((.*?)\);", release, re.S)[1]
        patterns = [line.strip().rstrip(',').strip('"') for line in excluded.splitlines()]
        for path in [*APP.joinpath("Debug").glob("*.swift"),
                     *APP.rglob("Scripted*.swift")]:
            self.assertTrue(any(fnmatch.fnmatch(path.name, pattern) for pattern in patterns), path)
        for config in objects.values():
            if "name = Release;" in config:
                flags = re.findall(r"(?:SWIFT_ACTIVE_COMPILATION_CONDITIONS|OTHER_SWIFT_FLAGS) = (.*?);",
                                   config, re.S)
                self.assertNotRegex(" ".join(flags), r"DEBUG|SCRIPTED|ATUM_DEMO_RELEASE")
        self.assertNotIn("ATUM_DEMO_RELEASE", (APP / "AtumMobileApp.swift").read_text())

    def test_shared_scenarios_and_app_debug_sources_are_compile_time_debug_only(self):
        paths = [*APP.joinpath("Debug").glob("*.swift"),
                 *APP.rglob("Scripted*.swift"),
                 *ROOT.joinpath("ios/Sources/AtumChat/Scripted").glob("*.swift"),
                 ROOT / "ios/Sources/AtumChat/LaunchArguments.swift"]
        for path in paths:
            text = path.read_text().strip()
            self.assertTrue(text.startswith("#if DEBUG\n"), path)
            self.assertTrue(text.endswith("#endif"), path)
        spec = (ROOT / "ios/project.yml").read_text()
        app_spec = spec.split("  AtumMobile:\n", 1)[1].split("  AtumNotifications:\n", 1)[0]
        self.assertNotIn("AtumPrototype", app_spec)
        self.assertNotIn("Fixtures", app_spec)
        scheme = (PROJECT.parent / "xcshareddata/xcschemes/AtumMobile.xcscheme").read_text()
        self.assertRegex(scheme, r'TestAction\s+buildConfiguration = "Debug"')

    def test_privacy_manifests_are_bundled_in_their_own_targets(self):
        objects = self.objects()
        for target_name, directory in [("AtumMobile", "App"), ("AtumNotifications", "Notifications")]:
            target = next(value for value in objects.values()
                          if "isa = PBXNativeTarget;" in value and f"name = {target_name};" in value)
            phase_id = re.search(r"([0-9A-F]{24}) /\* Resources \*/", target)[1]
            # Each bundle must have one manifest, without duplicate basename resources.
            self.assertEqual(objects[phase_id].count("PrivacyInfo.xcprivacy in Resources"), 1)
            manifest = plistlib.loads((ROOT / f"ios/{directory}/PrivacyInfo.xcprivacy").read_bytes())
            self.assertFalse(manifest["NSPrivacyTracking"])
            self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])
            types = {item["NSPrivacyCollectedDataType"].removeprefix("NSPrivacyCollectedDataType"): item
                     for item in manifest["NSPrivacyCollectedDataTypes"]}
            required = {"Name", "UserID", "DeviceID", "EmailsOrTextMessages", "PhotosorVideos", "OtherUserContent"}
            if target_name == "AtumMobile":
                required |= {"EmailAddress", "PurchaseHistory", "CustomerSupport", "CrashData",
                             "OtherDiagnosticData", "ProductInteraction", "AudioData"}
            self.assertEqual(set(types), required)
            for item in types.values():
                self.assertFalse(item["NSPrivacyCollectedDataTypeTracking"])
                self.assertTrue(item["NSPrivacyCollectedDataTypePurposes"])
            for name in required - {"CrashData", "OtherDiagnosticData"}:
                self.assertTrue(types[name]["NSPrivacyCollectedDataTypeLinked"], name)
            reasons = {item["NSPrivacyAccessedAPIType"].removeprefix("NSPrivacyAccessedAPICategory"):
                       set(item["NSPrivacyAccessedAPITypeReasons"])
                       for item in manifest["NSPrivacyAccessedAPITypes"]}
            expected = {"FileTimestamp": {"C617.1"}}
            if target_name == "AtumMobile":
                expected.update(UserDefaults={"CA92.1"}, SystemBootTime={"35F9.1"}, DiskSpace={"E174.1"},
                                FileTimestamp={"C617.1", "3B52.1"})
            self.assertEqual(reasons, expected)

    def test_licences_screen_contains_complete_retained_legal_texts(self):
        spec = importlib.util.spec_from_file_location("ios_licences", ROOT / "scripts/generate-ios-licences.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        index = generator.OUTPUT.read_text()
        self.assertEqual(index, generator.render(), "Regenerate the bundled licence index")
        self.assertIn("ThirdPartyLicences.json in Resources", PROJECT.read_text())
        entries = json.loads(index)
        self.assertEqual(len(entries), len(generator.SOURCES))
        bodies = []
        for entry, (title, source) in zip(entries, generator.SOURCES):
            self.assertEqual(entry["title"], title)
            if entry["bundle"] == "design":
                self.assertEqual(source, "ios/Vendor/AtumDesign/" + entry["resource"])
                self.assertIn(entry["resource"], json.loads(
                    (ROOT / "ios/Vendor/AtumDesign/manifest.json").read_text())["files"])
            else:
                self.assertEqual(entry["resource"], Path(source).name)
                self.assertIn(entry["resource"] + " in Resources", PROJECT.read_text())
            bodies.append((ROOT / source).read_bytes().decode("utf-8"))
        text = "\n\n".join(bodies)
        # New licences in either inventory must not silently disappear from the screen.
        inventory = json.loads((ROOT / "THIRD-PARTY.json").read_text())
        paths = [*(ROOT / "LICENSES").glob("*"),
                 *(ROOT / path for path in inventory["notices"]
                   if Path(path).name == "LICENSE" or "-LICENSE.txt" in path)]
        for path in paths:
            self.assertIn(path.read_bytes().decode("utf-8"), text, str(path))
        for path in (APP / "Resources/ThirdPartyNotices").glob("*.txt"):
            self.assertIn(path.read_bytes().decode("utf-8"), text, str(path))
        self.assertNotIn((APP / "Resources/NOTICE").read_text(), text)
        screen = (APP / "Account/LegalScreens.swift").read_text()
        self.assertNotIn('forResource: "NOTICE"', screen)
        self.assertNotIn('AtumDesign.data(for: "ATTRIBUTION.md")', screen)


if __name__ == "__main__":
    unittest.main()
