#!/usr/bin/env bash
set -euo pipefail

BFF_URL=${BFF_URL:-http://127.0.0.1:8080}
for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

request() {
  local method=$1 path=$2 payload=${3:-}
  local args=(-fsS -X "$method" "$BFF_URL$path")
  if [ -n "${TOKEN:-}" ]; then args+=(-H "Authorization: Bearer $TOKEN"); fi
  if [ -n "$payload" ]; then args+=(-H 'Content-Type: application/json' -d "$payload"); fi
  local result
  result=$(curl "${args[@]}") || { echo "HTTP request failed: $method $path" >&2; exit 1; }
  if ! jq -e '(.code == 0 or .code == 200)' >/dev/null <<<"$result"; then
    echo "Unexpected response for $method $path: $result" >&2
    exit 1
  fi
  printf '%s\n' "$result"
}

echo '==> Checking login, menus, permissions, and resource lists'
login=$(request POST /api/v1/auth/login '{"username":"admin","password":"Admin@123"}')
TOKEN=$(jq -r '.data.access_token // empty' <<<"$login")
test -n "$TOKEN" || { echo 'Login returned no access token' >&2; exit 1; }
menus=$(request GET /api/v1/me/menus)
jq -e '.data | arrays | length > 0' >/dev/null <<<"$menus"
jq -e '.data | .. | objects | select(.path? == "/system/user")' >/dev/null <<<"$menus"
perms=$(request GET /api/v1/me/perms)
jq -e '.data | arrays | length > 0' >/dev/null <<<"$perms"
for resource in users roles permissions; do
  result=$(request GET "/api/v1/$resource?page=1&page_size=20")
  jq -e '.data | arrays | length > 0' >/dev/null <<<"$result"
done

echo '==> Checking user, role, permission, and rate rule writes'
suffix="$$"
user=$(request POST /api/v1/users "{\"username\":\"smoke_$suffix\",\"password\":\"Test@12345\",\"email\":\"smoke_$suffix@example.com\"}")
user_id=$(jq -r '.data.id // .data.user.id // empty' <<<"$user")
test -n "$user_id" || { echo "User response has no ID: $user" >&2; exit 1; }
request PUT "/api/v1/users/$user_id" '{"nickname":"Smoke Updated"}' >/dev/null

role=$(request POST /api/v1/roles "{\"code\":\"smoke_$suffix\",\"name\":\"Smoke Role\"}")
role_id=$(jq -r '.data.id // .data.role.id // empty' <<<"$role")
test -n "$role_id" || { echo "Role response has no ID: $role" >&2; exit 1; }
request PUT "/api/v1/roles/$role_id" '{"name":"Smoke Role Updated"}' >/dev/null

permission=$(request POST /api/v1/permissions "{\"code\":\"smoke:$suffix\",\"type\":\"button\",\"name\":\"Smoke Permission\"}")
permission_id=$(jq -r '.data.id // .data.permission.id // empty' <<<"$permission")
test -n "$permission_id" || { echo "Permission response has no ID: $permission" >&2; exit 1; }
request PUT "/api/v1/permissions/$permission_id" '{"name":"Smoke Permission Updated"}' >/dev/null

rule=$(request POST /api/v1/rate-limit-rules "{\"service\":\"admin\",\"phase\":\"pre_auth\",\"method\":\"GET\",\"path\":\"/api/v1/smoke-$suffix\",\"match_kind\":\"exact\",\"path_pattern\":\"/api/v1/smoke-$suffix\",\"config\":{\"enabled\":true,\"key_by\":[\"ip\"],\"strategy\":\"fixed_window\",\"window_seconds\":60,\"max_requests\":100}}")
rule_id=$(jq -r '.data.id // empty' <<<"$rule")
test -n "$rule_id" || { echo "Create rule response has no ID: $rule" >&2; exit 1; }
rules=$(request GET /api/v1/rate-limit-rules)
jq -e --argjson id "$rule_id" '.data[] | select(.id == $id)' >/dev/null <<<"$rules"

request DELETE "/api/v1/rate-limit-rules/$rule_id" >/dev/null
request DELETE "/api/v1/permissions/$permission_id" >/dev/null
request DELETE "/api/v1/roles/$role_id" >/dev/null
request DELETE "/api/v1/users/$user_id" >/dev/null

echo '==> Checking logout revocation'
request POST /api/v1/auth/logout '{}' >/dev/null
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BFF_URL/api/v1/me/perms")
test "$status" = 401 || { echo "Revoked token returned HTTP $status" >&2; exit 1; }
echo '==> Smoke test passed'
