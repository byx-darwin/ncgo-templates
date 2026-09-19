# Middleware Registration Order Fix (Issue #73) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix RateLimit/Idempotency middleware registration order across `base-hertz`, `ratelimit-hertz`, and `admin-bff-hertz` so identity-scoped branches (`Claims.AK`/`Claims.Uid`) that are currently unreachable become reachable, without breaking existing reachable branches.

**Architecture:** Each package's `internal/router/*.go` template registers middleware on Hertz route groups (`api`, `protected`, and — for admin-bff-hertz — `auth`). The fix threads a `*ratelimit.Resolver` into ratelimit-hertz's router function (mirroring admin-bff-hertz's existing `password_change` pattern) so `RateLimit("post_auth", ...)` can register on `protected` after `JWTAuth`, and moves `Idempotency` off the shared `api` group onto whichever group actually owns each route, so every request runs it exactly once with the identity that's genuinely available at that point.

**Tech Stack:** Go, Hertz (`github.com/cloudwego/hertz`), `github.com/golang-jwt/jwt/v5`, Go template YAML (`ncgo` template format).

**Spec:** `docs/superpowers/specs/2026-09-19-middleware-identity-order-design.md`

## Global Constraints

- Template files under `hertz-template/` are YAML wrapping Go source in a `body:` block. `base-hertz`/`ratelimit-hertz` templates use plain Go (`body: |-`); `admin-bff-hertz` templates (marked `loop_service: true`) use Go-template-escaped braces (`{{ "{" }}` / `{{ "}" }}`) because they're rendered twice (ncgo templating, then per-service loop). Preserve each file's existing escaping style exactly — do not introduce one style into a file using the other.
- No changes to `idempotency.go`, `rate_limit.go`, or `resolver.go`'s own logic in any package — only registration call sites move.
- Every task's Go code changes must be verified with `go build ./...` and `go vet ./...` against a project generated from the affected template (see each task's Testing step for the exact `ncgo new` invocation), plus the package's existing `go test ./...`.
- Router-level tests use a real Hertz engine via `github.com/cloudwego/hertz/pkg/common/ut.PerformRequest` — never hand-constructed `*app.RequestContext` — matching the convention already established in `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml`.
- Test JWTs are signed with `github.com/golang-jwt/jwt/v5`, `jwt.SigningMethodHS256`, matching the test config's `auth.token.signing_key`.

---

### Task 1: ratelimit-hertz — reposition `RateLimit("post_auth", ...)` and move `Idempotency` to `protected`

**Files:**
- Modify: `ratelimit-hertz/hertz-template/internal_base_server_server_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_router_service_go.yaml`
- Create: `ratelimit-hertz/hertz-template/internal_router_service_test_go.yaml`

**Interfaces:**
- Consumes: `middleware.RateLimit(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver) app.HandlerFunc` (unchanged signature, from `internal_pkg_middleware_rate_limit_go.yaml`); `middleware.Idempotency(cfg conf.IdempotencyConfig) app.HandlerFunc` (unchanged); `ratelimit.NewResolver(cfg conf.RateLimitConfig, opts ratelimit.Options) *ratelimit.Resolver`; `ratelimit.ResolveFunc func(ctx context.Context, lookup ratelimit.Lookup) (*conf.RateLimitRuleConfig, bool, error)` implementing `ratelimit.GRPCClient`.
- Produces: `router.RegisterServiceRoutes(h *server.Hertz, resolver *ratelimit.Resolver)` — signature changes from `RegisterServiceRoutes(h *server.Hertz)`. `server.go`'s `Run()` is the only other caller and is updated in this same task.

- [ ] **Step 1: Write the failing router-level test** — create `ratelimit-hertz/hertz-template/internal_router_service_test_go.yaml`:

