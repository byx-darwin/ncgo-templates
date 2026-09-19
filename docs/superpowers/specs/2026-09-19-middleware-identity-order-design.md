# Middleware Registration Order vs. Identity Availability (Issue #73)

## Context

While fixing #72 (wiring `SignatureAuth`'s verified app key into `Claims.AK`), code
review found a structural issue distinct from #66/#72: `RateLimit` and `Idempotency`
middleware are registered *before* the request's identity is known in several places,
making some of their own identity-scoped branches unreachable — not because the
identity fields are wrong, but because of registration order.

This design re-verifies the registration order against the current codebase (some
facts changed since #73 was filed on 2026-09-15 — see "What changed since filing"),
and specifies the fix per middleware per package.

## Current state (re-verified 2026-09-19)

| Middleware | Package | Registration point | Reachability |
|---|---|---|---|
| `Idempotency` | base-hertz, ratelimit-hertz, admin-bff-hertz | `api.Use(...)`, before `protected.Use(JWTAuth)` | `ak:` branch live (SignatureAuth already ran on `api` group); `ak_user_uuid:`/`user_uuid:` branches dead (`Uid` always empty) |
| `RateLimit("pre_auth"/"post_auth")` | ratelimit-hertz | `h.Use(...)` engine-level in `server.go`, before `router.RegisterServiceRoutes()` (which runs `SignatureAuth`/`JWTAuth`) | Both phases run pre-identity; `post_auth` name doesn't match actual position |
| `RateLimit("pre_auth"/"post_auth")` | base-hertz | Middleware function + config fields (`RateLimitConfig`, `PreAuth`, `PostAuth`) exist and are validated, but **never called** anywhere in generated `server.go`/router code | Fully dead — not a registration-order bug, a never-wired one |
| `RateLimit("password_change")` | admin-bff-hertz | Per-route, on `terminalUsers.POST("/:uid/reset-password", middleware.RateLimit("password_change", ...), ...)`, inside `protected` group (after `JWTAuth`) | Already correct — `Claims.AK`/`Uid` reachable here |

### What changed since filing

Issue #73's Context (written 2026-09-15) said admin-bff-hertz "doesn't wire `RateLimit`
into its router at all". That's now out of date: #71 (forgot-password self-reset,
merged 2026-09-18/19) added the `password_change` phase call above, correctly
positioned post-auth. No action needed for that call site.

Separately, this review found base-hertz ships a fully dead `RateLimit` middleware +
config that #73's Context didn't mention (it only discussed ratelimit-hertz's and
admin-bff-hertz's `RateLimit`). base-hertz's own README/template.yaml explicitly state
it does **not** include rate limiting ("For services that need rate limiting, use
`ratelimit-hertz` instead") — so this is leftover code contradicting the template's
documented feature set, not an intentional extension point.

## Decisions

Confirmed with the repo owner (2026-09-19):

1. **ratelimit-hertz `RateLimit`** — reposition `post_auth` to actually run post-auth.
   `pre_auth` stays engine-level (IP-based DoS mitigation before any routing work).
2. **base-hertz `RateLimit`** — remove entirely (dead code contradicting the template's
   own "no rate limiting" documentation).
3. **Idempotency (all 3 packages)** — dual registration: keep the existing `api`-group
   registration (serves AK/IP-scoped signature callers and public routes), add a
   second registration inside the `protected` group after `JWTAuth` (makes the
   `Uid`-scoped branches reachable for authenticated routes).

## Design

### 1. ratelimit-hertz: reposition `post_auth`

Follow the existing pattern admin-bff-hertz already uses for `password_change`: thread
the `*ratelimit.Resolver` into the router registration function instead of building it
only in `server.go`.

- `internal/base/server/server.go`: keep `h.Use(middleware.RateLimit("pre_auth", cfg.RateLimit, cfg.RateLimit.PreAuth, rlResolver))`. Remove the `post_auth` `h.Use(...)` call. Pass `rlResolver` into `router.RegisterServiceRoutes(h, rlResolver)`.
- `internal/router/service.go`: accept `resolver *ratelimit.Resolver` as a parameter. After `protected := api.Group(""); protected.Use(middleware.JWTAuth(cfg.Auth.Token))`, add:
  ```go
  if cfg.RateLimit.Enabled {
      protected.Use(middleware.RateLimit("post_auth", cfg.RateLimit, cfg.RateLimit.PostAuth, resolver))
  }
  ```

No changes to `rate_limit.go` itself — `rateLimitAppKey`/`rateLimitUserUUID` already
read `Claims` correctly; they just weren't being invoked at a point where `Claims` was
populated.

### 2. base-hertz: remove dead `RateLimit` code

Delete:
- `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`
- `RateLimitConfig` type, `RateLimit` field, `PreAuth`/`PostAuth` fields, and their
  validation branches (`validateRateLimitPhase` calls) from
  `internal_base_conf_conf_go.yaml`
- The `rate_limit:` config block from `conf_dev_conf_yaml.yaml`

Verify after removal: `grep -rn "RateLimit" base-hertz/hertz-template/` returns nothing,
and a generated base-hertz project still builds (`go build ./...`) and passes
`go vet ./...`.

### 3. Idempotency: dual registration (all 3 packages)

In each package's router file (`internal/router/service.go` for base-hertz /
ratelimit-hertz, `internal/router/adminbffservice.go` for admin-bff-hertz), after
`protected.Use(middleware.JWTAuth(cfg.Auth.Token))`, add:

