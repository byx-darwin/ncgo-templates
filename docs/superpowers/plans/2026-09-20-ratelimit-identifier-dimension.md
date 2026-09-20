# Ratelimit Identifier Dimension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an identifier-based key dimension to `internal/pkg/ratelimit`'s `Lookup`/`BuildKey`, and use it to add a handler-level, per-account fine-grained rate-limit check to `user-bff-hertz`'s `password-reset/request` and `password-reset/confirm` endpoints, without touching the existing middleware-level IP-only coarse limiting.

**Architecture:** Two-phase limiting (Approach C). The existing `middleware.RateLimit` code path is untouched. `Lookup` gains an `Identifier` field and `BuildKey` gains `"identifier"`/`"ip_identifier"` keyBy dimensions (both falling through when their inputs are empty, exactly like the existing dimensions). A new `ratelimit.Check` helper wraps Resolve→NormalizeRule→BuildKey→Store.Allow for handler call sites. `AuthHandler` gains a resolver/store/cfg dependency and calls `ratelimit.Check` after parsing the request body, using two new independent `RateLimitConfig` phase fields.

**Tech Stack:** Go, Hertz, the project's own `internal/pkg/ratelimit` package (in-memory LRU / Redis-backed counters), `gotest`/table-style unit tests matching existing `ratelimit` package test conventions.

**Spec:** `docs/superpowers/specs/2026-09-20-ratelimit-identifier-dimension-design.md`

## Global Constraints

- Zero changes to `internal/pkg/middleware/rate_limit.go` in any service template (all modes).
- `Lookup`'s existing fields and `BuildKey`'s existing `keyBy` cases must keep producing byte-identical keys (backward compatibility for `pre_auth`/`post_auth`/`password_change`/etc.).
- The four mirrored `ratelimit` package templates (`user-bff-hertz`, `base-hertz`, `ratelimit-hertz`, `admin-bff-hertz`) must stay in sync on `Lookup`/`BuildKey`/`Check`.
- New config fields use `RateLimitPhaseConfig` (same struct already used by every other phase) — no new struct types.
- Confirm-phase identifier is `req.Phone` (the `confirmPasswordResetReq` struct has no email field).
- Follow the file's existing Jinja/Go-template escaping convention: literal `{` / `}` in the YAML `body:` block are written as `{{ "{" }}` / `{{ "}" }}`.

---

### Task 1: `Lookup.Identifier` + `BuildKey` new dimensions + `ratelimit.Check` (user-bff-hertz)

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml` (the `Lookup` struct, `normalizeLookup`)
- Modify: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml` (`BuildKey`, new `Check` function)
- Create: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`

**Interfaces:**
- Produces: `ratelimit.Lookup{..., Identifier string}`, `ratelimit.BuildKey` cases `"identifier"`/`"ip_identifier"`, `func Check(ctx context.Context, resolver *Resolver, store Store, cfg conf.RateLimitConfig, lookup Lookup) (bool, error)`.

- [ ] **Step 1: Write the failing tests for `BuildKey`'s new dimensions**

Create `user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/ratelimit/store_test.go
path: internal/pkg/ratelimit/store_test.go
update_behavior:
    type: cover
body: |
    package ratelimit

    import "testing"

    func TestBuildKeyByIdentifier(t *testing.T) {{ "{" }}
    	lookup := Lookup{{ "{" }}Identifier: "alice@example.com"{{ "}" }}
    	if got, want := BuildKey(lookup, []string{{ "{" }}"identifier"{{ "}" }}, "test"), "test:identifier:alice@example.com"; got != want {{ "{" }}
    		t.Fatalf("got %q, want %q", got, want)
    	{{ "}" }}
    {{ "}" }}

    func TestBuildKeyByIPIdentifier(t *testing.T) {{ "{" }}
    	lookup := Lookup{{ "{" }}ClientIP: "10.0.0.1", Identifier: "alice@example.com"{{ "}" }}
    	if got, want := BuildKey(lookup, []string{{ "{" }}"ip_identifier"{{ "}" }}, "test"), "test:ip_identifier:10.0.0.1:alice@example.com"; got != want {{ "{" }}
    		t.Fatalf("got %q, want %q", got, want)
    	{{ "}" }}
    {{ "}" }}

    func TestBuildKeyIPIdentifierFallsBackWhenIdentifierEmpty(t *testing.T) {{ "{" }}
    	lookup := Lookup{{ "{" }}ClientIP: "10.0.0.1"{{ "}" }}
    	if got, want := BuildKey(lookup, []string{{ "{" }}"ip_identifier", "ip"{{ "}" }}, "test"), "test:ip:10.0.0.1"; got != want {{ "{" }}
    		t.Fatalf("got %q, want %q", got, want)
    	{{ "}" }}
    {{ "}" }}

    func TestBuildKeyIdentifierFallsBackWhenEmpty(t *testing.T) {{ "{" }}
    	lookup := Lookup{{ "{" }}ClientIP: "10.0.0.1"{{ "}" }}
    	if got, want := BuildKey(lookup, []string{{ "{" }}"identifier", "ip"{{ "}" }}, "test"), "test:ip:10.0.0.1"; got != want {{ "{" }}
    		t.Fatalf("got %q, want %q", got, want)
    	{{ "}" }}
    {{ "}" }}

    func TestBuildKeyExistingDimensionsUnaffected(t *testing.T) {{ "{" }}
    	lookup := Lookup{{ "{" }}AppKey: "app-1", ClientIP: "10.0.0.1"{{ "}" }}
    	if got, want := BuildKey(lookup, []string{{ "{" }}"ak", "ip"{{ "}" }}, "test"), "test:ak:app-1"; got != want {{ "{" }}
    		t.Fatalf("got %q, want %q", got, want)
    	{{ "}" }}
    {{ "}" }}
