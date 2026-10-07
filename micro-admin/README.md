# micro-admin

Official **micro-admin workspace** composition template — wires `admin-services-kitex` (authority) + `admin-bff-hertz` (admin BFF) into a runnable micro workspace for the admin backend (运营中台).

## Overview

This template provides a **workspace shell** that orchestrates two service templates into a cohesive admin workspace:

- **admin-services-kitex** — Unified authority service (RBAC + Rule Center)
  - Authentication (JWT login/token)
  - RBAC (users, roles, permissions, menus, Casbin)
  - Rule Center (rate limit rules management)

- **admin-bff-hertz** — Admin BFF (HTTP API gateway)
  - JWT authentication
  - RBAC authorization
  - API signature (optional)
  - Idempotency (optional)

**Architecture:**
```
Client → admin-bff-hertz (HTTP :8080)
              ↓ gRPC
         admin-services-kitex (RPC :8888)
              ↓
         PostgreSQL + Redis
```

## Prerequisites

- `ncgo` CLI (latest version)
- `hz` (Hertz code generator)
- `kitex` (Kitex code generator)
- `sqlc` (SQL compiler)
- `goose` (database migrations)
- `jq` (HTTP smoke assertions)
- `docker` + `docker compose` (for infrastructure)
- `postgres` 15+ (or use docker-compose)
- `redis` 7+ (or use docker-compose)

## Quick Start

### DingTalk operations login

The authority service includes the `000002_dingtalk.sql` migration. Apply all migrations before startup, then run `scripts/seed.sql` to grant the default admin `user:approve`.

Set `DINGTALK_APP_KEY` and `DINGTALK_APP_SECRET` in the admin BFF process. The BFF exchanges the one-time authorization code and keeps the secret server side. For local tests, `DINGTALK_API_BASE_URL` may point to a mock server; otherwise it defaults to `https://api.dingtalk.com`. Without credentials, password login remains available.

Build `ncgo-admin-web-template` with `DINGTALK_APP_KEY` and `DINGTALK_REDIRECT_URI`, and register the exact callback URI with the DingTalk application. A new identity submits an application; a user with `user:approve` and `role:read` assigns a role under **用户管理 → 钉钉申请**. After approval, the applicant scans again. The public application endpoint accepts a signed ten-minute `apply_token`, rather than a caller-supplied UnionID.

### 1. Create Workspace

```bash
mkdir my-admin && cd my-admin
ncgo new --mode micro my-admin --module github.com/acme/my-admin --dir .
```

### 2. Copy Workspace Shell

```bash
# Copy infrastructure compose and Makefile from micro-admin template
cp -r /path/to/micro-admin/workspace/compose.infra.yaml .
cp -r /path/to/micro-admin/workspace/Makefile .
cp -r /path/to/micro-admin/workspace/scripts .
```

### 3. Add Services

```bash
# Add authority service (RBAC + Rule Center)
ncgo add rpc authority --template-dir /path/to/admin-services-kitex

# Add Admin BFF (HTTP gateway)
ncgo add bff admin --template-dir /path/to/admin-bff-hertz
```

### 4. Start Infrastructure

```bash
# Start postgres + redis
make infra-up

# Or manually:
docker compose -f compose.infra.yaml up -d
```

Run `make prepare` once after adding both services. It enables the authority
database in the generated development config, generates the BFF's four Kitex
clients, runs `sqlc` and the BFF i18n generator, resolves Go dependencies, and
regenerates `scripts/seed-permissions.sql` from the BFF route permission table.

```bash
make prepare
```

### 5. Initialize Database

```bash
# Run migrations for authority service
cd services/authority
DATABASE_URL="postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable" make migrate-up

# Seed initial data (admin user, roles, permissions)
cat ../../scripts/seed-permissions.sql ../../scripts/seed.sql | \
  docker compose -f ../../compose.infra.yaml exec -T postgres \
  psql -U postgres -d micro_admin -v ON_ERROR_STOP=1

cd ../..
```

### 6. Build & Start Services

