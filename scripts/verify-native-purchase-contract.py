#!/usr/bin/env python3
"""Verify the public d1 contract text subset; full-pack verification stays private."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "docs/contracts/provider/mobile-purchases/v1"


def verify(pack=PACK):
    entries = [line.split("  ") for line in (pack / "PINNED-SHA256").read_text().splitlines()]
    if len(entries) != 2 or {entry[1] for entry in entries if len(entry) == 2} != {
        "README.md", "contract.json"
    }:
        raise ValueError("public checksum manifest must name only README.md and contract.json")
    for digest, name in entries:
        if hashlib.sha256((pack / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"public contract checksum mismatch: {name}")
    if (pack / "fixtures").exists():
        raise ValueError("upstream d1 fixture files must remain private")


if __name__ == "__main__":
    verify()
    print("PASS: public d1 README.md and contract.json SHA-256; full-pack verification stays private")
