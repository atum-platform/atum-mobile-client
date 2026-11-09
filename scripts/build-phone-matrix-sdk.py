#!/usr/bin/env python3
"""Build and verify the unselected LC4 iOS device/simulator SDK artifact."""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACK = "phone-26.10.15"
CANDIDATE_PACK = "phone-26.10.15-founder"
PACK = DEFAULT_PACK
PACKS = {
    DEFAULT_PACK: {
        "manifest": ROOT / "sdk/phone-26.10.15/source.json",
        "pending": None,
        "markers": ("func accountDataRaw(eventType:", "class Room"),
    },
    CANDIDATE_PACK: {
        "manifest": None,
        "pending": ROOT / "sdk/phone-26.10.15-founder/source.pending.json",
        "markers": ("func accountDataRaw(eventType:",
                    "func fetchGlobalAccountDataRaw(eventType:", "class Room"),
    },
}
TARGETS = ("aarch64-apple-ios", "aarch64-apple-ios-sim")
EXPECTED_SLICES = {
    ("ios", None, ("arm64",)),
    ("ios", "simulator", ("arm64",)),
}
PIN_PATH = PACKS[DEFAULT_PACK]["manifest"]
BUILD_METADATA = {".build", ".swiftpm"}
spec = importlib.util.spec_from_file_location(
    "atum_sdk_source", ROOT / "scripts/prepare-matrix-sdk.py"
)
source_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_tools)


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def package_manifest(binary="MatrixSDKFFI.xcframework"):
    return f'''// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "MatrixRustSDK",
    platforms: [.iOS("26.0")],
    products: [.library(name: "MatrixRustSDK", type: .dynamic, targets: ["MatrixRustSDK"])],
    targets: [
        .binaryTarget(name: "MatrixSDKFFI", path: "{binary}"),
        .target(name: "MatrixRustSDK", dependencies: [.target(name: "MatrixSDKFFI")])])
'''


def swift_compile_command(derived):
    return [
        "xcodebuild", "-scheme", "MatrixRustSDK",
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(derived),
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGNING_ALLOWED=NO", "build",
    ]


def binding_markers(binding, required=None):
    text = binding.read_text()
    required = required or PACKS[DEFAULT_PACK]["markers"]
    missing = [value for value in required if value not in text]
    if missing:
        raise ValueError(f"Patched generated Swift binding missing: {', '.join(missing)}")
    return {
        "path": "Sources/MatrixRustSDK/matrix_sdk_ffi.swift",
        "sha256": digest(binding),
        "markers": list(required),
    }


def exported_symbols(library):
    command = [
        "xcrun", "nm", "--no-llvm-bc", "--export-symbols", str(library),
    ]
    try:
        completed = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip()
        if not detail:
            detail = f"nm exited {error.returncode} without diagnostics"
        raise ValueError(f"XCFramework slice export inventory failed: {detail}") from error
    symbols = sorted({
        line.strip()
        for line in completed.stdout.splitlines()
        if line.strip()
    })
    if not symbols:
        raise ValueError("XCFramework slice exported-symbol inventory empty")
    return "\n".join(symbols) + "\n"