```

This template must render valid Go — since ncgo templates are only materialized by generating a project, verify template syntax by rendering it manually: confirm every `{` in the intended Go source is written as `{{ "{" }}` and every `}` as `{{ "}" }}` (cross-check against the existing sibling file `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`, which already renders correctly, for the exact escaping pattern).

- [ ] **Step 2: Confirm the tests fail without the implementation**

Since these are ncgo templates (rendered only when a project is generated from them), "run to verify it fails" here means: temporarily render this single template's `body` field to a scratch `.go` file and run `go vet`/`gofmt` on it to confirm it is syntactically valid Go that references `Identifier`/`identifier`/`ip_identifier`, which do not exist yet in the current (unmodified) `resolver.go`/`store.go` templates. Concretely:

```bash
cd user-bff-hertz/hertz-template
python3 -c "
import yaml
doc = yaml.safe_load(open('internal_pkg_ratelimit_store_test_go.yaml'))
print(doc['body'].replace('{{ \"{\" }}', '{').replace('{{ \"}\" }}', '}'))
" > /tmp/store_test_scratch.go
gofmt -l /tmp/store_test_scratch.go
```

Expected: `gofmt -l` reports no formatting errors (the template body is valid Go syntax) — this is a template-authoring sanity check, not a "test fails" check, since there's no compiled package at this stage of a templates-only repo. Record that `Identifier`/`identifier`/`ip_identifier` are new symbols the next steps must add.

- [ ] **Step 3: Add `Identifier` to `Lookup` and normalize it**

In `user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`, change:

```yaml
    type Lookup struct {{ "{" }}
    	Service  string
    	Phase    string
    	AppKey   string
    	Method   string
    	Path     string
    	UserUUID string
    	ClientIP string
    {{ "}" }}
```

to:

```yaml
    type Lookup struct {{ "{" }}
    	Service    string
    	Phase      string
    	AppKey     string
    	Method     string
    	Path       string
    	UserUUID   string
    	ClientIP   string
    	Identifier string
    {{ "}" }}
```

and in `normalizeLookup`, change:

```yaml
    func normalizeLookup(lookup Lookup) Lookup {{ "{" }}
    	lookup.Service = strings.TrimSpace(lookup.Service)
    	lookup.Phase = strings.ToLower(strings.TrimSpace(lookup.Phase))
    	lookup.AppKey = strings.TrimSpace(lookup.AppKey)
    	lookup.Method = strings.ToUpper(strings.TrimSpace(lookup.Method))
    	lookup.Path = strings.TrimSpace(lookup.Path)
    	lookup.UserUUID = strings.TrimSpace(lookup.UserUUID)
    	lookup.ClientIP = strings.TrimSpace(lookup.ClientIP)
    	return lookup
    {{ "}" }}
```

to:

```yaml
    func normalizeLookup(lookup Lookup) Lookup {{ "{" }}
    	lookup.Service = strings.TrimSpace(lookup.Service)
    	lookup.Phase = strings.ToLower(strings.TrimSpace(lookup.Phase))
    	lookup.AppKey = strings.TrimSpace(lookup.AppKey)
    	lookup.Method = strings.ToUpper(strings.TrimSpace(lookup.Method))
    	lookup.Path = strings.TrimSpace(lookup.Path)
    	lookup.UserUUID = strings.TrimSpace(lookup.UserUUID)
    	lookup.ClientIP = strings.TrimSpace(lookup.ClientIP)
    	lookup.Identifier = strings.TrimSpace(lookup.Identifier)
    	return lookup
    {{ "}" }}
```

- [ ] **Step 4: Add the two new `BuildKey` cases and the `Check` helper**

In `user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`, in the `BuildKey` function, insert two new `case` branches right before the existing `case "ip":` branch:

```yaml
    		case "identifier":
    			if lookup.Identifier != "" {{ "{" }}
    				return joinKeyParts(prefix, "identifier", lookup.Identifier)
    			{{ "}" }}
    		case "ip_identifier":
    			if lookup.ClientIP != "" && lookup.Identifier != "" {{ "{" }}
    				return joinKeyParts(prefix, "ip_identifier", lookup.ClientIP, lookup.Identifier)
    			{{ "}" }}
    		case "ip":
```

(i.e. the existing `case "ip":` block stays exactly as-is; only the two new cases are inserted above it, inside the same `for _, part := range keyBy { switch ... }` loop.)

Then add `Check` as a new top-level function at the end of the same file (after `ruleTTL`), and add `"context"` to the file's `import` block if not already present (check first — `store.go`'s current imports are `context`, `strings`, `sync`, `time`, `github.com/redis/go-redis/v9`, `github.com/samber/hot`, and the module's `conf` package; `context` is already imported):

```yaml
    // Check resolves the rule for lookup against resolver, builds its counter
    // key, and consults store. It returns (true, nil) when the resolved rule
    // is disabled (no limiting applied). This is the same
    // Resolve -> NormalizeRule -> BuildKey -> Store.Allow sequence the
    // rate-limit middleware runs inline; Check exists for call sites outside
    // the middleware (e.g. handler-level identifier checks) that want the
    // same behavior without duplicating it.
    func Check(ctx context.Context, resolver *Resolver, store Store, cfg conf.RateLimitConfig, lookup Lookup) (bool, error) {{ "{" }}
    	resolved, err := resolver.Resolve(ctx, lookup)
    	if err != nil {{ "{" }}
    		return false, err
    	{{ "}" }}
    	rule := NormalizeRule(resolved.Rule)
    	if !rule.Enabled {{ "{" }}
    		return true, nil
    	{{ "}" }}
    	key := BuildKey(lookup, rule.KeyBy, cfg.KeyPrefix)
    	return store.Allow(ctx, key, rule)
    {{ "}" }}
