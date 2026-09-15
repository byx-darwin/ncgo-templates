# user-bff-hertz

Official **end-user BFF (Backend for Frontend)** Hertz HTTP template — a login gateway in front of `user-kitex`, supporting local username/password auth and third-party OAuth2/OIDC login, with one-time-code JWT exchange and account binding/unbinding.

## Overview

`user-bff-hertz` sits in front of `user-kitex` (the authority RPC service for end-user accounts) and exposes an HTTP surface for browser/mobile clients:

- **Local auth** — username/password register + login, delegated to `user-kitex`.
- **OAuth2/OIDC login** — start/callback flow against third-party providers, brokered through `user-kitex`.
- **One-time code → JWT exchange** — the OAuth callback redirects the browser with a short-lived opaque code instead of the JWT itself; the frontend then calls `POST /auth/oauth/exchange` server-to-server (or from a script, never left sitting in browser history/referrer headers/logs) to redeem it for the real token.
- **Account binding** — an already-authenticated user can bind/unbind additional third-party identities to their account.

**Architecture:**
```
Client → user-bff-hertz (BFF) → user-kitex (Authority)
         - CORS                  - Local register/login
         - JWT validation        - OAuth start/callback/bind (state carries uid+purpose)
         - Idempotency           - RuleService (rate limit rules, via rule-center)
         - Rate limit
```

### Why a one-time code, not a direct JWT redirect?

After a successful OAuth callback, `user-bff-hertz` cannot safely hand the JWT back to the browser via a `302` redirect query parameter — URLs land in browser history, server access logs, and `Referer` headers. Instead:

1. `GET /auth/oauth/:provider/callback` exchanges the provider's code with `user-kitex`, receives a JWT, stores it in `oauthcode.Store` (Redis-backed, short TTL) under a freshly generated one-time code, and redirects the browser to `oauth_redirect.success_url?code=<one-time-code>`.
2. The frontend immediately calls `POST /auth/oauth/exchange` with that code. The store consumes (deletes) it on first read and returns the JWT. A second exchange attempt with the same code fails.

## Quick Start

```bash
# 1. Scaffold the project from this template package
ncgo new user-api --module github.com/acme/user-api --kind hertz \
  --template-dir /path/to/ncgo-templates/user-bff-hertz

cd user-api

# 2. Populate kitex_gen/ — this template ships its RPC client IDLs under
#    idl/ but does NOT vendor generated client code; both of the following
#    are required before the project builds:
ncgo add kitex-client user --service UserService --idl idl/user.proto
ncgo add kitex-client rulecenter --service RuleService --idl idl/rule_center.proto

# NOTE: the FIRST `ncgo add kitex-client` above prints a
# `go mod tidy failed: ... Repository not found` error. This is expected and
# harmless — internal/base/server/server.go imports BOTH generated client
# packages from the moment the template is rendered, so the internal tidy that
# runs after the first command cannot resolve the second package yet. The user
# client is still written correctly (check kitex_gen/api/user/v1/ and
# pkg/client/user/). Only the second command's exit status, and step 3's
# `go mod tidy`, actually indicate success or failure.

# 3. Resolve module dependencies pulled in by the generated clients
go mod tidy

# 4. Build
go build ./...
```

> `ncgo new --template user-bff-hertz` (pulling from a published registry, once this
> package is published there) works the same way — Steps 2-4 are unaffected by how the
> template package itself was obtained.

## Required Upstream Configuration

`conf/dev/conf.yaml` (and any other environment config) must point at real running instances of `user-kitex` and `rule-center`, and must share `user-kitex`'s JWT signing key:

