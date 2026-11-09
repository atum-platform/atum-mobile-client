"""The screenshot extraction plan, on a synthetic xcresulttool manifest. No Xcode run."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/extract-ui-screenshots.py"
loader = importlib.machinery.SourceFileLoader("extract_ui_screenshots", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
extract = importlib.util.module_from_spec(spec)
loader.exec_module(extract)

UUID = "8A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"


def attachment(exported, suggested, configuration="Configuration 1", failure=False):
    return {"exportedFileName": exported, "suggestedHumanReadableName": suggested,
            "isAssociatedWithFailure": failure, "configurationName": configuration,
            "deviceName": "iPhone 16 Pro", "deviceId": "00000000-SECRET-DEVICE"}


class ExtractUIScreenshotsTests(unittest.TestCase):
    def test_images_are_named_after_their_test_and_attachment(self):
        manifest = [{"testIdentifier": "LaunchUITests/testLaunches()", "attachments": [
            attachment("a1.png", f"launch_0_{UUID}.png")]}]
        copies = extract.plan(manifest, {"a1.png"})
        self.assertEqual([c.destination for c in copies], ["LaunchUITests.testLaunches--launch--Configuration-1.png"])
        self.assertEqual(copies[0].name, "launch")

    def test_only_exported_images_are_copied(self):
        manifest = [{"testIdentifier": "T/testA()", "attachments": [
            attachment("log.txt", "log.txt"), attachment("missing.png", "x.png"), attachment("b.jpeg", "open.jpeg")]}]
        copies = extract.plan(manifest, {"log.txt", "b.jpeg"})
        self.assertEqual([c.source for c in copies], ["b.jpeg"])
        self.assertTrue(copies[0].destination.endswith(".jpeg"))

    def test_repeated_names_never_overwrite_each_other(self):
        manifest = [{"testIdentifier": "T/testA()", "attachments": [
            attachment("1.png", "open.png"), attachment("2.png", "open.png"), attachment("3.png", "open.png")]}]
        destinations = [c.destination for c in extract.plan(manifest, {"1.png", "2.png", "3.png"})]
        self.assertEqual(len(set(destinations)), 3)

    def test_names_are_file_safe(self):
        self.assertEqual(extract.test_name("Chat Tests/test Ünïcode() "), "Chat-Tests.test-n-code")
        self.assertEqual(extract.attachment_name("../../etc/passwd.png"), "passwd")
        self.assertEqual(extract.attachment_name(f"dark mode, AX XXL_3_{UUID}.png"), "dark-mode-AX-XXL")

    def test_the_index_names_the_simulator_but_never_its_identifier(self):
        manifest = [{"testIdentifier": "T/testA()", "attachments": [attachment("1.png", "open.png", failure=True)]}]
        text = extract.index(extract.plan(manifest, {"1.png"}), "run.xcresult")
        self.assertIn("iPhone 16 Pro", text)
        self.assertIn("| yes |", text)
        self.assertNotIn("SECRET", text)

    def test_a_missing_bundle_stops(self):
        self.assertEqual(extract.main(["/nonexistent.xcresult", "/tmp/unused"]), 1)
        self.assertEqual(extract.main([]), 2)


if __name__ == "__main__":
    unittest.main()
