#!/bin/zsh
#   scripts/test.sh          run tests with coverage, print per-folder line summary
#   scripts/test.sh <extra xcodebuild args...>
#
# xcodegen generate → xcodebuild test (coverage on) → xccov JSON → per-folder
# line-coverage summary. Exits non-zero if tests fail or the result bundle is
# missing.
set -euo pipefail

cd "$(dirname "$0")/.."

RESULT_BUNDLE="build/cov.xcresult"

rm -rf "$RESULT_BUNDLE"

echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild test"
xcodebuild test \
  -project Mimi.xcodeproj \
  -scheme Mimi \
  -destination 'platform=macOS' \
  -enableCodeCoverage YES \
  -resultBundlePath "$RESULT_BUNDLE" \
  -quiet \
  "$@"

echo "==> coverage"
xcrun xccov view --report --json "$RESULT_BUNDLE" > build/cov.json

python3 - <<'PY'
import json, sys

with open("build/cov.json") as f:
    report = json.load(f)

prefixes = [
    ("State/",       "Mimi/State/"),
    ("Export/",      "Mimi/Export/"),
    ("Text/",        "Mimi/Text/"),
    ("Session/",     "Mimi/Session/"),
    ("Translation/", "Mimi/Translation/"),
    ("Model/",       "Mimi/Model/"),
    ("ASR/",         "Mimi/ASR/"),
    ("Audio/",       "Mimi/Audio/"),
    ("App/",         "Mimi/App/"),
    ("UI/",          "Mimi/UI/"),
]

agg = {label: [0, 0] for label, _ in prefixes}
files = []
for target in report.get("targets", []):
    for f in target.get("files", []):
        path = f.get("path", "")
        if "/Mimi/" not in path or "/MimiTests/" in path:
            continue
        cov = f.get("lineCoverage", 0.0)
        covered = f.get("coveredLines", 0)
        lines = f.get("executableLines", 0)
        files.append((path, cov, lines))
        for label, prefix in prefixes:
            if prefix in path:
                agg[label][0] += lines
                agg[label][1] += covered
                break

print(f"{'Folder / file':<28} {'line %':>8}  gate")
print("-" * 47)

floors = {
    "State/":       77.5,
    "Export/":     100.0,
    "Text/":        98.0,
    "Session/":     65.0,
    "Translation/": 96.5,
    "Model/":       79.5,
    "ASR/":         43.0,
    "Audio/":        8.0,
}
failed_gates = []
for label, _ in prefixes:
    total, covered = agg[label]
    pct = (covered / total * 100) if total else float("nan")
    floor = floors.get(label)
    if floor is None:
        verdict = "  (excluded)"
    elif pct >= floor:
        verdict = f"  PASS ≥ {floor:g}%"
    else:
        verdict = f"  FAIL < {floor:g}%"
        failed_gates.append(label)
    print(f"{label:<28} {pct:>7.1f}%{verdict}")
print("-" * 47)
for path, cov, lines in sorted(files):
    name = path.split("/Mimi/")[-1]
    print(f"{name:<28} {cov * 100:>7.1f}%  ({lines} lines)")

bad = [f for f in files if f[1] < 1.0]
if bad:
    print(f"\n{len(bad)} file(s) below 100%:", file=sys.stderr)
if failed_gates:
    print(f"\ncoverage gate FAILED: {', '.join(failed_gates)}", file=sys.stderr)
    sys.exit(1)
PY
