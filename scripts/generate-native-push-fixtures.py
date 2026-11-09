#!/usr/bin/env python3
"""Project accepted contract-b iOS message fixtures, with the original pack pin."""
import argparse
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
shared = runpy.run_path(str(ROOT / "scripts/generate-native-api-fixtures.py"))
MESSAGES = frozenset({"pusher.set.request", "pusher.delete.request", "apns.payload"})
OUTPUT = ROOT / "ios/Sources/AtumPrototype/Fixtures/provider-push-v1"


def generate():
    return shared["generate"](ROOT / "docs/contracts/provider/mobile-push/v1", MESSAGES)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    shared["write_or_check"](generate(), OUTPUT, args.check)