```yaml
# ncgo exported template — internal/router/service_test.go
path: internal/router/service_test.go
update_behavior:
    type: skip
body: |-
    package router

    import (
        "context"
        "os"
        "path/filepath"
        "testing"
        "time"

        "github.com/cloudwego/hertz/pkg/app/server"
        "github.com/cloudwego/hertz/pkg/common/ut"
        "github.com/cloudwego/hertz/pkg/protocol/consts"
        "github.com/golang-jwt/jwt/v5"

        "{{.Module}}/internal/base/conf"
        "{{.Module}}/internal/pkg/ratelimit"
    )

    // testRouterConfYAML enables auth.token (so JWTAuth enforces on protected
    // routes), idempotency, and rate_limit.post_auth with a grpc source — the
    // grpc source lets the test intercept the Lookup RateLimit builds via a
    // fake ratelimit.GRPCClient, without needing the local rule matcher to
    // actually rate-limit anything.
    const testRouterConfYAML = `
    env: test
    auth:
      token:
        enabled: true
        header: "Authorization"
        signing_key: "router-test-secret"
    idempotency:
      enabled: true
    rate_limit:
      enabled: true
      source:
        type: grpc
      grpc:
        timeout_milliseconds: 200
      post_auth:
        enabled: true
    `

    func TestMain(m *testing.M) {
        dir, err := os.MkdirTemp("", "ratelimit-hertz-router-test")
        if err != nil {
            panic(err)
        }
        path := filepath.Join(dir, "conf.yaml")
        if err := os.WriteFile(path, []byte(testRouterConfYAML), 0o644); err != nil {
            panic(err)
        }
        os.Setenv("CONFIG_PATH", path)
        code := m.Run()
        os.RemoveAll(dir)
        os.Exit(code)
    }

    // capturingGRPCClient records the last Lookup RateLimit's resolver asked
    // it to resolve, then reports "no rule found" so the request proceeds
    // (letting the test inspect what identity was visible at that point,
    // independent of whether any rule actually fires).
    type capturingGRPCClient struct {
        lastLookup ratelimit.Lookup
        called     bool
    }

    func (c *capturingGRPCClient) ResolveRateLimitRule(ctx context.Context, lookup ratelimit.Lookup) (*conf.RateLimitRuleConfig, bool, error) {
        c.called = true
        c.lastLookup = lookup
        return nil, false, nil
    }

    func newRouterTestEngine(t *testing.T, capture *capturingGRPCClient) *server.Hertz {
        t.Helper()
        cfg := conf.Get()
        resolver := ratelimit.NewResolver(cfg.RateLimit, ratelimit.Options{
            GRPC: ratelimit.ResolveFunc(capture.ResolveRateLimitRule),
        })
        h := server.New()
        RegisterServiceRoutes(h, resolver)
        return h
    }

    func newRouterTestJWT(t *testing.T, uid string) string {
        t.Helper()
        token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
            "uid": uid,
            "exp": time.Now().Add(time.Hour).Unix(),
        })
        signed, err := token.SignedString([]byte("router-test-secret"))
        if err != nil {
            t.Fatalf("failed to sign test jwt: %v", err)
        }
        return signed
    }

    // TestPostAuthRateLimit_ProtectedRoute_SeesUserUUID is the fix probe:
    // before this task's fix, RateLimit("post_auth", ...) was registered
    // engine-level in server.go, before router.RegisterServiceRoutes ever
    // ran JWTAuth — so Claims (and therefore Lookup.UserUUID) was always
    // empty at that point despite the "post_auth" name. With the fix,
    // post_auth is registered on `protected` after JWTAuth, so a valid JWT's
    // uid must reach the resolver's Lookup.
    func TestPostAuthRateLimit_ProtectedRoute_SeesUserUUID(t *testing.T) {
        capture := &capturingGRPCClient{}
        h := newRouterTestEngine(t, capture)
        jwtToken := newRouterTestJWT(t, "user-123")

        w := ut.PerformRequest(h.Engine, "GET", "/api/v1/resources",
            nil, ut.Header{Key: "Authorization", Value: "Bearer " + jwtToken})
        resp := w.Result()

        if resp.StatusCode() != consts.StatusOK {
            t.Fatalf("expected 200, got %d", resp.StatusCode())
        }
        if !capture.called {
            t.Fatal("expected RateLimit(\"post_auth\", ...) to call the resolver, but it never did")
        }
        if capture.lastLookup.UserUUID != "user-123" {
            t.Errorf("Lookup.UserUUID = %q, want %q — post_auth rate limiting ran before identity was known", capture.lastLookup.UserUUID, "user-123")
        }
    }
```

This test will not compile yet against the current (pre-fix) code: `RegisterServiceRoutes` still takes only `(h *server.Hertz)`, one argument, not two. That compile failure is the expected RED state — Step 3 below changes the function's signature to accept the resolver, which is what makes this test (and its caller in `server.go`) compile.

- [ ] **Step 2: Run test to verify it fails to compile / fails**

