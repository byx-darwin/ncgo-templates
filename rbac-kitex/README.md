# rbac-kitex

Official **RBAC + auth authority** Kitex RPC template — a DDD service that owns
users / roles / permissions, Casbin enforcement, JWT login, and audit
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
  ValidateToken) + `RBACService`:
  - **User**: CreateUser / UpdateUser / DeleteUser / GetUser / ListUsers
  - **Role**: CreateRole / UpdateRole / DeleteRole / ListRoles
  - **Permission** (all writes): CreatePermission / UpdatePermission / DeletePermission / GetPermission / ListPermissions
  - **Menu** (read-only): ListMenus (returns tree view filtered to catalog+menu types)
  - **Grant/Assign**: AssignRolesToUser / GrantPermissionsToRole (takes `permission_codes []string`)
  - **AuthZ**: Enforce / GetUserMenuTree / GetUserPermCodes
- **DDD layers** (`internal/domain/<agg>` + `internal/application/<agg>`):
  - `user`, `role`, `permission` aggregates (entities + ports + validation).
  - `menu` aggregate is **read-only** (query service): ListMenus, GetUserMenuTree, UserPermCodes.
  - `rbac` aggregate (Enforce).
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

## Data Model

7 tables (Postgres):

| Table | Key Columns |
|---|---|
| `users` | id, username, password_hash, nickname, avatar, email, phone, **status int (1=enabled, 0=disabled)**, created_at, updated_at |
| `roles` | id, code, name, **status int**, **remark text**, created_at, updated_at |
| `permissions` | id, code, **type** (catalog\|menu\|button\|api), name, **parent_id** (self-FK), path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, method, sort, status, description, created_at, updated_at — **UNIQUE(code, type)** |
| `user_roles` | user_id, role_id |
| `role_permissions` | role_id, permission_id |
| `casbin_rule` | id, ptype, v0..v5 |
| `audit_log` | id, actor_uid, action, target, detail_json, created_at |

**Single Permission tree**: the `permissions` table replaces the former `permissions + menus` two-table design. Menu tree queries are a filtered view: `WHERE type IN ('catalog', 'menu')`. Casbin only consumes `code`; the `code+type` composite uniqueness is transparent to it.

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
