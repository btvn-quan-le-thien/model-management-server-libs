#!/bin/bash
# =============================================================================
# test_upload.sh — Tests for upload.sh (against lakeFS)
#
#   - Creates the `unit_test` repo if it does not already exist.
#   - Packs a fixture, uploads the zip to `unit_test/main`, and verifies the
#     object appears, the commit carries the version metadata, and the tag
#     was created.
#   - Uploads the fixture folder (recursive) and verifies it appears.
#   - Cleanup: unless --no-cleanup is passed, the `unit_test` repo is deleted
#     at the end of THIS script. When run via run_all.sh, run_all.sh passes
#     --no-cleanup so the repo survives for the download tests, and deletes
#     it afterwards.
#
# Usage:
#   ./test_upload.sh                # create repo, run tests, then delete repo
#   ./test_upload.sh --no-cleanup   # keep repo (for run_all.sh / manual inspect)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

NO_CLEANUP=false
for arg in "$@"; do
  case "$arg" in
    --no-cleanup) NO_CLEANUP=true ;;
    -h|--help)
      sed -n '4,/^# =\{20,\}=$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

# Require lakeFS.
if ! lakectl_alive; then fatal "lakeFS not reachable — run ./health.sh"; fi

section "test_upload.sh — upload.sh (repo: $UNIT_REPO)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ZIP_TAG="$(zip_tag)"
FOLDER_TAG="$(folder_tag)"
info "run id: $(get_run_id)"
info "zip tag:    $ZIP_TAG"
info "folder tag: $FOLDER_TAG"

# --- Ensure repo exists ------------------------------------------------------
ensure_unit_repo

# --- Build fixture + pack ----------------------------------------------------
FIX="$(build_fixture "$WORK")"
ZIP="$WORK/model_test.zip"
"$PACK_SH" "$FIX" -o "$ZIP" >/dev/null
assert_file_exists "$ZIP" "fixture packed"

# --- Test 1: upload a zip -----------------------------------------------------
section "upload zip → $UNIT_REPO/main (tag $ZIP_TAG)"
"$UPLOAD_SH" "$ZIP" "$UNIT_REPO" main "$ZIP_TAG" >/dev/null
pass "upload.sh exited 0 (zip)"

# object visible on main
if object_exists "$UNIT_REPO" main model_test.zip; then
  pass "object model_test.zip listed on main"
else
  fail "object model_test.zip not found on main"
fi

# commit metadata version=<tag>
if "$LAKECTL_SH" log "lakefs://$UNIT_REPO/main" 2>/dev/null | grep -q "version.*= $ZIP_TAG"; then
  pass "commit metadata version=$ZIP_TAG present in log"
else
  fail "commit metadata version=$ZIP_TAG not found in log"
fi

# tag created
if tag_exists "$UNIT_REPO" "$ZIP_TAG"; then
  pass "tag $ZIP_TAG created"
else
  fail "tag $ZIP_TAG missing"
fi

# --- Test 2: upload a folder (recursive) -------------------------------------
section "upload folder → $UNIT_REPO/main (tag $FOLDER_TAG)"
"$UPLOAD_SH" "$FIX/" "$UNIT_REPO" main "$FOLDER_TAG" >/dev/null
pass "upload.sh exited 0 (folder)"

# folder object appears (the folder is uploaded under its basename model_test/)
if "$LAKECTL_SH" fs ls "lakefs://$UNIT_REPO/main/model_test/" 2>/dev/null | grep -q 'config.json'; then
  pass "folder uploaded: model_test/config.json visible"
else
  fail "folder contents not visible under model_test/"
fi

if tag_exists "$UNIT_REPO" "$FOLDER_TAG"; then
  pass "tag $FOLDER_TAG created"
else
  fail "tag $FOLDER_TAG missing"
fi

# --- Cleanup -----------------------------------------------------------------
print_summary "test_upload.sh"

if [ "$NO_CLEANUP" = true ]; then
  warn "--no-cleanup: leaving repo $UNIT_REPO in place (download tests will use it)"
else
  section "cleanup"
  delete_unit_repo
fi

exit_code
