# user-kitex

Official **end-user account** Kitex RPC template — local password
registration/login plus third-party OAuth2/OIDC login (wechat / alipay /
github / google / oidc), and an admin-facing management surface (list/ban/
unban/force-logout/list-identities) for `admin-bff-hertz` (or any RBAC-gated
caller) to drive.

## Use

```bash
ncgo template pull user-kitex
ncgo new user --module github.com/acme/user --kind kitex \
  --template user-kitex --db postgres
```

> The service always owns a PostgreSQL database (`users` + `user_identities`).
> Run `make migrate-up` against the target database after scaffolding.
> OAuth CSRF state and the admin force-logout blacklist are Redis-backed —
> set `redis.enabled: true` and `redis.addr` in `conf.yaml` before exercising
> those RPCs.

### Upgrading an existing generated project

After updating the password reset query template, run `make sqlc` before
`go build` so `ConsumeValidPasswordResetToken` is generated. Custom
implementations of `passwordreset.Repository` must implement the new
`ConsumeValid` method. The `password_reset_tokens` table schema is unchanged,
so this update needs no database migration.

`SQLRepository.ConsumeValid` now returns the consumed token's `UsedAt` value,
matching `MemoryRepository`. The template tests its timestamp mapping; a full
SQL integration test needs a running PostgreSQL instance, which this template's
test suite does not provision.

## Contents

- `idl/user.proto` — `user.v1.UserService`:
  - **Self-service**: Register / Login / OAuthStart / OAuthCallback /
    BindProvider / UnbindProvider / ChangePassword / RequestPasswordReset /
    ConfirmPasswordReset — `RequestPasswordReset` always returns success
    whether or not the identifier matched an account (anti-enumeration);
    `ConfirmPasswordReset` consumes a one-time reset token to set a new
    password.
  - **Admin**: ListUsers / GetUser / BanUser / UnbanUser / ForceLogout /
    ListUserIdentities / AdminUnbindProvider / ResetPassword / ListAuditLogs
- **DDD layers**:
  - `internal/domain/user` — `User`/`Identity` entities, `Repository` port.
  - `internal/application/user` (`usersvc`) — self-service usecases: local
    register/login, OAuth start/callback/bind/unbind.
  - `internal/application/useradmin` (`useradminsvc`) — admin usecases:
    list/get/ban/unban/force-logout/list-identities. `AdminUnbindProvider`
    is deliberately *not* here: its handler delegates to `usersvc`'s
    `UnbindProvider` so the "cannot unbind your only authentication method"
    safety check applies identically to self-service and admin callers.
- **Infrastructure**:
  - `internal/infrastructure/auth` — HS256 JWT (`{uid, roles: ["user"]}`) +
    argon2id password hashing (reused conventions from `rbac-kitex`).
  - `internal/pkg/oauth` — provider-agnostic `Provider`/`Registry`
    abstraction, a Redis-backed `StateStore` for OAuth CSRF state, and five
    adapters: `wechat.go`, `alipay.go`, `github.go`, `google.go`, `oidc.go`.
  - `internal/infrastructure/audit` — the `audit_log` subsystem: a
    `Writer`/`Reader` pair (sqlc-backed plus in-memory test doubles) recording
    login success/failure, identity bind/unbind and password change/reset
    events. Entries are never pruned — no retention policy ships with this
    template, so add one (partition drop or a scheduled `DELETE`) before the
    table grows unbounded in production. *(future work)*
- **Repository** (`internal/repository/user`, `userrepo`) — sqlc-backed
  `user.Repository` implementation.
- `internal/base/server/server.go` wires the pgx pool, sqlc `gen.Queries`,
  `userrepo.New`, an `oauth.Registry` populated only from providers enabled
  in `conf.yaml`, a Redis `oauth.StateStore` + force-logout blacklist,
  `usersvc.New`, `useradminsvc.New`, and `handler.NewUserServiceHandlerImpl`
  onto one Kitex server.

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.

