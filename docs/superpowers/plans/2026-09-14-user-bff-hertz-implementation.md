# user-bff-hertz Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `user-bff-hertz` Hertz HTTP template package — a browser-facing gateway in front of the already-shipped `user-kitex` RPC service, providing local register/login, OAuth2 login via browser redirect + one-time code exchange, and bind/unbind of third-party identities — plus a small, contained extension to `user-kitex` (already merged to `main`) so the bind flow no longer trusts a client-supplied `uid`.

**Architecture:** `user-kitex` extension (state payload carries `uid`) → `user-bff-hertz`: `internal/pkg/middleware/{cors,token,idempotency,rate_limit,resolver}` (CORS/JWT/idempotency/rule-center-backed rate limit) → `internal/pkg/oauthcode` (one-time code→JWT exchange store, Redis) → `internal/handler/{auth,oauth}` (register/login, OAuth start/callback/exchange, bind/unbind) → `internal/router` → `internal/base/server` wiring. Each template file is an `ncgo` `.yaml` wrapper under `user-bff-hertz/hertz-template/`, following `admin-bff-hertz`'s established conventions exactly (same middleware structure, same `response`/`conf` package shapes) except where `user-bff-hertz`'s own `Claims` type must diverge to match what `user-kitex` actually signs.

**Tech Stack:** Go 1.22+, Hertz, `github.com/golang-jwt/jwt/v5`, Redis (`github.com/redis/go-redis/v9`), Kitex client (`pkg/client/userservice` from `user-kitex`), `github.com/google/uuid`, `github.com/byx-darwin/go-tools/go-framework/hertz` (RPCErrorRouter).

**Spec:** `docs/superpowers/specs/2026-09-14-user-bff-hertz-design.md`

## Global Constraints