```bash
# Build authority service
cd services/authority
go build -o authority .
cd ../..

# Build admin BFF
cd services/admin
go build -o admin .
cd ../..

# Start authority in one terminal
(cd services/authority && GO_ENV=dev ./authority)

# Start BFF in another terminal
(cd services/admin && GO_ENV=dev ./admin)
```

### 7. Test

```bash
# Run smoke test against running services
bash scripts/smoke-test.sh

# Or run fresh Docker-backed migrations, seed, unit tests, and HTTP smoke checks:
make test

# Or manually:

# Login
curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"Admin@123"}'

# Get current user menus
curl -H "Authorization: Bearer <token>" http://localhost:8080/api/v1/me/menus

# Create user (requires user:create permission)
curl -X POST http://localhost:8080/api/v1/users \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"Test@123","email":"test@example.com"}'

# Create rate-limit rule (requires rate-limit:create permission)
curl -X POST http://localhost:8080/api/v1/rate-limit-rules \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"service":"admin","phase":"pre_auth","method":"GET","path":"/api/v1/example","match_kind":"exact","path_pattern":"/api/v1/example","config":{"enabled":true,"key_by":["ip"],"strategy":"fixed_window","window_seconds":60,"max_requests":100}}'
```

## Workspace Layout

```
my-admin/
├── ncgo.workspace          # Micro workspace metadata
├── compose.yaml            # Service containers (ncgo-generated)
├── compose.infra.yaml      # PostgreSQL + Redis infrastructure
├── Makefile                # Workspace commands
├── .pre-commit-config.yaml # Git hooks
├── scripts/
│   ├── e2e-test.sh        # E2E test runner
│   ├── prepare.sh         # Generate clients and code for both services
│   ├── smoke-test.sh      # Happy-path smoke test
│   ├── seed.sql           # Initial users, roles, and grants
│   └── seed-permissions.sql # Generated permission definitions
└── services/
    ├── authority/          # ← from admin-services-kitex (RBAC + Rule Center)
    └── admin/              # ← from admin-bff-hertz (HTTP BFF)
```

## Configuration

### Authority Service

Edit `services/authority/conf/dev/conf.yaml`:

```yaml
server:
  rpc:
    port: ":8888"
    network: "tcp"

database:
  enabled: true
  dsn: "postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable"

redis:
  addrs:
    - "127.0.0.1:6379"

auth:
  jwt_secret: "dev-secret-change-me"
  access_ttl_seconds: 3600
  refresh_ttl_seconds: 604800
  token_store: "memory"  # or "redis"
```

### Admin BFF

Edit `services/admin/conf/dev/conf.yaml`:

```yaml
server:
  http:
    port: "8080"
    mode: 1  # Listen on all interfaces so localhost reaches the BFF

database:
  enabled: true
  dsn: "postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable"

redis:
  addrs:
    - "127.0.0.1:6379"

auth:
  token:
    enabled: true
    header: "Authorization"
    signing_key: "dev-secret-change-me"  # Must match authority auth.jwt_secret
  signature:
    enabled: false
    static_secret: ""

grpc:
  authority:
    service_name: "authority"
    host_ports:
      - "127.0.0.1:8888"

# Optional: Enable idempotency
idempotency:
  enabled: false
  backend: "memory"
```

## Database Schema

The authority service creates the following tables:

### Users & Auth
- `users` - User accounts (username, password_hash, email, status)
- `roles` - Role definitions (code, name, status)
- `user_roles` - User-to-role assignments

### Permissions
- `permissions` - Permission definitions (code, type, name, path, method)
- `role_permissions` - Role-to-permission assignments

### Casbin Policy
- `casbin_rule` - Casbin policies (ptype, v0, v1, v2)

### Rate Limit Rules
- `rate_limit_rules` - Rate limit rule definitions (name, path_pattern, limit, window, strategy)

## API Endpoints

### Public Routes

- `POST /api/v1/auth/login` - Login
- `POST /api/v1/auth/refresh` - Refresh token
- `GET /healthz` - Liveness probe
- `GET /readyz` - Readiness probe

