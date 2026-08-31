#!/bin/bash
set -euo pipefail

# =============================================================================
# dev-setup.sh — Install lakectl + configure for local lakeFS server
# Run this once on your machine to set up access to lakeFS.
# Prerequisite: ./scripts/setup.sh must have been run on the server first
# (produces config.env with the user-provided lakeFS creds + endpoints).
# =============================================================================

LAKEFS_VERSION="1.83.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
BIN_DIR="$SCRIPT_DIR/bin"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# --- Load config (endpoints + credentials) ---
if [ ! -f "$CONFIG_FILE" ]; then
  fail "Credentials file not found: $CONFIG_FILE
Create config.env with LAKEFS_ENDPOINT, ACCESS_KEY_ID, SECRET_ACCESS_KEY (see README Quick Start)."
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Apply localhost defaults for any endpoint left unset in config.env.
LAKEFS_ENDPOINT="${LAKEFS_ENDPOINT:-http://localhost:8088}"
SEAWEED_S3_ENDPOINT="${SEAWEED_S3_ENDPOINT:-http://localhost:9002}"
AUTH_ENDPOINT="${AUTH_ENDPOINT:-http://localhost:8090}"

# --- Detect OS/arch ---
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="x86_64" ;;
  aarch64) ARCH="arm64" ;;
  arm64)   ARCH="arm64" ;;
  *)       fail "Unsupported architecture: $ARCH" ;;
esac
case "$OS" in
  darwin) OS="Darwin" ;;
  linux)  OS="Linux" ;;
  *)      fail "Unsupported OS: $OS" ;;
esac

# --- Download lakectl ---
mkdir -p "$BIN_DIR"
if [ ! -f "$BIN_DIR/lakectl" ]; then
  URL="https://github.com/treeverse/lakeFS/releases/download/v${LAKEFS_VERSION}/lakeFS_${LAKEFS_VERSION}_${OS}_${ARCH}.tar.gz"
  info "Downloading lakectl v${LAKEFS_VERSION} (${OS}/${ARCH})..."
  curl -sL "$URL" | tar xz -C "$BIN_DIR" lakectl
  chmod +x "$BIN_DIR/lakectl"
  ok "lakectl installed at $BIN_DIR/lakectl"
else
  info "lakectl already installed at $BIN_DIR/lakectl"
fi

# --- Configure lakectl ---
LAKECTL_CONFIG="$HOME/.lakectl.yaml"
cat > "$LAKECTL_CONFIG" <<YAML
server:
  endpoint_url: ${LAKEFS_ENDPOINT}
credentials:
  access_key_id: "${ACCESS_KEY_ID}"
  secret_access_key: "${SECRET_ACCESS_KEY}"
YAML
ok "lakectl configured at $LAKECTL_CONFIG"

# --- Verify connectivity ---
info "Verifying connectivity to lakeFS..."
if "$BIN_DIR/lakectl" repo list >/dev/null 2>&1; then
  ok "Connected to lakeFS at ${LAKEFS_ENDPOINT}"
else
  fail "Cannot connect to lakeFS at ${LAKEFS_ENDPOINT}. Is the server running? Run ./scripts/setup.sh first."
fi

info "Verifying auth server..."
if curl -sf "${AUTH_ENDPOINT}/health" >/dev/null 2>&1; then
  ok "Auth server reachable at ${AUTH_ENDPOINT}"
else
  warn "Auth server not reachable at ${AUTH_ENDPOINT} (downloads via API key won't work)"
fi

# --- Done ---
echo ""
ok "=== Dev setup complete ==="
echo ""
echo "  lakectl:        $BIN_DIR/lakectl"
echo "  config:         $LAKECTL_CONFIG"
echo "  lakeFS URL:     ${LAKEFS_ENDPOINT}"
echo "  Auth Server:    ${AUTH_ENDPOINT}"
echo "  SeaweedFS S3:   ${SEAWEED_S3_ENDPOINT}"
echo ""
echo "  Quick test:     $SCRIPT_DIR/lakectl.sh repo list"
echo "  Upload file:    $SCRIPT_DIR/upload.sh ./model.zip ml-models main v1.0.0"
echo "  Upload folder:  $SCRIPT_DIR/upload.sh ./model_a/ ml-models main v1.0.0"
echo "  Download:       $SCRIPT_DIR/download.sh ml-models v1.0.0 model_a/"
echo ""
