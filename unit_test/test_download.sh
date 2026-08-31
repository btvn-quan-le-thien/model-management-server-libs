#!/bin/bash
# =============================================================================
# test_download.sh — Tests for download.sh (against lakeFS)
#
# Self-provisions to stay standalone + byte-exact: it packs a fixture, uploads
# it to the `unit_test` repo under a download-specific tag, then exercises
# download.sh:
#   1. Download a file by tag → sha256 of download == sha256 of uploaded zip.
#   2. download --unzip      → plain unzip leaves *.zst files present.
#   3. download --unpack     → unpack.sh auto-decompresses; diff -r == original.
#   4. Download a folder by tag (recursive) → contents == original fixture.
#
# Requires lakeFS + the `unit_test` repo. Ensures the repo exists; reuses any
# data already there. When run via run_all.sh, the repo is deleted afterwards
# by run_all.sh.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

# Require lakeFS.
if ! lakectl_alive; then fatal "lakeFS not reachable — run ./health.sh"; fi

section "test_download.sh — download.sh (repo: $UNIT_REPO)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Download-specific tags (distinct from test_upload's tags to avoid collisions;
# deterministic from the shared run id so re-runs are consistent).
RID="$(get_run_id)"
DL_ZIP_TAG="unit-test-${RID}-dl"
DL_FOLDER_TAG="unit-test-${RID}-dlfld"
info "run id: $RID"
info "dl zip tag:    $DL_ZIP_TAG"
info "dl folder tag: $DL_FOLDER_TAG"

ensure_unit_repo

# --- Build + pack + upload the fixture (self-provision) ----------------------
# Use a distinct fixture name (model_test_dl) so uploads land on DIFFERENT
# object paths than test_upload.sh's model_test.zip/model_test/ — otherwise the
# duplicate upload on the same branch would hit lakeFS "commit: no changes".
FIX="$(build_fixture "$WORK" model_test_dl)"
SRC_ZIP="$WORK/model_test_dl.zip"
"$PACK_SH" "$FIX" -o "$SRC_ZIP" >/dev/null
assert_file_exists "$SRC_ZIP" "fixture packed"
SRC_SHA="$(sha256_file "$SRC_ZIP")"
info "source zip sha256: $SRC_SHA"

section "provision: upload zip (tag $DL_ZIP_TAG)"
"$UPLOAD_SH" "$SRC_ZIP" "$UNIT_REPO" main "$DL_ZIP_TAG" >/dev/null
pass "zip uploaded for download tests"

section "provision: upload folder (tag $DL_FOLDER_TAG)"
"$UPLOAD_SH" "$FIX/" "$UNIT_REPO" main "$DL_FOLDER_TAG" >/dev/null
pass "folder uploaded for download tests"

# --- Test 1: download a file by tag (byte-exact) -----------------------------
section "download file by tag (byte-exact sha256)"
DL_ZIP="$WORK/downloaded.zip"
"$DOWNLOAD_SH" "$UNIT_REPO" "$DL_ZIP_TAG" model_test_dl.zip "$DL_ZIP" >/dev/null
assert_file_exists "$DL_ZIP" "downloaded zip exists"
DL_SHA="$(sha256_file "$DL_ZIP")"
assert_eq "$DL_SHA" "$SRC_SHA" "downloaded zip sha256 == uploaded zip sha256 (byte-exact)"

# download is deterministic: a second download yields the same bytes
DL_ZIP2="$WORK/downloaded2.zip"
"$DOWNLOAD_SH" "$UNIT_REPO" "$DL_ZIP_TAG" model_test_dl.zip "$DL_ZIP2" >/dev/null
DL_SHA2="$(sha256_file "$DL_ZIP2")"
assert_eq "$DL_SHA2" "$DL_SHA" "second download sha256 == first (deterministic)"

# --- Test 2: download --unzip (plain unzip leaves .zst intact) ---------------
section "download --unzip (leaves .zst)"
UNZ_OUT="$WORK/unz.zip"
UNZ_DIR="${UNZ_OUT%.zip}"          # download.sh extracts to ${OUTPUT%.zip}
"$DOWNLOAD_SH" "$UNIT_REPO" "$DL_ZIP_TAG" model_test_dl.zip "$UNZ_OUT" --unzip >/dev/null
if [ -f "$UNZ_DIR/model.pkl.zst" ]; then
  pass "plain unzip left model.pkl.zst intact"
else
  fail "expected model.pkl.zst after --unzip (plain unzip should not decompress)"
fi
if [ ! -f "$UNZ_DIR/model.pkl" ]; then
  pass "no decompressed model.pkl after --unzip (as expected for plain unzip)"
else
  fail "--unzip unexpectedly decompressed model.pkl"
fi

# --- Test 3: download --unpack (auto zstd-decompress; round-trip) ------------
section "download --unpack (auto zstd-decompress)"
UNPACK_DIR="$WORK/unpacked"
"$DOWNLOAD_SH" "$UNIT_REPO" "$DL_ZIP_TAG" model_test_dl.zip "$WORK/up.zip" --unpack >/dev/null
# unpack.sh extracts to ${OUTPUT%.zip} -> $WORK/up/
if [ -d "$WORK/up" ]; then
  assert_dir_eq "$FIX" "$WORK/up" "download --unpack: restored == original fixture"
else
  fail "unpack dir $WORK/up not created by --unpack"
fi
[ -f "$WORK/up/model.pkl" ] && pass "model.pkl decompressed after --unpack" || fail "model.pkl missing after --unpack"
[ ! -e "$WORK/up/model.pkl.zst" ] && pass "no leftover .zst after --unpack" || fail "leftover .zst after --unpack"

# --- Test 4: download a folder by tag (recursive) ---------------------------
section "download folder by tag (recursive)"
DL_FOLDER="$WORK/downloaded_folder"
"$DOWNLOAD_SH" "$UNIT_REPO" "$DL_FOLDER_TAG" model_test_dl/ "$DL_FOLDER" >/dev/null
# The downloaded folder should contain the fixture contents.
if [ -d "$DL_FOLDER" ]; then
  pass "folder downloaded to $DL_FOLDER"
else
  fail "folder download dir missing: $DL_FOLDER"
fi
# Compare contents. lakectl may nest under model_test_dl/ or place files at root;
# compare the fixture against the download root, then fall back to a nested dir.
if diff -r "$FIX" "$DL_FOLDER" >/dev/null 2>&1; then
  pass "folder download contents == original (flat layout)"
elif diff -r "$FIX" "$DL_FOLDER/model_test_dl" >/dev/null 2>&1; then
  pass "folder download contents == original (nested model_test_dl/ layout)"
else
  fail "folder download contents differ from original"
  warn "downloaded tree:"; find "$DL_FOLDER" -maxdepth 2 | head -20 >&2
fi

print_summary "test_download.sh"
exit_code
