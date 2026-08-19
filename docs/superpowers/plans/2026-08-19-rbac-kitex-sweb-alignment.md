# rbac-kitex s-web Alignment Revision Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Revise the existing rbac-kitex seed project to reflect the 6 s-web alignment decisions locked in ncgo PR#78, then re-export the template.

**Architecture:** Modify the seed project at `.cache/rbac-seed/rbac-rpc/` (proto + SQL + DDD layers + handlers) → make build+test green → `ncgo export templates --kind kitex` → replace `rbac-kitex/` template YAML files → update proto + e2e test + README.

**Spec:** Upstream: `ncgo` repo `docs/superpowers/specs/2026-08-19-rbac-kitex-alignment-decisions.md` + `docs/superpowers/plans/2026-08-18-rbac-kitex-template.md` + `docs/superpowers/specs/2026-08-18-rbac-kitex-design.md`.

## Global Constraints

- All 6 locked decisions must be reflected (see upstream decisions doc §1-§6).
- Seed project must pass `make sqlc` + `go build ./...` + `go test ./...` after each task.
- Do NOT touch infrastructure/ (casbin adapter, JWT, argon2, token store, audit) unless directly impacted.
- Do NOT change Casbin model — zero impact per decisions doc §5.
- `role_permissions` table keeps `permission_id` FK (RPC only exposes codes).
- Template YAML files are GENERATED — edit the seed, then re-export.

---

## Task 1: Proto revision (seed `idl/auth.proto`)

**Files:**
- Modify: `.cache/rbac-seed/rbac-rpc/idl/auth.proto`

**Delta:**
- Remove: `CreateMenu`, `UpdateMenu`, `DeleteMenu` RPCs + their Req/Resp messages
- Add: `UpdatePermission`, `GetPermission` RPCs + their Req/Resp messages
- Expand: `Permission` message (16 fields — single tree shape: type, parent_id, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, method, sort, status, description)
- Expand: `CreatePermissionReq` (match Permission fields minus id)
- Add: `UpdatePermissionReq` (all optional fields)
- Add: `GetPermissionReq { int64 id = 1; }`
- Expand: `ListPermissionsReq` (add optional type/parent_id/status filters)
- Expand: `User` message (add nickname, avatar, email, phone; change status string→int32)
- Expand: `CreateUserReq` / `UpdateUserReq` (add new fields)
- Expand: `Role` message (add status int32, remark string, permissions []string)
- Expand: `CreateRoleReq` (add remark), `UpdateRoleReq` (add optional status, remark)
- Revise: `Menu` message (single tree view shape: code, name, parent_id, type catalog|menu, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, sort)
- Remove: `CreateMenuReq`, `UpdateMenuReq`, `DeleteMenuReq`
- Revise: `GrantPermissionsToRoleReq` (permission_ids → permission_codes)
- Keep: `ListMenusReq`, `MenuResp`, `ListMenusResp`, `AssignRolesToUserReq`, `Enforce*`, `GetUserMenuTree*`, `GetUserPermCodes*`

- [ ] **Step 1:** Edit proto per delta above
- [ ] **Step 2:** `cd .cache/rbac-seed/rbac-rpc && make update` (kitex codegen)
- [ ] **Step 3:** Verify generated `kitex_gen/` compiles: `go build ./...` (expect handler failures — OK for now)
- [ ] **Step 4:** Commit: `feat(seed): revise proto for s-web alignment`

---

## Task 2: SQL revision (seed DDL + queries)

