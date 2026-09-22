#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AUTHORITY="$ROOT/services/authority"
ADMIN="$ROOT/services/admin"

for tool in kitex sqlc python3; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
test -f "$AUTHORITY/go.mod" && test -f "$ADMIN/go.mod" || {
  echo "Generate services/authority and services/admin first" >&2
  exit 1
}

# The authority package is reusable outside this composition, so its default
# database is disabled. Enable the workspace database in the generated copy.
python3 - "$AUTHORITY/conf/dev/conf.yaml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = 'database:\n  # 是否启用数据库连接\n  enabled: false'
new = 'database:\n  # 是否启用数据库连接\n  enabled: true'
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit('authority database config has an unexpected shape')
old = '  dsn: ""'
new = '  dsn: "postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable"'
if old in text:
    text = text.replace(old, new, 1)
elif new not in text:
    raise SystemExit('authority database DSN has an unexpected shape')
path.write_text(text)
PY

echo '==> Generating authority database code'
(cd "$AUTHORITY" && make sqlc && go mod tidy)

echo '==> Generating BFF RPC clients, database code, and i18n catalog'
(
  cd "$ADMIN"
  module=$(go list -m)
  for proto in auth rbac rule_center user; do
    kitex -module "$module" -type protobuf -I idl "idl/$proto.proto"
  done
  make sqlc
  make i18n
  go mod tidy
)

echo '==> Workspace preparation complete'