```yaml
rpc:
  user_service:
    service_name: "userservice"
    host_ports:
      - "127.0.0.1:8888"   # user-kitex
  rule_center:
    service_name: "rulecenterservice"
    host_ports:
      - "127.0.0.1:8889"   # rule-center

# auth.token.signing_key MUST match user-kitex's own signing key exactly —
# user-bff-hertz only verifies JWTs, it never issues them. user-kitex signs
# with HS256 using this same secret (see user-kitex's own conf_dev.yaml).
auth:
  token:
    enabled: true
    header: "Authorization"
    signing_key: "dev-secret-change-me"

oauth_code:
  ttl_seconds: "60s"

# Where the browser is redirected to after each OAuth flow completes.
# Replace with real frontend URLs in every non-dev environment.
oauth_redirect:
  success_url: "http://localhost:3000/auth/callback"
  bind_success_url: "http://localhost:3000/settings/connections"
  error_url: "http://localhost:3000/auth/error"
```

`rate_limit` and `idempotency` are configured the same way as other ncgo Hertz templates; see `conf/dev/conf.yaml` in the rendered project for the full set of keys.

## API Routes

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/ping` | none | Basic connectivity check (generated from `idl/app/*.proto`) |
| POST | `/auth/register` | none | Local register — delegates to `user-kitex` |
| POST | `/auth/login` | none | Local login — returns `{uid, token}` |
| GET | `/auth/oauth/:provider/start` | none | Begin login-flow OAuth redirect |
| GET | `/auth/oauth/:provider/callback` | none | Complete login-flow OAuth redirect; redirects browser with a one-time code |
| POST | `/auth/oauth/exchange` | none | Redeem the one-time code from the callback redirect for the JWT |
| GET | `/auth/oauth/:provider/bind-start` | JWT | Begin bind-flow OAuth redirect for the authenticated user |
| GET | `/auth/oauth/:provider/bind-callback` | none* | Complete bind-flow OAuth redirect |
| DELETE | `/auth/oauth/:provider/bind` | JWT | Unbind a third-party identity from the authenticated user |

\* `bind-callback` itself carries no `Authorization` header (it's a browser redirect from the OAuth provider) — the identity being bound is recovered from the OAuth `state` value that `bind-start` minted from the caller's JWT `uid`, not from anything supplied in the callback request itself.

`POST /auth/register` also runs through the `Idempotency` middleware when `idempotency.enabled: true`; both `/auth/register` and `/auth/login` run through `RateLimit` (`pre_auth` / `post_auth` phases respectively).

> **Client contract:** while `idempotency.enabled: true` (the shipped `conf/dev/conf.yaml` default), every `POST /auth/register` request **must** carry an `X-Idempotency-Key` header — the middleware rejects a request without one with `400 {"code":10203,"msg":"idempotency_key_missing"}` before the handler runs. Set `idempotency.enabled: false`, or add `/auth/register` to `idempotency.skip_paths`, if you do not want that requirement.

## Seams

- **Issue #66 — JWT `Claims` field mismatch (resolved).** `base-hertz`/`admin-bff-hertz`/`ratelimit-hertz` previously defined `Claims{UserID, UUID, AK, Roles}`, decoding an empty identity from every real `user-kitex`/`rbac-kitex`-issued token (which only ever signs `{uid, roles}`). All three packages have since been fixed to use `Claims{Uid, AK, Roles}`, matching the issuer schema. This package's own `internal/pkg/middleware/token.go` still defines its **own** `Claims{Uid, Roles}` shape rather than reusing `admin-bff-hertz`'s `Claims` type — that remains a package-local choice (no `AK`/API-key path here), not a bug workaround.
- **`admin-bff-hertz` terminal-user-management integration is out of scope here.** Giving admin operators the ability to manage end-user accounts (the ones this package's `user-kitex` backend owns) through `admin-bff-hertz` is a separate, not-yet-started body of work (Plan 3). `user-bff-hertz` and `admin-bff-hertz` do not currently share code or wiring beyond both being ncgo Hertz templates.

## Related Templates

- **user-kitex** — the authority RPC service this template is a gateway for (local auth, OAuth brokering, account binding, state-carries-uid OAuth state store).
- **admin-bff-hertz** — the separate admin-facing BFF (JWT + RBAC), not integrated with `user-kitex` end-user accounts (see Seams above).
- **base-hertz** — the basic HTTP service template this one is built on.

## License

Part of the ncgo template registry.