**Files:**
- Modify: `.cache/rbac-seed/rbac-rpc/internal/db/migrations/000001_init.sql`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/db/query/rbac.sql`

**DDL Delta:**
- `users`: add nickname/avatar/email/phone (TEXT NULL), change status to `INTEGER NOT NULL DEFAULT 1`
- `roles`: add `status INTEGER NOT NULL DEFAULT 1`, `remark TEXT NULL`, `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`
- `permissions`: replace with single tree (type, parent_id self-FK, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, method, sort, status, description); `UNIQUE(code, type)`; add indexes on parent_id + type
- DELETE `menus` table + `idx_menus_parent`
- `user_roles`, `role_permissions`, `casbin_rule`, `audit_log`: unchanged

**Query Delta:**
- Update: `CreateUser`, `UpdateUser` (new fields)
- Update: `CreateRole`, `UpdateRole` (status + remark)
- Remove: `CreateMenu`, `GetMenuByID`, `ListMenus`, `UpdateMenu`, `DeleteMenu`, `ListMenusByPermCodes`
- Add: `ListMenusAsTree`, `ListMenusByParentID` (read-only view over permissions)
- Revise: `CreatePermission` (15 cols), `UpdatePermission` (new), `GetPermissionByCode` → :many, `GetPermissionByCodeAndType` → :one, `ListPermissionsFiltered`, `ListChildPermissionIDs`
- Revise: `ListPermissionIDsByRoleID` → `ListPermissionCodesByRoleID` (return codes via join)
- Add: `ListPermissionIDsByCodes` (for GrantPermissionsToRole resolution)
- Table count: 8 → 7

- [ ] **Step 1:** Edit migration DDL
- [ ] **Step 2:** Edit query file
- [ ] **Step 3:** `make sqlc` — verify sqlc generates cleanly
- [ ] **Step 4:** Commit: `feat(seed): revise SQL for s-web alignment`

---

## Task 3: Domain layer revision

**Files:**
- Modify: `.cache/rbac-seed/rbac-rpc/internal/domain/permission/{entity,valueobject,repository}.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/domain/permission/entity_test.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/domain/menu/{entity,service,repository}.go`
- Rename: `menu/service.go` → `menu/query_service.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/domain/menu/entity_test.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/domain/user/entity.go` (status int, new fields)
- Modify: `.cache/rbac-seed/rbac-rpc/internal/domain/role/entity.go` (status, remark)

**Permission aggregate (expand):**
- Entity: 16 fields (ID, Code, Type, Name, ParentID, Path, Icon, RouteName, Redirect, KeepAlive, HideInMenu, IsExternal, Method, Sort, Status, Description)
- Type constants: TypeCatalog, TypeMenu, TypeButton, TypeAPI
- Status constants: StatusEnabled (1), StatusDisabled (0)
- `New()` validation: type ∈ {catalog,menu,button,api}; when type=api, method required ∈ {GET,POST,PUT,DELETE}
- Repository port adds: `GetByCodeAndType`, `ListChildren` (cascade), `ListByCodes`

**Menu aggregate (degrade to read-only):**
- Rename `service.go` → `query_service.go`
- `QueryService` with `ListMenusAsTree` + `GetUserMenuTree`
- Remove write methods from Repository port; keep only `ListMenusAsTree`, `ListMenusByParentID`
- `Node` + `BuildTree` preserved (pure function)

**User aggregate:**
- Status: `string` → `int` (StatusEnabled/StatusDisabled)
- Add fields: Nickname, Avatar, Email, Phone

**Role aggregate:**
- Add: Status int, Remark string
- `Assign()` domain rule: accepts `permissionCodes []string` instead of `permissionIDs []int64`

- [ ] **Step 1:** Write failing tests for new permission validation
- [ ] **Step 2:** Implement domain changes
- [ ] **Step 3:** `go test ./internal/domain/... -count=1` → PASS
- [ ] **Step 4:** Commit: `feat(seed): revise DDD domain for s-web alignment`

---

## Task 4: Repository layer revision

**Files:**
- Modify: `.cache/rbac-seed/rbac-rpc/internal/repository/{permission,menu,user,role}/repo.go`

**Delta:**
- `permission.Repo`: add `GetByCodeAndType`, `ListChildren`, `ListByCodes`, `Update`; match new sqlc query names
- `menu.Repo`: read-only — `ListMenusAsTree`, `ListMenusByParentID`; remove all write methods
- `user.Repo`: `Create`/`Update` support new fields; `status` int
- `role.Repo`: `Create`/`Update` support status + remark; add `ListPermissionCodesByRoleID`

- [ ] **Step 1:** Implement repo changes per delta
- [ ] **Step 2:** `go build ./internal/repository/...` → PASS
- [ ] **Step 3:** Commit: `feat(seed): revise repositories for s-web alignment`

---

## Task 5: Application services revision

**Files:**
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/permission/{permission_service,dto}.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/permission/permission_service_test.go`
- Rename: `menu/menu_service.go` → `menu/menu_query_service.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/menu/{dto,menu_query_service}.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/menu/menu_service_test.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/role/{role_service,dto}.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/role/role_service_test.go`
- Modify: `.cache/rbac-seed/rbac-rpc/internal/application/user/{user_service,dto}.go`

