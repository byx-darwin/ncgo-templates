#!/usr/bin/env bash
# Render both composition packages and verify their RBAC contract without services.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for tool in ncgo kitex sqlc go; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
TASK_DIR=$(mktemp -d)
trap 'rm -rf "$TASK_DIR"' EXIT
for spec in 'authority:kitex:admin-services-kitex' 'admin:hertz:admin-bff-hertz'; do
  IFS=: read -r service kind package <<< "$spec"
  ncgo new "$service" --module "example.com/micro-admin/$service" --kind "$kind" \
    --template-dir "$ROOT/$package" --dir "$TASK_DIR/$service" --no-auto-steps
  (
    cd "$TASK_DIR/$service"
    make sqlc
    if [ "$service" = admin ]; then
      for proto in auth rbac rule_center user z_agent_event; do
        kitex -module example.com/micro-admin/admin -type protobuf -I idl "idl/$proto.proto"
      done
      make i18n
    fi
    go mod tidy
    go build ./...
    go vet ./...
    go test ./... -count=1
    if [ "$service" = admin ]; then
      go run ./cmd/permgen > "$TASK_DIR/seed-permissions.sql"
      cmp "$TASK_DIR/seed-permissions.sql" "$ROOT/micro-admin/workspace/scripts/seed-permissions.sql"
    fi
  )
done
bash "$ROOT/scripts/check-duplicate-template-paths.sh" \
  "$ROOT/admin-bff-hertz/hertz-template" "$ROOT/admin-services-kitex/kitex-template"
echo 'micro-admin permission generation, build, tests, and seed consistency passed'