### Protected Routes (JWT + RBAC Required)

#### Current User
- `GET /api/v1/me/menus` - Get current user's menu tree
- `GET /api/v1/me/perms` - Get current user's permissions

#### User Management
- `GET /api/v1/users` - List users (permission: `user:read`)
- `GET /api/v1/users/:id` - Get user (permission: `user:read`)
- `POST /api/v1/users` - Create user (permission: `user:create`)
- `PUT /api/v1/users/:id` - Update user (permission: `user:update`)
- `DELETE /api/v1/users/:id` - Delete user (permission: `user:delete`)

#### Role Management
- `GET /api/v1/roles` - List roles (permission: `role:read`)
- `POST /api/v1/roles` - Create role (permission: `role:create`)
- `PUT /api/v1/roles/:id` - Update role (permission: `role:update`)
- `DELETE /api/v1/roles/:id` - Delete role (permission: `role:delete`)

#### Permission Management
- `GET /api/v1/permissions` - List permissions (permission: `permission:read`)
- `POST /api/v1/permissions` - Create permission (permission: `permission:create`)
- `PUT /api/v1/permissions/:id` - Update permission (permission: `permission:update`)
- `DELETE /api/v1/permissions/:id` - Delete permission (permission: `permission:delete`)

#### Menu Management
- `GET /api/v1/menus` - List menus (permission: `menu:read`)

#### Rate Limit Rules
- `GET /api/v1/rate-limit-rules` - List rules (permission: `rate-limit:read`)
- `POST /api/v1/rate-limit-rules` - Create rule (permission: `rate-limit:create`)
- `PUT /api/v1/rate-limit-rules/:id` - Update rule (permission: `rate-limit:update`)
- `DELETE /api/v1/rate-limit-rules/:id` - Delete rule (permission: `rate-limit:delete`)

## Seed Data

The `scripts/seed.sql` creates:

- **Admin user**: username=`admin`, password=`Admin@123` (Argon2id hash)
- **Roles**: `admin` (assigned to the admin user), `super_admin`, and restricted `operator`
- **Permission seeds**: generated API/button permissions, shared action codes, and catalog/menu nodes
- **Casbin policies**: Admin user UUID → `admin` role → wildcard `* / *`; ordinary grants use `execute`

## Security

### Password Hashing
Uses Argon2id (recommended by OWASP):
- Memory: 64 MB
- Iterations: 3
- Parallelism: 4
- Salt: 16 bytes
- Key length: 32 bytes

### JWT Tokens
- Algorithm: HS256
- Access token TTL: 3600s (1 hour)
- Refresh token TTL: 86400s (24 hours)
- Secret: Configurable (must match between BFF and authority)

### Error Codes

| Code | HTTP | Message | Description |
|------|------|---------|-------------|
| 10002 | 401 | auth_failed | Generic auth failure |
| 10007 | 401 | signature_missing | Missing signature headers |
| 10019 | 403 | signature_invalid | Invalid signature |
| 10020 | 401 | token_missing | Missing JWT token |
| 10021 | 401 | token_invalid | Invalid JWT token |
| 10108 | 403 | permission_denied | Insufficient permissions |
| 10203 | 400 | idempotency_key_missing | Missing Idempotency-Key |

## Integration Testing

```bash
# Run E2E test (includes infra setup, migrations, smoke test)
make test

# Or run manually:
./scripts/e2e-test.sh
```

**Test phases:** generation, build, unit tests, fresh Docker database and Redis,
migrations, seed, live services, then HTTP smoke checks. Docker and local
ports 5432, 6379, 8888, and 8080 must be available.

### Smoke Test Steps

1. Login, menus, permission codes, and resource lists
2. User, role, permission, and rate-limit-rule create/update/delete
3. Logout revocation

## Troubleshooting

### JWT Token Validation Failed

Ensure BFF `auth.token.signing_key` matches authority `auth.jwt_secret`:
```yaml
# services/authority/conf/dev/conf.yaml
auth:
  jwt_secret: "dev-secret-change-me"

# services/admin/conf/dev/conf.yaml
auth:
  token:
    signing_key: "dev-secret-change-me"
```

