#!/usr/bin/env bash
#
# Package release DMG:
#   build/pkg/Mimi.dmg   (~20–40 MB; JMdict dictionary data bundled, ASR
#                        model downloaded on first launch)
#
# Signed with the local self-signed "Mimi Dev" certificate so TCC
# permission grants (Screen Recording) persist across rebuilds.
# Launch locally after "Open Anyway" / xattr -cr.
# Usage: scripts/package.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/pkg"
SIGN_IDENTITY="${SIGN_IDENTITY:-Mimi Dev}"

cd "${REPO_ROOT}"

command -v xcodegen >/dev/null || { echo "xcodegen required (brew install xcodegen)"; exit 1; }
xcodegen generate

build_app() {
  local scheme="$1" config="$2" out="$3"
  echo "==> Building ${scheme} (${config})"
  xcodebuild -project Mimi.xcodeproj -scheme "${scheme}" \
    -configuration "${config}" -destination "generic/platform=macOS" \
    -derivedDataPath "${BUILD_DIR}/derived" build
  local built
  built="$(find "${BUILD_DIR}/derived/Build/Products/${config}" -maxdepth 1 -name '*.app' | head -1)"
  rm -rf "${out}"
  mkdir -p "$(dirname "${out}")"
  cp -R "${built}" "${out}"
  # Remove the un-staged build output. It carries no Resources (dictionary
  # data is staged below, only into the copy), and Release builds have no
  # dev-checkout fallback for the bundled JMdict — launching it instead of
  # the packaged app fails every session start with "Bundled JMdict_e.gz
  # not found in the app bundle".
  rm -rf "${built}"
}

sign_app() {
  # Sign last: staging (dylibs, README) modifies the bundle after the build,
  # which would otherwise invalidate the seal. Nested dylibs are already
  # signed by stage_runtime; this seals the outer bundle over them.
  codesign --force --sign "${SIGN_IDENTITY}" "$1"
}

stage_runtime() {
  local app="$1"
  local fwdir="${app}/Contents/Frameworks"
  mkdir -p "${fwdir}"
  # Dictionary tokenizer dylib — independent of the ASR runtime. Without it
  # the dictionary DB can never be built, and session start (see
  # AppModel.ensureDictionaryReady) fails — such a package is broken.
  if [[ -f "${REPO_ROOT}/local/frameworks/libdictionary.dylib" ]]; then
    cp -f "${REPO_ROOT}/local/frameworks/libdictionary.dylib" "${fwdir}/libdictionary.dylib"
    codesign --force --sign "${SIGN_IDENTITY}" "${fwdir}/libdictionary.dylib"
  else
    echo "ERROR: dictionary runtime not built. Run scripts/build_dictionary.sh first." >&2
    exit 1
  fi
  # Bundled JMdict data — the SQLite DB is built from this locally on first
  # launch (never bundled, never downloaded). Without it session start
  # fails with "Bundled JMdict_e.gz not found in the app bundle".
  if [[ -f "${REPO_ROOT}/local/dictionaries/JMdict_e.gz" ]]; then
    local resdir="${app}/Contents/Resources"
    mkdir -p "${resdir}"
    cp -f "${REPO_ROOT}/local/dictionaries/JMdict_e.gz" "${resdir}/JMdict_e.gz"
  else
    echo "ERROR: JMdict_e.gz not fetched. Run scripts/build_dictionary.sh first." >&2
    exit 1
  fi
  if [[ ! -d "${REPO_ROOT}/local/frameworks/crispasr" ]]; then
    echo "WARNING: native runtime not built (scripts/build_runtime.sh); app will run in mock mode."
    return
  fi
  # The CrispASR dylib set is self-contained (its dylibs resolve their own
  # @rpath dependencies via a @loader_path RPATH), so it bundles as a plain
  # subdirectory of Contents/Frameworks.
  cp -R "${REPO_ROOT}/local/frameworks/crispasr" "${fwdir}/crispasr"
  find "${fwdir}/crispasr" -type f \( -name "*.dylib" -o -name crispasr -o -name "*.gguf" \) | while read -r f; do
    codesign --force --sign "${SIGN_IDENTITY}" "${f}"
  done
}

stage_readme() {
  local app="$1"
  cat > "/tmp/mimi-launch-notes.txt" <<EOF
Mimi — real-time JP livestream transcriber/translator

This app is signed with a self-signed local certificate ("Mimi Dev").
First launch may be blocked by macOS:
  1. Double-click Mimi.app once.
  2. Open System Settings → Privacy & Security → scroll to "Open Anyway".
  3. Or run:  xattr -cr /Applications/Mimi.app

Compatibility: Apple Silicon, macOS 15+.
First run: grant Screen Recording access (system audio capture via
ScreenCaptureKit; no microphone is used); one-time
translation language-pack download prompt.

$(cat "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" 2>/dev/null || true)
EOF
  mkdir -p "${app}/Contents/Resources"
  cp "/tmp/mimi-launch-notes.txt" "${app}/Contents/Resources/README.txt"
}

make_dmg() {
  local app="$1" name="$2"
  local staging="${BUILD_DIR}/${name}"
  rm -rf "${staging}" "${BUILD_DIR}/${name}.dmg"
  mkdir -p "${staging}"
  cp -R "${app}" "${staging}/"
  ln -s /Applications "${staging}/Applications"
  hdiutil create -volname "${name}" -srcfolder "${staging}" \
    -format UDZO -ov "${BUILD_DIR}/${name}.dmg"
}

# --- app ---
build_app Mimi Release "${BUILD_DIR}/Mimi.app"
stage_runtime "${BUILD_DIR}/Mimi.app"
stage_readme "${BUILD_DIR}/Mimi.app"
sign_app "${BUILD_DIR}/Mimi.app"
make_dmg "${BUILD_DIR}/Mimi.app" "Mimi"

echo
echo "Artifacts in ${BUILD_DIR}:"
ls -lh "${BUILD_DIR}" | grep dmg || true
echo "Launch ${BUILD_DIR}/Mimi.app (or install the DMG) — not the derived build output."
