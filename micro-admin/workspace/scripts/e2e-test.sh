#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
export COMPOSE_PROJECT_NAME="micro_admin_test_$$"
DATABASE_URL='postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable'
AUTHORITY_PID=''
ADMIN_PID=''

cleanup() {
  if [ -n "$ADMIN_PID" ]; then kill "$ADMIN_PID" 2>/dev/null || true; fi
  if [ -n "$AUTHORITY_PID" ]; then kill "$AUTHORITY_PID" 2>/dev/null || true; fi
  if [ -n "$ADMIN_PID" ]; then wait "$ADMIN_PID" 2>/dev/null || true; fi
  if [ -n "$AUTHORITY_PID" ]; then wait "$AUTHORITY_PID" 2>/dev/null || true; fi
  docker compose -f compose.infra.yaml down -v >/dev/null 2>&1 || true
  rm -f .authority-test .admin-test
}
trap cleanup EXIT

for tool in docker curl jq goose; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

./scripts/prepare.sh
# Enable the machine boundary only in this disposable E2E workspace.
export AGENT_TOKEN="e2e-agent-token"
python3 - <<'PYCONFIG'
from pathlib import Path
p=Path('services/admin/conf/dev/conf.yaml')
s=p.read_text().replace('alerts_enabled: false','alerts_enabled: true').replace('agent:\n  enabled: false','agent:\n  enabled: true').replace('  uid: ""','  uid: "00000000-0000-7000-8000-000000000003"').replace('  allowed_cidrs: []','  allowed_cidrs: ["127.0.0.1/32", "::1/128"]').replace('  revalidate_seconds: 300','  revalidate_seconds: 1')
p.write_text(s)
p=Path('services/authority/conf/dev/conf.yaml');p.write_text(p.read_text().replace('alerts_enabled: false','alerts_enabled: true'))
PYCONFIG

echo '==> Building and testing authority'
(cd services/authority && go build -o "$ROOT/.authority-test" . && go test ./...)
echo '==> Building and testing BFF'
(cd services/admin && go build -o "$ROOT/.admin-test" . && go test ./...)

echo '==> Starting fresh PostgreSQL and Redis containers'
docker compose -f compose.infra.yaml up -d
ready=0
for _ in $(seq 1 30); do
  if docker compose -f compose.infra.yaml exec -T postgres pg_isready -U postgres -d micro_admin >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
test "$ready" -eq 1 || { echo 'PostgreSQL did not become ready' >&2; exit 1; }

echo '==> Migrating and seeding authority database'
(cd services/authority && DATABASE_URL="$DATABASE_URL" make migrate-up)
cat scripts/seed-permissions.sql scripts/seed.sql | docker compose -f compose.infra.yaml exec -T postgres \
  psql -U postgres -d micro_admin -v ON_ERROR_STOP=1

echo '==> Starting authority and BFF'
(cd services/authority && exec env GO_ENV=dev "$ROOT/.authority-test") > "$ROOT/authority-e2e.log" 2>&1 &
AUTHORITY_PID=$!
(cd services/admin && exec env GO_ENV=dev "$ROOT/.admin-test") > "$ROOT/admin-e2e.log" 2>&1 &
ADMIN_PID=$!
ready=0
for _ in $(seq 1 30); do
  if ! kill -0 "$AUTHORITY_PID" 2>/dev/null || ! kill -0 "$ADMIN_PID" 2>/dev/null; then
    cat admin-e2e.log authority-e2e.log >&2
    exit 1
  fi
  if curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
test "$ready" -eq 1 || { cat admin-e2e.log authority-e2e.log >&2; exit 1; }

echo '==> Running HTTP smoke test'
BFF_URL=http://127.0.0.1:8080 ./scripts/smoke-test.sh
echo '==> Running machine WebSocket, durable RPC events and error integration tests'
(cd services/admin && AGENT_E2E_URL=http://127.0.0.1:8080 AGENT_E2E_DSN="$DATABASE_URL" go test ./internal/pkg/agentstream -run TestAgentEndToEnd -count=1 -v)
echo '==> Full backend E2E passed'
