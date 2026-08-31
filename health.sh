#!/bin/bash
set -euo pipefail

# =============================================================================
# health.sh — Check health of lakeFS + SeaweedFS + Auth Server
# Reads endpoints from config.env (localhost defaults if unset/absent).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

LAKEFS_ENDPOINT="${LAKEFS_ENDPOINT:-http://localhost:8088}"
SEAWEED_S3_ENDPOINT="${SEAWEED_S3_ENDPOINT:-http://localhost:9002}"
AUTH_ENDPOINT="${AUTH_ENDPOINT:-http://localhost:8090}"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; }

echo "=== Service Health ==="
echo ""

# lakeFS
if curl -sf "${LAKEFS_ENDPOINT}/_health" >/dev/null 2>&1; then
  ok "lakeFS          ${LAKEFS_ENDPOINT}  alive"
else
  fail "lakeFS          ${LAKEFS_ENDPOINT}  DOWN"
fi

# lakeFS API
API_STATUS=$(curl -sf -o /dev/null -w '%{http_code}' "${LAKEFS_ENDPOINT}/api/v1/healthcheck" 2>/dev/null || echo "fail")
if [ "$API_STATUS" = "204" ]; then
  ok "lakeFS API       ${LAKEFS_ENDPOINT}/api/v1   204"
else
  fail "lakeFS API       ${LAKEFS_ENDPOINT}/api/v1   DOWN ($API_STATUS)"
fi

# SeaweedFS S3
S3_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${SEAWEED_S3_ENDPOINT}/" 2>/dev/null || echo "000")
if [ "$S3_STATUS" = "200" ] || [ "$S3_STATUS" = "403" ] || [ "$S3_STATUS" = "400" ]; then
  ok "SeaweedFS S3    ${SEAWEED_S3_ENDPOINT}      alive (HTTP $S3_STATUS)"
else
  fail "SeaweedFS S3    ${SEAWEED_S3_ENDPOINT}      DOWN (HTTP $S3_STATUS)"
fi

# Auth Server
if curl -sf "${AUTH_ENDPOINT}/health" >/dev/null 2>&1; then
  ok "Auth Server     ${AUTH_ENDPOINT}      alive"
else
  fail "Auth Server     ${AUTH_ENDPOINT}      DOWN"
fi

echo ""
