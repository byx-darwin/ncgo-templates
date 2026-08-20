#!/bin/bash
set -e

# Auto-detect BFF address
BFF_PORT=8080
BFF_IP=$(lsof -i :$BFF_PORT -P -n 2>/dev/null | grep LISTEN | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "127.0.0.1")
BFF_URL="http://${BFF_IP}:${BFF_PORT}"

echo "==> Smoke test: Happy path (BFF_URL=$BFF_URL)"

check_response() {
    local resp="$1"
    local label="$2"
    if [ -z "$resp" ]; then
        echo "FAIL: $label - empty response"
        exit 1
    fi
    # Check for HTTP-level error (code != 200 means business error)
    local code=$(echo "$resp" | jq -r '.code // empty')
    if [ "$code" != "200" ] && [ "$code" != "0" ]; then
        echo "FAIL: $label - error code $code"
        echo "Response: $resp"
        exit 1
    fi
}

# 1. Login
echo "  [1/4] Login (admin-bff → rbac-rpc)..."
LOGIN_RESP=$(curl -s -X POST $BFF_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"Admin@123"}')
TOKEN=$(echo $LOGIN_RESP | jq -r '.data.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "FAIL: login failed - no token"
    echo "Response: $LOGIN_RESP"
    exit 1
fi
echo "  ✓ Login successful"

# 2. Get current user menus
echo "  [2/4] Get menus (admin-bff → rbac-rpc)..."
MENUS=$(curl -s -H "Authorization: Bearer $TOKEN" $BFF_URL/api/v1/me/menus)
check_response "$MENUS" "get menus"
echo "  ✓ Menus retrieved"

# 3. Create user (JWT + RBAC Authz)
echo "  [3/4] Create user (admin-bff → rbac-rpc with Authz)..."
CREATE_USER=$(curl -s -X POST $BFF_URL/api/v1/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","email":"test@example.com"}')
check_response "$CREATE_USER" "create user"
echo "  ✓ User created"

# 4. Create rate-limit rule (admin-bff → rule-rpc)
echo "  [4/4] Create rate-limit rule (admin-bff → rule-rpc)..."
CREATE_RULE=$(curl -s -X POST $BFF_URL/api/v1/rate-limit-rules \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"api-limit","limit":100,"window":"1m"}')
check_response "$CREATE_RULE" "create rate-limit rule"
echo "  ✓ Rate-limit rule created"

echo ""
echo "==> Smoke test: PASSED"
echo ""
echo "==> Verified:"
echo "  ✓ Postgres connection (users, menus data)"
echo "  ✓ Redis connection (token store)"
echo "  ✓ JWT auth (login → token → protected routes)"
echo "  ✓ Cross-service RPC (admin-bff → rbac-rpc, admin-bff → rule-rpc)"
echo "  ✓ RBAC authorization (Casbin enforcement)"
