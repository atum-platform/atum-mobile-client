"""Source-only checks for the additive Founder SDK bridge candidate."""

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "sdk/phone-26.10.15-founder"
PENDING = PACK / "source.pending.json"
SPEC = importlib.util.spec_from_file_location(
    "refresh_phone_sdk_source_pin", ROOT / "scripts/refresh-phone-sdk-source-pin.py")
REFRESH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REFRESH)
PREPARE_SPEC = importlib.util.spec_from_file_location(
    "prepare_matrix_sdk", ROOT / "scripts/prepare-matrix-sdk.py")
PREPARE = importlib.util.module_from_spec(PREPARE_SPEC)
PREPARE_SPEC.loader.exec_module(PREPARE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FounderPhoneSDKSourceTests(unittest.TestCase):
    def test_founder_pack_keeps_the_historical_source_pack_and_is_the_app_pin(self):
        selected = json.loads((ROOT / "sdk/phone-26.10.15/source.json").read_text())
        pending = json.loads(PENDING.read_text())
        self.assertFalse(pending["runtimeSelected"])
        self.assertEqual(pending["status"], "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION")
        self.assertEqual(pending["upstreamRevision"], selected["upstreamRevision"])
        self.assertEqual(pending["licenseSHA256"], selected["licenseSHA256"])
        self.assertIsNone(pending["patchedSHA256"])
        self.assertEqual(digest(ROOT / pending["patch"]), pending["patchSHA256"])
        self.assertEqual(set(pending["preimageSHA256"]), {
            "bindings/matrix-sdk-ffi/src/room/mod.rs",
            "crates/matrix-sdk-ui/src/room_list_service/mod.rs",
            "crates/matrix-sdk-ui/tests/integration/room_list_service.rs",
            "crates/matrix-sdk/src/error.rs",
            "crates/matrix-sdk/tests/integration/send_queue.rs",
        })
        project = (ROOT / "ios/project.yml").read_text()
        self.assertIn("66c18d378d44d9ad61946f08b926514cccb14fb5", project)
        self.assertNotIn("cf18be30f10f0a6cea89d3aae93c6799af7edcde", project)

    def test_generated_source_manifest_records_the_exact_patch_and_hashes(self):
        pending = json.loads(PENDING.read_text())
        generated = json.loads((PACK / "source.json").read_text())
        self.assertEqual(generated["status"], "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED")
        self.assertFalse(generated["runtimeSelected"])
        self.assertEqual(generated["patchSHA256"], digest(ROOT / pending["patch"]))
        self.assertEqual(generated["patchSHA256"], pending["patchSHA256"])
        self.assertEqual(generated["preimageSHA256"], pending["preimageSHA256"])
        self.assertEqual(set(generated["patchedSHA256"]), set(pending["preimageSHA256"]))
        for value in generated["patchedSHA256"].values():
            self.assertRegex(value, r"^[0-9a-f]{64}$")

    def test_patch_adds_exact_required_state_and_authoritative_fetch_only(self):
        patch = (ROOT / json.loads(PENDING.read_text())["patch"]).read_text()
        self.assertEqual(patch.count('"io.atum.founder_chat"'), 16)
        self.assertIn(
            'const ATUM_REQUIRED_STATE: &[&str] = &["io.atum.conversation", '
            '"io.atum.app_bot.dm", "io.atum.founder_chat"];', patch)
        self.assertIn('let expected = ["io.atum.conversation", "io.atum.app_bot.dm", '
                      '"io.atum.founder_chat"];', patch)
        self.assertIn('["io.atum.founder_chat", ""]', patch)
        self.assertIn("fetch_global_account_data_raw", patch)
        self.assertIn(".fetch_account_data(event_type)", patch)
        self.assertNotIn(".fetch_account_data(&event_type)", patch)
        self.assertIn("event.map(|event| event.json().get().to_owned())", patch)
        self.assertIn("global_account_data_none_and_some_map_to_the_raw_json_boundary",
                      patch)
        self.assertNotIn('["*", "*"]', patch)
        self.assertNotIn("authedRequest", patch)
        self.assertNotIn("http://", patch)
        self.assertNotIn("https://", patch)

    def test_bootstrap_candidate_pin_hashes_only_the_exact_changed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "source"
            repo.mkdir()
            (repo / "file.txt").write_text("before\n")
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "fixture@example.test"],
                           cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Fixture"], cwd=repo, check=True)
            subprocess.run(["git", "add", "file.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=repo, check=True)
            (repo / "file.txt").write_text("after\n")
            pending = {
                "status": "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION",
                "patchedSHA256": None,
                "preimageSHA256": {
                    "file.txt": hashlib.sha256(b"before\n").hexdigest(),
                },
                "pendingGeneration": {"reason": "fixture"},
            }
            generated = PREPARE.candidate_pin(pending, repo)
            self.assertEqual(generated["status"], "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED")
            self.assertEqual(generated["patchedSHA256"]["file.txt"],
                             hashlib.sha256(b"after\n").hexdigest())
            self.assertNotIn("pendingGeneration", generated)

            (repo / "extra.txt").write_text("unexpected\n")
            with self.assertRaisesRegex(ValueError, "unexpected file set"):
                PREPARE.candidate_pin(pending, repo)

    def test_bootstrap_prepare_generates_and_verifies_before_any_compile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "upstream"
            repo.mkdir()
            (repo / "LICENSE").write_text("Apache-2.0 fixture\n")
            (repo / "file.txt").write_text("before\n")
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "fixture@example.test"],
                           cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Fixture"], cwd=repo, check=True)
            subprocess.run(["git", "add", "LICENSE", "file.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=repo, check=True)
            subprocess.run(["git", "remote", "add", "origin",
                            "https://example.test/sdk.git"], cwd=repo, check=True)
            revision = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True,
                stdout=subprocess.PIPE, text=True
            ).stdout.strip()
            (repo / "file.txt").write_text("after\n")
            patch_path = root / "fixture.patch"
            patch_path.write_text(subprocess.run(
                ["git", "diff", "--", "file.txt"], cwd=repo, check=True,
                stdout=subprocess.PIPE, text=True
            ).stdout)
            subprocess.run(["git", "checkout", "--", "file.txt"], cwd=repo, check=True)

            pending_path = root / "source.pending.json"
            pending_path.write_text(json.dumps({
                "schemaVersion": 1,
                "runtimeSelected": False,
                "status": "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION",
                "upstreamURL": "https://example.test/sdk.git",
                "upstreamRevision": revision,
                "license": "Apache-2.0",
                "licenseSHA256": digest(repo / "LICENSE"),
                "rustToolchain": "fixture",
                "patch": str(patch_path),
                "patchSHA256": digest(patch_path),
                "preimageSHA256": {"file.txt": hashlib.sha256(b"before\n").hexdigest()},
                "patchedSHA256": None,
                "pendingGeneration": {"reason": "fixture"},
            }, indent=2) + "\n")

            destination = root / "source"
            generated = root / "source.json"
            PREPARE.prepare(destination, source_cache=repo, pack="fixture",
                            bootstrap_manifest=pending_path,
                            bootstrap_output=generated)
            result = json.loads(generated.read_text())
            self.assertEqual(result["status"], "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED")
            self.assertEqual(result["patchedSHA256"]["file.txt"],
                             hashlib.sha256(b"after\n").hexdigest())
            receipt = json.loads((destination / "atum-source-receipt.json").read_text())
            self.assertEqual(receipt["status"], "SOURCE_PREPARED")
            self.assertEqual(receipt["sourcePack"], "fixture")
            self.assertEqual(receipt["sourceManifestSHA256"], digest(generated))
            self.assertTrue((destination / "file.txt").read_text() == "after\n")

    def _tiny_source(self, root):
        repo = root / "upstream"
        repo.mkdir()
        (repo / "LICENSE").write_text("Apache-2.0 fixture\n")
        (repo / "file.txt").write_text("before\n")
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.test"],
                       cwd=repo, check=True)
        subprocess.run(["git", "config", "user.name", "Fixture"], cwd=repo, check=True)
        subprocess.run(["git", "add", "LICENSE", "file.txt"], cwd=repo, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=repo, check=True)
        subprocess.run(["git", "remote", "add", "origin",
                        "https://example.test/sdk.git"], cwd=repo, check=True)
        revision = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo, check=True,
            stdout=subprocess.PIPE, text=True
        ).stdout.strip()
        (repo / "file.txt").write_text("after\n")
        patch = root / "fixture.patch"
        patch.write_text(subprocess.run(
            ["git", "diff", "--", "file.txt"], cwd=repo, check=True,
            stdout=subprocess.PIPE, text=True
        ).stdout)
        subprocess.run(["git", "checkout", "--", "file.txt"], cwd=repo, check=True)
        pending = {
            "schemaVersion": 1,
            "runtimeSelected": False,
            "status": "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION",
            "upstreamURL": "https://example.test/sdk.git",
            "upstreamRevision": revision,
            "license": "Apache-2.0",
            "licenseSHA256": digest(repo / "LICENSE"),
            "rustToolchain": "fixture",
            "patch": str(patch),
            "patchSHA256": digest(patch),
            "preimageSHA256": {"file.txt": hashlib.sha256(b"before\n").hexdigest()},
            "patchedSHA256": None,
            "pendingGeneration": {"reason": "fixture"},
        }
        pending_path = root / "source.pending.json"
        pending_path.write_text(json.dumps(pending, indent=2) + "\n")
        return repo, pending_path, pending

    def test_exact_candidate_prepare_cli_accepts_pack_with_source_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo, pending_path, pending = self._tiny_source(root)
            generated = root / "source.json"
            completed = subprocess.run(
                [sys.executable, "scripts/prepare-matrix-sdk.py",
                 str(root / "prepared"),
                 "--pack", "phone-26.10.15-founder",
                 "--source-cache", str(repo),
                 "--bootstrap-manifest", str(pending_path),
                 "--bootstrap-output", str(generated)],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(generated.read_text())
            self.assertEqual(result["patchedSHA256"]["file.txt"],
                             hashlib.sha256(b"after\n").hexdigest())
            self.assertEqual(result["upstreamRevision"], pending["upstreamRevision"])

    def test_candidate_cli_refuses_missing_manifest_without_argparse_error(self):
        with tempfile.TemporaryDirectory() as directory:
            completed = subprocess.run(
                [sys.executable, "scripts/prepare-matrix-sdk.py",
                 str(Path(directory) / "prepared"),
                 "--pack", "phone-26.10.15-founder"],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertNotIn("invalid choice", completed.stderr)
            self.assertIn("requires --bootstrap-manifest or --manifest",
                          completed.stderr)

    def test_selected_prepare_cli_still_accepts_the_default_pack(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "existing"
            destination.mkdir()
            completed = subprocess.run(
                [sys.executable, "scripts/prepare-matrix-sdk.py",
                 str(destination), "--pack", "phone-26.10.15"],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertNotIn("invalid choice", completed.stderr)
            self.assertIn("destination must be new", completed.stderr)

    def test_build_and_study_cli_accept_candidate_pack_and_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, pending_path, pending = self._tiny_source(root)
            generated = root / "generated.json"
            generated.write_text(json.dumps({
                **pending,
                "runtimeSelected": False,
                "status": "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED",
                "patchedSHA256": {relative: "a" * 64
                                  for relative in pending["preimageSHA256"]},
            }, indent=2) + "\n")
            artifact = root / "artifact"
            artifact.mkdir()
            build = subprocess.run(
                [sys.executable, "scripts/build-phone-matrix-sdk.py",
                 "--verify-only", str(artifact),
                 "--pack", "phone-26.10.15-founder",
                 "--manifest", str(generated)],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.assertNotEqual(build.returncode, 0)
            self.assertNotIn("invalid choice", build.stderr)

            study = subprocess.run(
                [sys.executable, "scripts/study-phone-matrix-sdk-app.py",
                 str(artifact), str(root / "study"), str(root / "study.json"),
                 "--pack", "phone-26.10.15-founder",
                 "--manifest", str(generated)],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            self.assertNotEqual(study.returncode, 0)
            self.assertNotIn("invalid choice", study.stderr)

    def test_refresh_generator_recomputes_real_patched_hashes_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / "sdk"
            repo.mkdir()
            (repo / "LICENSE").write_text("Apache-2.0 fixture\n")
            (repo / "file.txt").write_text("before\n")
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "fixture@example.test"],
                           cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Fixture"], cwd=repo, check=True)
            subprocess.run(["git", "add", "LICENSE", "file.txt"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=repo, check=True)
            subprocess.run(["git", "remote", "add", "origin",
                            "https://example.test/sdk.git"], cwd=repo, check=True)
            revision = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=repo, check=True,
                stdout=subprocess.PIPE, text=True
            ).stdout.strip()

            (repo / "file.txt").write_text("after\n")
            patch = subprocess.run(
                ["git", "diff", "--", "file.txt"], cwd=repo, check=True,
                stdout=subprocess.PIPE, text=True
            ).stdout
            patch_path = root / "founder.patch"
            patch_path.write_text(patch)
            subprocess.run(["git", "checkout", "--", "file.txt"], cwd=repo, check=True)

            pending_path = root / "source.pending.json"
            pending_path.write_text(json.dumps({
                "schemaVersion": 1,
                "runtimeSelected": False,
                "status": "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION",
                "upstreamURL": "https://example.test/sdk.git",
                "upstreamRevision": revision,
                "license": "Apache-2.0",
                "licenseSHA256": digest(repo / "LICENSE"),
                "rustToolchain": "fixture",
                "patch": str(patch_path),
                "patchSHA256": digest(patch_path),
                "preimageSHA256": {"file.txt": digest(repo / "file.txt")},
                "patchedSHA256": None,
                "pendingGeneration": {"reason": "fixture"},
            }, indent=2) + "\n")

            output = root / "source.json"
            REFRESH.refresh(repo, pending_path, output)
            result = json.loads(output.read_text())
            self.assertEqual(result["status"], "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED")
            self.assertEqual(result["patchedSHA256"]["file.txt"],
                             hashlib.sha256(b"after\n").hexdigest())
            self.assertNotIn("pendingGeneration", result)
            self.assertIn("generatedFrom", result)


if __name__ == "__main__":
    unittest.main()
