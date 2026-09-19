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
2. **base-hertz `RateLimit`** — **keep, do not remove** (revised 2026-09-19 during
   execution — see "Design rejected during execution: removing base-hertz's
   RateLimit code" below). Document the limitation in the README instead.
3. **Idempotency (all 3 packages)** — per-group single registration (revised
   2026-09-19 after discovering dual registration's flaw — see "Design rejected during
   planning" below): move the registration off the shared `api` group and onto
   whichever subgroup actually owns each route (`protected` after `JWTAuth`, plus a
   public subgroup for packages that have public mutating routes), so each request
   only ever runs Idempotency once, with whatever identity is genuinely available for
   that route.

### Design rejected during planning: dual registration

The design initially approved (2026-09-19) kept `api.Use(Idempotency)` unchanged and
added a second `protected.Use(Idempotency)` after `JWTAuth`. Rejected before
implementation because it has a real correctness defect: the outer (`api`-group)
instance still runs for every protected request too (Hertz subgroups inherit their
parent's middleware), always scoping by `ip:`/`ak:` since it runs pre-`JWTAuth`. Two
different JWT-authenticated users behind the same IP who happen to reuse the same
client-supplied `X-Idempotency-Key` value would collide on that outer check and never
reach the inner, `Uid`-aware check — the outer instance's coarser scope shadows the
inner one instead of being superseded by it. Moving to one registration per route
group (instead of layering a second on top) avoids both this shadowing and the doubled
store round-trip.

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

### 2. base-hertz: keep `RateLimit` code, document the limitation

**Superseded during execution (2026-09-19) — see "Design rejected during execution"
below.** Originally planned as a deletion; reverted before merge. No code change in
this section; `internal_pkg_middleware_rate_limit_go.yaml`,
`internal_pkg_middleware_rate_limit_test_go.yaml`, and `internal_base_conf_conf_go.yaml`
are untouched by this issue. Only the README gets a new note (see Documentation below)
explaining why `RateLimit` code ships in a template whose own docs say it has no rate
limiting.

### Design rejected during execution: removing base-hertz's `RateLimit` code

The Task 2 implementer (dispatched to delete `base-hertz`'s `RateLimit` middleware and
config, per the original decision above) found that the deletion breaks `go build` for
any `base-hertz` project generated with `--db`. Root cause: `ncgo` itself (a separate
repository, `github.com/byx-darwin/ncgo`) ships a built-in default hertz layout
(`internal/assets/_data/hertz/layout.yaml`) that unconditionally generates
`internal/repository/rate_limit_rule.go` (plus its db schema/query/migration/seed
files) for any hertz template that doesn't set `skip_default_templates: true` —
`base-hertz` doesn't set it, and has no local override for that specific path. That
embedded default file references `conf.RateLimitConfig`/`conf.RateLimitRuleConfig`
directly, so it fails to compile once those types are removed from `base-hertz`'s own
`conf.go`.

In other words: `base-hertz`'s local `RateLimit` middleware/config were not simply
leftover copy-paste from `ratelimit-hertz` — they exist (at least in part) to satisfy a
compile-time dependency from `ncgo`'s shared default DB-repository scaffold, which this
repository (`ncgo-templates`) doesn't control. Removing them without also either (a)
patching `ncgo`'s embedded layout in a separate PR to that repository, or (b) adding
`skip_default_templates: true` to `base-hertz/template.yaml` and fully re-validating
everything that flag drops (unknown blast radius — it may skip far more than the
rate-limit-specific files), is out of scope for this issue and this repository.

Decided with the repo owner (2026-09-19): keep `base-hertz`'s `RateLimit` code as-is.
Document the limitation in the README (Task 5) instead of removing it. No follow-up
issue filed against `ncgo` as part of this change — left to the repo owner's
discretion outside this workflow.

### 3. Idempotency: per-group single registration (all 3 packages)

**base-hertz, ratelimit-hertz** (`internal/router/service.go`): these packages have no
public mutating (POST/PUT/PATCH/DELETE) routes — the only public route is
`api.GET("/health", ...)`, and Idempotency's default method set
(`POST,PUT,PATCH,DELETE`) already skips GET. So the fix is a straight move, not an add:

```go
api := h.Group("/api/v1")
if cfg.Auth.Signature.Enabled {
    api.Use(middleware.SignatureAuth(cfg.Auth.Signature, resolver))
}
// (Idempotency no longer registered here)

api.GET("/health", resourceHandler.Health)

protected := api.Group("")
protected.Use(middleware.JWTAuth(cfg.Auth.Token))
if cfg.Idempotency.Enabled {
    protected.Use(middleware.Idempotency(cfg.Idempotency))
}
```

**admin-bff-hertz** (`internal/router/adminbffservice.go`): has two public mutating
routes, `POST /auth/login` and `POST /auth/refresh`, already declared on their own
existing subgroup (`auth := api.Group("/auth")`) — no new subgroup needed, just move
the registration onto that subgroup and onto `protected`:

```go
api := h.Group("/api/v1")
if cfg.Auth.Signature.Enabled {
    api.Use(middleware.SignatureAuth(cfg.Auth.Signature, resolver))
}
// (Idempotency no longer registered here)

auth := api.Group("/auth")
if cfg.Idempotency.Enabled {
    auth.Use(middleware.Idempotency(cfg.Idempotency))
}
auth.POST("/login", authHandler.Login)
auth.POST("/refresh", authHandler.Refresh)

protected := api.Group("")
protected.Use(middleware.JWTAuth(cfg.Auth.Token))
if cfg.Idempotency.Enabled {
    protected.Use(middleware.Idempotency(cfg.Idempotency))
}
```

Each request now runs Idempotency exactly once, through whichever group it actually
belongs to. `/auth/login`/`/auth/refresh` keep `ak:`/`ip:`-scoped protection (no
`Uid` — they're pre-authentication by definition); every `protected` route gets
`idempotencyKey()`'s full precedence (`ak_user_uuid:` > `user_uuid:` > `ak:` > `ip:`)
since both `AK` (from `SignatureAuth`, preserved through `TokenAuth`) and `Uid` (from
`JWTAuth`) are populated by the time it runs.

No changes to `idempotency.go` itself.

### 4. Tests

Add router-level tests (real Hertz engine, not hand-constructed context — matching the
verification method #73's Context used and the pattern #72's review Minor-1 asked
for), one per package:

- **ratelimit-hertz**: a request through the full chain to a `protected` route with a
  valid JWT should reach `RateLimit("post_auth", ...)` with `Uid` populated in the
  `ratelimit.Lookup` — assert via a resolver/store test double that records the
  `Lookup.UserUUID` it received is non-empty.
- **base-hertz / ratelimit-hertz / admin-bff-hertz**: two requests to a `protected`
  POST route, same `X-Idempotency-Key` header value, but signed as two *different*
  users (different `uid` claims) — must NOT collide (both must succeed independently).
  Before the fix (Idempotency only reachable pre-`JWTAuth`, scoped by `ip:`), both
  requests share the same test-client IP and the same key, so the second would be
  wrongly rejected/replayed as a duplicate of the first. After the fix, each gets its
  own `user_uuid:`-scoped key. This directly exercises the reachability bug without
  needing to inspect the unexported `idempotencyKey()`'s output.
- **admin-bff-hertz only**: `POST /auth/login` with an `X-Idempotency-Key` must still
  get idempotency protection (two identical requests → second one replays/dedupes),
  confirming the move to the `auth` subgroup didn't drop public-route coverage.

These are regression tests against reordering, not unit tests that assume the order.

### 5. Documentation

Replace the three README notes #72 left pointing at #73 as unresolved, with the final
state:

- `base-hertz/README.md:70` — update to state `RateLimit` middleware/config ship in
  this template but are never wired into `server.go`/router (kept only to satisfy a
  compile-time dependency from `ncgo`'s shared default DB-repository scaffold — see
  the design doc's "Design rejected during execution" note); this template still has
  no user-facing rate limiting (see `ratelimit-hertz` for that). `Idempotency` now runs
  once, inside the `protected` group, after both `SignatureAuth` (api-level) and
  `JWTAuth` have run, so it reaches the full precedence (`ak_user_uuid:` > `user_uuid:`
  > `ak:` > `ip:`).
- `ratelimit-hertz/README.md:270` — update to state final registration order and that
  all branches (`ak:`, `ak_user_uuid:`, `user_uuid:`, `ip:`, and both `RateLimit`
  phases) are now reachable as designed.
- `admin-bff-hertz/README.md:371` — same update as ratelimit-hertz for `Idempotency`
  (now split: `auth` subgroup for public login/refresh, `protected` group for
  everything else); note `RateLimit` only exists as the already-correct
  `password_change` phase (no `pre_auth`/`post_auth` in this package).

## Testing / Verification

- `go build ./...` + `go vet ./...` on a project generated from each of the 3 templates
  (hermetic, memory backend, and `--db` for base-hertz) — must stay green.
- Each package's existing `e2e_test.sh` — must stay green.
- New router-level tests above — RED before the reposition/per-group-registration
  changes, GREEN after.

## Out of scope

- Any change to `admin-bff-hertz`'s `password_change` `RateLimit` call — already
  correctly positioned.
- Any change to `idempotencyKey()`'s or `rateLimitAppKey()`/`rateLimitUserUUID()`'s
  scope-precedence logic — only registration position changes.
- Removing base-hertz's `RateLimit` middleware/config — reverted during execution
  (2026-09-19); see "Design rejected during execution" above. Any fix belongs in
  `github.com/byx-darwin/ncgo` (a different repository), not here.

