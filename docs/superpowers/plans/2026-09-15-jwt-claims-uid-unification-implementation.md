# JWT Claims uid Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix a silent identity-loss bug in `base-hertz` and `admin-bff-hertz`: their JWT `Claims` struct reads fields (`UUID`/`json:"uuid"`, `UserID`/`json:"user_id"`) that the actual token issuers (`rbac-kitex`, `admin-services-kitex`, `user-kitex`) never set (they only set `uid`/`json:"uid"`) — so every consumer of the parsed identity (idempotency scoping, rate-limit scoping, RBAC authorization, current-user lookups, logout) silently receives an empty string today.

**Architecture:** Consolidate `base-hertz`'s and `admin-bff-hertz`'s `Claims` struct to a single `Uid string \`json:"uid"\`` field matching the issuer-side schema (already correct in `rbac-kitex`/`admin-services-kitex`/`user-kitex`/`user-bff-hertz`), then update every consumer of the old `UUID`/`UserID` fields to use `Uid`. No issuer-side code changes. No new packages or abstractions — this is a field rename propagated through existing call sites.

**Tech Stack:** Go 1.22+, Hertz, `github.com/golang-jwt/jwt/v5`, existing `ncgo` template rendering pipeline (`.yaml` template files with `body:` Go source blocks).

**Spec:** `docs/superpowers/specs/2026-09-15-jwt-claims-uid-unification-design.md`

## Global Constraints

- Literal Go braces `{` / `}` inside a `body:` block are written as plain `{`/`}` in some files (`token.go`, both packages) and as `{{ "{" }}` / `{{ "}" }}` in others (`jwt.go`, `jwt_test.go`, `idempotency.go`, `idempotency_test.go`, `rate_limit.go`, `rate_limit_test.go`, `authz.go`, `current_user.go`, `auth.go`, `internal_router_adminbffservice_test_go.yaml`) — **match each file's own existing style exactly**, never introduce escaping into a plain file or vice versa.
- `AK string \`json:"ak"\`` stays untouched — it is a separate API-key auth path, unrelated to JWT identity.
- Issuer-side packages (`rbac-kitex`, `admin-services-kitex`, `user-kitex`, `user-bff-hertz`) are already correct (`Uid string \`json:"uid"\``) and are NOT touched by this plan.
- `admin-bff-hertz/internal/pkg/ratelimit`'s `Lookup.UserUUID` field (in `internal_pkg_ratelimit_resolver_go.yaml` / `internal_pkg_ratelimit_store_go.yaml` / `internal_pkg_ratelimit_store_test_go.yaml`) is a separate internal struct unrelated to `middleware.Claims` — it is populated by `rateLimitUserUUID(c)`, which this plan fixes to read `claims.Uid`. The `Lookup.UserUUID` field name itself, and the `"ak_user_uuid"`/`"user_uuid"` cache-key-scope string literals in `idempotency.go` and `ratelimit/store.go`, are cosmetic labels only (never fed back into consumers as data) and are explicitly OUT OF SCOPE — renaming them is unrelated churn with no bug-fix value.
- Every task must render the WHOLE package via the real `ncgo new --template-dir` pipeline (never a cross-render-copy shortcut) and run `go build/vet/test/race`, per the lesson carried forward from every prior plan in this registry — a task that only builds the files it touched has repeatedly missed real breakage.
- `admin-bff-hertz` additionally depends on `kitex_gen` (rbac/rule_center/auth/user RPC clients) to build `internal/router`/`internal/pkg/middleware` in isolation — Task 2's final verification uses the existing `admin-bff-hertz/test/e2e_test.sh` script (already handles the full codegen pipeline: `ncgo new` → `ncgo add kitex-client` (user.proto) → `kitex` CLI (auth/rbac/rule_center.proto) → `go build`/`go test`) instead of reinventing that pipeline by hand.
- **Added after final whole-branch review discovered it (Task 3 below):** `ratelimit-hertz` is a third, formally published `hertz` template package (own `template.yaml`, `kind: hertz`, described as "JWT + signature + idempotency + rate limiting middleware") carrying the byte-for-byte identical bug — its `Claims` struct, `jwt.go`, `idempotency.go`, `rate_limit.go`, and `jwt_test.go` are near-identical copies of `base-hertz`'s pre-fix versions. The original design doc's root-cause survey never scanned this package. Task 3 closes that gap in the same branch (user decision, recorded 2026-09-15) rather than deferring to a follow-up issue.

---

### Task 1: `base-hertz` — unify Claims to a single `Uid` field

