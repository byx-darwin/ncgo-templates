# base-hertz Rate-Limit Dead Code Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Revision note:** This plan replaces an earlier version that proposed
> porting the `internal/pkg/ratelimit` package into `base-hertz` (option 1).
> That approach was reversed after discovering `base-hertz/README.md`
> explicitly states the template does NOT include rate limiting, and the
> commit that introduced `RateLimitConfig` (`6aefd85`) says it meant to
> remove rate-limit from base-hertz but left dead code behind. This plan
> implements the deletion (option 2) instead. See the design doc's
> "根因（修订）" section for the full evidence.

**Goal:** Make `base-hertz` template render a project that compiles, by removing the rate-limit dead code it was never supposed to have — the `internal/repository/rate_limit_rule.go` template, the leftover `repository.NewRateLimitRuleRepository()` call in `server.go`, and the orphaned `RateLimitConfig` types/defaults/validation in `conf.go`.

**Architecture:** Three template files change. `server.go` loses one call and one now-dead import. `conf.go` loses the `RateLimitConfig` type tree (8 types), its default-value block, its `Validate()` branch, and 4 helper functions — while keeping `RedisConfig`/`MemoryCacheConfig`, which `Idempotency` and `Auth.Signature.Nonce` still use. Two whole template files (the repository .go + _test.go) are deleted outright. A stale comment in the dev config YAML is corrected.

**Tech Stack:** Go, `ncgo` template engine (YAML template files with `{{.Module}}` etc. placeholders), Hertz framework.

**Spec:** `docs/superpowers/specs/2026-09-08-base-hertz-ratelimit-pkg-design.md`

## Global Constraints

- Do not touch `RedisConfig`, `MemoryCacheConfig`, or any of their usages outside the `RateLimitConfig` tree — both types are shared with `Idempotency` and `Auth.Signature.Nonce`.
- Do not touch the `do`/`injector` dependency-injection scaffold in `server.go` (the `ncgo:wire:ddd` block) beyond removing the one `repository.NewRateLimitRuleRepository()` line — it is a generic extension point for future repositories, not rate-limit-specific.
- Do not modify `base-hertz/README.md` — it already correctly states the template has no rate limiting; this plan makes the code match the docs, not the other way round.
- `ratelimit-hertz/` is not touched by this plan at all.

---

### Task 1: Reproduce the build failure (RED)

**Files:**
- None modified — this task only renders a scratch project to confirm the reported failure.

**Interfaces:**
- Consumes: `ncgo` CLI (`ncgo new <name> --module <mod> --kind hertz --template-dir base-hertz --dir <dir>`).
- Produces: nothing persisted — a throwaway scratch dir under `/tmp`.

- [ ] **Step 1: Render base-hertz to a scratch project**

```bash
rm -rf /tmp/base-hertz-e2e && mkdir -p /tmp/base-hertz-e2e
ncgo new rlcheck --module example.com/rlcheck --kind hertz \
  --template-dir base-hertz --dir /tmp/base-hertz-e2e/rlcheck
```

- [ ] **Step 2: Run `go build` and confirm it fails**

```bash
cd /tmp/base-hertz-e2e/rlcheck && go mod tidy >/dev/null 2>&1; go build ./... ; cd -
```

Expected: FAIL — unresolved import for `internal/pkg/ratelimit` (from
`internal/repository/rate_limit_rule.go`), matching Issue #42's report.

No commit for this task — it produces no repo changes.

---

### Task 2: Delete the rate-limit repository template files

**Files:**
- Delete: `base-hertz/hertz-template/internal_repository_rate_limit_rule_go.yaml`
- Delete: `base-hertz/hertz-template/internal_repository_rate_limit_rule_test_go.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — this is the file whose missing dependency (`internal/pkg/ratelimit`) caused the original build failure; deleting it removes that dependency entirely.

- [ ] **Step 1: Delete both files**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git rm base-hertz/hertz-template/internal_repository_rate_limit_rule_go.yaml \
       base-hertz/hertz-template/internal_repository_rate_limit_rule_test_go.yaml
```

- [ ] **Step 2: Confirm no other template file still references these paths**

```bash
grep -rl "internal_repository_rate_limit_rule" base-hertz/hertz-template/ || echo "no references — clean"
```

