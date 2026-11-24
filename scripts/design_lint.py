#!/usr/bin/env python3
"""Design lint: no new raw spacing, radii, font sizes or animation curves in the app.

The phone's tokens live in `ios/App/DesignSystem/` (`kit.space(.sN)`,
`kit.phoneRadius(_:)`, `kit.font(_:)`, `Motion`). Every other Swift file under
`ios/App/` is counted for five kinds of drift:

  padding    `.padding(12)`, `.padding(.horizontal, 12)`, `.safeAreaPadding(…)`,
             `EdgeInsets(top: 8, …)` (each non-zero edge counts)
  spacing    `spacing: 8`, `horizontalSpacing:` / `verticalSpacing:` literals
  radius     `cornerRadius: 14`, `.cornerRadius(14)`, `topLeadingRadius: 18`,
             `RectangleCornerRadii(topLeading: 18, …)` literals
  font-size  `.system(size: …)`
  animation  a bare curve (`.easeOut`, `.spring(…)`, `.snappy`, `.linear`, …),
             `.default` as an animation, or a bare `withAnimation {}`

Zero is not drift (`spacing: 0`, `.padding(0)`). Comments and string literals are
ignored. A line carrying `design-lint: allow` (with a reason) is skipped; use it for
geometry that is not spacing, such as a 1 pt hairline or an ambient loop.

Counts are compared per file and kind with `scripts/design-lint-baseline.json`, the
counts on the day the lint landed. A count above its baseline fails (new drift; a new
file starts at zero). A count below its baseline also fails until `--update` locks the
progress in, so a migrated file cannot quietly drift back.

  python3 scripts/design_lint.py            # check (exit 1 on new drift)
  python3 scripts/design_lint.py --update   # rewrite the baseline to today's counts

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN = "ios/App"
EXEMPT = "ios/App/DesignSystem/"
BASELINE = "scripts/design-lint-baseline.json"
ALLOW = "design-lint: allow"
KINDS = ("padding", "spacing", "radius", "font-size", "animation")

_NUMBER = r"-?\d+(?:\.\d+)?"
_EDGES = re.compile(rf"\b(?:top|leading|bottom|trailing)\s*:\s*({_NUMBER})")
_CORNERS = re.compile(
    rf"\b(?:topLeading|topTrailing|bottomLeading|bottomTrailing)\s*:\s*({_NUMBER})"
)
_CURVES = (
    "easeIn", "easeOut", "easeInOut", "linear", "spring", "interactiveSpring",
    "interpolatingSpring", "snappy", "smooth", "bouncy", "timingCurve",
)

# (kind, pattern, group holding the literal or None, group holding an argument list or None)
_RULES: tuple[tuple[str, re.Pattern[str], int | None, int | None], ...] = (
    ("padding", re.compile(
        rf"\.(?:padding|safeAreaPadding)\(\s*(?:(?:\.[A-Za-z]+|\[[^\]]*\])\s*,\s*)?({_NUMBER})\s*\)"), 1, None),
    ("padding", re.compile(r"\bEdgeInsets\(([^)]*)\)"), None, 1),
    ("spacing", re.compile(
        rf"\b(?:spacing|horizontalSpacing|verticalSpacing)\s*:\s*({_NUMBER})(?![\w.])"), 1, None),
    ("radius", re.compile(
        rf"\b(?:cornerRadius|topLeadingRadius|topTrailingRadius|bottomLeadingRadius|"
        rf"bottomTrailingRadius)\s*[:(]\s*({_NUMBER})(?![\w.])"), 1, None),
    ("radius", re.compile(r"\bRectangleCornerRadii\(([^)]*)\)"), None, 1),
    ("font-size", re.compile(r"\.system\(\s*size\s*:"), None, None),
    ("animation", re.compile(rf"\.(?:{'|'.join(_CURVES)})\b"), None, None),
    ("animation", re.compile(
        r"(?:\bAnimation\.default\b|\.animation\(\s*\.default\b|\bwithAnimation\(\s*\.default\b)"),
        None, None),
    ("animation", re.compile(r"\bwithAnimation\s*(?:\{|\(\s*\))"), None, None),
)


def strip_comments_and_strings(source: str) -> str:
    """Blanks comments and string contents, keeping every newline and offset."""
    out = list(source)
    i, n = 0, len(source)

    def blank(start: int, end: int) -> None:
        for k in range(start, min(end, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end == -1 else end
            blank(i, end)
            i = end
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            end = n if end == -1 else end + 3
            blank(i + 3, end - 3)
            i = end
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] not in '"\n':
                j += 2 if source[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)


def findings(source: str) -> list[tuple[str, int]]:
    """Every drift occurrence in one Swift source, as (kind, 1-based line)."""
    code = strip_comments_and_strings(source)
    lines = source.split("\n")
    found: list[tuple[str, int]] = []
    for kind, pattern, literal, arguments in _RULES:
        for match in pattern.finditer(code):
            line = code.count("\n", 0, match.start()) + 1
            if ALLOW in lines[line - 1]:
                continue
            if literal is not None:
                if float(match.group(literal)) != 0:
                    found.append((kind, line))
            elif arguments is not None:
                inner = _EDGES if kind == "padding" else _CORNERS
                for value in inner.findall(match.group(arguments)):
                    if float(value) != 0:
                        found.append((kind, line))
            else:
                found.append((kind, line))
    return sorted(found, key=lambda item: (item[1], KINDS.index(item[0])))


def scan(root: Path) -> dict[str, list[tuple[str, int]]]:
    """Findings for every scanned file that has any, keyed by repo-relative path."""
    result: dict[str, list[tuple[str, int]]] = {}
    for path in sorted((root / SCAN).rglob("*.swift")):
        relative = path.relative_to(root).as_posix()
        if relative.startswith(EXEMPT):
            continue
        found = findings(path.read_text(encoding="utf-8"))
        if found:
            result[relative] = found
    return result


def counts(found: dict[str, list[tuple[str, int]]]) -> dict[str, dict[str, int]]:
    table: dict[str, dict[str, int]] = {}
    for relative, items in found.items():
        row: dict[str, int] = {}
        for kind, _ in items:
            row[kind] = row.get(kind, 0) + 1
        table[relative] = {kind: row[kind] for kind in KINDS if kind in row}
    return table


def load_baseline(path: Path) -> dict[str, dict[str, int]]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("files", {})


def write_baseline(path: Path, table: dict[str, dict[str, int]]) -> None:
    data = {
        "about": "Design lint counts per file; see scripts/design_lint.py. "
                 "Lower a count by migrating to tokens, then run --update.",
        "files": {relative: table[relative] for relative in sorted(table)},
    }
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def check(root: Path, baseline_path: Path, out=sys.stdout) -> int:
    found = scan(root)
    current = counts(found)
    baseline = load_baseline(baseline_path)
    drift: list[str] = []
    stale: list[str] = []
    for relative in sorted(set(current) | set(baseline)):
        now = current.get(relative, {})
        was = baseline.get(relative, {})
        for kind in KINDS:
            have, allowed = now.get(kind, 0), was.get(kind, 0)
            if have > allowed:
                drift.append(f"{relative}: {kind} {have} > baseline {allowed}")
                drift.extend(f"  {relative}:{line}: raw {kind}"
                             for item_kind, line in found[relative] if item_kind == kind)
            elif have < allowed:
                stale.append(f"{relative}: {kind} {have} < baseline {allowed}")
    if drift:
        print("design lint: new raw values outside ios/App/DesignSystem/. Use kit.space(.sN), "
              "kit.phoneRadius(_:), kit.font(_:) or Motion; mark a real exception with "
              f"'// {ALLOW}: <reason>'.", file=out)
        print("\n".join(drift), file=out)
    if stale:
        print("design lint: fewer raw values than the baseline. Lock the progress in with "
              "`python3 scripts/design_lint.py --update` and commit the baseline.", file=out)
        print("\n".join(stale), file=out)
    if drift or stale:
        return 1
    total = sum(sum(row.values()) for row in current.values())
    print(f"design lint: OK ({total} baseline findings in {len(current)} files)", file=out)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--update", action="store_true", help="rewrite the baseline to today's counts")
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    baseline_path = args.root / BASELINE
    if args.update:
        table = counts(scan(args.root))
        write_baseline(baseline_path, table)
        print(f"design lint: wrote {baseline_path.relative_to(args.root)} "
              f"({sum(sum(r.values()) for r in table.values())} findings in {len(table)} files)")
        return 0
    return check(args.root, baseline_path)


if __name__ == "__main__":
    sys.exit(main())
