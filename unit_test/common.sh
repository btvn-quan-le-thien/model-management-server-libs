#!/bin/bash
# =============================================================================
# common.sh — Shared helpers for the unit_test suite.
#
# Sourced by every test_*.sh and run_all.sh. Provides:
#   - Project-root + lakectl resolution
#   - Pass/fail/skip counters + colored output
#   - Assertions (file exists, numeric less-than, dir equality, string eq, sha256)
#   - Fixture builder (a realistic model folder with compressible weight files)
#   - lakeFS helpers (repo exists/create/delete, object exists, tag exists, health)
#
# Not meant to be executed directly.
# =============================================================================

# Resolve project root = parent of the directory holding this file.
UNIT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$UNIT_TEST_DIR/.." && pwd)"

LAKECTL_SH="$PROJECT_ROOT/lakectl.sh"
LAKECTL_BIN="$PROJECT_ROOT/bin/lakectl"
PACK_SH="$PROJECT_ROOT/pack.sh"
UNPACK_SH="$PROJECT_ROOT/unpack.sh"
UPLOAD_SH="$PROJECT_ROOT/upload.sh"
DOWNLOAD_SH="$PROJECT_ROOT/download.sh"
HEALTH_SH="$PROJECT_ROOT/health.sh"
DEV_SETUP_SH="$PROJECT_ROOT/dev-setup.sh"
CRED_FILE="$PROJECT_ROOT/config.env"
if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CRED_FILE"
fi
LAKEFS_ENDPOINT="${LAKEFS_ENDPOINT:-http://localhost:8088}"

# Unit-test lakeFS repo + storage namespace.
# Computed per run from the run id (see get_run_id below) so each run gets its
# own repo + namespace. This is required because:
#   - lakeFS rejects underscores in repo names (we use a hyphen), and
#   - deleting a repo leaves its storage namespace permanently "dirty"
#     (_lakefs/dummy marker), so a fixed name could not be recreated across
#     runs. A per-run namespace avoids that collision entirely.
# UNIT_REPO / UNIT_REPO_NS are assigned after get_run_id is defined (see below).

# --- Counters (globals so they survive across sourced test files) -----------
TEST_PASS=0
TEST_FAIL=0
TEST_SKIP=0

# --- Colors ------------------------------------------------------------------
C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'; C_OFF='\033[0m'

section() { echo -e "\n${C_CYAN}━━━ $* ━━━${C_OFF}"; }
info()    { echo -e "${C_BLUE}[INFO]${C_OFF}  $*"; }
pass()    { TEST_PASS=$((TEST_PASS+1)); echo -e "${C_GREEN}[PASS]${C_OFF}  $*"; }
fail()    { TEST_FAIL=$((TEST_FAIL+1)); echo -e "${C_RED}[FAIL]${C_OFF}  $*"; }
warn()    { echo -e "${C_YELLOW}[WARN]${C_OFF}  $*"; }
skip()    { TEST_SKIP=$((TEST_SKIP+1)); echo -e "${C_YELLOW}[SKIP]${C_OFF}  $*"; }

# Hard failure: print and exit immediately (for unrecoverable setup errors).
fatal() { echo -e "${C_RED}[FATAL]${C_OFF} $*" >&2; exit 1; }

# --- Assertions (non-fatal: record pass/fail, keep running) -------------------
assert_file_exists() {
  local f="$1" msg="${2:-}"
  if [ -f "$f" ]; then pass "${msg:-file exists: $f}"; else fail "${msg:-file missing: $f}"; fi
}

assert_not_empty() {
  local f="$1" msg="${2:-}"
  if [ -s "$f" ]; then pass "${msg:-file non-empty: $f}"; else fail "${msg:-file empty: $f}"; fi
}

# assert_lt <a> <b> : assert integer a < b
assert_lt() {
  local a="$1" b="$2" msg="${3:-}"
  if [ "$a" -lt "$b" ] 2>/dev/null; then pass "${msg:-$a < $b}"; else fail "${msg:-$a >= $b (expected $a < $b)}"; fi
}

# assert_le <a> <b> : assert integer a <= b
assert_le() {
  local a="$1" b="$2" msg="${3:-}"
  if [ "$a" -le "$b" ] 2>/dev/null; then pass "${msg:-$a <= $b}"; else fail "${msg:-$a > $b (expected $a <= $b)}"; fi
}

assert_eq() {
  local a="$1" b="$2" msg="${3:-}"
  if [ "$a" = "$b" ]; then pass "${msg:-equal: '$a'}"; else fail "${msg:-'$a' != '$b'}"; fi
}

assert_ne() {
  local a="$1" b="$2" msg="${3:-}"
  if [ "$a" != "$b" ]; then pass "${msg:-differ as expected}"; else fail "${msg:-'$a' == '$b' (expected different)}"; fi
}

# assert_dir_eq <dir_a> <dir_b> : recursive content identical (diff -r)
assert_dir_eq() {
  local a="$1" b="$2" msg="${3:-}"
  if diff -r "$a" "$b" >/dev/null 2>&1; then
    pass "${msg:-dirs identical: $(basename "$a") == $(basename "$b")}"
  else
    fail "${msg:-dirs differ: $a != $b}"
    diff -r "$a" "$b" >&2 | head -20
  fi
}

# assert_zip_contains <zip> <pattern> : grep pattern in `unzip -l` listing
assert_zip_contains() {
  local zip="$1" pat="$2" msg="${3:-}"
  if unzip -l "$zip" 2>/dev/null | grep -q "$pat"; then
    pass "${msg:-zip contains '$pat'}"
  else
    fail "${msg:-zip missing '$pat'}"
  fi
}

# assert_zip_not_contains <zip> <pattern>
assert_zip_not_contains() {
  local zip="$1" pat="$2" msg="${3:-}"
  if unzip -l "$zip" 2>/dev/null | grep -q "$pat"; then
    fail "${msg:-zip unexpectedly contains '$pat'}"
  else
    pass "${msg:-zip does not contain '$pat'}"
  fi
}

# --- Misc helpers ------------------------------------------------------------
sha256_file() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$1" | cut -d' ' -f1; }

# byte size of a file (linux stat -c or mac stat -f)
file_bytes() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null; }

