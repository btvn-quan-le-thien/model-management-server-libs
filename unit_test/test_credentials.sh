#!/bin/bash
# =============================================================================
# test_credentials.sh — Tests for dev-setup.sh credential validation
#
# Scenarios:
#   1. No credentials file present → dev-setup.sh must fail.
#   2. Empty credentials (credential is "none") → lakectl must reject (401).
#   3. Correct credentials → lakectl repo list succeeds.
#   4. Wrong credentials brute force (100 attempts) → every attempt rejected.
#
# Safety: tests use temp lakectl config files (-c <file>), so the real
# ~/.lakectl.yaml is never modified.
#
# Run:  ./test_credentials.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

section "test_credentials.sh — dev-setup.sh credential validation"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BRUTE_COUNT="${BRUTE_COUNT:-100}"

# --- Test 1: No credentials file → dev-setup.sh fails -------------------------
section "no credentials (credentials file missing)"
mkdir -p "$WORK/nocreds"
cp "$DEV_SETUP_SH" "$WORK/nocreds/"
if bash "$WORK/nocreds/dev-setup.sh" >"$WORK/nocreds_out.txt" 2>&1; then
  fail "dev-setup.sh succeeded without credentials (should have failed)"
else
  pass "dev-setup.sh failed without credentials (exit non-zero)"
  if grep -q "Credentials file not found" "$WORK/nocreds_out.txt"; then
    pass "error message contains 'Credentials file not found'"
  else
    fail "missing expected 'Credentials file not found' message"
    cat "$WORK/nocreds_out.txt" >&2
  fi
fi

# --- Test 2: Empty credentials → lakectl 401 ---------------------------------
section "empty credentials (credential is none)"
make_lakectl_config "$WORK/empty.yaml" "" ""
if lakectl_with_config "$WORK/empty.yaml" repo list >"$WORK/empty_out.txt" 2>&1; then
  fail "lakectl succeeded with empty credentials (should have failed)"
else
  pass "lakectl failed with empty credentials (exit non-zero)"
  if grep -q "401" "$WORK/empty_out.txt"; then
    pass "empty creds rejected with 401 Unauthorized"
  else
    warn "empty creds failed but not 401 (got: $(head -1 "$WORK/empty_out.txt"))"
  fi
fi

# --- lakeFS gate for remaining tests -----------------------------------------
if [ "${SKIP_LAKEFS:-0}" = "1" ]; then
  warn "SKIP_LAKEFS=1 → skipping correct/brute-force credential tests"
  print_summary "test_credentials.sh"
  exit_code
  exit $?
fi
if ! lakectl_alive; then
  warn "lakeFS not reachable — skipping correct/brute-force credential tests"
  print_summary "test_credentials.sh"
  exit_code
  exit $?
fi

# --- Test 3: Correct credentials → lakectl succeeds --------------------------
section "correct credentials"
if [ ! -f "$CRED_FILE" ]; then
  warn "credentials file not found at $CRED_FILE — skipping correct credentials test"
else
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  make_lakectl_config "$WORK/correct.yaml" "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY"
  if lakectl_with_config "$WORK/correct.yaml" repo list >"$WORK/correct_out.txt" 2>&1; then
    pass "correct credentials: lakectl repo list succeeded"
    if grep -q "ml-models" "$WORK/correct_out.txt"; then
      pass "correct credentials: repo list returned repos"
    else
      warn "repo list output did not contain 'ml-models'"
      cat "$WORK/correct_out.txt" >&2
    fi
  else
    fail "correct credentials: lakectl repo list failed (should have succeeded)"
    cat "$WORK/correct_out.txt" >&2
  fi
fi

# --- Test 4: Wrong credentials brute force (100 attempts) -------------------
section "wrong credentials brute force ($BRUTE_COUNT attempts)"
BRUTE_REJECTED=0
BRUTE_BREACHED=0
info "simulating $BRUTE_COUNT brute-force attempts with different wrong credentials..."
START=$SECONDS
for i in $(seq 1 "$BRUTE_COUNT"); do
  WRONG_AK="AKIA$(printf '%032d' "$i" | tr '0' x)"
  WRONG_SK="wrong$(printf '%040d' "$i" | tr '0' y)"
  make_lakectl_config "$WORK/brute_$i.yaml" "$WRONG_AK" "$WRONG_SK"
  if lakectl_with_config "$WORK/brute_$i.yaml" repo list >/dev/null 2>&1; then
    BRUTE_BREACHED=$((BRUTE_BREACHED+1))
    fail "brute force attempt $i: SUCCEEDED with wrong credentials (SECURITY BREACH!)"
  else
    BRUTE_REJECTED=$((BRUTE_REJECTED+1))
  fi
  if [ $((i % 25)) -eq 0 ] || [ "$i" -eq "$BRUTE_COUNT" ]; then
    info "  ... $i/$BRUTE_COUNT attempts ($BRUTE_REJECTED rejected, $BRUTE_BREACHED breached)"
  fi
done
ELAPSED=$((SECONDS - START))
info "brute force completed in ${ELAPSED}s"
info "results: $BRUTE_REJECTED/$BRUTE_COUNT rejected, $BRUTE_BREACHED/$BRUTE_COUNT breached"
assert_eq "$BRUTE_REJECTED" "$BRUTE_COUNT" "all $BRUTE_COUNT brute-force attempts rejected"
assert_eq "$BRUTE_BREACHED" "0" "no brute-force attempt succeeded (no breach)"

print_summary "test_credentials.sh"
exit_code
