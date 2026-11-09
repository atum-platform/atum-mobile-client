#!/usr/bin/env python3
"""Build a derived signed Debug app against one verified SDK candidate."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("prototype project shape changed")
    return text.replace(old, new)


def candidate_source_files(study_sources, project_source):
    """Return every source/config byte that contributes to the signed app."""
    values = [
        *(ROOT / "ios/App").rglob("*.swift"),
        *(ROOT / "ios/App/PushLocalizations").glob("*.xcstrings"),
        *(ROOT / "ios/Notifications").glob("*"),
        ROOT / "ios/Package.swift",
        *(ROOT / "ios/Sources/AtumNativeAPI").glob("*.swift"),
        *(ROOT / "ios/Sources/AtumChat").rglob("*.swift"),
        *(ROOT / "ios/Sources/AtumDesign").rglob("*.swift"),
        *(ROOT / "ios/Vendor/AtumDesign").rglob("*"),
        *[path for path in study_sources if path.name != "Probe.swift"],
        project_source,
        ROOT / "ios/App/AtumMobile.entitlements",
        ROOT / "ios/App/Info.plist",
    ]
    return sorted({path for path in values if path.is_file()})


def candidate_authority(artifact, unselected_longpoll):
    """Return the verifier-selected SDK receipt, manifest and study module."""
    study_spec = importlib.util.spec_from_file_location(
        "candidate_study", ROOT / "scripts/study-matrix-sdk-existing.py")
    study = importlib.util.module_from_spec(study_spec)
    study_spec.loader.exec_module(study)
    if unselected_longpoll:
        longpoll_spec = importlib.util.spec_from_file_location(
            "atum_longpoll_apple", ROOT / "scripts/sdk_longpoll_apple.py")
        longpoll = importlib.util.module_from_spec(longpoll_spec)
        longpoll_spec.loader.exec_module(longpoll)
        sdk, sdk_digest = longpoll.verify_artifact(artifact)
        return sdk, sdk_digest, longpoll.manifest_path(), study
    sdk, sdk_digest = study.verify_artifact(artifact)
    return sdk, sdk_digest, ROOT / "sdk/custody/source.json", study


def build(args):
    artifact = args.artifact.resolve(strict=True)
    unselected_longpoll = args.unselected_longpoll_ownership
    if unselected_longpoll:
        if args.receipt.exists():
            raise ValueError("Unselected candidate receipt destination must be new")
        if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
            raise ValueError("Unselected candidate requires a committed clean consumer")
    sdk, sdk_digest, source_manifest, study = candidate_authority(artifact, unselected_longpoll)
    source_manifest_digest = digest(source_manifest)
    derived = args.derived_data.resolve()
    if derived.is_relative_to(ROOT):
        raise ValueError("signed outputs must remain outside Git")
    project_source = ROOT / "ios/project.yml"
    text = project_source.read_text()
    text = replace_once(text, "    path: .\n", "    path: " + json.dumps(str(ROOT / "ios")) + "\n")
    text = replace_once(text, "    url: https://github.com/atum-platform/atum-matrix-rust-components-swift.git\n    revision: 66c18d378d44d9ad61946f08b926514cccb14fb5\n",
                        "    path: " + json.dumps(str(artifact)) + "\n")
    # The stock app no longer compiles the study sources (revamp S0); the
    # candidate build adds them right after the app sources.
    text = replace_once(text, "      - App\n", "      - path: " + json.dumps(str(ROOT / "ios/App"))
                        + "\n        excludes: [Info.plist, AtumMobile.entitlements]\n" + "".join(
                            "      - path: " + json.dumps(str(p)) + "\n" for p in study.SOURCES if p.name != "Probe.swift"))
    text = replace_once(text, "        CODE_SIGN_ENTITLEMENTS: App/AtumMobile.entitlements\n",
                        "        CODE_SIGN_ENTITLEMENTS: " + json.dumps(str(ROOT / "ios/App/AtumMobile.entitlements")) + "\n")
    text = replace_once(text, "      - path: Notifications\n",
                        "      - path: " + json.dumps(str(ROOT / "ios/Notifications")) + "\n")
    text = replace_once(text, "      - path: App/PushLocalizations\n",
                        "      - path: " + json.dumps(str(ROOT / "ios/App/PushLocalizations")) + "\n")
    text = replace_once(text, "        CODE_SIGN_ENTITLEMENTS: Notifications/AtumNotifications.entitlements\n",
                        "        CODE_SIGN_ENTITLEMENTS: " + json.dumps(str(ROOT / "ios/Notifications/AtumNotifications.entitlements")) + "\n")
    text = replace_once(text, "    SWIFT_VERSION: '6.0'\n",
                        "    SWIFT_VERSION: '6.0'\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS: '$(inherited) DEBUG ATUM_SDK_CANDIDATE_STUDY'\n")
    text = replace_once(text, "        AtumBuildLane: live-private-candidate\n",
                        "        AtumBuildLane: P2-candidate-study-not-release\n"
                        "        AtumCandidateBuildReceiptSHA256: " + json.dumps(sdk_digest) + "\n"
                        "        AtumCandidateSourceManifestSHA256: " + json.dumps(source_manifest_digest) + "\n"
                        "        AtumCandidateConsumerRevision: " + json.dumps(sdk["source"]["consumerRevision"]) + "\n")
    log = Path("/tmp/atum-p2-sdk-candidate-build.log")
    with tempfile.TemporaryDirectory(prefix="atum-p2-sdk-candidate-project-") as temporary, log.open("w") as output:
        log.chmod(0o600)
        workspace = Path(temporary)
        manifest = workspace / "project.yml"
        manifest.write_text(text)

        def command(argv, timeout):
            process = subprocess.Popen(argv, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                status = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            if status:
                raise subprocess.CalledProcessError(status, argv)

        command(["xcodegen", "generate", "--spec", str(manifest), "--project", str(workspace)], 30)
        command(["xcodebuild", "-project", str(workspace / "AtumMobile.xcodeproj"), "-scheme", "AtumMobile",
                 "-configuration", "Debug", "-destination", "generic/platform=iOS", "-derivedDataPath", str(derived),
                 "-clonedSourcePackagesDirPath", str(args.package_cache.resolve()), "-jobs", "2", "build"], 900)
        app = derived / "Build/Products/Debug-iphoneos/AtumMobile.app"
        command(["codesign", "--verify", "--deep", "--strict", str(app)], 30)
        signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                capture_output=True, check=True, timeout=30)
        entitlements = plistlib.loads(signed.stdout)
        if (entitlements.get("application-identifier") != "7D5FC62RXD.com.atum.mobile"
                or entitlements.get("aps-environment") != "development"
                or set(entitlements.get("keychain-access-groups", [])) != {
                    "7D5FC62RXD.com.atum.mobile", "7D5FC62RXD.com.atum.mobile.matrix"}
                or set(entitlements.get("com.apple.security.application-groups", [])) != {"group.com.atum.mobile.shared"}
                or set(entitlements.get("com.apple.developer.associated-domains", [])) != {
                    "applinks:api.atumplatform.com", "webcredentials:api.atumplatform.com"}):
            raise ValueError("signed main custody/push/callback boundary mismatch")
        extension = app / "PlugIns/AtumNotifications.appex"
        command(["codesign", "--verify", "--strict", str(extension)], 30)
        extension_signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(extension)],
                                          capture_output=True, check=True, timeout=30)
        extension_entitlements = plistlib.loads(extension_signed.stdout)
        if (extension_entitlements.get("application-identifier") != "7D5FC62RXD.com.atum.mobile.notifications"
                or set(extension_entitlements.get("keychain-access-groups", [])) != {"7D5FC62RXD.com.atum.mobile.matrix"}
                or set(extension_entitlements.get("com.apple.security.application-groups", [])) != {"group.com.atum.mobile.shared"}
                or any(k in extension_entitlements for k in ["aps-environment", "com.apple.developer.associated-domains",
                       "com.apple.developer.applesignin", "com.apple.developer.usernotifications.filtering"])):
            raise ValueError("signed extension Matrix-only boundary mismatch")
        extension_info = plistlib.loads((extension / "Info.plist").read_bytes())
        if (extension_info.get("CFBundleIdentifier") != "com.atum.mobile.notifications"
                or extension_info.get("NSExtension") != {
                "NSExtensionPointIdentifier": "com.apple.usernotifications.service",
                "NSExtensionPrincipalClass": "AtumNotifications.NotificationService"}):
            raise ValueError("signed extension entry point mismatch")
        catalog = ROOT / "ios/App/PushLocalizations/Localizable.xcstrings"
        alerts = json.loads(catalog.read_bytes())["strings"]["ATUM_NEW_MESSAGE"]["localizations"]
        compiled_alerts = {}
        extension_alerts = {}
        for locale, unit in alerts.items():
            localized = app / (locale + ".lproj") / "Localizable.strings"
            actual = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(localized)], timeout=10))
            if actual != {"ATUM_NEW_MESSAGE": unit["stringUnit"]["value"]}:
                raise ValueError("signed generic notification localization mismatch")
            compiled_alerts[str(localized.relative_to(app))] = digest(localized)
            extension_localized = extension / (locale + ".lproj") / "Localizable.strings"
            extension_actual = json.loads(subprocess.check_output([
                "plutil", "-convert", "json", "-o", "-", str(extension_localized)], timeout=10))
            if extension_actual != actual:
                raise ValueError("signed extension generic localization mismatch")
            extension_alerts[str(extension_localized.relative_to(extension))] = digest(extension_localized)
        info = plistlib.loads((app / "Info.plist").read_bytes())
        if any(extension_info.get(key) != info.get(key) for key in ["CFBundleShortVersionString", "CFBundleVersion"]):
            raise ValueError("signed extension/app versions mismatch")
        if (info.get("AtumBuildLane") != "P2-candidate-study-not-release"
                or info.get("AtumCandidateBuildReceiptSHA256") != sdk_digest
                or info.get("AtumCandidateSourceManifestSHA256") != source_manifest_digest
                or info.get("AtumCandidateConsumerRevision") != sdk["source"]["consumerRevision"]):
            raise ValueError("signed study configuration mismatch")
        value = {"schemaVersion": 1, "status": "SIGNED_DEBUG_BUILD_ONLY",
                 "observedAtUTC": datetime.now(timezone.utc).isoformat(),
                 "consumerRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                 "consumerHasUncommittedChanges": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()),
                 "candidateConsumerRevision": sdk["source"]["consumerRevision"],
                 "candidateBuildReceiptSHA256": sdk_digest,
                 "sourceManifestSHA256": source_manifest_digest,
                 **({"unselectedLongpollOwnership": True, "runtimeSelected": False} if unselected_longpoll else {}),
                 "derivedProjectSHA256": digest(manifest),
                 "collectorSHA256": digest(Path(__file__)),
                 "appExecutableSHA256": digest(app / "AtumMobile"),
                 "appDebugDylibSHA256": digest(app / "AtumMobile.debug.dylib"),
                 "genericAlertCatalogIncluded": True,
                 "signedMainCustodyAndCallbackGroupsMatch": True,
                 "signedAPNSEnvironment": "development",
                 "compiledGenericAlertSHA256": compiled_alerts,
                 "signedExtensionMatrixOnlyGroupsMatch": True,
                 "signedExtensionEntryPointMatches": True,
                 "extensionExecutableSHA256": digest(extension / "AtumNotifications"),
                 "extensionDebugDylibSHA256": digest(extension / "AtumNotifications.debug.dylib")
                     if (extension / "AtumNotifications.debug.dylib").is_file() else None,
                 "extensionGenericAlertSHA256": extension_alerts,
                 "sourceSHA256": {str(p.relative_to(ROOT)): digest(p)
                                  for p in candidate_source_files(study.SOURCES, project_source)},
                 "mainProjectKeepsOriginalSDK": "url: https://github.com/atum-platform/atum-matrix-rust-components-swift.git" in project_source.read_text(),
                 "scope": "Single verified candidate library in a derived signed Debug live-root app; no release or runtime verdict",
                 "doesNotProve": "Device execution, physical Security/NSE, authenticated account, provider admission, recovery, runtime selection or owner Gate 2"}
        args.receipt.write_text(json.dumps(value, indent=2) + "\n")
    print("PASS · derived single-candidate live-root Debug build and signing; no device/runtime pass")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--unselected-longpoll-ownership", action="store_true",
                        help="Use an explicitly verified unselected long-poll Apple artifact")
    parser.add_argument("--derived-data", type=Path, default=Path("/tmp/atum-mobile-p2-candidate"))
    parser.add_argument("--package-cache", type=Path, default=Path("/tmp/atum-mobile-p2/SourcePackages"))
    parser.add_argument("--receipt", type=Path, default=ROOT / ".artifacts/sdk-candidate-ios-build.json")
    try:
        build(parser.parse_args())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        raise SystemExit("FAIL · candidate Debug build/signing; raw output withheld in private local build log")
