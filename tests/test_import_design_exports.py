"""Exercise committed Git artifacts and real filesystem replacement, no network."""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/import-design-exports"
loader = importlib.machinery.SourceFileLoader("importer", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
importer = importlib.util.module_from_spec(spec)
loader.exec_module(importer)


def exports():
    files = {path: b"{}\n" for path in importer.REQUIRED}
    files["ATTRIBUTION.md"] = b"Test assets; no third-party content.\n"
    files["fixtures/phone.json"] = b'{"schemaVersion":1}\n'
    files["marks/eclipse.json"] = b'{"viewBox":[0,0,64,64]}\n'
    files["Localizable.xcstrings"] = importer.json_bytes({
        "sourceLanguage": "vi", "version": "1.0", "strings": {
            "phone.trust": {"localizations": {
                locale: {"stringUnit": {"state": "translated", "value": "Test"}}
                for locale in importer.LOCALES
            }}
        }
    })
    return remanifest(files)


def remanifest(files, schema=1):
    files["manifest.json"] = importer.json_bytes({
        "schemaVersion": schema, "developmentLanguage": "vi",
        "locales": sorted(importer.LOCALES),
        "files": {path: importer.digest(data) for path, data in files.items() if path != "manifest.json"}
    })
    return files


class ImportDesignTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.mobile = self.root / "mobile"
        self.mobile.mkdir()
        self.repo = self.root / "desktop"
        self.repo.mkdir()
        self.git("init", "--quiet")
        hooks = self.root / "empty-hooks"
        hooks.mkdir()
        self.git("config", "core.hooksPath", str(hooks))
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "user.name", "Atum fixture")
        self.git("config", "user.email", "fixture@atum.invalid")
        self.git("remote", "add", "origin", "https://github.com/atum-platform/atum-desktop.git")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args]).decode().strip()

    def commit(self, files):
        folder = self.repo / importer.PREFIX
        folder.mkdir(parents=True, exist_ok=True)
        for path, data in files.items():
            target = folder / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Disposable generated export fixture")
        return self.git("rev-parse", "HEAD")

    def test_import_reads_requested_commit_not_working_tree_and_verifies_offline(self):
        files = exports()
        revision = self.commit(files)
        (self.repo / importer.PREFIX / "colors.json").write_bytes(b"uncommitted corruption")
        loaded = importer.read_export(self.repo, revision)
        self.assertEqual(loaded, files)
        importer.install(self.mobile, loaded, revision)
        pin = importer.verify(self.mobile)
        self.assertEqual(pin["revision"], revision)
        self.assertEqual(pin["manifestSha256"], importer.digest(files["manifest.json"]))

    def test_bad_hash_and_new_schema_preserve_previous_pin(self):
        original = exports()
        revision = self.commit(original)
        importer.install(self.mobile, original, revision)
        old_pin = (self.mobile / "atum-design.lock").read_bytes()
        bad = dict(original)
        bad["colors.json"] = b"tampered"
        with self.assertRaisesRegex(importer.ImportFailure, "Hash mismatch"):
            importer.install(self.mobile, bad, "b" * 40)
        with self.assertRaisesRegex(importer.ImportFailure, "Unsupported"):
            importer.install(self.mobile, remanifest(dict(original), 999), "b" * 40)
        self.assertEqual((self.mobile / "atum-design.lock").read_bytes(), old_pin)
        self.assertEqual(importer.verify(self.mobile)["revision"], revision)

    def test_kit_tokens_are_required(self):
        files = exports()
        del files["atum-kit-tokens.json"]
        remanifest(files)
        with self.assertRaisesRegex(importer.ImportFailure, "Incomplete design-export manifest"):
            importer.validate(files)

    def test_interrupted_lock_replace_rolls_back_resources_and_pin(self):
        original = exports()
        revision = self.commit(original)
        importer.install(self.mobile, original, revision)
        changed = dict(original)
        changed["colors.json"] = b'{"changed":true}\n'
        remanifest(changed)
        real_replace = importer.os.replace
        def interrupted(source, target):
            if Path(source).name == "lock":
                raise OSError("Injected write interruption")
            return real_replace(source, target)
        with patch.object(importer.os, "replace", interrupted):
            with self.assertRaises(OSError):
                importer.install(self.mobile, changed, "b" * 40)
        self.assertEqual(importer.verify(self.mobile)["revision"], revision)
        self.assertEqual((self.mobile / "ios/Vendor/AtumDesign/colors.json").read_bytes(), original["colors.json"])

    def test_unsafe_paths_unlisted_files_symlinks_and_wrong_origin_are_refused(self):
        for path in ("../escape", "/absolute", "marks/../../escape", "marks\\escape", ".git/config"):
            with self.subTest(path=path), self.assertRaises(importer.ImportFailure):
                importer.safe_path(path)
        files = exports()
        revision = self.commit(files)
        files["unlisted.json"] = b"{}"
        with self.assertRaisesRegex(importer.ImportFailure, "Unlisted"):
            importer.validate(files)
        self.git("remote", "set-url", "origin", "https://github.com/another/fork.git")
        with self.assertRaisesRegex(importer.ImportFailure, "canonical"):
            importer.read_export(self.repo, revision)
        self.git("remote", "set-url", "origin", "https://github.com/atum-platform/atum-desktop.git")
        (self.repo / importer.PREFIX / "link").symlink_to("colors.json")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Symlink fixture")
        with self.assertRaisesRegex(importer.ImportFailure, "archive entry"):
            importer.read_export(self.repo, self.git("rev-parse", "HEAD"))

    def test_missing_locale_and_duplicate_json_key_are_rejected(self):
        files = exports()
        catalog = importer.parse_json(files["Localizable.xcstrings"])
        del catalog["strings"]["phone.trust"]["localizations"]["ja"]
        files["Localizable.xcstrings"] = importer.json_bytes(catalog)
        remanifest(files)
        with self.assertRaisesRegex(importer.ImportFailure, "five locales"):
            importer.validate(files)
        for schema in (True, "1", None):
            with self.subTest(schema=schema), self.assertRaisesRegex(importer.ImportFailure, "Unsupported"):
                importer.validate(remanifest(exports(), schema))
        with self.assertRaisesRegex(importer.ImportFailure, "Duplicate"):
            importer.parse_json(b'{"schemaVersion":1,"schemaVersion":2}')

    @unittest.skipUnless(hasattr(os, "mkfifo"), "Requires a POSIX filesystem")
    def test_offline_verification_rejects_non_regular_extra_entries(self):
        files = exports()
        revision = self.commit(files)
        importer.install(self.mobile, files, revision)
        os.mkfifo(self.mobile / "ios/Vendor/AtumDesign/unlisted.pipe")
        with self.assertRaisesRegex(importer.ImportFailure, "regular files"):
            importer.verify(self.mobile)

    def test_public_https_and_ssh_origins_are_accepted_private_donor_is_rejected(self):
        revision = self.commit(exports())
        for origin in ("https://github.com/atum-platform/atum-desktop.git",
                       "https://github.com/atum-platform/atum-desktop",
                       "git@github.com:atum-platform/atum-desktop.git"):
            with self.subTest(origin=origin):
                self.git("remote", "set-url", "origin", origin)
                self.assertEqual(importer.read_export(self.repo, revision), exports())
        self.git("remote", "set-url", "origin", "https://github.com/atum-platform/atum-app.git")
        with self.assertRaisesRegex(importer.ImportFailure, "canonical"):
            importer.read_export(self.repo, revision)
