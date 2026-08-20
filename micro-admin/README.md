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
ncgo new --mode micro my-admin --module github.com/acme/my-admin --template micro-admin
cd my-admin
```

### 2. Add Services

```bash
# Add RBAC service
ncgo add rpc rbac --template rbac-kitex

# Add Admin BFF
ncgo add bff admin --template admin-bff-hertz

# Add Rule Center service
ncgo add rpc rule --template rule-center
```

### 3. Start Infrastructure

```bash
# Start postgres + redis
make infra-up

# Or manually:
docker compose up -d postgres redis
```

### 4. Initialize Databases

```bash
# Run migrations for rbac-rpc
cd services/rbac-rpc
make migrate

# Run migrations for rule-rpc
cd ../rule-rpc
make migrate

cd ../..
```

### 5. Start Services

```bash
# Start all services
make dev

# Or start individually:
cd services/rbac-rpc && go run . &
cd services/admin-bff && go run . &
cd services/rule-rpc && go run . &
```

### 6. Test

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
├── compose.yaml            # postgres + redis
├── Makefile                # workspace commands
├── .pre-commit-config.yaml # git hooks
├── scripts/
│   ├── e2e-test.sh        # E2E test runner
│   └── smoke-test.sh      # Happy-path smoke test
└── services/
    ├── rbac-rpc/           # Kitex RBAC service
    ├── admin-bff/          # Hertz Admin BFF
    └── rule-rpc/           # Kitex Rule Center service
```

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