Expected: `no references — clean` (Task 3 will remove the one remaining
reference, the `repository.NewRateLimitRuleRepository()` call in
`server.go`, which is handled separately since it's a modify, not a delete).

- [ ] **Step 3: Commit**

```bash
git commit -m "fix(base-hertz): delete unused rate-limit repository template"
```

---

### Task 3: Remove the dead call and import from `server.go`

**Files:**
- Modify: `base-hertz/hertz-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes: nothing from Task 2 directly (this is a text edit), but must run after Task 2 so the repository package genuinely no longer exists in the generated project.
- Produces: a `server.go` template with no reference to the deleted `internal/repository` package.

- [ ] **Step 1: Remove the now-unused `internal/repository` import**

Current (lines 23-27):

```
        "{{.Module}}/internal/base/conf"
    {{if .WithDatabase}}
        "{{.Module}}/internal/base/data"
        "{{.Module}}/internal/repository"
    {{end}}
```

Change to:

```
        "{{.Module}}/internal/base/conf"
    {{if .WithDatabase}}
        "{{.Module}}/internal/base/data"
    {{end}}
```

- [ ] **Step 2: Remove the `repository.NewRateLimitRuleRepository()` call**

Current:

```
            dbData = do.MustInvoke[*data.Data](injector)
            repository.NewRateLimitRuleRepository()
        }
        {{end}}
```

Change to:

```
            dbData = do.MustInvoke[*data.Data](injector)
        }
        {{end}}
```

Do NOT remove the `do.New()`/`ProvideValue`/`MustInvoke` lines above this —
per Global Constraints, that DI scaffold is a generic `ncgo:wire:ddd`
extension point, not rate-limit-specific.

- [ ] **Step 3: Render and confirm the repository import/call are gone from generated code**

```bash
rm -rf /tmp/base-hertz-e2e && mkdir -p /tmp/base-hertz-e2e
ncgo new rlcheck --module example.com/rlcheck --kind hertz \
  --template-dir base-hertz --dir /tmp/base-hertz-e2e/rlcheck
grep -n "internal/repository\|NewRateLimitRuleRepository" /tmp/base-hertz-e2e/rlcheck/internal/base/server/server.go
```

Expected: no output (no matches).

- [ ] **Step 4: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add base-hertz/hertz-template/internal_base_server_server_go.yaml
git commit -m "fix(base-hertz): remove dead rate-limit repository call from server.go"
```

---

### Task 4: Remove `RateLimitConfig` and its supporting types from `conf.go`

**Files:**
- Modify: `base-hertz/hertz-template/internal_base_conf_conf_go.yaml`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a `conf.go` template with no `RateLimit*` symbols; `RedisConfig` and `MemoryCacheConfig` remain untouched for `Idempotency`/`Auth.Signature.Nonce` to keep using.

- [ ] **Step 1: Remove the `RateLimit` field from the top-level `Config` struct**

Current:

```
        CORS CORSConfig `yaml:"cors"`
        RateLimit RateLimitConfig `yaml:"rate_limit"`
        Idempotency IdempotencyConfig `yaml:"idempotency"`
```

Change to:

```
        CORS CORSConfig `yaml:"cors"`
        Idempotency IdempotencyConfig `yaml:"idempotency"`
```

- [ ] **Step 2: Remove the 8 `RateLimit*` type definitions**

Current (immediately after `type LogConfig struct {...}` and before `type RedisConfig struct {...}`):

