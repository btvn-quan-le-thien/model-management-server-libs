#!/bin/bash
# =============================================================================
# test_unpack.sh — Round-trip tests for pack.sh + unpack.sh
#
# Flow (per the user's spec):
#   pack.sh a folder WITH zstd  -> unpack.sh -> diff -r vs original (must match)
#   pack.sh a folder WITHOUT zstd -> unpack.sh -> diff -r vs original (must match)
#   Force guard: unpack into an existing dest without -f fails; with -f succeeds.
#
# Run:  ./test_unpack.sh        (standalone)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

section "test_unpack.sh — pack/unpack round-trip"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FIX="$(build_fixture "$WORK")"
info "fixture: $FIX"

# --- Round-trip WITH zstd ----------------------------------------------------
section "round-trip WITH zstd"
ZSTD_ZIP="$WORK/model_test_zstd.zip"
"$PACK_SH" "$FIX" -o "$ZSTD_ZIP" >/dev/null
assert_file_exists "$ZSTD_ZIP" "zstd zip created"

RESTORED1="$WORK/restored_zstd"
"$UNPACK_SH" "$ZSTD_ZIP" -d "$RESTORED1" -f >/dev/null
assert_dir_eq "$FIX" "$RESTORED1" "zstd round-trip: restored == original"
# specifically: .zst files were decompressed back to raw weights
[ -f "$RESTORED1/model.pkl" ] && pass "restored model.pkl (decompressed)" || fail "restored model.pkl missing"
[ ! -e "$RESTORED1/model.pkl.zst" ] && pass "no leftover .zst after unpack" || fail "leftover model.pkl.zst"
[ -f "$RESTORED1/config.json" ] && pass "config.json restored" || fail "config.json missing"

# --- Round-trip WITHOUT zstd -------------------------------------------------
section "round-trip WITHOUT zstd"
PLAIN_ZIP="$WORK/model_test_plain.zip"
"$PACK_SH" "$FIX" --no-compress -o "$PLAIN_ZIP" >/dev/null
assert_file_exists "$PLAIN_ZIP" "plain zip created"

RESTORED2="$WORK/restored_plain"
"$UNPACK_SH" "$PLAIN_ZIP" -d "$RESTORED2" -f >/dev/null
assert_dir_eq "$FIX" "$RESTORED2" "plain round-trip: restored == original"
[ -f "$RESTORED2/model.pkl" ] && pass "plain: model.pkl restored" || fail "plain: model.pkl missing"
[ -f "$RESTORED2/weights.pt" ] && pass "plain: weights.pt restored" || fail "plain: weights.pt missing"

# --- Force guard: existing destination ---------------------------------------
section "force guard (-f)"
# Unpacking into RESTORED1 (already exists) WITHOUT -f should fail.
if "$UNPACK_SH" "$ZSTD_ZIP" -d "$RESTORED1" >/dev/null 2>&1; then
  fail "unpack overwrote existing dest WITHOUT -f (should have refused)"
else
  pass "unpack refused to overwrite existing dest without -f"
fi
# Unpacking into RESTORED1 WITH -f should succeed.
if "$UNPACK_SH" "$ZSTD_ZIP" -d "$RESTORED1" -f >/dev/null 2>&1; then
  pass "unpack overwrote existing dest WITH -f"
else
  fail "unpack with -f failed on existing dest"
fi
assert_dir_eq "$FIX" "$RESTORED1" "after -f overwrite: restored == original"

print_summary "test_unpack.sh"
exit_code
