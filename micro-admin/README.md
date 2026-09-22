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
clients, runs `sqlc` and the BFF i18n generator, and resolves Go dependencies.

```bash
make prepare
```

### 5. Initialize Database

```bash
# Run migrations for authority service
cd services/authority
DATABASE_URL="postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable" make migrate-up

# Seed initial data (admin user, roles, permissions)
docker compose -f ../../compose.infra.yaml exec -T postgres \
  psql -U postgres -d micro_admin -v ON_ERROR_STOP=1 < ../../scripts/seed.sql

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

# Create rate-limit rule (requires rate_limit:create permission)
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
│   └── seed.sql           # Initial data (admin user, roles, permissions)
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
- `GET /api/v1/users` - List users (permission: `user:list`)
- `GET /api/v1/users/:id` - Get user (permission: `user:read`)
- `POST /api/v1/users` - Create user (permission: `user:create`)
- `PUT /api/v1/users/:id` - Update user (permission: `user:update`)
- `DELETE /api/v1/users/:id` - Delete user (permission: `user:delete`)

#### Role Management
- `GET /api/v1/roles` - List roles (permission: `role:list`)
- `POST /api/v1/roles` - Create role (permission: `role:create`)
- `PUT /api/v1/roles/:id` - Update role (permission: `role:update`)
- `DELETE /api/v1/roles/:id` - Delete role (permission: `role:delete`)

#### Permission Management
- `GET /api/v1/permissions` - List permissions (permission: `permission:list`)
- `POST /api/v1/permissions` - Create permission (permission: `permission:create`)
- `PUT /api/v1/permissions/:id` - Update permission (permission: `permission:update`)
- `DELETE /api/v1/permissions/:id` - Delete permission (permission: `permission:delete`)

#### Menu Management
- `GET /api/v1/menus` - List menus (permission: `menu:list`)

#### Rate Limit Rules
- `GET /api/v1/rate-limit-rules` - List rules (permission: `rate_limit:list`)
- `POST /api/v1/rate-limit-rules` - Create rule (permission: `rate_limit:create`)
- `PUT /api/v1/rate-limit-rules/:id` - Update rule (permission: `rate_limit:update`)
- `DELETE /api/v1/rate-limit-rules/:id` - Delete rule (permission: `rate_limit:delete`)

## Seed Data

The `scripts/seed.sql` creates:

- **Admin user**: username=`admin`, password=`Admin@123` (Argon2id hash)
- **Roles**: `admin` (assigned to the admin user) and `super_admin`
- **All permissions**: user/role/permission/menu/rate_limit CRUD
- **Casbin policies**: Admin user UUID → `admin` role → all permissions

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
