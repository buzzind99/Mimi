#!/bin/zsh
#   scripts/lint.sh          check only (exit 1 on issues)
#   scripts/lint.sh --fix    auto-format in place, then re-check
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--fix" ]]; then
  swiftformat . --quiet
  echo "Formatted."
fi

swiftformat --lint . --quiet
echo "swiftformat: OK"

swiftlint --quiet
echo "swiftlint: OK"
