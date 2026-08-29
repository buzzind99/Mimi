#!/usr/bin/env bash
#
# Phase 1 — build the CrispASR native runtime (one-time, dev machine) and
# install its SDK into the repo so the app can link/load it.
#
#   scripts/build_runtime.sh           # Metal (GPU) build — default
#   scripts/build_runtime.sh --cpu     # CPU-only build for debugging
#
# Outputs:
#   local/install/crispasr/                          SDK prefix (libs, headers, CLI)
#   local/frameworks/crispasr/libcrispasr.dylib + ggml companions
#   Mimi/native/include/crispasr/crispasr_session.h  refreshed stable header
#
# The dylib set is isolated in a `crispasr/` subdirectory (ids and load
# commands use @loader_path/@rpath into that directory).
#
# Prereqs: xcode-select --install; brew install cmake ninja
#   (CMake >= 3.26)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/CrispASR"
SDK_DIR="${REPO_ROOT}/local/install/crispasr"
FRAMEWORKS_DIR="${REPO_ROOT}/local/frameworks/crispasr"
UPSTREAM="https://github.com/CrispStrobe/CrispASR.git"
CRISPASR_REF="${CRISPASR_REF:-5a37b5e107aa0f243e6c3567fce2985befdb9eb0}"
BUILD_DIR="build"

GGML_METAL=ON
if [[ "${1:-}" == "--cpu" ]]; then
  GGML_METAL=OFF
fi

echo "==> CrispASR runtime build (GGML_METAL=${GGML_METAL})"

# 1. Clone + submodules (ggml is a submodule; the CLI also needs c2pa-audio)
if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "==> Cloning ${UPSTREAM} (pinned ${CRISPASR_REF})"
  git clone "${UPSTREAM}" "${VENDOR_DIR}"
  git -C "${VENDOR_DIR}" checkout -q "${CRISPASR_REF}"
else
  current_ref="$(git -C "${VENDOR_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ "${current_ref}" != "${CRISPASR_REF}" ]]; then
    echo "WARNING: vendor/CrispASR is at ${current_ref:-<unknown>}, pinned ref is ${CRISPASR_REF}"
    echo "         Override CRISPASR_REF to build a different commit intentionally."
  fi
fi
pushd "${VENDOR_DIR}" >/dev/null
git submodule update --init --recursive

# Homebrew's libsentencepiece links abseil without re-exporting its symbols,
# which breaks the final link of libcrispasr. It is only used by the
# irodori-tts backend (TTS — unused by Mimi), so drop the optional link and
# let that backend fall back to its built-in tokenizer.
perl -0pi -e 's/find_library\(SENTENCEPIECE_LIB sentencepiece\)\nif\(SENTENCEPIECE_LIB\)\n.*?\nendif\(\)\n//s' \
  src/CMakeLists.txt

# 2. Configure + build
echo "==> Configuring"
EXTRA_CMAKE_ARGS=(
  -DGGML_METAL="${GGML_METAL}"
  # Embed the Metal shader library into libggml-metal (the default when
  # GGML_METAL is ON) so nothing besides the dylibs needs staging.
  -DGGML_METAL_EMBED_LIBRARY="${GGML_METAL}"
  # Shared libcrispasr dylib exposing the crispasr_session C ABI.
  -DBUILD_SHARED_LIBS=ON
  -DCRISPASR_BUILD_TESTS=OFF
  -DCRISPASR_BUILD_SERVER=OFF
)
cmake -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  "${EXTRA_CMAKE_ARGS[@]}"

echo "==> Building (this takes a while)"
cmake --build "${BUILD_DIR}" -j"$(sysctl -n hw.ncpu)" --target crispasr-cli crispasr-lib
popd >/dev/null

# 3. Collect artifacts into the local prefix. The build tree produces
#    bin/crispasr (CLI), src/libcrispasr.dylib, and the ggml companion dylibs.
echo "==> Installing to ${SDK_DIR}"
BUILD_BIN="${VENDOR_DIR}/${BUILD_DIR}/bin"
mkdir -p "${SDK_DIR}/bin" "${SDK_DIR}/lib" "${SDK_DIR}/include/crispasr"
cp -f "${BUILD_BIN}/crispasr" "${SDK_DIR}/bin/crispasr"
find "${VENDOR_DIR}/${BUILD_DIR}/src" "${VENDOR_DIR}/${BUILD_DIR}/ggml/src" -name "*.dylib" | while read -r dylib; do
  cp -f "${dylib}" "${SDK_DIR}/lib/"
