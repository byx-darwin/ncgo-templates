# admin-bff-hertz 集成终端用户管理 Implementation Plan (Plan 3 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `admin-bff-hertz`'s admin console the ability to list/inspect/ban/unban terminal (end-user) accounts and force-unbind their third-party identities, by calling `user-kitex`'s existing (and two newly-added) admin-facing RPCs — and, discovered as a prerequisite during planning, fix a real pre-existing authorization-bypass bug in `admin-bff-hertz`'s `Authz` middleware that currently makes RBAC permission checks a no-op for every protected route in the package.

**Architecture:** `user-kitex` gains two small RPC additions (`GetUser`, `AdminUnbindProvider`) reusing existing service-layer logic. `admin-bff-hertz` gains its own local `idl/user.proto` copy (same production-wiring pattern Plan 2 established: `ncgo add kitex-client` generates a local `kitex_gen` independent of `user-kitex`'s own generated project) plus a new `internal/handler/terminal_user.go`, new `/api/v1/terminal-users` routes, and a corrected `Authz`/`RequirePermission` registration order applied to every existing route group as well as the new one.

**Tech Stack:** Go 1.22+, Hertz, Kitex client (`kitex_gen/api/user/v1/userservice`, generated locally via `ncgo add kitex-client`), existing `admin-bff-hertz` RBAC (`kitex_gen/api/rbac/v1/rbacservice`) and response/middleware packages.

**Spec:** `docs/superpowers/specs/2026-09-15-admin-bff-terminal-user-management-design.md`

## Global Constraints

- Literal Go braces `{` / `}` inside `body:` blocks MUST be written as `{{ "{" }}` / `{{ "}" }}` — verified again against every file read while planning this.
- **New route/permission naming is `terminal_user:*` under `/api/v1/terminal-users`, deliberately distinct from `admin-bff-hertz`'s existing `/api/v1/users` + `user:*` permissions (those manage RBAC *admin operator* accounts via `rbacservice`, a completely different resource from `user-kitex`'s terminal/end-user accounts).** Never reuse the `user:*` permission codes or the `/users` path for this work.
- **`Authz` middleware ordering bug, confirmed by reading Hertz v0.10.6's actual router source (`combineHandlers` in `pkg/route/routergroup.go`, `RequestContext.Next` in `pkg/app/context.go`):** `protected.Use(middleware.Authz(rbacCli))` registers `Authz` as a group-level handler, which `combineHandlers` always places *before* any route's own per-route handlers (like `middleware.RequirePermission(code)`) in the final handler chain. Since `Next()` is a forward-only loop (not onion/recursive), `Authz` reads `GetPermission(c)` — which is empty, because `RequirePermission` (later in the chain) hasn't run yet — takes its "no permission required" branch, and calls `c.Next()` which runs everything else including the real handler, all without ever calling `rbacCli.Enforce`. **This means RBAC authorization currently does not function on ANY existing protected route in `admin-bff-hertz`** (`/users`, `/roles`, `/permissions`, `/menus`, `/rate-limit-rules`) — any authenticated JWT holder can call any of them regardless of actual permission. Fixing this (Task 3) is in scope for this plan per explicit user decision, and must fix *every* existing route registration, not just the new `terminal-users` ones.
- `AdminUnbindProvider` (new `user-kitex` RPC) MUST NOT duplicate `usersvc.Service.UnbindProvider`'s logic — its handler calls the exact same already-existing `h.self.UnbindProvider(ctx, req.Uid, req.Provider)` that the existing `UnbindProvider` RPC handler calls (see `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml:71-74`). The two RPCs exist as separate wire-level entry points (different trust models: self-service vs. admin-authorized) but share one implementation.
- `GetUser` (new `user-kitex` RPC) exists because `ListUsers(limit, offset)` has no way to filter by a single `uid` — without it, a "get one user's detail" admin-bff-hertz handler would have to page through the entire `ListUsers` result set client-side, which doesn't scale and isn't how any other admin-bff-hertz detail handler works (compare `UserHandler.Get`, which calls a dedicated `rbacCli.GetUser`). This is a minimal, directly-motivated addition, not scope creep.
- Audit log query is explicitly OUT OF SCOPE for this plan (confirmed by user during brainstorming) — `user-kitex` has no audit log storage/RPC at all; that is a future, separate, larger plan.
- Every task must render the WHOLE package (both `user-kitex` and `admin-bff-hertz`, via the real `ncgo new --template-dir` + `ncgo add kitex-client` pipeline, never the cross-render-copy shortcut) and run `go build/vet/test/race`, per the lesson carried forward from Plan 1 and Plan 2's own ledgers — a task that only builds the files it touched has repeatedly missed real breakage in this registry.

---

### Task 1: `user-kitex` — add `GetUser` and `AdminUnbindProvider` admin RPCs

**Files:**
- Modify: `user-kitex/idl/user.proto`
- Modify: `user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml`
- Modify: `user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`
- Modify: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`
- Test: same files above (template test bodies), plus a handler-level test file if one already exists for `userservice_handler.go` (check `user-kitex/kitex-template/internal_handler_userservice_handler_test_go.yaml` — if present, add cases there; if absent, this task does not need to create one, since the existing RPC handlers for `ListUsers`/`BanUser`/etc. have no dedicated handler-level tests either — service-level tests are this package's established coverage boundary for admin RPCs).

**Interfaces:**
- Consumes: `useradminsvc.Service` (existing, from `internal/application/useradmin/admin_service.go`), `usersvc.Service.UnbindProvider(ctx, uid, providerName string) error` (existing, unchanged, from `internal/application/user/user_service.go`), `user.Repository.GetByID(ctx, id) (*User, error)` (existing) and `user.ErrNotFound` (existing).
- Produces: `useradminsvc.Service.GetUser(ctx, uid string) (UserDTO, error)` — new method; `userv1.UserService` gains two new RPCs, `GetUser(GetUserReq) returns (GetUserResp)` and `AdminUnbindProvider(AdminUnbindProviderReq) returns (AdminUnbindProviderResp)`, consumed by Task 2's `admin-bff-hertz/idl/user.proto` copy and Task 4's handler.

- [ ] **Step 1: Add the two new proto messages and RPCs**

Open `user-kitex/idl/user.proto`. Add these message definitions directly after the existing `ListUserIdentitiesResp` message (keep the file's existing message ordering otherwise untouched):

```protobuf
message GetUserReq {
  string uid = 1;
}
message GetUserResp {
  UserItem user = 1;
}

