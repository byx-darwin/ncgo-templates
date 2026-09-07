# Issue #48: Casbin Delete-Cascade Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close two Casbin-cleanup gaps found in the #39 final-review pass — `permission.Service.Delete`'s cascade never touches Casbin for child permissions, and `role.Service.Delete` never touches Casbin at all — mirrored identically across `rbac-kitex` and `admin-services-kitex`.

**Architecture:** No new components. Both fixes extend existing `Service.Delete` methods with additional Casbin enforcer calls, following the already-established error-handling pattern from #39 (`klog.CtxErrorf` on cleanup failure, never fail the request). `role.Service`'s narrow `Enforcer` port gains one new method (`RemoveFilteredGroupingPolicy`) backed by the real `*casbin.Enforcer` (no adapter changes needed — it's a type alias over the upstream library, which already implements this method).

**Tech Stack:** Go, casbin/casbin v2 (RBAC model `p = sub,obj,act` / `g = _,_`), Kitex-generated service scaffolding stored as ncgo `.yaml` template sources (`body:` block is the literal `.go` file content, `{{ "{" }}`/`{{ "}" }}` escape literal braces).

**Spec:** `docs/superpowers/specs/2026-09-07-issue48-casbin-delete-cascade-design.md`

## Global Constraints

- Casbin cleanup failures MUST NOT fail the delete request — log via `klog.CtxErrorf` and continue (established in #39; see referenced spec's "Design Decision").
- Every change must be applied identically to **both** `rbac-kitex/kitex-template/...` and `admin-services-kitex/kitex-template/...` (files are currently byte-identical; keep them that way).
- `role.Service.Delete` fetches the role (`GetByID`) **before** calling `roles.Delete`, since the Code is needed for the Casbin calls afterward.
- `permission.Service.cascadeDelete` must call `RemoveFilteredPolicy(1, code)` for every node it deletes (children AND the top-level node), not just the top-level one — the existing top-level call in `Delete` is removed in favor of a single path through `cascadeDelete`.
- `g` binding cleanup (`RemoveFilteredGroupingPolicy(1, r.Code)`) is REQUIRED per the approved design (cascade-clean role bindings on role delete).

---

### Task 1: `permission.Service` — cascade Casbin cleanup for all deleted nodes (rbac-kitex)

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml` (the `body:` block, which is `internal/application/permission/permission_service.go`)
- Test: `rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml` (the `body:` block, which is `internal/application/permission/permission_service_test.go`)

**Interfaces:**
- Consumes: existing `PermRepo.ListChildren(ctx, parentID) ([]*permission.Permission, error)`, `PermRepo.Delete(ctx, id) error`, `Enforcer.RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error)` — no interface changes.
- Produces: `cascadeDelete(ctx, parentID int64) error` now also cleans Casbin for every deleted node (signature unchanged, callable the same way from `Delete`).

Both files use YAML `body: |` block scalars containing literal Go source; `{{ "{" }}` / `{{ "}" }}` are Go template escapes for literal `{` / `}` (already present throughout the file — preserve this convention in any new code).

- [ ] **Step 1: Write the failing test — cascade cleans Casbin policy for a grandchild permission**

In `rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`, inside the `body: |` block, add after `TestDeleteRemovesCasbinPolicy` (before the `errEnforcer` type):

```go
    func TestDeleteCascadeRemovesCasbinPolicyForChildren(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, e, _ := newPermService(t)

    	parent, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "system", Type: permission.TypeCatalog, Name: "System"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create parent: %v", err)
    	{{ "}" }}
    	child, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "system:user:delete", Type: permission.TypeAPI, Name: "Delete User", ParentID: fmt.Sprint(parent.ID), Method: "DELETE"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create child: %v", err)
    	{{ "}" }}
    	if _, err := e.AddPolicy("admin", child.Code, "DELETE"); err != nil {{ "{" }}
    		t.Fatalf("AddPolicy: %v", err)
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", child.Code, "DELETE"); !allowed {{ "{" }}
    		t.Fatal("Enforce before delete = false, want true")
    	{{ "}" }}

    	if err := svc.Delete(ctx, fmt.Sprint(parent.ID)); err != nil {{ "{" }}
    		t.Fatalf("Delete: %v", err)
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", child.Code, "DELETE"); allowed {{ "{" }}
    		t.Fatal("Enforce(child) after cascade delete = true, want false")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run (inside the generated `rbac-kitex` project, i.e. wherever the ncgo template renders/lives for local `go test` — see repo conventions if unsure which directory holds the rendered Go module): `go test ./internal/application/permission/... -run TestDeleteCascadeRemovesCasbinPolicyForChildren -v`
Expected: FAIL — `Enforce(child) after cascade delete = true, want false` (child policy still present, since only the top-level code is cleaned today).

- [ ] **Step 3: Write minimal implementation**

In `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`, replace the `Delete` and `cascadeDelete` bodies:

```go
    // Delete removes a permission and cascades to children (tree semantics).
    // Also removes stale Casbin policies for the permission and every
    // descendant it cascades to.
    func (s *Service) Delete(ctx context.Context, id string) error {{ "{" }}
    	pid, err := strconv.ParseInt(id, 10, 64)
    	if err != nil {{ "{" }}
    		return permission.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	p, err := s.perms.GetByID(ctx, pid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	// Cascade: delete children recursively (DFS post-order), cleaning
    	// Casbin policy for every node along the way (including this one).
    	if err := s.cascadeDelete(ctx, pid); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "permission.delete", p.Code, "{{ "{" }}{{ "}" }}")
    	return nil
    {{ "}" }}

    func (s *Service) cascadeDelete(ctx context.Context, parentID int64) error {{ "{" }}
    	children, err := s.perms.ListChildren(ctx, parentID)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	for _, child := range children {{ "{" }}
    		if err := s.cascadeDelete(ctx, child.ID); err != nil {{ "{" }}
    			return err
    		{{ "}" }}
    	{{ "}" }}
    	p, err := s.perms.GetByID(ctx, parentID)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if err := s.perms.Delete(ctx, parentID); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if _, err := s.enforcer.RemoveFilteredPolicy(1, p.Code); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "permission.delete: remove casbin policies for permission %s failed: %v", p.Code, err)
    	{{ "}" }}
    	return nil
    {{ "}" }}
```

Note: `cascadeDelete` now fetches the node via `GetByID` *before* deleting it (to read `Code` for the Casbin call) — the existing `TestDeleteCasbinCleanupErrorDoesNotFailRequest` test's `fakePermRepo` already supports `GetByID` after `Create`, so no fake changes are needed there.

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/application/permission/... -v`
Expected: PASS — all tests including `TestDeleteCascadeRemovesCasbinPolicyForChildren`, `TestDeleteCascadesChildren`, `TestDeleteRemovesCasbinPolicy`, `TestDeleteCasbinCleanupErrorDoesNotFailRequest`.

- [ ] **Step 5: Commit**

```bash
git add rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml
git commit -m "fix(rbac-kitex): cascade Casbin policy cleanup to all deleted child permissions"
```

---

### Task 2: `permission.Service` — mirror Task 1 in admin-services-kitex

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Test: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`

**Interfaces:** identical to Task 1 (files are byte-identical mirrors).

- [ ] **Step 1: Diff-verify the two source files are still identical before editing**

Run: `diff rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml && diff rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`
Expected: no output (both pairs identical) — confirms it's safe to apply the same edit verbatim.

- [ ] **Step 2: Apply the identical Step 1/3 edits from Task 1 to the `admin-services-kitex` copies**

Copy the same test addition and the same `Delete`/`cascadeDelete` replacement into `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml` and its test file.

- [ ] **Step 3: Run test to verify it passes**

Run (in the `admin-services-kitex` rendered module directory): `go test ./internal/application/permission/... -v`
Expected: PASS.

- [ ] **Step 4: Verify the two repos are byte-identical again**

Run: `diff rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml && diff rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml
git commit -m "fix(admin-services-kitex): cascade Casbin policy cleanup to all deleted child permissions"
```

---

### Task 3: `role.Service.Delete` — clean up p policies and g bindings (rbac-kitex)

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Test: `rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`

**Interfaces:**
- Consumes: `RoleRepo.GetByID(ctx, id) (*role.Role, error)` (already in interface), `RoleRepo.Delete(ctx, id) error` (already in interface).
- Produces: `Enforcer` interface gains `RemoveFilteredGroupingPolicy(fieldIndex int, fieldValues ...string) (bool, error)`. Backed at call sites by the real `*casbin.Enforcer` (upstream `casbin/casbin/v2` `Enforcer` already implements this — no adapter/infra changes).

- [ ] **Step 1: Write the failing tests — Delete cleans p policy and g binding**

In `rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`, inside the `body: |` block, add after `TestUpdateRejectsNonIntegerID` (before the `errEnforcer` type):

```go
    func TestDeleteRemovesCasbinPolicyAndRoleBindings(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, store, _ := newRoleService(t)

    	if err := svc.GrantPermissions(ctx, "1", []string{{ "{" }}"user:create"{{ "}" }}); err != nil {{ "{" }}
    		t.Fatalf("GrantPermissions: %v", err)
    	{{ "}" }}
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	if _, err := e.AddRoleForUser("alice", "admin"); err != nil {{ "{" }}
    		t.Fatalf("AddRoleForUser: %v", err)
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", "user:create", "POST"); !allowed {{ "{" }}
    		t.Fatal("precondition: Enforce(admin, user:create, POST) = false, want true")
    	{{ "}" }}
    	roles, err := e.GetRolesForUser("alice")
    	if err != nil || len(roles) != 1 {{ "{" }}
    		t.Fatalf("precondition: GetRolesForUser(alice) = %v, %v, want [admin]", roles, err)
    	{{ "}" }}

    	if err := svc.Delete(ctx, "1"); err != nil {{ "{" }}
    		t.Fatalf("Delete: %v", err)
    	{{ "}" }}

    	e2, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	if allowed, _ := e2.Enforce("admin", "user:create", "POST"); allowed {{ "{" }}
    		t.Fatal("Enforce(admin, user:create, POST) after Delete = true, want false")
    	{{ "}" }}
    	roles, err = e2.GetRolesForUser("alice")
    	if err != nil {{ "{" }}
    		t.Fatalf("GetRolesForUser: %v", err)
    	{{ "}" }}
    	if len(roles) != 0 {{ "{" }}
    		t.Fatalf("GetRolesForUser(alice) after Delete = %v, want []", roles)
    	{{ "}" }}
    {{ "}" }}

    func TestDeleteCasbinCleanupErrorsDoNotFailRequest(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := casbin.NewMemoryPolicyStore()
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	roles := &fakeRoleRepo{{ "{" }}roles: map[int64]*role.Role{{ "{" }}1: {{ "{" }}ID: 1, Code: "admin", Name: "Admin"{{ "}}" }}{{ "}" }}
    	perms := &fakePermReader{{ "{" }}perms: map[string]*permission.Permission{{ "{}" }}{{ "}" }}
    	aud := audit.NewMemoryWriter()
    	svc := New(roles, perms, &errEnforcer{{ "{" }}Enforcer: e, removeErr: errors.New("boom"){{ "}" }}, aud)

    	if err := svc.Delete(ctx, "1"); err != nil {{ "{" }}
    		t.Fatalf("Delete with casbin cleanup errors = %v, want nil (cleanup failure must not fail the request)", err)
    	{{ "}" }}
    {{ "}" }}
```

Then extend the existing `errEnforcer` type (right below the new tests, where it's currently defined) to also stub the new method:

```go
    func (e *errEnforcer) RemoveFilteredGroupingPolicy(fieldIndex int, fieldValues ...string) (bool, error) {{ "{" }}
    	return false, e.removeErr
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/application/role/... -run 'TestDeleteRemovesCasbinPolicyAndRoleBindings|TestDeleteCasbinCleanupErrorsDoNotFailRequest' -v`
Expected: compile failure or FAIL — `errEnforcer` doesn't yet satisfy the (not-yet-extended) `Enforcer` interface / `svc.Delete` doesn't call the new methods, and `TestDeleteRemovesCasbinPolicyAndRoleBindings` fails because neither the `p` policy nor the `g` binding is cleaned yet.

- [ ] **Step 3: Write minimal implementation**

In `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml`, extend the `Enforcer` interface:

```go
    // Enforcer syncs permission grants into Casbin (p policies) and manages
    // role-to-user bindings (g policies).
    type Enforcer interface {{ "{" }}
    	AddPolicy(params ...any) (bool, error)
    	RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error)
    	RemoveFilteredGroupingPolicy(fieldIndex int, fieldValues ...string) (bool, error)
    {{ "}" }}
```

And replace the `Delete` method body:

```go
    // Delete removes a role identified by its decimal-string id, and cleans
    // up its Casbin p policies and any g role bindings held by users.
    func (s *Service) Delete(ctx context.Context, id string) error {{ "{" }}
    	rid, err := strconv.ParseInt(id, 10, 64)
    	if err != nil {{ "{" }}
    		return role.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	r, err := s.roles.GetByID(ctx, rid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if err := s.roles.Delete(ctx, rid); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if _, err := s.enforcer.RemoveFilteredPolicy(0, r.Code); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "role.delete: remove casbin policies for role %s failed: %v", r.Code, err)
    	{{ "}" }}
    	if _, err := s.enforcer.RemoveFilteredGroupingPolicy(1, r.Code); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "role.delete: remove casbin role bindings for role %s failed: %v", r.Code, err)
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "role.delete", id, "{{ "{" }}{{ "}" }}")
    	return nil
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/application/role/... -v`
Expected: PASS — all tests including the two new ones and existing `TestGrantPermissions*`, `TestCreateValidatesRole`, `TestUpdateRejectsNonIntegerID`.

- [ ] **Step 5: Commit**

```bash
git add rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml
git commit -m "fix(rbac-kitex): clean up Casbin p policies and g role bindings on role delete"
```

---

### Task 4: `role.Service.Delete` — mirror Task 3 in admin-services-kitex

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Test: `admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`

**Interfaces:** identical to Task 3 (files are byte-identical mirrors).

- [ ] **Step 1: Diff-verify the two source files are still identical before editing**

Run: `diff rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml && diff rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`
Expected: no output.

- [ ] **Step 2: Apply the identical Step 1/3 edits from Task 3 to the `admin-services-kitex` copies**

Copy the same test additions, `errEnforcer` extension, `Enforcer` interface extension, and `Delete` replacement into `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml` and its test file.

- [ ] **Step 3: Run test to verify it passes**

Run (in the `admin-services-kitex` rendered module directory): `go test ./internal/application/role/... -v`
Expected: PASS.

- [ ] **Step 4: Verify the two repos are byte-identical again**

Run: `diff rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml && diff rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml
git commit -m "fix(admin-services-kitex): clean up Casbin p policies and g role bindings on role delete"
```

---

## Post-Implementation Checklist (covers remaining Issue #48 acceptance criteria)

- [x] Design decision on `g`-binding cascade: **yes, cascade-clean** — recorded in the spec and implemented in Task 3/4.
- [x] `permission.Delete` cleans Casbin for every cascaded child (Task 1/2), not just the top level.
- [x] `role.Delete` cleans both `p` policies and `g` bindings (Task 3/4).
- [x] Unit tests added for both (Task 1-4).
- [x] `permission.Service.Delete` doc comment updated to match cascade behavior (Task 1/2, Step 3).
