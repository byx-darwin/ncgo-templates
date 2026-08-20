# micro-admin

Official **micro-admin workspace** composition template — wires `rbac-kitex` (authority) + `admin-bff-hertz` (admin BFF) + `rule-center` (rate-limit) into a runnable micro workspace for the micro-admin (运营中台) program.

## Overview

This template provides a **workspace shell** that orchestrates three service templates into a cohesive admin workspace:

- **rbac-kitex** — RBAC + auth authority service (users, roles, permissions, menus, Casbin enforcement, JWT login)
- **admin-bff-hertz** — Admin BFF (thin HTTP API gateway with JWT auth + RBAC authorization)
- **rule-center** — Rate-limit rule-center service (dynamic rate-limit rules)

## Prerequisites

- `ncgo` CLI (latest version)
- `hz` (Hertz code generator)
- `kitex` (Kitex code generator)
- `sqlc` (SQL compiler)
- `docker` + `docker compose` (for infrastructure)
- `postgres` 15+ (or use docker-compose)
- `redis` 7+ (or use docker-compose)

## Quick Start

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
```

### 3. Add Services

```bash
# Add RBAC service (authority)
ncgo add rpc rbac --template-dir /path/to/rbac-kitex

# Add Admin BFF (HTTP gateway)
ncgo add bff admin --template-dir /path/to/admin-bff-hertz

# Add Rule Center service (rate-limit)
ncgo add rpc rule --template-dir /path/to/rule-center
```

### 4. Start Infrastructure

```bash
# Start postgres + redis
make infra-up

# Or manually:
docker compose -f compose.infra.yaml up -d
```

### 5. Initialize Databases

```bash
# Run migrations for rbac
cd services/rbac
make sqlc
DATABASE_URL="postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable" make migrate-up

# Run migrations for rule
cd ../rule
make sqlc
DATABASE_URL="postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable" make migrate-up

cd ../..
```

### 6. Build & Start Services

```bash
# Build all services
cd services/rbac && go mod tidy && go build . && cd ../..
cd services/admin && go mod tidy && go build . && cd ../..
cd services/rule && go mod tidy && go build . && cd ../..

# Start all services
cd services/rbac && ./rbac > /tmp/rbac.log 2>&1 &
cd services/admin && ./admin > /tmp/admin.log 2>&1 &
cd services/rule && ./rule > /tmp/rule.log 2>&1 &
cd ../..
```

### 7. Test

```bash
# Login
curl -X POST http://localhost:8888/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}'

# Get current user menus
curl -H "Authorization: Bearer <token>" http://localhost:8888/api/v1/me/menus
```

## E2E Testing

The workspace includes hybrid E2E tests:

```bash
# Run all tests (hermetic + integration if docker available)
make test

# Or run manually:
./scripts/e2e-test.sh
```

**Test Phases:**
- **Phase 1 (Hermetic):** Always runs — build + unit tests
- **Phase 2 (Integration):** Requires docker — starts services + runs smoke test

## Workspace Layout

```
my-admin/
├── ncgo.workspace          # micro workspace metadata
├── compose.yaml            # service containers (ncgo-generated)
├── compose.infra.yaml      # postgres + redis infrastructure
├── Makefile                # workspace commands
├── .pre-commit-config.yaml # git hooks
├── scripts/
│   ├── e2e-test.sh        # E2E test runner
│   └── smoke-test.sh      # Happy-path smoke test
└── services/
    ├── rbac/               # Kitex RBAC service
    ├── admin/              # Hertz Admin BFF
    └── rule/               # Kitex Rule Center service
```

## Integration Testing

Complete integration test flow from workspace creation to service validation:

### 1. Create Workspace

```bash
mkdir -p /tmp/micro-admin-test && cd /tmp/micro-admin-test
ncgo new --mode micro test-admin --module github.com/test/admin --dir .
```

### 2. Add Services

```bash
# Copy workspace shell
cp -r /path/to/micro-admin/workspace/* .

# Add services (triggers code generation)
ncgo add rpc rbac --template-dir /path/to/rbac-kitex
ncgo add bff admin --template-dir /path/to/admin-bff-hertz
ncgo add rpc rule --template-dir /path/to/rule-center
```

### 3. Start Infrastructure

```bash
docker compose -f compose.infra.yaml up -d
sleep 5
```

### 4. Run Database Migrations

```bash
cd services/rbac && make sqlc
DATABASE_URL="postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable" make migrate-up
cd ../rule && make sqlc
DATABASE_URL="postgres://postgres:postgres@localhost:5432/micro_admin?sslmode=disable" make migrate-up
cd ../..
```

### 5. Start Services

```bash
cd services/rbac && go mod tidy && go build . && ./rbac &
cd services/admin && go mod tidy && go build . && ./admin &
cd services/rule && go mod tidy && go build . && ./rule &
cd ../..

sleep 10
```

### 6. Run Smoke Test

```bash
./scripts/smoke-test.sh
```

Expected output:
```
==> Smoke test: Service interactions
  [1/4] Login (admin-bff → rbac-rpc)...
  ✓ Login successful
  [2/4] Get menus (admin-bff → rbac-rpc)...
  ✓ Menus retrieved
  [3/4] Create user (admin-bff → rbac-rpc with Authz)...
  ✓ User created
  [4/4] Create rate-limit rule (admin-bff → rule-rpc)...
  ✓ Rate-limit rule created

==> Smoke test: PASSED
```

### Service Interactions Verified

- ✅ admin-bff → rbac-rpc: Login (AuthService)
- ✅ admin-bff → rbac-rpc: GetMenus (RBACService)
- ✅ admin-bff → rbac-rpc: CreateUser (RBACService with Authz)
- ✅ admin-bff → rule-rpc: CreateRule (RuleService)
- ✅ JWT token propagation across services
- ✅ Database connections (postgres)
- ✅ Service health (all listening on expected ports)

## Graceful Degradation

| Scenario | Behavior |
|----------|----------|
| **rule-center unavailable** | admin-bff still serves; rate-limit rule management returns errors, other functions unaffected |
| **postgres unavailable** | All services fail to start (hard dependency) |
| **redis unavailable** | rbac-rpc and rule-rpc degrade (cache misses, but still functional) |

## Seams (Documented TODO, Not Built in v1)

| Seam | Description | Code Marker |
|------|-------------|-------------|
| **OTel Observability** | Basic wiring, requires jaeger config | `// TODO(otel)` |
| **SSO/OIDC** | Current JWT, extensible to SSO/OIDC | `// TODO(sso)` |
| **Org-tree/Data-scope** | Organization tree + data permissions | `// TODO(org-tree)` |
| **Production deployment** | k8s deployment configs | `// TODO(k8s)` |

## Related

- [rbac-kitex](../rbac-kitex/) — Authority service template
- [admin-bff-hertz](../admin-bff-hertz/) — Admin BFF template
- [rule-center](../rule-center/) — Rate-limit service template
- [Issue #13](https://github.com/byx-darwin/ncgo-templates/issues/13) — micro-admin composition