**Delta:**
- `permission.Service`: add `Update(ctx, cmd)` + `Get(ctx, id)`; `Delete` cascades via `ListChildren` recurse; `Create` validates type
- `menu.QueryService`: remove `Create/Update/Delete`; keep `ListMenus` + `GetUserMenuTree` + `UserPermCodes`
- `role.Service`: `GrantPermissions(ctx, roleID, permissionCodes []string)` — resolves codes via `ListByCodes`; unknown code → domain error
- `user.Service`: `Create`/`Update` accept new fields; status int

- [ ] **Step 1:** Write failing tests for new service methods
- [ ] **Step 2:** Implement service changes
- [ ] **Step 3:** `go test ./internal/application/... -count=1` → PASS
- [ ] **Step 4:** Commit: `feat(seed): revise app services for s-web alignment`

---

## Task 6: Handlers + server wiring revision

**Files:**
- Modify: `.cache/rbac-seed/rbac-rpc/internal/handler/rbacservice/handler.go`
- Remove: `CreateMenu`, `UpdateMenu`, `DeleteMenu` handler methods
- Add: `UpdatePermission`, `GetPermission` handler methods
- Modify: `GrantPermissionsToRole` handler — uses `req.PermissionCodes`
- Modify: handler struct field `menu *menu.Service` → `menuQuery *menu.QueryService`

- [ ] **Step 1:** Edit handlers
- [ ] **Step 2:** `go build ./...` → PASS
- [ ] **Step 3:** `go test ./... -count=1` → PASS
- [ ] **Step 4:** Commit: `feat(seed): revise handlers + wiring for s-web alignment`

---

## Task 7: Re-export template

- [ ] **Step 1:** `cd .cache/rbac-seed/rbac-rpc && make sqlc && make update && go build ./... && go test ./... -count=1`
- [ ] **Step 2:** From ncgo-templates root: `ncgo export templates --kind kitex --source .cache/rbac-seed/rbac-rpc --output /tmp/rbac-kitex-export` (verify exact flags)
- [ ] **Step 3:** Compare exported YAML with existing `rbac-kitex/kitex-template/` — verify delta matches expectations
- [ ] **Step 4:** Replace `rbac-kitex/kitex-template/*.yaml` with exported files
- [ ] **Step 5:** Copy `idl/auth.proto` → `rbac-kitex/idl/auth.proto`
- [ ] **Step 6:** Commit: `feat(rbac-kitex): re-export template after s-web alignment`

---

## Task 8: E2E test + README update

**Files:**
- Modify: `rbac-kitex/test/e2e_test.sh`
- Modify: `rbac-kitex/README.md`

**E2E delta:**
- Add structural assertions: proto has `UpdatePermission` + `GetPermission`; proto has no `CreateMenu`/`UpdateMenu`/`DeleteMenu`; SQL has no `menus` table; SQL has `UNIQUE(code, type)` in permissions

**README delta:**
- Update data model description: single permissions tree, 7 tables
- Update RPC surface: UpdatePermission/GetPermission present, Menu CRUD removed
- Update field lists for User/Role/Permission

- [ ] **Step 1:** Update e2e test assertions
- [ ] **Step 2:** Update README
- [ ] **Step 3:** `bash rbac-kitex/test/e2e_test.sh` → PASS
- [ ] **Step 4:** Commit: `test(rbac-kitex): update e2e + README for s-web alignment`

---

## Verification Checklist

- [ ] `go build ./...` PASS in seed project
- [ ] `go test ./... -count=1` PASS in seed project
- [ ] `make sqlc` PASS in seed project
- [ ] `bash rbac-kitex/test/e2e_test.sh` PASS
- [ ] Proto: no CreateMenu/UpdateMenu/DeleteMenu; has UpdatePermission/GetPermission
- [ ] SQL: no menus table; permissions has UNIQUE(code, type); 7 tables total
- [ ] GrantPermissionsToRoleReq uses permission_codes (not permission_ids)
- [ ] User.status is int32 (not string)
- [ ] Role has status + remark fields
- [ ] Permission entity has 16 fields (single tree)
