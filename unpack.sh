#!/bin/bash
set -euo pipefail

# =============================================================================
# unpack.sh — Unpack a model zip produced by pack.sh.
#
# The zip is unzipped into a staging directory, then any *.zst files inside
# are decompressed with zstd (restoring e.g. model.pkl.zst -> model.pkl, with
# the .zst removed). Plain zips (no .zst files) are handled correctly — the
# decompression loop is simply a no-op. The result is atomically moved into
# the destination directory (default: <zip-basename>.zip -> <zip-basename>/).
#
# Usage:  ./unpack.sh <zip> [-d <dest_dir>] [-f,--force]
#
# Options:
#   -d <dest_dir>     Destination directory (default: <zip basename minus .zip>).
#   -f, --force       Overwrite an existing destination directory.
#   -h, --help        Show this help.
#
# Examples:
#   ./unpack.sh ./model_a.zip                # -> ./model_a/
#   ./unpack.sh ./model_a.zip -d ./restored
#   ./unpack.sh ./model_a.zip -f             # overwrite if exists
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ZIP=""
DEST=""
FORCE=false

usage() {
  sed -n '4,^# =\{20,\}=$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d) DEST="${2:-}"; shift 2 ;;
    -f|--force) FORCE=true; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)
      if [ -z "$ZIP" ]; then
        ZIP="$1"
      else
        echo "Unexpected argument: $1" >&2; usage 1
      fi
      shift
      ;;
  esac
done

if [ -z "$ZIP" ]; then
  echo "Error: <zip> is required" >&2
  usage 1
fi

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# --- Validate input ---
if [ ! -f "$ZIP" ]; then
  fail "Not a file: $ZIP"
fi
ZIP_ABS="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"

ZIP_BASE="$(basename "$ZIP_ABS")"
DEST="${DEST:-$(dirname "$ZIP_ABS")/${ZIP_BASE%.zip}}"
DEST_ABS="$(cd "$(dirname "$DEST")" && pwd)/$(basename "$DEST")"

# --- Tool checks ---
if ! command -v unzip >/dev/null 2>&1; then
  fail "'unzip' is required (apt-get install unzip)"
fi

# --- Destination guard ---
if [ -e "$DEST_ABS" ]; then
  if [ "$FORCE" = true ]; then
    warn "Destination exists, removing: $DEST_ABS"
    rm -rf "$DEST_ABS"
  else
    fail "Destination already exists: $DEST_ABS (use -f to overwrite)"
  fi
fi

# --- Peek inside: do we need zstd? ---
NEEDS_ZSTD=false
if unzip -l "$ZIP_ABS" | grep -q '\.zst$'; then
  NEEDS_ZSTD=true
fi
if [ "$NEEDS_ZSTD" = true ] && ! command -v zstd >/dev/null 2>&1; then
  fail "'zstd' is required to decompress this zip (apt-get install zstd)"
fi

# --- Unzip into a staging directory (atomic swap into place at the end) ---
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "Unzipping $ZIP_BASE -> staging ..."
unzip -o -q "$ZIP_ABS" -d "$STAGE"

DECOMP_COUNT=0
if [ "$NEEDS_ZSTD" = true ]; then
  info "Decompressing *.zst files with zstd ..."
  while IFS= read -r -d '' z; do
    out="${z%.zst}"
    if zstd -d -q --rm -o "$out" -- "$z"; then
      DECOMP_COUNT=$((DECOMP_COUNT + 1))
      echo "  zstd -d: $(basename "$z") -> $(basename "$out")"
    else
      warn "zstd -d failed on: $z (leaving .zst in place)"
    fi
  done < <(find "$STAGE" -type f -name '*.zst' -print0)
else
  info "No .zst files found — plain zip"
fi

# --- Move staging into place atomically ---
info "Finalizing -> $DEST_ABS"
mv "$STAGE" "$DEST_ABS"
trap - EXIT

FILE_COUNT=$(find "$DEST_ABS" -type f | wc -l)
DEST_SIZE=$(du -sh "$DEST_ABS" | cut -f1)

echo ""
ok "=== Unpack complete ==="
echo "  Zip:        $ZIP_ABS"
echo "  Output:     $DEST_ABS ($DEST_SIZE)"
echo "  Files:      $FILE_COUNT"
echo "  zstd -d:    $DECOMP_COUNT file(s) decompressed"
echo ""
ls -la "$DEST_ABS"
echo ""