```go
if cfg.Idempotency.Enabled {
    protected.Use(middleware.Idempotency(cfg.Idempotency))
}
```

The existing `api.Use(middleware.Idempotency(cfg.Idempotency))` registration is
unchanged. `idempotencyKey()` already handles precedence correctly
(`ak_user_uuid:` > `user_uuid:` > `ak:` > `ip:`); running the middleware twice for a
protected request creates two independently-tracked keys (one derived pre-JWT with
whatever identity was available then, one post-JWT with `Uid` now available) from the
same `X-Idempotency-Key` header value — both must acquire for the request to proceed,
both get marked complete on success. This is a deliberate small redundancy (extra
store round-trip for protected routes) traded for correctness without restructuring
the handler pipeline.

No changes to `idempotency.go` itself.

### 4. Tests

Add router-level tests (real Hertz engine, not hand-constructed context — matching the
verification method #73's Context used and the pattern #72's review Minor-1 asked
for), one per package:

- **ratelimit-hertz**: a request through the full chain to a `protected` route with a
  valid JWT should reach `RateLimit("post_auth", ...)` with `Uid` populated in the
  `ratelimit.Lookup` — assert via a resolver/store test double that records the
  `Lookup.UserUUID` it received is non-empty.
- **base-hertz / ratelimit-hertz / admin-bff-hertz**: a request through the full chain
  to a `protected` POST route with a valid JWT and an `X-Idempotency-Key` header should
  produce an idempotency store key containing the `user_uuid:`/`ak_user_uuid:` scope
  (not just `ak:`/`ip:`) — assert via a store test double or by inspecting the key
  format if the store exposes it in test builds.

These are regression tests against reordering, not unit tests that assume the order.

### 5. Documentation

Replace the three README notes #72 left pointing at #73 as unresolved, with the final
state:

- `base-hertz/README.md:70` — update to state `RateLimit` was removed entirely (no
  rate limiting in this template, see `ratelimit-hertz`); `Idempotency` now reaches
  `ak_user_uuid:` via dual registration.
- `ratelimit-hertz/README.md:270` — update to state final registration order and that
  all branches (`ak:`, `ak_user_uuid:`, `user_uuid:`, `ip:`, and both `RateLimit`
  phases) are now reachable as designed.
- `admin-bff-hertz/README.md:371` — same update as ratelimit-hertz for `Idempotency`;
  note `RateLimit` only exists as the already-correct `password_change` phase (no
  `pre_auth`/`post_auth` in this package).

## Testing / Verification

- `go build ./...` + `go vet ./...` on a project generated from each of the 3 templates
  (hermetic, memory backend) — must stay green after removing base-hertz's RateLimit
  fields (config struct shape changes).
- Each package's existing `e2e_test.sh` — must stay green.
- New router-level tests above — RED before the reposition/dual-registration changes,
  GREEN after.
- `grep -rn "RateLimit" base-hertz/` — zero hits outside this design doc / commit
  history after removal.

## Out of scope

- Any change to `admin-bff-hertz`'s `password_change` `RateLimit` call — already
  correctly positioned.
- Any change to `idempotencyKey()`'s or `rateLimitAppKey()`/`rateLimitUserUUID()`'s
  scope-precedence logic — only registration position changes.
- Filing a separate issue for base-hertz's dead code — folded into #73 per repo
  owner's decision (2026-09-19), since it was discovered during this issue's
  re-verification.