```
    type RateLimitConfig struct {
        Enabled      bool                    `yaml:"enabled"`
        Mode         string                  `yaml:"mode"`                 // shadow | enforce
        Static       StaticLimitConfig       `yaml:"static"`
        Source       RateLimitSourceConfig   `yaml:"source"`
        GRPC         RateLimitGRPCConfig     `yaml:"grpc"`
        RuleCenter   RateLimitDatabaseConfig `yaml:"rule_center"`
        Database     RateLimitDatabaseConfig `yaml:"database"`
        Backend      string                  `yaml:"backend"`
        FailOpen     bool                    `yaml:"fail_open"`
        KeyPrefix    string                  `yaml:"key_prefix"`
        AppKeyHeader string                  `yaml:"app_key_header"`
        SkipPaths    []string                `yaml:"skip_paths"`
        PreAuth      RateLimitPhaseConfig    `yaml:"pre_auth"`
        PostAuth     RateLimitPhaseConfig    `yaml:"post_auth"`
        Memory       MemoryCacheConfig       `yaml:"memory"`
        Redis        RedisConfig    `yaml:"redis"`
    }
    
    type StaticLimitConfig struct {
        MaxQPS         int `yaml:"max_qps"`
        MaxConnections int `yaml:"max_connections"`
    }
    
    type RateLimitSourceConfig struct {
        Type            string          `yaml:"type"`
        CacheTTLSeconds config.Duration `yaml:"cache_ttl_seconds"`
        FallbackOnError bool            `yaml:"fallback_on_error"`
    }
    
    type RateLimitGRPCConfig struct {
        Target              string          `yaml:"target"`
        TimeoutMilliseconds config.Duration `yaml:"timeout_milliseconds"`
        AuthHeader          string          `yaml:"auth_header"`
        AuthToken           string          `yaml:"auth_token"`
        ServiceName         string          `yaml:"service_name"`
    }
    
    type RateLimitDatabaseConfig struct {
        QueryTimeoutMilliseconds config.Duration `yaml:"query_timeout_milliseconds"`
    }
    
    type RateLimitPhaseConfig struct {
        Enabled     bool                   `yaml:"enabled"`
        DefaultRule RateLimitRuleConfig    `yaml:"default_rule"`
        Rules       []RateLimitMatchConfig `yaml:"rules"`
    }
    
    type RateLimitMatchConfig struct {
        AppKey      string            `yaml:"app_key"`
        Method      string            `yaml:"method"`
        MatchKind   string            `yaml:"match_kind"`
        Path        string            `yaml:"path"`
        PathPattern string            `yaml:"path_pattern"`
        PathPrefix  string            `yaml:"path_prefix"`
        Priority    int               `yaml:"priority"`
        Rule        RateLimitRuleConfig `yaml:"rule"`
    }
    
    type RateLimitRuleConfig struct {
        Enabled           bool            `yaml:"enabled"`
        KeyBy             []string        `yaml:"key_by"`
        Strategy          string          `yaml:"strategy"`
        WindowSeconds     config.Duration `yaml:"window_seconds"`
        MaxRequests       int             `yaml:"max_requests"`
        RequestsPerSecond float64         `yaml:"requests_per_second"`
        Burst             int             `yaml:"burst"`
        ClientTTLSeconds  config.Duration `yaml:"client_ttl_seconds"`
    }
    
    type RedisConfig struct {
```

Change to (delete everything between `type LogConfig struct {...}` and
`type RedisConfig struct {`, keeping `RedisConfig` itself untouched):

```
    type RedisConfig struct {
```

- [ ] **Step 3: Remove the `RateLimit: RateLimitConfig{...}` default-value block**

Current (inside the function that builds default config, between the `CORS:` block and the `Idempotency:` block):

```
            CORS: CORSConfig{
                AllowOrigins:  []string{"*"},
                AllowMethods:  []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
                AllowHeaders:  []string{"Content-Type", "Authorization", "X-Authorization", "X-Request-ID", "X-App-Key", "X-Timestamp", "X-Nonce", "X-Signature", "X-Idempotency-Key"},
                ExposeHeaders: []string{"X-Request-ID"},
                MaxAgeSeconds: config.Duration{Duration: 600 * time.Second},
            },
            RateLimit: RateLimitConfig{
                Source: RateLimitSourceConfig{
                    Type:            "config",
                    CacheTTLSeconds: config.Duration{Duration: 60 * time.Second},
                    FallbackOnError: true,
                },
                GRPC: RateLimitGRPCConfig{
                    TimeoutMilliseconds: config.Duration{Duration: 200 * time.Millisecond},
                    AuthHeader:          "Authorization",
                },
                Database: RateLimitDatabaseConfig{
                    QueryTimeoutMilliseconds: config.Duration{Duration: 200 * time.Millisecond},
                },
                Backend:      "memory",
                KeyPrefix:    "rate_limit",
                AppKeyHeader: "X-App-Key",
                Memory:       MemoryCacheConfig{MaxEntries: 100000},
                SkipPaths:    []string{"/healthz", "/readyz"},
                PreAuth: RateLimitPhaseConfig{
                    Enabled: true,
                    DefaultRule: RateLimitRuleConfig{
                        Enabled:          true,
                        KeyBy:            []string{"ak_path", "ip"},
                        Strategy:         "fixed_window",
                        WindowSeconds:    config.Duration{Duration: 60 * time.Second},
                        MaxRequests:      100,
                        ClientTTLSeconds: config.Duration{Duration: 300 * time.Second},
                    },
                },
                PostAuth: RateLimitPhaseConfig{
                    DefaultRule: RateLimitRuleConfig{
                        Enabled:          true,
                        KeyBy:            []string{"ak_user_uuid", "user_uuid", "ak"},
                        Strategy:         "fixed_window",
                        WindowSeconds:    config.Duration{Duration: 60 * time.Second},
                        MaxRequests:      50,
                        ClientTTLSeconds: config.Duration{Duration: 300 * time.Second},
                    },
                },
            },
            Idempotency: IdempotencyConfig{
```

