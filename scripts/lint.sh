#!/bin/zsh
#   scripts/lint.sh          check only (exit 1 on issues)
#   scripts/lint.sh --fix    auto-format in place, then re-check
#
# Compact output: one line per tool when clean; on violations, violations
# grouped by rule as rule: file:line-ranges. Raw tool output: build/lint.log.
# SwiftLint warnings are display-only; SwiftFormat violations and SwiftLint
# errors fail the script.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build
: > build/lint.log

fail=0

if [[ "${1:-}" == "--fix" ]]; then
  swiftformat . --quiet >> build/lint.log 2>&1
  echo "Formatted."
fi

# Capture both tools (no --quiet for swiftformat: it hides violation lines).
sf_status=0
sf_out=$(swiftformat --lint . 2>&1) || sf_status=$?
sl_status=0
sl_out=$(swiftlint --quiet 2>&1) || sl_status=$?
printf '=== swiftformat --lint (exit %d) ===\n%s\n' "$sf_status" "$sf_out" >> build/lint.log
printf '=== swiftlint (exit %d) ===\n%s\n' "$sl_status" "$sl_out" >> build/lint.log

# Compact both reports: group violations by rule, ranges of line numbers,
# relative paths; banners and prose dropped. Stray unknown lines pass through.
if ! printf '%s' "$sf_out" | python3 -c '
import os, re, sys

sf_status, sl_status, sl_text = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
sf_pat = re.compile(r"^(.+?):(\d+):\d+: error: \(([^()]+)\)")
sl_pat = re.compile(r"^(.+?):(\d+):\d+: (warning|error): .+ \(([^()]+)\)$")
sf_noise = re.compile(r"^(Running SwiftFormat|\(lint mode|Reading config file|SwiftFormat completed|Source input did not pass lint check|\d+/\d+ files require formatting)")


def rel(p):
    try:
        return os.path.relpath(os.path.realpath(p))
    except ValueError:
        return p


def parse(text, pat, rule_idx):
    n = 0
    errs = 0
    groups = {}
    stray = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = pat.match(line)
        if not m:
            stray.append(line)
            continue
        sev = m.group(3) if rule_idx == 4 else "error"
        if sev == "error":
            errs += 1
        n += 1
        groups.setdefault(m.group(rule_idx), []).append((rel(m.group(1)), int(m.group(2))))
    return n, errs, groups, stray


def emit(label, n, groups, stray):
    for s in stray:
        print(s)
    if n:
        print(label + ": " + str(n) + " violation" + ("s" if n != 1 else ""))
        for rule, locs in sorted(groups.items()):
            by_file = {}
            for path, lineno in locs:
                by_file.setdefault(path, []).append(lineno)
            chunks = []
            for path, lines in by_file.items():
                spans = []
                ls = sorted(lines)
                start = prev = ls[0]
                for x in ls[1:]:
                    if x == prev + 1:
                        prev = x
                    else:
                        spans.append((start, prev))
                        start = prev = x
                spans.append((start, prev))
                chunks.append(path + ":" + ",".join(str(a) if a == b else str(a) + "-" + str(b) for a, b in spans))
            print("  " + rule + ": " + ", ".join(chunks))
    elif stray:
        pass
    else:
        print(label + ": OK")


sf_n, sf_errs, sf_groups, sf_stray = parse(sys.stdin.read(), sf_pat, 3)
sf_stray = [s for s in sf_stray if not sf_noise.match(s)]
emit("swiftformat", sf_n, sf_groups, sf_stray)
if sf_status != 0 and sf_n == 0 and not sf_stray:
    print("swiftformat: failed (exit " + str(sf_status) + ")")

sl_n, sl_errs, sl_groups, sl_stray = parse(sl_text, sl_pat, 4)
if sl_n:
    parts = []
    for sev, cnt in (("error", sl_errs), ("warning", sl_n - sl_errs)):
        if cnt:
            parts.append(str(cnt) + " " + sev + ("s" if cnt != 1 else ""))
    print("swiftlint: " + ", ".join(parts))
    for rule, locs in sorted(sl_groups.items()):
        by_file = {}
        for path, lineno in locs:
            by_file.setdefault(path, []).append(lineno)
        chunks = [p + ":" + ",".join(str(x) for x in sorted(ls)) for p, ls in by_file.items()]
        print("  " + rule + ": " + ", ".join(chunks))
    for s in sl_stray:
        print(s)
elif sl_stray:
    for s in sl_stray:
        print(s)
elif sl_status != 0:
    print("swiftlint: failed (exit " + str(sl_status) + ")")
else:
    print("swiftlint: OK")

sys.exit(0 if sf_status == 0 and sl_status == 0 and sl_errs == 0 else 1)
' "$sf_status" "$sl_status" "$sl_out"; then
  fail=1
fi

if (( fail )); then
  echo "detail: build/lint.log"
  echo "RESULT: FAIL"
  exit 1
fi

echo "RESULT: PASS"
