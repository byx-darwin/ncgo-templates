# base-hertz Missing ratelimit Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `base-hertz` template render a project that compiles, by porting the missing `internal/pkg/ratelimit` package and `internal/pkg/middleware/rate_limit.go` from `ratelimit-hertz`, and wiring the rate-limit middleware into `server.go`.

**Architecture:** `base-hertz`'s `conf.go` and `internal/repository/rate_limit_rule.go` already carry full rate-limit config/repository support (copied from `ratelimit-hertz` in an earlier, incomplete migration). This plan copies the three files `ratelimit-hertz` has that `base-hertz` lacks — `internal/pkg/ratelimit/resolver.go`, `internal/pkg/ratelimit/store.go`, `internal/pkg/middleware/rate_limit.go` (plus their `_test.go` companions) — byte-for-byte, since their `package ratelimit` / `package middleware` implementations are generic and don't reference anything `ratelimit-hertz`-specific. `server.go` then gets the same `ratelimit` import and `if cfg.RateLimit.Enabled { ... }` middleware wiring block that `ratelimit-hertz` has, inserted at the same place, while every line unique to `base-hertz` (the `pbhandler`/`usecasepb` DDD wiring) stays untouched.

**Tech Stack:** Go, `ncgo` template engine (YAML template files with `{{.Module}}` etc. placeholders), Hertz framework.

**Spec:** `docs/superpowers/specs/2026-09-08-base-hertz-ratelimit-pkg-design.md`

## Global Constraints

- Template files use `update_behavior: type: cover` and no `loop_service` for all six ported files — copy verbatim, do not add per-service looping.
- `server.go`'s `import` block keeps its existing alphabetical grouping: `"{{.Module}}/internal/pkg/middleware"` then `"{{.Module}}/internal/pkg/ratelimit"` then `"{{.Module}}/internal/pkg/response"`.
- The rate-limit middleware wiring block is **not** gated by `{{if .WithDatabase}}` — `cfg.RateLimit` is populated unconditionally in `conf.go`, matching `ratelimit-hertz`'s placement (after OTel tracing, before the `{{if .WithDatabase}}` DDD block).
- Do not touch `repository.NewRateLimitRuleRepository()` — its discarded-return-value form is inherited as-is from `ratelimit-hertz` and is out of scope for this issue.
- `ratelimit-hertz/` is a read-only copy source — no changes to any file under it.

---

### Task 1: Reproduce the build failure (RED)

**Files:**
- None modified — this task only renders a scratch project to confirm the reported failure.

**Interfaces:**
- Consumes: `ncgo` CLI (`ncgo new <name> --module <mod> --kind hertz --template-dir base-hertz --dir <dir>`), already installed at `/Users/xs/go/bin/ncgo`.
- Produces: nothing persisted — a throwaway scratch dir under `/tmp`.

- [ ] **Step 1: Render base-hertz to a scratch project**

```bash
rm -rf /tmp/base-hertz-e2e && mkdir -p /tmp/base-hertz-e2e
ncgo new rlcheck --module example.com/rlcheck --kind hertz \
  --template-dir base-hertz --dir /tmp/base-hertz-e2e/rlcheck
```

- [ ] **Step 2: Run `go build` and confirm it fails with the reported error**

```bash
cd /tmp/base-hertz-e2e/rlcheck && go mod tidy >/dev/null 2>&1; go build ./... ; cd -
```

Expected: FAIL — `internal/repository/rate_limit_rule.go` reports
`package example.com/rlcheck/internal/pkg/ratelimit is not in std`
(or equivalent "no such file or directory" / unresolved import error).
This confirms Issue #42's reproduction before any fix is applied.

No commit for this task — it produces no repo changes.

---

### Task 2: Port `internal/pkg/ratelimit` template files

**Files:**
- Create: `base-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- Create: `base-hertz/hertz-template/internal_pkg_ratelimit_resolver_test_go.yaml`
- Create: `base-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`
- Create: `base-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: the `internal/pkg/ratelimit` package (`ratelimit.NewResolver`, `ratelimit.Options`, `ratelimit.Lookup`, `ratelimit.DatabaseHook`) that Task 4's `server.go` wiring and the existing `internal_repository_rate_limit_rule_go.yaml` both depend on.

- [ ] **Step 1: Copy the four template files verbatim from `ratelimit-hertz`**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
cp ratelimit-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml \
   base-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml
cp ratelimit-hertz/hertz-template/internal_pkg_ratelimit_resolver_test_go.yaml \
   base-hertz/hertz-template/internal_pkg_ratelimit_resolver_test_go.yaml
cp ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml \
   base-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml
cp ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml \
   base-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml
```

- [ ] **Step 2: Verify the copies are byte-identical to the source**

```bash
diff base-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml ratelimit-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml
diff base-hertz/hertz-template/internal_pkg_ratelimit_resolver_test_go.yaml ratelimit-hertz/hertz-template/internal_pkg_ratelimit_resolver_test_go.yaml
diff base-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml
diff base-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml
```

Expected: no output from any `diff` (identical).

- [ ] **Step 3: Commit**

```bash
git add base-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml \
        base-hertz/hertz-template/internal_pkg_ratelimit_resolver_test_go.yaml \
        base-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml \
        base-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml
git commit -m "fix(base-hertz): port internal/pkg/ratelimit templates from ratelimit-hertz"
```

---

### Task 3: Port `internal/pkg/middleware/rate_limit.go` template files

**Files:**
- Create: `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- Create: `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`

**Interfaces:**
- Consumes: `internal/pkg/ratelimit` package from Task 2 (`ratelimit.NewResolver`, etc. — `middleware.RateLimit` takes a resolver produced by that package).
- Produces: `middleware.RateLimit(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver) app.HandlerFunc` (exact signature per the copied file), consumed by Task 4's `server.go` wiring.

