#!/usr/bin/env bash
#
# Fetch + verify the pinned JMDict_Extended release asset, probe its format,
# and emit the bundled lookup DB from it. The probe and build implementations
# live in jmdict_probe.py and jmdict_build.py (same directory); this script
# is the orchestrator and the only supported entrypoint.
#
#   scripts/build_jmdict.sh                # probe (tripwire) + build DB (skips if built)
#   scripts/build_jmdict.sh --probe-only   # probe only, no DB emitted
#   scripts/build_jmdict.sh --rebuild      # probe + rebuild DB even if built
#
# The pin (tag + asset + SHA-256) is recorded here AND in
# Mimi/Dictionary/JMDictPin.swift; this script cross-checks the two and
# hard-fails on drift, so a pin bump must touch both files or nothing builds.
# The probe runs before every build and hard-fails on any mismatch with the
# documented input contract — on a pin bump it is the tripwire against silent
# upstream format drift, and the DB is only ever built from a probed-pass
# asset. (The only exception is the up-to-date skip: when the versioned
# artifact for this pin already exists and passes `zstd -t`, plain
# invocations exit early without re-downloading, re-probing, or rebuilding;
# --rebuild forces the full path.)
#
# Artifacts (gitignored, under local/ and build/):
#   local/dictionaries/jmdictExtended-<date>.json.zip   pinned release asset
#   local/dictionaries/jmdictExtended-<date>.json       unzipped input
#   local/dictionaries/jmdict-<tag>.sqlite.zst          bundled lookup DB
#                                                       (package.sh -> Contents/Resources)
#   build/jmdict-<tag>.sqlite                           uncompressed intermediate
#   build/jmdict-probe.log                              full probe report
#   build/jmdict-build.log                              full build log

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DICT_DIR="${REPO_ROOT}/local/dictionaries"
BUILD_DIR="${REPO_ROOT}/build"

# --- Pin: keep in sync with Mimi/Dictionary/JMDictPin.swift -----------------
PIN_TAG="1.4.1-auto-release-2026-09-01"
PIN_ASSET="jmdictExtended-2026-09-01.json.zip"
# SHA-256 of the .zip asset, cross-checked against the digest GitHub publishes
# on the release asset page.
PIN_SHA256="4bee23eb7bd088d0a9c48301d0d25964b8ac9ecd6465c91b40adf8191d4b040a"
PIN_URL="https://github.com/Bluskyo/JMDict_Extended/releases/download/${PIN_TAG}/${PIN_ASSET}"
# ----------------------------------------------------------------------------

ZIP_PATH="${DICT_DIR}/${PIN_ASSET}"
JSON_PATH="${DICT_DIR}/${PIN_ASSET%.zip}"
PROBE_LOG="${BUILD_DIR}/jmdict-probe.log"
PREPARED_NAME="jmdict-${PIN_TAG}.sqlite"
ZST_NAME="${PREPARED_NAME}.zst"
ZST_PATH="${DICT_DIR}/${ZST_NAME}"

MODE="build"
REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-only) MODE="probe" ;;
    --rebuild) REBUILD=1 ;;
    -h|--help)
      echo "usage: build_jmdict.sh [--probe-only] [--rebuild]"
      echo "  (default)    probe the pinned asset, then build the DB (skips if built)"
      echo "  --probe-only probe only, no DB emitted"
      echo "  --rebuild    probe + rebuild the DB even if the artifact exists"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1 (see --help)" >&2
      exit 1
      ;;
  esac
  shift
done
if [[ "${MODE}" == "probe" && "${REBUILD}" == "1" ]]; then
  echo "ERROR: --probe-only and --rebuild are mutually exclusive" >&2
  exit 1
fi

echo "==> JMDict_Extended pin: ${PIN_TAG}"
echo "    asset: ${PIN_ASSET}"

# Cross-check the Swift pin constants (drift fails here, never silently).
PIN_SWIFT="${REPO_ROOT}/Mimi/Dictionary/JMDictPin.swift"
if [[ ! -f "${PIN_SWIFT}" ]]; then
  echo "ERROR: ${PIN_SWIFT} not found; the pin must exist in both the script and Swift." >&2
  exit 1
