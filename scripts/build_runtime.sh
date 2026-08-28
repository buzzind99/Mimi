#!/usr/bin/env bash
#
# Phase 1 — build the NeMo-Speech native runtime (one-time, dev machine) and
# install its SDK into the repo so the app can link/load it.
#
#   scripts/build_runtime.sh           # Metal (GPU) ASR preset — default
#   scripts/build_runtime.sh --cpu     # CPU preset for debugging
#
# Outputs:
#   local/install/                          SDK prefix (libs, headers)
#   local/frameworks/libnemo_speech_asr_c.dylib + companions
#   Mimi/native/include/nemo_speech/asr.h   refreshed stable header
#
# Prereqs: xcode-select --install; brew install cmake ninja
#   (CMake >= 3.26)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/NeMo-Speech.cpp"
INSTALL_PREFIX="${REPO_ROOT}/local/install"
FRAMEWORKS_DIR="${REPO_ROOT}/local/frameworks"
UPSTREAM="https://github.com/NVIDIA/NeMo-Speech.cpp"
PRESET="metal-asr"

if [[ "${1:-}" == "--cpu" ]]; then
  PRESET="cpu-asr"
fi

echo "==> NeMo-Speech runtime build (${PRESET})"

# 1. Clone + submodules
if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "==> Cloning ${UPSTREAM}"
  git clone "${UPSTREAM}" "${VENDOR_DIR}"
fi
pushd "${VENDOR_DIR}" >/dev/null
git submodule update --init ggml
git submodule update --init llama.cpp

# 2. Configure + build
echo "==> Configuring"
EXTRA_CMAKE_ARGS=()
# Homebrew's sentencepiece links abseil statically without re-exporting it,
# so absl symbols referenced by the SDK need to be linked explicitly.
if [[ -x "$(command -v brew)" && -f /opt/homebrew/lib/libabsl_status.dylib ]]; then
  ABSL_LIBS=""
  for lib in status statusor strings log_severity spinlock_wait raw_hash_set \
             hash city low_level_hash int128 base raw_logging_internal \
             throw_delegate log_internal_message; do
    [[ -f "/opt/homebrew/lib/libabsl_${lib}.dylib" ]] && ABSL_LIBS+=" -labsl_${lib}"
  done
  EXTRA_CMAKE_ARGS+=(
    "-DCMAKE_SHARED_LINKER_FLAGS=-L/opt/homebrew/lib ${ABSL_LIBS}"
    "-DCMAKE_EXE_LINKER_FLAGS=-L/opt/homebrew/lib ${ABSL_LIBS}"
  )
fi
scripts/configure.sh "${PRESET}" "${EXTRA_CMAKE_ARGS[@]:-}"

echo "==> Building (this takes a while)"
cmake --build "build/${PRESET}" -j"$(sysctl -n hw.ncpu)"

# 3. Install to the local prefix
echo "==> Installing to ${INSTALL_PREFIX}"
cmake --install "build/${PRESET}" --prefix "${INSTALL_PREFIX}"

popd >/dev/null

# 4. Stage dylibs with @rpath-fixed install names into local/frameworks
echo "==> Fixing @rpath and staging into ${FRAMEWORKS_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
find "${INSTALL_PREFIX}/lib" -name "*.dylib" -maxdepth 1 | while read -r dylib; do
  name="$(basename "${dylib}")"
  cp -f "${dylib}" "${FRAMEWORKS_DIR}/${name}"
  install_name_tool -id "@rpath/${name}" "${FRAMEWORKS_DIR}/${name}"
done

# Companion assets shipped beside the dylib (e.g. backend resources).
if [[ -d "${INSTALL_PREFIX}/share/nemo_speech" ]]; then
  mkdir -p "${FRAMEWORKS_DIR}/nemo_speech"
  cp -R "${INSTALL_PREFIX}/share/nemo_speech/" "${FRAMEWORKS_DIR}/nemo_speech/"
fi

# 5. Refresh the vendored stable header used by the bridging header.
mkdir -p "${REPO_ROOT}/Mimi/native/include/nemo_speech"
cp -f "${INSTALL_PREFIX}/include/nemo_speech/asr.h" \
      "${REPO_ROOT}/Mimi/native/include/nemo_speech/asr.h"

# 6. Ad-hoc sign everything so the app loads it locally.
echo "==> Ad-hoc signing"
find "${FRAMEWORKS_DIR}" -name "*.dylib" | while read -r dylib; do
  codesign --force --sign - "${dylib}"
done

# 7. Smoke test: streaming example against a dev model if present.
MODEL="${REPO_ROOT}/models/nemotron-3.5-asr-streaming-0.6b.q8_0.gguf"
if [[ -f "${MODEL}" ]]; then
  echo "==> Smoke test (transcribe_live)"
  if [[ -x "${INSTALL_PREFIX}/bin/transcribe_live" ]]; then
    "${INSTALL_PREFIX}/bin/transcribe_live" --model "${MODEL}" --language ja-JP --seconds 5 || true
  fi
else
  echo "==> (Skipping smoke test: no model at ${MODEL})"
  echo "    Download with:"
  echo "    hf download nvidia/nemotron-3.5-asr-streaming-0.6b \\"
  echo "      nemotron-3.5-asr-streaming-0.6b.q8_0.gguf --local-dir ${REPO_ROOT}/models"
fi

echo
echo "Done. The app picks up the runtime from ${FRAMEWORKS_DIR} when run from"
echo "this checkout; scripts/package.sh bundles it into Mimi.app/Contents/Frameworks."
