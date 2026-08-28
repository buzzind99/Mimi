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
# commands use @loader_path/@rpath into that directory) so it can coexist on
# disk with the NeMo-Speech runtime staged by the previous build script.
#
# Prereqs: xcode-select --install; brew install cmake ninja
#   (CMake >= 3.26)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/CrispASR"
SDK_DIR="${REPO_ROOT}/local/install/crispasr"
FRAMEWORKS_DIR="${REPO_ROOT}/local/frameworks/crispasr"
UPSTREAM="https://github.com/CrispStrobe/CrispASR.git"
BUILD_DIR="build"
MODEL="${REPO_ROOT}/models/qwen3-asr-0.6b-q8_0.gguf"

GGML_METAL=ON
if [[ "${1:-}" == "--cpu" ]]; then
  GGML_METAL=OFF
fi

echo "==> CrispASR runtime build (GGML_METAL=${GGML_METAL})"

# 1. Clone + submodules (ggml is a submodule; the CLI also needs c2pa-audio)
if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "==> Cloning ${UPSTREAM}"
  git clone --recurse-submodules "${UPSTREAM}" "${VENDOR_DIR}"
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
# A copy of the CLI next to the dylibs serves as the smoke-test binary.
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
if [[ ! -f "${VAD_MODEL}" ]]; then
  echo "==> Fetching FireRedVAD model"
  curl -fL --retry 3 -o "${VAD_MODEL}" "${VAD_URL}"
else
  echo "==> FireRedVAD model already present at ${VAD_MODEL}"
fi

# 7. Ad-hoc sign everything so the app loads it locally.
echo "==> Ad-hoc signing"
find "${FRAMEWORKS_DIR}" -name "*.dylib" -o -name crispasr | while read -r f; do
  codesign --force --sign - "${f}"
done

# 8. Smoke test: transcribe a short file against the JA anime fine-tune.
if [[ -f "${MODEL}" ]]; then
  echo "==> Smoke test (file mode, backend qwen3)"
  "${FRAMEWORKS_DIR}/crispasr" --backend qwen3 -m "${MODEL}" -l ja -t 4 \
    "${REPO_ROOT}/samples/smoke_ja.wav" 2>&1 || true
else
  echo "==> (Skipping smoke test: no model at ${MODEL})"
  echo "    Download with:"
  echo "    hf download cstr/qwen3-asr-0.6b-GGUF \\"
  echo "      qwen3-asr-0.6b-q8_0.gguf --local-dir ${REPO_ROOT}/models"
fi

echo
echo "Done. The app picks up the runtime from ${FRAMEWORKS_DIR} when run from"
echo "this checkout; scripts/package.sh bundles it into Mimi.app/Contents/Frameworks."
