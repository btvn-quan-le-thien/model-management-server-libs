#!/bin/bash
set -euo pipefail

# =============================================================================
# upload.sh — Upload a file or folder to lakeFS, commit, and tag
#
# Usage:  ./upload.sh <file_or_folder> <repo> <branch> <version_tag>
#
# Examples:
#   ./upload.sh ./model.zip ml-models main v1.0.0        # single file
#   ./upload.sh ./model_a/ ml-models main v1.0.0        # folder (recursive)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAKECTL="$SCRIPT_DIR/lakectl.sh"

if [ $# -lt 4 ]; then
  echo "Usage: $0 <file_or_folder> <repo> <branch> <version_tag>"
  echo ""
  echo "Examples:"
  echo "  $0 ./model.zip ml-models main v1.0.0      # single file"
  echo "  $0 ./model_a/ ml-models main v1.0.0        # folder (recursive)"
  exit 1
fi

SOURCE="$1"
REPO="$2"
BRANCH="$3"
TAG="$4"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

if [ ! -e "$SOURCE" ]; then
  fail "Path not found: $SOURCE"
fi

BASENAME="$(basename "$SOURCE")"
# Resolve to absolute path (lakectl recursive upload needs absolute --source)
SOURCE_ABS="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"

# --- Upload (auto-detect file vs folder) ---
info "Uploading $BASENAME → lakefs://$REPO/$BRANCH/$BASENAME ..."
if [ -d "$SOURCE_ABS" ]; then
  "$LAKECTL" fs upload "lakefs://$REPO/$BRANCH/$BASENAME/" \
    --source "$SOURCE_ABS" --recursive
else
  "$LAKECTL" fs upload "lakefs://$REPO/$BRANCH/$BASENAME" \
    --source "$SOURCE_ABS"
fi
ok "Upload complete"

# --- Commit ---
info "Committing..."
"$LAKECTL" commit "lakefs://$REPO/$BRANCH" \
  --message "Upload $BASENAME $TAG" \
  --meta version="$TAG"
ok "Committed"

# --- Tag ---
info "Creating tag $TAG..."
"$LAKECTL" tag create "lakefs://$REPO/$TAG" "lakefs://$REPO/$BRANCH" 2>/dev/null && ok "Tagged: $TAG" || {
  echo -e "\033[1;33m[WARN]\033[0m Tag $TAG already exists, skipping"
}

echo ""
ok "=== Upload complete ==="
echo ""
echo "  Path:     $BASENAME"
echo "  Repo:     $REPO"
echo "  Branch:   $BRANCH"
echo "  Tag:      $TAG"
echo ""
echo "  Download: $SCRIPT_DIR/download.sh $REPO $TAG $BASENAME"
echo ""