**Files:**
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`
- Test (new): `base-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`

**Interfaces:**
- Consumes: nothing new (no other task's output).
- Produces: `middleware.Claims{Uid string \`json:"uid"\`, AK string \`json:"ak"\`, Roles []string \`json:"roles,omitempty"\`, jwt.RegisteredClaims}` — Task 2 mirrors this exact shape in `admin-bff-hertz`.

- [ ] **Step 1: Write a failing regression test proving the bug, using the target (post-fix) API**

`base-hertz` currently has no test file for `token.go` at all — `JWTAuth`/`TokenAuth`/`VerifyToken` (the middleware actually wired into `internal_router_service_go.yaml:40`) has zero coverage today; only the *unused* `JWT()` function in `jwt.go` has a test. Create `base-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/middleware/token_test.go
path: internal/pkg/middleware/token_test.go
update_behavior:
    type: cover
body: |-
    package middleware

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/golang-jwt/jwt/v5"

    	"{{.Module}}/internal/base/conf"
    )

    // TestVerifyToken_RealIssuerShapedToken_PopulatesUid signs a token with
    // the exact claim shape rbac-kitex/admin-services-kitex/user-kitex
    // actually issue (only a "uid" claim, no "uuid" or "user_id") and
    // proves VerifyToken recovers a non-empty, correct Uid. Before this
    // task's fix, Claims had no Uid field at all (UUID/UserID only, neither
    // ever set by any real issuer) — this test fails to compile until the
    // rename lands, which is the expected RED state.
    func TestVerifyToken_RealIssuerShapedToken_PopulatesUid(t *testing.T) {
    	secret := "test-secret"
    	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
    		"uid":   "user-123",
    		"roles": []interface{}{"member"},
    		"exp":   time.Now().Add(time.Hour).Unix(),
    	})
    	tokenStr, err := token.SignedString([]byte(secret))
    	if err != nil {
    		t.Fatalf("failed to sign test token: %v", err)
    	}

    	verifier := JWTVerifier{Config: conf.TokenConfig{Enabled: true, SigningKey: secret}}
    	claims, err := verifier.VerifyToken(context.Background(), tokenStr)
    	if err != nil {
    		t.Fatalf("VerifyToken() error = %v, want nil", err)
    	}
    	if claims.Uid != "user-123" {
    		t.Errorf("claims.Uid = %q, want %q", claims.Uid, "user-123")
    	}
    }
```

Run: `go build ./internal/pkg/middleware/...` (against a fresh render — see Step 5) — expect a compile failure: `claims.Uid undefined (type *Claims has no field or method Uid)`. This is the RED state: it proves today's `Claims` struct cannot express the issuer's actual token shape.

- [ ] **Step 2: Rename `Claims` fields in `token.go`**

Edit `base-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`. Change:

```go
type Claims struct {
	UserID string   `json:"user_id"`
	UUID   string   `json:"uuid"`
	AK     string   `json:"ak"`
	Roles  []string `json:"roles,omitempty"`
	jwt.RegisteredClaims
}
```

to:

```go
type Claims struct {
	Uid   string   `json:"uid"`
	AK    string   `json:"ak"`
	Roles []string `json:"roles,omitempty"`
	jwt.RegisteredClaims
}
```

- [ ] **Step 3: Fix the unused-but-must-compile `JWT()` function and its test**

Edit `base-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml`. Change:

```go
		uuid, _ := claims["uuid"].(string)
```
to:
```go
		uid, _ := claims["uid"].(string)
```

and change:

```go
		c.Set(ContextKeyTokenClaims, &Claims{{ "{" }}
			UUID:  uuid,
			Roles: roles,
		{{ "}" }})
```
to:
```go
		c.Set(ContextKeyTokenClaims, &Claims{{ "{" }}
			Uid:   uid,
			Roles: roles,
		{{ "}" }})
```

Edit `base-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml`. In `TestJWT_ValidToken_SetsClaims`, change:

```go
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
		"uuid":  "user-123",
		"roles": []interface{{ "{" }}{{ "}" }}{{ "{" }}"{{ToLower .ServiceName}}"{{ "}" }},
		"exp":   time.Now().Add(time.Hour).Unix(),
	{{ "}" }})
```
to:
```go
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
		"uid":   "user-123",
		"roles": []interface{{ "{" }}{{ "}" }}{{ "{" }}"{{ToLower .ServiceName}}"{{ "}" }},
		"exp":   time.Now().Add(time.Hour).Unix(),
	{{ "}" }})
```

and change:
```go
	if claims.UUID != "user-123" {{ "{" }}
		t.Errorf("expected UUID user-123, got %s", claims.UUID)
	{{ "}" }}
```
to:
```go
	if claims.Uid != "user-123" {{ "{" }}
		t.Errorf("expected Uid user-123, got %s", claims.Uid)
	{{ "}" }}
```

In `TestJWT_ExpiredToken_Aborts`, change the signed claim key too:
```go
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
		"uuid": "user-123",
		"exp":  time.Now().Add(-time.Hour).Unix(),
	{{ "}" }})
```
to:
```go
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
		"uid": "user-123",
		"exp": time.Now().Add(-time.Hour).Unix(),
	{{ "}" }})
```

- [ ] **Step 4: Fix `idempotency.go`'s identity scoping and its test**

Edit `base-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`. Change:

```go
		switch {
		case claims.AK != "" && claims.UUID != "":
			scope = "ak_user_uuid:" + claims.AK + ":" + claims.UUID
		case claims.UUID != "":
			scope = "user_uuid:" + claims.UUID
		case claims.AK != "":
			scope = "ak:" + claims.AK
		}
```
to:
```go
		switch {
		case claims.AK != "" && claims.Uid != "":
			scope = "ak_user_uuid:" + claims.AK + ":" + claims.Uid
		case claims.Uid != "":
			scope = "user_uuid:" + claims.Uid
		case claims.AK != "":
			scope = "ak:" + claims.AK
		}
```

(The `"ak_user_uuid:"`/`"user_uuid:"` string literals are cache-key-scope labels, not struct fields — left as-is per Global Constraints.)

Edit `base-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`. Change:

```go
	c.Set(ContextKeyTokenClaims, &Claims{AK: "verified-ak", UUID: "user-1"})
```
to:
```go
	c.Set(ContextKeyTokenClaims, &Claims{AK: "verified-ak", Uid: "user-1"})
```

- [ ] **Step 5: Full render + build + test**

```bash
rm -rf /tmp/basehertz-task1-validate
ncgo new basehertztask1 --kind hertz --module github.com/example/basehertztask1 \
  --template-dir <repo>/base-hertz --dir /tmp/basehertz-task1-validate
cd /tmp/basehertz-task1-validate
go mod tidy
go build ./... && go vet ./... && go test ./... && go test -race ./...
```

All must pass, including the new `TestVerifyToken_RealIssuerShapedToken_PopulatesUid` (now GREEN) and every existing `middleware` test with its renamed field references. Confirm via `grep -n "UUID\|UserID" internal/pkg/middleware/*.go` in the rendered output that zero references to the old field names remain, and `grep -rn '{{ "{' internal/pkg/middleware/*.go` returns zero matches (no leftover template-escape artifacts).

- [ ] **Step 6: Commit**

```bash
git add base-hertz/hertz-template/internal_pkg_middleware_token_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml \
        base-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml
git commit -m "fix(base-hertz): unify JWT Claims to a single Uid field matching issuer schema"
```

---

### Task 2: `admin-bff-hertz` — unify Claims to a single `Uid` field, propagate through every consumer

**Files:**
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_middleware_authz_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_handler_current_user_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_handler_auth_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml`
- Test (new): `admin-bff-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`

**Interfaces:**
- Consumes: same `Claims{Uid, AK, Roles, jwt.RegisteredClaims}` shape Task 1 established (this package's `token.go` is edited independently but must converge on the identical shape).
- Produces: nothing consumed by a later task — this is the last task in the plan.

- [ ] **Step 1: Write a failing regression test proving the bug (mirrors Task 1 Step 1)**

`admin-bff-hertz` also has no `token_test.go` today. Create `admin-bff-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/middleware/token_test.go
path: internal/pkg/middleware/token_test.go
update_behavior:
    type: cover
body: |-
    package middleware

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/golang-jwt/jwt/v5"

    	"{{.Module}}/internal/base/conf"
    )

    // TestVerifyToken_RealIssuerShapedToken_PopulatesUid signs a token with
    // the exact claim shape rbac-kitex/admin-services-kitex/user-kitex
    // actually issue (only a "uid" claim) and proves VerifyToken recovers a
    // non-empty, correct Uid — the live path (internal_router_adminbffservice_go.yaml
    // wires middleware.JWTAuth, which calls this) previously always got an
    // empty identity from a real token.
    func TestVerifyToken_RealIssuerShapedToken_PopulatesUid(t *testing.T) {
    	secret := "test-secret"
    	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
    		"uid":   "user-123",
    		"roles": []interface{}{"admin"},
    		"exp":   time.Now().Add(time.Hour).Unix(),
    	})
    	tokenStr, err := token.SignedString([]byte(secret))
    	if err != nil {
    		t.Fatalf("failed to sign test token: %v", err)
    	}

    	verifier := JWTVerifier{Config: conf.TokenConfig{Enabled: true, SigningKey: secret}}
    	claims, err := verifier.VerifyToken(context.Background(), tokenStr)
    	if err != nil {
    		t.Fatalf("VerifyToken() error = %v, want nil", err)
    	}
    	if claims.Uid != "user-123" {
    		t.Errorf("claims.Uid = %q, want %q", claims.Uid, "user-123")
    	}
    }
