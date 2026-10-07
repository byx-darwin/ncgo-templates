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
jq -e '[.data | .. | objects | select(has("children")) | .code] | all(. != null and . != "")' >/dev/null <<<"$menus"
request GET /api/v1/permissions/tree >/dev/null
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

echo '==> Checking role grants, menu codes, super roles, and revocation'
admin_token=$TOKEN
request POST "/api/v1/roles/$role_id/permissions" '{"permission_codes":["system:view","system:user","user:read"]}' >/dev/null
request POST "/api/v1/users/$user_id/roles" "{\"role_ids\":[\"$role_id\"]}" >/dev/null
TOKEN=''
limited_login=$(request POST /api/v1/auth/login "{\"username\":\"smoke_$suffix\",\"password\":\"Test@12345\"}")
limited_token=$(jq -r '.data.access_token // empty' <<<"$limited_login")
test -n "$limited_token"
TOKEN=$limited_token
request GET /api/v1/users >/dev/null
limited_menus=$(request GET /api/v1/me/menus)
jq -e '.data | .. | objects | select(.code? == "system:user")' >/dev/null <<<"$limited_menus"
status=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' "$BFF_URL/api/v1/users")
test "$status" = 403 || { echo "Restricted write returned HTTP $status" >&2; exit 1; }
TOKEN=$admin_token
request POST "/api/v1/roles/$role_id/permissions" '{"permission_codes":["*"]}' >/dev/null
TOKEN=$limited_token
request GET /api/v1/roles >/dev/null
super_perms=$(request GET /api/v1/me/perms)
jq -e --arg code "smoke:$suffix" '.data | index($code) != null' >/dev/null <<<"$super_perms"
TOKEN=$admin_token
request POST "/api/v1/roles/$role_id/permissions" '{"permission_codes":[]}' >/dev/null
TOKEN=$limited_token
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BFF_URL/api/v1/users")
test "$status" = 403 || { echo "Revoked grant returned HTTP $status" >&2; exit 1; }
TOKEN=$admin_token

request DELETE "/api/v1/rate-limit-rules/$rule_id" >/dev/null
request DELETE "/api/v1/permissions/$permission_id" >/dev/null
request DELETE "/api/v1/roles/$role_id" >/dev/null
request DELETE "/api/v1/users/$user_id" >/dev/null

echo '==> Checking logout revocation'
request POST /api/v1/auth/logout '{}' >/dev/null
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$BFF_URL/api/v1/me/perms")
test "$status" = 401 || { echo "Revoked token returned HTTP $status" >&2; exit 1; }
echo '==> Smoke test passed'
