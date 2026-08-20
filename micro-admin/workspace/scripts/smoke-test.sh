#!/bin/bash
set -e

BFF_URL="http://localhost:8888"

echo "==> Smoke test: Happy path"

# 1. Login
echo "  [1/4] Login..."
LOGIN_RESP=$(curl -s -X POST $BFF_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}')

TOKEN=$(echo $LOGIN_RESP | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "FAIL: login failed"
    echo "Response: $LOGIN_RESP"
    exit 1
fi
echo "  ✓ Login successful"

# 2. Get current user menus
echo "  [2/4] Get current user menus..."
MENUS=$(curl -s -H "Authorization: Bearer $TOKEN" $BFF_URL/api/v1/me/menus)
if [ -z "$MENUS" ] || [ "$MENUS" = "null" ]; then
    echo "FAIL: get menus failed"
    exit 1
fi
echo "  ✓ Menus retrieved"

# 3. RBAC management (create user)
echo "  [3/4] Create user..."
CREATE_USER=$(curl -s -X POST $BFF_URL/api/v1/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","email":"test@example.com"}')
if [ -z "$CREATE_USER" ] || echo "$CREATE_USER" | grep -q "error"; then
    echo "FAIL: create user failed"
    echo "Response: $CREATE_USER"
    exit 1
fi
echo "  ✓ User created"

# 4. Rate-limit rule management
echo "  [4/4] Create rate-limit rule..."
CREATE_RULE=$(curl -s -X POST $BFF_URL/api/v1/rate-limit-rules \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"api-limit","limit":100,"window":"1m"}')
if [ -z "$CREATE_RULE" ] || echo "$CREATE_RULE" | grep -q "error"; then
    echo "FAIL: create rate-limit rule failed"
    echo "Response: $CREATE_RULE"
    exit 1
fi
echo "  ✓ Rate-limit rule created"

echo ""
echo "==> Smoke test: PASSED"
