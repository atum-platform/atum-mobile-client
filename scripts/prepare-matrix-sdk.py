#!/usr/bin/env python3
"""Prepare one immutable Apache SDK source tree for custody conformance/build.

No credentials, product stores, or signing material are inputs. The destination
must be new; failure leaves diagnostic source in place and never repairs it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = {
    "custody": ROOT / "sdk/custody/source.json",
    "phone-26.10.15": ROOT / "sdk/phone-26.10.15/source.json",
}
CANDIDATE_PACK = "phone-26.10.15-founder"
PACK_CHOICES = tuple(MANIFESTS) + (CANDIDATE_PACK,)
# Backward-compatible authority for the historical candidate scripts that
# import this module directly. Their default remains custody and never follows
# the selected phone package implicitly.
MANIFEST = MANIFESTS["custody"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(arguments, cwd):
    process = subprocess.Popen(arguments, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        # Git's transport children also hold the pipe. End this operation's
        # own process group so a timed-out fetch cannot retain the caller.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, arguments)
    return output.decode().strip()


def changed_paths(destination):
    changed = set(command(["git", "diff", "HEAD", "--name-only"], destination).splitlines())
    changed.update(command(["git", "ls-files", "--others", "--exclude-standard"], destination).splitlines())
    return changed


def candidate_pin(pending, destination):
    """Compute the exact patched hashes for one pending additive manifest."""
    changed = changed_paths(destination)
    if changed != set(pending["preimageSHA256"]):
        raise ValueError("Patched SDK source changed an unexpected file set")
    patched = {
        relative: digest(destination / relative)
        for relative in sorted(pending["preimageSHA256"])
    }
    result = {key: value for key, value in pending.items()
              if key not in {"patchedSHA256", "pendingGeneration"}}
    result["patchedSHA256"] = patched
    result["status"] = "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED"
    return result


def verify_patched_source(destination, pin):
    if (command(["git", "rev-parse", "HEAD"], destination) != pin["upstreamRevision"]
            or command(["git", "remote", "get-url", "origin"], destination) != pin["upstreamURL"]):
        raise ValueError("SDK patched checkout authority mismatch")
    changed = changed_paths(destination)
    if changed - {*pin["patchedSHA256"], "atum-source-receipt.json"}:
        raise ValueError("Unexpected SDK source changes")
    for relative, expected in pin["patchedSHA256"].items():
        path = destination / relative
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ValueError("SDK patched source digest mismatch")
    if digest(destination / "LICENSE") != pin["licenseSHA256"]:
        raise ValueError("SDK Apache license mismatch")


def prepare(destination, source_cache=None, pack="custody", manifest=None,
            bootstrap_manifest=None, bootstrap_output=None):
    if manifest is None and bootstrap_manifest is None and pack not in MANIFESTS:
        raise ValueError(f"{pack} requires --bootstrap-manifest or --manifest")
    if bootstrap_manifest is not None:
        if bootstrap_output is None:
            raise ValueError("Bootstrap preparation requires a generated manifest output")
        manifest = bootstrap_manifest.resolve(strict=True)
        pin = json.loads(manifest.read_text())
        if (pin.get("status") != "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION"
                or pin.get("patchedSHA256") is not None):
            raise ValueError("Bootstrap preparation requires a pending manifest")
    else:
        manifest = manifest or MANIFESTS[pack]
        pin = json.loads(manifest.read_text())
    patch = ROOT / pin["patch"]
    if digest(patch) != pin["patchSHA256"]:
        raise ValueError(f"{pack} patch digest mismatch")
    destination = destination.absolute()
    if destination.exists():
        raise ValueError("SDK source destination must be new")
    if source_cache is not None:
        source_cache = source_cache.resolve(strict=True)
        if (command(["git", "rev-parse", "HEAD"], source_cache) != pin["upstreamRevision"]
                or command(["git", "remote", "get-url", "origin"], source_cache) != pin["upstreamURL"]):
            raise ValueError("SDK source cache authority mismatch")
    destination.mkdir(parents=True, mode=0o700)
    if source_cache is None:
        command(["git", "init", "."], destination)
        command(["git", "remote", "add", "origin", pin["upstreamURL"]], destination)
        command(["git", "-c", "http.lowSpeedLimit=1024", "-c", "http.lowSpeedTime=30",
                 "fetch", "--depth=1", "origin", pin["upstreamRevision"]], destination)
        command(["git", "checkout", "--detach", "FETCH_HEAD"], destination)
    else:
        # Clone committed objects only, never the cache's working files.
        command(["git", "clone", "--no-hardlinks", "--no-checkout", str(source_cache), "."], destination)
        command(["git", "remote", "set-url", "origin", pin["upstreamURL"]], destination)
        command(["git", "checkout", "--detach", pin["upstreamRevision"]], destination)
    if command(["git", "rev-parse", "HEAD"], destination) != pin["upstreamRevision"]:
        raise ValueError("SDK source revision mismatch")
    for relative, expected in pin["preimageSHA256"].items():
        path = destination / relative
        if expected is None:
            if path.exists():
                raise ValueError("New SDK test already exists")
        elif not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ValueError("SDK source preimage mismatch")
    command(["git", "apply", "--check", str(patch)], destination)
    command(["git", "apply", str(patch)], destination)
    receipt_manifest = manifest
    if bootstrap_manifest is not None:
        bootstrap_output = bootstrap_output.resolve()
        if bootstrap_output.is_relative_to(destination):
            raise ValueError("Generated manifest output must be outside the source tree")
        if bootstrap_output.exists():
            raise ValueError("Generated manifest output must be new")
        pin = candidate_pin(pin, destination)
        bootstrap_output.write_text(json.dumps(pin, indent=2) + "\n")
        receipt_manifest = bootstrap_output
    verify_patched_source(destination, pin)
    receipt = {**pin, "schemaVersion": 1, "status": "SOURCE_PREPARED",
        "runtimeStatus": pin["status"],
        "consumerRevision": command(["git", "rev-parse", "HEAD"], ROOT),
        "consumerHasUncommittedChanges": bool(command(["git", "status", "--porcelain"], ROOT)),
        "sourceManifestSHA256": digest(receipt_manifest),
        "sourcePack": pack,
        "scope": "Source preparation only; not compilation, runtime, code review, or gate acceptance"}
    (destination / "atum-source-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("PASS · immutable SDK source/preimages/patch/license verified; build and runtime still required")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--source-cache", type=Path, help="Optional already-fetched official pinned Git checkout")
    parser.add_argument("--pack", choices=PACK_CHOICES, default="custody",
                        help="Static selected pack, or the explicit additive Founder candidate")
    parser.add_argument("--manifest", type=Path,
                        help="An explicit generated source.json (for an additive pack)")
    parser.add_argument("--bootstrap-manifest", type=Path,
                        help="A pending additive source.pending.json to apply and hash")
    parser.add_argument("--bootstrap-output", type=Path,
                        help="New path for the generated source.json outside the source tree")
    args = parser.parse_args()
    if args.bootstrap_manifest is not None and args.manifest is not None:
        parser.error("--manifest and --bootstrap-manifest are exclusive")
    try:
        prepare(args.destination, args.source_cache, args.pack, args.manifest,
                args.bootstrap_manifest, args.bootstrap_output)
    except ValueError as error:
        raise SystemExit(f"SDK source preparation refused: {error}") from None
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        raise SystemExit("SDK source preparation refused; no product data addressed") from None
