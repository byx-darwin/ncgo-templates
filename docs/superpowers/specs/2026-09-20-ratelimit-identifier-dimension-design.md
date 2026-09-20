# Ratelimit Identifier Dimension — Design

- Issue: #78 — fix(ratelimit): KeyBy has no identifier dimension, only IP
- Status: Approved
- Mode: standard (gf-workflow)

## Context

Discovered during Issue #71 (forgot-password self-reset) review. The design
called for `/password-reset/request` rate limiting keyed by IP + identifier
(email/phone), but the ratelimit infrastructure's `Lookup`/`BuildKey`
(`internal/pkg/ratelimit`) only supports
`ak_user_uuid`/`user_uuid`/`ak`/`path`/`method_path`/`ak_path`/`ak_method_path`/`ip`
— no identifier dimension exists at all.

As implemented, `password_reset_request`/`password_reset_confirm` are keyed
by IP only (5/hour and 10/hour respectively). Simple IP rotation trivially
bypasses per-account throttling — not just for password-reset, but for any
future endpoint that would want identifier-scoped rate limiting.

`password-reset/request` and `password-reset/confirm` are rate-limited today
via the generic `middleware.RateLimit` wrapper, which runs before the
handler parses the request body. The account identifier (email/phone) only
exists inside the JSON body, so the middleware has no way to see it without
introducing body-peeking.

## Goal

Extend the ratelimit infrastructure to support an identifier-based key
dimension, and use it to add per-account throttling to
`password_reset_request`/`password_reset_confirm`, without weakening or
touching the existing IP-based coarse limiting.

## Chosen Approach: Two-Phase Limiting (Approach C)

Three approaches were discussed:

- A. Body pre-read in middleware (peek + re-buffer the body before handler
  parses it).
- B. Move rate limiting entirely into the handler (drop the middleware for
  these two routes).
- C. **Two-phase limiting**: keep the existing middleware-level IP-only
  coarse limiting completely unchanged, and add a second, independent
  identifier-scoped fine-grained check inside the handler, after the body
  has been parsed.

**Approach C was selected.** It requires zero changes to the already-tested
middleware code path (lowest risk), keeps the two concerns (coarse IP flood
protection vs. per-account throttling) explicit and independently tunable,
and avoids introducing a new "peek without consuming the body" mechanism
that doesn't exist anywhere else in the codebase today.

## Design

### 1. `internal/pkg/ratelimit` — `Lookup` / `BuildKey` (core package)

Templates touched (mirrors of the same package, kept in sync):
`user-bff-hertz`, `base-hertz`, `ratelimit-hertz`, `admin-bff-hertz`
(`internal_pkg_ratelimit_resolver_go.yaml`, `internal_pkg_ratelimit_store_go.yaml`).

- `Lookup` gains a new field:

  ```go
  type Lookup struct {
      Service  string
      Phase    string
      AppKey   string
      Method   string
      Path     string
      UserUUID string
      ClientIP string
      Identifier string // new: caller-supplied account identifier (email/phone/etc.)
  }
  ```

  `normalizeLookup` trims `Identifier` like the other string fields.

- `BuildKey` gains two new `keyBy` cases, inserted alongside the existing
  ones, following the exact same "match or fall through to the next
  dimension" pattern already used by `ak_user_uuid`/`ak`/etc.:

  ```go
  case "identifier":
      if lookup.Identifier != "" {
          return joinKeyParts(prefix, "identifier", lookup.Identifier)
      }
  case "ip_identifier":
      if lookup.ClientIP != "" && lookup.Identifier != "" {
          return joinKeyParts(prefix, "ip_identifier", lookup.ClientIP, lookup.Identifier)
      }
  ```

  Existing `keyBy` lists (`["ip"]` etc.) are completely unaffected — no
  behavior change for any phase that doesn't request the new dimensions.

- A new package-level helper is added to avoid duplicating the
  Resolve → NormalizeRule → BuildKey → Store.Allow sequence that today only
  exists inlined inside `middleware.rateLimitWithStore`:

  ```go
  // Check resolves the rule for lookup, builds its counter key, and
  // consults store. It returns (true, nil) when the rule is disabled.
  func Check(ctx context.Context, resolver *Resolver, store Store, cfg conf.RateLimitConfig, lookup Lookup) (bool, error) {
      resolved, err := resolver.Resolve(ctx, lookup)
      if err != nil {
          return false, err
      }
      rule := NormalizeRule(resolved.Rule)
      if !rule.Enabled {
          return true, nil
      }
      key := BuildKey(lookup, rule.KeyBy, cfg.KeyPrefix)
      return store.Allow(ctx, key, rule)
  }
  ```

  The existing middleware (`internal/pkg/middleware/rate_limit.go`) is
  **not** refactored to call `Check` in this change — it keeps its current
  inline implementation untouched, to keep this fix's diff minimal and
  risk-free. `Check` exists purely for the new handler call sites (and is
  available for a future cleanup).

