#!/usr/bin/env bash
# Render all account participants and run generated code, never live providers.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for tool in ncgo kitex sqlc go; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
TASK_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_DIR"' EXIT
for spec in 'user:kitex:user-kitex' 'app:hertz:user-bff-hertz' 'admin:hertz:admin-bff-hertz'; do
  IFS=: read -r service kind package <<< "$spec"
  ncgo new "$service" --module "example.com/accounts/$service" --kind "$kind" \
    --template-dir "$ROOT/$package" --dir "$TASK_DIR/$service" --no-auto-steps
  (
    cd "$TASK_DIR/$service"
    if [ "$kind" = kitex ] || [ "$service" = admin ]; then make sqlc; fi
    if [ "$kind" = hertz ]; then
      for proto in user rule_center auth rbac; do
        if [ -f "idl/$proto.proto" ]; then
          kitex -module "example.com/accounts/$service" -type protobuf -I idl "idl/$proto.proto"
        fi
      done
      if [ -d tools/i18n/gen ]; then go run ./tools/i18n/gen; fi
    fi
    go mod tidy
    go build ./...
    go vet ./...
    go test ./... -count=1
    if [ "$service" = user ] && [ -n "${ACCOUNT_TEST_DSN:-}" ]; then
      go test -race ./internal/application/account ./internal/application/accountconfig ./internal/handler -count=1
    fi
    if [ "$service" = admin ]; then
      go run ./cmd/permgen > "$TASK_DIR/seed-permissions.sql"
      cmp "$TASK_DIR/seed-permissions.sql" "$ROOT/micro-admin/workspace/scripts/seed-permissions.sql"
    fi
  )
done
bash "$ROOT/scripts/check-duplicate-template-paths.sh" \
  "$ROOT/user-kitex/kitex-template" "$ROOT/user-bff-hertz/hertz-template" "$ROOT/admin-bff-hertz/hertz-template"
echo 'Application accounts: generation, build, vet, tests, race checks and seed consistency passed'
