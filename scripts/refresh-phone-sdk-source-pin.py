#!/usr/bin/env python3
"""Refresh one additive phone SDK source manifest from an exact upstream tree.

The selected cf18be30 distribution and its `sdk/phone-26.10.15` source pack are
immutable. This generator is for a new pending source pack whose patch has not
yet been applied to a local upstream checkout. It verifies the exact upstream
authority and every preimage, applies the pending patch in a disposable git
worktree, and writes the final `source.json` with the real patched byte hashes.

It performs no network, download, native build, signing or selection.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import shutil


ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def command(arguments, cwd):
    completed = subprocess.run(arguments, cwd=cwd, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True)
    return completed.stdout.strip()


def bytes_at(source, path):
    return subprocess.run(
        ["git", "show", f"HEAD:{path}"], cwd=source, check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout


def refresh(source, pending_manifest, output=None):
    source = source.resolve(strict=True)
    pending_manifest = pending_manifest.resolve(strict=True)
    pin = json.loads(pending_manifest.read_text())
    if pin.get("status") != "SOURCE_PATCH_CANDIDATE_PENDING_GENERATION":
        raise ValueError("source manifest is not a pending additive candidate")
    if command(["git", "rev-parse", "HEAD"], source) != pin["upstreamRevision"]:
        raise ValueError("upstream revision mismatch")
    if command(["git", "remote", "get-url", "origin"], source) != pin["upstreamURL"]:
        raise ValueError("upstream origin mismatch")
    if command(["git", "status", "--porcelain"], source):
        raise ValueError("upstream source checkout must be clean")
    if digest(source / "LICENSE") != pin["licenseSHA256"]:
        raise ValueError("upstream Apache license mismatch")

    preimages = pin["preimageSHA256"]
    for relative, expected in preimages.items():
        actual = hashlib.sha256(bytes_at(source, relative)).hexdigest()
        if actual != expected:
            raise ValueError(f"upstream preimage mismatch: {relative}")

    patch = Path(pin["patch"])
    if not patch.is_absolute():
        patch = (ROOT / patch).resolve()
    if digest(patch) != pin["patchSHA256"]:
        raise ValueError("pending patch digest mismatch")

    temporary = Path(tempfile.mkdtemp(prefix="atum-phone-founder-pin-"))
    tree = temporary / "tree"
    worktree_added = False
    try:
        command(["git", "worktree", "add", "--detach", "--force", str(tree), "HEAD"], source)
        worktree_added = True
        command(["git", "apply", "--check", str(patch)], tree)
        command(["git", "apply", str(patch)], tree)
        changed = set(command(["git", "diff", "HEAD", "--name-only"], tree).splitlines())
        changed.update(command(["git", "ls-files", "--others", "--exclude-standard"], tree).splitlines())
        if changed != set(preimages):
            raise ValueError("patched source changed an unexpected file set")
        patched = {relative: digest(tree / relative) for relative in sorted(preimages)}

        result = {key: value for key, value in pin.items()
                  if key not in {"patchedSHA256", "pendingGeneration"}}
        result["patchedSHA256"] = patched
        result["status"] = "SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED"
        result["generatedFrom"] = {
            "pendingManifestSHA256": digest(pending_manifest),
            "upstreamRevision": pin["upstreamRevision"],
        }
        destination = (output or pending_manifest.with_name("source.json")).resolve()
        destination.write_text(json.dumps(result, indent=2) + "\n")
        return destination
    finally:
        if worktree_added:
            subprocess.run(["git", "worktree", "remove", "--force", str(tree)],
                           cwd=source, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(temporary, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path,
                        help="Clean exact upstream matrix-rust-sdk checkout")
    parser.add_argument("pending_manifest", type=Path,
                        help="source.pending.json for the additive pack")
    parser.add_argument("--output", type=Path,
                        help="Generated source.json (default: beside the pending manifest)")
    arguments = parser.parse_args()
    try:
        destination = refresh(arguments.source, arguments.pending_manifest,
                              arguments.output)
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"SDK source pin refresh refused: {error}") from None
    print(f"PASS · generated {destination}")


if __name__ == "__main__":
    main()
