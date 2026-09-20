# Memory-Backend RateLimit Redis-Dial Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `rateLimitWithStore()` from dialing a shared Redis client when `RateLimit.Backend != "redis"`, in the two template packages (`ratelimit-hertz`, `base-hertz`) where the bug is real, with a regression-proof unit test in each.

**Architecture:** Mirror the guard pattern already used by `idempotency.go`/`signature.go` in the same package (`if cfg.Backend == "redis" { sharedRedisClient(cfg.Redis) }`). Turn `sharedRedisClient` from a `func` into a package-level func-typed `var` so tests can swap in a call-counting spy instead of touching the network. This repo is a **template registry**: every file below is a `.yaml` wrapper (`path` + `body`) whose `body` is rendered by Go's `text/template` into a real `.go` file in a generated project — edits are made to the YAML `body` block, and generated/rendered code is only produced by `ncgo new` for verification.

**Tech Stack:** Go 1.x, `github.com/redis/go-redis/v9`, `ncgo` CLI (this repo's own codegen tool) for rendering templates into a throwaway scratch project.

**Spec:** `docs/superpowers/specs/2026-09-20-ratelimit-memory-backend-redis-dial-design.md` (Issue #79, approved)

## Global Constraints

- Do not modify `internal/base/conf/conf.go` / `applyRedisFallbacks()` in either template — out of scope per the approved design.
- Do not modify `user-bff-hertz` or `admin-bff-hertz` — their `sharedRedisClient` is a hardcoded `return nil` stub, confirmed unaffected by this bug.
- Preserve each file's existing brace-escaping style exactly: `ratelimit-hertz`'s `rate_limit_test_go.yaml` uses **plain** `{`/`}` in its `body: |-` block; `base-hertz`'s `rate_limit_test_go.yaml` uses **escaped** `{{ "{" }}` / `{{ "}" }}` around every literal brace (a pre-existing style split between the two files — match whichever file you're editing, don't unify them).
- New code must not change any existing test's behavior — the 9 existing tests in each `rate_limit_test.go` must keep passing unmodified.

---

### Task 1: Fix ratelimit-hertz — gate the Redis client, add the test seam, add regression tests

**Files:**
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`

**Interfaces:**
- Produces: `sharedRedisClient` becomes `var sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {...}` (same call signature as before — `idempotency.go`/`signature.go` call sites in this package are untouched and keep compiling).
- Consumes: `conf.RateLimitConfig.Backend` (string field, already exists), `conf.RateLimitConfig.Redis` (already exists, type `conf.RedisConfig`).

- [ ] **Step 1: Edit `internal_pkg_middleware_redis_client_go.yaml` — turn the func into a func-typed var**

Replace the `body` block's final function with a var declaration (everything else in the file is unchanged):

```yaml
body: |-
    package middleware

    import (
        "github.com/redis/go-redis/v9"

        "{{.Module}}/internal/base/conf"
        "{{.Module}}/internal/base/data"
    )

    // sharedRedisClient returns the process-wide shared Redis client used by the
    // rate-limit store. cfg is rate_limit.redis, which conf.Validate merges from
    // the top-level redis when left empty. Returns nil when no addrs are
    // configured, in which case NewStore falls back to the in-memory store.
    //
    // Declared as a var (not a func) so tests can swap in a spy without a real
    // network dial -- see rate_limit_test.go.
    var sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {
        if len(cfg.Addrs) == 0 {
            return nil
        }
        return data.SharedRedisClient(cfg)
    }
```

- [ ] **Step 2: Edit `internal_pkg_middleware_rate_limit_go.yaml` — gate the call on `cfg.Backend`**

Add the `redis` import and replace the store-construction line inside `rateLimitWithStore`:

```yaml
body: |-
    package middleware

    import (
    	"context"
    	"net"
    	"strings"

    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/redis/go-redis/v9"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/pkg/ratelimit"
    	"{{.Module}}/internal/pkg/response"
    )

    func RateLimit(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver) app.HandlerFunc {
    	return rateLimitWithStore(phase, cfg, phaseCfg, resolver, nil)
    }

    func rateLimitWithStore(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver, store ratelimit.Store) app.HandlerFunc {
    	cfg = ratelimit.NormalizeConfig(cfg)
    	skipper := PathSkipper(cfg.SkipPaths...)
    	if store == nil {
    		var redisClient redis.UniversalClient
    		if cfg.Backend == "redis" {
    			redisClient = sharedRedisClient(cfg.Redis)
    		}
    		store = ratelimit.NewStore(cfg, redisClient)
    	}
    	if resolver == nil {
    		resolver = ratelimit.NewResolver(cfg, ratelimit.Options{})
    	}
```

(Leave every line after `if resolver == nil {` through the end of the file exactly as it is today — only the `import` block and the `if store == nil { ... }` block change.)

- [ ] **Step 3: Edit `internal_pkg_middleware_rate_limit_test_go.yaml` — add the `redis` import**

In the existing `import (...)` block, add `"github.com/redis/go-redis/v9"` next to the other third-party imports:

```go
import (
	"context"
	"errors"
	"testing"
	"time"

	config "github.com/byx-darwin/go-tools/go-framework/config"
	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/redis/go-redis/v9"

	"{{.Module}}/internal/base/conf"
	"{{.Module}}/internal/pkg/ratelimit"
)
```

- [ ] **Step 4: Append two new test functions** right after `TestRedisConfigToMiddleware` (before `func newRateLimitContext`):

```go
func TestRateLimitWithStoreSkipsRedisDialForMemoryBackend(t *testing.T) {
	original := sharedRedisClient
	defer func() { sharedRedisClient = original }()
	called := false
	sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {
		called = true
		return nil
	}

	phase := conf.RateLimitPhaseConfig{Enabled: true, DefaultRule: conf.RateLimitRuleConfig{Enabled: true, KeyBy: []string{"ip"}, Strategy: "fixed_window", WindowSeconds: config.Duration{Duration: 60 * time.Second}, MaxRequests: 5}}
	cfg := conf.RateLimitConfig{Enabled: true, Backend: "memory", KeyPrefix: "test", PreAuth: phase, Redis: conf.RedisConfig{Addrs: []string{"127.0.0.1:6379"}}}
	RateLimit("pre_auth", cfg, phase, nil)

	if called {
		t.Fatalf("sharedRedisClient was called for a memory-backend config; want no Redis dial")
	}
}

func TestRateLimitWithStoreDialsRedisForRedisBackend(t *testing.T) {
	original := sharedRedisClient
	defer func() { sharedRedisClient = original }()
	calls := 0
	var gotCfg conf.RedisConfig
	sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {
		calls++
		gotCfg = cfg
		return nil
	}

	phase := conf.RateLimitPhaseConfig{Enabled: true, DefaultRule: conf.RateLimitRuleConfig{Enabled: true, KeyBy: []string{"ip"}, Strategy: "fixed_window", WindowSeconds: config.Duration{Duration: 60 * time.Second}, MaxRequests: 5}}
	redisCfg := conf.RedisConfig{Addrs: []string{"127.0.0.1:6379"}, DB: 3}
	cfg := conf.RateLimitConfig{Enabled: true, Backend: "redis", KeyPrefix: "test", PreAuth: phase, Redis: redisCfg}
	RateLimit("pre_auth", cfg, phase, nil)

	if calls != 1 {
		t.Fatalf("sharedRedisClient calls = %d, want 1", calls)
	}
	if gotCfg.DB != 3 || len(gotCfg.Addrs) != 1 || gotCfg.Addrs[0] != "127.0.0.1:6379" {
		t.Fatalf("sharedRedisClient called with unexpected config: %+v", gotCfg)
	}
}
```

- [ ] **Step 5: Render and run this template's tests in isolation**

```bash
DIR=$(mktemp -d)
ncgo new rltest --module example.com/rltest --kind hertz \
  --template-dir ratelimit-hertz --dir "$DIR/rltest"
cd "$DIR/rltest" && go mod tidy && go test ./internal/pkg/middleware/... -run TestRateLimitWithStore -v
```

Expected: `TestRateLimitWithStoreSkipsRedisDialForMemoryBackend` and `TestRateLimitWithStoreDialsRedisForRedisBackend` both PASS.

- [ ] **Step 6: Run the full generated test suite for this template to confirm no regressions**

```bash
cd "$DIR/rltest" && go test ./... 2>&1 | tail -40
```

Expected: all packages PASS (no prior test broken by the `var` conversion or the new import).

- [ ] **Step 7: Commit**

```bash
git add ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml
git commit -m "fix(ratelimit-hertz): skip Redis dial when rate_limit.backend != redis (#79)"
```

---

### Task 2: Mirror the fix in base-hertz

**Files:**
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`

**Interfaces:**
- Same as Task 1 — `base-hertz`'s files declare the identical package/type/function names (`sharedRedisClient`, `rateLimitWithStore`, `conf.RateLimitConfig`, `conf.RedisConfig`); this task applies the same transformation to base-hertz's copies.

- [ ] **Step 1: Edit `internal_pkg_middleware_redis_client_go.yaml` — turn the func into a func-typed var**

```yaml
body: |-
    package middleware

    import (
        "github.com/redis/go-redis/v9"

        "{{.Module}}/internal/base/conf"
        "{{.Module}}/internal/base/data"
    )

    // sharedRedisClient returns the process-wide shared Redis client used by
    // the idempotency/signature-nonce/rate-limit stores. cfg is e.g.
    // idempotency.redis or rate_limit.redis, which conf.Validate merges from
    // the top-level redis when left empty. Returns nil when no addrs are
    // configured, in which case the caller falls back to the in-memory store.
    //
    // Declared as a var (not a func) so tests can swap in a spy without a real
    // network dial -- see rate_limit_test.go.
    var sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {
        if len(cfg.Addrs) == 0 {
            return nil
        }
        return data.SharedRedisClient(cfg)
    }
```

- [ ] **Step 2: Edit `internal_pkg_middleware_rate_limit_go.yaml` — gate the call on `cfg.Backend`**

```yaml
body: |-
    package middleware

    import (
    	"context"
    	"net"
    	"strings"

    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/redis/go-redis/v9"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/pkg/ratelimit"
    	"{{.Module}}/internal/pkg/response"
    )

    func RateLimit(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver) app.HandlerFunc {
    	return rateLimitWithStore(phase, cfg, phaseCfg, resolver, nil)
    }

    func rateLimitWithStore(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver, store ratelimit.Store) app.HandlerFunc {
    	cfg = ratelimit.NormalizeConfig(cfg)
    	skipper := PathSkipper(cfg.SkipPaths...)
    	if store == nil {
    		var redisClient redis.UniversalClient
    		if cfg.Backend == "redis" {
    			redisClient = sharedRedisClient(cfg.Redis)
    		}
    		store = ratelimit.NewStore(cfg, redisClient)
    	}
    	if resolver == nil {
    		resolver = ratelimit.NewResolver(cfg, ratelimit.Options{})
    	}
```

(Leave everything after `if resolver == nil {` unchanged.)

- [ ] **Step 3: Edit `internal_pkg_middleware_rate_limit_test_go.yaml` — add the `redis` import**

This file uses the **escaped-brace** style (`{{ "{" }}` / `{{ "}" }}`) throughout its body — the import block itself has no braces to escape, so this edit is plain text:

```go
import (
	"context"
	"errors"
	"testing"
	"time"

	config "github.com/byx-darwin/go-tools/go-framework/config"
	"github.com/cloudwego/hertz/pkg/app"
	"github.com/cloudwego/hertz/pkg/protocol"
	"github.com/cloudwego/hertz/pkg/protocol/consts"
	"github.com/redis/go-redis/v9"

	"{{.Module}}/internal/base/conf"
	"{{.Module}}/internal/pkg/ratelimit"
)
```

- [ ] **Step 4: Append two new test functions**, right after `TestRedisConfigToMiddleware`'s closing `{{ "}" }}` (before `func newRateLimitContext`) — written in this file's escaped-brace style:

```
    func TestRateLimitWithStoreSkipsRedisDialForMemoryBackend(t *testing.T) {{ "{" }}
    	original := sharedRedisClient
    	defer func() {{ "{" }} sharedRedisClient = original {{ "}" }}()
    	called := false
    	sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {{ "{" }}
    		called = true
    		return nil
    	{{ "}" }}

    	phase := conf.RateLimitPhaseConfig{{ "{" }}Enabled: true, DefaultRule: conf.RateLimitRuleConfig{{ "{" }}Enabled: true, KeyBy: []string{{ "{" }}"ip"{{ "}" }}, Strategy: "fixed_window", WindowSeconds: config.Duration{{ "{" }}Duration: 60 * time.Second{{ "}" }}, MaxRequests: 5{{ "}" }}{{ "}" }}
    	cfg := conf.RateLimitConfig{{ "{" }}Enabled: true, Backend: "memory", KeyPrefix: "test", PreAuth: phase, Redis: conf.RedisConfig{{ "{" }}Addrs: []string{{ "{" }}"127.0.0.1:6379"{{ "}" }}{{ "}" }}{{ "}" }}
    	RateLimit("pre_auth", cfg, phase, nil)

    	if called {{ "{" }}
    		t.Fatalf("sharedRedisClient was called for a memory-backend config; want no Redis dial")
    	{{ "}" }}
    {{ "}" }}

    func TestRateLimitWithStoreDialsRedisForRedisBackend(t *testing.T) {{ "{" }}
    	original := sharedRedisClient
    	defer func() {{ "{" }} sharedRedisClient = original {{ "}" }}()
    	calls := 0
    	var gotCfg conf.RedisConfig
    	sharedRedisClient = func(cfg conf.RedisConfig) redis.UniversalClient {{ "{" }}
    		calls++
    		gotCfg = cfg
    		return nil
    	{{ "}" }}

    	phase := conf.RateLimitPhaseConfig{{ "{" }}Enabled: true, DefaultRule: conf.RateLimitRuleConfig{{ "{" }}Enabled: true, KeyBy: []string{{ "{" }}"ip"{{ "}" }}, Strategy: "fixed_window", WindowSeconds: config.Duration{{ "{" }}Duration: 60 * time.Second{{ "}" }}, MaxRequests: 5{{ "}" }}{{ "}" }}
    	redisCfg := conf.RedisConfig{{ "{" }}Addrs: []string{{ "{" }}"127.0.0.1:6379"{{ "}" }}, DB: 3{{ "}" }}
    	cfg := conf.RateLimitConfig{{ "{" }}Enabled: true, Backend: "redis", KeyPrefix: "test", PreAuth: phase, Redis: redisCfg{{ "}" }}
    	RateLimit("pre_auth", cfg, phase, nil)

    	if calls != 1 {{ "{" }}
    		t.Fatalf("sharedRedisClient calls = %d, want 1", calls)
    	{{ "}" }}
    	if gotCfg.DB != 3 || len(gotCfg.Addrs) != 1 || gotCfg.Addrs[0] != "127.0.0.1:6379" {{ "{" }}
    		t.Fatalf("sharedRedisClient called with unexpected config: %+v", gotCfg)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 5: Render and run this template's tests in isolation**

```bash
DIR=$(mktemp -d)
ncgo new bhtest --module example.com/bhtest --kind hertz \
  --template-dir base-hertz --dir "$DIR/bhtest"
cd "$DIR/bhtest" && go mod tidy && go test ./internal/pkg/middleware/... -run TestRateLimitWithStore -v
```

Expected: both new tests PASS.

- [ ] **Step 6: Verify no residual template-escape artifacts leaked into generated Go source**

```bash
grep -rn '{{ "{"\|{{ "}"\|{{[^}]*}}' "$DIR/bhtest" --include='*.go'
```

Expected: no output (empty) — confirms every escaped brace and every `{{...}}` directive rendered correctly.

- [ ] **Step 7: Run the full generated test suite for this template to confirm no regressions**

```bash
cd "$DIR/bhtest" && go test ./... 2>&1 | tail -40
```

Expected: all packages PASS.

- [ ] **Step 8: Commit**

```bash
git add base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml
git commit -m "fix(base-hertz): skip Redis dial when rate_limit.backend != redis (#79)"
```

---

### Task 3: Whole-suite verification (both templates, redis variant included)

**Files:** none modified — verification only.

**Interfaces:**
- Consumes: the fixes from Task 1 and Task 2, plus `ratelimit-hertz/test/e2e_test.sh` (existing script, unmodified) which already exercises a hermetic (memory-backend) generation + build + test baseline and a redis-backend variant gated on `redis-cli`.

- [ ] **Step 1: Run ratelimit-hertz's existing e2e test script**

```bash
bash ratelimit-hertz/test/e2e_test.sh
```

Expected: `[e2e] hermetic 基线 build ok` / `test ok` (and the redis variant, if `redis-cli` is available in this environment); exit code 0, no `FAIL` lines.

- [ ] **Step 2: Confirm the acceptance criteria directly — no Redis dial log noise on a memory-backend generated project**

```bash
DIR=$(mktemp -d)
ncgo new rlfinal --module example.com/rlfinal --kind hertz \
  --template-dir ratelimit-hertz --dir "$DIR/rlfinal"
cd "$DIR/rlfinal" && go mod tidy && go test ./... -v 2>&1 | grep -i "redis: connection pool" || echo "no redis dial noise"
```

Expected: `no redis dial noise` printed — proves the fix under a real generated build, not just the mocked unit test.

- [ ] **Step 3: Repeat the base-hertz generation check**

```bash
DIR=$(mktemp -d)
ncgo new bhfinal --module example.com/bhfinal --kind hertz \
  --template-dir base-hertz --dir "$DIR/bhfinal"
cd "$DIR/bhfinal" && go mod tidy && go test ./... -v 2>&1 | grep -i "redis: connection pool" || echo "no redis dial noise"
```

Expected: `no redis dial noise` printed.

- [ ] **Step 4: Clean up scratch directories**

```bash
rm -rf "$DIR"
```

(Repeat for every `mktemp -d` directory created across Tasks 1–3 that wasn't already inside a cleaned-up `$DIR`.)

No commit for this task — it's verification-only, confirming Tasks 1 and 2's commits are correct.
