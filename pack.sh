#!/bin/bash
set -euo pipefail

# =============================================================================
# pack.sh — Pack a model folder into a zip for upload to lakeFS.
#
# By default each model weight file (.pkl/.pt/.bin/.safetensors, configurable)
# is zstd-compressed to <name>.<ext>.zst (original removed from the zip), then
# the whole folder is zipped. unpack.sh (and spatialX's poller) auto-detect
# compressed files by their .zst extension and decompress them on the fly, so
# a plain zip and a compressed zip are interchangeable downstream.
#
# Usage:  ./pack.sh <folder> [options]
#
# Options:
#   --no-compress           Skip zstd; produce a plain zip (folder contents only).
#   -e, --extensions <list> Comma-separated extensions to compress.
#                           Default: pkl,pt,bin,safetensors
#                           Env override: PACK_EXTENSIONS=...
#   -l, --level <1..19>      zstd compression level (default: 3).
#   -o, --output <path>     Output zip path (default: ./<folder_basename>.zip).
#   -h, --help              Show this help.
#
# Examples:
#   ./pack.sh ./model_a                         # -> ./model_a.zip (zstd-compressed)
#   ./pack.sh ./model_a --no-compress           # -> ./model_a.zip (plain)
#   ./pack.sh ./model_a -e pkl,pt -l 9          # custom extensions + max level
#   ./pack.sh ./model_a -o /tmp/out.zip
#
# After packing, upload with:
#   ./upload.sh ./<basename>.zip ml-models main <tag>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

FOLDER=""
NO_COMPRESS=false
EXTENSIONS="${PACK_EXTENSIONS:-pkl,pt,bin,safetensors}"
LEVEL=3
OUTPUT=""

usage() {
  sed -n '4,/^# =\{20,\}=$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-compress) NO_COMPRESS=true; shift ;;
    -e|--extensions) EXTENSIONS="${2:-}"; shift 2 ;;
    --extensions=*) EXTENSIONS="${1#*=}"; shift ;;
    -l|--level) LEVEL="${2:-}"; shift 2 ;;
    --level=*) LEVEL="${1#*=}"; shift ;;
    -o|--output) OUTPUT="${2:-}"; shift 2 ;;
    --output=*) OUTPUT="${1#*=}"; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *)
      if [ -z "$FOLDER" ]; then
        FOLDER="$1"
      else
        echo "Unexpected argument: $1" >&2; usage 1
      fi
      shift
      ;;
  esac
done

if [ -z "$FOLDER" ]; then
  echo "Error: <folder> is required" >&2
  usage 1
fi

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# --- Validate input ---
if [ ! -d "$FOLDER" ]; then
  fail "Not a directory: $FOLDER"
fi

FOLDER_ABS="$(cd "$FOLDER" && pwd)"
BASENAME="$(basename "$FOLDER_ABS")"
OUTPUT="${OUTPUT:-$(pwd)/${BASENAME}.zip}"
OUTPUT_ABS="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

case "$OUTPUT_ABS" in
  *.zip) ;;
  *) warn "Output does not end in .zip; downstream scripts assume .zip"; ;;
esac

# --- Tool checks ---
if ! command -v zip >/dev/null 2>&1; then
  fail "'zip' is required (apt-get install zip)"
fi
if [ "$NO_COMPRESS" = false ] && ! command -v zstd >/dev/null 2>&1; then
  fail "'zstd' is required for compression (apt-get install zstd), or pass --no-compress"
fi

# Validate level
if ! [[ "$LEVEL" =~ ^-?[0-9]+$ ]]; then
  fail "Invalid zstd level: $LEVEL"
fi

