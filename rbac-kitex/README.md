# rbac-kitex

Official **RBAC + auth authority** Kitex RPC template — a DDD service that owns
users / roles / permissions / menus, Casbin enforcement, JWT login, and audit
logging. Other services (e.g. an admin BFF) call it to validate tokens and
answer authorization questions.

## Use

```bash
ncgo template pull rbac-kitex
ncgo new rbac --module github.com/acme/rbac --kind kitex \
  --template rbac-kitex --db postgres
```

> The authority always owns a PostgreSQL database (relational grants,
> `casbin_rule` enforcement source, and `audit_log`). Run `make migrate-up`
> against the target database after scaffolding.

## Contents

- `idl/auth.proto` — `rbac.v1`: `AuthService` (Login / Refresh / Logout /
  ValidateToken) + `RBACService` (user / role / permission / menu CRUD,
  AssignRolesToUser, GrantPermissionsToRole, Enforce, GetUserMenuTree,
  GetUserPermCodes).
- **DDD layers** (`internal/domain/<agg>` + `internal/application/<agg>`):
  - `user`, `role`, `permission`, `menu` aggregates (entities + ports +
    validation), plus `rbac` (Enforce).
  - Cross-aggregate consistency (grant → role, assign → user) lives in the
    application services, which **sync into Casbin** in the same flow.
- **Infrastructure** (`internal/infrastructure/`):
  - `casbin/` — sqlc-backed `persist.Adapter` over `casbin_rule`; embedded RBAC
    model `sub, obj, act`. `casbin_rule` is the enforcement single source;
    management writes (grant/assign) sync into it.
  - `auth/` — HS256 JWT (`{uid, roles}`) + argon2id password hashing.
  - `token/` — refresh-token store + access-token blacklist (memory default).
  - `audit/` — `audit_log` writer for every RBAC mutation.
- **Repositories** (`internal/repository/<agg>/`) — sqlc-backed domain-port
  implementations.
- `internal/base/server/server.go` wires both RPC services onto one Kitex
  server; `conf/` carries the JWT secret + token TTLs.

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.

## Seams (documented TODO)

- **Data scope / org tree**: `// TODO(data-scope)` — a `dom` column on
  permission/role links plus a `departments` tree is the intended extension;
  v1 enforces `sub, obj, act` only.
- **RS256 / JWKS**: HS256 with a configured secret is the v1 default.
- **Local Casbin enforcer + watcher**: v1 answers `Enforce` via RPC; a BFF-side
  enforcer with a Redis pub/sub watcher is a documented follow-up.
- **Redis token store**: `auth.token_store: redis` selects the seam type; wire
  a real redis client to enable it (memory is the hermetic default).
- **OTel observability**: enabled when `jaeger` config is present (base wiring).
