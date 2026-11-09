#!/usr/bin/env python3
"""Build the source-verified, unsigned single SDK Apple library candidate."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("atum_sdk_source", ROOT / "scripts/prepare-matrix-sdk.py")
source_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_tools)


def build(source, output):
    pin = json.loads(source_tools.MANIFEST.read_text())
    source = source.resolve(strict=True)
    output = output.absolute()
    source_tools.verify_patched_source(source, pin)
    receipt = json.loads((source / "atum-source-receipt.json").read_text())
    if (receipt.get("status") != "SOURCE_PREPARED"
            or receipt.get("sourceManifestSHA256") != source_tools.digest(source_tools.MANIFEST)
            or receipt.get("consumerHasUncommittedChanges") is not False):
        raise ValueError("Apple build requires a clean committed consumer source receipt")
    if output.exists():
        raise ValueError("SDK output destination must be new")

    # Upstream xtask hardcodes a floating stable toolchain and omits --locked.
    # Change only those three build invocations; retain its target selection,
    # UniFFI generation and private SQLite symbol-localization implementation.
    xtask = source / "xtask/src/swift.rs"
    before = xtask.read_bytes()
    pattern = b"rustup run stable cargo build -p matrix-sdk-ffi"
    if before.count(pattern) != 3:
        raise ValueError("SDK Swift build invocation changed")
    after = before.replace(pattern,
        b"rustup run 1.96.0 cargo build --locked -p matrix-sdk-ffi")
    xtask.write_bytes(after)

    environment = {**os.environ, "CARGO_BUILD_JOBS": "2", "CARGO_INCREMENTAL": "0"}
    subprocess.run(["cargo", "+1.96.0", "run", "--locked", "-p", "xtask", "--",
        "swift", "build-framework", "--release", "--target", "aarch64-apple-ios",
        "--target", "aarch64-apple-darwin", "--components-path", str(output),
        "--ios-deployment-target", "26.0", "--macos-deployment-target", "15.0",
        "--sequentially"], cwd=source, env=environment, check=True)
    (output / "Package.swift").write_text('''// swift-tools-version:5.7
import PackageDescription
let package = Package(name: "MatrixRustSDK",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [.library(name: "MatrixRustSDK", targets: ["MatrixRustSDK"])],
    targets: [
        .binaryTarget(name: "MatrixSDKFFI", path: "MatrixSDKFFI.xcframework"),
        .target(name: "MatrixRustSDK", dependencies: [.target(name: "MatrixSDKFFI")])])
''')
    shutil.copyfile(source / "LICENSE", output / "LICENSE")
    binding = output / "Sources/MatrixRustSDK/matrix_sdk_ffi.swift"
    if "func restoreSessionExisting(" not in binding.read_text():
        raise ValueError("Existing restore Swift binding missing")
    # Compile the generated Swift surface against this exact library, without
    # credentials, signing, device installation or app-runtime selection.
    subprocess.run(["swift", "build", "--package-path", str(output), "-j", "2"],
                   env=environment, check=True)
    files = {str(p.relative_to(output)): source_tools.digest(p)
        for p in sorted(output.rglob("*")) if p.is_file() and ".build" not in p.relative_to(output).parts}
    result = {"schemaVersion": 1, "status": "APPLE_LIBRARY_AND_SWIFT_COMPILED",
        "source": receipt, "features": "upstream FFI defaults plus upstream xtask sentry",
        "profile": "small-release", "targets": ["aarch64-apple-ios", "aarch64-apple-darwin"],
        "xtaskBeforeSHA256": hashlib.sha256(before).hexdigest(),
        "xtaskAfterSHA256": hashlib.sha256(after).hexdigest(),
        "toolchain": source_tools.command(["rustc", "+1.96.0", "--version", "--verbose"], source),
        "xcode": source_tools.command(["xcodebuild", "-version"], source),
        "iphoneSDKVersion": source_tools.command(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], source),
        "artifactSHA256": files,
        "scope": "Unsigned one-library candidate and generated Swift compilation only; no app selection, device, Keychain, account, or gate acceptance"}
    (output / "atum-build-receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    print("PASS · single Apple SDK library and generated existing-only Swift binding compiled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--unselected-longpoll-ownership", action="store_true",
                        help="Build the explicit unselected long-poll source authority")
    args = parser.parse_args()
    if args.unselected_longpoll_ownership:
        longpoll_spec = importlib.util.spec_from_file_location("atum_longpoll_apple", ROOT / "scripts/sdk_longpoll_apple.py")
        longpoll = importlib.util.module_from_spec(longpoll_spec)
        longpoll_spec.loader.exec_module(longpoll)
        longpoll.build(args.source, args.output)
    else:
        build(args.source, args.output)