```

Run: `go build ./internal/pkg/middleware/...` (against a fresh render — see Step 8) — expect the same RED compile failure as Task 1 Step 1.

- [ ] **Step 2: Rename `Claims` fields in `token.go`**

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`. Change:

```go
type Claims struct {
	UserID string   `json:"user_id"`
	UUID   string   `json:"uuid"`
	AK     string   `json:"ak"`
	Roles  []string `json:"roles"`
	jwt.RegisteredClaims
}
```

to:

```go
type Claims struct {
	Uid   string   `json:"uid"`
	AK    string   `json:"ak"`
	Roles []string `json:"roles"`
	jwt.RegisteredClaims
}
```

- [ ] **Step 3: Fix the unused-but-must-compile `JWT()` function and its test**

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml` — same two changes as Task 1 Step 3 (`claims["uuid"]` → `claims["uid"]`, `UUID: uuid` → `Uid: uid` inside the `&Claims{{ "{" }}...{{ "}" }}` literal).

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml` — identical changes to Task 1 Step 3 (this file is byte-identical to `base-hertz`'s copy): both `jwt.MapClaims` literals' `"uuid"` key → `"uid"`, and the `claims.UUID`/`"expected UUID..."` assertion → `claims.Uid`/`"expected Uid..."`.

- [ ] **Step 4: Fix `idempotency.go`'s identity scoping and its test**

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`. Change:

```go
    		switch {{ "{" }}
    		case claims.AK != "" && claims.UUID != "":
    			scope = "ak_user_uuid:" + claims.AK + ":" + claims.UUID
    		case claims.UUID != "":
    			scope = "user_uuid:" + claims.UUID
    		case claims.AK != "":
    			scope = "ak:" + claims.AK
    		{{ "}" }}
```
to:
```go
    		switch {{ "{" }}
    		case claims.AK != "" && claims.Uid != "":
    			scope = "ak_user_uuid:" + claims.AK + ":" + claims.Uid
    		case claims.Uid != "":
    			scope = "user_uuid:" + claims.Uid
    		case claims.AK != "":
    			scope = "ak:" + claims.AK
    		{{ "}" }}
```

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`. Change:
```go
	c.Set(ContextKeyTokenClaims, &Claims{{ "{" }}AK: "verified-ak", UUID: "user-1"{{ "}" }})
```
to:
```go
	c.Set(ContextKeyTokenClaims, &Claims{{ "{" }}AK: "verified-ak", Uid: "user-1"{{ "}" }})
```

- [ ] **Step 5: Fix `rate_limit.go`'s identity resolver and its test**

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`. Change:

```go
    func rateLimitUserUUID(c *app.RequestContext) string {{ "{" }}
    	claims, hasClaims := GetClaims(c)
    	if hasClaims {{ "{" }}
    		return strings.TrimSpace(claims.UUID)
    	{{ "}" }}
    	return ""
    {{ "}" }}
```
to:
```go
    func rateLimitUserUUID(c *app.RequestContext) string {{ "{" }}
    	claims, hasClaims := GetClaims(c)
    	if hasClaims {{ "{" }}
    		return strings.TrimSpace(claims.Uid)
    	{{ "}" }}
    	return ""
    {{ "}" }}
```

(`rateLimitUserUUID`'s own function name and its caller's `UserUUID: rateLimitUserUUID(c)` field assignment at line 44 are the `ratelimit.Lookup.UserUUID` field named in Global Constraints — left as-is, out of scope; only the `claims.UUID` → `claims.Uid` read changes.)

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`. In `TestRateLimitUsesPostAuthPhaseConfig`, change both occurrences:
```go
	first.Set(ContextKeyTokenClaims, &Claims{{ "{" }}UUID: "user-1"{{ "}" }})
```
and
```go
	second.Set(ContextKeyTokenClaims, &Claims{{ "{" }}UUID: "user-1"{{ "}" }})
```
to:
```go
	first.Set(ContextKeyTokenClaims, &Claims{{ "{" }}Uid: "user-1"{{ "}" }})
```
and
```go
	second.Set(ContextKeyTokenClaims, &Claims{{ "{" }}Uid: "user-1"{{ "}" }})
```
respectively.

- [ ] **Step 6: Fix `authz.go`, `current_user.go`, `auth.go`**

Edit `admin-bff-hertz/hertz-template/internal_pkg_middleware_authz_go.yaml`. Change:
```go
    		resp, err := rbacCli.Enforce(ctx, &api.EnforceReq{{ "{" }}
    			Uid: claims.UUID,
    			Obj: perm,
    			Act: "execute",
    		{{ "}" }})
```
to:
```go
    		resp, err := rbacCli.Enforce(ctx, &api.EnforceReq{{ "{" }}
    			Uid: claims.Uid,
    			Obj: perm,
    			Act: "execute",
    		{{ "}" }})
```

Edit `admin-bff-hertz/hertz-template/internal_handler_current_user_go.yaml`. In `GetMenus`, change:
```go
    	resp, err := h.rbacCli.GetUserMenuTree(ctx, &api.GetUserMenuTreeReq{{ "{" }}
    		UserId: claims.UserID,
    	{{ "}" }})
```
to:
```go
    	resp, err := h.rbacCli.GetUserMenuTree(ctx, &api.GetUserMenuTreeReq{{ "{" }}
    		UserId: claims.Uid,
    	{{ "}" }})
```
In `GetPerms`, change:
```go
    	resp, err := h.rbacCli.GetUserPermCodes(ctx, &api.GetUserPermCodesReq{{ "{" }}
    		UserId: claims.UserID,
    	{{ "}" }})
```
to:
```go
    	resp, err := h.rbacCli.GetUserPermCodes(ctx, &api.GetUserPermCodesReq{{ "{" }}
    		UserId: claims.Uid,
    	{{ "}" }})
```

Edit `admin-bff-hertz/hertz-template/internal_handler_auth_go.yaml`. In `Logout`, change:
```go
    	_, err := h.rbacCli.Logout(ctx, &api.LogoutReq{{ "{" }}UserId: claims.UserID{{ "}" }})
```
to:
```go
    	_, err := h.rbacCli.Logout(ctx, &api.LogoutReq{{ "{" }}UserId: claims.Uid{{ "}" }})
```

- [ ] **Step 7: Fix the router test's hand-signed JWT and add an end-to-end identity-propagation assertion**

This is the AC #3 "cross-service integration test": it proves a real issuer-shaped token, parsed by `admin-bff-hertz`'s actual wired middleware chain (`JWTAuth` → `Authz`), carries the correct `Uid` all the way to the RBAC `Enforce` call — the exact live path this bug broke.

Edit `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml`.

First, fix `newRouterTestJWT` (it currently signs the same stale `"uuid"` shape the rest of this bug was about):

```go
    func newRouterTestJWT(t *testing.T) string {{ "{" }}
    	t.Helper()
    	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
    		"uuid": "user-123",
    		"exp":  time.Now().Add(time.Hour).Unix(),
    	{{ "}" }})
    	signed, err := token.SignedString([]byte("router-test-secret"))
    	if err != nil {{ "{" }}
    		t.Fatalf("failed to sign test jwt: %v", err)
    	{{ "}" }}
    	return signed
    {{ "}" }}
```
to:
```go
    func newRouterTestJWT(t *testing.T) string {{ "{" }}
    	t.Helper()
    	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{{ "{" }}
    		"uid": "user-123",
    		"exp": time.Now().Add(time.Hour).Unix(),
    	{{ "}" }})
    	signed, err := token.SignedString([]byte("router-test-secret"))
    	if err != nil {{ "{" }}
    		t.Fatalf("failed to sign test jwt: %v", err)
    	{{ "}" }}
    	return signed
    {{ "}" }}
```

Then extend `fakeRouterRBACClient` to capture the `Uid` it was actually called with, so a test can assert on it. Change:
```go
    type fakeRouterRBACClient struct {{ "{" }}
    	rbacservice.Client
    	allowed bool
    {{ "}" }}

    func (f *fakeRouterRBACClient) Enforce(ctx context.Context, req *rbacv1.EnforceReq, callOptions ...callopt.Option) (*rbacv1.EnforceResp, error) {{ "{" }}
    	return &rbacv1.EnforceResp{{ "{" }}Allowed: f.allowed{{ "}" }}, nil
    {{ "}" }}
```
to:
```go
    type fakeRouterRBACClient struct {{ "{" }}
    	rbacservice.Client
    	allowed        bool
    	lastEnforceUid string
    {{ "}" }}

    func (f *fakeRouterRBACClient) Enforce(ctx context.Context, req *rbacv1.EnforceReq, callOptions ...callopt.Option) (*rbacv1.EnforceResp, error) {{ "{" }}
    	f.lastEnforceUid = req.Uid
    	return &rbacv1.EnforceResp{{ "{" }}Allowed: f.allowed{{ "}" }}, nil
    {{ "}" }}
```

Finally, add a new test after `TestAuthz_AllowedPermission_Returns200` (this file's `update_behavior` is `skip`, so this is additive — do not remove or reorder any existing test):

```go
    // TestAuthz_UsesRealJWTIdentity_PropagatesUidToRBAC is the AC #3
    // cross-service integration test for the Claims-uid-unification fix: a
    // JWT signed with the same claim shape rbac-kitex/user-kitex actually
    // issue (only a "uid" claim, via newRouterTestJWT) must thread its
    // identity, unmodified, all the way from JWTAuth's parse through Authz
    // into the RBAC Enforce call. Before this fix, Claims had no Uid field
    // (UUID/UserID only, neither ever set by a real issuer), so
    // fakeRouterRBACClient.lastEnforceUid would have observed "" here
    // instead of "user-123".
    func TestAuthz_UsesRealJWTIdentity_PropagatesUidToRBAC(t *testing.T) {{ "{" }}
    	rbacCli := &fakeRouterRBACClient{{ "{" }}allowed: true{{ "}" }}
    	engine := newRouterTestEngine(t, rbacCli)
    	jwtToken := newRouterTestJWT(t)

    	w := ut.PerformRequest(engine, "GET", "/api/v1/users",
    		nil, ut.Header{{ "{" }}Key: "Authorization", Value: "Bearer " + jwtToken{{ "}" }})
    	resp := w.Result()

    	if resp.StatusCode() != consts.StatusOK {{ "{" }}
    		t.Fatalf("expected 200, got %d", resp.StatusCode())
    	{{ "}" }}
    	if rbacCli.lastEnforceUid != "user-123" {{ "{" }}
    		t.Errorf("rbacCli.lastEnforceUid = %q, want %q — JWT identity did not propagate to RBAC Enforce", rbacCli.lastEnforceUid, "user-123")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 8: Full render + build + test via the existing e2e script**

```bash
<repo>/admin-bff-hertz/test/e2e_test.sh
```

Must exit 0 (`全部必跑通过`). This script already: renders the template, runs `ncgo add kitex-client` + `kitex` CLI for all four RPC clients, asserts zero residual template-escape artifacts, and runs `go build ./...` + `go test ./...` (excluding the known-unrelated `internal/pkg/i18n` scaffold gap documented at the top of the script).

Then, for a faster focused check while iterating (optional, same render the script already produced and cleaned up — re-run standalone if needed):

```bash
rm -rf /tmp/adminbff-task2-validate
ncgo new adminbfftask2 --kind hertz --module github.com/example/adminbfftask2 \
  --template-dir <repo>/admin-bff-hertz --dir /tmp/adminbff-task2-validate
cd /tmp/adminbff-task2-validate
ncgo add kitex-client terminaluser --service UserService --idl idl/user.proto --module github.com/example/adminbfftask2
kitex -module github.com/example/adminbfftask2 -type protobuf -I idl idl/auth.proto
kitex -module github.com/example/adminbfftask2 -type protobuf -I idl idl/rbac.proto
kitex -module github.com/example/adminbfftask2 -type protobuf -I idl idl/rule_center.proto
go mod tidy
go test ./internal/pkg/middleware/... -run TestVerifyToken_RealIssuerShapedToken_PopulatesUid -v
go test ./internal/router/... -run 'TestAuthz_|TestTerminalUsersRoute_|TestUnprotectedRoute_' -v
```

All listed tests must pass, including the new `TestAuthz_UsesRealJWTIdentity_PropagatesUidToRBAC`. Confirm via `grep -n "UUID\|UserID" internal/pkg/middleware/*.go internal/handler/*.go internal/router/*.go` that zero references to the old field names remain, and `grep -rn '{{ "{' internal/pkg/middleware/*.go internal/handler/*.go internal/router/*.go` returns zero matches.

- [ ] **Step 9: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_pkg_middleware_token_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml \
        admin-bff-hertz/hertz-template/internal_pkg_middleware_authz_go.yaml \
        admin-bff-hertz/hertz-template/internal_handler_current_user_go.yaml \
        admin-bff-hertz/hertz-template/internal_handler_auth_go.yaml \
        admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml
git commit -m "fix(admin-bff-hertz): unify JWT Claims to a single Uid field, propagate through all consumers"
```

---

### Task 3: `ratelimit-hertz` — unify Claims to a single `Uid` field (discovered during final review, same bug as Task 1/2)

**Files:**
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`
- Modify: `ratelimit-hertz/README.md`
- Test (new): `ratelimit-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`

**Interfaces:**
- Consumes: same `Claims{Uid, AK, Roles, jwt.RegisteredClaims}` shape Task 1/2 established.
- Produces: nothing consumed by a later task.

**Impact note:** `ratelimit-hertz`'s entire value proposition is rate limiting. `internal_pkg_ratelimit_store_go.yaml`'s `"ak_user_uuid"`/`"user_uuid"` key-by branches silently fall through to a fallback key when `claims.UUID` is empty — meaning any deployment configuring "rate limit by user" currently degrades silently to a shared IP/global bucket for every authenticated user. This task does not touch `ratelimit/store.go`'s key-by branch logic itself (out of scope, unchanged), only the `claims.UUID` read that feeds it — same boundary Task 2 drew for `admin-bff-hertz`.

- [ ] **Step 1: Write a failing regression test proving the bug (mirrors Task 1 Step 1)**

`ratelimit-hertz` has no `token_test.go` today either. Create `ratelimit-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/middleware/token_test.go
path: internal/pkg/middleware/token_test.go
update_behavior:
    type: cover
body: |-
    package middleware

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/golang-jwt/jwt/v5"

    	"{{.Module}}/internal/base/conf"
    )

    // TestVerifyToken_RealIssuerShapedToken_PopulatesUid signs a token with
    // the exact claim shape rbac-kitex/admin-services-kitex/user-kitex
    // actually issue (only a "uid" claim) and proves VerifyToken recovers a
    // non-empty, correct Uid. Before this task's fix, rateLimitUserUUID(c)
    // (rate_limit.go) always read an empty claims.UUID from a real token,
    // silently degrading "rate limit by user" to a shared bucket.
    func TestVerifyToken_RealIssuerShapedToken_PopulatesUid(t *testing.T) {
    	secret := "test-secret"
    	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
    		"uid":   "user-123",
    		"roles": []interface{}{"member"},
    		"exp":   time.Now().Add(time.Hour).Unix(),
    	})
    	tokenStr, err := token.SignedString([]byte(secret))
    	if err != nil {
    		t.Fatalf("failed to sign test token: %v", err)
    	}

    	verifier := JWTVerifier{Config: conf.TokenConfig{Enabled: true, SigningKey: secret}}
    	claims, err := verifier.VerifyToken(context.Background(), tokenStr)
    	if err != nil {
    		t.Fatalf("VerifyToken() error = %v, want nil", err)
    	}
    	if claims.Uid != "user-123" {
    		t.Errorf("claims.Uid = %q, want %q", claims.Uid, "user-123")
    	}
    }
```

Run: `go build ./internal/pkg/middleware/...` (against a fresh render — see Step 8) — expect the same RED compile failure as Task 1/2 Step 1.

- [ ] **Step 2: Rename `Claims` fields in `token.go`**

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`. Change:

```go
type Claims struct {
	UserID string   `json:"user_id"`
	UUID   string   `json:"uuid"`
	AK     string   `json:"ak"`
	Roles  []string `json:"roles,omitempty"`
	jwt.RegisteredClaims
}
```

to:

```go
type Claims struct {
	Uid   string   `json:"uid"`
	AK    string   `json:"ak"`
	Roles []string `json:"roles,omitempty"`
	jwt.RegisteredClaims
}
```

- [ ] **Step 3: Fix the unused-but-must-compile `JWT()` function and its test**

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml` (uses `{{ "{" }}`/`{{ "}" }}` escaping — confirm before editing). Change:

```go
		uuid, _ := claims["uuid"].(string)
```
to:
```go
		uid, _ := claims["uid"].(string)
```

and change:

```go
		c.Set(ContextKeyTokenClaims, &Claims{{ "{" }}
			UUID:  uuid,
			Roles: roles,
		{{ "}" }})
```
to:
```go
		c.Set(ContextKeyTokenClaims, &Claims{{ "{" }}
			Uid:   uid,
			Roles: roles,
		{{ "}" }})
```

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml` (this file is byte-identical to `base-hertz`'s copy) — apply the identical changes Task 1 Step 3 made: both `jwt.MapClaims` literals' `"uuid"` key → `"uid"`, and the `claims.UUID`/`"expected UUID..."` assertion → `claims.Uid`/`"expected Uid..."` in `TestJWT_ValidToken_SetsClaims`; the signed claim key `"uuid"` → `"uid"` in `TestJWT_ExpiredToken_Aborts`.

- [ ] **Step 4: Fix `idempotency.go`'s identity scoping and its test**

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`. Change:

```go
    	switch {
    	case claims.AK != "" && claims.UUID != "":
    		scope = "ak_user_uuid:" + claims.AK + ":" + claims.UUID
    	case claims.UUID != "":
    		scope = "user_uuid:" + claims.UUID
    	case claims.AK != "":
    		scope = "ak:" + claims.AK
    	}
```
to:
```go
    	switch {
    	case claims.AK != "" && claims.Uid != "":
    		scope = "ak_user_uuid:" + claims.AK + ":" + claims.Uid
    	case claims.Uid != "":
    		scope = "user_uuid:" + claims.Uid
    	case claims.AK != "":
    		scope = "ak:" + claims.AK
    	}
```

(Confirm this file's actual brace style before editing — Task 1's `base-hertz` copy is plain-brace; verify `ratelimit-hertz`'s copy matches before applying.)

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`. Change:

```go
	c.Set(ContextKeyTokenClaims, &Claims{AK: "verified-ak", UUID: "user-1"})
```
to:
```go
	c.Set(ContextKeyTokenClaims, &Claims{AK: "verified-ak", Uid: "user-1"})
```

- [ ] **Step 5: Fix `rate_limit.go`'s identity resolver and its test**

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`. Change:

```go
    func rateLimitUserUUID(c *app.RequestContext) string {
    	claims, hasClaims := GetClaims(c)
    	if hasClaims {
    		return strings.TrimSpace(claims.UUID)
    	}
    	return ""
    }
```
to:
```go
    func rateLimitUserUUID(c *app.RequestContext) string {
    	claims, hasClaims := GetClaims(c)
    	if hasClaims {
    		return strings.TrimSpace(claims.Uid)
    	}
    	return ""
    }
```

(`rateLimitUserUUID`'s own function name is left as-is, out of scope — same boundary as Task 2 Step 5.)

Edit `ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`. Change both:
```go
	first.Set(ContextKeyTokenClaims, &Claims{UUID: "user-1"})
```
```go
	second.Set(ContextKeyTokenClaims, &Claims{UUID: "user-1"})
```
to:
```go
	first.Set(ContextKeyTokenClaims, &Claims{Uid: "user-1"})
```
```go
	second.Set(ContextKeyTokenClaims, &Claims{Uid: "user-1"})
```
(Match this file's actual brace style — confirm plain vs. `{{ "{" }}` before editing.)

- [ ] **Step 6: Update `README.md`'s documented `Claims` struct**

Edit `ratelimit-hertz/README.md`. In the "JWT Claims" section, change:

```go
type Claims struct {
    UserID string   `json:"user_id"`
    UUID   string   `json:"uuid"`
    AK     string   `json:"ak"`
    Roles  []string `json:"roles,omitempty"`
    jwt.RegisteredClaims
}
```
to:
```go
type Claims struct {
    Uid    string   `json:"uid"`
    AK     string   `json:"ak"`
    Roles  []string `json:"roles,omitempty"`
    jwt.RegisteredClaims
}
```

- [ ] **Step 7: Full render + build + test via the existing e2e script**

```bash
<repo>/ratelimit-hertz/test/e2e_test.sh
```

Must exit 0. This script's hermetic (memory backend) baseline is required to pass; redis/postgres variants are gated on tool availability per the script's own logic — do not treat a `skipped: <reason>` line for those as a failure.

Then, for a faster focused check while iterating:

```bash
rm -rf /tmp/ratelimithertz-task3-validate
ncgo new ratelimithertztask3 --kind hertz --module github.com/example/ratelimithertztask3 \
  --template-dir <repo>/ratelimit-hertz --dir /tmp/ratelimithertz-task3-validate
cd /tmp/ratelimithertz-task3-validate
go mod tidy
go build ./... && go vet ./... && go test ./... && go test -race ./...
```

All must pass, including the new `TestVerifyToken_RealIssuerShapedToken_PopulatesUid`. Confirm via `grep -n "UUID\|UserID" internal/pkg/middleware/*.go` that zero references to the old field names remain, and `grep -rn '{{ "{' internal/pkg/middleware/*.go` returns zero matches.

- [ ] **Step 8: Commit**

```bash
git add ratelimit-hertz/hertz-template/internal_pkg_middleware_token_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml \
        ratelimit-hertz/README.md
git commit -m "fix(ratelimit-hertz): unify JWT Claims to a single Uid field matching issuer schema"
```