- [ ] **Step 1: Copy the two template files verbatim from `ratelimit-hertz`**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
cp ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
   base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml
cp ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml \
   base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml
```

- [ ] **Step 2: Verify the copies are byte-identical to the source**

```bash
diff base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml
diff base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml
```

Expected: no output from either `diff`.

- [ ] **Step 3: Commit**

```bash
git add base-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml
git commit -m "fix(base-hertz): port internal/pkg/middleware/rate_limit template from ratelimit-hertz"
```

---

### Task 4: Wire rate-limit middleware into `server.go`

**Files:**
- Modify: `base-hertz/hertz-template/internal_base_server_server_go.yaml` (currently 133 lines)

**Interfaces:**
- Consumes: `ratelimit.NewResolver`, `ratelimit.Options` (Task 2); `middleware.RateLimit` (Task 3).
- Produces: nothing consumed by later tasks — this is the final wiring point.

- [ ] **Step 1: Add the `ratelimit` import**

Current (line 28-33 of `base-hertz/hertz-template/internal_base_server_server_go.yaml`):

```
        "{{.Module}}/internal/handler/health"
        pbhandler "{{.Module}}/internal/handler/pb"
        "{{.Module}}/internal/pkg/middleware"
        "{{.Module}}/internal/pkg/response"
        "{{.Module}}/internal/router"
        usecasepb "{{.Module}}/internal/usecase/pb"
```

Change to:

```
        "{{.Module}}/internal/handler/health"
        pbhandler "{{.Module}}/internal/handler/pb"
        "{{.Module}}/internal/pkg/middleware"
        "{{.Module}}/internal/pkg/ratelimit"
        "{{.Module}}/internal/pkg/response"
        "{{.Module}}/internal/router"
        usecasepb "{{.Module}}/internal/usecase/pb"
```

- [ ] **Step 2: Insert the middleware wiring block after the OTel tracing block**

Current (ends the OTel block, then goes straight to the logging-wiring comment):

```
            h.Use(provider.ServerMiddleware())
        }

        // Optional structured logging wiring (after `ncgo add infra logging`):
```

Change to:

```
            h.Use(provider.ServerMiddleware())
        }

        // Rate-limit middleware — pre-auth & post-auth phases (memory/redis backend)
        if cfg.RateLimit.Enabled {
            rlResolver := ratelimit.NewResolver(cfg.RateLimit, ratelimit.Options{})
            h.Use(middleware.RateLimit("pre_auth", cfg.RateLimit, cfg.RateLimit.PreAuth, rlResolver))
            h.Use(middleware.RateLimit("post_auth", cfg.RateLimit, cfg.RateLimit.PostAuth, rlResolver))
        }

        // Optional structured logging wiring (after `ncgo add infra logging`):
```

- [ ] **Step 3: Update the file's header comment to mention rate-limit wiring**

Current (lines 1-3):

```
# Hertz custom template — base/server.go
# Generates the server entry point using go-framework/hertz.NewHTTPServer.
# Includes database initialization when WithDatabase is enabled.
```

Change to:

```
# Hertz custom template — base/server.go
# Generates the server entry point using go-framework/hertz.NewHTTPServer.
# Includes database initialization when WithDatabase is enabled and rate-limit
# middleware wiring (pre_auth / post_auth) derived from conf.RateLimitConfig.
```

- [ ] **Step 4: Render base-hertz again and confirm the import/wiring appear in generated code**

```bash
rm -rf /tmp/base-hertz-e2e && mkdir -p /tmp/base-hertz-e2e
ncgo new rlcheck --module example.com/rlcheck --kind hertz \
  --template-dir base-hertz --dir /tmp/base-hertz-e2e/rlcheck
grep -n "internal/pkg/ratelimit\|RateLimit.Enabled" /tmp/base-hertz-e2e/rlcheck/internal/base/server/server.go
```

Expected: both the import line and the `if cfg.RateLimit.Enabled {` line are present in the generated `server.go`.

- [ ] **Step 5: Commit**

```bash
git add base-hertz/hertz-template/internal_base_server_server_go.yaml
git commit -m "fix(base-hertz): wire rate-limit middleware into server.go"
```

---

### Task 5: Full end-to-end verification (GREEN)

**Files:**
- None modified — verification only.

**Interfaces:**
- Consumes: all templates ported/modified in Tasks 2-4.
- Produces: nothing — confirms the fix closes Issue #42.

- [ ] **Step 1: Render base-hertz to a fresh scratch project**

```bash
rm -rf /tmp/base-hertz-e2e && mkdir -p /tmp/base-hertz-e2e
ncgo new rlcheck --module example.com/rlcheck --kind hertz \
  --template-dir base-hertz --dir /tmp/base-hertz-e2e/rlcheck
```

- [ ] **Step 2: Run `go build` and confirm it now succeeds**

```bash
cd /tmp/base-hertz-e2e/rlcheck && go mod tidy && go build ./...
```

Expected: PASS — no output, exit code 0. This is the GREEN counterpart to Task 1's RED reproduction.

- [ ] **Step 3: Run `go test` on the ported packages and confirm they pass**

```bash
go test ./internal/pkg/ratelimit/... ./internal/pkg/middleware/...
```

Expected: PASS — `ok` for both packages, no failures.

- [ ] **Step 4: Run the full test suite for the scratch project as a regression check**

```bash
go test ./...
```

Expected: PASS — no regressions introduced in unrelated packages.

- [ ] **Step 5: Clean up the scratch project**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
rm -rf /tmp/base-hertz-e2e
```

No commit for this task — it produces no repo changes beyond what Tasks 2-4 already committed.
