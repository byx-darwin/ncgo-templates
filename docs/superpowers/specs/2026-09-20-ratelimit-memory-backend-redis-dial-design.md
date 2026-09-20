# Design: memory-backend RateLimit must not dial Redis (Issue #79)

## Classification

Bounded — fix to an existing, well-understood flow in two template files
(`rate_limit.go` + `redis_client.go`), no new subsystem or interface change.

## Problem

`internal/base/conf/conf.go`'s `applyRedisFallbacks()` unconditionally
defaults `c.RateLimit.Redis` from `c.Redis` (itself defaulting to
`127.0.0.1:6379`), regardless of `RateLimit.Backend`. Then
`internal/pkg/middleware/rate_limit.go`'s `rateLimitWithStore()`
unconditionally calls `sharedRedisClient(cfg.Redis)` to build the store —
even when `cfg.RateLimit.Backend == "memory"` — and `ratelimit.NewStore()`
silently discards the client when the backend isn't `"redis"`. Net effect:
any service running `rate_limit.backend: memory` (the default) still opens
and holds an idle Redis connection pool, dialing (and failing, if
unreachable) in the background.

## Scope

Confirmed by reading the template sources that only **`base-hertz`** and
**`ratelimit-hertz`** are affected. `user-bff-hertz` and `admin-bff-hertz`
ship a hardcoded stub `sharedRedisClient` that always returns `nil`
regardless of config, so their rate-limit path is already unconditionally
memory-backed — no bug there.

Sibling middlewares in the same package (`idempotency.go`, `signature.go`)
already gate their `sharedRedisClient(cfg.Redis)` call on
`cfg.Backend == "redis"`. `rate_limit.go` is the one outlier that skipped
this guard — this fix brings it into line with the established pattern,
no new pattern introduced.

## Fix

For both `base-hertz/hertz-template/` and `ratelimit-hertz/hertz-template/`:

1. **`internal_pkg_middleware_rate_limit_go.yaml`** — guard the client
   construction:
   ```go
   var redisClient redis.UniversalClient
   if cfg.Backend == "redis" {
       redisClient = sharedRedisClient(cfg.Redis)
   }
   store = ratelimit.NewStore(cfg, redisClient)
   ```
   (adds `github.com/redis/go-redis/v9` import)

2. **`internal_pkg_middleware_redis_client_go.yaml`** — turn the function
   into a package-level function-typed var (call sites in `rate_limit.go`,
   `idempotency.go`, `signature.go` are unaffected since Go calls a
   func-typed var identically to a func):
   ```go
   var sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {
       if len(cfg.Addrs) == 0 {
           return nil
       }
       return data.SharedRedisClient(cfg)
   }
   ```
   This gives tests a seam to swap in a spy without a real network dial.

3. **`internal_pkg_middleware_rate_limit_test_go.yaml`** — two new tests:
   - `TestRateLimitWithStoreSkipsRedisDialForMemoryBackend`: swap
     `sharedRedisClient` for a call-counting spy, build `RateLimitConfig{Backend: "memory"}`,
     invoke `RateLimit(...)`, assert the spy was never called.
   - `TestRateLimitWithStoreDialsRedisForRedisBackend`: same spy, `Backend: "redis"`,
     assert the spy was called exactly once with the expected `cfg.Redis`
     (regression guard for the acceptance criterion "redis backend still
     connects correctly").

## Testing

- `go test ./...` in a generated `base-hertz` and `ratelimit-hertz` project
  (via `ncgo new --template-dir`) covering the new tests above plus the
  existing rate-limit suite (no regressions).

## Non-goals

- Not touching `conf.go`'s `applyRedisFallbacks()` — gating the call site is
  sufficient and matches the acceptance criteria; leaving the default
  address fallback in place is harmless once nothing dials it in memory mode.
- Not touching `user-bff-hertz` / `admin-bff-hertz` — confirmed unaffected.
