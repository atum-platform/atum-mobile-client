"""Pure safety checks for the derived LC4 app/linkage study."""

import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import stat
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "study_phone_matrix_sdk_app", ROOT / "scripts/study-phone-matrix-sdk-app.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PhoneSDKAppStudyTests(unittest.TestCase):
    def test_cli_routes_positions_and_archive_overrides_are_fail_closed(self):
        with mock.patch.object(MODULE, "build") as build:
            MODULE.main(["artifact", "workspace", "receipt"])
        build.assert_called_once_with(Path("artifact"), Path("workspace"), Path("receipt"),
                                      MODULE.sdk_builder.DEFAULT_PACK, None)
        with mock.patch.object(MODULE, "build") as build:
            MODULE.main(["artifact", "workspace", "receipt",
                         "--pack", MODULE.sdk_builder.CANDIDATE_PACK,
                         "--manifest", "generated-source.json"])
        build.assert_called_once_with(Path("artifact"), Path("workspace"), Path("receipt"),
                                      MODULE.sdk_builder.CANDIDATE_PACK,
                                      Path("generated-source.json"))
        self.assertIn(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ATUM_DEMO_RELEASE",
            MODULE.ARCHIVE_OVERRIDES,
        )
        for value in ("CODE_SIGN_IDENTITY=", "PROVISIONING_PROFILE_SPECIFIER=",
                      "CODE_SIGN_ENTITLEMENTS="):
            self.assertIn(value, MODULE.ARCHIVE_OVERRIDES)

        source = (ROOT / "scripts/study-phone-matrix-sdk-app.py").read_text()
        self.assertIn('"platform=iOS Simulator,name=iPhone 17"', source)
        self.assertNotIn("name=iPhone 17,OS=27.0", source)

    def test_private_log_allows_an_existing_workspace_and_starts_mode_600(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "build.log"
            with MODULE.private_log(path) as handle:
                handle.write("diagnostic")
            MODULE.record_failure(Path(directory), ValueError("linkage missing"))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertIn("ValueError: linkage missing", path.read_text())

    def test_project_replacement_is_exact(self):
        self.assertEqual(MODULE.replace_once("old", "old", "new"), "new")
        for value in ("missing", "old old"):
            with self.assertRaisesRegex(ValueError, "shape changed"):
                MODULE.replace_once(value, "old", "new")

    def _stage_derived_project(self, root):
        project = root / "ios"
        (project / "App").mkdir(parents=True)
        (project / "AtumMobile.xcodeproj").mkdir()
        shutil.copyfile(ROOT / "ios/project.yml", project / "project.yml")
        shutil.copyfile(ROOT / "ios/App/Info.plist", project / "App/Info.plist")
        shutil.copyfile(
            ROOT / "ios/AtumMobile.xcodeproj/project.pbxproj",
            project / "AtumMobile.xcodeproj/project.pbxproj",
        )
        return project

    def _rewrite_once(self, text, old, new):
        self.assertEqual(text.count(old), 1)
        return text.replace(old, new)

    def _new_derived_project(self, root):
        project = self._stage_derived_project(root)
        (root / "artifact").mkdir()
        MODULE.rewrite_project(project, root / "artifact", "receipt-digest")
        return project

    def test_committed_project_is_rewritten_to_the_local_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self._new_derived_project(root)
            artifact = root / "artifact"

            manifest = (project / "project.yml").read_text()
            self.assertIn(f'    path: "{artifact!s}"', manifest)
            self.assertNotIn(MODULE.SDK_URL, manifest)
            self.assertEqual(
                manifest.count("      - package: MatrixRustSDK\n"), 1
            )
            self.assertEqual(
                manifest.count(
                    "      - package: MatrixRustSDK\n        embed: true\n"
                ),
                1,
            )
            self.assertEqual(manifest.count("        embed: true"), 2)
            with (project / "App/Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
            self.assertEqual(
                info["AtumBuildLane"], "LC4-phone-sdk-derived-proof-not-release"
            )
            self.assertEqual(
                info["AtumCandidateBuildReceiptSHA256"], "receipt-digest"
            )
            pbx = (project / "AtumMobile.xcodeproj/project.pbxproj").read_text()
            self.assertEqual(
                pbx.count(
                    "\t\t97704AB3428F663611A759AD /* XCLocalSwiftPackageReference "
                    '"MatrixRustSDK" */ = {\n'
                ),
                1,
            )
            self.assertEqual(
                pbx.count("isa = XCLocalSwiftPackageReference;"), 2
            )
            self.assertIn('relativePath = "../artifact";', pbx)
            self.assertEqual(
                pbx.count(f'repositoryURL = "{MODULE.SDK_URL}";'), 0
            )
            self.assertEqual(
                pbx.count(
                    "\t\tC342FA7561CB2949BE0755B9 /* MatrixRustSDK "
                    "in Embed Frameworks */ = {isa = PBXBuildFile"
                ),
                1,
            )
            self.assertEqual(
                pbx.count(
                    "\t\t\t\tC342FA7561CB2949BE0755B9 /* MatrixRustSDK "
                    "in Embed Frameworks */,"
                ),
                1,
            )
            self.assertEqual(
                pbx.count(
                    "\t\t093673C5B8D31EC0B784A742 /* Embed Frameworks */ = {"
                ),
                1,
            )
            self.assertEqual(
                pbx.count(
                    "\t\t\t\t093673C5B8D31EC0B784A742 "
                    "/* Embed Frameworks */,"
                ),
                1,
            )
            self.assertEqual(pbx.count("CodeSignOnCopy"), 1)
            self.assertIn("dstSubfolderSpec = 10;", pbx)
            self.assertEqual(
                pbx.count(
                    "\t\t2B3F6FA27D944DF0213C44E5 "
                    "/* MatrixRustSDK */ = {\n"
                ),
                1,
            )
            self.assertEqual(
                pbx.count(
                    "\t\tA9408AD08F2984260BB299AC /* MatrixRustSDK "
                    "in Frameworks */ = {isa = PBXBuildFile"
                ),
                1,
            )
            self.assertEqual(
                pbx.count(
                    "\t\t\t\tA9408AD08F2984260BB299AC /* MatrixRustSDK "
                    "in Frameworks */,"
                ),
                1,
            )

    def test_rewrite_refuses_malformed_duplicated_embed_context(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self._stage_derived_project(root)
            pbx_path = project / "AtumMobile.xcodeproj/project.pbxproj"
            pbx = pbx_path.read_text()
            pbx = self._rewrite_once(
                pbx,
                '\t\tC2FD7254CCF6633C18FBD49F /* TimelineStartRow.swift '
                "in Sources */ "
                "= {isa = PBXBuildFile; "
                "fileRef = 74387C8A27D11F2B1288AD0A "
                "/* TimelineStartRow.swift */; };\n",
                '\t\tC2FD7254CCF6633C18FBD49F /* TimelineStartRow.swift '
                "in Sources */ "
                "= {isa = PBXBuildFile; "
                "fileRef = 74387C8A27D11F2B1288AD0A "
                "/* TimelineStartRow.swift */; };\n"
                "\t\tC342FA7561CB2949BE0755B9 /* MatrixRustSDK "
                "in Embed Frameworks */ = {isa = PBXBuildFile; "
                "productRef = 2B3F6FA27D944DF0213C44E5 "
                "/* MatrixRustSDK */; settings = {ATTRIBUTES = ("
                "CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };\n",
            )
            pbx_path.write_text(pbx)
            (root / "artifact").mkdir()
            with self.assertRaisesRegex(
                ValueError, "refusing malformed duplicated proof context"
            ):
                MODULE.rewrite_project(project, root / "artifact", "receipt-digest")

    def test_rewrite_refuses_the_nonembedded_shape_instead_of_injecting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self._stage_derived_project(root)
            pbx_path = project / "AtumMobile.xcodeproj/project.pbxproj"
            pbx = pbx_path.read_text()
            pbx = self._rewrite_once(
                pbx,
                "\t\t093673C5B8D31EC0B784A742 /* Embed Frameworks */ = {\n"
                "\t\t\tisa = PBXCopyFilesBuildPhase;\n"
                "\t\t\tbuildActionMask = 2147483647;\n"
                '\t\t\tdstPath = "";\n'
                "\t\t\tdstSubfolderSpec = 10;\n"
                "\t\t\tfiles = (\n"
                "\t\t\t\tC342FA7561CB2949BE0755B9 /* MatrixRustSDK "
                "in Embed Frameworks */,\n"
                "\t\t\t);\n"
                '\t\t\tname = "Embed Frameworks";\n'
                "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
                "\t\t};\n",
                "",
            )
            pbx = self._rewrite_once(
                pbx,
                "\t\t\t\t093673C5B8D31EC0B784A742 "
                "/* Embed Frameworks */,\n",
                "",
            )
            pbx_path.write_text(pbx)
            (project / "project.yml").write_text(
                (project / "project.yml")
                .read_text()
                .replace(
                    "      - package: MatrixRustSDK\n        embed: true\n",
                    "      - package: MatrixRustSDK\n",
                )
            )
            (root / "artifact").mkdir()
            with self.assertRaisesRegex(
                ValueError, "unexpected project shape"
            ):
                MODULE.rewrite_project(project, root / "artifact", "receipt-digest")

    def test_rewrite_refuses_a_missing_embed_phase_membership(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = self._stage_derived_project(root)
            pbx_path = project / "AtumMobile.xcodeproj/project.pbxproj"
            pbx_path.write_text(
                self._rewrite_once(
                    pbx_path.read_text(),
                    "\t\t\t\t093673C5B8D31EC0B784A742 "
                    "/* Embed Frameworks */,\n",
                    "",
                )
            )
            (root / "artifact").mkdir()
            with self.assertRaisesRegex(
                ValueError, "unexpected project shape"
            ):
                MODULE.rewrite_project(project, root / "artifact", "receipt-digest")

    def test_linkage_requires_an_app_framework_and_none_in_the_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "AtumMobile.app"
            framework = app / "Frameworks/MatrixRustSDK.framework"
            framework.mkdir(parents=True)
            (app / "AtumMobile").write_bytes(b"app")
            (app / "AtumMobile.debug.dylib").write_bytes(b"debug")
            (framework / "MatrixRustSDK").write_bytes(b"framework")
            extension = app / "PlugIns/AtumNotifications.appex"
            extension.mkdir(parents=True)
            (extension / "AtumNotifications").write_bytes(b"extension")

            def output(arguments, **_):
                if arguments[0] == "otool":
                    if str(arguments[-1]).endswith("debug.dylib"):
                        return "AtumMobile.debug.dylib:\n\t@rpath/MatrixRustSDK.framework/MatrixRustSDK\n"
                    return "AtumMobile:\n"
                if arguments[0] == "file":
                    return "Mach-O 64-bit dynamically linked shared library\n"
                raise AssertionError(arguments)

            with mock.patch.object(MODULE.subprocess, "check_output", side_effect=output):
                value = MODULE.matrix_linkage(app)
            self.assertEqual(value["frameworks"][0]["path"],
                             "Frameworks/MatrixRustSDK.framework")
            self.assertEqual([item["path"] for item in value["binaries"]],
                             ["AtumMobile", "AtumMobile.debug.dylib"])

            extension_framework = extension / "Frameworks/MatrixRustSDK.framework"
            extension_framework.mkdir(parents=True)
            with mock.patch.object(MODULE.subprocess, "check_output", side_effect=output):
                with self.assertRaisesRegex(ValueError, "must not embed"):
                    MODULE.matrix_linkage(app)

    def test_workflow_can_reuse_the_verified_framework_artifact(self):
        workflow = (ROOT / ".github/workflows/matrix-sdk-phone.yml").read_text()
        self.assertIn("source_run_id:", workflow)
        self.assertIn("actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093",
                      workflow)
        self.assertIn("run-id: ${{ env.ATUM_SOURCE_RUN_ID }}", workflow)
        self.assertIn("name: sdk-phone-${{ env.ATUM_SDK_PACK }}", workflow)
        self.assertIn("Verify reused framework artifact against committed manifest", workflow)
        self.assertIn("--manifest sdk/phone-26.10.15-founder/source.json", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("if: ${{ !inputs.source_run_id }}", workflow)
        self.assertIn("needs.source.result == 'skipped'", workflow)
        download = workflow.index("Download verified framework artifact from retained run")
        verify = workflow.index("Verify reused framework artifact against committed manifest")
        study = workflow.index("study-phone-matrix-sdk-app.py", verify)
        self.assertLess(download, verify)
        self.assertLess(verify, study)
        self.assertEqual(workflow.count("--unpack-retained"), 2)
        self.assertIn("--unpack-retained", workflow[verify:study])

    def test_pr_workflow_resolves_derived_proof_pack_from_committed_selection(self):
        workflow = (ROOT / ".github/workflows/matrix-sdk-phone.yml").read_text()
        self.assertEqual(MODULE.selected_source_pack(), "phone-26.10.15-founder")
        self.assertIn("default: phone-26.10.15", workflow)
        self.assertIn("ATUM_SDK_PACK: ${{ inputs.pack || '' }}", workflow)
        self.assertNotIn("inputs.pack || 'phone-26.10.15'", workflow)
        resolver = (
            "python3 scripts/study-phone-matrix-sdk-app.py --print-selected-pack"
        )
        self.assertEqual(workflow.count(resolver), 2)
        self.assertEqual(workflow.count(f'pack="$({resolver})"'), 2)
        self.assertNotIn(f'echo "ATUM_SDK_PACK=$({resolver})"', workflow)
        self.assertEqual(
            workflow.count("if: env.ATUM_SDK_PACK == ''"),
            2,
            "only event lanes without an explicit manual pack may derive selection",
        )
        apple = workflow.index("  apple:")
        apple_resolver = workflow.index(resolver, apple)
        founder_study = workflow.index(
            "Verify additive Founder derived app, AppTests and unsigned archive linkage",
            apple,
        )
        self.assertLess(apple_resolver, founder_study)
        self.assertIn(
            "if: env.ATUM_SDK_PACK == 'phone-26.10.15-founder'",
            workflow[apple_resolver:founder_study + 200],
        )

    def test_selected_pack_resolver_fails_closed_on_pin_or_manifest_drift(self):
        selection_path = ROOT / MODULE.SDK_SELECTION_RECEIPT
        selection = json.loads(selection_path.read_text())
        manifest_relative = selection["mobileSourceManifest"]["path"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "ios").mkdir()
            shutil.copyfile(ROOT / "ios/project.yml", root / "ios/project.yml")
            (root / selection_path.relative_to(ROOT)).parent.mkdir(parents=True)
            shutil.copyfile(selection_path, root / selection_path.relative_to(ROOT))
            (root / manifest_relative).parent.mkdir(parents=True)
            shutil.copyfile(ROOT / manifest_relative, root / manifest_relative)

            self.assertEqual(
                MODULE.selected_source_pack(root), "phone-26.10.15-founder"
            )
            project = (root / "ios/project.yml").read_text()
            (root / "ios/project.yml").write_text(
                project.replace(MODULE.SDK_REVISION, "0" * 40, 1)
            )
            with self.assertRaisesRegex(ValueError, "app pin and published SDK"):
                MODULE.selected_source_pack(root)

            (root / "ios/project.yml").write_text(project)
            (root / manifest_relative).write_text("{}\n")
            with self.assertRaisesRegex(ValueError, "manifest digest mismatch"):
                MODULE.selected_source_pack(root)

    def test_workflow_runs_the_study_without_signing_or_publication(self):
        workflow = (ROOT / ".github/workflows/matrix-sdk-phone.yml").read_text()
        self.assertIn("study-phone-matrix-sdk-app.py", workflow)
        self.assertIn("atum-phone-app-proof.json", workflow)
        upload = workflow.index("Upload verified SDK framework artifact before app proof")
        study = workflow.index("study-phone-matrix-sdk-app.py", upload)
        self.assertLess(
            upload,
            study,
            "the verified framework artifact must be retained before the app proof gate",
        )
        self.assertIn("Upload derived app proof receipt", workflow)
        for path in ("scripts/study-phone-matrix-sdk-app.py",
                     "tests/test_phone_sdk_app_study.py", "ios/project.yml",
                     "ios/App/Info.plist",
                     "ios/AtumMobile.xcodeproj/project.pbxproj"):
            self.assertIn(f"- {path}", workflow)
        self.assertNotIn("command -v xcodegen", workflow)
        self.assertNotIn("codesign", workflow)
        self.assertNotIn("gh release", workflow)


if __name__ == "__main__":
    unittest.main()