### Permission Denied

Check if user has the required permission:
```sql
SELECT p.code, p.name
FROM permissions p
JOIN role_permissions rp ON rp.permission_id = p.id
JOIN user_roles ur ON ur.role_id = rp.role_id
WHERE ur.user_id = (SELECT id FROM users WHERE username = 'admin');
```

### gRPC Connection Failed

Check authority service is running on correct port:
```bash
lsof -i :8888  # Should show authority service
```

## Related Templates

- **admin-services-kitex** — Authority service (RBAC + Rule Center)
- **admin-bff-hertz** — Admin BFF with RBAC authorization
- **base-hertz** — Basic HTTP service (no RBAC)
- **ratelimit-hertz** — HTTP service with rate limiting execution

## License

Part of the ncgo template registry.

## Permission contract (v2)

The composition shares api-src's generic RBAC behavior. The HTTP binding is
`services/admin/internal/pkg/authz/routes.go`: every matched route must be in
`Routes` or an explicit health exemption, otherwise it returns 403. Public routes
carry `Public: true`; `/me/menus`, `/me/perms`, and logout require login even
though they have no permission code. Unknown URLs still return 404. A generated
AST coverage test compares the hand-written router and permission table in both
directions. Adding a route requires adding its permission-table entry.

Ordinary API and button grants share the same action code and Casbin action
`execute`. The API permission's DB `path` and `method` are display metadata;
one code may authorize multiple HTTP routes. `cmd/permgen` creates deterministic
API/button seeds from that table. After changing routes, run `make prepare` and
apply the regenerated permission seed before using the new permissions.

`POST /api/v1/users/:id/roles` accepts `{"role_ids":["1"]}`.
`POST /api/v1/roles/:id/permissions` accepts
`{"permission_codes":["user:read"]}`. An explicit empty list revokes all grants.
`{"permission_codes":["*"]}` grants a super role; mixing `*` and concrete codes
is rejected. These endpoints require `user:assignRole` and `role:assignPerm`.
`GET /api/v1/permissions/tree` returns the full permission hierarchy and requires
`permission:read`. Both `/menus` and `/me/menus` return trees with `code` on every
node, supporting `/me/perms`-based frontend controls.

Menu visibility and `/me/perms` depend on `roles.is_super`, never the role name
`admin`. Super role responses include `permissions: ["*"]` and `is_super: true`.
Concrete grants clear the super flag. DB grants and the super flag update in one
transaction; Casbin sync errors are reported so the same input can be retried.

For existing generated workspaces, update the schema/query/repository/application
and BFF files together, regenerate sqlc and Kitex code, and apply migrations
`000003_rbac_super` and `000004_permission_contract` before deploying. The latter
merges legacy `:list`, `rate_limit:*`, and menu codes into the canonical codes
while preserving existing grants and parent links. The code merge and `execute`
repair are intentionally not reversed by Down. A role is promoted to super only
when it already has a wildcard policy or receives an explicit wildcard grant.
Several application and handler files use `update_behavior: skip`; refreshing
the template cache alone does not overwrite an existing project's implementation.

Fresh workspace seeds include `operator / Admin@123`, restricted to RBAC read
operations and their menus. `make test` exercises ordinary authorization, write
denial, role assignment, wildcard grants, revocation, menu codes, and logout.
From the template repository, `scripts/test-micro-admin-permissions.sh` renders
both services and runs build, vet, all unit tests, and seed consistency checks
without Docker. Database E2E requires Docker through the workspace's `make test`.

The templates keep their existing UUID/string ID and RPC package contracts;
iproost business resources such as edge devices and billing remain project-owned.

## Agent WebSocket, durable events and operational alerts

The Authority template now registers `AgentEventService` alongside Auth, RBAC and
Rule Center. Migration `000005_agent_events.sql` adds a PostgreSQL event queue;
`prepare.sh` also generates the BFF client from `idl/z_agent_event.proto`.

Enable the gateway in the generated BFF configuration:

