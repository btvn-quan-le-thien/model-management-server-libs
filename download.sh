#!/bin/bash
set -euo pipefail

# =============================================================================
# download.sh — Download a file or folder from lakeFS via lakectl
#
# Usage:  ./download.sh <repo> <ref> <path> [output_path] [--unzip]
#
# Examples:
#   ./download.sh ml-models v1.0.0 model.zip                 # single file
#   ./download.sh ml-models v1.0.0 model_a/                  # folder (recursive)
#   ./download.sh ml-models v1.0.0 model.zip ./out.zip       # custom output
#   ./download.sh ml-models v1.0.0 model.zip --unzip        # download + unzip
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAKECTL="$SCRIPT_DIR/lakectl.sh"

UNZIP=false
OUTPUT=""
ARGS=()

for arg in "$@"; do
  case "$arg" in
    --unzip) UNZIP=true ;;
    *)       ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]}"

if [ $# -lt 3 ]; then
  echo "Usage: $0 <repo> <ref> <path> [output_path] [--unzip]"
  echo ""
  echo "Examples:"
  echo "  $0 ml-models v1.0.0 model.zip"
  echo "  $0 ml-models v1.0.0 model_a/"
  echo "  $0 ml-models v1.0.0 model.zip ./downloaded.zip"
  echo "  $0 ml-models v1.0.0 model.zip --unzip"
  exit 1
fi

REPO="$1"
REF="$2"
LAKCTL_PATH="$3"
OUTPUT="${4:-$(basename "$LAKCTL_PATH")}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

info "Downloading lakefs://$REPO/$REF/$LAKCTL_PATH ..."

# Auto-detect folder (trailing /) vs file
if [[ "$LAKCTL_PATH" == */ ]]; then
  # Folder download (recursive)
  "$LAKECTL" fs download "lakefs://$REPO/$REF/$LAKCTL_PATH" "$OUTPUT" --recursive 2>/dev/null || \
    fail "Download failed. Check repo, ref, and path."
  ok "Downloaded folder: $OUTPUT/"
  FILE_COUNT=$(find "$OUTPUT" -type f | wc -l)
  echo "  Files: $FILE_COUNT"
else
  # Single file download
  "$LAKECTL" fs download "lakefs://$REPO/$REF/$LAKCTL_PATH" "$OUTPUT" 2>/dev/null || \
    fail "Download failed. Check repo, ref, and path."
  SIZE=$(du -h "$OUTPUT" | cut -f1)
  ok "Downloaded: $OUTPUT ($SIZE)"
fi

if [ "$UNZIP" = true ]; then
  EXTRACT_DIR="${OUTPUT%.zip}"
  info "Unzipping to $EXTRACT_DIR/ ..."
  mkdir -p "$EXTRACT_DIR"
  unzip -o "$OUTPUT" -d "$EXTRACT_DIR" >/dev/null
  ok "Extracted to $EXTRACT_DIR/"
  ls -la "$EXTRACT_DIR/"
fi