Run: `cd` into a project generated from this template (see Task 1's Testing step below for the exact generation command) and run `go test ./internal/router/... -run TestPostAuthRateLimit -v`
Expected: FAIL — either a compile error (`RegisterServiceRoutes` signature mismatch) or a runtime failure with `Lookup.UserUUID = "", want "user-123"`.

- [ ] **Step 3: Reposition `post_auth` and move `Idempotency`**

Edit `ratelimit-hertz/hertz-template/internal_base_server_server_go.yaml`. Change:

```go
        // Rate-limit middleware — pre-auth & post-auth phases (memory/redis backend)
        if cfg.RateLimit.Enabled {
            rlResolver := ratelimit.NewResolver(cfg.RateLimit, ratelimit.Options{})
            h.Use(middleware.RateLimit("pre_auth", cfg.RateLimit, cfg.RateLimit.PreAuth, rlResolver))
            h.Use(middleware.RateLimit("post_auth", cfg.RateLimit, cfg.RateLimit.PostAuth, rlResolver))
        }
```

to:

```go
        // Rate-limit middleware — pre-auth phase only (engine-level, IP-based
        // DoS mitigation before any routing work). post_auth phase is
        // registered inside router.RegisterServiceRoutes, on the `protected`
        // group after JWTAuth, so it can actually see Claims (see issue #73).
        var rlResolver *ratelimit.Resolver
        if cfg.RateLimit.Enabled {
            rlResolver = ratelimit.NewResolver(cfg.RateLimit, ratelimit.Options{})
            h.Use(middleware.RateLimit("pre_auth", cfg.RateLimit, cfg.RateLimit.PreAuth, rlResolver))
        }
```

and change the call:

```go
        // Register custom service routes with JWT/signature middleware
        router.RegisterServiceRoutes(h)
```

to:

```go
        // Register custom service routes with JWT/signature middleware
        router.RegisterServiceRoutes(h, rlResolver)
```

Edit `ratelimit-hertz/hertz-template/internal_router_service_go.yaml`. Change:

```go
    package router

    import (
        "github.com/cloudwego/hertz/pkg/app/server"

        "{{.Module}}/internal/base/conf"
        "{{.Module}}/internal/handler"
        "{{.Module}}/internal/pkg/middleware"
    )

    // RegisterServiceRoutes registers service routes with rate limiting
    func RegisterServiceRoutes(h *server.Hertz) {
        cfg := conf.Get()

        resourceHandler := handler.NewResourceHandler()

        api := h.Group("/api/v1")

        // ── Signature verification (optional, for open-api callers) ─────────
        if cfg.Auth.Signature.Enabled {
            resolver := middleware.StaticSecretResolver{SecretValue: cfg.Auth.Signature.StaticSecret}
            api.Use(middleware.SignatureAuth(cfg.Auth.Signature, resolver))
        }

        // ── Idempotency (optional, for POST/PUT/DELETE) ─────────────────────
        if cfg.Idempotency.Enabled {
            api.Use(middleware.Idempotency(cfg.Idempotency))
        }

        // Public routes (no JWT)
        api.GET("/health", resourceHandler.Health)

        // Protected routes (JWT required, rate limited)
        protected := api.Group("")
        protected.Use(middleware.JWTAuth(cfg.Auth.Token))

        // Example protected endpoints (all are rate limited by middleware)
        resources := protected.Group("/resources")
        resources.GET("", resourceHandler.List)
        resources.GET("/:id", resourceHandler.Get)
        resources.POST("", resourceHandler.Create)
        resources.PUT("/:id", resourceHandler.Update)
        resources.DELETE("/:id", resourceHandler.Delete)
    }
```

to:

```go
    package router

    import (
        "github.com/cloudwego/hertz/pkg/app/server"

        "{{.Module}}/internal/base/conf"
        "{{.Module}}/internal/handler"
        "{{.Module}}/internal/pkg/middleware"
        "{{.Module}}/internal/pkg/ratelimit"
    )

    // RegisterServiceRoutes registers service routes with rate limiting.
    // resolver is used by the post_auth RateLimit phase registered below on
    // `protected`; it may be nil when cfg.RateLimit.Enabled is false.
    func RegisterServiceRoutes(h *server.Hertz, resolver *ratelimit.Resolver) {
        cfg := conf.Get()

        resourceHandler := handler.NewResourceHandler()

        api := h.Group("/api/v1")

        // ── Signature verification (optional, for open-api callers) ─────────
        if cfg.Auth.Signature.Enabled {
            sigResolver := middleware.StaticSecretResolver{SecretValue: cfg.Auth.Signature.StaticSecret}
            api.Use(middleware.SignatureAuth(cfg.Auth.Signature, sigResolver))
        }

        // Public routes (no JWT) — no mutating methods here, so Idempotency
        // is not needed on this group (its default method set is
        // POST/PUT/PATCH/DELETE, which GET already skips).
        api.GET("/health", resourceHandler.Health)

        // Protected routes (JWT required, rate limited)
        protected := api.Group("")
        protected.Use(middleware.JWTAuth(cfg.Auth.Token))

        // ── Idempotency (optional, for POST/PUT/DELETE) — registered here,
        // after JWTAuth, so Claims.Uid is available and idempotencyKey()'s
        // ak_user_uuid:/user_uuid: branches are reachable (see issue #73).
        if cfg.Idempotency.Enabled {
            protected.Use(middleware.Idempotency(cfg.Idempotency))
        }

        // post_auth rate limiting — registered here, after JWTAuth, so
        // Claims.AK/Uid are available (see issue #73).
        if cfg.RateLimit.Enabled {
            protected.Use(middleware.RateLimit("post_auth", cfg.RateLimit, cfg.RateLimit.PostAuth, resolver))
        }

        // Example protected endpoints (all are rate limited by middleware)
        resources := protected.Group("/resources")
        resources.GET("", resourceHandler.List)
        resources.GET("/:id", resourceHandler.Get)
        resources.POST("", resourceHandler.Create)
        resources.PUT("/:id", resourceHandler.Update)
        resources.DELETE("/:id", resourceHandler.Delete)
    }
```

Note the renamed local variable `sigResolver` (was `resolver`) inside the signature-verification block — it must not shadow the new `resolver *ratelimit.Resolver` parameter.

Now finish the test file per Step 1's note: use `conf.Get()` directly (import `"{{.Module}}/internal/base/conf"`) and `*conf.RateLimitRuleConfig` as `ResolveRateLimitRule`'s return type instead of the placeholder `ratelimitRuleConfigAlias` / `getConfForTest`.

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/router/... -run TestPostAuthRateLimit -v`
Expected: PASS

- [ ] **Step 5: Add and run the Idempotency cross-user regression test**

Append to the same test file:

```go
    import (
        // ...existing imports...
        "bytes"
    )

    // TestIdempotency_DifferentUsers_DoNotCollide is the Idempotency fix
    // probe: before this task's fix, Idempotency was registered on `api`,
    // before JWTAuth ever ran, so idempotencyKey() always fell back to
    // ip:-scoped keys for every request through this test client (same IP).
    // Two different JWT-authenticated users reusing the same
    // X-Idempotency-Key value would collide on that ip: key — the second
    // user's identical request would be wrongly rejected as a duplicate
    // (409) instead of succeeding independently, because ip: scoping
    // doesn't distinguish them. With the fix (Idempotency registered on
    // `protected` after JWTAuth), each user gets their own
    // user_uuid:-scoped key.
    func TestIdempotency_DifferentUsers_DoNotCollide(t *testing.T) {
        h := newRouterTestEngine(t, &capturingGRPCClient{})
        tokenA := newRouterTestJWT(t, "user-A")
        tokenB := newRouterTestJWT(t, "user-B")
        body := []byte(`{}`)

        wA := ut.PerformRequest(h.Engine, "POST", "/api/v1/resources",
            &ut.Body{Body: bytes.NewReader(body), Len: len(body)},
            ut.Header{Key: "Authorization", Value: "Bearer " + tokenA},
            ut.Header{Key: "X-Idempotency-Key", Value: "shared-key-123"},
            ut.Header{Key: "Content-Type", Value: "application/json"},
        )
        if got := wA.Result().StatusCode(); got != consts.StatusOK {
            t.Fatalf("user A: expected 200, got %d", got)
        }

        wB := ut.PerformRequest(h.Engine, "POST", "/api/v1/resources",
            &ut.Body{Body: bytes.NewReader(body), Len: len(body)},
            ut.Header{Key: "Authorization", Value: "Bearer " + tokenB},
            ut.Header{Key: "X-Idempotency-Key", Value: "shared-key-123"},
            ut.Header{Key: "Content-Type", Value: "application/json"},
        )
        if got := wB.Result().StatusCode(); got != consts.StatusOK {
            t.Fatalf("user B: expected 200 (different user, same idempotency key must not collide), got %d — this is exactly the bug this task fixes", got)
        }
    }
```

Run: `go test ./internal/router/... -run TestIdempotency_DifferentUsers_DoNotCollide -v`
Expected: FAIL against the pre-fix code (409 for user B), PASS after Step 3's changes (both already applied, so this should PASS immediately — if it doesn't, the Step 3 edits are incomplete; re-check the `protected.Use(middleware.Idempotency(...))` placement).

- [ ] **Step 6: Run the full package test suite**

Run: `go test ./... -v` from the generated project root
Expected: PASS — including pre-existing `internal/pkg/middleware` tests, which are unaffected by this task.

- [ ] **Step 7: Commit**

```bash
git add ratelimit-hertz/hertz-template/internal_base_server_server_go.yaml \
        ratelimit-hertz/hertz-template/internal_router_service_go.yaml \
        ratelimit-hertz/hertz-template/internal_router_service_test_go.yaml
git commit -m "fix(ratelimit-hertz): reposition post_auth RateLimit and Idempotency after JWTAuth (#73)"
```

**Testing (generate a real project to run the above):**

```bash
cd /tmp && rm -rf ratelimit-hertz-test && mkdir ratelimit-hertz-test && cd ratelimit-hertz-test
ncgo new --template-dir /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates/ratelimit-hertz --module github.com/test/ratelimit-hertz-test testsvc
cd testsvc && make sqlc 2>/dev/null; make update 2>/dev/null || true
go build ./... && go vet ./... && go test ./...
```

(Exact `ncgo new` flags may need adjusting to match this repo's actual CLI — check `ratelimit-hertz/test/e2e_test.sh` for the currently-working invocation and reuse it rather than guessing.)

---

### Task 2: ~~base-hertz — remove dead `RateLimit` middleware and config~~ — SKIPPED

**Status: skipped during execution (2026-09-19).** The implementer found that
`base-hertz`'s `RateLimit` middleware/config, though never wired into `server.go`/
router, are load-bearing for a different reason: `ncgo` (a separate repository,
`github.com/byx-darwin/ncgo`) ships a built-in default hertz layout that
unconditionally generates `internal/repository/rate_limit_rule.go` (and its db
schema/query/migration/seed files) for any hertz template without
`skip_default_templates: true` — `base-hertz` doesn't set that flag and has no local
override for that path. That embedded default file references
`conf.RateLimitConfig`/`conf.RateLimitRuleConfig` directly, so removing those types
from `base-hertz`'s `conf.go` breaks `go build` for any project generated with `--db`.

Ruling (repo owner, 2026-09-19): keep `base-hertz`'s `RateLimit` code as-is. No files
listed under this task are touched. See the design doc's "Design rejected during
execution: removing base-hertz's `RateLimit` code" section for the full account. Task 5
documents the limitation in the README instead of removing the code.

No commit for this task — nothing to fix-loop or review; move directly to Task 3.


---

### Task 3: base-hertz — move `Idempotency` to `protected` group

**Files:**
- Modify: `base-hertz/hertz-template/internal_router_service_go.yaml`
- Create: `base-hertz/hertz-template/internal_router_service_test_go.yaml`

**Interfaces:**
- Consumes: `middleware.Idempotency(cfg conf.IdempotencyConfig) app.HandlerFunc` (unchanged), `middleware.JWTAuth(cfg conf.TokenConfig) app.HandlerFunc` (unchanged).
- Produces: `router.RegisterServiceRoutes(h *server.Hertz)` — signature unchanged (base-hertz never had a `RateLimit` resolver to thread through, unlike ratelimit-hertz).

- [ ] **Step 1: Write the failing test** — create `base-hertz/hertz-template/internal_router_service_test_go.yaml`:

```yaml
# ncgo exported template — internal/router/service_test.go
path: internal/router/service_test.go
update_behavior:
    type: skip
body: |-
    package router

    import (
        "bytes"
        "os"
        "path/filepath"
        "testing"
        "time"

        "github.com/cloudwego/hertz/pkg/app/server"
        "github.com/cloudwego/hertz/pkg/common/ut"
        "github.com/cloudwego/hertz/pkg/protocol/consts"
        "github.com/golang-jwt/jwt/v5"
    )

    const testRouterConfYAML = `
    env: test
    auth:
      token:
        enabled: true
        header: "Authorization"
        signing_key: "router-test-secret"
    idempotency:
      enabled: true
    `

    func TestMain(m *testing.M) {
        dir, err := os.MkdirTemp("", "base-hertz-router-test")
        if err != nil {
            panic(err)
        }
        path := filepath.Join(dir, "conf.yaml")
        if err := os.WriteFile(path, []byte(testRouterConfYAML), 0o644); err != nil {
            panic(err)
        }
        os.Setenv("CONFIG_PATH", path)
        code := m.Run()
        os.RemoveAll(dir)
        os.Exit(code)
    }

    func newRouterTestEngine(t *testing.T) *server.Hertz {
        t.Helper()
        h := server.New()
        RegisterServiceRoutes(h)
        return h
    }

    func newRouterTestJWT(t *testing.T, uid string) string {
        t.Helper()
        token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
            "uid": uid,
            "exp": time.Now().Add(time.Hour).Unix(),
        })
        signed, err := token.SignedString([]byte("router-test-secret"))
        if err != nil {
            t.Fatalf("failed to sign test jwt: %v", err)
        }
        return signed
    }

    // TestIdempotency_DifferentUsers_DoNotCollide is the fix probe: before
    // this task's fix, Idempotency was registered on `api`, before JWTAuth
    // ever ran, so idempotencyKey() always fell back to ip:-scoped keys for
    // every request from this test client (same IP). Two different
    // JWT-authenticated users reusing the same X-Idempotency-Key value would
    // collide on that ip: key. With the fix (Idempotency registered on
    // `protected` after JWTAuth), each gets their own user_uuid:-scoped key.
    func TestIdempotency_DifferentUsers_DoNotCollide(t *testing.T) {
        h := newRouterTestEngine(t)
        tokenA := newRouterTestJWT(t, "user-A")
        tokenB := newRouterTestJWT(t, "user-B")
        body := []byte(`{}`)

        wA := ut.PerformRequest(h.Engine, "POST", "/api/v1/resources",
            &ut.Body{Body: bytes.NewReader(body), Len: len(body)},
            ut.Header{Key: "Authorization", Value: "Bearer " + tokenA},
            ut.Header{Key: "X-Idempotency-Key", Value: "shared-key-123"},
            ut.Header{Key: "Content-Type", Value: "application/json"},
        )
        if got := wA.Result().StatusCode(); got != consts.StatusOK {
            t.Fatalf("user A: expected 200, got %d", got)
        }

        wB := ut.PerformRequest(h.Engine, "POST", "/api/v1/resources",
            &ut.Body{Body: bytes.NewReader(body), Len: len(body)},
            ut.Header{Key: "Authorization", Value: "Bearer " + tokenB},
            ut.Header{Key: "X-Idempotency-Key", Value: "shared-key-123"},
            ut.Header{Key: "Content-Type", Value: "application/json"},
        )
        if got := wB.Result().StatusCode(); got != consts.StatusOK {
            t.Fatalf("user B: expected 200 (different user, same idempotency key must not collide), got %d — this is exactly the bug this task fixes", got)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/router/... -run TestIdempotency_DifferentUsers_DoNotCollide -v`
Expected: FAIL with `user B: expected 200 ..., got 409`.

- [ ] **Step 3: Move `Idempotency` registration**

Edit `base-hertz/hertz-template/internal_router_service_go.yaml`. Change:

```go
        // ── Idempotency (optional, for POST/PUT/DELETE) ─────────────────────
        if cfg.Idempotency.Enabled {
            api.Use(middleware.Idempotency(cfg.Idempotency))
        }

        // Public routes (no JWT)
        api.GET("/health", resourceHandler.Health)

        // Protected routes (JWT required)
        protected := api.Group("")
        protected.Use(middleware.JWTAuth(cfg.Auth.Token))
```

to:

```go
        // Public routes (no JWT) — no mutating methods here, so Idempotency
        // is not needed on this group.
        api.GET("/health", resourceHandler.Health)

        // Protected routes (JWT required)
        protected := api.Group("")
        protected.Use(middleware.JWTAuth(cfg.Auth.Token))

        // ── Idempotency (optional, for POST/PUT/DELETE) — registered here,
        // after JWTAuth, so Claims.Uid is available and idempotencyKey()'s
        // ak_user_uuid:/user_uuid: branches are reachable (see issue #73).
        if cfg.Idempotency.Enabled {
            protected.Use(middleware.Idempotency(cfg.Idempotency))
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/router/... -run TestIdempotency_DifferentUsers_DoNotCollide -v`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `go build ./... && go vet ./... && go test ./...`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add base-hertz/hertz-template/internal_router_service_go.yaml \
        base-hertz/hertz-template/internal_router_service_test_go.yaml
git commit -m "fix(base-hertz): move Idempotency registration after JWTAuth (#73)"
```

**Testing:**

```bash
cd /tmp && rm -rf base-hertz-test && mkdir base-hertz-test && cd base-hertz-test
ncgo new --template-dir /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates/base-hertz --module github.com/test/base-hertz-test testsvc
cd testsvc && go build ./... && go vet ./... && go test ./...
```

(Check `base-hertz/test/e2e_test.sh` for the exact working `ncgo new` invocation this repo currently uses.)

---

### Task 4: admin-bff-hertz — split `Idempotency` into `auth` and `protected` groups

**Files:**
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml`

**Interfaces:**
- Consumes: `middleware.Idempotency(cfg conf.IdempotencyConfig) app.HandlerFunc` (unchanged); existing `fakeRouterRBACClient`, `fakeRouterUserClient`, `newRouterTestEngine`, `newRouterTestJWT` test helpers already in this file.
- Produces: `Register{{.ServiceName}}BffServiceRoutes(...)` signature unchanged.

- [ ] **Step 1: Write the failing tests** — append to `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml` (inside the existing `body:` block, after the last test function; keep the file's `{{ "{" }}`/`{{ "}" }}` escaping style):

```go
    // fakeRouterAuthClient is a minimal fake authservice.Client for the
    // Idempotency tests below — Login always succeeds so the test can focus
    // on whether Idempotency dedupes the second identical request.
    type fakeRouterAuthClient struct {{ "{" }}
    	authservice.Client
    	loginCalls int
    {{ "}" }}

    func (f *fakeRouterAuthClient) Login(ctx context.Context, req *api.LoginReq, callOptions ...callopt.Option) (*api.LoginResp, error) {{ "{" }}
    	f.loginCalls++
    	return &api.LoginResp{{ "{" }}AccessToken: "tok", RefreshToken: "rtok", ExpiresIn: 3600{{ "}" }}, nil
    {{ "}" }}

    func newRouterTestEngineWithAuth(t *testing.T, authCli authservice.Client, rbacCli rbacservice.Client) *route.Engine {{ "{" }}
    	t.Helper()
    	h := server.New()
    	var ruleCli ruleservice.Client
    	var resolver *ratelimit.Resolver
    	userCli := &fakeRouterUserClient{{ "{" }}{{ "}" }}
    	Register{{.ServiceName}}BffServiceRoutes(h, authCli, rbacCli, ruleCli, userCli, resolver)
    	return h.Engine
    {{ "}" }}

    // TestIdempotency_DifferentUsers_DoNotCollide is the fix probe for
    // protected routes: before this task's fix, Idempotency was registered
    // on `api`, before JWTAuth ever ran, so idempotencyKey() always fell
    // back to ip:-scoped keys for every request from this test client (same
    // IP). Two different JWT-authenticated users reusing the same
    // X-Idempotency-Key value would collide on that ip: key. With the fix
    // (Idempotency registered on `protected` after JWTAuth), each gets their
    // own user_uuid:-scoped key.
    func TestIdempotency_DifferentUsers_DoNotCollide(t *testing.T) {{ "{" }}
    	engine := newRouterTestEngine(t, &fakeRouterRBACClient{{ "{" }}allowed: true{{ "}" }})
    	tokenA := newRouterTestJWTWithUid(t, "user-A")
    	tokenB := newRouterTestJWTWithUid(t, "user-B")
    	body := []byte(`{{ "{" }}{{ "}" }}`)

    	wA := ut.PerformRequest(engine, "GET", "/api/v1/menus",
    		&ut.Body{{ "{" }}Body: bytes.NewReader(body), Len: len(body){{ "}" }},
    		ut.Header{{ "{" }}Key: "Authorization", Value: "Bearer " + tokenA{{ "}" }},
    		ut.Header{{ "{" }}Key: "X-Idempotency-Key", Value: "shared-key-123"{{ "}" }},
    	)
    	if got := wA.Result().StatusCode(); got != consts.StatusOK {{ "{" }}
    		t.Fatalf("user A: expected 200, got %d", got)
    	{{ "}" }}

    	wB := ut.PerformRequest(engine, "GET", "/api/v1/menus",
    		&ut.Body{{ "{" }}Body: bytes.NewReader(body), Len: len(body){{ "}" }},
    		ut.Header{{ "{" }}Key: "Authorization", Value: "Bearer " + tokenB{{ "}" }},
    		ut.Header{{ "{" }}Key: "X-Idempotency-Key", Value: "shared-key-123"{{ "}" }},
    	)
    	if got := wB.Result().StatusCode(); got != consts.StatusOK {{ "{" }}
    		t.Fatalf("user B: expected 200 (different user, same idempotency key must not collide), got %d — this is exactly the bug this task fixes", got)
    	{{ "}" }}
    {{ "}" }}

    // TestIdempotency_PublicLogin_StillDeduped confirms moving Idempotency
    // off the shared `api` group didn't drop coverage for the public
    // /auth/login route: two identical login requests with the same
    // X-Idempotency-Key must still result in only one real Login RPC call.
    func TestIdempotency_PublicLogin_StillDeduped(t *testing.T) {{ "{" }}
    	authCli := &fakeRouterAuthClient{{ "{" }}{{ "}" }}
    	engine := newRouterTestEngineWithAuth(t, authCli, &fakeRouterRBACClient{{ "{" }}allowed: true{{ "}" }})
    	body := []byte(`{{ "{" }}"username":"u","password":"p"{{ "}" }}`)

    	for i := 0; i < 2; i++ {{ "{" }}
    		w := ut.PerformRequest(engine, "POST", "/api/v1/auth/login",
    			&ut.Body{{ "{" }}Body: bytes.NewReader(body), Len: len(body){{ "}" }},
    			ut.Header{{ "{" }}Key: "X-Idempotency-Key", Value: "login-key-1"{{ "}" }},
    			ut.Header{{ "{" }}Key: "Content-Type", Value: "application/json"{{ "}" }},
    		)
    		if got := w.Result().StatusCode(); got != consts.StatusOK {{ "{" }}
    			t.Fatalf("request %d: expected 200, got %d", i, got)
    		{{ "}" }}
    	{{ "}" }}
    	if authCli.loginCalls != 1 {{ "{" }}
    		t.Errorf("loginCalls = %d, want 1 — the second identical request should have been deduped by Idempotency, not re-invoked the real Login RPC", authCli.loginCalls)
    	{{ "}" }}
    {{ "}" }}
```

Add `"bytes"` to the file's existing `import (...)` block. The file's existing `newRouterTestJWT` helper hardcodes `"uid": "user-123"` and takes no uid parameter — add a second helper alongside it (don't change the existing one; other tests in this file depend on its current fixed-uid behavior):

```go
    func newRouterTestJWTWithUid(t *testing.T, uid string) string {{ "{" }}
    	t.Helper()
    	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
    		"uid": uid,
    		"exp": time.Now().Add(time.Hour).Unix(),
    	{{ "}" }})
    	signed, err := token.SignedString([]byte("router-test-secret"))
    	if err != nil {{ "{" }}
    		t.Fatalf("failed to sign test jwt: %v", err)
    	{{ "}" }}
    	return signed
    {{ "}" }}
```

(Add `"time"` to the imports too if the file doesn't already import it — check first: the existing `newRouterTestJWT` already calls `time.Now()`, so `"time"` is already imported.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/router/... -run 'TestIdempotency_DifferentUsers_DoNotCollide|TestIdempotency_PublicLogin_StillDeduped' -v`
Expected: `TestIdempotency_DifferentUsers_DoNotCollide` FAILs (409 for user B). `TestIdempotency_PublicLogin_StillDeduped` should already PASS against current code (Idempotency is already on `api`, which covers `/auth/login`) — confirm this so Step 3 doesn't accidentally regress it.

- [ ] **Step 3: Split the registration**

Edit `admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml`. Change:

```go
    	api := h.Group("/api/v1")

    	// ── Signature verification (optional, for open-api callers) ─────────
    	if cfg.Auth.Signature.Enabled {{ "{" }}
    		resolver := middleware.StaticSecretResolver{{ "{" }}SecretValue: cfg.Auth.Signature.StaticSecret{{ "}" }}
    		api.Use(middleware.SignatureAuth(cfg.Auth.Signature, resolver))
    	{{ "}" }}

    	// ── Idempotency (optional, for POST/PUT/DELETE) ─────────────────────
    	if cfg.Idempotency.Enabled {{ "{" }}
    		api.Use(middleware.Idempotency(cfg.Idempotency))
    	{{ "}" }}

    	// Public routes (no JWT)
    	auth := api.Group("/auth")
    	auth.POST("/login", authHandler.Login)
    	auth.POST("/refresh", authHandler.Refresh)

    	// Protected routes (JWT required)
    	protected := api.Group("")
    	protected.Use(middleware.JWTAuth(cfg.Auth.Token))
```

to:

```go
    	api := h.Group("/api/v1")

    	// ── Signature verification (optional, for open-api callers) ─────────
    	if cfg.Auth.Signature.Enabled {{ "{" }}
    		sigResolver := middleware.StaticSecretResolver{{ "{" }}SecretValue: cfg.Auth.Signature.StaticSecret{{ "}" }}
    		api.Use(middleware.SignatureAuth(cfg.Auth.Signature, sigResolver))
    	{{ "}" }}

    	// Public routes (no JWT)
    	auth := api.Group("/auth")
    	// ── Idempotency for public auth routes (ak:/ip: scope only — no Uid
    	// pre-authentication; see issue #73) ─────────────────────────────────
    	if cfg.Idempotency.Enabled {{ "{" }}
    		auth.Use(middleware.Idempotency(cfg.Idempotency))
    	{{ "}" }}
    	auth.POST("/login", authHandler.Login)
    	auth.POST("/refresh", authHandler.Refresh)

    	// Protected routes (JWT required)
    	protected := api.Group("")
    	protected.Use(middleware.JWTAuth(cfg.Auth.Token))
    	// ── Idempotency for protected routes — registered after JWTAuth, so
    	// Claims.Uid is available and idempotencyKey()'s ak_user_uuid:/
    	// user_uuid: branches are reachable (see issue #73) ─────────────────
    	if cfg.Idempotency.Enabled {{ "{" }}
    		protected.Use(middleware.Idempotency(cfg.Idempotency))
    	{{ "}" }}
```

Note the renamed local variable `sigResolver` (was `resolver`) — this file's outer scope already has a `resolver *ratelimit.Resolver` function parameter (used later for `password_change`'s `middleware.RateLimit(...)` call); the old code's inner `resolver :=` shadowed it only within the `if` block, which happened to be harmless before, but keeping the rename removes the shadow entirely for clarity.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/router/... -run 'TestIdempotency_DifferentUsers_DoNotCollide|TestIdempotency_PublicLogin_StillDeduped' -v`
Expected: both PASS.

- [ ] **Step 5: Run the full existing router test suite (regression check)**

Run: `go test ./internal/router/... -v`
Expected: all existing tests (`TestAuthz_*`, `TestUnprotectedRoute_*`, `TestTerminalUsersRoute_*`) still PASS — the Idempotency split must not affect `Authz`/`RequirePermission`/JWT behavior on any route.

- [ ] **Step 6: Run the full suite**

Run: `go build ./... && go vet ./... && go test ./...`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml \
        admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml
git commit -m "fix(admin-bff-hertz): split Idempotency into auth/protected group registrations (#73)"
```

**Testing:**

```bash
cd /tmp && rm -rf admin-bff-hertz-test && mkdir admin-bff-hertz-test && cd admin-bff-hertz-test
ncgo new --template-dir /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates/admin-bff-hertz --module github.com/test/admin-bff-hertz-test testsvc
cd testsvc && go build ./... && go vet ./... && go test ./...
```

(Check `admin-bff-hertz/test/e2e_test.sh` for the exact working `ncgo new` invocation this repo currently uses — admin-bff-hertz likely needs extra flags for its RPC client dependencies.)

---

### Task 5: Documentation — replace the three #72-placeholder README notes

**Files:**
- Modify: `base-hertz/README.md`
- Modify: `ratelimit-hertz/README.md`
- Modify: `admin-bff-hertz/README.md`

**Interfaces:**
- Consumes: the final registration order established by Tasks 1–4.
- Produces: nothing consumed by other tasks — this is the terminal documentation task.

- [ ] **Step 1: Update `base-hertz/README.md:70`**

Read the current line and its surrounding paragraph (`grep -n -B3 -A3 "tracked as issue #73" base-hertz/README.md`) and replace the sentence:

> "Only `idempotency.go`'s plain `ak:`-scoped branch actually consumes it today — the combined `ak_user_uuid:` branch is unreachable because idempotency's key is computed before JWT runs, so `Uid` is always empty at that point (tracked as issue #73)."

with:

> "`idempotency.go` now runs once, inside the JWT-protected route group (after both `SignatureAuth` and `JWTAuth` have run), so it reaches the full precedence — `ak_user_uuid:` when both are set, otherwise `user_uuid:`/`ak:`/`ip:` (issue #73). This template still has no user-facing rate limiting (see `ratelimit-hertz` for that); it does ship a `RateLimit` middleware and `RateLimitConfig`/`PreAuth`/`PostAuth` types that are never wired into `server.go` or the router — they exist only to satisfy a compile-time dependency from `ncgo`'s built-in default DB-repository scaffold (`internal/repository/rate_limit_rule.go`, generated regardless of this template's own files), not because this template offers rate limiting itself."

- [ ] **Step 2: Update `ratelimit-hertz/README.md:270`**

Replace the sentence starting "Registration order limits what's actually reachable today ..." through "Tracked separately as issue #73." with:

> "All branches are now reachable: `idempotency.go` is registered on the `protected` group after both `SignatureAuth` and `JWTAuth`, so it sees the full `ak_user_uuid:`/`user_uuid:`/`ak:`/`ip:` precedence. `rate_limit.go`'s `pre_auth` phase stays engine-level (IP-based, before any routing work, for DoS mitigation); `post_auth` is registered on `protected` after `JWTAuth`, so `Claims.AK`/`Uid` are available there too (issue #73)."

- [ ] **Step 3: Update `admin-bff-hertz/README.md:371`**

Replace the sentence starting "Registration order limits what's actually reachable today ..." through "Tracked separately as issue #73." with:

> "`idempotency.go` is registered once per route group: on the public `auth` group (`/auth/login`, `/auth/refresh` — `ak:`/`ip:` scope only, no `Uid` before authentication) and on the `protected` group after `JWTAuth` (full `ak_user_uuid:`/`user_uuid:`/`ak:`/`ip:` precedence). This package's only `rate_limit.go` call site is the `password_change` phase on the password-reset route, already correctly positioned inside `protected` after `JWTAuth` (issue #73)."

- [ ] **Step 4: Verify no other stale cross-references remain**

Run: `grep -rn "issue #73\|tracked as #73\|Tracked separately as issue #73" base-hertz/README.md ratelimit-hertz/README.md admin-bff-hertz/README.md`
Expected: the three updated lines still mention "#73" (that's fine — they now describe the resolution, not an open question) but no longer say "not yet reachable" or "tracked separately" as an open item.

- [ ] **Step 5: Commit**

```bash
git add base-hertz/README.md ratelimit-hertz/README.md admin-bff-hertz/README.md
git commit -m "docs: update AK/Uid reachability notes now that #73 is fixed"
```

---

## Final Verification

After all 5 tasks:

- [ ] Confirm `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml` and its config fields in `internal_base_conf_conf_go.yaml` are untouched (Task 2 was skipped) — `git diff main...HEAD -- base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml base-hertz/hertz-template/internal_base_conf_conf_go.yaml` should show no changes from this branch.
- [ ] For each of the 3 templates, generate a fresh project and run `go build ./... && go vet ./... && go test ./...` — all green.
- [ ] Each package's existing `test/e2e_test.sh` — still green.
- [ ] `git log --oneline` shows commits for Tasks 1, 3, 4, 5 (Task 2 skipped, no commit expected).
