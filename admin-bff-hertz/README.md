# admin-bff-hertz

Official **admin BFF** Hertz HTTP template — a JSON API gateway for admin
dashboards that authenticates via JWT, enforces RBAC authorization through
`rbac-kitex`, and manages dynamic rate-limit rules through `rule-center`.

## Use

```bash
ncgo template pull admin-bff-hertz
ncgo new admin-bff --module github.com/acme/admin-bff --kind hertz \
  --template admin-bff-hertz
```

> The BFF is a pure HTTP facade; it does **not** own a database. Upstream
> authority (`rbac-kitex`) and rate-limit rules (`rule-center`) are called
> over Kitex RPC — set their addresses in `conf/dev/conf.yaml` under
> `rpc.services.rbac_kitex` / `rpc.services.rule_center`.

## Contents

- **IDL** (`idl/`):
  - `auth.proto` — `AuthService`: Login / Refresh / Logout (JWT issuance).
  - `rbac.proto` — `RBACService`: users, roles, permissions, menus,
    grant/assign, Enforce, GetUserMenuTree, GetUserPermCodes.
  - `rule_center.proto` — `RuleService`: dynamic rate-limit rule CRUD.
- **Handlers** (`internal/handler/`):
  - `auth` — login / refresh / logout.
  - `current_user` — current user's menu tree and permission codes.
  - `user` / `role` / `permission` / `menu` — RBAC management.
  - `rate_limit` — dynamic rate-limit rule management.
  - `health` — `/healthz`, `/readyz`.
- **Middleware** (`internal/pkg/middleware/`):
  - `JWT` — HS256 validation; public paths skipped via `cfg.Auth.PublicPaths`.
  - `Authz` — `RequirePermission(...)` enforcement by calling `rbac-kitex`.
  - `CORS` — configurable origin/method/header allowlists.
  - `Idempotency` — POST/PUT/PATCH/DELETE idempotency keys.
  - `RateLimit` — pre-auth and post-auth phases; pulls rules from
    `rule-center` at startup and hot-reloads on change.
  - `Signature` / `Observability` / `RequestID` / `AccessLog` / `Recovery`.
- **Architecture** — DDD-inspired layered split:
  ```
  handler/*  →  usecase/*  →  adapter/* (RPC clients)
  ```
  Handlers bind+validate then delegate to usecases; usecases call adapter
  ports (Kitex RPC clients). No direct DB access in this template.
- **Layer rules** (enforced by `ncgo doctor`):
  - Handlers MUST NOT import `internal/repository/*` or `internal/base/data`.
  - Usecases MUST NOT import `github.com/cloudwego/hertz/...`.
  - Adapters MUST NOT import `internal/usecase/*`.
- **Request lifecycle**:
  ```
  Recovery → RequestID → AccessLog → RequestTimeout
    → CORS → RateLimit(pre_auth) → Signature → JWT → RateLimit(post_auth)
    → Idempotency → hz-generated routes → Handler.Method
  ```
- **Responses** — `go-framework/hertz.Responder`; JSON by default, Protobuf
  when `Accept: application/x-protobuf`. i18n via `internal/pkg/i18n`
  (en, zh-CN, zh-TW, ja-JP, ko-KR, fr-FR, de-DE, es-ES).
- **Error codes** — framework `10000–10499`, middleware `20000–20699`,
  auth `40000–40099`, business `>= 40100`. Raised as
  `goerror.In("...").Code(code).Public("msg")` chains.

## Configuration

Configuration lives in `conf/<env>/conf.yaml`, selected by `GO_ENV`
(defaults to `dev`). `Init()` is called once from `main.go`.

Key sections:

| Section | Purpose |
|---|---|
| `server` | Hertz listen address, read/write/idle timeouts. |
| `rpc.services.rbac_kitex` | Kitex target for `rbac-kitex` (host:port). |
| `rpc.services.rule_center` | Kitex target for `rule-center` (host:port). |
| `rpc.request_timeout_seconds` | Default RPC deadline. |
| `auth.public_paths` | JWT-skipped paths (login, health, etc.). |
| `auth.jwt_secret` | HS256 signing secret. |
| `cors` | Origin/method/header allowlists. |
| `rate_limit.source` | `memory` / `redis` backend. |
| `rate_limit.rule.*` | Default window/limit/strategy for the pre-auth phase. |
| `idempotency` | Backend + TTL for idempotency keys. |
| `security.internal_only` | CIDR/path allowlist for internal routes. |

Duration-typed fields (timeouts, TTLs, windows) use `config.Duration` and
accept duration strings like `"30s"` or `"200ms"` in YAML; bare integers
are rejected.

## Seams (extension points)

Generated code marks customisation seams with `// TODO(ncgo):` comments.
Replace the default stub with your own logic:

| File | Seam |
|---|---|
| `internal/usecase/<service>/*.go` | Wire real RPC adapter ports instead of the `notImplementedUseCase` stub. |
| `internal/adapter/rbac/client.go` | Replace the stubbed RBAC client with a real Kitex call to `rbac-kitex`. |
| `internal/adapter/rulecenter/client.go` | Replace the stubbed RuleCenter client with a real Kitex call. |
| `internal/handler/pb/{{.ServiceName}}_service.go` | Register additional middleware per-route (e.g. `RequirePermission("user:write")`). |
| `internal/pkg/errcode/errcode.go` | Add business error codes (`>= 40100`) and their HTTP status mappings. |
| `internal/pkg/i18n/locales/*.json` | Extend translations; run `make i18n` to regenerate `catalog_gen.go`. |
| `internal/pkg/middleware/observability.go` | Swap the default logger for a structured-logging snippet (Redis / Kafka / ES / ClickHouse variants ship under `internal/pkg/middleware/snippets/`). |
| `router/` | Add new routes after the generated block (between `// ncgo:managed` markers). |

## Testing

```bash
cd <generated-project>
go build ./...
go test ./...
```

The template ships an E2E scaffold script at
`admin-bff-hertz/test/e2e_test.sh` that generates a project from the
template, builds it, and runs `go test ./...` — useful for CI smoke tests.

## References

- Hertz template design doc: [`admin-bff/CLAUDE.md`](../admin-bff/CLAUDE.md)
- Upstream authority template: [`rbac-kitex/`](../rbac-kitex/)
- Rate-limit rule service: [`rule-center/`](../rule-center/)
- Base Hertz template: [`base-hertz/`](../base-hertz/)
