# Issue #79 — Memory-Backend RateLimit Idle Redis Dial — Code Review

**Delivery type:** Merge commit `b6fdefad2a5863ad05626a7d1c77b42d9568ddf8` on `main`, merging the fix for Issue #79 ("fix(ratelimit-hertz): memory-backend RateLimit still opens an idle Redis connection pool"). Pre-merge `main` tip was `8d1ca8e`.
**Reviewed diff:** `git diff 8d1ca8e...b6fdefad2a5863ad05626a7d1c77b42d9568ddf8`
**Verdict:** No blocking issues. No correctness findings.

---

## 1. Scope of change

All Go source lives inside YAML `body: |` block scalars in ncgo template files. Review was scoped to the 6 changed `.yaml` template files (per instructions, the two new markdown design/plan docs under `docs/superpowers/specs` and `docs/superpowers/plans` were excluded — already reviewed/approved earlier in this workflow):

- `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- `ratelimit-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml`
- `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`
- `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- `base-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml`
- `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`

Intended change (both `ratelimit-hertz` and `base-hertz` mirrors): `sharedRedisClient` converted from a `func` to a package-level func-typed `var` (enabling test spying), and `rateLimitWithStore()` changed to call `sharedRedisClient(cfg.Redis)` only when `cfg.Backend == "redis"`, instead of unconditionally — the unconditional call was the bug, causing an idle Redis dial even on the memory backend. Two new tests were added to each `rate_limit_test.go`: one asserting the spy is not called when `Backend == "memory"`, one asserting it is called with the correct `RedisConfig` when `Backend == "redis"`.

---

## 2. Correctness review

### 2.1 Confirmed correct / consistent

- The `Backend == "redis"` guard around `sharedRedisClient(cfg.Redis)` in `rateLimitWithStore()` is placed after config normalization (which defaults an empty/unset `Backend` to `"memory"`), so the guard correctly covers the `""` case too — no regression for callers that never set `Backend` explicitly.
- The func-to-var conversion of `sharedRedisClient` is applied identically and consistently in both `ratelimit-hertz` and `base-hertz` mirrors, in both the production file (`redis_client.go`) and the guarded call site (`rate_limit.go`).
- No `t.Parallel()` is used in the affected/new tests, so mutating the package-level `sharedRedisClient` var as a test spy (save original, substitute, defer restore) does not introduce a data race between subtests.
- The new "memory backend does not dial Redis" and "redis backend dials with correct config" tests are structurally sound and actually exercise the changed branch (they assert on the spy having been called/not called, and on the `RedisConfig` value passed through), rather than just asserting no panic.
- `base-hertz`'s test file consistently uses go-template brace-escaping (`{{ "{" }}` / `{{ "}" }}`) throughout its body, as expected since the whole file is itself rendered as a Go template; this is unrelated to the fix and is applied correctly (no stray unescaped braces that would break template execution).
- `ratelimit-hertz`'s equivalent file does not need brace-escaping and correctly omits it.
- Both `ratelimit-hertz` and `base-hertz` templates are patched in a mirrored, matching way — no divergence between the two copies of the fix.

### 2.2 Pre-existing, out-of-scope issue (noted, not a new finding)

- `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml` hardcodes the import path `github.com/acme/scratch` instead of using `{{.Module}}`. This predates this change (confirmed present before `8d1ca8e`) and is unrelated to the Issue #79 fix, so it is not counted as a finding introduced by this diff. Flagging only for visibility in case a future cleanup pass wants to pick it up.

### 2.3 Findings

None. No correctness bugs were identified in the diff.

---

## 3. Summary

The fix correctly gates the Redis client construction behind `cfg.Backend == "redis"`, is applied consistently across both `ratelimit-hertz` and `base-hertz` template mirrors, and is backed by tests that meaningfully verify both the negative (memory backend, no dial) and positive (redis backend, dial with correct config) cases. No correctness issues found in the 6 reviewed template files.