```

- [ ] **Step 5: Verify the test template renders as valid Go**

Re-run the same scratch-render check as Step 2 for `internal_pkg_ratelimit_store_test_go.yaml`, `internal_pkg_ratelimit_resolver_go.yaml`, and `internal_pkg_ratelimit_store_go.yaml`:

```bash
cd user-bff-hertz/hertz-template
for f in internal_pkg_ratelimit_resolver_go.yaml internal_pkg_ratelimit_store_go.yaml internal_pkg_ratelimit_store_test_go.yaml; do
  python3 -c "
import yaml
doc = yaml.safe_load(open('$f'))
print(doc['body'].replace('{{ \"{\" }}', '{').replace('{{ \"}\" }}', '}'))
" > /tmp/scratch_$f.go
  gofmt -l /tmp/scratch_$f.go
done
```

Expected: no output from any `gofmt -l` (all three render as syntactically valid Go).

- [ ] **Step 6: Generate a scratch project and run the real Go tests**

Templates only prove themselves when rendered into an actual generated project. Use the repo's own generation entrypoint (check `README.md`/`Makefile` at the repo root for the `ncgo` generate command — e.g. `ncgo generate --module github.com/example/scratch --kind user-bff-hertz --out /tmp/scratch-user-bff-hertz` or the project's documented equivalent) to materialize `user-bff-hertz` into a temp directory, then:

```bash
cd /tmp/scratch-user-bff-hertz
go test ./internal/pkg/ratelimit/... -run TestBuildKey -v
```

Expected: `TestBuildKeyByIdentifier`, `TestBuildKeyByIPIdentifier`, `TestBuildKeyIPIdentifierFallsBackWhenIdentifierEmpty`, `TestBuildKeyIdentifierFallsBackWhenEmpty`, `TestBuildKeyExistingDimensionsUnaffected` all PASS. If any prior `BuildKey`/store tests exist from ncgo's built-in defaults, run the full package (`go test ./internal/pkg/ratelimit/...`) and confirm nothing regresses.

- [ ] **Step 7: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml
git commit -m "feat(ratelimit): add identifier key dimension to Lookup/BuildKey (user-bff-hertz)"
```

---

### Task 2: Mirror the `Lookup`/`BuildKey`/`Check` change to `base-hertz`, `ratelimit-hertz`, `admin-bff-hertz`

