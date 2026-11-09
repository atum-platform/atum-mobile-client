#!/usr/bin/env python3
"""Generate the phone's Phosphor custom-symbol assets from the Atum Kit export.

The Kit draws every icon with Phosphor Light (Fill only for a selected state,
STYLE §8). atum-app ships the paths in `packages/atum-kit/dist/phosphor-icons.json`;
`packages/mobile-design-exports` does not carry them yet (atum-app export gap F11),
so this script reads the Kit file at the design pin and vendors only the icons the
phone maps in `ios/Vendor/AtumKitIcons/phosphor-map.json`.

  generate-phosphor-symbols.py --source <phosphor-icons.json> --revision <sha>
      refresh the vendored subset from an atum-app checkout's Kit file
  generate-phosphor-symbols.py
      regenerate the .symbolset assets from the vendored subset
  generate-phosphor-symbols.py --check
      fail if the assets differ from what the vendored subset would generate

Each symbol is a Regular-M-only custom symbol template (v3.0). One em (the
template's 100 pt) is one Phosphor box (256 units), so `.font(.system(size: 20))`
draws the Kit's 20 pt icon, centred on the cap height like an SF Symbol.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "ios/Vendor/AtumKitIcons"
MAP = VENDOR / "phosphor-map.json"
SUBSET = VENDOR / "phosphor-icons.json"
ASSETS = ROOT / "ios/App/Assets.xcassets/Phosphor"
SWIFT = ROOT / "ios/App/DesignSystem/PhosphorSymbols.swift"

BOX = 256.0
EM = 100.0
LEFT = 1391.3
BASELINE = 1126.0
CAPLINE = 1055.54
SCALE = EM / BOX
TOP = (BASELINE + CAPLINE) / 2 - EM / 2


def load_map():
    entries = json.loads(MAP.read_text())["aliases"]
    result = {}
    for alias, value in entries.items():
        if isinstance(value, str):
            value = {"name": value, "weight": "light"}
        result[alias] = (value["name"], value.get("weight", "light"))
    return result


def asset_name(name, weight):
    return f"ph.{name}" + (".fill" if weight == "fill" else "")


TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def fmt(value):
    text = f"{value:.3f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def transform_path(d):
    """Absolute coordinates, scaled into the template's Regular-M box.

    A uniform scale plus a translation keeps every SVG command's meaning, so
    S/T reflections and arc flags carry over unchanged.
    """
    tokens = TOKEN.findall(d)
    if not tokens:
        raise SystemExit("empty path")
    out = []
    i = 0
    cx = cy = sx = sy = 0.0
    command = None

    def X(x):
        return fmt(LEFT + x * SCALE)

    def Y(y):
        return fmt(TOP + y * SCALE)

    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]
            i += 1
            if command in "Zz":
                out.append("Z")
                cx, cy = sx, sy
                continue
        elif command is None:
            raise SystemExit("path starts without a command")
        upper = command.upper()
        relative = command.islower()
        values = [float(v) for v in tokens[i:i + ARITY[upper]]]
        if len(values) != ARITY[upper]:
            raise SystemExit(f"truncated {command} segment")
        i += ARITY[upper]
        if upper == "H":
            x = values[0] + (cx if relative else 0)
            out.append(f"H{X(x)}")
            cx = x
        elif upper == "V":
            y = values[0] + (cy if relative else 0)
            out.append(f"V{Y(y)}")
            cy = y
        elif upper == "A":
            rx, ry, rotation, large, sweep, x, y = values
            if relative:
                x, y = x + cx, y + cy
            out.append(f"A{fmt(rx * SCALE)} {fmt(ry * SCALE)} {fmt(rotation)} {int(large)} {int(sweep)} {X(x)} {Y(y)}")
            cx, cy = x, y
        else:
            points = []
            for j in range(0, len(values), 2):
                x, y = values[j], values[j + 1]
                if relative:
                    x, y = x + cx, y + cy
                points.append((x, y))
            out.append(upper + " ".join(f"{X(x)} {Y(y)}" for x, y in points))
            cx, cy = points[-1]
            if upper == "M":
                sx, sy = cx, cy
                command = "l" if relative else "L"
    return " ".join(out)


def template(name, weight, paths):
    body = "\n".join(f'   <path d="{transform_path(d)}"/>' for d in paths)
    line = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
    guides = "\n".join(
        f'  <line id="{gid}" {line} x1="263" x2="3036" y1="{y}" y2="{y}"/>'
        for gid, y in (("Baseline-S", 696), ("Capline-S", 625.541),
                       ("Baseline-M", 1126), ("Capline-M", 1055.54),
                       ("Baseline-L", 1556), ("Capline-L", 1485.54)))
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<!-- Generated by scripts/generate-phosphor-symbols.py from Phosphor {name} ({weight}). Do not edit. -->
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1933)">{asset_name(name, weight)}</text>
 </g>
 <g id="Guides">
{guides}
  <line id="left-margin-Regular-M" {line} x1="{fmt(LEFT)}" x2="{fmt(LEFT)}" y1="1030.79" y2="1150.12"/>
  <line id="right-margin-Regular-M" {line} x1="{fmt(LEFT + EM)}" x2="{fmt(LEFT + EM)}" y1="1030.79" y2="1150.12"/>
 </g>
 <g id="Symbols">
  <g id="Regular-M">
{body}
  </g>
 </g>
</svg>
'''


def contents(filename):
    return json.dumps({"info": {"author": "xcode", "version": 1},
                       "properties": {"preserves-vector-representation": True,
                                      "template-rendering-intent": "template"},
                       "symbols": [{"filename": filename, "idiom": "universal"}]}, indent=2) + "\n"


def expected_files(subset):
    files = {"Contents.json": json.dumps({"info": {"author": "xcode", "version": 1},
                                          "properties": {"provides-namespace": False}}, indent=2) + "\n"}
    for alias, (name, weight) in sorted(load_map().items()):
        paths = subset[weight].get(name)
        if not paths:
            raise SystemExit(f"{alias}: Phosphor {weight} '{name}' is not in the vendored subset")
        asset = asset_name(name, weight)
        files[f"{asset}.symbolset/{asset}.svg"] = template(name, weight, paths)
        files[f"{asset}.symbolset/Contents.json"] = contents(f"{asset}.svg")
    return files


def swift_map():
    lines = [f'        "{alias}": "{asset_name(name, weight)}",' for alias, (name, weight) in sorted(load_map().items())]
    return ("// Generated by scripts/generate-phosphor-symbols.py from\n"
            "// ios/Vendor/AtumKitIcons/phosphor-map.json. Do not edit.\n\n"
            "/// Exported glyph alias -> the Phosphor custom symbol in Assets.xcassets/Phosphor.\n"
            "enum PhosphorSymbols {\n"
            "    static let aliases: [String: String] = [\n" + "\n".join(lines) + "\n    ]\n}\n")


def refresh_subset(source, revision):
    data = source.read_bytes()
    kit = json.loads(data)
    wanted = sorted(set(load_map().values()))
    subset = {"source": {"repository": "atum-platform/atum-app",
                         "path": "packages/atum-kit/dist/phosphor-icons.json",
                         "revision": revision,
                         "sha256": hashlib.sha256(data).hexdigest()},
              "phosphorVersion": kit["phosphorVersion"], "viewBox": kit["viewBox"],
              "light": {}, "fill": {}}
    for name, weight in wanted:
        if name not in kit[weight]:
            raise SystemExit(f"Phosphor {weight} '{name}' is missing from the Kit export")
        subset[weight][name] = kit[weight][name]
    SUBSET.write_text(json.dumps(subset, indent=2, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.source:
        if not args.revision:
            parser.error("--source needs --revision")
        refresh_subset(args.source, args.revision)
    subset = json.loads(SUBSET.read_text())
    if subset["viewBox"] != [0, 0, 256, 256]:
        raise SystemExit("unexpected Phosphor viewBox")
    files = expected_files(subset)
    if args.check:
        actual = {str(p.relative_to(ASSETS)): p.read_text() for p in ASSETS.rglob("*") if p.is_file()} if ASSETS.exists() else {}
        if SWIFT.read_text() != swift_map():
            print("PhosphorSymbols.swift is stale", file=sys.stderr)
            return 1
        if actual != files:
            stale = sorted(set(actual) ^ set(files) | {k for k in files if actual.get(k) != files[k]})
            print("Phosphor symbols are stale:", *stale[:10], sep="\n  ", file=sys.stderr)
            return 1
        print(f"Phosphor symbols match ({len(files) // 2} symbols).")
        return 0
    if ASSETS.exists():
        shutil.rmtree(ASSETS)
    for relative, text in files.items():
        path = ASSETS / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    SWIFT.write_text(swift_map())
    print(f"Wrote {len(files) // 2} Phosphor symbols to {ASSETS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