def slice_inventory(framework):
    with (framework / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    libraries = info.get("AvailableLibraries")
    if not isinstance(libraries, list):
        raise ValueError("XCFramework slice inventory missing")
    slices = []
    actual = set()
    for value in libraries:
        platform = value.get("SupportedPlatform")
        variant = value.get("SupportedPlatformVariant")
        architectures = tuple(sorted(value.get("SupportedArchitectures", [])))
        identifier = value.get("LibraryIdentifier")
        relative = value.get("LibraryPath")
        if not all(isinstance(item, str) and item for item in (platform, identifier, relative)):
            raise ValueError("XCFramework slice metadata invalid")
        library = framework / identifier / relative
        if not library.is_file() or library.is_symlink():
            raise ValueError("XCFramework slice library missing")
        normalized_symbols = exported_symbols(library)
        actual.add((platform, variant, architectures))
        slices.append({
            "identifier": identifier,
            "platform": platform,
            "variant": variant,
            "architectures": list(architectures),
            "library": str(library.relative_to(framework.parent)),
            "librarySHA256": digest(library),
            "exportedSymbolsSHA256": hashlib.sha256(
                normalized_symbols.encode()
            ).hexdigest(),
        })
    if actual != EXPECTED_SLICES:
        raise ValueError(f"XCFramework must contain only iOS arm64 device/simulator slices: {actual}")
    return sorted(slices, key=lambda value: value["identifier"])


def deterministic_zip(source, destination, epoch):
    instant = datetime.datetime.fromtimestamp(
        max(epoch, 315532800), datetime.timezone.utc
    )
    timestamp = tuple(instant.timetuple()[:6])
    paths = [source, *sorted(source.rglob("*"))]
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=6, allowZip64=True) as archive:
        for path in paths:
            if path.is_symlink():
                raise ValueError("Phone SDK XCFramework must not contain symlinks")
            relative = Path(source.name) / path.relative_to(source)
            name = relative.as_posix() + ("/" if path.is_dir() else "")
            entry = zipfile.ZipInfo(name, date_time=timestamp)
            entry.create_system = 3
            mode = 0o755 if path.is_dir() else 0o644
            entry.external_attr = (mode | (stat.S_IFDIR if path.is_dir() else stat.S_IFREG)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            if path.is_dir():
                archive.writestr(entry, b"")
            else:
                with path.open("rb") as source_file, archive.open(entry, "w") as target:
                    shutil.copyfileobj(source_file, target, 1024 * 1024)


def verify_zip(source, archive):
    expected = {
        (Path(source.name) / path.relative_to(source)).as_posix(): digest(path)
        for path in sorted(source.rglob("*"))
        if path.is_file() and not path.is_symlink()
    }
    with zipfile.ZipFile(archive) as value:
        files = [name for name in value.namelist() if not name.endswith("/")]
        if set(files) != set(expected):
            raise ValueError("Phone SDK zip inventory mismatch")
        for name in files:
            hasher = hashlib.sha256()
            with value.open(name) as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    hasher.update(chunk)
            if hasher.hexdigest() != expected[name]:
                raise ValueError("Phone SDK zip content mismatch")


def unpack_retained_artifact(output):
    """Reconstruct the XCFramework directory a retained artifact ships as a zip."""
    output = output.resolve(strict=True)
    framework = "MatrixSDKFFI.xcframework"
    archive = output / f"{framework}.zip"
    destination = output / framework
    if not archive.is_file() or archive.is_symlink():
        raise ValueError("Retained phone SDK zip missing")
    if destination.exists() or destination.is_symlink():
        raise ValueError("Retained phone SDK unpack destination already exists")
    receipt = json.loads((output / "atum-build-receipt.json").read_text())
    if receipt.get("zipSHA256") != digest(archive):
        raise ValueError("Phone SDK zip checksum mismatch")
    prefix = f"{framework}/"
    staging = output / f".{framework}.unpack"
    if staging.exists() or staging.is_symlink():
        raise ValueError("Retained phone SDK unpack staging path already exists")
    try:
        with zipfile.ZipFile(archive) as value:
            seen = set()
            for info in value.infolist():
                name = info.filename
                if name in seen:
                    raise ValueError("Retained phone SDK zip contains duplicate entries")
                seen.add(name)
                if name != prefix and not name.startswith(prefix):
                    raise ValueError("Retained phone SDK zip entry is outside the XCFramework")
                relative = name[len(prefix):]
                if relative.endswith("/"):
                    relative = relative[:-1]
                if relative and (
                    relative.startswith("/")
                    or "\\" in relative
                    or "\x00" in relative
                    or any(part in ("", ".", "..") for part in relative.split("/"))
                ):
                    raise ValueError("Retained phone SDK zip entry is unsafe")
                if stat.S_ISLNK(info.external_attr >> 16):
                    raise ValueError("Retained phone SDK zip must not contain symlinks")
            value.extractall(staging)
        extracted = staging / framework
        if not extracted.is_dir() or extracted.is_symlink():
            raise ValueError("Retained phone SDK zip lacks the XCFramework directory")
        extracted.rename(destination)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def artifact_files(output, receipt_path):
    values = {}
    for path in sorted(output.rglob("*")):
        if path.is_symlink():
            raise ValueError("Phone SDK artifact must not contain symlinks")
        relative = path.relative_to(output)
        if (path.is_file() and path != receipt_path
                and BUILD_METADATA.isdisjoint(relative.parts)):
            values[str(relative)] = digest(path)
    return values


def _manifest(pack=DEFAULT_PACK, manifest_path=None):
    if pack not in PACKS:
        raise ValueError("Unknown phone SDK pack")
    spec = PACKS[pack]
    if manifest_path is not None:
        if spec["pending"] is None:
            raise ValueError("An explicit manifest is only allowed for the additive candidate pack")
        generated = json.loads(Path(manifest_path).resolve(strict=True).read_text())
        pending = json.loads(spec["pending"].read_text())
        if generated.get("status") != "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED":
            raise ValueError("Candidate source manifest is pending or not generated")
        if generated.get("runtimeSelected") is not False:
            raise ValueError("Candidate source manifest is not an unselected source candidate")
        for key in ("upstreamURL", "upstreamRevision", "license", "licenseSHA256",
                    "patch", "patchSHA256", "preimageSHA256", "rustToolchain",
                    "swiftDistribution"):
            if generated.get(key) != pending.get(key):
                raise ValueError(f"Candidate source manifest mismatches the pending pack: {key}")
        patched = generated.get("patchedSHA256")
        if not isinstance(patched, dict) or set(patched) != set(pending["preimageSHA256"]):
            raise ValueError("Candidate source manifest lacks exact patched hashes")
        if any(not isinstance(value, str) or len(value) != 64
               or any(character not in "0123456789abcdef" for character in value)
               for value in patched.values()):
            raise ValueError("Candidate source manifest has an invalid patched hash")
        return Path(manifest_path).resolve(strict=True), generated
    if spec["manifest"] is None:
        raise ValueError("The additive candidate pack requires an explicit generated --manifest")
    return spec["manifest"], json.loads(spec["manifest"].read_text())


def verify_artifact(output, pack=DEFAULT_PACK, manifest_path=None):
    output = output.resolve(strict=True)
    manifest, pin = _manifest(pack, manifest_path)
    receipt_path = output / "atum-build-receipt.json"
    receipt = json.loads(receipt_path.read_text())
    if (receipt.get("status") != "PHONE_APPLE_LIBRARY_AND_SWIFT_COMPILED"
            or receipt.get("sourcePack") != pack
            or receipt.get("source", {}).get("sourcePack") != pack
            or receipt.get("source", {}).get("upstreamRevision") != pin["upstreamRevision"]
            or receipt.get("source", {}).get("sourceManifestSHA256") != digest(manifest)
            or receipt.get("targets") != list(TARGETS)):
        raise ValueError("Phone SDK build receipt authority mismatch")
    if (output / "Package.swift").read_text() != package_manifest():
        raise ValueError("Phone SDK local package manifest mismatch")
    if digest(output / "LICENSE") != pin["licenseSHA256"]:
        raise ValueError("Phone SDK licence mismatch")
    binding = output / "Sources/MatrixRustSDK/matrix_sdk_ffi.swift"
    markers = binding_markers(binding, PACKS[pack]["markers"])
    slices = slice_inventory(output / "MatrixSDKFFI.xcframework")
    archive = output / "MatrixSDKFFI.xcframework.zip"
    verify_zip(output / "MatrixSDKFFI.xcframework", archive)
    if digest(archive) != receipt.get("zipSHA256"):
        raise ValueError("Phone SDK zip checksum mismatch")
    files = artifact_files(output, receipt_path)
    if files != receipt.get("artifactSHA256"):
        raise ValueError("Phone SDK artifact file digest mismatch")
    if slices != receipt.get("slices") or markers != receipt.get("generatedSwift"):
        raise ValueError("Phone SDK artifact inventory mismatch")
    return receipt


def build(source, output, pack=DEFAULT_PACK, manifest_path=None):
    manifest, pin = _manifest(pack, manifest_path)
    source = source.resolve(strict=True)
    output = output.absolute()
    source_tools.verify_patched_source(source, pin)
    source_receipt = json.loads((source / "atum-source-receipt.json").read_text())
    if (source_receipt.get("status") != "SOURCE_PREPARED"
            or source_receipt.get("sourcePack") != pack
            or source_receipt.get("sourceManifestSHA256") != digest(manifest)
            or source_receipt.get("consumerHasUncommittedChanges") is not False):
        raise ValueError("Phone Apple build requires a clean committed source receipt")
    if output.exists():
        raise ValueError("Phone SDK output destination must be new")

    xtask = source / "xtask/src/swift.rs"
    before = xtask.read_bytes()
    pattern = b"rustup run stable cargo build -p matrix-sdk-ffi"
    if before.count(pattern) != 3:
        raise ValueError("SDK Swift build invocation changed")
    after = before.replace(
        pattern, b"rustup run 1.96.0 cargo build --locked -p matrix-sdk-ffi"
    )
    xtask.write_bytes(after)

    epoch = int(source_tools.command(["git", "show", "-s", "--format=%ct", "HEAD"], source))
    rustflags = " ".join(filter(None, (
        os.environ.get("RUSTFLAGS"), f"--remap-path-prefix={source}=/matrix-rust-sdk",
    )))
    environment = {
        **os.environ,
        "CARGO_BUILD_JOBS": "2",
        "CARGO_INCREMENTAL": "0",
        "SOURCE_DATE_EPOCH": str(epoch),
        "RUSTFLAGS": rustflags,
    }
    command = [
        "cargo", "+1.96.0", "run", "--locked", "-p", "xtask", "--",
        "swift", "build-framework", "--release",
    ]
    for target in TARGETS:
        command.extend(("--target", target))
    command.extend([
        "--components-path", str(output),
        "--ios-deployment-target", "26.0", "--sequentially",
    ])
    subprocess.run(command, cwd=source, env=environment, check=True)

    (output / "Package.swift").write_text(package_manifest())
    shutil.copyfile(source / "LICENSE", output / "LICENSE")
    binding = output / "Sources/MatrixRustSDK/matrix_sdk_ffi.swift"
    generated_swift = binding_markers(binding, PACKS[pack]["markers"])
    slices = slice_inventory(output / "MatrixSDKFFI.xcframework")

    derived = output.parent / f"{output.name}-swift-derived"
    if derived.exists():
        raise ValueError("Phone SDK Swift compile destination must be new")
    try:
        subprocess.run(
            swift_compile_command(derived),
            cwd=output,
            env=environment,
            check=True,
        )
    finally:
        shutil.rmtree(derived, ignore_errors=True)
        shutil.rmtree(output / ".build", ignore_errors=True)
        shutil.rmtree(output / ".swiftpm", ignore_errors=True)
        (output / "Package.resolved").unlink(missing_ok=True)

    archive = output / "MatrixSDKFFI.xcframework.zip"
    deterministic_zip(output / "MatrixSDKFFI.xcframework", archive, epoch)
    verify_zip(output / "MatrixSDKFFI.xcframework", archive)
    receipt_path = output / "atum-build-receipt.json"
    files = artifact_files(output, receipt_path)
    result = {
        "schemaVersion": 1,
        "status": "PHONE_APPLE_LIBRARY_AND_SWIFT_COMPILED",
        "source": source_receipt,
        "sourcePack": pack,
        "targets": list(TARGETS),
        "product": {"name": "MatrixRustSDK", "type": "dynamic", "platform": "iOS 26.0"},
        "xtaskBeforeSHA256": hashlib.sha256(before).hexdigest(),
        "xtaskAfterSHA256": hashlib.sha256(after).hexdigest(),
        "toolchain": source_tools.command(["rustc", "+1.96.0", "--version", "--verbose"], source),
        "xcode": source_tools.command(["xcodebuild", "-version"], source),
        "iphoneSDKVersion": source_tools.command(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], source),
        "generatedSwift": generated_swift,
        "slices": slices,
        "zipSHA256": digest(archive),
        "artifactSHA256": files,
        "scope": "Unsigned unselected iOS device/simulator SDK artifact; no package publication, app selection, device, Keychain, account, or migration",
    }
    receipt_path.write_text(json.dumps(result, indent=2) + "\n")
    verify_artifact(output, pack, manifest_path)
    print(f"PASS · LC4 phone SDK device/simulator artifact and generated Swift verified ({pack})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, nargs="?")
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--verify-only", type=Path)
    parser.add_argument("--unpack-retained", action="store_true",
                        help="Unpack a downloaded artifact's XCFramework zip before --verify-only")
    parser.add_argument("--pack", choices=tuple(PACKS), default=DEFAULT_PACK,
                        help="Immutable selected pack or the explicit additive candidate")
    parser.add_argument("--manifest", type=Path,
                        help="Generated source.json for the additive candidate pack")
    args = parser.parse_args()
    if args.verify_only is not None:
        if args.source is not None or args.output is not None:
            parser.error("--verify-only does not accept build positions")
        if args.unpack_retained:
            unpack_retained_artifact(args.verify_only)
        verify_artifact(args.verify_only, args.pack, args.manifest)
        print(f"PASS · existing LC4 phone SDK artifact verified ({args.pack})")
    else:
        if args.unpack_retained:
            parser.error("--unpack-retained requires --verify-only")
        if args.source is None or args.output is None:
            parser.error("source and output are required for a build")
        build(args.source, args.output, args.pack, args.manifest)