Change to:

```
            CORS: CORSConfig{
                AllowOrigins:  []string{"*"},
                AllowMethods:  []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
                AllowHeaders:  []string{"Content-Type", "Authorization", "X-Authorization", "X-Request-ID", "X-App-Key", "X-Timestamp", "X-Nonce", "X-Signature", "X-Idempotency-Key"},
                ExposeHeaders: []string{"X-Request-ID"},
                MaxAgeSeconds: config.Duration{Duration: 600 * time.Second},
            },
            Idempotency: IdempotencyConfig{
```

- [ ] **Step 4: Remove the `RateLimit.Redis` merge line**

Current:

```
        c.Redis = mergeRedisConfig(c.Redis, defaultRedisConfig())
        c.RateLimit.Redis = mergeRedisConfig(c.RateLimit.Redis, c.Redis)
        c.Idempotency.Redis = mergeRedisConfig(c.Idempotency.Redis, c.Redis)
```

Change to:

```
        c.Redis = mergeRedisConfig(c.Redis, defaultRedisConfig())
        c.Idempotency.Redis = mergeRedisConfig(c.Idempotency.Redis, c.Redis)
```

- [ ] **Step 5: Remove the `RateLimit` validation block from `Validate()`**

Current:

```
        if c.CORS.Enabled && c.CORS.AllowCredentials && hasWildcard(c.CORS.AllowOrigins) {
            return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("cors.allow_credentials cannot be true when allow_origins contains *")
        }
        if c.RateLimit.Enabled {
            switch c.RateLimit.Source.Type {
            case "", "config", "grpc", "database", "rule_center":
            default:
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("rate_limit.source.type must be config, grpc, or database")
            }
            if c.RateLimit.Source.Type == "grpc" && c.RateLimit.GRPC.TimeoutMilliseconds.Duration <= 0 {
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("rate_limit.grpc.timeout_milliseconds must be positive")
            }
            if c.RateLimit.Source.Type == "database" && c.RateLimit.Database.QueryTimeoutMilliseconds.Duration <= 0 {
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("rate_limit.database.query_timeout_milliseconds must be positive")
            }
            switch c.RateLimit.Backend {
            case "", "memory", "redis":
            default:
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("rate_limit.backend must be memory or redis")
            }
            if c.RateLimit.Backend == "redis" && len(c.RateLimit.Redis.Addrs) == 0 {
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("rate_limit.redis.addrs is empty")
            }
            if c.RateLimit.Backend == "memory" && c.RateLimit.Memory.MaxEntries < 0 {
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("rate_limit.memory.max_entries must not be negative")
            }
            if !c.RateLimit.PreAuth.Enabled && !c.RateLimit.PostAuth.Enabled {
                return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("at least one rate_limit phase must be enabled")
            }
            if err := validateRateLimitPhase("rate_limit.pre_auth", c.RateLimit.PreAuth); err != nil {
                return err
            }
            if err := validateRateLimitPhase("rate_limit.post_auth", c.RateLimit.PostAuth); err != nil {
                return err
            }
        }
        if c.Idempotency.Enabled {
```

Change to:

```
        if c.CORS.Enabled && c.CORS.AllowCredentials && hasWildcard(c.CORS.AllowOrigins) {
            return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("cors.allow_credentials cannot be true when allow_origins contains *")
        }
        if c.Idempotency.Enabled {
```

- [ ] **Step 6: Remove the 4 `RateLimit*` validation helper functions**

Current (between `if !cc.Enabled { return nil } return nil }` and
`func validateLogging(...)`):