# total byte size of a directory tree
dir_bytes() { du -sb "$1" 2>/dev/null | cut -f1 || du -sk "$1" | awk '{print $1*1024}'; }

# unique id for this run (timestamp + pid) — used for branch/tag uniqueness
run_id() { date +%Y%m%d%H%M%S; }

# Shared run id: prefer env var (set by run_all.sh so upload/download agree on
# the same tags); fall back to a fresh timestamp when run standalone.
get_run_id() { echo "${UNIT_TEST_RUN_ID:-$(run_id)}"; }

# Deterministic tags derived from the run id (shared across upload/download).
zip_tag()    { echo "unit-test-$(get_run_id)"; }
folder_tag() { echo "unit-test-$(get_run_id)-folder"; }

# Per-run repo name + storage namespace (assigned now that get_run_id exists).
__unit_rid="$(get_run_id)"
UNIT_REPO="unit-test-${__unit_rid}"
UNIT_REPO_NS="s3://lakefs-data/unit-test-${__unit_rid}"
unset __unit_rid

# Print a per-file summary line.
print_summary() {
  local name="${1:-tests}"
  echo ""
  echo -e "${C_BOLD}--- $name summary ---${C_OFF}"
  echo -e "  ${C_GREEN}PASS:${C_OFF} $TEST_PASS   ${C_RED}FAIL:${C_OFF} $TEST_FAIL   ${C_YELLOW}SKIP:${C_OFF} $TEST_SKIP"
}

# Exit code helper: 0 if no failures, 1 otherwise.
exit_code() { [ "$TEST_FAIL" -eq 0 ]; }

# --- Fixture builder ---------------------------------------------------------
# build_fixture <dest_dir> -> echoes the fixture folder path (model_test/)
# Creates a realistic model folder: plain metadata files + compressible weight
# files (.pkl/.pt/.bin) made of a repeated byte pattern (compresses dramatically
# under zstd so size reduction is obvious, while staying fast to generate).
build_fixture() {
  local dest="$1" name="${2:-model_test}"
  local fix="$dest/$name"
  rm -rf "$fix"
  mkdir -p "$fix"

  cat > "$fix/config.json" <<'JSON'
{
  "model": "unit-test-fixture",
  "version": "1.0.0",
  "layers": 12,
  "hidden_size": 768
}
JSON

  printf 'This is a README for the unit-test fixture model.\nIt is not compressed by default.\n' > "$fix/README.md"

  # 5 MiB of a repeated ASCII pattern per weight file: highly compressible.
  yes "modelweightpattern0123456789" | head -c 5M > "$fix/model.pkl"
  yes "modelweightpattern0123456789" | head -c 5M > "$fix/weights.pt"
  yes "modelweightpattern0123456789" | head -c 5M > "$fix/vocab.bin"

  echo "$fix"
}

# --- lakeFS helpers ----------------------------------------------------------

# lakectl wrapper (so tests use the project's configured binary).
lk() { "$LAKECTL_SH" "$@"; }

# Is the lakeFS server reachable? (0 yes, 1 no)
lakectl_alive() {
  "$LAKECTL_SH" repo list >/dev/null 2>&1
}

# Does a repo exist? (0 yes, 1 no)
repo_exists() {
  local repo="$1"
  "$LAKECTL_SH" repo list 2>/dev/null | awk '{print $1}' | grep -qx "$repo"
}

# Create the unit_test repo if it doesn't already exist.
ensure_unit_repo() {
  if repo_exists "$UNIT_REPO"; then
    info "Repo '$UNIT_REPO' already exists"
    return 0
  fi
  info "Creating repo '$UNIT_REPO' ($UNIT_REPO_NS) ..."
  "$LAKECTL_SH" repo create "lakefs://$UNIT_REPO" "$UNIT_REPO_NS" --default-branch main \
    || fatal "Failed to create repo $UNIT_REPO"
  pass "repo created: $UNIT_REPO"
}