**Files:**
- Modify: `base-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml` — **if it does not define its own `Lookup`/`BuildKey` fragment, skip this file**; confirm first with `grep -l "type Lookup struct" base-hertz/hertz-template/*.yaml`.
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`, `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`, `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`, `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`, `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`

**Interfaces:**
- Consumes: the exact diffs applied in Task 1, Steps 3–4 (same `Lookup` field, same `normalizeLookup` line, same two `BuildKey` cases, same `Check` function).
- Produces: identical `Lookup`/`BuildKey`/`Check` surface across all four mirrored templates.

- [ ] **Step 1: Confirm which files actually define these fragments in each service**

```bash
grep -l "type Lookup struct" base-hertz/hertz-template/*.yaml ratelimit-hertz/hertz-template/*.yaml admin-bff-hertz/hertz-template/*.yaml
grep -l "func BuildKey" base-hertz/hertz-template/*.yaml ratelimit-hertz/hertz-template/*.yaml admin-bff-hertz/hertz-template/*.yaml
```

Record the matched filenames — `base-hertz` in particular has no `internal_pkg_ratelimit_resolver_go.yaml`/`internal_pkg_ratelimit_store_go.yaml` of its own per the earlier repo scan (its `rate_limit.go` override exists, but its `ratelimit` package resolver/store come from ncgo's built-in default template, not an override in this repo). If `base-hertz` has no override for `resolver.go`/`store.go`, this task only touches `ratelimit-hertz` and `admin-bff-hertz`; note this and move on — do not create new override files for fragments that currently inherit ncgo's built-in default (that would be an unrelated, larger-scope change).

- [ ] **Step 2: Apply the same three edits to `ratelimit-hertz`**

Apply the identical `Lookup` field addition, `normalizeLookup` line, two `BuildKey` cases, and `Check` function from Task 1 Steps 3–4 to:
- `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`

Then append the same five test functions from Task 1 Step 1 to the existing `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml` (append inside its `body:` block, after the last existing test function `TestNewStoreBackendSelection` or equivalent — read the file first to find the exact insertion point).

- [ ] **Step 3: Apply the same edits to `admin-bff-hertz`**

Same as Step 2, for:
- `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`
- `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_store_test_go.yaml`

Note: `admin-bff-hertz`'s `rateLimitAppKey` differs from `user-bff-hertz`'s (it reads from JWT claims' `AK` field per the earlier diff) — that function is unrelated to this change and must not be touched.

- [ ] **Step 4: Render-check all touched files**

Repeat the `gofmt -l` scratch-render check from Task 1 Step 5 for every file touched in Steps 2–3.

- [ ] **Step 5: Generate scratch projects and run tests for each service**

Repeat Task 1 Step 6's generate-and-test cycle for `ratelimit-hertz` and `admin-bff-hertz` (and `base-hertz` only if Step 1 found it has its own override). Expected: all `TestBuildKey*` tests PASS in each generated project, no regressions in the rest of `./internal/pkg/ratelimit/...`.

- [ ] **Step 6: Commit**

```bash
git add base-hertz/hertz-template/*.yaml ratelimit-hertz/hertz-template/*.yaml admin-bff-hertz/hertz-template/*.yaml
git commit -m "feat(ratelimit): mirror identifier key dimension to base-hertz/ratelimit-hertz/admin-bff-hertz templates"
```

(Adjust the `git add` paths to only the files actually modified per Step 1's findings.)

---

### Task 3: `RateLimitConfig` gains `PasswordResetRequestIdentifier`/`PasswordResetConfirmIdentifier` (user-bff-hertz conf.go)

**Files:**
- Modify: `user-bff-hertz/hertz-template/conf.yaml` (the `RateLimitConfig` struct, `Default()`'s `RateLimit` block)

**Interfaces:**
- Consumes: `RateLimitPhaseConfig`/`RateLimitRuleConfig` (already defined, unchanged).
- Produces: `conf.RateLimitConfig.PasswordResetRequestIdentifier`, `conf.RateLimitConfig.PasswordResetConfirmIdentifier` (type `RateLimitPhaseConfig`), read by Task 4's handler code as `cfg.RateLimit.PasswordResetRequestIdentifier` / `cfg.RateLimit.PasswordResetConfirmIdentifier`.

- [ ] **Step 1: Add the two new struct fields**

In `user-bff-hertz/hertz-template/conf.yaml`, change:

```yaml
      PasswordChange RateLimitPhaseConfig  `yaml:"password_change"`
      PasswordResetRequest RateLimitPhaseConfig `yaml:"password_reset_request"`
      PasswordResetConfirm RateLimitPhaseConfig `yaml:"password_reset_confirm"`
      Memory       MemoryCacheConfig       `yaml:"memory"`
```

to:

```yaml
      PasswordChange RateLimitPhaseConfig  `yaml:"password_change"`
      PasswordResetRequest RateLimitPhaseConfig `yaml:"password_reset_request"`
      PasswordResetConfirm RateLimitPhaseConfig `yaml:"password_reset_confirm"`
      // PasswordResetRequestIdentifier/PasswordResetConfirmIdentifier back a
      // second, independent rate-limit check run inside the handler (after
      // body parsing) keyed by account identifier (email/phone) + IP. They
      // are separate from PasswordResetRequest/PasswordResetConfirm above,
      // which continue to govern the middleware's existing IP-only coarse
      // limiting, unchanged — see docs/superpowers/specs/2026-09-20-ratelimit-identifier-dimension-design.md.
      PasswordResetRequestIdentifier RateLimitPhaseConfig `yaml:"password_reset_request_identifier"`
      PasswordResetConfirmIdentifier RateLimitPhaseConfig `yaml:"password_reset_confirm_identifier"`
      Memory       MemoryCacheConfig       `yaml:"memory"`
```

- [ ] **Step 2: Add default values in `Default()`**

In the same file, change:

```yaml
              PasswordResetConfirm: RateLimitPhaseConfig{
                  Enabled: true,
                  DefaultRule: RateLimitRuleConfig{
                      Enabled:          true,
                      KeyBy:            []string{"ip"},
                      Strategy:         "fixed_window",
                      WindowSeconds:    config.Duration{Duration: 3600 * time.Second},
                      MaxRequests:      10,
                      ClientTTLSeconds: config.Duration{Duration: 300 * time.Second},
                  },
              },
          },
```

to:

```yaml
              PasswordResetConfirm: RateLimitPhaseConfig{
                  Enabled: true,
                  DefaultRule: RateLimitRuleConfig{
                      Enabled:          true,
                      KeyBy:            []string{"ip"},
                      Strategy:         "fixed_window",
                      WindowSeconds:    config.Duration{Duration: 3600 * time.Second},
                      MaxRequests:      10,
                      ClientTTLSeconds: config.Duration{Duration: 300 * time.Second},
                  },
              },
              PasswordResetRequestIdentifier: RateLimitPhaseConfig{
                  Enabled: true,
                  DefaultRule: RateLimitRuleConfig{
                      Enabled:          true,
                      KeyBy:            []string{"ip_identifier"},
                      Strategy:         "fixed_window",
                      WindowSeconds:    config.Duration{Duration: 3600 * time.Second},
                      MaxRequests:      5,
                      ClientTTLSeconds: config.Duration{Duration: 300 * time.Second},
                  },
              },
              PasswordResetConfirmIdentifier: RateLimitPhaseConfig{
                  Enabled: true,
                  DefaultRule: RateLimitRuleConfig{
                      Enabled:          true,
                      KeyBy:            []string{"ip_identifier"},
                      Strategy:         "fixed_window",
                      WindowSeconds:    config.Duration{Duration: 3600 * time.Second},
                      MaxRequests:      10,
                      ClientTTLSeconds: config.Duration{Duration: 300 * time.Second},
                  },
              },
          },
```

(Values mirror the existing `PasswordResetRequest`/`PasswordResetConfirm` thresholds — 5/hour and 10/hour respectively — since the Issue's stated numbers already describe the intended per-account limits; the pre-existing `PasswordResetRequest`/`PasswordResetConfirm` phases remain the IP-only coarse guard and keep their current values unchanged.)

No new `validateRateLimitPhase` call is added for these two fields, consistent with the existing `PasswordResetRequest`/`PasswordResetConfirm` fields, which today are validated by `validateRateLimitRule` internally via `NormalizeConfig`/`NormalizeRule` at resolve time, not by an explicit `Validate()` call — see `validateRateLimitPhase` callers at `conf.yaml`'s `Validate()`, which today only calls it for `PreAuth`/`PostAuth`.

- [ ] **Step 3: Render-check and verify with `go vet`**

```bash
cd user-bff-hertz/hertz-template
python3 -c "
import yaml
doc = yaml.safe_load(open('conf.yaml'))
print(doc['body'])
" > /tmp/scratch_conf.go
gofmt -l /tmp/scratch_conf.go
```

Expected: no output.

- [ ] **Step 4: Generate a scratch project and confirm `conf` package compiles + existing conf tests pass**

```bash
cd /tmp/scratch-user-bff-hertz   # from Task 1 Step 6, regenerate if stale
go build ./internal/base/conf/...
go test ./internal/base/conf/... -v
```

Expected: build succeeds, all existing conf tests still PASS (no field was renamed or removed).

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/conf.yaml
git commit -m "feat(ratelimit): add PasswordResetRequestIdentifier/PasswordResetConfirmIdentifier config fields"
```

---

### Task 4: Wire `AuthHandler` to run the identifier-scoped check

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_handler_auth_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_handler_auth_test_go.yaml` (check first whether this file already exists — if it does, append to it instead of creating)

**Interfaces:**
- Consumes: `ratelimit.Lookup{Phase, ClientIP, Identifier}`, `ratelimit.Check(ctx, resolver, store, cfg, lookup) (bool, error)` (Task 1), `conf.RateLimitConfig.PasswordResetRequestIdentifier`/`PasswordResetConfirmIdentifier` (Task 3), `response.ErrorCode(c, response.CodeRateLimited)` (already exists — confirm the exact symbol name with `grep -n "CodeRateLimited" user-bff-hertz/hertz-template/*.yaml` before use).
- Produces: `NewAuthHandler(userCli userservice.Client, resolver *ratelimit.Resolver, store ratelimit.Store, cfg conf.RateLimitConfig) *AuthHandler` — new signature consumed by Task 5's router wiring.

- [ ] **Step 1: Check whether a handler test file already exists**

```bash
ls user-bff-hertz/hertz-template/internal_handler_auth_test_go.yaml 2>/dev/null || echo "does not exist"
```

If it exists, read it fully before editing (to match existing test helper conventions — e.g. how other tests in this file construct `*app.RequestContext` and a fake `userservice.Client`). If it does not exist, Step 2 below creates it using the same conventions as `internal_router_userbffservice_test_go.yaml` (read that file first for the request-context/mock-client construction pattern used elsewhere in this template set).

- [ ] **Step 2: Write the failing regression tests**

Add (to the existing test file, or a new `internal_handler_auth_test_go.yaml` with `path: internal/handler/auth_test.go`, `update_behavior: { type: cover }`) two tests. Read the file found/created in Step 1 first to match its exact fake-client and request-context helpers, then add:

```yaml
    func TestRequestPasswordResetThrottlesSameIdentifierAcrossIPs(t *testing.T) {{ "{" }}
    	resolver := ratelimit.NewResolver(conf.RateLimitConfig{{ "{" }}
    		PasswordResetRequestIdentifier: conf.RateLimitPhaseConfig{{ "{" }}
    			Enabled: true,
    			DefaultRule: conf.RateLimitRuleConfig{{ "{" }}
    				Enabled: true, KeyBy: []string{{ "{" }}"ip_identifier"{{ "}" }},
    				Strategy: "fixed_window",
    				WindowSeconds: config.Duration{{ "{" }}Duration: time.Hour{{ "}" }},
    				MaxRequests: 1,
    			{{ "}" }},
    		{{ "}" }},
    	{{ "}" }}, ratelimit.Options{{ "{" }}{{ "}" }})
    	store := ratelimit.NewStore(conf.RateLimitConfig{{ "{" }}Backend: "memory", KeyPrefix: "test"{{ "}" }}, nil)
    	cfg := conf.RateLimitConfig{{ "{" }}KeyPrefix: "test", PasswordResetRequestIdentifier: conf.RateLimitPhaseConfig{{ "{" }}Enabled: true{{ "}" }}{{ "}" }}
    	h := NewAuthHandler(fakeUserServiceClient{{ "{" }}{{ "}" }}, resolver, store, cfg)

    	body := []byte(`{{ "{" }}"identifier":"alice@example.com","channel":"email"{{ "}" }}`)

    	// First request from IP A: allowed.
    	c1 := newTestRequestContext(http.MethodPost, "/auth/password-reset/request", body)
    	c1.Request.SetHost("10.0.0.1")
    	h.RequestPasswordReset(context.Background(), c1)
    	if c1.Response.StatusCode() >= 400 {{ "{" }}
    		t.Fatalf("first request: expected success, got status %d", c1.Response.StatusCode())
    	{{ "}" }}

    	// Second request, same identifier, DIFFERENT IP: must still be throttled
    	// (this is the IP-rotation-bypass regression the Issue calls out).
    	c2 := newTestRequestContext(http.MethodPost, "/auth/password-reset/request", body)
    	c2.Request.SetHost("10.0.0.2")
    	h.RequestPasswordReset(context.Background(), c2)
    	if c2.Response.StatusCode() != 429 {{ "{" }}
    		t.Fatalf("second request from different IP, same identifier: expected 429, got %d", c2.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}

    func TestRequestPasswordResetDoesNotCrossThrottleDifferentIdentifiers(t *testing.T) {{ "{" }}
    	resolver := ratelimit.NewResolver(conf.RateLimitConfig{{ "{" }}
    		PasswordResetRequestIdentifier: conf.RateLimitPhaseConfig{{ "{" }}
    			Enabled: true,
    			DefaultRule: conf.RateLimitRuleConfig{{ "{" }}
    				Enabled: true, KeyBy: []string{{ "{" }}"ip_identifier"{{ "}" }},
    				Strategy: "fixed_window",
    				WindowSeconds: config.Duration{{ "{" }}Duration: time.Hour{{ "}" }},
    				MaxRequests: 1,
    			{{ "}" }},
    		{{ "}" }},
    	{{ "}" }}, ratelimit.Options{{ "{" }}{{ "}" }})
    	store := ratelimit.NewStore(conf.RateLimitConfig{{ "{" }}Backend: "memory", KeyPrefix: "test"{{ "}" }}, nil)
    	cfg := conf.RateLimitConfig{{ "{" }}KeyPrefix: "test", PasswordResetRequestIdentifier: conf.RateLimitPhaseConfig{{ "{" }}Enabled: true{{ "}" }}{{ "}" }}
    	h := NewAuthHandler(fakeUserServiceClient{{ "{" }}{{ "}" }}, resolver, store, cfg)

    	c1 := newTestRequestContext(http.MethodPost, "/auth/password-reset/request", []byte(`{{ "{" }}"identifier":"alice@example.com","channel":"email"{{ "}" }}`))
    	c1.Request.SetHost("10.0.0.1")
    	h.RequestPasswordReset(context.Background(), c1)
    	if c1.Response.StatusCode() >= 400 {{ "{" }}
    		t.Fatalf("alice: expected success, got status %d", c1.Response.StatusCode())
    	{{ "}" }}

    	// Same IP, DIFFERENT identifier: must NOT be throttled by alice's count.
    	c2 := newTestRequestContext(http.MethodPost, "/auth/password-reset/request", []byte(`{{ "{" }}"identifier":"bob@example.com","channel":"email"{{ "}" }}`))
    	c2.Request.SetHost("10.0.0.1")
    	h.RequestPasswordReset(context.Background(), c2)
    	if c2.Response.StatusCode() >= 400 {{ "{" }}
    		t.Fatalf("bob: expected success (independent identifier), got status %d", c2.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}
```

Adjust `newTestRequestContext`/`fakeUserServiceClient`/the exact way to set the client IP on a Hertz `*app.RequestContext` in tests to whatever helper the file located in Step 1 already provides — do not invent a second helper if one exists (grep for `func newTestRequestContext\|func fakeUserServiceClient\|RequestContext{{ "{" }}` in the existing router/handler test files first).

- [ ] **Step 3: Verify the tests fail to compile (the new `NewAuthHandler` signature and `PasswordResetRequestIdentifier` field don't exist yet if Task 3/this task's Step 4 haven't landed — confirm ordering)**

If Task 3 already landed (its own commit), `PasswordResetRequestIdentifier` exists on `conf.RateLimitConfig` already; this step's tests will fail to compile only on `NewAuthHandler`'s signature (3 extra params) until Step 4 below lands. Render-check + scratch-generate + `go vet ./internal/handler/...` and confirm the compiler error names `NewAuthHandler` with a "too many/not enough arguments" message.

- [ ] **Step 4: Update `NewAuthHandler` and both handlers**

In `user-bff-hertz/hertz-template/internal_handler_auth_go.yaml`:

Change the imports block:

```yaml
    import (
    	"context"
    	"encoding/json"
    	"strings"

    	"github.com/cloudwego/hertz/pkg/app"

    	"{{.Module}}/internal/pkg/middleware"
    	"{{.Module}}/internal/pkg/response"
    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )
```

to:

```yaml
    import (
    	"context"
    	"encoding/json"
    	"strings"

    	"github.com/cloudwego/hertz/pkg/app"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/pkg/middleware"
    	"{{.Module}}/internal/pkg/ratelimit"
    	"{{.Module}}/internal/pkg/response"
    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )
```

Change the struct and constructor:

```yaml
    type AuthHandler struct {{ "{" }}
    	userCli userservice.Client
    {{ "}" }}

    func NewAuthHandler(userCli userservice.Client) *AuthHandler {{ "{" }}
    	return &AuthHandler{{ "{" }}userCli: userCli{{ "}" }}
    {{ "}" }}
```

to:

```yaml
    type AuthHandler struct {{ "{" }}
    	userCli  userservice.Client
    	resolver *ratelimit.Resolver
    	store    ratelimit.Store
    	cfg      conf.RateLimitConfig
    {{ "}" }}

    // NewAuthHandler builds the auth handler. resolver/store/cfg back the
    // identifier-scoped rate-limit check that RequestPasswordReset and
    // ConfirmPasswordReset run after parsing their request bodies — see
    // docs/superpowers/specs/2026-09-20-ratelimit-identifier-dimension-design.md.
    func NewAuthHandler(userCli userservice.Client, resolver *ratelimit.Resolver, store ratelimit.Store, cfg conf.RateLimitConfig) *AuthHandler {{ "{" }}
    	return &AuthHandler{{ "{" }}userCli: userCli, resolver: resolver, store: store, cfg: cfg{{ "}" }}
    {{ "}" }}
```

Change `RequestPasswordReset`:

```yaml
    func (h *AuthHandler) RequestPasswordReset(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req requestPasswordResetReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	if _, err := h.userCli.RequestPasswordReset(ctx, &userv1.RequestPasswordResetReq{{ "{" }}Identifier: req.Identifier, Channel: req.Channel{{ "}" }}); err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	// Always the same success body, regardless of whether identifier
    	// matched an account — see usersvc.RequestPasswordReset's doc comment.
    	response.OK(c, map[string]string{{ "{" }}"status": "reset_requested"{{ "}" }})
    {{ "}" }}
```

to:

```yaml
    func (h *AuthHandler) RequestPasswordReset(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req requestPasswordResetReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	if !h.checkIdentifierRateLimit(ctx, c, "password_reset_request", h.cfg.PasswordResetRequestIdentifier, strings.TrimSpace(req.Identifier)) {{ "{" }}
    		return
    	{{ "}" }}
    	if _, err := h.userCli.RequestPasswordReset(ctx, &userv1.RequestPasswordResetReq{{ "{" }}Identifier: req.Identifier, Channel: req.Channel{{ "}" }}); err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	// Always the same success body, regardless of whether identifier
    	// matched an account — see usersvc.RequestPasswordReset's doc comment.
    	response.OK(c, map[string]string{{ "{" }}"status": "reset_requested"{{ "}" }})
    {{ "}" }}
```

Change `ConfirmPasswordReset`:

```yaml
    func (h *AuthHandler) ConfirmPasswordReset(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req confirmPasswordResetReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	if _, err := h.userCli.ConfirmPasswordReset(ctx, &userv1.ConfirmPasswordResetReq{{ "{" }}Credential: req.Credential, NewPassword: req.NewPassword, Phone: req.Phone{{ "}" }}); err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"status": "password_reset"{{ "}" }})
    {{ "}" }}
```

to:

```yaml
    func (h *AuthHandler) ConfirmPasswordReset(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req confirmPasswordResetReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	if !h.checkIdentifierRateLimit(ctx, c, "password_reset_confirm", h.cfg.PasswordResetConfirmIdentifier, strings.TrimSpace(req.Phone)) {{ "{" }}
    		return
    	{{ "}" }}
    	if _, err := h.userCli.ConfirmPasswordReset(ctx, &userv1.ConfirmPasswordResetReq{{ "{" }}Credential: req.Credential, NewPassword: req.NewPassword, Phone: req.Phone{{ "}" }}); err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"status": "password_reset"{{ "}" }})
    {{ "}" }}
```

Then add the shared helper (append after `ConfirmPasswordReset`, at the end of the file's `body:` block):

```yaml
    // checkIdentifierRateLimit runs the identifier-scoped fine-grained
    // rate-limit check for phase, using identifier (already trimmed by the
    // caller) alongside the caller's IP. It writes the rate-limited error
    // response and returns false when the request must be rejected;
    // otherwise it returns true and writes nothing. A disabled phaseCfg or an
    // empty resolver/store (e.g. not wired up by the caller) is treated as
    // "allow" — this mirrors the middleware's own FailOpen-style behavior
    // for the coarse IP check, applied here to the fine-grained check.
    func (h *AuthHandler) checkIdentifierRateLimit(ctx context.Context, c *app.RequestContext, phase string, phaseCfg conf.RateLimitPhaseConfig, identifier string) bool {{ "{" }}
    	if !phaseCfg.Enabled || h.resolver == nil || h.store == nil || identifier == "" {{ "{" }}
    		return true
    	{{ "}" }}
    	lookup := ratelimit.Lookup{{ "{" }}
    		Phase:      phase,
    		ClientIP:   c.ClientIP(),
    		Identifier: identifier,
    	{{ "}" }}
    	allowed, err := ratelimit.Check(ctx, h.resolver, h.store, h.cfg, lookup)
    	if err != nil {{ "{" }}
    		if h.cfg.FailOpen {{ "{" }}
    			return true
    		{{ "}" }}
    		response.ErrorCode(c, response.CodeCacheUnavailable)
    		return false
    	{{ "}" }}
    	if !allowed {{ "{" }}
    		response.ErrorCode(c, response.CodeRateLimited)
    		return false
    	{{ "}" }}
    	return true
    {{ "}" }}
```

Before finalizing, confirm the exact names `response.CodeRateLimited` and `response.CodeCacheUnavailable` already exist (they are used verbatim by `internal_pkg_middleware_rate_limit_go.yaml` today) — no new response codes are introduced.

- [ ] **Step 5: Render-check, regenerate, run tests**

Repeat the `gofmt -l` scratch-render check for `internal_handler_auth_go.yaml` and the test file, then regenerate the scratch project and run:

```bash
cd /tmp/scratch-user-bff-hertz
go build ./...
go test ./internal/handler/... -run "PasswordReset" -v
```

Expected: build succeeds project-wide (confirms the router — Task 5 — isn't required yet only if `NewAuthHandler`'s call site in `router.go` is also updated in the same generated snapshot; if Task 5 hasn't landed yet, `go build ./...` will fail at the router package only — acceptable at this point, but re-run `go build ./...` again after Task 5 lands to confirm project-wide compilation). `TestRequestPasswordResetThrottlesSameIdentifierAcrossIPs` and `TestRequestPasswordResetDoesNotCrossThrottleDifferentIdentifiers` PASS.

- [ ] **Step 6: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_auth_go.yaml
git add user-bff-hertz/hertz-template/internal_handler_auth_test_go.yaml   # if newly created, otherwise it's already tracked
git commit -m "feat(ratelimit): run identifier-scoped rate-limit check in password-reset handlers"
```

---

### Task 5: Wire the router to construct and pass resolver/store/cfg into `NewAuthHandler`

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`

**Interfaces:**
- Consumes: `NewAuthHandler(userCli, resolver, store, cfg conf.RateLimitConfig)` (Task 4), `ratelimit.NewStore(cfg conf.RateLimitConfig, redisClient redis.UniversalClient) Store` (already exported, unchanged).
- Produces: nothing new — this is the final wiring task.

- [ ] **Step 1: Update the `NewAuthHandler` call site**

Change:

```yaml
    	authHandler := handler.NewAuthHandler(userCli)
```

to:

```yaml
    	rateLimitStore := ratelimit.NewStore(cfg.RateLimit, nil)
    	authHandler := handler.NewAuthHandler(userCli, resolver, rateLimitStore, cfg.RateLimit)
```

(`nil` for the redis client mirrors this template's existing `sharedRedisClient` stub in `internal_pkg_middleware_redis_client_go.yaml`, which always returns `nil` today — so `ratelimit.NewStore` always falls back to its in-memory backend here, exactly as the middleware's own store construction already does. This keeps the handler-level store's backend selection consistent with the middleware's, without requiring access to the middleware package's unexported `sharedRedisClient`.)

- [ ] **Step 2: Render-check**

```bash
cd user-bff-hertz/hertz-template
python3 -c "
import yaml
doc = yaml.safe_load(open('internal_router_userbffservice_go.yaml'))
print(doc['body'])
" > /tmp/scratch_router.go
gofmt -l /tmp/scratch_router.go
```

Expected: no output.

- [ ] **Step 3: Regenerate the scratch project and run the full test suite**

```bash
cd /tmp/scratch-user-bff-hertz   # regenerate from the four modified templates if stale
go build ./...
go test ./... -v
```

Expected: full build succeeds, every test package passes — including the Task 1 `BuildKey` tests, Task 3 conf tests, and Task 4 handler regression tests, plus every pre-existing test in the generated project (no regression in `pre_auth`/`post_auth`/`password_change`/OAuth/etc. flows).

- [ ] **Step 4: Manually exercise the IP-rotation-bypass scenario end-to-end (acceptance criteria check)**

If the scratch project has a runnable dev server target (check its `Makefile`/`README.md`), start it with the default config, and issue:

```bash
curl -s -X POST http://localhost:8080/auth/password-reset/request -H 'X-Forwarded-For: 1.1.1.1' -d '{"identifier":"alice@example.com","channel":"email"}'
curl -s -X POST http://localhost:8080/auth/password-reset/request -H 'X-Forwarded-For: 1.1.1.1' -d '{"identifier":"alice@example.com","channel":"email"}'
curl -s -X POST http://localhost:8080/auth/password-reset/request -H 'X-Forwarded-For: 1.1.1.1' -d '{"identifier":"alice@example.com","channel":"email"}'
curl -s -X POST http://localhost:8080/auth/password-reset/request -H 'X-Forwarded-For: 1.1.1.1' -d '{"identifier":"alice@example.com","channel":"email"}'
curl -s -X POST http://localhost:8080/auth/password-reset/request -H 'X-Forwarded-For: 1.1.1.1' -d '{"identifier":"alice@example.com","channel":"email"}'
curl -s -X POST http://localhost:8080/auth/password-reset/request -H 'X-Forwarded-For: 2.2.2.2' -d '{"identifier":"alice@example.com","channel":"email"}'
```

Expected: the first 5 requests (same IP, default `PasswordResetRequest` limit of 5/hour) start returning the coarse IP-limit's rate-limited response once the IP-only limit is hit; the 6th request, from a rotated IP but the same identifier, is now ALSO rejected by the new `PasswordResetRequestIdentifier` check (previously it would have been allowed, since only the IP dimension existed) — confirming the acceptance criteria's "IP rotation no longer bypasses per-account limits" is satisfied. If there's no runnable dev-server target for this project kind, skip this step and rely on Step 3's automated test coverage, noting the skip in the PR description.

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml
git commit -m "feat(ratelimit): wire identifier-scoped store into user-bff-hertz router"
```

---

## Self-Review Notes (already applied above)

- **Spec coverage:** every acceptance criterion in Issue #78 maps to a task — infra support (Task 1–2), phases updated (Task 3–4), backward compatibility (Global Constraints + Task 1 Step 1's `TestBuildKeyExistingDimensionsUnaffected`), tests for the new dimension + IP-rotation regression (Task 1 Step 1, Task 4 Step 2, Task 5 Step 4).
- **Type consistency:** `ratelimit.Check`'s signature is defined once in Task 1 and used identically (same parameter order/types) in Task 4's `checkIdentifierRateLimit`. `Lookup.Identifier` is defined once in Task 1 and referenced by field name consistently in Task 4.
- **No placeholders:** every step includes literal code, not descriptions of code.
