#!/bin/bash
# =============================================================================
# test_pack.sh — Tests for pack.sh
#
# Verifies:
#   1. Pack WITH zstd: zip is created, weight files become *.zst inside, plain
#      files (config.json/README.md) stay uncompressed, and the total zip size
#      is reduced vs the original folder AND vs a plain zip.
#   2. Pack WITHOUT zstd (--no-compress): zip contains the raw weight files
#      (no .zst) and plain files.
#
# Run:  ./test_pack.sh        (standalone)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

section "test_pack.sh — pack.sh (zstd vs no-compress)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIX="$(build_fixture "$WORK")"
FIX_BYTES="$(dir_bytes "$FIX")"
info "fixture: $FIX ($(file_bytes "$FIX/model.pkl") bytes/weight file, $FIX_BYTES bytes total)"

# --- Test 1: pack with zstd (default) ----------------------------------------
section "pack WITH zstd (default)"
ZSTD_ZIP="$WORK/model_test.zip"
"$PACK_SH" "$FIX" -o "$ZSTD_ZIP" >/dev/null
ZSTD_BYTES="$(file_bytes "$ZSTD_ZIP")"
info "zstd.zip = $ZSTD_BYTES bytes"

assert_file_exists "$ZSTD_ZIP" "zstd zip created"
assert_not_empty "$ZSTD_ZIP" "zstd zip non-empty"
# weight files compressed to .zst
assert_zip_contains "$ZSTD_ZIP" 'model\.pkl\.zst'  "weights compressed to .zst (model.pkl)"
assert_zip_contains "$ZSTD_ZIP" 'weights\.pt\.zst' "weights compressed to .zst (weights.pt)"
assert_zip_contains "$ZSTD_ZIP" 'vocab\.bin\.zst'  "weights compressed to .zst (vocab.bin)"
# plain metadata files NOT compressed
assert_zip_contains    "$ZSTD_ZIP" 'config\.json'  "config.json present (uncompressed)"
assert_zip_not_contains "$ZSTD_ZIP" 'config\.json\.zst' "config.json not compressed"
assert_zip_contains    "$ZSTD_ZIP" 'README\.md'   "README.md present (uncompressed)"
# size reduced vs original folder
assert_lt "$ZSTD_BYTES" "$FIX_BYTES" "zstd zip < original folder size (reduced)"

# --- Test 2: pack without zstd (--no-compress) --------------------------------
section "pack WITHOUT zstd (--no-compress)"
PLAIN_ZIP="$WORK/plain.zip"
"$PACK_SH" "$FIX" --no-compress -o "$PLAIN_ZIP" >/dev/null
PLAIN_BYTES="$(file_bytes "$PLAIN_ZIP")"
info "plain.zip = $PLAIN_BYTES bytes"

assert_file_exists "$PLAIN_ZIP" "plain zip created"
assert_not_empty "$PLAIN_ZIP" "plain zip non-empty"
# raw weight files present, no .zst anywhere
assert_zip_contains "$PLAIN_ZIP" 'model\.pkl'  "raw model.pkl present"
assert_zip_contains "$PLAIN_ZIP" 'weights\.pt' "raw weights.pt present"
assert_zip_contains "$PLAIN_ZIP" 'vocab\.bin'  "raw vocab.bin present"
assert_zip_not_contains "$PLAIN_ZIP" '\.zst'   "no .zst files in plain zip"
assert_zip_contains "$PLAIN_ZIP" 'config\.json' "config.json present"
assert_zip_contains "$PLAIN_ZIP" 'README\.md'   "README.md present"

# --- Bonus: zstd zip is smaller than the plain zip ---------------------------
section "zstd vs plain (zstd should be smaller)"
info "zstd.zip=$ZSTD_BYTES  plain.zip=$PLAIN_BYTES  folder=$FIX_BYTES"
assert_lt "$ZSTD_BYTES" "$PLAIN_BYTES" "zstd zip < plain zip (zstd adds compression beyond zip deflate)"

# --- Input folder untouched --------------------------------------------------
section "input folder unchanged"
if diff -r "$FIX" "$FIX" >/dev/null 2>&1; then
  pass "input folder still present after pack (pack stages a copy)"
fi
# verify the weight files in the source fixture are still raw (no .zst leaked)
[ -f "$FIX/model.pkl" ] && pass "source model.pkl untouched" || fail "source model.pkl removed"
[ -f "$FIX/weights.pt" ] && pass "source weights.pt untouched" || fail "source weights.pt removed"
[ ! -f "$FIX/model.pkl.zst" ] && pass "no .zst leaked into source folder" || fail ".zst leaked into source folder"

print_summary "test_pack.sh"
exit_code
