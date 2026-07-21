#!/bin/bash
set -euo pipefail

# =============================================================================
# dev-setup.sh — Install lakectl + configure for local lakeFS server
# Run this once on your machine to set up access to lakeFS.
# Prerequisite: ./scripts/setup.sh must have been run on the server first
# (produces .lakectl-credentials.env with the user-provided lakeFS creds).
# =============================================================================

LAKEFS_VERSION="1.83.0"
LAKEFS_PORT="8088"
AUTH_PORT="8090"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDENTIALS_FILE="$SCRIPT_DIR/.lakectl-credentials.env"
BIN_DIR="$SCRIPT_DIR/bin"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; exit 1; }

# --- Check for credentials --- 
if [ ! -f "$CREDENTIALS_FILE" ]; then
  fail "Credentials file not found: $CREDENTIALS_FILE
Run ./scripts/setup.sh on the server first (export the 5 env vars — see README Quick Start)."
fi
source "$CREDENTIALS_FILE"

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
  endpoint_url: http://localhost:${LAKEFS_PORT}
credentials:
  access_key_id: "${ACCESS_KEY_ID}"
  secret_access_key: "${SECRET_ACCESS_KEY}"
YAML
ok "lakectl configured at $LAKECTL_CONFIG"

# --- Verify connectivity ---
info "Verifying connectivity to lakeFS..."
if "$BIN_DIR/lakectl" repo list >/dev/null 2>&1; then
  ok "Connected to lakeFS at http://localhost:${LAKEFS_PORT}"
else
  fail "Cannot connect to lakeFS. Is the server running? Run ./scripts/setup.sh first."
fi

info "Verifying auth server..."
if curl -sf "http://localhost:${AUTH_PORT}/health" >/dev/null 2>&1; then
  ok "Auth server reachable at http://localhost:${AUTH_PORT}"
else
  warn "Auth server not reachable at http://localhost:${AUTH_PORT} (downloads via API key won't work)"
fi

# --- Done ---
echo ""
ok "=== Dev setup complete ==="
echo ""
echo "  lakectl:        $BIN_DIR/lakectl"
echo "  config:         $LAKECTL_CONFIG"
echo "  lakeFS URL:     http://localhost:${LAKEFS_PORT}"
echo "  Auth Server:    http://localhost:${AUTH_PORT}"
echo "  SeaweedFS S3:   http://localhost:9002"
echo ""
echo "  Quick test:     $SCRIPT_DIR/lakectl.sh repo list"
echo "  Upload file:    $SCRIPT_DIR/upload.sh ./model.zip ml-models main v1.0.0"
echo "  Upload folder:  $SCRIPT_DIR/upload.sh ./model_a/ ml-models main v1.0.0"
echo "  Download:       $SCRIPT_DIR/download.sh ml-models v1.0.0 model_a/"
echo ""
