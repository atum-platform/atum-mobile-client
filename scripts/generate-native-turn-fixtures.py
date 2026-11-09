#!/usr/bin/env python3
"""Project frozen contract-c contents and client transitions for P2."""
import argparse
import runpy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
shared = runpy.run_path(str(ROOT / "scripts/generate-native-api-fixtures.py"))
MESSAGES = frozenset({"turn.answer_content", "turn.status_notice_content", "agents.readiness_entry", "turn.state.request", "turn.state.response"})
OUTPUT = ROOT / "ios/Sources/AtumPrototype/Fixtures/provider-turns-v1"


def generate():
    return shared["generate"](ROOT / "docs/contracts/provider/agent-turns/v1", MESSAGES, frozenset({"client_turn"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    shared["write_or_check"](generate(), OUTPUT, args.check)