## Data Model

2 tables (Postgres):

| Table | Key Columns |
|---|---|
| `users` | id, username (unique, nullable for OAuth-only accounts), password_hash (nullable), nickname, avatar, email, phone, status int (1=enabled, 0=banned), created_at, updated_at |
| `user_identities` | id, user_id (FK), provider, provider_user_id, raw_profile_json — **UNIQUE(provider, provider_user_id)** |

An OAuth-only user (no local password) is created on first successful
`OAuthCallback` with an empty `username`/`password_hash`; a subsequent
`BindProvider` call links additional providers to an already-authenticated
account.

## Configuration (`conf.yaml`)

```yaml
oauth:
  wechat:
    enabled: false
    client_id: ""
    client_secret: ""
    redirect_url: ""
  alipay:
    enabled: false
    client_id: ""      # Alipay app_id
    client_secret: ""  # Alipay RSA2 private key (signing is a documented seam — see below)
    redirect_url: ""   # forwarded as redirect_uri on the authorize URL; effective (not merely documentary)
  github:
    enabled: false
    client_id: ""
    client_secret: ""
    redirect_url: ""
  google:
    enabled: false
    client_id: ""
    client_secret: ""
    redirect_url: ""
  oidc:
    enabled: false
    client_id: ""
    client_secret: ""
    redirect_url: ""
    auth_endpoint: ""
    token_endpoint: ""
    user_info_endpoint: ""
redis:
  enabled: false
  addr: "127.0.0.1:6379"
```

Set `enabled: true` and fill in the provider's credentials for every
third-party login you want to expose; leave the rest `enabled: false`.

> ⚠️ All five provider adapters (wechat/alipay/github/google/oidc) are
> generated into every project; unused providers are disabled via
> `conf.yaml`'s `enabled: false`, not omitted from generation.
> Generation-time selection (`ncgo new --var providers=github,google`
> skipping unselected adapter files entirely) depends on upstream `ncgo`
> CLI support, tracked separately in the `ncgo` repository — this template
> will adopt it in a follow-up revision once available.

## Seams (documented TODO)

- **`uid` trust boundary (BindProvider/UnbindProvider)**: these RPCs trust
  the caller-supplied `uid` field as-is and perform no token verification of
  their own. The caller (a future BFF/gateway) MUST extract `uid` from a
  verified JWT and never forward a client-supplied `uid` directly — doing so
  is an authorization bypass, since any caller could then bind/unbind
  providers for an arbitrary other user's account. See the `uid` field
  comments on `BindProviderReq`/`UnbindProviderReq` in `idl/user.proto`.
- **`OAuthCallback` is not transactional**: the create-user + create-identity
  sequence for a brand-new OAuth user is two separate writes, not wrapped in
  a DB transaction. A failure between them can leave an orphaned user row
  with no bound identity (contained, cleanup-able — not a security issue).
  Tracked as a follow-up, not fixed in this revision.
- **Alipay RSA2 signing**: production Alipay calls must be RSA2-signed per
  Alipay's Open Platform spec; `AlipayConfig.PrivateKey` is wired through
  but signing itself is out of scope for this template revision (interface
  contract only — see `internal/pkg/oauth/alipay.go`). `AlipayConfig.RedirectURL`,
  by contrast, IS effective — it's forwarded as-is into `AuthURL`'s
  `redirect_uri` param.
- **Force-logout enforcement**: `ForceLogout` writes a revocation marker to
  Redis; wiring the JWT-verifying middleware in `admin-bff-hertz`/
  `base-hertz` to consult the same key is a follow-up, not part of this
  template.
- **RS256 / JWKS**: HS256 with a configured secret is the v1 default,
  matching `rbac-kitex`.
- **OTel observability**: enabled when `jaeger` config is present (base
  wiring, same as `rbac-kitex`/`base-kitex`).
