#!/usr/bin/env bash
#
# Phase 4 — package unsigned release DMGs:
#   build/Mimi-lite.dmg   (~10–30 MB, model downloaded on first launch)
#   build/Mimi-full.dmg   (~700 MB, model bundled in Contents/Resources/models via repo models/)
#
# Both signed with the local self-signed "Mimi Dev" certificate so TCC
# permission grants (Screen Recording) persist across rebuilds.
# Launch locally after "Open Anyway" / xattr -cr.
# Usage: scripts/package.sh [path/to/model.gguf]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/pkg"
MODEL_PATH="${1:-${REPO_ROOT}/models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf}"
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
  codesign --force --deep --sign "${SIGN_IDENTITY}" "${out}"
}

stage_runtime() {
  local app="$1"
  local fwdir="${app}/Contents/Frameworks"
  mkdir -p "${fwdir}"
  if [[ ! -d "${REPO_ROOT}/local/frameworks" ]]; then
    echo "WARNING: native runtime not built (scripts/build_runtime.sh); app will run in mock mode."
    return
  fi
  cp -R "${REPO_ROOT}/local/frameworks/" "${fwdir}/"

  # The runtime links Homebrew abseil via absolute paths (dev-machine
  # dependency); copy the abseil closure into the bundle and rewrite every
  # load command to @rpath.
  local prefix
  prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
  local changed=1
  while [[ "$changed" == 1 ]]; do
    changed=0
    for dylib in "${fwdir}"/*.dylib; do
      for dep in $(otool -L "$dylib" | awk '/libabsl_/{print $1}'); do
        case "$dep" in
          /*) ;;
          *) continue ;;
        esac
        local name
        name="$(basename "$dep")"
        if [[ ! -f "${fwdir}/${name}" && -f "${dep}" ]]; then
          cp -L "$dep" "${fwdir}/${name}"
          changed=1
        fi
      done
    done
  done
  for dylib in "${fwdir}"/*.dylib; do
    for dep in $(otool -L "$dylib" | awk '/libabsl_/{print $1}'); do
      case "$dep" in
        "${prefix}"/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dylib" ;;
      esac
    done
  done

  # Fix dependent dylibs to @rpath inside the bundle.
  find "${fwdir}" -name "*.dylib" | while read -r dylib; do
    install_name_tool -id "@rpath/$(basename "${dylib}")" "${dylib}" 2>/dev/null || true
    codesign --force --sign "${SIGN_IDENTITY}" "${dylib}"
  done
}

stage_readme() {
  local app="$1" variant="$2"
  cat > "/tmp/mimi-launch-notes.txt" <<EOF
Mimi (${variant}) — real-time JP livestream transcriber/translator

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

# --- lite ---
build_app Mimi Release "${BUILD_DIR}/Mimi-lite.app"
stage_runtime "${BUILD_DIR}/Mimi-lite.app"
stage_readme "${BUILD_DIR}/Mimi-lite.app" "lite"
make_dmg "${BUILD_DIR}/Mimi-lite.app" "Mimi-lite"

# --- full ---
if [[ -f "${MODEL_PATH}" ]]; then
  build_app Mimi-full Release "${BUILD_DIR}/Mimi-full.app"
  stage_runtime "${BUILD_DIR}/Mimi-full.app"
  stage_readme "${BUILD_DIR}/Mimi-full.app" "full"
  make_dmg "${BUILD_DIR}/Mimi-full.app" "Mimi-full"
else
  echo
  echo "==> Skipping Mimi-full: no model at ${MODEL_PATH}"
  echo "    Download it first:"
  echo "    hf download nvidia/nemotron-3.5-asr-streaming-0.6b \\"
  echo "      nemotron-3.5-asr-streaming-0.6b.q8_0.gguf --local-dir ${REPO_ROOT}/models"
fi

echo
echo "Artifacts in ${BUILD_DIR}:"
ls -lh "${BUILD_DIR}" | grep dmg || true
