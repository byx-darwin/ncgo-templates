# admin-bff-hertz

Official **Admin BFF (Backend for Frontend)** Hertz HTTP template — JWT authentication, RBAC authorization, API signature, and idempotency support.

## Overview

`admin-bff-hertz` is designed for building admin backends with fine-grained permission control. It connects to `admin-services-kitex` (authority service) for authentication and authorization:

- ✅ **JWT Authentication** - Bearer token validation
- ✅ **RBAC Authorization** - Permission-based access control via Casbin
- ✅ **API Signature** - HMAC signature verification (optional)
- ✅ **Idempotency** - Prevent duplicate requests (optional)
- ✅ **Fine-grained Error Codes** - Aligned with go-framework v0.2.1

**Architecture:**
```
Client → admin-bff-hertz (BFF) → admin-services-kitex (Authority)
         - JWT validation        - AuthService (login/token)
         - RBAC check            - RBACService (users/roles/permissions)
         - Signature             - RuleService (rate limit rules)
```

## Quick Start

```bash
# Create admin BFF
ncgo new admin-api --module github.com/acme/admin-api --kind hertz --db postgres --template admin-bff-hertz

# Add authority service (required)
ncgo add rpc authority --template admin-services-kitex
```

## Configuration

### JWT Configuration

JWT authentication uses the unified `auth.token` configuration:

```yaml
auth:
  token:
    enabled: true
    header: "X-Authorization"
    signing_key: "dev-secret-change-me"  # Must match authority service
    issuer: ""
    buffer_seconds: 300
    expires_seconds: 3600
```

### gRPC Connection

Connect to authority service:

```yaml
grpc:
  authority:
    service_name: "authority"
    host_ports:
      - "127.0.0.1:8888"
    rpc_timeout_seconds: 5
```