- Literal Go braces `{` / `}` inside `body:` blocks MUST be written as `{{ "{" }}` / `{{ "}" }}` — the dominant, required escaping convention across this template corpus (verified again in `admin-bff-hertz`'s middleware files).
- **`user-bff-hertz`'s JWT `Claims` type MUST use `Uid string \`json:"uid"\`` (matching what `user-kitex` actually signs — reused verbatim from `rbac-kitex`'s `Claims{Uid, Roles}`), NOT `admin-bff-hertz`'s `Claims{UserID, UUID, AK, Roles}` shape.** Copying `admin-bff-hertz`'s `token.go` unmodified would silently decode an empty identity from a real `user-kitex`-issued token — this exact mismatch is filed separately as Issue #66 (not fixed here; `user-bff-hertz` works around it with its own correct `Claims` type, structurally styled like `admin-bff-hertz`'s but with different fields).
- The one-time OAuth code→JWT exchange store is **independent** of `user-kitex`'s own CSRF `StateStore` — different package, different Redis key prefix, different TTL (60s vs 10min), different purpose. Do not conflate them.
- `BindProviderReq`'s `uid` field is being **removed** from `user-kitex`'s proto in Task 1 of this plan — after Task 1, the bind flow's identity comes exclusively from the OAuth state (Redis), never from a client-supplied field. `user-bff-hertz`'s bind-start handler is the only piece of code responsible for putting the authenticated user's `uid` into that state (via the extended `OAuthStart` RPC), and it MUST get that `uid` from the JWT middleware's verified claims, never from a request body/query param.
- Rate limiting reuses `admin-bff-hertz`'s `rule-center`-backed dynamic rule middleware (not a self-contained limiter) — `user-bff-hertz` therefore has a gRPC dependency on `rule-center` in addition to `user-kitex`.
- **CORRECTED in Task 9 (see SDD ledger Ruling):** `user-bff-hertz` DOES carry its own `idl/user.proto` (copy of `user-kitex/idl/user.proto`) and `idl/rule_center.proto` (copy of `admin-bff-hertz/idl/rule_center.proto`) — this reverses the plan's original "no proto/IDL" constraint, which was an unverified assumption made during brainstorming. `user-bff-hertz`'s HTTP-facing handlers remain hand-authored Go (no `idl/app/*.proto`, no `hz`-generated handlers) — only the two *client-facing* RPC protos are added, exactly mirroring `admin-bff-hertz`'s own `idl/{auth,rbac,rule_center}.proto` precedent. Verified end-to-end against the real `ncgo` CLI: `ncgo new` renders these protos with `{{.Module}}` substituted; a post-scaffold `ncgo add kitex-client user --service UserService --idl idl/user.proto` (and the equivalent for `rule_center`) populates `kitex_gen/` and lets `go mod tidy`/`go build` succeed — this step must be documented in Task 10's README (mirroring the same undocumented gap that exists in `admin-bff-hertz`'s own README, now closed here instead of repeated).

---

### Task 1: Extend `user-kitex` — OAuth state carries `uid`, `BindProviderReq` no longer trusts a client-supplied `uid`

**Files:**
- Modify: `user-kitex/idl/user.proto`
- Modify: `user-kitex/kitex-template/internal_pkg_oauth_state_go.yaml`
- Modify: `user-kitex/kitex-template/internal_pkg_oauth_state_test_go.yaml`
- Modify: `user-kitex/kitex-template/internal_application_user_dto_go.yaml`
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`
- Modify: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`

**Interfaces:**
- Consumes: nothing new (this is entirely within `user-kitex`, already-committed code).
- Produces: `oauth.StateStore.Put(ctx, state, provider, purpose, uid string, ttl time.Duration) error`, `.Consume(ctx, state string) (provider, purpose, uid string, ok bool, err error)`; `usersvc.OAuthStart(ctx, providerName, purpose, uid string) (string, error)`; `userv1.OAuthStartReq` gains `uid` field (proto field 3); `userv1.BindProviderReq` loses its `uid` field — **Task 2+ of this plan (the `user-bff-hertz` side) depends on this exact shape.**

- [ ] **Step 1: Update the proto**

Edit `user-kitex/idl/user.proto`. Change `OAuthStartReq`:

```protobuf
message OAuthStartReq {
  string provider = 1;
  // purpose distinguishes a login-flow start ("login") from a bind-flow
  // start ("bind"); the resulting state token is tagged with it and the
  // matching callback (OAuthCallback for "login", BindProvider for "bind")
  // rejects the state if the purpose (or provider) doesn't match. Defaults
  // to "login" when empty.
  string purpose = 2;
  // uid is the already-authenticated user starting a bind flow. Required
  // when purpose == "bind" (OAuthStart rejects a bind request with an
  // empty uid); ignored when purpose == "login". The caller (a BFF/gateway)
  // MUST populate this only from a verified JWT, never from unauthenticated
  // client input.
  string uid = 3;
}
```

Change `BindProviderReq` — remove the `uid` field entirely and reserve it so it's never reused by accident:

```protobuf
message BindProviderReq {
  reserved 1;
  reserved "uid";
  // provider/state/code identify the OAuth callback being completed. The
  // user being bound is NOT taken from this message — it comes from the
  // uid embedded in the OAuth state (see OAuthStartReq.uid), which was set
  // when the bind flow was started by an already-authenticated caller.
  // This RPC no longer trusts a client-supplied uid.
  string provider = 2;
  string state = 3;
  string code = 4;
}
```

- [ ] **Step 2: Update the OAuth state store**

Edit `user-kitex/kitex-template/internal_pkg_oauth_state_go.yaml`. Replace the whole `body:` with:

```yaml
# ncgo exported template — internal/pkg/oauth/state.go
path: internal/pkg/oauth/state.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"errors"
    	"time"

    	"github.com/redis/go-redis/v9"
    )

    // StateStore issues and single-use-consumes OAuth CSRF state tokens.
    //
    // Put/Consume carry the provider name, a purpose tag ("login" or
    // "bind"), and — for bind flows — the uid of the already-authenticated
    // user who started the flow. Consume returns all three so the caller
    // can verify the state was issued for the provider/purpose it is now
    // being presented to, and (for bind) which user it belongs to without
    // trusting any client-supplied identity in the callback request.
    type StateStore interface {{ "{" }}
    	// Put records state as valid for ttl, tagged with the provider,
    	// purpose ("login" or "bind"), and — for "bind" — the uid of the
    	// user who started the flow (empty for "login").
    	Put(ctx context.Context, state, provider, purpose, uid string, ttl time.Duration) error
    	// Consume reports whether state was valid and, if so, deletes it so
    	// it cannot be replayed, returning the provider, purpose, and uid it
    	// was originally issued with.
    	Consume(ctx context.Context, state string) (provider, purpose, uid string, ok bool, err error)
    {{ "}" }}

    const stateKeyPrefix = "oauth:state:"

    // statePayload is the JSON value stored in Redis for a single state
    // token, carrying the provider + purpose + (for bind) uid it was
    // issued for.
    type statePayload struct {{ "{" }}
    	Provider string `json:"provider"`
    	Purpose  string `json:"purpose"`
    	Uid      string `json:"uid,omitempty"`
    {{ "}" }}

    // RedisStateStore stores OAuth state tokens in Redis with a TTL and
    // atomically deletes them on first consumption (GETDEL).
    type RedisStateStore struct {{ "{" }}
    	client *redis.Client
    {{ "}" }}

    // NewRedisStateStore wraps an existing Redis client.
    func NewRedisStateStore(client *redis.Client) *RedisStateStore {{ "{" }}
    	return &RedisStateStore{{ "{" }}client: client{{ "}" }}
    {{ "}" }}

    // Put records state as valid for ttl, tagged with provider, purpose,
    // and (for bind flows) uid.
    func (s *RedisStateStore) Put(ctx context.Context, state, provider, purpose, uid string, ttl time.Duration) error {{ "{" }}
    	raw, err := json.Marshal(statePayload{{ "{" }}Provider: provider, Purpose: purpose, Uid: uid{{ "}" }})
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	return s.client.Set(ctx, stateKeyPrefix+state, raw, ttl).Err()
    {{ "}" }}

    // Consume reports whether state was valid and, if so, deletes it so it
    // cannot be replayed, returning the provider + purpose + uid it was
    // issued for.
    func (s *RedisStateStore) Consume(ctx context.Context, state string) (provider, purpose, uid string, ok bool, err error) {{ "{" }}
    	raw, err := s.client.GetDel(ctx, stateKeyPrefix+state).Result()
    	if errors.Is(err, redis.Nil) {{ "{" }}
    		return "", "", "", false, nil
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return "", "", "", false, err
    	{{ "}" }}
    	var payload statePayload
    	if err := json.Unmarshal([]byte(raw), &payload); err != nil {{ "{" }}
    		return "", "", "", false, err
    	{{ "}" }}
    	return payload.Provider, payload.Purpose, payload.Uid, true, nil
    {{ "}" }}
```

- [ ] **Step 3: Update the state store test**

Edit `user-kitex/kitex-template/internal_pkg_oauth_state_test_go.yaml` — every `Put(ctx, state, provider, purpose, ttl)` call becomes `Put(ctx, state, provider, purpose, uid, ttl)`, and every `Consume` call site that destructures `(provider, purpose, ok, err)` becomes `(provider, purpose, uid, ok, err)`. Update the whole `body:` to:

```yaml
# ncgo exported template — internal/pkg/oauth/state_test.go
path: internal/pkg/oauth/state_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/alicebob/miniredis/v2"
    	"github.com/redis/go-redis/v9"
    )

    func newTestRedis(t *testing.T) *redis.Client {{ "{" }}
    	t.Helper()
    	mr, err := miniredis.Run()
    	if err != nil {{ "{" }}
    		t.Fatalf("start miniredis: %v", err)
    	{{ "}" }}
    	t.Cleanup(mr.Close)
    	return redis.NewClient(&redis.Options{{ "{" }}Addr: mr.Addr(){{ "}" }})
    {{ "}" }}

    func TestRedisStateStore_PutConsume(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := NewRedisStateStore(newTestRedis(t))

    	if err := store.Put(ctx, "state-1", "github", "login", "", time.Minute); err != nil {{ "{" }}
    		t.Fatalf("put: %v", err)
    	{{ "}" }}

    	provider, purpose, uid, ok, err := store.Consume(ctx, "state-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if !ok {{ "{" }}
    		t.Fatal("expected state to be found and consumed")
    	{{ "}" }}
    	if provider != "github" || purpose != "login" || uid != "" {{ "{" }}
    		t.Fatalf("unexpected provider/purpose/uid: %q/%q/%q", provider, purpose, uid)
    	{{ "}" }}

    	_, _, _, ok, err = store.Consume(ctx, "state-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume again: %v", err)
    	{{ "}" }}
    	if ok {{ "{" }}
    		t.Fatal("expected state to be gone after first consume (single use)")
    	{{ "}" }}
    {{ "}" }}

    func TestRedisStateStore_UnknownState(t *testing.T) {{ "{" }}
    	store := NewRedisStateStore(newTestRedis(t))
    	_, _, _, ok, err := store.Consume(context.Background(), "never-issued")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if ok {{ "{" }}
    		t.Fatal("expected unknown state to report not-found")
    	{{ "}" }}
    {{ "}" }}

    func TestRedisStateStore_BindCarriesUid(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := NewRedisStateStore(newTestRedis(t))

    	if err := store.Put(ctx, "state-bind-1", "wechat", "bind", "018f0000-0000-7000-8000-000000000001", time.Minute); err != nil {{ "{" }}
    		t.Fatalf("put: %v", err)
    	{{ "}" }}

    	provider, purpose, uid, ok, err := store.Consume(ctx, "state-bind-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if !ok {{ "{" }}
    		t.Fatal("expected state to be found")
    	{{ "}" }}
    	if provider != "wechat" || purpose != "bind" || uid != "018f0000-0000-7000-8000-000000000001" {{ "{" }}
    		t.Fatalf("unexpected provider/purpose/uid: %q/%q/%q", provider, purpose, uid)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it fails, then update `usersvc` to match**

Run: `go test ./internal/pkg/oauth/... -v` (rendered scratch project). Expected: FAIL — `Put`/`Consume` call sites elsewhere in the package (none in `oauth` itself, but `usersvc` won't compile yet) — actually this specific test will PASS on its own since `oauth` package is self-consistent; the FAILURE will show up as a compile error in `usersvc` (Task 12's package), which is expected and fixed by the rest of this task. Run `go build ./...` and confirm the failure is exactly in `internal/application/user` referencing the old `Put`/`Consume` signatures, nowhere else.

- [ ] **Step 5: Update `usersvc` DTOs, `OAuthStart`, `OAuthCallback`, `BindProvider`**

Edit `user-kitex/kitex-template/internal_application_user_dto_go.yaml` — remove the `Uid` field from `BindProviderInput`:

```yaml
# ncgo exported template — internal/application/user/dto.go
path: internal/application/user/dto.go
update_behavior:
    type: cover
body: |-
    package usersvc

    type RegisterInput struct {{ "{" }}
    	Username string
    	Password string
    {{ "}" }}

    type RegisterOutput struct {{ "{" }}
    	Uid string
    {{ "}" }}

    type LoginInput struct {{ "{" }}
    	Username string
    	Password string
    {{ "}" }}

    type LoginOutput struct {{ "{" }}
    	Uid   string
    	Token string
    {{ "}" }}

    type OAuthCallbackInput struct {{ "{" }}
    	Provider string
    	State    string
    	Code     string
    {{ "}" }}

    type BindProviderInput struct {{ "{" }}
    	Provider string
    	State    string
    	Code     string
    {{ "}" }}
```

Edit `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`:
- `OAuthStart(ctx context.Context, providerName, purpose string) (string, error)` becomes `OAuthStart(ctx context.Context, providerName, purpose, uid string) (string, error)`. After the existing purpose validation, add: if `purpose == oauthPurposeBind && uid == ""`, return `errors.New("user: uid required for bind purpose")`. Pass `uid` through to `s.stateStore.Put(ctx, state, providerName, purpose, uid, 10*time.Minute)`.
- `OAuthCallback`: `provider, purpose, _, ok, err := s.stateStore.Consume(ctx, in.State)` (uid discarded — login flow doesn't need it, the user is identified by the provider identity lookup as before). No other change to this method's body.
- `BindProvider(ctx context.Context, in BindProviderInput) error`: change `provider, purpose, ok, err := s.stateStore.Consume(...)` to `provider, purpose, uid, ok, err := s.stateStore.Consume(...)`; add a check that `uid != ""` alongside the existing `!ok || provider != in.Provider || purpose != oauthPurposeBind` check (if state was somehow stored without a uid, treat as invalid — `!ok || provider != in.Provider || purpose != oauthPurposeBind || uid == ""`); replace `uid, err := parseUID(in.Uid)` with `parsedUID, err := parseUID(uid)` and use `parsedUID` in the rest of the function body (the existing code after this line uses a local variable named `uid` for the parsed `user.ID` — rename that local to `parsedUID` throughout the rest of the function to avoid shadowing/confusion with the new string `uid` from `Consume`).

- [ ] **Step 6: Update the Kitex handler**

Edit `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`:
- `OAuthStart` handler: `url, err := h.self.OAuthStart(ctx, req.Provider, purpose, req.Uid)`.
- `BindProvider` handler: `err := h.self.BindProvider(ctx, usersvc.BindProviderInput{{ "{" }}Provider: req.Provider, State: req.State, Code: req.Code{{ "}" }})` (no `Uid` field).

- [ ] **Step 7: Update the `usersvc` test file for the new signatures**

Edit `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml` — every direct call to `svc.OAuthStart(ctx, "provider")`-shaped test helper (if any exist for the login path) becomes `svc.OAuthStart(ctx, "provider", "login", "")`; every `BindProviderInput{{ "{" }}Uid: ..., Provider: ..., ...{{ "}" }}` literal drops the `Uid` field. Since the exact current test file content should be read before editing (its precise shape may have grown/changed slightly across earlier fix rounds — re-read the committed file first rather than assuming the version described in the original Plan 1 document), apply the signature changes surgically: locate every call site of `OAuthStart`, `Consume`-mocking fake `StateStore` implementations (the fake's `Put`/`Consume` method signatures must also be updated to the new 5/5-arg shapes), and `BindProviderInput{{ "{" }}...{{ "}" }}` literals, and update each to match Steps 2/5 exactly.

- [ ] **Step 8: Full render + build + test**

Run the full render/build/test cycle used throughout `user-kitex`'s own plan: `DIR=$(mktemp -d); ncgo new tplcheck --module example.com/user-e2e --kind kitex --template-dir user-kitex --dir "$DIR/tplcheck"`, then `sqlc generate` (or `make sqlc`), `go build ./...`, `go vet ./...`, `go test ./...`, `go test -race ./...`. All must pass with zero regressions across every package (this touches `oauth`, `usersvc`, and the Kitex handler — three packages other tasks in this plan and the already-shipped `user-kitex` binary depend on).

- [ ] **Step 9: Commit**

```bash
git add user-kitex/idl/user.proto \
        user-kitex/kitex-template/internal_pkg_oauth_state_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_state_test_go.yaml \
        user-kitex/kitex-template/internal_application_user_dto_go.yaml \
        user-kitex/kitex-template/internal_application_user_user_service_go.yaml \
        user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml \
        user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml
git commit -m "feat(user-kitex): thread uid through OAuth state so BindProvider no longer trusts a client-supplied uid"
```

---

### Task 2: `user-bff-hertz` scaffolding — `conf.yaml`, `response.go`, `main.yaml`, `makefile.yaml`, `template.yaml`

**Files:**
- Create: `user-bff-hertz/hertz-template/conf.yaml`
- Create: `user-bff-hertz/hertz-template/conf_dev.yaml`
- Create: `user-bff-hertz/hertz-template/response_go.yaml`
- Create: `user-bff-hertz/hertz-template/main.yaml`
- Create: `user-bff-hertz/hertz-template/makefile.yaml`
- Create: `user-bff-hertz/template.yaml`

**Interfaces:**
- Consumes: nothing from other tasks in this plan (foundation task).
- Produces: `conf.Config{Server, RPC{UserService, RuleCenter kitexclient.Config-shaped}, Redis, CORS, RateLimit, Idempotency, Auth.Token, OAuthCode, Log}` and `conf.Get()`/`conf.Load()` — consumed by every later task; `response.OK`/`response.Err`/`response.ErrorCode`/error code constants — consumed by every handler task.

- [ ] **Step 1: Write `conf.yaml`**

Mirror `admin-bff-hertz/hertz-template/conf_go.yaml`'s complete `Config` struct/`Load()`/`Default()`/`Validate()` shape (Server, Redis, CORS, RateLimit, Idempotency, Log, Jaeger — copy structurally), with these package-specific changes:
- Replace `admin-bff-hertz`'s `RPC` client config (pointing at `authservice`/`rbacservice`/`ruleservice`) with two RPC client configs: `UserService` (pointing at `user-kitex`'s `userserviceclient.Config` shape — `ServiceName, CallerService, HostPorts, RPCTimeoutSeconds, ConnectTimeoutMilliseconds, EnableMetaInfo, Retry`, matching `user-kitex/kitex-template/client.yaml`'s `Config` struct exactly since `user-bff-hertz` will construct a `userserviceclient.Config` from this) and `RuleCenter` (same shape, pointing at `rule-center`'s client — mirror whatever `admin-bff-hertz`'s `conf.go` currently has for its `RuleCenter` RPC client field, since `user-bff-hertz` reuses the same rate-limit-resolver machinery).
- `Auth.Token` (`TokenConfig{Enabled, Header, SigningKey, Issuer}`) — same shape as `admin-bff-hertz`'s, but this plan's own `token.go` (Task 3) is what actually consumes it, so keep the config shape identical for consistency even though the `Claims` type differs.
- Add a new `OAuthCode` config section: `OAuthCodeConfig{Redis RedisConfig, TTLSeconds config.Duration}` (defaults: reuse the top-level `Redis` config if unset, `TTLSeconds` default 60) — consumed by Task 4's code-exchange store.
- Add a new `OAuthRedirect` config section: `OAuthRedirectConfig{SuccessURL, BindSuccessURL, ErrorURL string}` — the front-end URLs `user-bff-hertz` 302s back to after OAuth callbacks complete (login success appends `?code=...`; bind success/error don't need a code). No default — `Validate()` requires these non-empty (a template consumer MUST configure their actual frontend URLs; an empty default would silently redirect nowhere).
- No `Signature` config section (this package deliberately excludes API-signature middleware per the design's explicit scope decision).

- [ ] **Step 2: Write `conf_dev.yaml`**

Mirror `admin-bff-hertz/hertz-template/conf_dev_conf_yaml.yaml`'s structure with `user-bff-hertz`-appropriate defaults: `rpc.user_service.host_ports: ["127.0.0.1:8888"]` (matching `user-kitex`'s default port from its own `main.yaml`), `rpc.rule_center.host_ports` (same placeholder pattern `admin-bff-hertz`'s dev config uses), `oauth_redirect.success_url: "http://localhost:3000/auth/callback"`, `oauth_redirect.bind_success_url: "http://localhost:3000/settings/connections"`, `oauth_redirect.error_url: "http://localhost:3000/auth/error"`, `auth.token.enabled: true` with a dev placeholder `signing_key` (same convention as `rbac-kitex`'s `conf_dev.yaml` uses for `auth.jwt_secret`, e.g. `"dev-secret-change-me"` — **this MUST match the actual signing key `user-kitex`'s own dev config uses, or JWT verification will fail end-to-end in local dev**: check `user-kitex/kitex-template/conf_dev.yaml`'s `auth.jwt_secret` value and use the exact same string here).

- [ ] **Step 3: Write `response.go`**

Copy `admin-bff-hertz/hertz-template/response_go.yaml` verbatim (path, error code registry, `NewResponder`/`OK`/`Err`/`ErrorCode`/`StatusFromCode`/`MsgFromCode` — this is generic infrastructure with no admin-specific content, safe to reuse byte-for-byte).

- [ ] **Step 4: Write `main.yaml`, `makefile.yaml`**

Mirror `admin-bff-hertz/hertz-template/main_go.yaml` and `makefile_yaml.yaml` structurally — service name substitution only, no `user-bff-hertz`-specific logic (server bootstrap is generic: load conf, construct clients, build router, start Hertz).

- [ ] **Step 5: Write `template.yaml`**

```yaml
name: user-bff-hertz
kind: hertz
description: "Official end-user HTTP gateway for user-kitex (local + third-party OAuth2/OIDC login, one-time code JWT exchange, account binding)"
version: "1"
skip_default_templates:
  - handler.yaml
  - usecase.yaml
  - repository.yaml
  - server.yaml
```

(Only the generic ncgo Hertz-kind default fragments need excluding — this package has no rule-center-specific fragments to suppress, unlike `admin-bff-hertz`, since it never had that content embedded for its `kind`.)

- [ ] **Step 6: Commit**

```bash
git add user-bff-hertz/hertz-template/conf.yaml \
        user-bff-hertz/hertz-template/conf_dev.yaml \
        user-bff-hertz/hertz-template/response_go.yaml \
        user-bff-hertz/hertz-template/main.yaml \
        user-bff-hertz/hertz-template/makefile.yaml \
        user-bff-hertz/template.yaml
git commit -m "feat(user-bff-hertz): scaffold conf/response/main/makefile/template.yaml"
```

---

### Task 3: JWT middleware with the correct `Claims{Uid, Roles}` shape

**Files:**
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_token_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml`

**Interfaces:**
- Consumes: `conf.TokenConfig` (Task 2), `response.ErrorCode`/error codes (Task 2).
- Produces: `middleware.Claims{Uid string, Roles []string}`, `middleware.ContextKeyTokenClaims`, `middleware.JWTAuth(cfg conf.TokenConfig) app.HandlerFunc`, `middleware.GetClaims(c *app.RequestContext) (*Claims, bool)` — consumed by every later middleware/handler task that needs the authenticated `uid`.

- [ ] **Step 1: Write the failing test**

```yaml
# ncgo exported template — internal/pkg/middleware/token_test.go
path: internal/pkg/middleware/token_test.go
update_behavior:
    type: cover
body: |-
    package middleware

    import (
    	"context"
    	"net/http/httptest"
    	"testing"
    	"time"

    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/cloudwego/hertz/pkg/protocol"
    	"github.com/golang-jwt/jwt/v5"

    	"{{.Module}}/internal/base/conf"
    )

    func signTestToken(t *testing.T, secret, uid string, roles []string) string {{ "{" }}
    	t.Helper()
    	claims := Claims{{ "{" }}
    		Uid:   uid,
    		Roles: roles,
    		RegisteredClaims: jwt.RegisteredClaims{{ "{" }}
    			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
    		{{ "}" }},
    	{{ "}" }}
    	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
    	if err != nil {{ "{" }}
    		t.Fatalf("sign: %v", err)
    	{{ "}" }}
    	return tok
    {{ "}" }}

    func TestJWTAuth_ValidToken_SetsClaims(t *testing.T) {{ "{" }}
    	cfg := conf.TokenConfig{{ "{" }}Enabled: true, Header: "Authorization", SigningKey: "test-secret"{{ "}" }}
    	tok := signTestToken(t, "test-secret", "018f0000-0000-7000-8000-000000000001", []string{{ "{" }}"user"{{ "}" }})

    	ctx := app.NewContext(0)
    	req := protocol.NewRequest("GET", "/anything", nil)
    	req.Header.Set("Authorization", "Bearer "+tok)
    	ctx.Init(req, httptest.NewRecorder().Result().Header, nil)

    	var reached bool
    	handler := JWTAuth(cfg)
    	handler(context.Background(), ctx)
    	if !ctx.IsAborted() {{ "{" }}
    		reached = true
    	{{ "}" }}
    	if !reached {{ "{" }}
    		t.Fatal("expected handler to call c.Next, not abort")
    	{{ "}" }}

    	claims, ok := GetClaims(ctx)
    	if !ok {{ "{" }}
    		t.Fatal("expected claims to be set")
    	{{ "}" }}
    	if claims.Uid != "018f0000-0000-7000-8000-000000000001" {{ "{" }}
    		t.Fatalf("expected uid to round-trip, got %q", claims.Uid)
    	{{ "}" }}
    	if len(claims.Roles) != 1 || claims.Roles[0] != "user" {{ "{" }}
    		t.Fatalf("expected roles to round-trip, got %v", claims.Roles)
    	{{ "}" }}
    {{ "}" }}

    func TestJWTAuth_MissingToken_Aborts(t *testing.T) {{ "{" }}
    	cfg := conf.TokenConfig{{ "{" }}Enabled: true, Header: "Authorization", SigningKey: "test-secret"{{ "}" }}
    	ctx := app.NewContext(0)
    	req := protocol.NewRequest("GET", "/anything", nil)
    	ctx.Init(req, httptest.NewRecorder().Result().Header, nil)

    	JWTAuth(cfg)(context.Background(), ctx)
    	if !ctx.IsAborted() {{ "{" }}
    		t.Fatal("expected missing token to abort the chain")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/middleware/... -run JWTAuth -v` (rendered scratch project). Expected: FAIL — `undefined: Claims`, `undefined: JWTAuth`.

- [ ] **Step 3: Write the JWT middleware**

```yaml
# ncgo exported template — internal/pkg/middleware/token.go
path: internal/pkg/middleware/token.go
update_behavior:
    type: cover
body: |-
    package middleware

    import (
    	"context"
    	"errors"
    	"strings"

    	goerror "github.com/byx-darwin/go-tools/go-common/error"
    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/golang-jwt/jwt/v5"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/pkg/response"
    )

    const ContextKeyTokenClaims = "tokenClaims"

    // Claims matches exactly what user-kitex (reusing rbac-kitex's JWT
    // issuance) signs: Uid + Roles, json key "uid" not "uuid". Do NOT copy
    // admin-bff-hertz's Claims{UserID, UUID, AK, Roles} shape here — it
    // decodes an empty identity from a real user-kitex-issued token (see
    // Issue #66). This mismatch is deliberate and package-local.
    type Claims struct {{ "{" }}
    	Uid   string   `json:"uid"`
    	Roles []string `json:"roles"`
    	jwt.RegisteredClaims
    {{ "}" }}

    func JWTAuth(cfg conf.TokenConfig) app.HandlerFunc {{ "{" }}
    	return func(ctx context.Context, c *app.RequestContext) {{ "{" }}
    		if !cfg.Enabled {{ "{" }}
    			c.Next(ctx)
    			return
    		{{ "}" }}
    		header := cfg.Header
    		if header == "" {{ "{" }}
    			header = "Authorization"
    		{{ "}" }}
    		raw := strings.TrimSpace(c.Request.Header.Get(header))
    		if strings.HasPrefix(strings.ToLower(raw), "bearer ") {{ "{" }}
    			raw = strings.TrimSpace(raw[7:])
    		{{ "}" }}
    		if raw == "" {{ "{" }}
    			response.ErrorCode(c, response.CodeTokenMissing)
    			c.Abort()
    			return
    		{{ "}" }}
    		claims, err := verifyToken(cfg, raw)
    		if err != nil {{ "{" }}
    			code, _ := response.CodeMsg(err)
    			response.ErrorCode(c, code)
    			c.Abort()
    			return
    		{{ "}" }}
    		c.Set(ContextKeyTokenClaims, claims)
    		c.Next(ctx)
    	{{ "}" }}
    {{ "}" }}

    func verifyToken(cfg conf.TokenConfig, tokenString string) (*Claims, error) {{ "{" }}
    	if cfg.SigningKey == "" {{ "{" }}
    		return nil, goerror.In("token").Code(response.CodeConfigInvalid).Public(response.MsgFromCode(response.CodeConfigInvalid)).New("token signing key is empty")
    	{{ "}" }}
    	claims := &Claims{{ "{" }}{{ "}" }}
    	options := make([]jwt.ParserOption, 0, 1)
    	if cfg.Issuer != "" {{ "{" }}
    		options = append(options, jwt.WithIssuer(cfg.Issuer))
    	{{ "}" }}
    	token, err := jwt.ParseWithClaims(tokenString, claims, func(token *jwt.Token) (any, error) {{ "{" }}
    		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {{ "{" }}
    			return nil, goerror.In("token").Code(response.CodeTokenInvalid).Public(response.MsgFromCode(response.CodeTokenInvalid)).New("invalid token signing method")
    		{{ "}" }}
    		return []byte(cfg.SigningKey), nil
    	{{ "}" }}, options...)
    	if err != nil {{ "{" }}
    		if errors.Is(err, jwt.ErrTokenExpired) {{ "{" }}
    			return nil, goerror.In("token").Code(response.CodeTokenExpired).Public(response.MsgFromCode(response.CodeTokenExpired)).Wrap(err)
    		{{ "}" }}
    		if errors.Is(err, jwt.ErrTokenInvalidClaims) || errors.Is(err, jwt.ErrTokenNotValidYet) {{ "{" }}
    			return nil, goerror.In("token").Code(response.CodeClaimsInvalid).Public(response.MsgFromCode(response.CodeClaimsInvalid)).Wrap(err)
    		{{ "}" }}
    		return nil, goerror.In("token").Code(response.CodeTokenInvalid).Public(response.MsgFromCode(response.CodeTokenInvalid)).Wrap(err)
    	{{ "}" }}
    	if token == nil || !token.Valid {{ "{" }}
    		return nil, goerror.In("token").Code(response.CodeTokenInvalid).Public(response.MsgFromCode(response.CodeTokenInvalid)).New("token is invalid")
    	{{ "}" }}
    	if claims.Uid == "" {{ "{" }}
    		return nil, goerror.In("token").Code(response.CodeClaimsInvalid).Public(response.MsgFromCode(response.CodeClaimsInvalid)).New("token claims missing uid")
    	{{ "}" }}
    	return claims, nil
    {{ "}" }}

    func GetClaims(c *app.RequestContext) (*Claims, bool) {{ "{" }}
    	value, ok := c.Get(ContextKeyTokenClaims)
    	if !ok {{ "{" }}
    		return nil, false
    	{{ "}" }}
    	claims, ok := value.(*Claims)
    	return claims, ok
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/middleware/... -run JWTAuth -v`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_pkg_middleware_token_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_token_test_go.yaml
git commit -m "feat(user-bff-hertz): add JWT middleware with Claims matching user-kitex's actual uid claim"
```

---

### Task 4: CORS middleware (verbatim reuse) + one-time OAuth code→JWT exchange store

**Files:**
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_cors_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_cors_test_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_oauthcode_store_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_oauthcode_store_test_go.yaml`

**Interfaces:**
- Consumes: `conf.CORSConfig` (Task 2, copied verbatim from `admin-bff-hertz`'s shape), `conf.OAuthCodeConfig` (Task 2).
- Produces: `middleware.CORS(cfg conf.CORSConfig) app.HandlerFunc`; `oauthcode.Store` interface (`Put(ctx, jwt string, ttl time.Duration) (code string, err error)`, `Consume(ctx, code string) (jwt string, ok bool, err error)`) + `oauthcode.NewRedisStore(client *redis.Client) *RedisStore` — consumed by Task 6 (OAuth handlers).

- [ ] **Step 1: Copy CORS middleware + test verbatim**

```bash
cp admin-bff-hertz/hertz-template/internal_pkg_middleware_cors_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_middleware_cors_go.yaml
cp admin-bff-hertz/hertz-template/internal_pkg_middleware_cors_test_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_middleware_cors_test_go.yaml
```

This is a deliberate byte-for-byte copy — CORS handling has no admin-specific content, and the `conf.CORSConfig` shape is identical (copied structurally in Task 2 Step 1).

- [ ] **Step 2: Run the copied test to confirm it still passes unmodified**

Run: `go test ./internal/pkg/middleware/... -run CORS -v`. Expected: PASS (identical to `admin-bff-hertz`'s own passing test).

- [ ] **Step 3: Write the failing test for the OAuth code store**

```yaml
# ncgo exported template — internal/pkg/oauthcode/store_test.go
path: internal/pkg/oauthcode/store_test.go
update_behavior:
    type: cover
body: |-
    package oauthcode

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/alicebob/miniredis/v2"
    	"github.com/redis/go-redis/v9"
    )

    func newTestRedis(t *testing.T) *redis.Client {{ "{" }}
    	t.Helper()
    	mr, err := miniredis.Run()
    	if err != nil {{ "{" }}
    		t.Fatalf("start miniredis: %v", err)
    	{{ "}" }}
    	t.Cleanup(mr.Close)
    	return redis.NewClient(&redis.Options{{ "{" }}Addr: mr.Addr(){{ "}" }})
    {{ "}" }}

    func TestRedisStore_PutConsume(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := NewRedisStore(newTestRedis(t))

    	code, err := store.Put(ctx, "signed-jwt-value", time.Minute)
    	if err != nil {{ "{" }}
    		t.Fatalf("put: %v", err)
    	{{ "}" }}
    	if code == "" {{ "{" }}
    		t.Fatal("expected a non-empty code")
    	{{ "}" }}

    	jwt, ok, err := store.Consume(ctx, code)
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if !ok || jwt != "signed-jwt-value" {{ "{" }}
    		t.Fatalf("expected to consume the jwt, got ok=%v jwt=%q", ok, jwt)
    	{{ "}" }}

    	_, ok, err = store.Consume(ctx, code)
    	if err != nil {{ "{" }}
    		t.Fatalf("consume again: %v", err)
    	{{ "}" }}
    	if ok {{ "{" }}
    		t.Fatal("expected code to be gone after first consume (single use)")
    	{{ "}" }}
    {{ "}" }}

    func TestRedisStore_UnknownCode(t *testing.T) {{ "{" }}
    	store := NewRedisStore(newTestRedis(t))
    	_, ok, err := store.Consume(context.Background(), "never-issued")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if ok {{ "{" }}
    		t.Fatal("expected unknown code to report not-found")
    	{{ "}" }}
    {{ "}" }}

    func TestRedisStore_DistinctCodesPerCall(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := NewRedisStore(newTestRedis(t))
    	code1, err := store.Put(ctx, "jwt-1", time.Minute)
    	if err != nil {{ "{" }}
    		t.Fatalf("put 1: %v", err)
    	{{ "}" }}
    	code2, err := store.Put(ctx, "jwt-2", time.Minute)
    	if err != nil {{ "{" }}
    		t.Fatalf("put 2: %v", err)
    	{{ "}" }}
    	if code1 == code2 {{ "{" }}
    		t.Fatal("expected distinct codes for distinct Put calls")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `go test ./internal/pkg/oauthcode/... -v`. Expected: FAIL — `undefined: NewRedisStore`.

- [ ] **Step 5: Write the OAuth code store**

```yaml
# ncgo exported template — internal/pkg/oauthcode/store.go
path: internal/pkg/oauthcode/store.go
update_behavior:
    type: cover
body: |-
    package oauthcode

    import (
    	"context"
    	"errors"
    	"time"

    	"github.com/google/uuid"
    	"github.com/redis/go-redis/v9"
    )

    // Store issues one-time codes that redeem a previously-issued JWT
    // exactly once. Used to hand a JWT to the frontend after a browser
    // OAuth redirect completes, without putting the JWT itself in a URL
    // (URLs end up in browser history, Referrer headers, and server access
    // logs). Independent of user-kitex's own OAuth CSRF StateStore — this
    // store's codes flow BFF -> frontend, not BFF -> third-party provider.
    type Store interface {{ "{" }}
    	// Put stores jwt under a freshly generated code, valid for ttl, and
    	// returns the code.
    	Put(ctx context.Context, jwt string, ttl time.Duration) (code string, err error)
    	// Consume reports whether code was valid and, if so, deletes it so
    	// it cannot be redeemed twice, returning the jwt it was issued for.
    	Consume(ctx context.Context, code string) (jwt string, ok bool, err error)
    {{ "}" }}

    const codeKeyPrefix = "oauthcode:"

    // RedisStore stores one-time codes in Redis with a TTL and atomically
    // deletes them on first consumption (GETDEL).
    type RedisStore struct {{ "{" }}
    	client *redis.Client
    {{ "}" }}

    // NewRedisStore wraps an existing Redis client.
    func NewRedisStore(client *redis.Client) *RedisStore {{ "{" }}
    	return &RedisStore{{ "{" }}client: client{{ "}" }}
    {{ "}" }}

    // Put generates a fresh code, stores jwt under it for ttl, and returns
    // the code.
    func (s *RedisStore) Put(ctx context.Context, jwt string, ttl time.Duration) (string, error) {{ "{" }}
    	code := uuid.NewString()
    	if err := s.client.Set(ctx, codeKeyPrefix+code, jwt, ttl).Err(); err != nil {{ "{" }}
    		return "", err
    	{{ "}" }}
    	return code, nil
    {{ "}" }}

    // Consume reports whether code was valid and, if so, deletes it so it
    // cannot be redeemed twice, returning the jwt it was issued for.
    func (s *RedisStore) Consume(ctx context.Context, code string) (string, bool, error) {{ "{" }}
    	jwt, err := s.client.GetDel(ctx, codeKeyPrefix+code).Result()
    	if errors.Is(err, redis.Nil) {{ "{" }}
    		return "", false, nil
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return "", false, err
    	{{ "}" }}
    	return jwt, true, nil
    {{ "}" }}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `go test ./internal/pkg/oauthcode/... -v`. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_pkg_middleware_cors_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_cors_test_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_oauthcode_store_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_oauthcode_store_test_go.yaml
git commit -m "feat(user-bff-hertz): reuse CORS middleware, add one-time OAuth code->JWT exchange store"
```

---

### Task 5: Idempotency middleware (adapted to `Claims{Uid}`) + rate-limit middleware/resolver (reused from `admin-bff-hertz`)

**Files:**
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_pkg_middleware_skip_go.yaml`

**Interfaces:**
- Consumes: `middleware.Claims{Uid}`/`GetClaims` (Task 3, NOT `admin-bff-hertz`'s `{UUID, AK}` shape), `conf.IdempotencyConfig`/`conf.RateLimitConfig` (Task 2).
- Produces: `middleware.Idempotency(cfg conf.IdempotencyConfig) app.HandlerFunc`, `middleware.RateLimit(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, resolver *ratelimit.Resolver) app.HandlerFunc` — consumed by Task 8 (router wiring).

- [ ] **Step 1: Copy the rate-limit resolver, store, redis-client helper, and skip-path helper verbatim**

```bash
cp admin-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml
cp admin-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml
cp admin-bff-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml
cp admin-bff-hertz/hertz-template/internal_pkg_middleware_skip_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_middleware_skip_go.yaml
```

These four files are pure infrastructure (Redis client sharing, path-skip matching, the rule-center resolver's `Lookup`/`ResolvedRule`/`GRPCClient` types, the rate-limit token-bucket store) with zero admin-specific content — safe to copy verbatim, matching how Task 3/4 of the `user-kitex` plan reused `rbac-kitex` files unmodified.

- [ ] **Step 2: Copy `rate_limit.go` verbatim (it takes `Lookup{{ "{" }}...{{ "}" }}` by value, no `Claims`-shaped dependency)**

```bash
cp admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml
cp admin-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml \
   user-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml
```

Before committing, grep the copied `rate_limit.go`'s body for any reference to `claims.UUID`/`claims.AK`/`GetClaims` (the resolver `Lookup` construction may key off the authenticated user for per-user limits) — if present, adapt exactly as Step 3 below does for idempotency: replace `claims.UUID` with `claims.Uid`, drop any `claims.AK` branch (this package has no API-key auth concept). If absent (the copied file only builds `Lookup` from `Service`/`Phase`/`Method`/`Path`/`ClientIP` with no per-user field), no adaptation is needed — this is plausible since `rate_limit.go`'s job here is IP-based login/register brute-force protection, which doesn't require identifying an already-authenticated user (the endpoints being protected are pre-auth by definition). Verify by reading the copied file's actual content before deciding.

- [ ] **Step 3: Write the idempotency middleware, adapted to `Claims{Uid}`**

Copy `admin-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml`'s full body, then apply exactly one change to `idempotencyKey`: replace the `AK`/`UUID`-branching switch with a single `Uid`-based check (since this package's `Claims` has no `AK` field):

```yaml
# ncgo exported template — internal/pkg/middleware/idempotency.go
path: internal/pkg/middleware/idempotency.go
update_behavior:
    type: cover
body: |
    # ... (identical to admin-bff-hertz's file for every function EXCEPT idempotencyKey below — copy the rest verbatim: idempotencyRecord, idempotencyStore interface, memoryIdempotencyStore, redisIdempotencyStore, Idempotency(), newIdempotencyStore(), newMemoryIdempotencyStore(), replayIdempotencyResponse(), idempotencyFingerprint(), idempotencyMethods(), idempotencyCacheableStatus(), cloneIdempotencyRecord(), normalizeIdempotencyConfig())

    func idempotencyKey(c *app.RequestContext, cfg conf.IdempotencyConfig, requestKey string) string {{ "{" }}
    	scope := "ip:" + requestIP(c)
    	if claims, ok := GetClaims(c); ok && claims.Uid != "" {{ "{" }}
    		scope = "user_uid:" + claims.Uid
    	{{ "}" }} else if ak := strings.TrimSpace(c.Request.Header.Get(cfg.AppKeyHeader)); ak != "" {{ "{" }}
    		scope = "ak:" + ak
    	{{ "}" }}
    	return joinRateLimitKey(cfg.KeyPrefix, scope, string(c.Method()), string(c.Path()), requestKey)
    {{ "}" }}
```

Since `POST /auth/register` (the only route this middleware is mounted on, per the design) runs BEFORE the JWT middleware (it's a public/pre-auth endpoint), `GetClaims(c)` will always return `ok=false` there in practice, and the scope will always be `ip:...` — this is correct and expected; the `Uid` branch exists for completeness/future routes, not because `register` needs it today. Copy the test file structurally from `admin-bff-hertz`'s equivalent, adjusting any `claims.UUID`/`claims.AK` references in test setup to `claims.Uid`.

- [ ] **Step 4: Run tests to verify everything passes**

Run: `go test ./internal/pkg/middleware/... -v` and `go test ./internal/pkg/ratelimit/... -v`. Expected: PASS for all copied/adapted tests.

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_idempotency_test_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_ratelimit_store_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_redis_client_go.yaml \
        user-bff-hertz/hertz-template/internal_pkg_middleware_skip_go.yaml
git commit -m "feat(user-bff-hertz): add idempotency (Claims{Uid}-adapted) and rule-center-backed rate-limit middleware"
```

---

### Task 6: Local register/login handlers

**Files:**
- Create: `user-bff-hertz/hertz-template/internal_handler_auth_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_handler_auth_test_go.yaml`

**Interfaces:**
- Consumes: `userservice.Client` (from `user-kitex`'s `pkg/client/userservice`, wired in Task 8), `userv1.RegisterReq/RegisterResp/LoginReq/LoginResp` (from `user-kitex`'s generated `kitex_gen`), `response.OK`/`response.Err`/`response.ErrorCode` (Task 2).
- Produces: `handler.AuthHandler{{ "{" }}...{{ "}" }}`, `handler.NewAuthHandler(userCli userservice.Client) *AuthHandler`, `(*AuthHandler).Register`, `(*AuthHandler).Login` (both `func(ctx context.Context, c *app.RequestContext)`) — consumed by Task 9 (router).

- [ ] **Step 1: Write the failing test**

```yaml
# ncgo exported template — internal/handler/auth_test.go
path: internal/handler/auth_test.go
update_behavior:
    type: skip
loop_service: true
body: |
    package handler

    import (
    	"context"
    	"net/http/httptest"
    	"testing"

    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/cloudwego/hertz/pkg/protocol"

    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    )

    type fakeUserClient struct {{ "{" }}
    	userv1client
    	registerFn func(ctx context.Context, req *userv1.RegisterReq) (*userv1.RegisterResp, error)
    	loginFn    func(ctx context.Context, req *userv1.LoginReq) (*userv1.LoginResp, error)
    {{ "}" }}

    func (f *fakeUserClient) Register(ctx context.Context, req *userv1.RegisterReq) (*userv1.RegisterResp, error) {{ "{" }}
    	return f.registerFn(ctx, req)
    {{ "}" }}
    func (f *fakeUserClient) Login(ctx context.Context, req *userv1.LoginReq) (*userv1.LoginResp, error) {{ "{" }}
    	return f.loginFn(ctx, req)
    {{ "}" }}

    func newTestContext(method, path, body string) *app.RequestContext {{ "{" }}
    	ctx := app.NewContext(0)
    	req := protocol.NewRequest(method, path, nil)
    	req.SetBody([]byte(body))
    	ctx.Init(req, httptest.NewRecorder().Result().Header, nil)
    	return ctx
    {{ "}" }}

    func TestAuthHandler_Register_Success(t *testing.T) {{ "{" }}
    	cli := &fakeUserClient{{ "{" }}registerFn: func(ctx context.Context, req *userv1.RegisterReq) (*userv1.RegisterResp, error) {{ "{" }}
    		if req.Username != "alice" || req.Password != "hunter22" {{ "{" }}
    			t.Fatalf("unexpected request: %+v", req)
    		{{ "}" }}
    		return &userv1.RegisterResp{{ "{" }}Uid: "uid-1"{{ "}" }}, nil
    	{{ "}" }}{{ "}" }}
    	h := NewAuthHandler(cli)
    	c := newTestContext("POST", "/auth/register", `{{ "{" }}"username":"alice","password":"hunter22"{{ "}" }}`)
    	h.Register(context.Background(), c)
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("expected 200, got %d: %s", c.Response.StatusCode(), c.Response.Body())
    	{{ "}" }}
    {{ "}" }}

    func TestAuthHandler_Login_Success(t *testing.T) {{ "{" }}
    	cli := &fakeUserClient{{ "{" }}loginFn: func(ctx context.Context, req *userv1.LoginReq) (*userv1.LoginResp, error) {{ "{" }}
    		return &userv1.LoginResp{{ "{" }}Uid: "uid-1", Token: "jwt-token"{{ "}" }}, nil
    	{{ "}" }}{{ "}" }}
    	h := NewAuthHandler(cli)
    	c := newTestContext("POST", "/auth/login", `{{ "{" }}"username":"alice","password":"hunter22"{{ "}" }}`)
    	h.Login(context.Background(), c)
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("expected 200, got %d: %s", c.Response.StatusCode(), c.Response.Body())
    	{{ "}" }}
    {{ "}" }}

    func TestAuthHandler_Register_InvalidJSON(t *testing.T) {{ "{" }}
    	h := NewAuthHandler(&fakeUserClient{{ "{" }}{{ "}" }})
    	c := newTestContext("POST", "/auth/register", `not-json`)
    	h.Register(context.Background(), c)
    	if c.Response.StatusCode() == 200 {{ "{" }}
    		t.Fatal("expected non-200 for invalid JSON body")
    	{{ "}" }}
    {{ "}" }}
```

Note: the `fakeUserClient` above embeds `userv1client` as a placeholder name standing in for whatever the generated `userservice.Client` interface is actually named/aliased as in the rendered `kitex_gen` output — **before rendering this test for real, replace that embed with the actual generated interface type** (check `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`'s import alias, `userv1 "{{.Module}}/kitex_gen/api/user/v1"`, and the client package `userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"` — the fake must embed `userservice.Client` to satisfy the full interface via embedding while only overriding the two methods under test, matching the standard Go "partial fake via interface embedding" pattern).

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/handler/... -run AuthHandler -v` (rendered scratch project, after Task 9's router/wiring exists enough for `kitex_gen` to be present — if `kitex_gen` isn't generated yet at this point in task ordering, render with `user-kitex`'s proto present as a dependency reference; since `user-bff-hertz` imports `user-kitex`'s generated Kitex types, the rendered scratch project needs BOTH templates' generation steps — coordinate with whoever renders this task by rendering `user-kitex` into a `pkg/client`-consumable location first, or note in your report if the ncgo tooling doesn't support cross-template generation in one render and describe what you did instead). Expected: FAIL — `undefined: NewAuthHandler`.

- [ ] **Step 3: Write the handler**

```yaml
# ncgo exported template — internal/handler/auth.go
path: internal/handler/auth.go
update_behavior:
    type: skip
loop_service: true
body: |
    package handler

    import (
    	"context"
    	"encoding/json"

    	"github.com/cloudwego/hertz/pkg/app"

    	"{{.Module}}/internal/pkg/response"
    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )

    type AuthHandler struct {{ "{" }}
    	userCli userservice.Client
    {{ "}" }}

    func NewAuthHandler(userCli userservice.Client) *AuthHandler {{ "{" }}
    	return &AuthHandler{{ "{" }}userCli: userCli{{ "}" }}
    {{ "}" }}

    type registerReq struct {{ "{" }}
    	Username string `json:"username"`
    	Password string `json:"password"`
    {{ "}" }}

    func (h *AuthHandler) Register(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req registerReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	resp, err := h.userCli.Register(ctx, &userv1.RegisterReq{{ "{" }}Username: req.Username, Password: req.Password{{ "}" }})
    	if err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"uid": resp.Uid{{ "}" }})
    {{ "}" }}

    type loginReq struct {{ "{" }}
    	Username string `json:"username"`
    	Password string `json:"password"`
    {{ "}" }}

    func (h *AuthHandler) Login(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req loginReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	resp, err := h.userCli.Login(ctx, &userv1.LoginReq{{ "{" }}Username: req.Username, Password: req.Password{{ "}" }})
    	if err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"uid": resp.Uid, "token": resp.Token{{ "}" }})
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/handler/... -run AuthHandler -v`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_auth_go.yaml \
        user-bff-hertz/hertz-template/internal_handler_auth_test_go.yaml
git commit -m "feat(user-bff-hertz): add register/login handlers"
```

---

### Task 7: OAuth login handlers — start / callback / exchange

**Files:**
- Create: `user-bff-hertz/hertz-template/internal_handler_oauth_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_handler_oauth_test_go.yaml`

**Interfaces:**
- Consumes: `userservice.Client` (`user-kitex`), `oauthcode.Store` (Task 4), `conf.OAuthRedirectConfig`/`conf.OAuthCodeConfig` (Task 2), `middleware.GetClaims` (Task 3, used by bind-start in Task 8 — NOT this task, login-flow handlers here are pre-auth).
- Produces: `handler.OAuthHandler{{ "{" }}...{{ "}" }}`, `handler.NewOAuthHandler(userCli userservice.Client, codeStore oauthcode.Store, redirectCfg conf.OAuthRedirectConfig, codeTTL time.Duration) *OAuthHandler`, `(*OAuthHandler).Start`, `(*OAuthHandler).Callback`, `(*OAuthHandler).Exchange` — consumed by Task 9 (router). Bind-flow handlers (`BindStart`/`BindCallback`/`Unbind`) are added to this same handler type in Task 8, since they share the constructor and fields.

- [ ] **Step 1: Write the failing test**

```yaml
# ncgo exported template — internal/handler/oauth_test.go
path: internal/handler/oauth_test.go
update_behavior:
    type: skip
loop_service: true
body: |
    package handler

    import (
    	"context"
    	"net/http/httptest"
    	"testing"
    	"time"

    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/cloudwego/hertz/pkg/protocol"
    	"github.com/cloudwego/hertz/pkg/protocol/consts"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/pkg/oauthcode"
    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )

    type fakeOAuthUserClient struct {{ "{" }}
    	userservice.Client
    	oauthStartFn    func(ctx context.Context, req *userv1.OAuthStartReq) (*userv1.OAuthStartResp, error)
    	oauthCallbackFn func(ctx context.Context, req *userv1.OAuthCallbackReq) (*userv1.OAuthCallbackResp, error)
    {{ "}" }}

    func (f *fakeOAuthUserClient) OAuthStart(ctx context.Context, req *userv1.OAuthStartReq) (*userv1.OAuthStartResp, error) {{ "{" }}
    	return f.oauthStartFn(ctx, req)
    {{ "}" }}
    func (f *fakeOAuthUserClient) OAuthCallback(ctx context.Context, req *userv1.OAuthCallbackReq) (*userv1.OAuthCallbackResp, error) {{ "{" }}
    	return f.oauthCallbackFn(ctx, req)
    {{ "}" }}

    type fakeCodeStore struct {{ "{" }}
    	putFn func(ctx context.Context, jwt string, ttl time.Duration) (string, error)
    {{ "}" }}

    func (f *fakeCodeStore) Put(ctx context.Context, jwt string, ttl time.Duration) (string, error) {{ "{" }}
    	return f.putFn(ctx, jwt, ttl)
    {{ "}" }}
    func (f *fakeCodeStore) Consume(ctx context.Context, code string) (string, bool, error) {{ "{" }}
    	if code == "valid-code" {{ "{" }}
    		return "jwt-from-code", true, nil
    	{{ "}" }}
    	return "", false, nil
    {{ "}" }}

    func newOAuthTestContext(method, path string, params map[string]string) *app.RequestContext {{ "{" }}
    	ctx := app.NewContext(0)
    	req := protocol.NewRequest(method, path, nil)
    	ctx.Init(req, httptest.NewRecorder().Result().Header, nil)
    	for k, v := range params {{ "{" }}
    		ctx.Params = append(ctx.Params, param{{ "{" }}Key: k, Value: v{{ "}" }})
    	{{ "}" }}
    	return ctx
    {{ "}" }}

    type param = struct {{ "{" }}
    	Key   string
    	Value string
    {{ "}" }}

    func TestOAuthHandler_Start_Redirects(t *testing.T) {{ "{" }}
    	cli := &fakeOAuthUserClient{{ "{" }}oauthStartFn: func(ctx context.Context, req *userv1.OAuthStartReq) (*userv1.OAuthStartResp, error) {{ "{" }}
    		if req.Provider != "github" || req.Purpose != "login" || req.Uid != "" {{ "{" }}
    			t.Fatalf("unexpected request: %+v", req)
    		{{ "}" }}
    		return &userv1.OAuthStartResp{{ "{" }}RedirectUrl: "https://github.com/authorize?..."{{ "}" }}, nil
    	{{ "}" }}{{ "}" }}
    	h := NewOAuthHandler(cli, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}SuccessURL: "http://localhost:3000/callback"{{ "}" }}, time.Minute)
    	c := app.NewContext(0)
    	req := protocol.NewRequest("GET", "/auth/oauth/github/start", nil)
    	c.Init(req, httptest.NewRecorder().Result().Header, nil)
    	c.Params = append(c.Params, param{{ "{" }}Key: "provider", Value: "github"{{ "}" }})
    	h.Start(context.Background(), c)
    	if c.Response.StatusCode() != consts.StatusFound {{ "{" }}
    		t.Fatalf("expected 302, got %d", c.Response.StatusCode())
    	{{ "}" }}
    	loc := string(c.Response.Header.Get("Location"))
    	if loc != "https://github.com/authorize?..." {{ "{" }}
    		t.Fatalf("unexpected redirect location: %s", loc)
    	{{ "}" }}
    {{ "}" }}

    func TestOAuthHandler_Callback_RedirectsWithCode(t *testing.T) {{ "{" }}
    	cli := &fakeOAuthUserClient{{ "{" }}oauthCallbackFn: func(ctx context.Context, req *userv1.OAuthCallbackReq) (*userv1.OAuthCallbackResp, error) {{ "{" }}
    		return &userv1.OAuthCallbackResp{{ "{" }}Uid: "uid-1", Token: "signed-jwt"{{ "}" }}, nil
    	{{ "}" }}{{ "}" }}
    	putCalled := false
    	codeStore := &fakeCodeStore{{ "{" }}putFn: func(ctx context.Context, jwt string, ttl time.Duration) (string, error) {{ "{" }}
    		putCalled = true
    		if jwt != "signed-jwt" {{ "{" }}
    			t.Fatalf("expected the callback's jwt to be stored, got %q", jwt)
    		{{ "}" }}
    		return "one-time-code", nil
    	{{ "}" }}{{ "}" }}
    	h := NewOAuthHandler(cli, codeStore, conf.OAuthRedirectConfig{{ "{" }}SuccessURL: "http://localhost:3000/callback"{{ "}" }}, time.Minute)
    	c := app.NewContext(0)
    	req := protocol.NewRequest("GET", "/auth/oauth/github/callback?state=s1&code=c1", nil)
    	c.Init(req, httptest.NewRecorder().Result().Header, nil)
    	c.Params = append(c.Params, param{{ "{" }}Key: "provider", Value: "github"{{ "}" }})
    	h.Callback(context.Background(), c)
    	if !putCalled {{ "{" }}
    		t.Fatal("expected the code store to be used")
    	{{ "}" }}
    	if c.Response.StatusCode() != consts.StatusFound {{ "{" }}
    		t.Fatalf("expected 302, got %d", c.Response.StatusCode())
    	{{ "}" }}
    	loc := string(c.Response.Header.Get("Location"))
    	if loc != "http://localhost:3000/callback?code=one-time-code" {{ "{" }}
    		t.Fatalf("unexpected redirect location: %s", loc)
    	{{ "}" }}
    {{ "}" }}

    func TestOAuthHandler_Exchange_ConsumesCode(t *testing.T) {{ "{" }}
    	h := NewOAuthHandler(&fakeOAuthUserClient{{ "{" }}{{ "}" }}, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}{{ "}" }}, time.Minute)
    	c := app.NewContext(0)
    	req := protocol.NewRequest("POST", "/auth/oauth/exchange", nil)
    	req.SetBody([]byte(`{{ "{" }}"code":"valid-code"{{ "}" }}`))
    	c.Init(req, httptest.NewRecorder().Result().Header, nil)
    	h.Exchange(context.Background(), c)
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("expected 200, got %d: %s", c.Response.StatusCode(), c.Response.Body())
    	{{ "}" }}
    {{ "}" }}

    func TestOAuthHandler_Exchange_InvalidCode_Returns401(t *testing.T) {{ "{" }}
    	h := NewOAuthHandler(&fakeOAuthUserClient{{ "{" }}{{ "}" }}, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}{{ "}" }}, time.Minute)
    	c := app.NewContext(0)
    	req := protocol.NewRequest("POST", "/auth/oauth/exchange", nil)
    	req.SetBody([]byte(`{{ "{" }}"code":"never-issued"{{ "}" }}`))
    	c.Init(req, httptest.NewRecorder().Result().Header, nil)
    	h.Exchange(context.Background(), c)
    	if c.Response.StatusCode() != consts.StatusUnauthorized {{ "{" }}
    		t.Fatalf("expected 401, got %d", c.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/handler/... -run OAuthHandler -v`. Expected: FAIL — `undefined: NewOAuthHandler`.

- [ ] **Step 3: Write the OAuth handler (start/callback/exchange only — bind-flow methods added in Task 8)**

```yaml
# ncgo exported template — internal/handler/oauth.go
path: internal/handler/oauth.go
update_behavior:
    type: skip
loop_service: true
body: |
    package handler

    import (
    	"context"
    	"encoding/json"
    	"time"

    	"github.com/cloudwego/hertz/pkg/app"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/pkg/oauthcode"
    	"{{.Module}}/internal/pkg/response"
    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )

    type OAuthHandler struct {{ "{" }}
    	userCli     userservice.Client
    	codeStore   oauthcode.Store
    	redirectCfg conf.OAuthRedirectConfig
    	codeTTL     time.Duration
    {{ "}" }}

    func NewOAuthHandler(userCli userservice.Client, codeStore oauthcode.Store, redirectCfg conf.OAuthRedirectConfig, codeTTL time.Duration) *OAuthHandler {{ "{" }}
    	return &OAuthHandler{{ "{" }}userCli: userCli, codeStore: codeStore, redirectCfg: redirectCfg, codeTTL: codeTTL{{ "}" }}
    {{ "}" }}

    // Start begins a login-flow OAuth redirect: GET /auth/oauth/:provider/start
    func (h *OAuthHandler) Start(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	provider := c.Param("provider")
    	resp, err := h.userCli.OAuthStart(ctx, &userv1.OAuthStartReq{{ "{" }}Provider: provider, Purpose: "login"{{ "}" }})
    	if err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	c.Redirect(302, []byte(resp.RedirectUrl))
    {{ "}" }}

    // Callback completes a login-flow OAuth redirect: GET /auth/oauth/:provider/callback
    func (h *OAuthHandler) Callback(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	provider := c.Param("provider")
    	state := string(c.Query("state"))
    	code := string(c.Query("code"))
    	resp, err := h.userCli.OAuthCallback(ctx, &userv1.OAuthCallbackReq{{ "{" }}Provider: provider, State: state, Code: code{{ "}" }})
    	if err != nil {{ "{" }}
    		c.Redirect(302, []byte(h.redirectCfg.ErrorURL))
    		return
    	{{ "}" }}
    	oneTimeCode, err := h.codeStore.Put(ctx, resp.Token, h.codeTTL)
    	if err != nil {{ "{" }}
    		c.Redirect(302, []byte(h.redirectCfg.ErrorURL))
    		return
    	{{ "}" }}
    	c.Redirect(302, []byte(h.redirectCfg.SuccessURL+"?code="+oneTimeCode))
    {{ "}" }}

    type exchangeReq struct {{ "{" }}
    	Code string `json:"code"`
    {{ "}" }}

    // Exchange redeems a one-time code for the JWT it was issued for:
    // POST /auth/oauth/exchange
    func (h *OAuthHandler) Exchange(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	var req exchangeReq
    	if err := json.Unmarshal(c.Request.Body(), &req); err != nil || req.Code == "" {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}
    	jwt, ok, err := h.codeStore.Consume(ctx, req.Code)
    	if err != nil {{ "{" }}
    		response.Err(c, err)
    		return
    	{{ "}" }}
    	if !ok {{ "{" }}
    		response.ErrorCode(c, response.CodeTokenInvalid)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"token": jwt{{ "}" }})
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/handler/... -run OAuthHandler -v`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_oauth_go.yaml \
        user-bff-hertz/hertz-template/internal_handler_oauth_test_go.yaml
git commit -m "feat(user-bff-hertz): add OAuth login start/callback/exchange handlers"
```

---

### Task 8: Bind/unbind handlers (JWT-authenticated) — extends `OAuthHandler`

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_handler_oauth_go.yaml`
- Modify: `user-bff-hertz/hertz-template/internal_handler_oauth_test_go.yaml`

**Interfaces:**
- Consumes: `middleware.GetClaims` (Task 3, for the authenticated `uid`), `userv1.OAuthStartReq.Uid`/`BindProviderReq` (Task 1's extended shape), `userservice.Client.BindProvider`/`.UnbindProvider`.
- Produces: `(*OAuthHandler).BindStart`, `(*OAuthHandler).BindCallback`, `(*OAuthHandler).Unbind` — consumed by Task 9 (router), mounted behind JWT middleware.

- [ ] **Step 1: Write the failing tests (append to the existing test file)**

Append to `user-bff-hertz/hertz-template/internal_handler_oauth_test_go.yaml`'s body (add these functions; also extend `fakeOAuthUserClient` with `bindProviderFn`/`unbindProviderFn` fields and matching methods, and add a helper to inject `middleware.Claims` into a test context):

```go
func (f *fakeOAuthUserClient) BindProvider(ctx context.Context, req *userv1.BindProviderReq) (*userv1.BindProviderResp, error) {{ "{" }}
	return f.bindProviderFn(ctx, req)
{{ "}" }}
func (f *fakeOAuthUserClient) UnbindProvider(ctx context.Context, req *userv1.UnbindProviderReq) (*userv1.UnbindProviderResp, error) {{ "{" }}
	return f.unbindProviderFn(ctx, req)
{{ "}" }}

func newAuthenticatedOAuthTestContext(method, path, uid string, params map[string]string) *app.RequestContext {{ "{" }}
	c := newOAuthTestContext(method, path, params)
	c.Set(middleware.ContextKeyTokenClaims, &middleware.Claims{{ "{" }}Uid: uid{{ "}" }})
	return c
{{ "}" }}

func TestOAuthHandler_BindStart_UsesAuthenticatedUid(t *testing.T) {{ "{" }}
	cli := &fakeOAuthUserClient{{ "{" }}oauthStartFn: func(ctx context.Context, req *userv1.OAuthStartReq) (*userv1.OAuthStartResp, error) {{ "{" }}
		if req.Provider != "wechat" || req.Purpose != "bind" || req.Uid != "uid-authenticated" {{ "{" }}
			t.Fatalf("unexpected request: %+v", req)
		{{ "}" }}
		return &userv1.OAuthStartResp{{ "{" }}RedirectUrl: "https://wechat.example/authorize"{{ "}" }}, nil
	{{ "}" }}{{ "}" }}
	h := NewOAuthHandler(cli, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}BindSuccessURL: "http://localhost:3000/settings"{{ "}" }}, time.Minute)
	c := newAuthenticatedOAuthTestContext("GET", "/auth/oauth/wechat/bind-start", "uid-authenticated", map[string]string{{ "{" }}"provider": "wechat"{{ "}" }})
	h.BindStart(context.Background(), c)
	if c.Response.StatusCode() != consts.StatusFound {{ "{" }}
		t.Fatalf("expected 302, got %d", c.Response.StatusCode())
	{{ "}" }}
{{ "}" }}

func TestOAuthHandler_BindCallback_RedirectsToBindSuccessURL(t *testing.T) {{ "{" }}
	cli := &fakeOAuthUserClient{{ "{" }}bindProviderFn: func(ctx context.Context, req *userv1.BindProviderReq) (*userv1.BindProviderResp, error) {{ "{" }}
		return &userv1.BindProviderResp{{ "{" }}{{ "}" }}, nil
	{{ "}" }}{{ "}" }}
	h := NewOAuthHandler(cli, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}BindSuccessURL: "http://localhost:3000/settings"{{ "}" }}, time.Minute)
	c := newOAuthTestContext("GET", "/auth/oauth/wechat/bind-callback?state=s1&code=c1", map[string]string{{ "{" }}"provider": "wechat"{{ "}" }})
	h.BindCallback(context.Background(), c)
	if c.Response.StatusCode() != consts.StatusFound {{ "{" }}
		t.Fatalf("expected 302, got %d", c.Response.StatusCode())
	{{ "}" }}
	loc := string(c.Response.Header.Get("Location"))
	if loc != "http://localhost:3000/settings" {{ "{" }}
		t.Fatalf("unexpected redirect location: %s", loc)
	{{ "}" }}
{{ "}" }}

func TestOAuthHandler_Unbind_UsesAuthenticatedUid(t *testing.T) {{ "{" }}
	cli := &fakeOAuthUserClient{{ "{" }}unbindProviderFn: func(ctx context.Context, req *userv1.UnbindProviderReq) (*userv1.UnbindProviderResp, error) {{ "{" }}
		if req.Uid != "uid-authenticated" || req.Provider != "github" {{ "{" }}
			t.Fatalf("unexpected request: %+v", req)
		{{ "}" }}
		return &userv1.UnbindProviderResp{{ "{" }}{{ "}" }}, nil
	{{ "}" }}{{ "}" }}
	h := NewOAuthHandler(cli, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}{{ "}" }}, time.Minute)
	c := newAuthenticatedOAuthTestContext("DELETE", "/auth/oauth/github/bind", "uid-authenticated", map[string]string{{ "{" }}"provider": "github"{{ "}" }})
	h.Unbind(context.Background(), c)
	if c.Response.StatusCode() != 200 {{ "{" }}
		t.Fatalf("expected 200, got %d: %s", c.Response.StatusCode(), c.Response.Body())
	{{ "}" }}
{{ "}" }}

func TestOAuthHandler_Unbind_MissingClaims_Returns401(t *testing.T) {{ "{" }}
	h := NewOAuthHandler(&fakeOAuthUserClient{{ "{" }}{{ "}" }}, &fakeCodeStore{{ "{" }}{{ "}" }}, conf.OAuthRedirectConfig{{ "{" }}{{ "}" }}, time.Minute)
	c := newOAuthTestContext("DELETE", "/auth/oauth/github/bind", map[string]string{{ "{" }}"provider": "github"{{ "}" }})
	h.Unbind(context.Background(), c)
	if c.Response.StatusCode() != consts.StatusUnauthorized {{ "{" }}
		t.Fatalf("expected 401 when no claims are set, got %d", c.Response.StatusCode())
	{{ "}" }}
{{ "}" }}
```

Add `"{{.Module}}/internal/pkg/middleware"` to the test file's import block.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/handler/... -run "OAuthHandler_Bind|OAuthHandler_Unbind" -v`. Expected: FAIL — `undefined: (*OAuthHandler).BindStart`, etc.

- [ ] **Step 3: Add the bind/unbind methods to `OAuthHandler`**

Append these methods to `user-bff-hertz/hertz-template/internal_handler_oauth_go.yaml`'s body (after `Exchange`), and add `"{{.Module}}/internal/pkg/middleware"` to the file's import block:

```go
// BindStart begins a bind-flow OAuth redirect for the authenticated user:
// GET /auth/oauth/:provider/bind-start (JWT-protected)
func (h *OAuthHandler) BindStart(ctx context.Context, c *app.RequestContext) {{ "{" }}
	claims, ok := middleware.GetClaims(c)
	if !ok {{ "{" }}
		response.ErrorCode(c, response.CodeUnauthorized)
		return
	{{ "}" }}
	provider := c.Param("provider")
	resp, err := h.userCli.OAuthStart(ctx, &userv1.OAuthStartReq{{ "{" }}Provider: provider, Purpose: "bind", Uid: claims.Uid{{ "}" }})
	if err != nil {{ "{" }}
		response.Err(c, err)
		return
	{{ "}" }}
	c.Redirect(302, []byte(resp.RedirectUrl))
{{ "}" }}

// BindCallback completes a bind-flow OAuth redirect: GET /auth/oauth/:provider/bind-callback
// The identity being bound comes from the OAuth state (set in BindStart
// from the authenticated caller's JWT), not from anything in this request.
func (h *OAuthHandler) BindCallback(ctx context.Context, c *app.RequestContext) {{ "{" }}
	provider := c.Param("provider")
	state := string(c.Query("state"))
	code := string(c.Query("code"))
	_, err := h.userCli.BindProvider(ctx, &userv1.BindProviderReq{{ "{" }}Provider: provider, State: state, Code: code{{ "}" }})
	if err != nil {{ "{" }}
		c.Redirect(302, []byte(h.redirectCfg.ErrorURL))
		return
	{{ "}" }}
	c.Redirect(302, []byte(h.redirectCfg.BindSuccessURL))
{{ "}" }}

// Unbind removes a bound third-party identity: DELETE /auth/oauth/:provider/bind (JWT-protected)
func (h *OAuthHandler) Unbind(ctx context.Context, c *app.RequestContext) {{ "{" }}
	claims, ok := middleware.GetClaims(c)
	if !ok {{ "{" }}
		response.ErrorCode(c, response.CodeUnauthorized)
		return
	{{ "}" }}
	provider := c.Param("provider")
	_, err := h.userCli.UnbindProvider(ctx, &userv1.UnbindProviderReq{{ "{" }}Uid: claims.Uid, Provider: provider{{ "}" }})
	if err != nil {{ "{" }}
		response.Err(c, err)
		return
	{{ "}" }}
	response.OK(c, map[string]string{{ "{" }}"status": "ok"{{ "}" }})
{{ "}" }}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/handler/... -run OAuthHandler -v`. Expected: PASS, all tests in this file (Start/Callback/Exchange from Task 7 plus BindStart/BindCallback/Unbind from this task).

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_oauth_go.yaml \
        user-bff-hertz/hertz-template/internal_handler_oauth_test_go.yaml
git commit -m "feat(user-bff-hertz): add bind-start/bind-callback/unbind handlers, uid sourced from JWT not client input"
```

---

### Task 9: Router wiring, server wiring, client wiring

**Files:**
- Create: `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`
- Create: `user-bff-hertz/hertz-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes: everything from Tasks 2-8.
- Produces: a fully wired Hertz server — **this is the integration checkpoint for this plan**, analogous to `user-kitex`'s Task 14/15; a full `go build ./...` here proves Tasks 1-8 all compile together.

- [ ] **Step 0: Add `idl/user.proto` and `idl/rule_center.proto`**

Copy `user-kitex/idl/user.proto` verbatim to `user-bff-hertz/idl/user.proto`. Copy `admin-bff-hertz/idl/rule_center.proto` verbatim to `user-bff-hertz/idl/rule_center.proto`. Both files already use `{{.Module}}`/template-relative `go_package` conventions consistent with this repo's IDL corpus — no edits needed beyond the copy. This corrects the plan's original Global Constraint ("no proto/IDL added"), which was an unverified assumption; see the ledger Ruling before this task. `idl/api.proto` does NOT need to be added — `ncgo new --kind hertz` auto-injects it (confirmed via a real scratch render: `ncgo new` with zero `idl/` files still produces `idl/api.proto` identical to `ncgo`'s own built-in `bff-default` scaffold testdata).

```bash
cp user-kitex/idl/user.proto user-bff-hertz/idl/user.proto
cp admin-bff-hertz/idl/rule_center.proto user-bff-hertz/idl/rule_center.proto
git add user-bff-hertz/idl/user.proto user-bff-hertz/idl/rule_center.proto
git commit -m "feat(user-bff-hertz): add idl/user.proto + idl/rule_center.proto for kitex client codegen"
```

- [ ] **Step 1: Write the router**

```yaml
# ncgo exported template — internal/router/userbffservice.go
path: internal/router/userbffservice.go
update_behavior:
    type: cover
loop_service: true
body: |
    package router

    import (
    	"github.com/cloudwego/hertz/pkg/app/server"

    	"{{.Module}}/internal/base/conf"
    	"{{.Module}}/internal/handler"
    	"{{.Module}}/internal/pkg/middleware"
    	"{{.Module}}/internal/pkg/oauthcode"
    	"{{.Module}}/internal/pkg/ratelimit"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )

    // Register{{.ServiceName}}BffServiceRoutes registers all user-bff-hertz routes.
    func Register{{.ServiceName}}BffServiceRoutes(h *server.Hertz, userCli userservice.Client, codeStore oauthcode.Store, resolver *ratelimit.Resolver) {{ "{" }}
    	cfg := conf.Get()

    	authHandler := handler.NewAuthHandler(userCli)
    	oauthHandler := handler.NewOAuthHandler(userCli, codeStore, cfg.OAuthRedirect, cfg.OAuthCode.TTLSeconds.Duration)

    	h.Use(middleware.CORS(cfg.CORS))

    	auth := h.Group("/auth")

    	// Public: register/login (idempotency on register, rate limit on both)
    	if cfg.Idempotency.Enabled {{ "{" }}
    		auth.POST("/register", middleware.Idempotency(cfg.Idempotency), middleware.RateLimit("public", cfg.RateLimit, cfg.RateLimit.Register, resolver), authHandler.Register)
    	{{ "}" }} else {{ "{" }}
    		auth.POST("/register", middleware.RateLimit("public", cfg.RateLimit, cfg.RateLimit.Register, resolver), authHandler.Register)
    	{{ "}" }}
    	auth.POST("/login", middleware.RateLimit("public", cfg.RateLimit, cfg.RateLimit.Login, resolver), authHandler.Login)

    	// Public: OAuth login flow
    	oauth := auth.Group("/oauth")
    	oauth.GET("/:provider/start", oauthHandler.Start)
    	oauth.GET("/:provider/callback", oauthHandler.Callback)
    	oauth.POST("/exchange", oauthHandler.Exchange)

    	// Protected: bind flow requires an authenticated user
    	protected := oauth.Group("")
    	protected.Use(middleware.JWTAuth(cfg.Auth.Token))
    	protected.GET("/:provider/bind-start", oauthHandler.BindStart)
    	protected.GET("/:provider/bind-callback", oauthHandler.BindCallback)
    	protected.DELETE("/:provider/bind", oauthHandler.Unbind)
    {{ "}" }}
```

Note: `cfg.RateLimit.Register`/`cfg.RateLimit.Login` are per-phase rate-limit config fields — mirror whatever field/type name `admin-bff-hertz`'s `conf.go` actually uses for its per-endpoint `RateLimitPhaseConfig` entries (e.g. `admin-bff-hertz` likely has phase configs keyed by name inside `RateLimitConfig`, given `middleware.RateLimit(phase string, cfg conf.RateLimitConfig, phaseCfg conf.RateLimitPhaseConfig, ...)`'s signature takes a phase-specific config as a separate argument) — check the actual current `admin-bff-hertz/hertz-template/conf_go.yaml`'s `RateLimitConfig` struct fields before finalizing this router file, and add two phase entries (`Register`, `Login`) to `user-bff-hertz`'s own `RateLimitConfig` in Task 2 if the upstream shape uses a fixed/named set of phases rather than a map (Task 2 was written before this exact wiring need was discovered — revisit Task 2's `conf.yaml` output when implementing this task and add the two phase config fields if missing, rather than guessing their shape now).

**Also note:** the router's `Group("")` call on an already-`/auth/oauth`-scoped group to mount JWT-protected sub-routes assumes Hertz's route-group API supports this nesting pattern (`oauth.Group("")` on the parent to create a distinct middleware chain for a path-overlapping subset) — verify this compiles and routes correctly against the actual Hertz version in this repo; if `Group("")` isn't idiomatic Hertz for this, the working alternative is to apply `middleware.JWTAuth` directly to just the three protected route registrations via Hertz's per-route middleware chaining (`oauth.GET("/:provider/bind-start", middleware.JWTAuth(cfg.Auth.Token), oauthHandler.BindStart)` etc.) instead of a sub-group — use whichever the rendered `hz`/Hertz version in this repo actually supports, checked by rendering and building, not assumed.

- [ ] **Step 2: Write server wiring**

Mirror `admin-bff-hertz/hertz-template/internal_base_server_server_go.yaml`'s shape exactly (its actual code, verified by reading the real rendered file — not the `userserviceclient` wrapper name used loosely elsewhere in this plan's earlier draft text): load `conf.Get()`, construct a Redis client (shared for `OAuthCode` store and idempotency/rate-limit as applicable), construct `oauthcode.NewRedisStore(redisClient)`, construct the `user-kitex` RPC client directly from the locally-generated `kitex_gen/api/user/v1/userservice` package (added via Step 0 + `ncgo add kitex-client`) using `userservice.NewClient(cfg.RPC.UserService.ServiceName, client.WithHostPorts(cfg.RPC.UserService.HostPorts[0]))` — same pattern `admin-bff-hertz`'s server.go uses for `authservice.NewClient`/`rbacservice.NewClient` — construct the `rule-center` RPC client the same way via `kitex_gen/api/ratelimit/v1/ruleservice`, build the `ratelimit.Resolver`, call `router.RegisterUserBffServiceRoutes(h, userCli, codeStore, resolver)`, then `h.Spin()`.

- [ ] **Step 3: Full render + build + test**

`user-bff-hertz` generates its OWN local `kitex_gen/` from its own `idl/user.proto`/`idl/rule_center.proto` (added in Step 0) — it does NOT import `user-kitex`'s generated package directly; this mirrors `admin-bff-hertz`'s own precedent exactly (its `idl/auth.proto`/`idl/rbac.proto`/`idl/rule_center.proto` are its own local copies too, not imports from `admin-services-kitex`'s generated output). Render with real `ncgo`:

```bash
ncgo new userbffvalidate --kind hertz --module github.com/example/userbffvalidate \
  --template-dir <repo>/user-bff-hertz --dir /tmp/userbff-validate
cd /tmp/userbff-validate
ncgo add kitex-client user --service UserService --idl idl/user.proto --module github.com/example/userbffvalidate
ncgo add kitex-client rulecenter --service RuleService --idl idl/rule_center.proto --module github.com/example/userbffvalidate
go mod tidy
go build ./... && go vet ./... && go test ./... && go test -race ./...
```

All must pass. (For tasks 6-8's earlier handler-only tests, the cross-render-copy technique was a validation shortcut; Task 9 must use the real `ncgo add kitex-client` mechanism since it's the actual production wiring path.)

- [ ] **Step 4: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml \
        user-bff-hertz/hertz-template/internal_base_server_server_go.yaml
git commit -m "feat(user-bff-hertz): wire router, server, user-kitex + rule-center clients"
```

---

### Task 10: Package docs, root README updates, e2e test, full acceptance run

**Files:**
- Create: `user-bff-hertz/README.md`
- Create: `user-bff-hertz/test/e2e_test.sh`
- Modify: `README.md`, `README.zh-CN.md` (repo root — add `user-bff-hertz` row to the HTTP services table)

**Interfaces:**
- Consumes: everything from Tasks 1-9.
- Produces: a fully consumable `ncgo new --kind hertz --template user-bff-hertz` template package — this plan's deliverable.

- [ ] **Step 1: Write `user-bff-hertz/README.md`**

Document: what the template provides (local + OAuth login gateway for `user-kitex`), the one-time code exchange rationale, all 9 routes with method/path/auth-requirement, required upstream config (`user-kitex` host/port, `rule-center` host/port, `oauth_redirect.*` URLs, `auth.token.signing_key` **must match `user-kitex`'s own signing key**), and a "Seams" section listing: Issue #66 (JWT Claims field mismatch in `base-hertz`/`admin-bff-hertz`, not present in this package's own `token.go`), and a note that `admin-bff-hertz`'s own terminal-user-management integration is Plan 3 (separate, not yet started).

- [ ] **Step 2: Write `user-bff-hertz/test/e2e_test.sh`**

Mirror `admin-bff-hertz/test/e2e_test.sh`'s tool-gating structure (`skipped: <tool> 未安装` when `ncgo`/`hz`/`kitex` missing), retarget to render `user-bff-hertz` (+ `user-kitex` as its RPC dependency) and run `go build ./... && go test ./...`.

- [ ] **Step 3: Update root READMEs**

Add a row to the "HTTP 服务 (Hertz)" table in `README.zh-CN.md` and the equivalent English table in `README.md`:

```
| `user-bff-hertz` | 终端用户 HTTP 网关（本地登录 + OAuth 第三方登录，一次性 code 换 JWT，账号绑定解绑） | ✅ `ncgo new --kind hertz --template user-bff-hertz` |
```

- [ ] **Step 4: Full acceptance run**

Run the full render/build/test/race cycle from Task 9 Step 3 one final time against the finished package, plus `gofmt -l` and a residual-template-escape grep (`{{ "{"`, `{{ "}"`, unresolved `{{.` actions) over the rendered `.go` files, matching the rigor `user-kitex`'s own Task 15 and final review applied.

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/README.md user-bff-hertz/test/e2e_test.sh README.md README.zh-CN.md
git commit -m "feat(user-bff-hertz): add README, e2e test, register in root READMEs"
```

---

## Plan Self-Review Notes

- **Spec coverage:** every route in `docs/superpowers/specs/2026-09-14-user-bff-hertz-design.md` is covered: local register/login (Task 6), OAuth start/callback/exchange (Task 7), bind-start/bind-callback/unbind (Task 8), the `user-kitex` state-carries-uid extension (Task 1), CORS/JWT/idempotency/rate-limit middleware (Tasks 3-5), router/server/client wiring (Task 9), docs (Task 10).
- **Type consistency:** `middleware.Claims{Uid, Roles}` (Task 3) is used consistently by Task 5's idempotency adaptation and Task 8's bind/unbind handlers (`claims.Uid`, never `claims.UUID`/`claims.AK`). `oauthcode.Store`'s `Put(ctx, jwt string, ttl time.Duration) (code string, err error)` / `Consume(ctx, code string) (jwt string, ok bool, err error)` (Task 4) match exactly between the interface, `RedisStore` impl, and Task 7/8's handler usage. `user-kitex`'s extended `StateStore.Put/Consume` 5-arg/5-return shape (Task 1) is internal to `user-kitex` and does not leak into `user-bff-hertz` — the BFF only ever calls `user-kitex`'s RPC surface (`OAuthStartReq.Uid`, not the state store directly).
- **No placeholders:** every step ships real, compilable code. Two places explicitly flag "verify against the actual current file before assuming" (Task 9's `RateLimitConfig` phase-field shape, Task 9's Hertz route-group nesting API, Task 6's `fakeUserClient` embed target) rather than guessing a specific API shape this plan's author couldn't directly verify — these are honest uncertainty flags for the implementer to resolve against the real, current code, not vague "add appropriate X" placeholders masquerading as complete.