# Delete the unit_test repo (idempotent, --yes).
delete_unit_repo() {
  if repo_exists "$UNIT_REPO"; then
    info "Deleting repo '$UNIT_REPO' ..."
    "$LAKECTL_SH" repo delete "lakefs://$UNIT_REPO" -y \
      && pass "repo deleted: $UNIT_REPO" \
      || warn "could not delete repo $UNIT_REPO (cleanup manually)"
  else
    info "Repo '$UNIT_REPO' not present, nothing to delete"
  fi
}

# Does an object exist at lakefs://<repo>/<ref>/<path>? (0 yes, 1 no)
object_exists() {
  local repo="$1" ref="$2" path="$3"
  "$LAKECTL_SH" fs ls "lakefs://$repo/$ref/" 2>/dev/null | awk '{print $NF}' | grep -qx "$path"
}

# Does a tag exist? (0 yes, 1 no)
tag_exists() {
  local repo="$1" tag="$2"
  "$LAKECTL_SH" tag list "lakefs://$repo" 2>/dev/null | awk '{print $1}' | grep -qx "$tag"
}

# Delete a tag if it exists (cleanup helper).
delete_tag() {
  local repo="$1" tag="$2"
  if tag_exists "$repo" "$tag"; then
    "$LAKECTL_SH" tag delete "lakefs://$repo/$tag" -y >/dev/null 2>&1 || true
  fi
}

# --- Credential helpers (for test_credentials.sh) ---------------------------

# make_lakectl_config <output_path> <access_key_id> <secret_access_key> [endpoint]
# Write a lakectl YAML config file with the given credentials. Used to test
# correct, wrong, and empty credentials WITHOUT touching the real ~/.lakectl.yaml.
make_lakectl_config() {
  local out="$1" ak="$2" sk="${3:-}" endpoint="${4:-${LAKEFS_ENDPOINT}}"
  cat > "$out" <<YAML
server:
  endpoint_url: $endpoint
credentials:
  access_key_id: "$ak"
  secret_access_key: "$sk"
YAML
}

# Run lakectl with a specific config file (does not use ~/.lakectl.yaml).
lakectl_with_config() {
  local cfg="$1"; shift
  "$LAKECTL_BIN" -c "$cfg" "$@"
}

# --- Big fixture builder (for test_big_upload.sh) ----------------------------

# build_big_fixture <dest_dir> [name] [size_mb] -> echoes the fixture folder path
# Creates a large model folder (default 500 MB) that mirrors a real model: plain
# metadata files (config.json, README.md) + three weight files using the default
# pack.sh extensions (.pkl, .pt, .bin).
#
# The weight data is a 1 MiB random block repeated many times. This gives a
# realistic balance for testing:
#   - zstd (large window) finds the repeats → dramatic compression (~90%).
#   - zip deflate (small ~32 KB window) can't see across the 1 MiB block →
#     stores nearly as-is.
# So the --no-compress zip stays ~500 MB (a genuinely large file in lakeFS),
# while the zstd zip shrinks to ~50 MB — a dramatic, visible reduction.
build_big_fixture() {
  local dest="$1" name="${2:-model_big_a}" size_mb="${3:-500}"
  local fix="$dest/$name"
  rm -rf "$fix"
  mkdir -p "$fix"

  cat > "$fix/config.json" <<'JSON'
{
  "model": "unit-test-big-fixture",
  "version": "1.0.0",
  "size_mb": 500,
  "description": "Large fixture for big upload testing"
}
JSON

  printf '# Big Model README\nLarge fixture for big-upload testing.\n' > "$fix/README.md"

  # Split the requested size across three weight files (.pkl, .pt, .bin) using
  # the default pack.sh extensions: 40% / 40% / 20%.
  local pkl_mb pt_mb bin_mb
  pkl_mb=$(( size_mb * 40 / 100 ))   # 40%
  pt_mb=$(( size_mb * 40 / 100 ))    # 40%
  bin_mb=$(( size_mb - pkl_mb - pt_mb ))  # remaining ~20%

  # Generate a single 1 MiB random block, then repeat it to fill each weight
  # file. zstd's large window compresses the repetitions; zip deflate can't.
  local block="$dest/.big_block"
  dd if=/dev/urandom of="$block" bs=1M count=1 2>/dev/null

  local i
  { for ((i=0; i<pkl_mb; i++)); do cat "$block"; done; } > "$fix/model.pkl"
  { for ((i=0; i<pt_mb;  i++)); do cat "$block"; done; } > "$fix/weights.pt"
  { for ((i=0; i<bin_mb; i++)); do cat "$block"; done; } > "$fix/vocab.bin"

  rm -f "$block"

  echo "$fix"
}