# Build find -name args array from extension list (default pkl,pt,bin,safetensors).
# Emits an array like: -name '*.pkl' -o -name '*.pt' ...
FIND_NAMES=()
build_find_names() {
  local ext
  FIND_NAMES=()
  while IFS= read -r ext; do
    ext="${ext#.}"          # strip leading dot
    [ -z "$ext" ] && continue
    if [ ${#FIND_NAMES[@]} -gt 0 ]; then
      FIND_NAMES+=(-o)
    fi
    FIND_NAMES+=(-name "*.${ext}")
  done < <(printf '%s\n' "$EXTENSIONS" | tr ',' '\n')
}

info "Packing folder: $FOLDER_ABS"
info "Output:        $OUTPUT_ABS"
if [ "$NO_COMPRESS" = true ]; then
  info "Mode:          plain zip (no zstd)"
else
  info "Mode:          zstd (level $LEVEL) on extensions: $EXTENSIONS"
fi

# --- Stage a copy so the input folder is never modified ---
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

info "Staging to $STAGE ..."
cp -a "$FOLDER_ABS/." "$STAGE/"

COMPRESSED_COUNT=0
TOTAL_SIZE_BEFORE=0
TOTAL_SIZE_AFTER=0

if [ "$NO_COMPRESS" = false ]; then
  build_find_names
  if [ ${#FIND_NAMES[@]} -eq 0 ]; then
    warn "No extensions configured; falling back to plain zip"
  else
    info "Compressing matching files with zstd ..."
    while IFS= read -r -d '' f; do
      SIZE_BEFORE=$(stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null)
      if zstd -q "-$LEVEL" -f -o "${f}.zst" -- "$f"; then
        rm -f -- "$f"
        SIZE_AFTER=$(stat -c '%s' "${f}.zst" 2>/dev/null || stat -f '%z' "${f}.zst" 2>/dev/null)
        TOTAL_SIZE_BEFORE=$((TOTAL_SIZE_BEFORE + SIZE_BEFORE))
        TOTAL_SIZE_AFTER=$((TOTAL_SIZE_AFTER + SIZE_AFTER))
        COMPRESSED_COUNT=$((COMPRESSED_COUNT + 1))
        echo "  zstd: $(basename "$f")  ${SIZE_BEFORE}B -> ${SIZE_AFTER}B"
      else
        warn "zstd failed on: $f (leaving as-is)"
      fi
    done < <(find "$STAGE" -type f \( "${FIND_NAMES[@]}" \) -print0)
  fi
fi

if [ "$NO_COMPRESS" = false ] && [ "$COMPRESSED_COUNT" -eq 0 ] && [ ${#FIND_NAMES[@]} -gt 0 ]; then
  warn "No files matched extensions [$EXTENSIONS] — zip will be plain"
fi

# --- Zip the staged folder contents at root (so unzip -d <dest>/ yields <dest>/<contents>) ---
# Start from a clean archive: `zip -r` appends to/merges with an existing zip,
# which would mix stale entries from a previous run into the new one.
rm -f "$OUTPUT_ABS"
info "Creating zip ..."
(
  cd "$STAGE"
  zip -r -q "$OUTPUT_ABS" .
)

ZIP_SIZE=$(stat -c '%s' "$OUTPUT_ABS" 2>/dev/null || stat -f '%z' "$OUTPUT_ABS" 2>/dev/null)
ZIP_SIZE_H=$(du -h "$OUTPUT_ABS" | cut -f1)

echo ""
ok "=== Pack complete ==="
echo "  Folder:          $FOLDER_ABS"
echo "  Output:          $OUTPUT_ABS ($ZIP_SIZE_H)"
if [ "$COMPRESSED_COUNT" -gt 0 ]; then
  echo "  Files compressed: $COMPRESSED_COUNT"
  if [ "$TOTAL_SIZE_BEFORE" -gt 0 ]; then
    RATIO=$(awk "BEGIN{ printf \"%.2f\", ($TOTAL_SIZE_AFTER/$TOTAL_SIZE_BEFORE) }")
    echo "  Weights size:    ${TOTAL_SIZE_BEFORE}B -> ${TOTAL_SIZE_AFTER}B (${RATIO}x)"
  fi
fi
echo ""
echo "  Next: $SCRIPT_DIR/upload.sh \"$OUTPUT_ABS\" ml-models main <tag>"
echo ""
