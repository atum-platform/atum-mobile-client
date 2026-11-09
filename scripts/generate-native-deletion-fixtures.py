#!/usr/bin/env python3
"""Project accepted contract-e wire fixtures, preserving full-pack provenance."""
import argparse
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
shared = runpy.run_path(str(ROOT / "scripts/generate-native-api-fixtures.py"))
MESSAGES = frozenset({"deletion.status.response", "deletion.request", "deletion.accepted.response",
                      "deletion.progress.response", "deletion.error.response"})
OUTPUT = ROOT / "ios/Sources/AtumPrototype/Fixtures/provider-deletion-v1"


def generate():
    return shared["generate"](ROOT / "docs/contracts/provider/account-deletion/v1", MESSAGES)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    shared["write_or_check"](generate(), OUTPUT, args.check)
