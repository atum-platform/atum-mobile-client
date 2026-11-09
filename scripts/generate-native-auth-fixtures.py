#!/usr/bin/env python3
"""Retain frozen static-client, binding and domain-lifecycle fixtures for P2."""
import argparse
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
shared = runpy.run_path(str(ROOT / "scripts/generate-native-api-fixtures.py"))
MESSAGES = frozenset({"ios.client_registration", "binding.facts"})
OUTPUT = ROOT / "ios/Sources/AtumPrototype/Fixtures/provider-auth-v1"


def generate():
    return shared["generate"](ROOT / "docs/contracts/provider/mobile-native-api/v1", MESSAGES, frozenset({"domain_grant"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    shared["write_or_check"](generate(), OUTPUT, args.check)