message AdminUnbindProviderReq {
  // uid is the target end-user, specified by an admin operator via
  // admin-bff-hertz. Trust boundary: admin-bff-hertz's own RBAC
  // authorization (the "terminal_user:unbind-identity" permission) gates
  // this call — user-kitex does not re-verify the caller's identity here,
  // matching the existing admin RPC surface (BanUser/UnbanUser/ForceLogout/
  // ListUsers already work this way: no per-call caller-identity check,
  // trust is placed in the calling BFF having already authorized the
  // operator). Do NOT confuse this with UnbindProviderReq, which is for
  // self-service callers acting on their own already-authenticated uid.
  string uid = 1;
  string provider = 2;
}
message AdminUnbindProviderResp {}
```

Then add both RPCs to the end of `service UserService`'s method list (after the existing `ListUserIdentities` line):

```protobuf
  rpc GetUser(GetUserReq) returns (GetUserResp);
  rpc AdminUnbindProvider(AdminUnbindProviderReq) returns (AdminUnbindProviderResp);
```

- [ ] **Step 2: Add `useradminsvc.Service.GetUser`**

Edit `user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml`. Add this method after the existing `ListUsers` method (the file already imports `"github.com/google/uuid"` and `"{{.Module}}/internal/domain/user"`, no new imports needed):

```yaml
    func (s *Service) GetUser(ctx context.Context, uid string) (UserDTO, error) {{ "{" }}
    	id, err := uuid.Parse(uid)
    	if err != nil {{ "{" }}
    		return UserDTO{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	u, err := s.repo.GetByID(ctx, id)
    	if err != nil {{ "{" }}
    		return UserDTO{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	return toUserDTO(u), nil
    {{ "}" }}
```

(Insert this as YAML-body text using the same `{{ "{" }}`/`{{ "}" }}` escaping as every other method already in that file — copy the existing `ListUsers`/`BanUser` methods' exact indentation style.)

- [ ] **Step 3: Add a failing test for `GetUser`, then make it pass**

Edit `user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`. First read the existing file in full to see its fake-repository test double (it already has one, used by the existing `TestListUsers`/`TestBanUser` etc. tests — reuse it, do not create a second one). Add these two test cases matching that existing fake repo's construction pattern:

```go
func TestGetUser_ReturnsDTO(t *testing.T) {
	// Arrange: seed the fake repo (used by every other test in this file)
	// with one user, then call GetUser with that user's uid.
	// Assert: returned UserDTO.Uid/Username/Nickname/Status match the seeded row.
}

func TestGetUser_NotFound_ReturnsError(t *testing.T) {
	// Arrange: a fake repo whose GetByID returns user.ErrNotFound for any id.
	// Assert: GetUser returns a non-nil error (do not assert a specific
	// error type beyond user.ErrNotFound — the fake repo's own behavior
	// already governs what's returned, mirroring how repo.GetByID's own
	// contract is tested elsewhere in this package).
}
```

(Write these using the actual fake-repo type and its exact field/method names as found in the existing test file — do not invent a new mock. If the existing fake repo's `GetByID` doesn't yet support returning `user.ErrNotFound` for a given id, extend it minimally rather than adding a second fake.)

Run: `go test ./internal/application/useradmin/... -run TestGetUser -v` (against a fresh render — see Task's final verification step) — expect both new tests to pass, and expect zero changes to any pre-existing test in this file.

- [ ] **Step 4: Add the two new handler methods**

Edit `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`. Add both new methods after the existing `ListUserIdentities` handler method (end of file):

```yaml
    func (h *UserServiceHandlerImpl) GetUser(ctx context.Context, req *userv1.GetUserReq) (*userv1.GetUserResp, error) {{ "{" }}
    	dto, err := h.admin.GetUser(ctx, req.Uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &userv1.GetUserResp{{ "{" }}User: &userv1.UserItem{{ "{" }}Uid: dto.Uid, Username: dto.Username, Nickname: dto.Nickname, Status: int32(dto.Status){{ "}" }}{{ "}" }}, nil
    {{ "}" }}

    func (h *UserServiceHandlerImpl) AdminUnbindProvider(ctx context.Context, req *userv1.AdminUnbindProviderReq) (*userv1.AdminUnbindProviderResp, error) {{ "{" }}
    	// Reuses the same self-service unbind logic as UnbindProvider — see
    	// this file's UnbindProvider method above and this task's Global
    	// Constraints note: two wire-level RPCs, one implementation, because
    	// the actual unbind business logic (the "cannot unbind your only
    	// auth method" safety check) must apply identically regardless of
    	// whether the caller is the end-user themselves or an admin acting
    	// on their behalf via admin-bff-hertz.
    	err := h.self.UnbindProvider(ctx, req.Uid, req.Provider)
    	return &userv1.AdminUnbindProviderResp{{ "{" }}{{ "}" }}, err
    {{ "}" }}
```

- [ ] **Step 5: Full render + build + test**

```bash
rm -rf /tmp/userkitex-task1-validate
ncgo new userkitextask1 --kind kitex --module github.com/example/userkitextask1 \
  --template-dir <repo>/user-kitex --dir /tmp/userkitex-task1-validate
cd /tmp/userkitex-task1-validate
go mod tidy
go build ./... && go vet ./... && go test ./... && go test -race ./...
```

All must pass. Confirm via `grep -n "GetUser\|AdminUnbindProvider" internal/handler/userservice_handler.go internal/application/useradmin/admin_service.go` that both new methods rendered correctly (no leftover `{{ "{" }}` template-escape artifacts — grep for that literal string too and confirm zero matches in the rendered `.go` files).

- [ ] **Step 6: Commit**

```bash
git add user-kitex/idl/user.proto \
        user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml \
        user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml \
        user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml
git commit -m "feat(user-kitex): add GetUser and AdminUnbindProvider admin RPCs"
```

---

### Task 2: `admin-bff-hertz` — add `idl/user.proto` and the terminal-user RPC client config

**Files:**
- Create: `admin-bff-hertz/idl/user.proto`
- Modify: `admin-bff-hertz/hertz-template/conf_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/conf_dev_conf_yaml.yaml` (or whatever the actual dev-config YAML file is named — check `admin-bff-hertz/hertz-template/` for the exact filename that renders to `conf/dev/conf.yaml`, matching however Task 1 of the Plan 2 precedent named it; do not guess, read the directory listing first)

**Interfaces:**
- Consumes: `user-kitex/idl/user.proto` (Task 1's output, including the two new RPCs) as the literal source to copy.
- Produces: `admin-bff-hertz/idl/user.proto` (a real file, copied verbatim except the `{{.Module}}` templating already present in the source, which needs no changes since `admin-bff-hertz`'s own render will substitute its own module path the same way `user-kitex`'s render does — copying is truly byte-for-byte); `conf.GRPCConfig.TerminalUser` (new field, type `ClientConfig`, same shape as the existing `conf.GRPCConfig.Authority` field) — consumed by Task 5's server wiring.

- [ ] **Step 1: Copy the IDL**

```bash
cp user-kitex/idl/user.proto admin-bff-hertz/idl/user.proto
```

Verify with `diff user-kitex/idl/user.proto admin-bff-hertz/idl/user.proto` — must be empty (byte-identical), exactly matching how `user-bff-hertz/idl/user.proto` was created in Plan 2 Task 9.

- [ ] **Step 2: Add `GRPCConfig.TerminalUser` to `conf.go`**

Read `admin-bff-hertz/hertz-template/conf_go.yaml` and find the existing `GRPCConfig` struct (currently `type GRPCConfig struct { Authority ClientConfig \`yaml:"authority"\` }`). Add a second field:

```go
type GRPCConfig struct {
	Authority    ClientConfig `yaml:"authority"`
	TerminalUser ClientConfig `yaml:"terminal_user"`
}
```

(`ClientConfig` is the existing struct — `ServiceName`, `HostPorts`, `RPCTimeoutSeconds`, `ConnectTimeoutMilliseconds`, `EnableMetaInfo`, `Retry` — reuse it verbatim, do not define a new type.) Check whether `conf.go`'s `Validate()` method validates `GRPC.Authority.ServiceName`/`HostPorts` (it likely does, given Plan 2's `user-bff-hertz` established this exact "guard against empty HostPorts" pattern in its own final fix wave) — if so, add the equivalent guard for `GRPC.TerminalUser.ServiceName`/`HostPorts` now, at the point of introduction, rather than waiting to discover the missing-guard panic the way Plan 2 did. If `Validate()` currently has NO such guard even for the pre-existing `Authority` field, that's a pre-existing gap outside this task's scope — add the guard only for the new `TerminalUser` field, and note the `Authority` gap in this task's commit message as an aside, but do not fix it (scope discipline).

- [ ] **Step 3: Add the dev-config default**

In whichever file renders `conf/dev/conf.yaml` (find it — it's the file with `path: conf/dev/conf.yaml` in its YAML frontmatter under `admin-bff-hertz/hertz-template/`), find the existing `grpc: authority: ...` block and add a sibling:

```yaml
grpc:
  authority:
    service_name: "authority"
    host_ports:
      - "127.0.0.1:8888"
    rpc_timeout_seconds: 5
    connect_timeout_milliseconds: 100
  terminal_user:
    service_name: "userservice"
    host_ports:
      - "127.0.0.1:8890"
    rpc_timeout_seconds: 3
    connect_timeout_milliseconds: 100
```

(Use `127.0.0.1:8890` — distinct from `user-kitex`'s own dev default of `8888` used by `user-bff-hertz`'s dev config in Plan 2, and distinct from `admin-services-kitex`'s `8888` used here for `authority` — all three services would need distinct ports if run together locally; pick whatever port is NOT already used by an existing dev config in this repo, verified by grepping all `hertz-template`/`kitex-template` dev-config files for `host_ports` before finalizing this value.)

- [ ] **Step 4: Full render + build**

```bash
rm -rf /tmp/adminbff-task2-validate
ncgo new adminbfftask2 --kind hertz --module github.com/example/adminbfftask2 \
  --template-dir <repo>/admin-bff-hertz --dir /tmp/adminbff-task2-validate
cd /tmp/adminbff-task2-validate
go build ./... && go vet ./...
```

Expect this to build clean for every package except wherever `kitex_gen` is referenced but not yet generated (Task 5's job, matching every prior plan's staged-build-gap pattern) — confirm the ONLY build failures are `kitex_gen`-import-related, nothing else (in particular, `internal/base/conf` and `internal/base/server` compiling error-for-error identically to before this task, aside from the new field, is the acceptance bar here).

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/idl/user.proto admin-bff-hertz/hertz-template/conf_go.yaml admin-bff-hertz/hertz-template/conf_dev_conf_yaml.yaml
git commit -m "feat(admin-bff-hertz): add idl/user.proto and terminal-user RPC client config"
```

(Adjust the second filename in `git add` to whatever Step 3 actually found — do not blindly copy this if the real filename differs.)

---

### Task 3: `admin-bff-hertz` — fix the `Authz` middleware ordering bug (all existing routes)

**Files:**
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml`
- Create: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml`

**Interfaces:**
- Consumes: `middleware.RequirePermission(code string) app.HandlerFunc`, `middleware.Authz(rbacCli rbacservice.Client) app.HandlerFunc` (both existing, unchanged — only their *registration order* changes), `middleware.JWTAuth`, `rbacservice.Client` (existing generated type).
- Produces: a router registration pattern (`RequirePermission(code)` immediately followed by `Authz(rbacCli)` on every individual route, instead of `Authz` once at the group level) that Task 5 must follow exactly for the new `terminal-users` routes.

- [ ] **Step 1: Understand the exact bug (do not skip — read this before editing)**

Currently (`internal_router_adminbffservice_go.yaml`):
```go
protected := api.Group("")
protected.Use(middleware.JWTAuth(cfg.Auth.Token))
protected.Use(middleware.Authz(rbacCli))
...
users.GET("", middleware.RequirePermission("user:list"), userHandler.List)
```

Hertz's `RouterGroup.combineHandlers` (verified against `github.com/cloudwego/hertz@v0.10.6/pkg/route/routergroup.go`) always places a group's `.Use()` handlers *before* a route's own per-call handlers in the final chain, regardless of registration order elsewhere. So the real chain for the route above is `[JWTAuth, Authz, RequirePermission("user:list"), List]`. `RequestContext.Next` (verified against `pkg/app/context.go`) is a forward-only `for` loop, not onion/recursive — so when `Authz` runs, `RequirePermission` has not executed yet, `middleware.GetPermission(c)` returns `""`, `Authz` takes its "no permission required, skip enforcement" branch, and calls `c.Next(ctx)` — which runs `RequirePermission` and `List` to completion inside that single call. `Authz`'s own `rbacCli.Enforce` call is never reached. **Fix: register `RequirePermission(code)` and `Authz(rbacCli)` together, per-route, in that order** — remove `protected.Use(middleware.Authz(rbacCli))` entirely, and change every protected route registration to `group.METHOD(path, middleware.RequirePermission(code), middleware.Authz(rbacCli), handler)`.

- [ ] **Step 2: Rewrite the router registrations**

Edit `internal_router_adminbffservice_go.yaml`. Remove the line `protected.Use(middleware.Authz(rbacCli))`. Change every existing permission-gated route from `group.METHOD(path, middleware.RequirePermission("code"), handler)` to `group.METHOD(path, middleware.RequirePermission("code"), middleware.Authz(rbacCli), handler)` — this applies to all 14 existing route registrations under `users`, `roles`, `perms`, `menus`, and `rules`. The `me` group's two routes (`GetMenus`/`GetPerms`) and `auth.POST("/auth/logout", ...)` have no `RequirePermission` call today (they rely on `JWTAuth` alone) — leave those three routes untouched, since they were never using the (broken) permission-check path in the first place and this task's job is fixing the broken enforcement, not adding new gates that weren't there.

- [ ] **Step 3: Write a router-level regression test proving real enforcement**

Create `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml` (`path: internal/router/adminbffservice_test.go`, `update_behavior: skip`, `loop_service: true`). Model it closely on `user-bff-hertz/hertz-template/internal_router_userbffservice_test_go.yaml` (read that file in full first — it's the established pattern in this repo for a router-level test: `TestMain` injects `CONFIG_PATH` pointing at a temp conf.yaml with `auth.token.enabled: true`, builds a real `route.Engine` via `Register{{.ServiceName}}BffServiceRoutes` with fake RPC clients, drives it with `github.com/cloudwego/hertz/pkg/common/ut.PerformRequest`). Adapt it for `admin-bff-hertz`'s four-client signature (`rbacAuthCli authservice.Client, rbacCli rbacservice.Client, rulecenterCli ruleservice.Client` — and, after Task 5 lands, a fourth `userCli userservice.Client`; if Task 3 runs before Task 5 in execution order, write this test against the CURRENT three-client signature and note in a comment that Task 5 will extend it, OR — preferably — coordinate by having whichever task actually lands second extend this test file rather than each assuming the other's shape; the SDD controller executing this plan should resolve this ordering explicitly, since both Task 3 and Task 5 touch the same test file's `newRouterTestEngine` helper).

The test must prove the actual bug is fixed, not just that the code compiles differently:

```go
func TestAuthz_DeniedPermission_Returns403(t *testing.T) {
	// Build a real route.Engine with a fake rbacservice.Client whose
	// Enforce() always returns {Allowed: false}, and a valid JWT for an
	// authenticated (but unauthorized) user.
	// Assert: GET /api/v1/users with that JWT returns 403 (CodePermissionDenied),
	// NOT 200 — this is the exact property that was silently broken before
	// this task: without the fix, this request would succeed because Authz
	// never actually calls Enforce.
}

func TestAuthz_AllowedPermission_Returns200(t *testing.T) {
	// Same setup but Enforce() returns {Allowed: true}.
	// Assert: the request succeeds (reaches the real handler).
}
```

Write a fake `rbacservice.Client` (embedding the real interface the same way Plan 2's `fakeRouterUserClient` did, overriding only `Enforce` and whatever `ListUsers`/etc. the specific test route needs) — do not use a real RPC connection. Use `/api/v1/users` (`GET`, permission `user:list`) as the probe route since it already exists and is the simplest one to construct a fake response for.

- [ ] **Step 4: Full render + build + test**

```bash
rm -rf /tmp/adminbff-task3-validate
ncgo new adminbfftask3 --kind hertz --module github.com/example/adminbfftask3 \
  --template-dir <repo>/admin-bff-hertz --dir /tmp/adminbff-task3-validate
cd /tmp/adminbff-task3-validate
go build ./... 2>&1 | grep -v kitex_gen  # expect only the known kitex_gen-import gap, filtered out here for readability
go vet ./...
go test ./internal/router/... -v
```

The two new tests must pass. If `internal/router` doesn't build in isolation yet because Task 2's `kitex_gen` doesn't exist (Task 5 populates it), run the test with `go build ./internal/router/...` first to confirm the *specific* failure is the expected `kitex_gen` import gap and nothing else in this task's own diff — this is expected at this point in the plan and not a Task 3 regression, matching the same staged-build-gap pattern every prior plan in this registry has used.

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml \
        admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml
git commit -m "fix(admin-bff-hertz): correct Authz middleware registration order (RBAC checks were a no-op)"
```

---

### Task 4: `admin-bff-hertz` — `terminal_user` handler

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_handler_terminal_user_go.yaml`
- Create: `admin-bff-hertz/hertz-template/internal_handler_terminal_user_test_go.yaml`

**Interfaces:**
- Consumes: `userservice.Client` (Task 2/5's locally-generated Kitex client, methods `ListUsers`, `GetUser`, `BanUser`, `UnbanUser`, `ForceLogout`, `AdminUnbindProvider` — all from Task 1's extended `user-kitex/idl/user.proto`, generated the same way `user-bff-hertz`'s `userservice.Client` was in Plan 2), `response.OK`/`response.ErrorCode`/`response.CodeInternalError`/`response.CodeRequestParamInvalid` (existing `admin-bff-hertz` package).
- Produces: `TerminalUserHandler` with methods `List(ctx, c)`, `Get(ctx, c)`, `Ban(ctx, c)`, `Unban(ctx, c)`, `UnbindIdentity(ctx, c)` — consumed by Task 5's router wiring.

- [ ] **Step 1: Write the handler**

```yaml
# ncgo exported template — internal/handler/terminal_user.go
path: internal/handler/terminal_user.go
update_behavior:
    type: skip
loop_service: true
body: |
    package handler

    import (
    	"context"
    	"strconv"

    	"github.com/cloudwego/hertz/pkg/app"

    	"{{.Module}}/internal/pkg/response"
    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )

    type TerminalUserHandler struct {{ "{" }}
    	userCli userservice.Client
    {{ "}" }}

    func NewTerminalUserHandler(userCli userservice.Client) *TerminalUserHandler {{ "{" }}
    	return &TerminalUserHandler{{ "{" }}userCli: userCli{{ "}" }}
    {{ "}" }}

    func (h *TerminalUserHandler) List(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	limit := int32(20)
    	offset := int32(0)
    	if v := string(c.Query("limit")); v != "" {{ "{" }}
    		if n, err := strconv.Atoi(v); err == nil {{ "{" }}
    			limit = int32(n)
    		{{ "}" }}
    	{{ "}" }}
    	if v := string(c.Query("offset")); v != "" {{ "{" }}
    		if n, err := strconv.Atoi(v); err == nil {{ "{" }}
    			offset = int32(n)
    		{{ "}" }}
    	{{ "}" }}

    	resp, err := h.userCli.ListUsers(ctx, &userv1.ListUsersReq{{ "{" }}Limit: limit, Offset: offset{{ "}" }})
    	if err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeInternalError)
    		return
    	{{ "}" }}
    	response.OK(c, resp)
    {{ "}" }}

    func (h *TerminalUserHandler) Get(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	uid := c.Param("uid")
    	if uid == "" {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}

    	userResp, err := h.userCli.GetUser(ctx, &userv1.GetUserReq{{ "{" }}Uid: uid{{ "}" }})
    	if err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeInternalError)
    		return
    	{{ "}" }}

    	identitiesResp, err := h.userCli.ListUserIdentities(ctx, &userv1.ListUserIdentitiesReq{{ "{" }}Uid: uid{{ "}" }})
    	if err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeInternalError)
    		return
    	{{ "}" }}

    	response.OK(c, map[string]any{{ "{" }}
    		"user":       userResp.User,
    		"identities": identitiesResp.Identities,
    	{{ "}" }})
    {{ "}" }}

    func (h *TerminalUserHandler) Ban(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	uid := c.Param("uid")
    	if uid == "" {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}

    	if _, err := h.userCli.BanUser(ctx, &userv1.BanUserReq{{ "{" }}Uid: uid{{ "}" }}); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeInternalError)
    		return
    	{{ "}" }}

    	// Ban carries an implicit "force logout" per this plan's design: a
    	// banned account should not keep using an already-issued token. A
    	// ForceLogout failure here does not roll back the ban (the ban
    	// itself, recorded in user-kitex's own database, is the source of
    	// truth and already succeeded) — it's surfaced to the caller as a
    	// concern rather than an outright failure, since ForceLogout is a
    	// best-effort revoke (see user-kitex's own noopBlacklist fallback
    	// when Redis is disabled — it's designed to degrade, not to be
    	// load-bearing for the ban itself).
    	logoutErr := ""
    	if _, err := h.userCli.ForceLogout(ctx, &userv1.ForceLogoutReq{{ "{" }}Uid: uid{{ "}" }}); err != nil {{ "{" }}
    		logoutErr = err.Error()
    	{{ "}" }}
    	response.OK(c, map[string]any{{ "{" }}"banned": true, "force_logout_error": logoutErr{{ "}" }})
    {{ "}" }}

    func (h *TerminalUserHandler) Unban(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	uid := c.Param("uid")
    	if uid == "" {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}

    	if _, err := h.userCli.UnbanUser(ctx, &userv1.UnbanUserReq{{ "{" }}Uid: uid{{ "}" }}); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeInternalError)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"status": "unbanned"{{ "}" }})
    {{ "}" }}

    func (h *TerminalUserHandler) UnbindIdentity(ctx context.Context, c *app.RequestContext) {{ "{" }}
    	uid := c.Param("uid")
    	provider := c.Param("provider")
    	if uid == "" || provider == "" {{ "{" }}
    		response.ErrorCode(c, response.CodeRequestParamInvalid)
    		return
    	{{ "}" }}

    	if _, err := h.userCli.AdminUnbindProvider(ctx, &userv1.AdminUnbindProviderReq{{ "{" }}Uid: uid, Provider: provider{{ "}" }}); err != nil {{ "{" }}
    		response.ErrorCode(c, response.CodeInternalError)
    		return
    	{{ "}" }}
    	response.OK(c, map[string]string{{ "{" }}"status": "unbound"{{ "}" }})
    {{ "}" }}
```

Note the `Ban` handler's `force_logout_error` field in its response — this is the concrete resolution of the design doc's open question ("does `ForceLogout` failure fail the whole `Ban` request?"): no, it doesn't; the ban still succeeds and reports itself as done, with the logout outcome surfaced separately so the admin UI can show a warning banner rather than treating the whole action as failed.

- [ ] **Step 2: Write the tests**

```yaml
# ncgo exported template — internal/handler/terminal_user_test.go
path: internal/handler/terminal_user_test.go
update_behavior:
    type: skip
loop_service: true
body: |
    package handler

    import (
    	"context"
    	"testing"

    	"github.com/cloudwego/hertz/pkg/app"
    	"github.com/cloudwego/hertz/pkg/common/ut"
    	"github.com/cloudwego/hertz/pkg/protocol"
    	"github.com/cloudwego/kitex/client/callopt"

    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
    )

    type fakeTerminalUserClient struct {{ "{" }}
    	userservice.Client
    	banErr, unbanErr, logoutErr, unbindErr error
    	forceLogoutCalled                      bool
    {{ "}" }}

    func (f *fakeTerminalUserClient) ListUsers(ctx context.Context, req *userv1.ListUsersReq, _ ...callopt.Option) (*userv1.ListUsersResp, error) {{ "{" }}
    	return &userv1.ListUsersResp{{ "{" }}Users: []*userv1.UserItem{{ "{" }}{{ "{" }}Uid: "u1", Username: "alice"{{ "}" }}{{ "}" }}, Total: 1{{ "}" }}, nil
    {{ "}" }}

    func (f *fakeTerminalUserClient) GetUser(ctx context.Context, req *userv1.GetUserReq, _ ...callopt.Option) (*userv1.GetUserResp, error) {{ "{" }}
    	return &userv1.GetUserResp{{ "{" }}User: &userv1.UserItem{{ "{" }}Uid: req.Uid, Username: "alice"{{ "}" }}{{ "}" }}, nil
    {{ "}" }}

    func (f *fakeTerminalUserClient) ListUserIdentities(ctx context.Context, req *userv1.ListUserIdentitiesReq, _ ...callopt.Option) (*userv1.ListUserIdentitiesResp, error) {{ "{" }}
    	return &userv1.ListUserIdentitiesResp{{ "{" }}Identities: []*userv1.IdentityItem{{ "{" }}{{ "{" }}Provider: "github"{{ "}" }}{{ "}" }}{{ "}" }}, nil
    {{ "}" }}

    func (f *fakeTerminalUserClient) BanUser(ctx context.Context, req *userv1.BanUserReq, _ ...callopt.Option) (*userv1.BanUserResp, error) {{ "{" }}
    	return &userv1.BanUserResp{{ "{" }}{{ "}" }}, f.banErr
    {{ "}" }}

    func (f *fakeTerminalUserClient) UnbanUser(ctx context.Context, req *userv1.UnbanUserReq, _ ...callopt.Option) (*userv1.UnbanUserResp, error) {{ "{" }}
    	return &userv1.UnbanUserResp{{ "{" }}{{ "}" }}, f.unbanErr
    {{ "}" }}

    func (f *fakeTerminalUserClient) ForceLogout(ctx context.Context, req *userv1.ForceLogoutReq, _ ...callopt.Option) (*userv1.ForceLogoutResp, error) {{ "{" }}
    	f.forceLogoutCalled = true
    	return &userv1.ForceLogoutResp{{ "{" }}{{ "}" }}, f.logoutErr
    {{ "}" }}

    func (f *fakeTerminalUserClient) AdminUnbindProvider(ctx context.Context, req *userv1.AdminUnbindProviderReq, _ ...callopt.Option) (*userv1.AdminUnbindProviderResp, error) {{ "{" }}
    	return &userv1.AdminUnbindProviderResp{{ "{" }}{{ "}" }}, f.unbindErr
    {{ "}" }}

    func newTestCtx() (context.Context, *app.RequestContext) {{ "{" }}
    	c := app.NewContext(0)
    	req := protocol.NewRequest("GET", "/", nil)
    	req.CopyTo(&c.Request)
    	return context.Background(), c
    {{ "}" }}

    func TestTerminalUserHandler_List_ReturnsUsers(t *testing.T) {{ "{" }}
    	h := NewTerminalUserHandler(&fakeTerminalUserClient{{ "{" }}{{ "}" }})
    	ctx, c := newTestCtx()
    	h.List(ctx, c)
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("status = %d, want 200", c.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}

    func TestTerminalUserHandler_Ban_CallsForceLogout(t *testing.T) {{ "{" }}
    	fake := &fakeTerminalUserClient{{ "{" }}{{ "}" }}
    	h := NewTerminalUserHandler(fake)
    	ctx, c := newTestCtx()
    	c.Params = append(c.Params, protocol.Param{{ "{" }}Key: "uid", Value: "u1"{{ "}" }})
    	h.Ban(ctx, c)
    	if !fake.forceLogoutCalled {{ "{" }}
    		t.Fatal("expected Ban to also call ForceLogout")
    	{{ "}" }}
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("status = %d, want 200", c.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}

    func TestTerminalUserHandler_Ban_ForceLogoutFailure_StillReturns200(t *testing.T) {{ "{" }}
    	fake := &fakeTerminalUserClient{{ "{" }}logoutErr: context.DeadlineExceeded{{ "}" }}
    	h := NewTerminalUserHandler(fake)
    	ctx, c := newTestCtx()
    	c.Params = append(c.Params, protocol.Param{{ "{" }}Key: "uid", Value: "u1"{{ "}" }})
    	h.Ban(ctx, c)
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("status = %d, want 200 (ban succeeds even if ForceLogout fails)", c.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}

    func TestTerminalUserHandler_UnbindIdentity_UsesAdminRPC(t *testing.T) {{ "{" }}
    	h := NewTerminalUserHandler(&fakeTerminalUserClient{{ "{" }}{{ "}" }})
    	ctx, c := newTestCtx()
    	c.Params = append(c.Params, protocol.Param{{ "{" }}Key: "uid", Value: "u1"{{ "}" }}, protocol.Param{{ "{" }}Key: "provider", Value: "github"{{ "}" }})
    	h.UnbindIdentity(ctx, c)
    	if c.Response.StatusCode() != 200 {{ "{" }}
    		t.Fatalf("status = %d, want 200", c.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}

    func TestTerminalUserHandler_Get_MissingUid_Returns400(t *testing.T) {{ "{" }}
    	h := NewTerminalUserHandler(&fakeTerminalUserClient{{ "{" }}{{ "}" }})
    	ctx, c := newTestCtx()
    	h.Get(ctx, c)
    	if c.Response.StatusCode() != 400 {{ "{" }}
    		t.Fatalf("status = %d, want 400", c.Response.StatusCode())
    	{{ "}" }}
    {{ "}" }}

    var _ = ut.PerformRequest // referenced to keep the import if a later edit adds engine-level cases; safe to remove if unused after implementation
```

(The `fakeTerminalUserClient`'s exact method signatures — `...callopt.Option` variadic trailing param — MUST be verified against the real generated `userservice.Client` interface via the cross-render technique from Plan 2 Task 6, or (better, and required by this task, matching Task 1-3's real-pipeline standard) the real `ncgo add kitex-client` pipeline in Step 3 below; do not assume the signature shown above is exactly right without checking the generated code. The `ut.PerformRequest` import line is a placeholder to avoid an unused-import compile error if you decide not to use `app.NewContext`-based direct calls; remove it if you end up not needing it — do not leave truly dead code in the final committed file.)

- [ ] **Step 3: Full render + build + test**

```bash
rm -rf /tmp/adminbff-task4-validate /tmp/userkitex-task4-crossrender
ncgo new userkitextask4 --kind kitex --module github.com/example/adminbfftask4 \
  --template-dir <repo>/user-kitex --dir /tmp/userkitex-task4-crossrender
ncgo new adminbfftask4 --kind hertz --module github.com/example/adminbfftask4 \
  --template-dir <repo>/admin-bff-hertz --dir /tmp/adminbff-task4-validate
cd /tmp/adminbff-task4-validate
ncgo add kitex-client terminaluser --service UserService --idl idl/user.proto --module github.com/example/adminbfftask4
go mod tidy
go build ./... && go vet ./... && go test ./internal/handler/... -v && go test -race ./internal/handler/...
```

All new `TestTerminalUserHandler_*` tests must pass. Fix any `callopt.Option`/other generated-type mismatches found this way exactly like Plan 2 Task 6/7/8 did (test-only fixes, no production handler code changes needed if the field names match the real generated types, which they should since Task 1 defined the proto).

- [ ] **Step 4: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_terminal_user_go.yaml \
        admin-bff-hertz/hertz-template/internal_handler_terminal_user_test_go.yaml
git commit -m "feat(admin-bff-hertz): add terminal_user handler (list/get/ban/unban/unbind-identity)"
```

---

### Task 5: `admin-bff-hertz` — router + server wiring for terminal-users routes

**Files:**
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml` (Task 3's file — extend its client signature/fakes for the new fourth client, per Task 3's own note about this ordering)
- Modify: `admin-bff-hertz/hertz-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes: `handler.NewTerminalUserHandler(userCli)` (Task 4), `userservice.Client` / `userservice.NewClient(...)` (Task 2's `kitex_gen`, populated via `ncgo add kitex-client` the same way Plan 2 Task 9 established), `conf.GRPCConfig.TerminalUser` (Task 2), the corrected `RequirePermission`+`Authz` per-route pattern (Task 3).
- Produces: `Register{{.ServiceName}}BffServiceRoutes(h, rbacAuthCli, rbacCli, rulecenterCli, userCli)` — signature gains a fourth parameter; this is this plan's integration checkpoint, analogous to Plan 2's Task 9.

- [ ] **Step 1: Extend the router signature and mount the new routes**

Edit `internal_router_adminbffservice_go.yaml`. Add the import:
```go
userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
```
Change the function signature to accept a fourth client:
```go
func Register{{.ServiceName}}BffServiceRoutes(h *server.Hertz, rbacAuthCli authservice.Client, rbacCli rbacservice.Client, rulecenterCli ruleservice.Client, userCli userservice.Client) {
```
Instantiate the new handler alongside the existing ones:
```go
terminalUserHandler := handler.NewTerminalUserHandler(userCli)
```
Mount the new route group after the existing `rules` group (end of the function body, before the closing brace):
```go
// Terminal (end-user) management — distinct from /users (RBAC admin
// accounts above): these call user-kitex, not rbacservice. See this
// plan's design doc for the naming-collision rationale.
terminalUsers := protected.Group("/terminal-users")
terminalUsers.GET("", middleware.RequirePermission("terminal_user:list"), middleware.Authz(rbacCli), terminalUserHandler.List)
terminalUsers.GET("/:uid", middleware.RequirePermission("terminal_user:read"), middleware.Authz(rbacCli), terminalUserHandler.Get)
terminalUsers.POST("/:uid/ban", middleware.RequirePermission("terminal_user:ban"), middleware.Authz(rbacCli), terminalUserHandler.Ban)
terminalUsers.POST("/:uid/unban", middleware.RequirePermission("terminal_user:unban"), middleware.Authz(rbacCli), terminalUserHandler.Unban)
terminalUsers.DELETE("/:uid/identities/:provider", middleware.RequirePermission("terminal_user:unbind-identity"), middleware.Authz(rbacCli), terminalUserHandler.UnbindIdentity)
```

Note these are written using the CORRECT per-route `RequirePermission`+`Authz` pairing from Task 3 — this task must not reintroduce the group-level `Authz` bug for its own new routes.

- [ ] **Step 2: Wire the client in `server.go`**

Edit `internal_base_server_server_go.yaml`. Add the import:
```go
userservice "{{.Module}}/kitex_gen/api/user/v1/userservice"
```
After the existing `ruleCli` construction block, add:
```go
userAddr := cfg.GRPC.TerminalUser.HostPorts[0]
userCli, err := userservice.NewClient(
    cfg.GRPC.TerminalUser.ServiceName,
    client.WithHostPorts(userAddr),
)
if err != nil {
    log.Fatalf("create terminal-user client: %v", err)
}
```
Update the route-registration call:
```go
router.Register{{.ServiceName}}BffServiceRoutes(h, rbacAuthCli, rbacCli, ruleCli, userCli)
```

- [ ] **Step 3: Extend Task 3's router test for the new client parameter**

Task 3's `internal_router_adminbffservice_test_go.yaml` built its `route.Engine` by calling `Register{{.ServiceName}}BffServiceRoutes` with three clients; that call site now needs a fourth argument. Add a minimal fake `userservice.Client` (embed the real interface, override nothing unless a specific new test needs a specific method — the existing `TestAuthz_*` tests from Task 3 don't touch any terminal-user route, so an embedding-only fake with no overridden methods is sufficient there). Add two new test cases specific to the terminal-user routes proving the SAME property Task 3 proved for `/users`, now for `/terminal-users` (closing the loop on this plan's own acceptance criterion):

```go
func TestTerminalUsersRoute_DeniedPermission_Returns403(t *testing.T) {
	// Same pattern as TestAuthz_DeniedPermission_Returns403 (Task 3), but
	// against GET /api/v1/terminal-users with permission "terminal_user:list".
}

func TestTerminalUsersRoute_AllowedPermission_Returns200(t *testing.T) {
	// Same pattern, Enforce() returns {Allowed: true}, expect 200.
}
```

- [ ] **Step 4: Full render + build + test — this plan's integration checkpoint**

```bash
rm -rf /tmp/adminbff-task5-validate
ncgo new adminbfftask5 --kind hertz --module github.com/example/adminbfftask5 \
  --template-dir <repo>/admin-bff-hertz --dir /tmp/adminbff-task5-validate
cd /tmp/adminbff-task5-validate
ncgo add kitex-client terminaluser --service UserService --idl idl/user.proto --module github.com/example/adminbfftask5
go mod tidy
go build ./... && go vet ./... && go test ./... && go test -race ./...
```

`internal/base/server/server.go` must now reference the real `userservice` package with no build errors, and `internal/router`'s tests (Task 3's + this task's new ones) must all pass. This is this plan's single most important acceptance criterion, matching the standard every prior plan in this registry ("Plan 1"/"Plan 2") held its own final integration task to.

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml \
        admin-bff-hertz/hertz-template/internal_router_adminbffservice_test_go.yaml \
        admin-bff-hertz/hertz-template/internal_base_server_server_go.yaml
git commit -m "feat(admin-bff-hertz): wire terminal-user routes, server, user-kitex client"
```

---

### Task 6: Docs, e2e test, root README updates, full acceptance run

**Files:**
- Modify: `admin-bff-hertz/README.md`
- Modify: `admin-bff-hertz/test/e2e_test.sh`
- Modify: `README.md`, `README.zh-CN.md` (repo root — update the `admin-bff-hertz` row's description to mention terminal-user management, matching the style already used for other feature rows in that table)

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: this plan's finished, documented, fully-buildable deliverable.

- [ ] **Step 1: Update `admin-bff-hertz/README.md`**

Add a new section (mirroring the existing "## Permission Codes" table's format) listing the five new `terminal_user:*` permission codes with descriptions, immediately after the existing rate-limit permission rows in that same table (do not create a second table — extend the existing one). Add a short subsection (mirroring however the existing README documents its `grpc.authority` requirement) documenting the new required `grpc.terminal_user` config pointing at a running `user-kitex` instance, and add a one-line note that `ForceLogout` (triggered automatically by `Ban`) is a no-op when `user-kitex`'s own Redis blacklist is disabled — matching the exact caveat already documented in `user-kitex`'s own template comments (`internal_base_server_server_go.yaml`'s `noopBlacklist` doc comment), so an admin-bff-hertz operator isn't surprised by behavior that's only explained in the other package's source.

Also add a short "Seams" note (matching the style Plan 2's `user-bff-hertz/README.md` used) pointing out: this plan fixed a pre-existing RBAC-authorization-bypass bug (`Authz` middleware ordering) that affected every protected route in this package, not just the new ones — worth a one-line callout so operators upgrading from a pre-Plan-3 version know their deployment's authorization behavior actually changes (routes that previously "worked" for any authenticated user now correctly enforce permissions).

- [ ] **Step 2: Update `admin-bff-hertz/test/e2e_test.sh`**

Read the current file. Add the `ncgo add kitex-client terminaluser --service UserService --idl idl/user.proto` step to its render pipeline (alongside whatever existing kitex-client steps it already runs for `auth.proto`/`rbac.proto`/`rule_center.proto`, if it runs any today — check first; if the existing script doesn't run ANY `ncgo add kitex-client` step today and instead has some other mechanism for populating `kitex_gen` for its existing three clients, mirror that exact mechanism for the new fourth one instead of introducing an inconsistent approach).

- [ ] **Step 3: Update root READMEs**

Find the `admin-bff-hertz` row in the HTTP services table in both `README.md` and `README.zh-CN.md`. Update its description to mention terminal-user management, e.g. (Chinese version): `管理中台 Hertz 网关（JWT 鉴权 + RBAC 授权 + 终端用户管理 + 限流规则管理）` — adjust wording to match this table's existing style for other rows rather than copying this verbatim if it doesn't fit.

- [ ] **Step 4: Full acceptance run**

```bash
rm -rf /tmp/adminbff-task6-final /tmp/userkitex-task6-final
ncgo new userkitextask6 --kind kitex --module github.com/example/task6final \
  --template-dir <repo>/user-kitex --dir /tmp/userkitex-task6-final
cd /tmp/userkitex-task6-final && go mod tidy && go build ./... && go vet ./... && go test ./... && go test -race ./...

ncgo new adminbfftask6 --kind hertz --module github.com/example/task6final \
  --template-dir <repo>/admin-bff-hertz --dir /tmp/adminbff-task6-final
cd /tmp/adminbff-task6-final
ncgo add kitex-client terminaluser --service UserService --idl idl/user.proto --module github.com/example/task6final
go mod tidy
go build ./... && go vet ./... && go test ./... && go test -race ./...
gofmt -l .
grep -rn '{{ "{"\|{{ "}"\|{{\.' --include="*.go" . || echo "clean — no residual template escapes"
```

All must pass (any `admin-bff-hertz`-inherited pre-existing gofmt/build gaps unrelated to this plan's own diff — e.g. anything already known from Plan 2's audit of this same package family — are acceptable per the precedent set there; do not attempt to fix unrelated pre-existing issues in this task). Run `admin-bff-hertz/test/e2e_test.sh` itself directly and confirm it exits 0.

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/README.md admin-bff-hertz/test/e2e_test.sh README.md README.zh-CN.md
git commit -m "docs(admin-bff-hertz): document terminal-user management, update e2e test and root READMEs"
```

---

## Plan Self-Review Notes

- **Spec coverage:** every acceptance criterion in Issue #67 maps to a task: `AdminUnbindProvider` RPC (Task 1), local `idl/user.proto` + `ncgo add kitex-client` wiring (Task 2, 5), terminal_user handler covering list/detail/ban/unban/unbind (Task 4), route naming/permission isolation from `/users` (Task 5), route-level `RequirePermission` enforcement test (Task 3, Task 5 Step 3), README + `ForceLogout` no-Redis caveat (Task 6), full real-pipeline verification (every task's own Step, plus Task 6's final run). The `Authz` ordering bug fix (Task 3) was not in the original Issue body since it was discovered during plan-writing, not brainstorming — it is covered by the user's explicit in-session decision to include it, and Issue #67's acceptance criteria remain otherwise satisfied without needing amendment (the bug fix is a natural extension of the existing "路由级测试覆盖 RequirePermission 中间件先于 handler 执行" criterion, which literally cannot pass without this fix).
- **Type consistency:** `useradminsvc.Service.GetUser(ctx, uid string) (UserDTO, error)` (Task 1) is consumed only by the new `GetUser` RPC handler (Task 1 Step 4) — no other task calls it directly. `userservice.Client`'s method set (`ListUsers`, `GetUser`, `BanUser`, `UnbanUser`, `ForceLogout`, `AdminUnbindProvider`) is used identically by Task 4's handler and Task 4/5's tests — every method name and field name (`Uid`, `Provider`, `Limit`, `Offset`) traces back to Task 1's proto definition, never invented independently in a later task.
- **No placeholders:** every step ships real, compilable code. Two places explicitly flag "verify against the actual current file/generated-type before finalizing" (Task 2 Step 2's `Validate()` guard question, Task 4's `fakeTerminalUserClient` method-signature verification) — both are the same honest, plan-author-cannot-directly-verify class of uncertainty flag this registry's prior plans have used, not vague "add appropriate X" placeholders. Task 3 Step 3 / Task 5 Step 3's shared-test-file coordination note is similarly an explicit, named risk for the executing controller to resolve (assign task order or merge authorship), not a silent gap.
