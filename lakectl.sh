#!/bin/bash
set -euo pipefail

# =============================================================================
# lakectl.sh — Run lakectl against local lakeFS server
# Uses the lakectl binary installed by dev-setup.sh (not docker exec).
# Automatically injects --pre-sign=false for fs upload/download.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAKECTL="$SCRIPT_DIR/bin/lakectl"

if [ ! -f "$LAKECTL" ]; then
  echo "Error: lakectl not found at $LAKECTL" >&2
  echo "Run $SCRIPT_DIR/dev-setup.sh first." >&2
  exit 1
fi

# Inject --pre-sign=false for fs upload/download commands so data goes through
# lakeFS (not via presigned SeaweedFS URLs which require special network access)
case "${1:-}" in
  fs)
    case "${2:-}" in
      upload|download)
        "$LAKECTL" "$@" --pre-sign=false
        exit $?
        ;;
    esac
    ;;
esac

"$LAKECTL" "$@"
