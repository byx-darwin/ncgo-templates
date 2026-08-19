# rbac-kitex

Official **RBAC + auth authority** Kitex RPC service template — a DDD-organized
service that owns users, roles, permissions, menus, and the Casbin policy. Other
services (e.g. an admin BFF) call its `AuthService` and `RBACService` RPCs.

## Use

```bash
ncgo template pull rbac-kitex
ncgo new auth-rpc --module github.com/acme/auth-rpc --kind kitex \
  --db postgres --template rbac-kitex
cd auth-rpc
make sqlc          # regenerate internal/db/gen from the bundled schema/queries
make update        # regenerate kitex_gen from idl/auth.proto
```

> Requires a PostgreSQL database (the authority owns `users`, `roles`,
> `permissions`, `menus`, `casbin_rule`, `audit_log`). Set `database.dsn` in
> `conf/dev/conf.yaml` before running.

## Contents

DDD layers (aggregate-organized):

- `internal/domain/{user,role,permission,menu}/` — pure domain entities, value
  objects, domain rules, and repository ports.
- `internal/application/{auth,user,role,permission,menu,rbac}/` — application
  services that orchestrate domain + repositories + Casbin policy sync.
- `internal/repository/{user,role,permission,menu}/` — sqlc-backed
  implementations of the domain ports.
- `internal/infrastructure/casbin/` — Casbin basic model (`sub, obj, act`) with a
  sqlc-based `persist.Adapter` over `casbin_rule`.
- `internal/infrastructure/auth/` — HS256 JWT (`uid`, `roles` claims) and
  argon2id password hashing.
- `internal/infrastructure/token/` — refresh-token store and JWT blacklist
  (in-memory default; Redis seam).
- `internal/infrastructure/audit/` — `audit_log` writer for RBAC mutations.

RPC surface (`idl/auth.proto`):

- `AuthService` — `Login`, `Refresh`, `Logout`, `ValidateToken`.
- `RBACService` — user/role/permission/menu CRUD, `AssignRolesToUser`,
  `GrantPermissionsToRole`, `Enforce`, `GetUserMenuTree`, `GetUserPermCodes`.

Unified permission code: `permissions.code` == Casbin `obj` == `menus.perm_code`.

## Variables

`{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.

## Seams

Production concerns documented as follow-ups (v1 is a reference scaffold):

- **Data scope / org tree** — Casbin uses the basic `sub, obj, act` model. A
  `dom` column plus a `departments` tree and role→data-scope binding are the
  intended extension.
- **RS256/JWKS** — tokens are HS256 signed with `auth.jwt_secret`; RS256/JWKS
  key rotation is a seam.
- **Local enforcer + watcher** — v1 answers `Enforce` via RPC; a local Casbin
  enforcer with a Redis pub/sub watcher for the BFF is a follow-up.
- **Redis token store** — `auth.token_store: redis` selects the Redis seam;
  the client is not wired in v1 (see `internal/infrastructure/token/redis.go`).
- **OTel** — Jaeger tracing is wired when `jaeger.enable` is set.