```
    func validateRateLimitPhase(name string, phase RateLimitPhaseConfig) error {
        if !phase.Enabled {
            return nil
        }
        if err := validateRateLimitRule(name+".default_rule", phase.DefaultRule); err != nil {
            return err
        }
        for i, rule := range phase.Rules {
            if err := validateRateLimitMatch(name, i, rule); err != nil {
                return err
            }
        }
        return nil
    }
    
    func validateRateLimitMatch(name string, index int, match RateLimitMatchConfig) error {
        normalized, err := normalizeRateLimitMatch(match)
        if err != nil {
            _ = index
            return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").Wrap(err)
        }
        if err := validateRateLimitRule(name+".rules["+string(rune('0'+index))+"]", normalized.Rule); err != nil {
            return err
        }
        return nil
    }
    
    func normalizeRateLimitMatch(match RateLimitMatchConfig) (RateLimitMatchConfig, error) {
        if match.PathPrefix != "" && match.MatchKind == "" {
            match.MatchKind = "prefix"
        }
        return match, nil
    }
    
    func validateRateLimitRule(name string, rule RateLimitRuleConfig) error {
        if !rule.Enabled {
            return nil
        }
        if len(rule.KeyBy) == 0 {
            return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New(name + ".key_by must not be empty")
        }
        if rule.WindowSeconds.Duration <= 0 && rule.MaxRequests <= 0 && rule.RequestsPerSecond <= 0 {
            return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New(name + " must specify window_seconds/max_requests or requests_per_second")
        }
        if rule.ClientTTLSeconds.Duration < 0 {
            return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New(name + ".client_ttl_seconds must not be negative")
        }
        return nil
    }
    
    func validateLogging(l LoggingConfig) error {
```

Change to (delete all 4 functions, keep `validateLogging` and everything
around it):

```
    func validateLogging(l LoggingConfig) error {
```

- [ ] **Step 7: Confirm no `RateLimit` symbol remains in the file**

```bash
grep -n "RateLimit" base-hertz/hertz-template/internal_base_conf_conf_go.yaml || echo "clean"
```

Expected: `clean`.

- [ ] **Step 8: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add base-hertz/hertz-template/internal_base_conf_conf_go.yaml
git commit -m "fix(base-hertz): remove orphaned RateLimitConfig from conf.go"
```

---

### Task 5: Fix the stale comment in the dev config YAML

**Files:**
- Modify: `base-hertz/hertz-template/conf_dev_conf_yaml.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed elsewhere — pure doc-comment correction.

- [ ] **Step 1: Update the comment that still lists `rate_limit` as a consumer of the shared Redis config**

Current (line 42):

```
    # Redis 连接配置：作为共享默认值供 rate_limit / idempotency / signature nonce 复用
```

Change to:

```
    # Redis 连接配置：作为共享默认值供 idempotency / signature nonce 复用
```

- [ ] **Step 2: Commit**

```bash
git add base-hertz/hertz-template/conf_dev_conf_yaml.yaml
git commit -m "docs(base-hertz): drop stale rate_limit mention from dev config comment"
```

---

### Task 6: Full end-to-end verification (GREEN)

**Files:**
- None modified — verification only.

**Interfaces:**
- Consumes: all deletions/edits from Tasks 2-5.
- Produces: nothing — confirms the fix closes Issue #42.

- [ ] **Step 1: Render base-hertz to a fresh scratch project (WithDatabase, since that's the path that was broken)**

```bash
rm -rf /tmp/base-hertz-e2e && mkdir -p /tmp/base-hertz-e2e
ncgo new rlcheck --module example.com/rlcheck --kind hertz \
  --template-dir base-hertz --dir /tmp/base-hertz-e2e/rlcheck
```

- [ ] **Step 2: Run `go build` and confirm it now succeeds**

```bash
cd /tmp/base-hertz-e2e/rlcheck && go mod tidy && go build ./...
```

Expected: PASS — no output, exit code 0. GREEN counterpart to Task 1's RED.

- [ ] **Step 3: Confirm no rate-limit residue in generated code**

```bash
grep -rn "RateLimit\|ratelimit" . --include='*.go'
```

Expected: no matches (run from inside `/tmp/base-hertz-e2e/rlcheck`).

- [ ] **Step 4: Run the full test suite for the scratch project as a regression check**

```bash
go test ./...
```

Expected: PASS — no regressions in `idempotency`/`signature` (which still
use `RedisConfig`/`MemoryCacheConfig`) or any other package.

- [ ] **Step 5: Clean up the scratch project**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
rm -rf /tmp/base-hertz-e2e
```

No commit for this task — it produces no repo changes beyond what Tasks 2-5 already committed.
