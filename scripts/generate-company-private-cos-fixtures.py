#!/usr/bin/env python3
"""Verify frozen private-CoS packs and project read-only phone fixtures."""
import argparse
import json
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARED = runpy.run_path(str(ROOT / "scripts/generate-native-api-fixtures.py"))
PACK = ROOT / "docs/contracts/provider/company-private-cos"
OUTPUT = ROOT / "ios/Tests/Fixtures/company-private-cos"


def generate():
    result = {}
    commit = json.loads((PACK / "PROVENANCE.json").read_bytes())["providerCommit"]
    for version, messages in [
        ("v1", {"view.response", "ensure.response"}),
        ("v1.1", {"ensure.accepted.response"}),
        ("v1.2", set()),
        ("v1.3", {"capability.response"}),
        ("v2", {"capability"}),
    ]:
        # The asynchronous preparing response is also returned by GET view.
        projected = SHARED["generate"](PACK / version, frozenset(messages))
        manifest = json.loads(projected["manifest.json"])
        manifest["providerCommit"] = commit
        projected["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
        result.update({version + "-" + name: body for name, body in projected.items()})
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    SHARED["write_or_check"](generate(), OUTPUT, parser.parse_args().check)
