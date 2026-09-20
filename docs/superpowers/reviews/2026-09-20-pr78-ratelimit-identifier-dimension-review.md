# PR #78 — Rate-Limit Identifier Dimension — Code Review

**Delivery type:** Merge commit `018c76e546fb8a3fab4d2d9705d7464f3746101c` on `main`, merging `feat/78-ratelimit-identifier-dimension` (#78). Branch had 6 commits: `d86c8b8`, `a0b9d32`, `dafb62a`, `67c503e`, `48e60dd`, `020d6aa`.
**Reviewed diff:** `git diff 018c76e^1 018c76e`
**Verdict:** No blocking issues. Two informational/medium findings worth follow-up.

---

## 1. Scope of change

All Go source lives inside YAML `body: |` block scalars in ncgo template files; brace-escaping conventions (`{{ "{" }}` / `{{ "}" }}` vs. plain braces) vary per file and were checked against each file's own pre-existing convention, not flagged as defects when consistent with that file's history.

Files touched:
- `internal/pkg/ratelimit` fragments mirrored across `user-bff-hertz/hertz-template/`, `ratelimit-hertz/hertz-template/`, `admin-bff-hertz/hertz-template/`: new `Identifier` field on `Lookup`, new `"identifier"`/`"ip_identifier"` keyBy dimensions in `BuildKey`, new package-level `ratelimit.Check` helper.
- `user-bff-hertz/hertz-template/conf.yaml`: new `RateLimitConfig` fields `PasswordResetRequestIdentifier`, `PasswordResetConfirmIdentifier`, keyed by `KeyBy: ["identifier"]`.
- `user-bff-hertz/hertz-template/internal_handler_auth_go.yaml`: `AuthHandler.RequestPasswordReset`/`ConfirmPasswordReset` wired to call the new check after body-parsing, using new phase strings `"password_reset_request_identifier"`/`"password_reset_confirm_identifier"`.
- `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`: constructs a `ratelimit.Store` and wires resolver/store/cfg into `NewAuthHandler`.
- Tests: `internal_pkg_ratelimit_store_test_go.yaml` (all 3 mirrors), `internal_handler_auth_test_go.yaml`.
- `base-hertz` correctly left untouched — it has no ratelimit fragments to override.

---

## 2. Correctness review

### 2.1 Confirmed correct / consistent

- `Lookup.Identifier` and the new `BuildKey` cases (`"identifier"`, `"ip_identifier"`) are mirrored identically across `user-bff-hertz`, `ratelimit-hertz`, and `admin-bff-hertz` templates.
- The new package-level `ratelimit.Check` helper is mirrored identically across the three templates.
- `Resolver.phaseConfig()`'s new `case "password_reset_request_identifier"` / `case "password_reset_confirm_identifier"` route correctly to the new `PasswordResetRequestIdentifier`/`PasswordResetConfirmIdentifier` config fields — distinct from the pre-existing `"password_reset_request"`/`"password_reset_confirm"` phase strings still used by the unchanged middleware. No other call site needs updating for this wiring to work end-to-end.
- `conf.yaml`'s `KeyBy: ["identifier"]` (deliberately not `["ip_identifier"]`) matches the design doc's stated rationale: an `ip_identifier` key requires both IP and identifier to match, which would not prevent an attacker from bypassing the limit via IP rotation while keeping the same identifier.
- `base-hertz` has no ratelimit files at all, so it correctly required no changes.
- `admin-bff-hertz`/`ratelimit-hertz` mirrors are inert-but-present as expected — they carry the new `Identifier`/keyBy/`Check` additions but have no password-reset routes to exercise them, consistent with "mirror the primitives everywhere, wire them up only where used."

### 2.2 Findings

**Finding 1 (Medium) — Identifier-scoped store hardcodes nil Redis client, silently downgrading to in-memory backend under a multi-replica Redis deployment.**

- File: `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml` (around the `ratelimit.NewStore` call site)
- The new identifier-scoped rate-limit store is constructed via `ratelimit.NewStore(cfg.RateLimit, nil)`, hardcoding a `nil` Redis client, so it always falls back to the in-memory backend even when `cfg.RateLimit.Backend == "redis"`. This differs from the existing IP-based middleware (`internal_pkg_middleware_rate_limit_go.yaml`), which passes a real `sharedRedisClient(cfg.Redis)`.
- **Failure scenario:** Deploy `user-bff-hertz` with `RateLimit.Backend: redis` across N replicas behind a load balancer. The coarse IP-based middleware check correctly shares counters via Redis, but `AuthHandler`'s new per-identifier check keeps its counter only in each replica's local memory. An attacker who rotates across replicas (or simply retries until routed to a different instance) gets a fresh in-memory counter per instance — defeating exactly the IP-rotation-bypass protection this PR was built to close, in any multi-replica deployment.
- **Recommendation:** Pass the same shared Redis client used by the existing middleware into the new store constructor, or make the omission explicit/configurable rather than silently hardcoded.

**Finding 2 (Low/Informational) — New `user-bff-hertz` store test file has much thinner coverage than its sibling mirrors.**

- File: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`
- This file is newly created for `user-bff-hertz` in this PR (it did not exist before) and contains only the 5 new identifier-dimension tests (~43 lines). The sibling mirrors in `admin-bff-hertz` and `ratelimit-hertz` carry the full pre-existing store test suite (~114 lines), covering fixed/sliding-window strategies, LRU eviction, and redis/memory backend fallback, plus the new identifier tests.
- **Failure scenario:** A project generated from the `user-bff-hertz` template (with `update_behavior: cover`, so this file fully replaces any existing content) ships the full `store.go` logic (fixed window, sliding window, LRU eviction, backend fallback) but with test coverage only for the new identifier dimension — a regression in `Allow()`'s window arithmetic or LRU eviction in `user-bff-hertz` would go undetected even though the identical code path is tested in the other two services.
- **Recommendation:** Port the full existing store test suite into the `user-bff-hertz` test file to match its siblings, not just the new identifier-dimension tests.

---

## 3. Summary

No blocking correctness bugs in the core logic reviewed (BuildKey dimensions, phase-string routing, config wiring, cross-template mirroring). Two findings: a real behavioral gap (Finding 1, Redis client not wired into the new store — undermines the IP-rotation-bypass protection under multi-replica/Redis deployments) and a test-coverage gap (Finding 2) worth addressing before this ships to production users of the `user-bff-hertz` template.