fi
check_pin_constant() {
  local name="$1" expected="$2"
  python3 - "$name" "$expected" "${PIN_SWIFT}" <<'CHECKEOF'
import re, sys
name, expected, path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
m = re.search(rf'\b{name}\s*=\s*"([^"]+)"', src)
actual = m.group(1) if m else None
if actual != expected:
    print(f"ERROR: JMDictPin.{name} mismatch\n  script: {expected}\n  swift:  {actual}", file=sys.stderr)
    sys.exit(1)
CHECKEOF
  echo "    pin.${name}: ok"
}
check_pin_constant releaseTag "${PIN_TAG}"
check_pin_constant sourceAssetFileName "${PIN_ASSET}"
check_pin_constant sourceSHA256 "${PIN_SHA256}"

# The produced artifact filename must match the Swift pin constants — the
# versioned name is the staleness key (§0.1 item 4). preparedFileName is
# interpolated in Swift, so guard the derivation expressions themselves
# (releaseTag is already cross-checked above, which pins the concrete name).
if ! grep -Fq 'static let preparedFileName = "jmdict-\(releaseTag).sqlite"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.preparedFileName no longer derives as \"jmdict-\\(releaseTag).sqlite\"; update this drift guard." >&2
  exit 1
fi
if ! grep -Fq 'bundledFileName = preparedFileName + ".zst"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.bundledFileName no longer derives from preparedFileName + \".zst\"; update this drift guard." >&2
  exit 1
fi

# Up-to-date skip (build mode only): the artifact name is versioned by the
# pin tag, so a pin bump naturally misses and rebuilds. A truncated artifact
# from an interrupted build fails `zstd -t` and falls through to a rebuild.
# --rebuild bypasses this entirely (needed when the build mapping changes
# under the same pin). --probe-only never consults the DB.
if [[ "${MODE}" == "build" && "${REBUILD}" == "0" && -s "${ZST_PATH}" ]]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "WARNING: zstd not found; cannot verify ${ZST_NAME}, rebuilding."
  elif zstd -q -t "${ZST_PATH}" 2>/dev/null; then
    echo "==> ${ZST_NAME} already built and valid; skipping (use --rebuild to force)."
    exit 0
  else
    echo "WARNING: ${ZST_PATH} exists but failed its integrity check; rebuilding."
  fi
fi

# Fetch once; verify the digest on every run (like the IPADIC pin).
mkdir -p "${DICT_DIR}" "${BUILD_DIR}"
if [[ ! -f "${ZIP_PATH}" ]]; then
  echo "==> Downloading ${PIN_URL}"
  curl -fL --retry 3 -o "${ZIP_PATH}" "${PIN_URL}"
fi
echo "==> Verifying asset SHA-256"
actual="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
if [[ "${actual}" != "${PIN_SHA256}" ]]; then
  echo "ERROR: asset SHA-256 mismatch" >&2
  echo "  expected ${PIN_SHA256}" >&2
  echo "  got      ${actual}" >&2
  rm -f "${ZIP_PATH}"
  exit 1
fi

if [[ ! -f "${JSON_PATH}" ]]; then
  echo "==> Unzipping to ${JSON_PATH}"
  unzip -o -q "${ZIP_PATH}" -d "${DICT_DIR}"
fi

# Probe on every run that proceeds past the up-to-date skip — build mode
# only continues past a passing probe.
echo "==> Probing format (full report: ${PROBE_LOG})"
python3 "${REPO_ROOT}/scripts/jmdict_probe.py" "${JSON_PATH}" "${PROBE_LOG}"
if [[ "${MODE}" == "probe" ]]; then
  echo
  echo "Probe passed. The pinned asset matches the documented contract."
  exit 0
fi

# ============================================================================
# DB build — the probe above already ran and passed on this exact asset.
#
command -v zstd >/dev/null 2>&1 || {
  echo "ERROR: zstd not found (brew install zstd)" >&2
  exit 1
}

RAW_DB="${BUILD_DIR}/${PREPARED_NAME}"
BUILD_LOG="${BUILD_DIR}/jmdict-build.log"

echo "==> Building ${PREPARED_NAME} (log: ${BUILD_LOG})"
rm -f "${RAW_DB}" "${ZST_PATH}"

python3 "${REPO_ROOT}/scripts/jmdict_build.py" "${JSON_PATH}" "${RAW_DB}" "${ZST_PATH}" \
  "${PROBE_LOG}" "${PIN_TAG}" "${PIN_SHA256}" "${PIN_ASSET}" 2>&1 | tee "${BUILD_LOG}"

zstd -q -t "${ZST_PATH}"
echo
echo "Done. package.sh bundles ${ZST_NAME} into Mimi.app/Contents/Resources;"
echo "DictionaryStore (Phase 5) stages/decompresses it to jmdict-<tag>.sqlite."
