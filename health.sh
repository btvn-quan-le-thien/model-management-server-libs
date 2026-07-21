#!/bin/bash
set -euo pipefail

# =============================================================================
# health.sh — Check health of lakeFS + SeaweedFS + Auth Server
# =============================================================================

LAKEFS_PORT="8088"
SEAWEED_S3_PORT="9002"
AUTH_PORT="8090"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; }

echo "=== Service Health ==="
echo ""

# lakeFS
if curl -sf "http://localhost:${LAKEFS_PORT}/_health" >/dev/null 2>&1; then
  ok "lakeFS          http://localhost:${LAKEFS_PORT}  alive"
else
  fail "lakeFS          http://localhost:${LAKEFS_PORT}  DOWN"
fi

# lakeFS API
API_STATUS=$(curl -sf -o /dev/null -w '%{http_code}' "http://localhost:${LAKEFS_PORT}/api/v1/healthcheck" 2>/dev/null || echo "fail")
if [ "$API_STATUS" = "204" ]; then
  ok "lakeFS API       http://localhost:${LAKEFS_PORT}/api/v1   204"
else
  fail "lakeFS API       http://localhost:${LAKEFS_PORT}/api/v1   DOWN ($API_STATUS)"
fi

# SeaweedFS S3
S3_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${SEAWEED_S3_PORT}/" 2>/dev/null || echo "000")
if [ "$S3_STATUS" = "200" ] || [ "$S3_STATUS" = "403" ] || [ "$S3_STATUS" = "400" ]; then
  ok "SeaweedFS S3    http://localhost:${SEAWEED_S3_PORT}      alive (HTTP $S3_STATUS)"
else
  fail "SeaweedFS S3    http://localhost:${SEAWEED_S3_PORT}      DOWN (HTTP $S3_STATUS)"
fi

# Auth Server
if curl -sf "http://localhost:${AUTH_PORT}/health" >/dev/null 2>&1; then
  ok "Auth Server     http://localhost:${AUTH_PORT}      alive"
else
  fail "Auth Server     http://localhost:${AUTH_PORT}      DOWN"
fi

echo ""
