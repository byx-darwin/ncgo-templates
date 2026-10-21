# user-bff-hertz

Application-account HTTP gateway for `user-kitex`: phone/email verification codes and account passwords, persistent sessions, and configured OAuth providers. There is no username registration or login endpoint. Administrator operator authentication belongs to `admin-bff-hertz`.

Clients send their configured `X-Client-ID` on requests. Public JSON requests may supply `client_id` instead; if both are present they must match. Protected requests require both the header and `Authorization: Bearer <access_token>`. Every protected request verifies the persistent session through `AccountVerify`; local JWT settings cannot bypass this check. Request-body user IDs, access tokens, IP addresses and user agents never establish the acting identity.

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

## Configuration

Point `rpc.user_service` at `user-kitex` and `rpc.rule_center` at the rule service. The account environment, enabled client methods, provider instances and encrypted credentials are controlled by `user-kitex` and the administrator configuration page. Changes apply without restarting the BFF.

OAuth exchange grants expire after 60 seconds and are stored only as hashes in the account service PostgreSQL database. The BFF does not use Redis for account OAuth exchange and never stores token or proof material. Configure `oauth_redirect.success_url` to a frontend URL exactly allowlisted on each OAuth instance. Callback destinations come from the server's consumed OAuth state; a caller-supplied redirect URL is ignored. Configure CORS origins for your clients and include `X-Client-ID` in any custom `allow_headers` list.

## API routes

All responses use the usual response envelope.

| Method | Path | Authentication / behavior |
|---|---|---|
| GET | `/auth/methods` | Client header; discover available methods |
| POST | `/auth/code` | `kind`, `identifier`, `purpose`; bearer session required for reauth/bind/replace |
| POST | `/auth/login` | `kind: phone/email`, `mode: code/password`, `identifier`, `credential`; returns access/refresh tokens |
| POST | `/auth/refresh` | `refresh_token`; rotates opaque refresh credentials |
| POST | `/auth/logout` | Bearer session; revokes the current session |
| GET / PATCH | `/auth/me` | Bearer session; read profile or update `nickname` and `avatar` |
| POST | `/auth/reauth` | Bearer session; `mode`, `kind`, `identifier`, `credential`; returns a short-lived proof |
| POST | `/auth/contact` | Bearer session; `operation: bind/replace/unbind`, `kind`, `identifier`, target `code`, existing-identity `proof` |
| POST | `/auth/password` | Bearer session; `new_password` plus `old_password` for changes, or contact-code reauth `proof` for initial setup |
| POST | `/auth/password-reset/request` | `kind`, `identifier`; same public response for known/unknown accounts |
| POST | `/auth/password-reset/confirm` | `kind`, `identifier`, `code`, `new_password`; resets an existing account |
| GET / POST | `/auth/oauth/:config/start` | Returns `redirect_url`, `state`, `flow`, `app_id`, and provider-specific `auth_info`; `purpose` defaults to login, bind/reauth/replace require bearer session and bind/replace require an existing-identity proof |
| GET / POST | `/auth/oauth/:config/callback` | `state`, provider `code` (Alipay also accepts `auth_code`); login/reauth GET redirects with an opaque exchange code, POST returns that code; bind/replace return completion status |
| POST | `/auth/oauth/exchange` | Client-bound `code`; authority consumes once, creates credentials only at exchange, and rechecks policy; login returns session tokens, reauth returns `{proof,purpose}` |

Supported code purposes are `login`, `reset`, `reauth`, `bind`, and `replace`. To establish the first password, send a `reauth` code to an already bound phone/email, exchange it through `/auth/reauth`, and pass the returned proof to `/auth/password`. Changing an existing password requires the old password.

OAuth browser callbacks recover the client and acting user from single-use server state, so they need no bearer header. Native POST callbacks may send `X-Client-ID`; a mismatch with state is rejected. When `code` and `auth_code` are both supplied, they must be identical; conflicting aliases are rejected before the RPC consumes OAuth state. The callback URL contains only the opaque exchange code. Sessions and reauthentication proofs are created only when the grant is redeemed. Callback and exchange responses send `Cache-Control: no-store` and `Referrer-Policy: no-referrer`. Alipay app clients use the signed `auth_info` start field to launch the SDK authorization flow, then POST its authorization code with the original state.

The HTTP login/reset routes also apply configured coarse rate limits. `user-kitex` enforces shared PostgreSQL subject/IP limits, five-attempt OTP consumption, client policy, identity uniqueness, session rotation and revocation. Disabling login channels stops new logins/binds while existing sessions retain refresh access until revoked or expired.

## Related templates

- `user-kitex`: application-account authority and provider adapters.
- `admin-bff-hertz`: administrator JWT/RBAC, application-user management and authentication configuration APIs.

## License

Part of the ncgo template registry.