### 2. `internal/base/conf/conf.go` (user-bff-hertz only)

Only `user-bff-hertz` has password-reset routes, so only its `conf.go`
template (`user-bff-hertz/hertz-template/conf.yaml`) changes.

`RateLimitConfig` gains two new phase fields, independent from the existing
`PasswordResetRequest`/`PasswordResetConfirm` (which keep governing the
middleware's IP-only coarse rule, untouched):

```go
type RateLimitConfig struct {
    ... // existing fields unchanged
    PasswordResetRequest           RateLimitPhaseConfig `yaml:"password_reset_request"`
    PasswordResetConfirm           RateLimitPhaseConfig `yaml:"password_reset_confirm"`
    PasswordResetRequestIdentifier RateLimitPhaseConfig `yaml:"password_reset_request_identifier"`
    PasswordResetConfirmIdentifier RateLimitPhaseConfig `yaml:"password_reset_confirm_identifier"`
    ...
}
```

Rationale for separate fields rather than reusing the existing ones with an
implicit "identifier empty → falls back to ip" behavior: the middleware
check and the handler check are two independent judgments with potentially
different thresholds (e.g. IP flood protection could stay generous while
per-account throttling stays tight). Explicit config is easier to review
and tune than relying on `BuildKey`'s fallback semantics for correctness.

Defaults (mirroring the existing password-reset defaults) and
`validateRateLimitPhase` calls are extended for the two new fields at the
same place the existing ones are set up (`NewDefaultConfig`-equivalent
block and the `Validate` method).

### 3. `internal/handler/auth.go` (user-bff-hertz only)

- `AuthHandler` gains three new constructor dependencies:

  ```go
  type AuthHandler struct {
      userCli  userservice.Client
      resolver *ratelimit.Resolver
      store    ratelimit.Store
      cfg      conf.RateLimitConfig
  }

  func NewAuthHandler(userCli userservice.Client, resolver *ratelimit.Resolver, store ratelimit.Store, cfg conf.RateLimitConfig) *AuthHandler
  ```

- `RequestPasswordReset`: after `req` is successfully unmarshalled,
  before calling `h.userCli.RequestPasswordReset`:

  ```go
  lookup := ratelimit.Lookup{
      Phase:      "password_reset_request",
      ClientIP:   requestIP-equivalent(c), // same IP source as middleware
      Identifier: strings.TrimSpace(req.Identifier),
  }
  allowed, err := ratelimit.Check(ctx, h.resolver, h.store, h.cfg, lookup)
  if err != nil {
      // fail-open/closed follows h.cfg.FailOpen, mirroring middleware behavior
  }
  if !allowed {
      response.ErrorCode(c, response.CodeRateLimited)
      return
  }
  ```

- `ConfirmPasswordReset`: identical shape, `Phase: "password_reset_confirm"`,
  `Identifier: strings.TrimSpace(req.Phone)` (the request body has no email
  field; `Phone` is the only stable account identifier available here).

### 4. `internal/router/userbffservice.go` (user-bff-hertz only)

The `NewAuthHandler(...)` call site is updated to pass the already-built
`resolver` (constructed once for the router) plus a new shared
`ratelimit.Store` instance and `cfg.RateLimit`. This store instance is
independent from the one(s) created inside `middleware.RateLimit` closures
— safe, because the key spaces never overlap (`ip:...` vs.
`ip_identifier:...`/`identifier:...`).

### 5. Tests

- `ratelimit` package: table tests for `BuildKey` covering `"identifier"`
  and `"ip_identifier"` (both dimensions present, identifier missing, IP
  missing, dimension absent from `keyBy` list — must fall through
  unaffected).
- `auth.go` handler tests: regression coverage for the acceptance criteria
  — same identifier from different IPs still gets throttled after N
  attempts; different identifiers from the same IP are not cross-throttled
  by the new dimension (existing IP coarse limit is a separate concern and
  keeps applying).

## Backward Compatibility

- `pre_auth`, `post_auth`, `password_change` phases and any other caller of
  `ratelimit.Lookup`/`BuildKey` are untouched: `Identifier` defaults to the
  zero value and no existing `keyBy` list references the two new
  dimensions.
- The middleware code path (`internal/pkg/middleware/rate_limit.go`) is not
  modified at all in this change.

## Out of Scope

- `admin-services-kitex`, `user-kitex`, `rule-center` do not have
  password-reset routes and are not touched beyond keeping the shared
  `ratelimit` package's `Lookup`/`BuildKey` surface identical across
  mirrored templates (for API consistency should they ever gain identifier
  needs of their own).
- No change to the middleware's own coarse IP-limiting logic or its
  existing config fields.