done
cp -f "${VENDOR_DIR}/include/crispasr.h" \
      "${VENDOR_DIR}/include/crispasr_session.h" \
      "${SDK_DIR}/include/crispasr/"

# 4. Stage dylibs into local/frameworks/crispasr. Every dylib gets its
#    build-tree RPATHs stripped and @loader_path added instead, so the set
#    resolves its own @rpath dependencies (CMake names them @rpath/<lib>)
#    from its own directory — no consumer rpath config required and no
#    dependency on this dev machine's build tree.
echo "==> Staging into ${FRAMEWORKS_DIR}"
strip_rpaths() {
  local f="$1" path
  for path in $(otool -l "$f" | awk '/LC_RPATH/{getline; print $2}'); do
    install_name_tool -delete_rpath "$path" "$f" 2>/dev/null || true
  done
  install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
}
mkdir -p "${FRAMEWORKS_DIR}"
for dylib in "${SDK_DIR}"/lib/*.dylib; do
  name="$(basename "${dylib}")"
  cp -f "${dylib}" "${FRAMEWORKS_DIR}/${name}"
  install_name_tool -id "@rpath/${name}" "${FRAMEWORKS_DIR}/${name}"
  strip_rpaths "${FRAMEWORKS_DIR}/${name}"
done
# A copy of the CLI next to the dylibs is handy for manual debugging.
cp -f "${SDK_DIR}/bin/crispasr" "${FRAMEWORKS_DIR}/crispasr"
strip_rpaths "${FRAMEWORKS_DIR}/crispasr"

# 5. Refresh the vendored stable headers used by the engine.
mkdir -p "${REPO_ROOT}/Mimi/native/include/crispasr"
cp -f "${SDK_DIR}/include/crispasr/crispasr.h" \
      "${SDK_DIR}/include/crispasr/crispasr_session.h" \
      "${REPO_ROOT}/Mimi/native/include/crispasr/"

# 6. Fetch the FireRedVAD model used for speech endpointing (2.4 MB). The
#    dylib dispatches on the basename, so it must keep this exact name;
#    package.sh bundles it along with the dylibs.
VAD_MODEL="${FRAMEWORKS_DIR}/firered-vad.gguf"
VAD_URL="https://huggingface.co/cstr/firered-vad-GGUF/resolve/main/firered-vad.gguf"
# Pinned digest: this model gets bundled into release DMGs, so its integrity
# is enforced on every build (existing or freshly downloaded).
VAD_SHA256="${VAD_SHA256:-72d37db1a5d2a9db386d1452b3f54d13f97bea79710105fc65acd050ea7db600}"
if [[ ! -f "${VAD_MODEL}" ]]; then
  echo "==> Fetching FireRedVAD model"
  curl -fL --retry 3 -o "${VAD_MODEL}" "${VAD_URL}"
fi
echo "==> Verifying FireRedVAD model"
vad_actual="$(shasum -a 256 "${VAD_MODEL}" | awk '{print $1}')"
if [[ "${vad_actual}" != "${VAD_SHA256}" ]]; then
  echo "ERROR: FireRedVAD model SHA-256 mismatch" >&2
  echo "       expected ${VAD_SHA256}" >&2
  echo "       got      ${vad_actual}" >&2
  rm -f "${VAD_MODEL}"
  exit 1
fi

# 7. Ad-hoc sign everything so the app loads it locally. (-type f keeps the
#    crispasr directory itself out — signing a directory creates a
#    _CodeSignature that then breaks the app bundle's outer seal.)
echo "==> Ad-hoc signing"
find "${FRAMEWORKS_DIR}" -type f \( -name "*.dylib" -o -name crispasr -o -name "*.gguf" \) | while read -r f; do
  codesign --force --sign - "${f}"
done

echo
echo "Done. The app picks up the runtime from ${FRAMEWORKS_DIR} when run from"
echo "this checkout; scripts/package.sh bundles it into Mimi.app/Contents/Frameworks."
