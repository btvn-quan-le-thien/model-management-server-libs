#!/bin/bash
# =============================================================================
# test_big_upload.sh — Pack + upload a 500 MB model zip to lakeFS
#
# Flow:
#   1. Spawn a ~500 MB model folder (incompressible random data).
#   2. pack.sh (zstd)        → model_big_a.zip
#   3. pack.sh --no-compress  → model_big_a_no_compress.zip
#   4. Upload both to lakeFS, verify objects + tags.
#   5. Download back + sha256 verify (big-file round-trip).
#
# Requires lakeFS. Creates/uses the per-run unit-test repo. When run via
# run_all.sh, cleanup is handled by run_all.sh (--no-cleanup is passed).
#
# Usage:
#   ./test_big_upload.sh               # create/verify repo, run tests, delete repo
#   ./test_big_upload.sh --no-cleanup  # keep repo (for run_all.sh / manual inspect)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

NO_CLEANUP=false
for arg in "$@"; do
  case "$arg" in
    --no-cleanup) NO_CLEANUP=true ;;
    -h|--help) sed -n '4,/^# =\{20,\}=$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

# Require lakeFS.
if ! lakectl_alive; then fatal "lakeFS not reachable — run ./health.sh"; fi

section "test_big_upload.sh — pack + upload 500 MB"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIG_SIZE_MB="${BIG_SIZE_MB:-500}"
BIG_ZIP_TAG="unit-test-$(get_run_id)-big"
BIG_NOCOMP_TAG="unit-test-$(get_run_id)-bignc"
info "run id: $(get_run_id)"
info "fixture size:  ${BIG_SIZE_MB} MB"
info "zstd tag:      $BIG_ZIP_TAG"
info "no-comp tag:   $BIG_NOCOMP_TAG"

ensure_unit_repo

# --- Build big fixture -------------------------------------------------------
section "build ${BIG_SIZE_MB} MB fixture (repeated random block)"
START=$SECONDS
FIX="$(build_big_fixture "$WORK" model_big_a "$BIG_SIZE_MB")"
ELAPSED=$((SECONDS - START))
info "fixture ready: $FIX ($(du -sh "$FIX" | cut -f1)) in ${ELAPSED}s"

# --- Pack with zstd → model_big_a.zip -----------------------------------------
section "pack with zstd → model_big_a.zip"
ZSTD_ZIP="$WORK/model_big_a.zip"
START=$SECONDS
"$PACK_SH" "$FIX" -o "$ZSTD_ZIP" >/dev/null
ELAPSED=$((SECONDS - START))
ZSTD_BYTES="$(file_bytes "$ZSTD_ZIP")"
assert_file_exists "$ZSTD_ZIP" "zstd zip created"
info "model_big_a.zip = $(du -sh "$ZSTD_ZIP" | cut -f1) ($ZSTD_BYTES bytes) in ${ELAPSED}s"

# --- Pack without zstd → model_big_a_no_compress.zip -------------------------
section "pack --no-compress → model_big_a_no_compress.zip"
PLAIN_ZIP="$WORK/model_big_a_no_compress.zip"
START=$SECONDS
"$PACK_SH" "$FIX" --no-compress -o "$PLAIN_ZIP" >/dev/null
ELAPSED=$((SECONDS - START))
PLAIN_BYTES="$(file_bytes "$PLAIN_ZIP")"
assert_file_exists "$PLAIN_ZIP" "no-compress zip created"
info "model_big_a_no_compress.zip = $(du -sh "$PLAIN_ZIP" | cut -f1) ($PLAIN_BYTES bytes) in ${ELAPSED}s"

# --- Size comparison ---------------------------------------------------------
section "size comparison (zstd should reduce the big zip)"
info "  zstd zip:      $(du -sh "$ZSTD_ZIP" | cut -f1) ($ZSTD_BYTES bytes)"
info "  no-comp zip:   $(du -sh "$PLAIN_ZIP" | cut -f1) ($PLAIN_BYTES bytes)"
# The fixture is highly compressible, so zstd must produce a smaller zip than
# the --no-compress zip (zip deflate also compresses repeated data, but far
# less than zstd).
assert_lt "$ZSTD_BYTES" "$PLAIN_BYTES" "zstd zip < no-compress zip (zstd reduces big zip size)"

# --- Upload zstd zip ---------------------------------------------------------
section "upload model_big_a.zip (zstd) → $UNIT_REPO/main (tag $BIG_ZIP_TAG)"
START=$SECONDS
"$UPLOAD_SH" "$ZSTD_ZIP" "$UNIT_REPO" main "$BIG_ZIP_TAG" >/dev/null
ELAPSED=$((SECONDS - START))
pass "upload.sh exited 0 (zstd zip) in ${ELAPSED}s"
if object_exists "$UNIT_REPO" main model_big_a.zip; then
  pass "object model_big_a.zip listed on main"
else
  fail "object model_big_a.zip not found on main"
fi
if tag_exists "$UNIT_REPO" "$BIG_ZIP_TAG"; then
  pass "tag $BIG_ZIP_TAG created"
else
  fail "tag $BIG_ZIP_TAG missing"
fi

# --- Upload no-compress zip --------------------------------------------------
section "upload model_big_a_no_compress.zip (no-compress) → $UNIT_REPO/main (tag $BIG_NOCOMP_TAG)"
START=$SECONDS
"$UPLOAD_SH" "$PLAIN_ZIP" "$UNIT_REPO" main "$BIG_NOCOMP_TAG" >/dev/null
ELAPSED=$((SECONDS - START))
pass "upload.sh exited 0 (no-compress zip) in ${ELAPSED}s"
if object_exists "$UNIT_REPO" main model_big_a_no_compress.zip; then
  pass "object model_big_a_no_compress.zip listed on main"
else
  fail "object model_big_a_no_compress.zip not found on main"
fi
if tag_exists "$UNIT_REPO" "$BIG_NOCOMP_TAG"; then
  pass "tag $BIG_NOCOMP_TAG created"
else
  fail "tag $BIG_NOCOMP_TAG missing"
fi

# --- Download + verify sha256 (big-file round-trip) -------------------------
section "download + sha256 verify (big-file round-trip)"
DL_ZIP="$WORK/dl_model_big_a.zip"
"$DOWNLOAD_SH" "$UNIT_REPO" "$BIG_ZIP_TAG" model_big_a.zip "$DL_ZIP" >/dev/null
DL_SHA="$(sha256_file "$DL_ZIP")"
SRC_SHA="$(sha256_file "$ZSTD_ZIP")"
assert_eq "$DL_SHA" "$SRC_SHA" "downloaded big zip sha256 == uploaded (byte-exact)"

print_summary "test_big_upload.sh"

if [ "$NO_CLEANUP" = true ]; then
  warn "--no-cleanup: leaving repo $UNIT_REPO in place"
else
  section "cleanup"
  delete_unit_repo
fi

exit_code