Connect to the `user-kitex` service (required for Terminal User Management routes — see [API Routes](#terminal-user-management)):

```yaml
grpc:
  terminal_user:
    service_name: "userservice"
    host_ports:
      - "127.0.0.1:8890"
    rpc_timeout_seconds: 3
    connect_timeout_milliseconds: 100
```

> The values above are the shipped `conf/dev/conf.yaml` defaults. Note that
> `rpc_timeout_seconds` / `connect_timeout_milliseconds` / `retry` are parsed
> into `conf.ClientConfig` but are **not** currently applied to the Kitex
> clients created in `internal/base/server/server.go` (which pass only
> `client.WithHostPorts`). This is a pre-existing gap shared with
> `grpc.authority` — set them for forward compatibility, but do not rely on
> them to bound RPC latency today.

> **`ForceLogout` caveat:** `POST /api/v1/terminal-users/:uid/ban` triggers `ForceLogout` on `user-kitex` automatically. If the `user-kitex` instance behind `grpc.terminal_user` has its own Redis blacklist disabled (`redis.enabled: false` in its config), `ForceLogout` succeeds at the API level but revokes nothing — this matches `user-kitex`'s documented `noopBlacklist` fallback behavior, not a bug in `admin-bff-hertz`. Enable Redis in `user-kitex` if you need bans to actually invalidate outstanding access tokens.

> **⚠️ Upgrading an existing deployment:** `grpc.authority.{service_name,host_ports}` and `grpc.terminal_user.{service_name,host_ports}` are both **required** — `Validate()` refuses to boot without them (`grpc.terminal_user.service_name is empty`, etc.), by design, not a bug. `conf.Load` fully replaces `Default()`'s values with whatever your loaded YAML contains, so a prod/staging `conf.yaml` written before these fields existed will **not** pick up their defaults automatically — only the shipped `conf/dev/conf.yaml` gets regenerated via `cover`. If your own `conf.yaml` predates Terminal User Management, add the `grpc.terminal_user` block above (and `grpc.authority`, if missing) before upgrading, or the service will fail to start.

### RBAC Authorization

Authorization is handled via Casbin policies:

```yaml
auth:
  public_paths:
    - /healthz
    - /readyz
```

### API Signature (Optional)

For open API scenarios:

```yaml
auth:
  signature:
    enabled: true
    static_secret: "your-app-secret"
    header_app_key: "X-App-Key"
    header_timestamp: "X-Timestamp"
    header_nonce: "X-Nonce"
    header_signature: "X-Signature"
```

## API Routes

### Public Routes

- `POST /api/v1/auth/login` - Login (returns JWT)
- `POST /api/v1/auth/refresh` - Refresh token
- `GET /healthz` - Liveness probe
- `GET /readyz` - Readiness probe

### Protected Routes (JWT + RBAC Required)

#### Auth

```
POST /api/v1/auth/logout
```

#### Current User

```
GET /api/v1/me/menus      # Get current user's menu tree
GET /api/v1/me/perms      # Get current user's permissions
```

#### User Management

```
GET    /api/v1/users      # permission: user:list
GET    /api/v1/users/:id  # permission: user:read
POST   /api/v1/users      # permission: user:create
PUT    /api/v1/users/:id  # permission: user:update
DELETE /api/v1/users/:id  # permission: user:delete
```

#### Role Management

```
GET    /api/v1/roles      # permission: role:list
POST   /api/v1/roles      # permission: role:create
PUT    /api/v1/roles/:id  # permission: role:update
DELETE /api/v1/roles/:id  # permission: role:delete
```

#### Permission Management

```
GET    /api/v1/permissions      # permission: permission:list
GET    /api/v1/permissions/:id  # permission: permission:read
POST   /api/v1/permissions      # permission: permission:create
PUT    /api/v1/permissions/:id  # permission: permission:update
DELETE /api/v1/permissions/:id  # permission: permission:delete
```

#### Menu Management

```
GET /api/v1/menus  # permission: menu:list
```

#### Rate Limit Rules Management

```
GET    /api/v1/rate-limit-rules      # permission: rate_limit:list
POST   /api/v1/rate-limit-rules      # permission: rate_limit:create
PUT    /api/v1/rate-limit-rules/:id  # permission: rate_limit:update
DELETE /api/v1/rate-limit-rules/:id  # permission: rate_limit:delete
```

#### Terminal User Management

Distinct from `/api/v1/users` above: these routes manage end-user (terminal) accounts owned by `user-kitex`, not RBAC admin accounts owned by the authority service. They call `user-kitex` via `grpc.terminal_user` (see [Configuration](#grpc-connection) above), not `rbacservice`.

```
GET    /api/v1/terminal-users                          # permission: terminal_user:list
GET    /api/v1/terminal-users/:uid                      # permission: terminal_user:read
POST   /api/v1/terminal-users/:uid/ban                  # permission: terminal_user:ban
POST   /api/v1/terminal-users/:uid/unban                # permission: terminal_user:unban
DELETE /api/v1/terminal-users/:uid/identities/:provider  # permission: terminal_user:unbind-identity
```

`POST .../ban` bans the account and then makes a best-effort `ForceLogout`
call. The ban is the source of truth and is never rolled back, so the route
returns `200` even when `ForceLogout` fails; the failure is reported in the
response body rather than in the status code:

```json
{ "banned": true, "force_logout_error": "" }
```

A non-empty `force_logout_error` means the account is banned but previously
issued access tokens may still be usable until they expire — clients that care
about immediate revocation must check this field, not just the status code.

## Middleware Stack

### Request Flow

```
1. Signature Verification (if enabled)
2. Idempotency Check (if enabled)
3. JWT Authentication
4. RBAC Authorization (Casbin)
5. Permission Check (per-route)
6. Handler Execution → gRPC call to authority
```

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

## Permission System

### Permission Types

- **catalog** - Top-level menu category
- **menu** - Menu item
- **button** - UI button/action
- **api** - API endpoint permission

### Permission Codes

Standard naming convention: `resource:action`

| Code | Description |
|------|-------------|
| `user:list` | List users |
| `user:read` | Get user detail |
| `user:create` | Create user |
| `user:update` | Update user |
| `user:delete` | Delete user |
| `role:list` | List roles |
| `role:create` | Create role |
| `role:update` | Update role |
| `role:delete` | Delete role |
| `permission:list` | List permissions |
| `permission:read` | Get permission detail |
| `permission:create` | Create permission |
| `permission:update` | Update permission |
| `permission:delete` | Delete permission |
| `menu:list` | List menus |
| `rate_limit:list` | List rate limit rules |
| `rate_limit:create` | Create rate limit rule |
| `rate_limit:update` | Update rate limit rule |
| `rate_limit:delete` | Delete rate limit rule |
| `terminal_user:list` | List terminal (end-user) accounts |
| `terminal_user:read` | Get terminal user detail |
| `terminal_user:ban` | Ban a terminal user (also triggers `ForceLogout`, see [gRPC Connection](#grpc-connection)) |
| `terminal_user:unban` | Unban a terminal user |
| `terminal_user:unbind-identity` | Unbind a third-party identity provider from a terminal user |

### Casbin Policy Model

```
[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[role_definition]
g = user, role

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = g(r.sub, p.sub) && r.obj == p.obj && r.act == p.act
```

## Project Structure

```
admin-api/
├── internal/
│   ├── base/
│   │   ├── conf/                  # Configuration
│   │   ├── data/                  # Database clients
│   │   └── server/                # HTTP server setup
│   ├── handler/
│   │   ├── auth.go                # Login/logout handlers
│   │   ├── user.go                # User management
│   │   ├── role.go                # Role management
│   │   ├── permission.go          # Permission management
│   │   ├── menu.go                # Menu management
│   │   ├── rate_limit.go          # Rate limit rules
│   │   ├── current_user.go        # Current user info
│   │   └── pb/                    # Proto handlers
│   ├── usecase/                   # Business logic
│   │   └── pb/                    # Proto use cases
│   ├── model/                     # Domain types (non-protobuf)
│   ├── pkg/
│   │   ├── middleware/
│   │   │   ├── jwt.go             # JWT validation
│   │   │   ├── authz.go           # RBAC authorization
│   │   │   ├── signature.go       # API signature
│   │   │   └── idempotency.go     # Idempotency
│   │   └── response/              # Error codes
│   ├── repository/                # Data access
│   └── router/
│       └── adminbffservice.go     # Route registration
├── conf/
│   └── dev/conf.yaml              # Configuration
└── idl/
    └── *.proto                    # Proto definitions
```

## DDD Scaffolding

The template generates the following DDD layers:

| Layer | Path | Description |
|-------|------|-------------|
| Handler | `internal/handler/pb/` | HTTP handlers — bind, delegate, respond |
| UseCase | `internal/usecase/pb/` | Business logic — implement handler's `useCase` interface |
| Repository | `internal/repository/` | Data access — database queries |
| Model | `internal/model/` | Domain types — for non-protobuf scenarios |
| Response | `internal/pkg/response/` | HTTP response helpers (wraps go-framework/hertz) |

### Wiring

The template wires layers in `internal/base/server/server.go`:

```go
// Wire DDD: usecase → handler
pbhandler.SetDefaultUseCase(usecasepb.NewUseCase())
```

### Error Routing

`NewResponder()` enables `RPCErrorRouter` by default, mapping `go-common/error` oops errors to HTTP status codes. This is essential for BFF services calling RPC backends.

### JWT Claims

The `Claims` struct includes a `Roles` field for permission-based access control:

```go
type Claims struct {
    Uid   string   `json:"uid"`
    AK    string   `json:"ak"`
    Roles []string `json:"roles,omitempty"`
    jwt.RegisteredClaims
}
```

`Uid` comes from a verified JWT (`TokenAuth`); `AK` comes from a verified HMAC signature (`SignatureAuth`, `X-App-Key`/`X-Signature` headers) — a separate, non-JWT open-API auth path. `TokenAuth` preserves any `AK` `SignatureAuth` already set earlier in the chain instead of overwriting it.

**Registration order limits what's actually reachable today** (`signature → idempotency → JWT`, with rate limiting registered engine-level even earlier): `idempotency.go`'s plain `ak:`-scoped branch is live — a signed request now gets a verified-`AK`-scoped key instead of falling back to the unverified `X-App-Key` header. The `ak_user_uuid:` combined branch and `rate_limit.go`'s `AK` read are **not yet reachable**, because idempotency runs before `TokenAuth` (so `Uid` is always empty there) and rate limiting runs before `SignatureAuth` (so `AK` is always empty there). Tracked separately as issue #73.

A JWT can also carry its own `ak` claim; if `SignatureAuth` never ran, `TokenAuth` passes that value through unverified by the HMAC path (only the JWT's own signature backs it).

## Login Flow

```bash
# 1. Login
curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"Admin@123"}'

# Response:
{
  "code": 200,
  "msg": "ok",
  "data": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "refresh_token": "9d4ab5f7bfb8...",
    "expires_in": 3600
  }
}

# 2. Use token
curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIs..." \
  http://localhost:8080/api/v1/users
```

## API Signature Example

```bash
# Generate signature
METHOD="POST"
PATH="/api/v1/users"
TIMESTAMP=$(date +%s)
NONCE=$(openssl rand -hex 8)
BODY='{"username":"testuser"}'
SECRET="your-app-secret"

CANONICAL="${METHOD}\n${PATH}\n\n${TIMESTAMP}\n${NONCE}\n${BODY}"
SIGNATURE=$(echo -ne "$CANONICAL" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')

# Make request
curl -X POST http://localhost:8080/api/v1/users \
  -H "X-App-Key: my-app" \
  -H "X-Timestamp: $TIMESTAMP" \
  -H "X-Nonce: $NONCE" \
  -H "X-Signature: $SIGNATURE" \
  -H "Content-Type: application/json" \
  -d "$BODY"
```

## Idempotency Example

```bash
# First request
curl -X POST http://localhost:8080/api/v1/users \
  -H "Authorization: Bearer <token>" \
  -H "Idempotency-Key: unique-key-123" \
  -H "Content-Type: application/json" \
  -d '{"username":"user1"}'

# Second request with same key (returns cached response)
curl -X POST http://localhost:8080/api/v1/users \
  -H "Authorization: Bearer <token>" \
  -H "Idempotency-Key: unique-key-123" \
  -H "Content-Type: application/json" \
  -d '{"username":"different-user"}'  # Ignored, returns first response
```

## Development

```bash
# Run in development mode
make dev

# Build binary
make build

# Run tests
make test
```

## Seams

- **`Authz` middleware ordering bug, fixed by this plan.** Prior to this plan, `middleware.Authz(rbacCli)` was registered at the `protected` route-group level via `.Use(...)`, before any per-route `RequirePermission(code)` had a chance to run. Because Hertz's `RouterGroup.combineHandlers` always places group-level `Use()` handlers ahead of a route's own handlers, and `RequestContext.Next` is a forward-only loop, `Authz` always executed with "no permission required yet" on the context and always took its no-op branch — silently skipping enforcement on **every** protected route in this package (all 19 pre-existing routes, not just the 5 new terminal-user ones). This plan fixed it by moving `Authz(rbacCli)` to run per-route, immediately after `RequirePermission(code)`, on every route. **If you are upgrading an existing deployment past this plan, be aware:** RBAC permission checks that were previously inert (any authenticated user could call any protected route regardless of assigned permissions) now actually enforce. Review your Casbin policies before rolling this out, or users without the right permission grants will start seeing `403 permission_denied` on routes that previously "worked."
- **New required config fields (`grpc.terminal_user`, `grpc.authority`) break boot on upgrade without a config change.** Both fields are enforced by an unconditional `Validate()` guard, and `conf.Load` fully replaces `Default()` rather than merging into it, so an existing `conf.yaml` written before these fields existed won't pick up their defaults. An upgrade that doesn't also update `conf.yaml` fails to boot with `grpc.terminal_user.service_name is empty` (or the `grpc.authority` equivalent) instead of starting up without the newer feature. This is the intended, by-design tradeoff (fail loud at startup over a silently misconfigured client) — see the [gRPC Connection](#grpc-connection) upgrade note above before rolling out either field to a running deployment.
- **New permission codes for admin-initiated password reset and audit-log read.** `POST /api/v1/terminal-users/:uid/reset-password` is gated by the `terminal_user:password-reset` permission code, and `GET /api/v1/terminal-users/:uid/audit-logs` by `terminal_user:audit-log:read` — both routed through the per-route `Authz(rbacCli)` + `RequirePermission(code)` pair described above, same as the pre-existing `terminal_user:*` codes, and both calling `user-kitex` via the same `grpc.terminal_user` client (see [Configuration](#grpc-connection)). Review your Casbin policies to grant these two codes to the appropriate admin roles before relying on either endpoint. Note the audit-log endpoint's query scope: it only ever returns records for the `:uid` in the path (`ActorUid` is pinned server-side from the path param, not from a request body/query field) — there is no cross-user or unscoped audit-log query capability in this package.

## Related Templates

- **base-hertz** - Basic HTTP service (no RBAC)
- **ratelimit-hertz** - HTTP service with rate limiting execution
- **admin-services-kitex** - Authority service (RBAC + Rule Center)
- **user-kitex** - End-user account RPC service backing Terminal User Management (`GetUser`, `AdminUnbindProvider`, and the `BanUser`/`UnbanUser`/`ForceLogout`/`ListUsers`/`ListUserIdentities` RPCs this package's terminal-user routes call)

## License

Part of the ncgo template registry.
