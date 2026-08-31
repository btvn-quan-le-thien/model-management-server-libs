#!/bin/bash
# =============================================================================
# run_all.sh — Run the whole unit_test suite in order.
#
# Order:
#   1. test_pack.sh            (local: zstd vs no-compress, size reduction)
#   2. test_unpack.sh          (local: pack/unpack round-trip + force guard)
#   3. test_credentials.sh     (mixed: no/empty creds local, correct/brute-force lakeFS)
#   4. test_upload.sh          (lakeFS: create unit-test repo, upload zip+folder)
#   5. test_download.sh        (lakeFS: download/—unzip/—unpack round-trip)
#   6. test_big_upload.sh      (lakeFS: pack + upload 500 MB zip, both zstd + no-compress)
#   7. cleanup: delete the per-run repo (unless --no-cleanup)
#
# lakeFS gate: health.sh is run first. If lakeFS is unreachable (or
# SKIP_LAKEFS=1), tests 3–4 are skipped with a warning; the local tests still
# run. The unit_test repo is deleted at the end unless --no-cleanup.
#
# A shared run id (UNIT_TEST_RUN_ID) is exported so upload/download agree on
# the same tags (download self-provisions its own data regardless).
#
# Usage:
#   ./run_all.sh                # run all, then delete unit_test repo
#   ./run_all.sh --no-cleanup   # keep the unit_test repo for inspection
#   SKIP_LAKEFS=1 ./run_all.sh  # skip lakeFS-dependent tests
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

# Shared run id so upload + download use the same tags.
export UNIT_TEST_RUN_ID="${UNIT_TEST_RUN_ID:-$(run_id)}"
RUN_ID="$UNIT_TEST_RUN_ID"
info "run id: $RUN_ID"

# --- Decide whether lakeFS-dependent tests run -------------------------------
RUN_LAKEFS=true
if [ "${SKIP_LAKEFS:-0}" = "1" ]; then
  warn "SKIP_LAKEFS=1 → skipping upload/download tests"
  RUN_LAKEFS=false
elif ! lakectl_alive; then
  warn "lakeFS not reachable (./health.sh) → skipping upload/download tests"
  warn "(pack/unpack tests will still run; set up lakeFS + ./dev-setup.sh to enable the rest)"
  RUN_LAKEFS=false
else
  info "lakeFS reachable → running upload/download tests"
fi

# --- Runners -----------------------------------------------------------------
# run_suite <name> <script> [args...] : run a suite, capture exit code, echo
# a machine-parseable summary line, accumulate totals.
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITE_RESULTS=()

run_suite() {
  local name="$1"; shift
  local log
  log="$(mktemp)"
  info "▶ running $name ..."
  if "$@" >"$log" 2>&1; then
    local rc=0
  else
    local rc=$?
  fi
  # Stream the suite's output to the console.
  cat "$log"
  # Parse its "PASS: X  FAIL: Y  SKIP: Z" summary line if present.
  # Strip ANSI color codes first (the summary line uses them).
  local clean
  clean="$(sed 's/\x1b\[[0-9;]*m//g' "$log")"
  local line sp sf ss
  line="$(printf '%s' "$clean" | grep -E 'PASS: +[0-9]+ +FAIL: +[0-9]+ +SKIP: +[0-9]+' | tail -1 || true)"
  sp="$(printf '%s' "$line" | sed -n 's/.*PASS: \([0-9]*\).*/\1/p')"
  sf="$(printf '%s' "$line" | sed -n 's/.*FAIL: \([0-9]*\).*/\1/p')"
  ss="$(printf '%s' "$line" | sed -n 's/.*SKIP: \([0-9]*\).*/\1/p')"
  sp="${sp:-0}"; sf="${sf:-0}"; ss="${ss:-0}"
  TOTAL_PASS=$((TOTAL_PASS+sp))
  TOTAL_FAIL=$((TOTAL_FAIL+sf))
  TOTAL_SKIP=$((TOTAL_SKIP+ss))
  if [ "$rc" -eq 0 ]; then
    SUITE_RESULTS+=("PASS  $name")
  else
    SUITE_RESULTS+=("FAIL  $name (exit $rc)")
  fi
  rm -f "$log"
  # Propagate failure to the overall run (but keep running the rest).
  return "$rc"
}

OVERALL_RC=0

# 1. pack (local)
run_suite "test_pack.sh"   "$SCRIPT_DIR/test_pack.sh"   || OVERALL_RC=1

# 2. unpack (local)
run_suite "test_unpack.sh"  "$SCRIPT_DIR/test_unpack.sh" || OVERALL_RC=1

# 3. credentials (mixed: "no creds" is local, correct/brute-force need lakeFS)
run_suite "test_credentials.sh" "$SCRIPT_DIR/test_credentials.sh" || OVERALL_RC=1

# 4. upload (lakeFS) — pass --no-cleanup so the repo survives for download.
if [ "$RUN_LAKEFS" = true ]; then
  run_suite "test_upload.sh"   "$SCRIPT_DIR/test_upload.sh" --no-cleanup || OVERALL_RC=1

  # 5. download (lakeFS)
  run_suite "test_download.sh" "$SCRIPT_DIR/test_download.sh" || OVERALL_RC=1

  # 6. big upload (lakeFS) — 500 MB pack + upload; pass --no-cleanup so run_all cleans up.
  run_suite "test_big_upload.sh" "$SCRIPT_DIR/test_big_upload.sh" --no-cleanup || OVERALL_RC=1

  # 7. cleanup: delete the per-run repo unless --no-cleanup.
  section "cleanup"
  if [ "$NO_CLEANUP" = true ]; then
    warn "--no-cleanup: keeping repo $UNIT_REPO (delete manually: ./lakectl.sh repo delete lakefs://$UNIT_REPO -y)"
  else
    delete_unit_repo
  fi
else
  skip "test_upload.sh     (lakeFS not available)"
  skip "test_download.sh  (lakeFS not available)"
  skip "test_big_upload.sh (lakeFS not available)"
  if [ "$NO_CLEANUP" = true ]; then
    warn "--no-cleanup: nothing to clean (lakeFS tests skipped)"
  fi
fi

# --- Final summary -----------------------------------------------------------
section "OVERALL RESULTS"
printf '  %s\n' "${SUITE_RESULTS[@]}"
echo ""
echo -e "${C_BOLD}Totals: ${C_GREEN}PASS $TOTAL_PASS${C_OFF}  ${C_RED}FAIL $TOTAL_FAIL${C_OFF}  ${C_YELLOW}SKIP $TOTAL_SKIP${C_OFF}"
if [ "$OVERALL_RC" -eq 0 ]; then
  echo -e "${C_GREEN}All suites passed.${C_OFF}"
else
  echo -e "${C_RED}One or more suites FAILED.${C_OFF}"
fi
exit "$OVERALL_RC"