```yaml
alerts_enabled: true
agent:
  enabled: true
  uid: "00000000-0000-7000-8000-000000000003"
  allowed_cidrs: ["127.0.0.1/32"]
  consumer_id: "admin-instance-1"
  revalidate_seconds: 300
```

Inject the machine secret with `AGENT_TOKEN`. Each BFF instance should have a
unique `consumer_id`. The gateway and alerts are disabled by default; enable
`alerts_enabled` in Authority too to persist its RPC errors and recovered panics.
Apply migrations and the workspace seeds before starting the services. The seed
creates an enabled `agent_worker` UUID account with an unusable password and only
`agent:stream` / `agent:publish` grants. Existing deployments must provision an
equivalent account and grants. Use private RPC connectivity or the configured
Authority caller allowlist for the trusted BFF-to-Authority boundary.

Connect to `GET /api/v1/agent/stream` with `X-Agent-Token`. Authentication checks
the raw TCP peer against `allowed_cidrs`, compares the token in constant time,
then verifies the account and the `agent:stream` permission. Forwarded-IP headers
are ignored. Account/permission revocation closes the socket with code **4403**;
a newer connection replaces the old one with code **4409**. Send a protocol
heartbeat at least every 90 seconds; WebSocket ping/pong alone does not renew the
read deadline. Frames are limited to 256 KiB and writes have a five-second deadline.

The gateway receives Authority frames shaped as:

```json
{"kind":"event","event_id":"job-1","event":{"event_id":"job-1","event_type":"example","payload_json":"{\"task\":\"sample\"}","reply_required":true}}
```

The worker sends `{"kind":"heartbeat"}`, `{"kind":"ack","event_id":"job-1"}`,
`{"kind":"result","event_id":"job-1","result_json":"{\"ok\":true}"}` or
`{"kind":"failed","event_id":"job-1","retryable":true,"error_message":"retry later"}`.
Authority replies with `accepted`, `heartbeat` or `error`. ACK completes a
notification; an event requiring a reply stays `acked` until a result arrives.

Publishing is available via the trusted `PublishAgentEvent` RPC or the machine-only
`POST /internal/v1/agent-events` route, which requires `agent:publish`:

```bash
curl -X POST http://127.0.0.1:8080/internal/v1/agent-events \
  -H "X-Agent-Token: $AGENT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"event_id":"job-1","event_type":"example","source":"scheduler","severity":"info","payload_json":"{\"task\":\"sample\"}","reply_required":true}'
```

Use a stable, unique `event_id` for retries: repeated publication preserves the
original event. `dedupe_key` is searchable metadata, not a global uniqueness
constraint. Delivery is at least once. PostgreSQL leases and `SKIP LOCKED` prevent
concurrent claimers from leasing the same event. Unacknowledged leases expire in
30 seconds; ACK extends a reply-required lease to five minutes. Expired or foreign
owners cannot change state. Identical results and notification ACKs can be replayed.
Retryable failures use exponential backoff; nonretryable failures stop delivery.
Workers should make their business effects idempotent. Domain-specific result
application belongs in the generated project's usecase, not the generic template.

Operational alerts cover HTTP 5xx responses, RPC failures and recovered panics.
They persist as `service_request_failed`, `service_rpc_failed` and `service_panic`
events even when the worker is offline. Publishing runs asynchronously with a
five-second timeout and a two-minute deduplication window. Alerts omit error text,
request/response bodies, credentials and query strings; they include error type,
request/trace identifiers and a sanitized stack excerpt. A publishing failure
releases the dedupe reservation so a later failure can retry publication.

Run `scripts/e2e-test.sh` in a generated workspace. It uses fresh PostgreSQL/Redis
Docker containers and runs the generated Go services on the host. It checks the
existing RBAC flows, machine authentication, validation/error routing, concurrent
leases, stale owners, ACK/results, retry, reconnect, replacement, account
revocation and durable operational-alert delivery. Panic recovery and sanitization
are covered by generated unit tests. Cleanup stops the owned processes and removes
the disposable containers and volumes.
