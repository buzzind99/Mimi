#!/usr/bin/env bash
#
# Build the dictionary tokenizer dylib (one-time, dev machine), stage it into
# the repo so the app can load it, and fetch the pinned IPADIC model.
#
#   scripts/build_dictionary.sh
#
# Outputs:
#   local/frameworks/libdictionary.dylib    FFI dylib (tokenizer core compiled
#                                           in; no companion dylibs)
#   local/dictionaries/ipadic-mecab-2_7_0/  pinned model: system.dic.zst
#                                           (bundled into the app by
#                                           package.sh) + COPYING + NOTICE
#
# The tokenizer core is the vendored daac-tools/vibrato (vendor/vibrato,
# cloned on first run at the pinned ref). The C ABI lives in our own
# vendor/vibrato-ffi crate — a path dependency on the vendored lib — so
# nothing is patched upstream, and the exported symbols use the generic
# dictionary_ prefix. To move to a newer vibrato: update VIBRATO_REF (and the
# model digest if the release assets change), delete vendor/vibrato, re-run.
#
# Prereqs: xcode-select --install; rustup/cargo

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/vibrato"
FFI_DIR="${REPO_ROOT}/vendor/vibrato-ffi"
FRAMEWORKS_DIR="${REPO_ROOT}/local/frameworks"
UPSTREAM="https://github.com/daac-tools/vibrato.git"
VIBRATO_REF="${VIBRATO_REF:-7462fa07a60a176e8d9ef3cb287c7973290a0f9d}"  # v0.5.2

echo "==> Dictionary tokenizer build (vibrato @ ${VIBRATO_REF})"

# 1. Clone the vendored engine (gitignored; fresh checkout on first run).
if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "==> Cloning ${UPSTREAM} (pinned ${VIBRATO_REF})"
  git clone "${UPSTREAM}" "${VENDOR_DIR}"
  git -C "${VENDOR_DIR}" checkout -q "${VIBRATO_REF}"
else
  current_ref="$(git -C "${VENDOR_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ "${current_ref}" != "${VIBRATO_REF}" ]]; then
    echo "WARNING: vendor/vibrato is at ${current_ref:-<unknown>}, pinned ref is ${VIBRATO_REF}"
    echo "         Override VIBRATO_REF to build a different commit intentionally."
  fi
fi

# 2. Build our FFI crate. The cdylib statically embeds the engine and the
#    zstd decoder, so the staged dylib needs no companion files.
echo "==> Building vendor/vibrato-ffi (first run takes a while)"
cargo build --release --manifest-path "${FFI_DIR}/Cargo.toml"

# 3. Staging.
echo "==> Staging into ${FRAMEWORKS_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
cp -f "${FFI_DIR}/target/release/libvibrato_ffi.dylib" "${FRAMEWORKS_DIR}/libdictionary.dylib"
install_name_tool -id "@rpath/libdictionary.dylib" "${FRAMEWORKS_DIR}/libdictionary.dylib"
# A pure-Rust cdylib carries no build-tree rpaths; strip defensively anyway —
# the app must never depend on this machine's layout.
for path in $(otool -l "${FRAMEWORKS_DIR}/libdictionary.dylib" | awk '/LC_RPATH/{getline; print $2}'); do
  install_name_tool -delete_rpath "$path" "${FRAMEWORKS_DIR}/libdictionary.dylib" 2>/dev/null || true
done

# 4. Fetch the pinned IPADIC model (~7.7 MB tar.xz). package.sh bundles
#    system.dic.zst into Contents/Resources; the app decompresses it once on
#    first launch (no DB build step). The model ships in release DMGs, so its
#    integrity is enforced on every build — refreshing to a different model
#    is a deliberate digest bump.
DICT_DIR="${REPO_ROOT}/local/dictionaries"
MODEL_DIR="${DICT_DIR}/ipadic-mecab-2_7_0"
IPADIC_URL="https://github.com/daac-tools/vibrato/releases/download/v0.5.0/ipadic-mecab-2_7_0.tar.xz"
# Pinned digest (ipadic-mecab-2_7_0.tar.xz from the v0.5.0 release assets,
# recorded by the Phase 0 preflight).
VIBRATO_IPADIC_SHA256="${VIBRATO_IPADIC_SHA256:-4764f983b7c3a9e1cb6a5ee945e00558efd812980e0dad61224f63ee3b0475d9}"
mkdir -p "${MODEL_DIR}"
ARCHIVE="${MODEL_DIR}/model.tar.xz"
if [[ ! -f "${ARCHIVE}" ]]; then
  echo "==> Fetching ipadic-mecab-2_7_0.tar.xz"
  curl -fL --retry 3 -o "${ARCHIVE}" "${IPADIC_URL}"
fi
echo "==> Verifying ipadic model digest"
actual="$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')"
if [[ "${actual}" != "${VIBRATO_IPADIC_SHA256}" ]]; then
  echo "ERROR: ipadic model SHA-256 mismatch" >&2
  echo "       expected ${VIBRATO_IPADIC_SHA256}" >&2
  echo "       got      ${actual}" >&2
  rm -f "${ARCHIVE}"
  exit 1
fi
if [[ ! -f "${MODEL_DIR}/system.dic.zst" ]]; then
  echo "==> Extracting model"
  extract_dir="$(mktemp -d)"
  tar -xJf "${ARCHIVE}" -C "${extract_dir}"
  # The archive may nest its files in a versioned directory.
  src_dir="${extract_dir}"
  if [[ ! -f "${src_dir}/system.dic.zst" ]]; then
    src_dir="$(dirname "$(find "${extract_dir}" -name system.dic.zst | head -1)")"
  fi
  cp -f "${src_dir}/system.dic.zst" "${src_dir}/COPYING" "${src_dir}/NOTICE" "${MODEL_DIR}/"
  rm -rf "${extract_dir}"
fi

# 5. Ad-hoc sign so the app loads it locally.
echo "==> Ad-hoc signing"
codesign --force --sign - "${FRAMEWORKS_DIR}/libdictionary.dylib"

# 6. Self-check: exactly the 5 generic exports, and no build-tree rpaths.
echo "==> Verifying exported symbols"
symbols="$(nm -gU "${FRAMEWORKS_DIR}/libdictionary.dylib" | awk '$3 ~ /_dictionary_/ {print $3}' | sed 's/^_//' | sort)"
echo "${symbols}"
expected=$'dictionary_free\ndictionary_free_string\ndictionary_open\ndictionary_prepare\ndictionary_tokenize_json'
if [[ "${symbols}" != "${expected}" ]]; then
  echo "ERROR: expected exactly the 5 dictionary_* exports, found:" >&2
  echo "${symbols}" >&2
  exit 1
fi
rpaths="$(otool -l "${FRAMEWORKS_DIR}/libdictionary.dylib" | awk '/LC_RPATH/{getline; print $2}' | wc -l | tr -d ' ')"
if [[ "${rpaths}" -ne 0 ]]; then
  echo "ERROR: expected zero LC_RPATH load commands, found ${rpaths}" >&2
  exit 1
fi

echo
echo "Done. The app loads ${FRAMEWORKS_DIR}/libdictionary.dylib when run from"
echo "this checkout; scripts/package.sh bundles the dylib into"
echo "Mimi.app/Contents/Frameworks and system.dic.zst into Contents/Resources."
