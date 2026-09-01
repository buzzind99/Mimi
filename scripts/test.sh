#!/bin/zsh
#   scripts/test.sh          run tests with coverage, print compact summary
#   scripts/test.sh <extra xcodebuild args...>
#
# xcodegen generate → xcodebuild test (coverage on) → xccov JSON → compact
# summary: overall %, failing gates, uncovered lines in failed folders only.
# Full detail: build/cov.json, build/lcov.info, build/cov-html/index.html.
# Exits non-zero if tests fail, the result bundle is missing, or a coverage
# gate fails.
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
import json, os, shutil, subprocess, sys

with open("build/cov.json") as f:
    report = json.load(f)

prefixes = [
    ("State/",       "Mimi/State/"),
    ("Export/",      "Mimi/Export/"),
    ("Dictionary/",  "Mimi/Dictionary/"),
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
overall = [0, 0]
for target in report.get("targets", []):
    for f in target.get("files", []):
        path = f.get("path", "")
        if "/Mimi/" not in path or "/MimiTests/" in path:
            continue
        covered = f.get("coveredLines", 0)
        lines = f.get("executableLines", 0)
        overall[0] += lines
        overall[1] += covered
        for label, prefix in prefixes:
            if prefix in path:
                agg[label][0] += lines
                agg[label][1] += covered
                break

floors = {
    "State/":       77.5,
    "Export/":     100.0,
    "Dictionary/":  98.0,
    "Text/":        98.0,
    "Session/":     65.0,
    "Translation/": 96.5,
    "Model/":       79.5,
    "ASR/":         43.0,
    "Audio/":        8.0,
}
failed_gates = []
passed = 0
for label, _ in prefixes:
    floor = floors.get(label)
    if floor is None:
        continue
    total, covered = agg[label]
    pct = (covered / total * 100) if total else float("nan")
    if pct >= floor:
        passed += 1
    else:
        failed_gates.append((label, pct, floor))

total_lines, covered_lines = overall
overall_pct = (covered_lines / total_lines * 100) if total_lines else float("nan")
print(f"coverage: {overall_pct:.1f}% ({covered_lines}/{total_lines} lines) "
      f"· gates {passed}/{len(floors)} PASS")
for label, pct, floor in failed_gates:
    print(f"  ✗ {label:<14}{pct:>6.1f}% < {floor:g}%")

# Per-line data: build/lcov.info + uncovered report; full detail in artifacts.
xccov = subprocess.run(["xcrun", "--find", "xccov"],
                       capture_output=True, text=True, check=True).stdout.strip()

records = []
for path in subprocess.run(
        [xccov, "view", "--archive", "--file-list", "build/cov.xcresult"],
        capture_output=True, text=True, check=True).stdout.splitlines():
    if "/Mimi/" not in path or "/MimiTests/" in path:
        continue
    doc = json.loads(subprocess.run(
        [xccov, "view", "--archive", "--json", "--file", path, "build/cov.xcresult"],
        capture_output=True, text=True, check=True).stdout)
    per_line = doc.get(path) if isinstance(doc, dict) else doc
    da = sorted((e["line"], e.get("executionCount", 0))
                for e in per_line if e.get("isExecutable"))
    records.append((os.path.relpath(path, os.getcwd()), da))

with open("build/lcov.info", "w") as f:
    for rel, da in records:
        f.write(f"SF:{rel}\n")
        for line, count in da:
            f.write(f"DA:{line},{count}\n")
        f.write(f"LF:{len(da)}\nLH:{sum(1 for _, c in da if c)}\nend_of_record\n")

if failed_gates:
    prefix_of = dict(prefixes)
    failed_prefixes = [prefix_of[label] for label, _, _ in failed_gates]
    uncovered = []
    for rel, da in records:
        if not any(rel.startswith(p) for p in failed_prefixes):
            continue
        misses = [line for line, count in da if count == 0]
        if misses:
            ranges = []
            start = prev = misses[0]
            for line in misses[1:]:
                if line == prev + 1:
                    prev = line
                else:
                    ranges.append((start, prev))
                    start = prev = line
            ranges.append((start, prev))
            uncovered.append((rel, len(misses), ranges))
    if uncovered:
        print("\nuncovered in failed gates:")
        for rel, count, ranges in sorted(uncovered, key=lambda r: (-r[1], r[0])):
            span = ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in ranges)
            print(f"  {rel:<44} {count:>3}  lines: {span}")

shutil.rmtree("build/cov-html", ignore_errors=True)
gen = subprocess.run(["genhtml", "build/lcov.info", "-o", "build/cov-html", "--quiet"],
                     capture_output=True, text=True)
if gen.returncode == 0:
    detail = "build/cov-html/index.html · build/lcov.info"
else:
    print(gen.stderr or gen.stdout, end="")
    detail = "build/lcov.info (genhtml failed)"
print(f"\ndetail: {detail}")
print("RESULT: FAIL" if failed_gates else "RESULT: PASS")
if failed_gates:
    sys.exit(1)
PY
