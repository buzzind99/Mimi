#!/usr/bin/env bash
#
# Build the dictionary tokenizer dylib (one-time, dev machine) and stage it
# into the repo so the app can load it.
#
#   scripts/build_dictionary.sh
#
# Outputs:
#   local/frameworks/libdictionary.dylib   FFI dylib (SQLite compiled in)
#   local/frameworks/dictionary            CLI for debugging
#
# The vendored source lives at vendor/tentoku-rs (cloned on first run) with a
# small local FFI addition (a database-build export) applied from
# scripts/MIMI_FFI.patch. The exported C symbols keep the upstream tentoku_
# prefix — only the staged file name is generic. To move to a newer upstream,
# delete vendor/tentoku-rs and re-run (the patch reapplies on the fresh
# clone; manual conflict resolution may be needed on larger upstream drift).
#
# Prereqs: xcode-select --install; rustup/cargo

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor/tentoku-rs"
FRAMEWORKS_DIR="${REPO_ROOT}/local/frameworks"
UPSTREAM="https://github.com/eridgd/tentoku-rs.git"
TENTOKU_REF="${TENTOKU_REF:-9b9c111d2d7805ebe751265c1b7eff6eae28e56c}"  # v0.1.2
FFI_PATCH="${REPO_ROOT}/scripts/MIMI_FFI.patch"

echo "==> Dictionary tokenizer build (upstream @ ${TENTOKU_REF})"

# 1. Clone.
if [[ ! -d "${VENDOR_DIR}" ]]; then
  echo "==> Cloning ${UPSTREAM} (pinned ${TENTOKU_REF})"
  git clone "${UPSTREAM}" "${VENDOR_DIR}"
  git -C "${VENDOR_DIR}" checkout -q "${TENTOKU_REF}"
else
  current_ref="$(git -C "${VENDOR_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ "${current_ref}" != "${TENTOKU_REF}" ]]; then
    echo "WARNING: vendor/tentoku-rs is at ${current_ref:-<unknown>}, pinned ref is ${TENTOKU_REF}"
    echo "         Override TENTOKU_REF to build a different commit intentionally."
  fi
fi
pushd "${VENDOR_DIR}" >/dev/null

# 2. Apply the local FFI patch (idempotent — skipped when already present).
if ! grep -q "tentoku_build_db" src/ffi.rs; then
  echo "==> Applying local FFI patch (scripts/MIMI_FFI.patch)"
  git apply --whitespace=nowarn "${FFI_PATCH}"
fi
# Keep a copy of the patch inside the vendor dir for reference.
cp -f "${FFI_PATCH}" ./MIMI_FFI.patch

# 3. Build. The cdylib carries rusqlite's bundled SQLite, so the staged dylib
#    needs no companion files; the CLI is built by the same invocation.
echo "==> Building (this takes a while)"
cargo build --release
popd >/dev/null

# 4. Staging.
echo "==> Staging into ${FRAMEWORKS_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"
cp -f "${VENDOR_DIR}/target/release/libtentoku.dylib" "${FRAMEWORKS_DIR}/libdictionary.dylib"
install_name_tool -id "@rpath/libdictionary.dylib" "${FRAMEWORKS_DIR}/libdictionary.dylib"
for path in $(otool -l "${FRAMEWORKS_DIR}/libdictionary.dylib" | awk '/LC_RPATH/{getline; print $2}'); do
  install_name_tool -delete_rpath "$path" "${FRAMEWORKS_DIR}/libdictionary.dylib" 2>/dev/null || true
done
# A copy of the CLI next to the dylib is handy for manual debugging.
cp -f "${VENDOR_DIR}/target/release/tentoku" "${FRAMEWORKS_DIR}/dictionary"

# 5. Ad-hoc sign so the app loads it locally.
echo "==> Ad-hoc signing"
codesign --force --sign - "${FRAMEWORKS_DIR}/libdictionary.dylib"
codesign --force --sign - "${FRAMEWORKS_DIR}/dictionary"

# 6. Self-check: the upstream 5 exports + our database-build export.
echo "==> Verifying exported symbols"
symbols="$(nm -gU "${FRAMEWORKS_DIR}/libdictionary.dylib" | awk '$3 ~ /_tentoku_/ {print $3}' | sed 's/^_//' | sort)"
echo "${symbols}"
count="$(echo "${symbols}" | grep -c '^tentoku_' || true)"
if [[ "${count}" -ne 6 ]]; then
  echo "ERROR: expected 6 exported tentoku_* symbols, found ${count}" >&2
  exit 1
fi

echo
echo "Done. The app loads ${FRAMEWORKS_DIR}/libdictionary.dylib when run from"
echo "this checkout; scripts/package.sh bundles it into Mimi.app/Contents/Frameworks."
