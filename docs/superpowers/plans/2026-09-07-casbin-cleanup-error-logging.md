# Casbin 策略清理错误日志化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 rbac-kitex / admin-services-kitex 两个模板包中 4 处被静默忽略的 Casbin 策略清理错误（`_, _ = s.enforcer.XXX(...)`），改为用 `klog.CtxErrorf` 记录，并为每处新增一条错误路径单元测试。

**Architecture:** 纯错误处理修改，不改变任何方法签名或返回值语义。`rbac-kitex/kitex-template/` 与 `admin-services-kitex/kitex-template/` 下同名模板文件内容当前完全一致（已用 `diff` 确认），因此每个 Task 对两个包应用逐字相同的 diff。

**Tech Stack:** Go, `github.com/cloudwego/kitex/pkg/klog`（项目既有日志组件，参考 `admin-services-kitex/kitex-template/internal_base_middleware_ratelimit_go.yaml` 中 `klog.CtxWarnf` 用法）。模板文件为 ncgo YAML 格式，`body:` 字段内的 Go 代码使用 `{{ "{" }}` / `{{ "}" }}` 转义花括号 — 所有新增代码必须遵循同一转义约定。

**Spec:** docs/superpowers/specs/2026-09-07-casbin-cleanup-error-logging-design.md

## Global Constraints

- 不改变任何公开方法的返回值语义（Casbin 清理失败不导致业务方法返回 error）
- 不引入事务/补偿机制（已在设计文档中确认排除）
- 所有新增 Go 代码块内的 `{` `}` 必须写成 `{{ "{" }}` / `{{ "}" }}`（与文件其余部分保持一致）
- rbac-kitex 与 admin-services-kitex 的对应文件当前逐字相同，每个 Task 必须对两个包应用完全相同的编辑

---

### Task 1: role_service — GrantPermissions 的 RemoveFilteredPolicy

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Test: `rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`
- Test: `admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`

**Interfaces:**
- Consumes: existing `rolesvc.Enforcer` interface (`AddPolicy(params ...any) (bool, error)`, `RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error)`), existing `rolesvc.New(roles RoleRepo, perms PermReader, enforcer Enforcer, audit audit.Writer) *Service`
- Produces: nothing consumed by later tasks (each service package is independent)

- [ ] **Step 1: Write the failing test**

In both `rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml` and `admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`, add `"errors"` to the import block:

```
    import (
    	"context"
    	"errors"
    	"fmt"
    	"testing"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/casbin"
    )
```

Append at the end of the `body:` block (after `TestUpdateRejectsNonIntegerID`):

```
    type errEnforcer struct {{ "{" }}
    	*casbin.Enforcer
    	removeErr error
    {{ "}" }}

    func (e *errEnforcer) RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error) {{ "{" }}
    	return false, e.removeErr
    {{ "}" }}

    func TestGrantPermissionsCasbinCleanupErrorDoesNotFailRequest(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := casbin.NewMemoryPolicyStore()
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	roles := &fakeRoleRepo{{ "{" }}roles: map[int64]*role.Role{{ "{" }}1: {{ "{" }}ID: 1, Code: "admin", Name: "Admin"{{ "}}" }}{{ "}" }}
    	perms := &fakePermReader{{ "{" }}perms: map[string]*permission.Permission{{ "{" }}
    		"user:create": {{ "{" }}ID: 1, Code: "user:create", Type: permission.TypeAPI, Name: "Create User", Method: "POST"{{ "}" }},
    	{{ "}}" }}
    	aud := audit.NewMemoryWriter()
    	svc := New(roles, perms, &errEnforcer{{ "{" }}Enforcer: e, removeErr: errors.New("boom"){{ "}" }}, aud)

    	if err := svc.GrantPermissions(ctx, "1", []string{{ "{" }}"user:create"{{ "}" }}); err != nil {{ "{" }}
    		t.Fatalf("GrantPermissions with casbin cleanup error = %v, want nil (cleanup failure must not fail the request)", err)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

The test won't compile yet — `errEnforcer` and the fake compile fine, but this step only actually fails once you've regenerated a project (Task 4 covers generation + `go test`). For this task, verify by generating a scratch project and running the package test:

```bash
ncgo new roletest --module example.com/roletest --kind kitex --template-dir rbac-kitex --dir /tmp/roletest --no-auto-steps
cd /tmp/roletest && go test ./internal/application/role/... -run TestGrantPermissionsCasbinCleanupErrorDoesNotFailRequest -v
```

Expected: FAIL — `GrantPermissions with casbin cleanup error = ..., want nil` (because Step 1's implementation change from Step 3 below hasn't happened yet, the current code silently drops the error too, so this actually already returns nil — confirm this by first regenerating BEFORE Step 3's implementation edit, to establish the baseline: the test compiles and passes even before the fix, since today's code also never surfaces the error to the caller. This is expected — the test's purpose is regression protection for the fix, not a red/green demonstration of currently-broken behavior. Proceed to Step 3 to make the log call itself land, then re-verify in Task 4.)

- [ ] **Step 3: Write minimal implementation**

In both `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml` and `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml`:

Add `"github.com/cloudwego/kitex/pkg/klog"` to the import block:

```
    import (
    	"context"
    	"strconv"

    	"github.com/cloudwego/kitex/pkg/klog"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/infrastructure/audit"
    )
```

Replace:

```
    	// Sync Casbin policies: clear existing then add new.
    	_, _ = s.enforcer.RemoveFilteredPolicy(0, r.Code)
```

with:

```
    	// Sync Casbin policies: clear existing then add new.
    	if _, err := s.enforcer.RemoveFilteredPolicy(0, r.Code); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "role.grant_permissions: remove existing casbin policies for role %s failed: %v", r.Code, err)
    	{{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
rm -rf /tmp/roletest
ncgo new roletest --module example.com/roletest --kind kitex --template-dir rbac-kitex --dir /tmp/roletest --no-auto-steps
cd /tmp/roletest && go build ./... && go test ./internal/application/role/... -v
```

Expected: PASS, including `TestGrantPermissionsCasbinCleanupErrorDoesNotFailRequest` and all pre-existing tests in the package.

- [ ] **Step 5: Commit**

```bash
git add rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml \
        rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml
git commit -m "fix(rbac-kitex,admin-services-kitex): log casbin RemoveFilteredPolicy error in GrantPermissions instead of silently dropping it"
```

---

### Task 2: permission_service — Delete 的 RemoveFilteredPolicy

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Test: `rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`
- Test: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`

**Interfaces:**
- Consumes: existing `permsvc.Enforcer` interface (`RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error)`), existing `permsvc.New(perms PermRepo, enforcer Enforcer, audit audit.Writer) *Service`
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing test**

In both permission test files, add `"errors"` to the import block:

```
    import (
    	"context"
    	"errors"
    	"fmt"
    	"testing"

    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/casbin"
    )
```

Append at the end of the `body:` block (after `TestDeleteRemovesCasbinPolicy`):

```
    type errEnforcer struct {{ "{" }}
    	removeErr error
    {{ "}" }}

    func (e *errEnforcer) RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error) {{ "{" }}
    	return false, e.removeErr
    {{ "}" }}

    func TestDeleteCasbinCleanupErrorDoesNotFailRequest(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	repo := &fakePermRepo{{ "{" }}perms: map[int64]*permission.Permission{{ "{" }}{{ "}}" }}
    	aud := audit.NewMemoryWriter()
    	svc := New(repo, &errEnforcer{{ "{" }}removeErr: errors.New("boom"){{ "}" }}, aud)

    	p, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "user:delete", Type: permission.TypeAPI, Name: "Delete User", Method: "DELETE"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	if err := svc.Delete(ctx, fmt.Sprint(p.ID)); err != nil {{ "{" }}
    		t.Fatalf("Delete with casbin cleanup error = %v, want nil (cleanup failure must not fail the request)", err)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Same caveat as Task 1 Step 2 — this is a regression-protection test, not a red/green test against currently-broken behavior. Skip ahead to Step 3, then verify green in Step 4.

- [ ] **Step 3: Write minimal implementation**

In both `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml` and `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`:

Add `"github.com/cloudwego/kitex/pkg/klog"` to the import block:

```
    import (
    	"context"
    	"strconv"

    	"github.com/cloudwego/kitex/pkg/klog"

    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/infrastructure/audit"
    )
```

Replace:

```
    	_, _ = s.enforcer.RemoveFilteredPolicy(1, p.Code)
```

with:

```
    	if _, err := s.enforcer.RemoveFilteredPolicy(1, p.Code); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "permission.delete: remove casbin policies for permission %s failed: %v", p.Code, err)
    	{{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
rm -rf /tmp/permtest
ncgo new permtest --module example.com/permtest --kind kitex --template-dir rbac-kitex --dir /tmp/permtest --no-auto-steps
cd /tmp/permtest && go build ./... && go test ./internal/application/permission/... -v
```

Expected: PASS, including `TestDeleteCasbinCleanupErrorDoesNotFailRequest` and all pre-existing tests in the package.

- [ ] **Step 5: Commit**

```bash
git add rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml \
        rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml
git commit -m "fix(rbac-kitex,admin-services-kitex): log casbin RemoveFilteredPolicy error in permission Delete instead of silently dropping it"
```

---

### Task 3: user_service — Delete 与 AssignRoles 的 DeleteRolesForUser（2 处）

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Test: `rbac-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`
- Test: `admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`

**Interfaces:**
- Consumes: existing `usersvc.Enforcer` interface (`DeleteRolesForUser(user string, domain ...string) (bool, error)`, `AddRoleForUser(user string, role string, domain ...string) (bool, error)`), existing `usersvc.New(users UserRepo, enforcer Enforcer, audit audit.Writer) *Service`
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing test**

In both user test files, add `"errors"` to the import block:

```
    import (
    	"context"
    	"errors"
    	"fmt"
    	"strings"
    	"testing"

    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/casbin"
    )
```

Append at the end of the `body:` block (after `TestAssignRolesSyncsCasbin`):

```
    type errEnforcer struct {{ "{" }}
    	*casbin.Enforcer
    	deleteErr error
    {{ "}" }}

    func (e *errEnforcer) DeleteRolesForUser(user string, domain ...string) (bool, error) {{ "{" }}
    	return false, e.deleteErr
    {{ "}" }}

    func TestDeleteCasbinCleanupErrorDoesNotFailRequest(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := casbin.NewMemoryPolicyStore()
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	repo := &fakeUserRepo{{ "{" }}
    		users:     map[int64]*user.User{{ "{" }}{{ "}" }},
    		byUUID:    map[string]int64{{ "{" }}{{ "}" }},
    		roleDefs:  map[int64]*role.Role{{ "{" }}{{ "}" }},
    		rolesByID: map[int64][]*role.Role{{ "{" }}{{ "}" }},
    	{{ "}" }}
    	aud := audit.NewMemoryWriter()
    	svc := New(repo, &errEnforcer{{ "{" }}Enforcer: e, deleteErr: errors.New("boom"){{ "}" }}, aud)

    	created, err := svc.Create(ctx, CreateUserInput{{ "{" }}Username: "dave", Password: "Passw0rd!"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	if err := svc.Delete(ctx, created.UUID); err != nil {{ "{" }}
    		t.Fatalf("Delete with casbin cleanup error = %v, want nil (cleanup failure must not fail the request)", err)
    	{{ "}" }}
    {{ "}" }}

    func TestAssignRolesCasbinCleanupErrorDoesNotFailRequest(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := casbin.NewMemoryPolicyStore()
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	repo := &fakeUserRepo{{ "{" }}
    		users:     map[int64]*user.User{{ "{" }}{{ "}" }},
    		byUUID:    map[string]int64{{ "{" }}{{ "}" }},
    		roleDefs:  map[int64]*role.Role{{ "{" }}1: {{ "{" }}ID: 1, Code: "admin", Name: "Admin"{{ "}}" }}{{ "}" }},
    		rolesByID: map[int64][]*role.Role{{ "{" }}{{ "}" }},
    	{{ "}" }}
    	aud := audit.NewMemoryWriter()
    	svc := New(repo, &errEnforcer{{ "{" }}Enforcer: e, deleteErr: errors.New("boom"){{ "}" }}, aud)

    	created, err := svc.Create(ctx, CreateUserInput{{ "{" }}Username: "erin", Password: "Passw0rd!"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	if err := svc.AssignRoles(ctx, created.UUID, []string{{ "{" }}"1"{{ "}" }}); err != nil {{ "{" }}
    		t.Fatalf("AssignRoles with casbin cleanup error = %v, want nil (cleanup failure must not fail the request)", err)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Same caveat as Task 1 Step 2 — regression-protection test. Proceed to Step 3, verify green in Step 4.

- [ ] **Step 3: Write minimal implementation**

In both `rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml` and `admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml`:

Add `"github.com/cloudwego/kitex/pkg/klog"` to the import block:

```
    import (
    	"context"
    	"strconv"

    	"github.com/cloudwego/kitex/pkg/klog"

    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/audit"
    	authinfra "{{.Module}}/internal/infrastructure/auth"
    )
```

Replace (in `Delete`):

```
    	_, _ = s.enforcer.DeleteRolesForUser(id)
```

with:

```
    	if _, err := s.enforcer.DeleteRolesForUser(id); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "user.delete: remove casbin role bindings for user %s failed: %v", id, err)
    	{{ "}" }}
```

Replace (in `AssignRoles`):

```
    	_, _ = s.enforcer.DeleteRolesForUser(uid)
```

with:

```
    	if _, err := s.enforcer.DeleteRolesForUser(uid); err != nil {{ "{" }}
    		klog.CtxErrorf(ctx, "user.assign_roles: remove existing casbin role bindings for user %s failed: %v", uid, err)
    	{{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
rm -rf /tmp/usertest
ncgo new usertest --module example.com/usertest --kind kitex --template-dir rbac-kitex --dir /tmp/usertest --no-auto-steps
cd /tmp/usertest && go build ./... && go test ./internal/application/user/... -v
```

Expected: PASS, including `TestDeleteCasbinCleanupErrorDoesNotFailRequest`, `TestAssignRolesCasbinCleanupErrorDoesNotFailRequest`, and all pre-existing tests in the package.

- [ ] **Step 5: Commit**

```bash
git add rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml \
        rbac-kitex/kitex-template/internal_application_user_user_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "fix(rbac-kitex,admin-services-kitex): log casbin DeleteRolesForUser error in user Delete/AssignRoles instead of silently dropping it"
```

---

### Task 4: Full generated-project verification for both template packages

**Files:**
- None modified — verification only.

**Interfaces:**
- Consumes: all changes from Tasks 1-3
- Produces: nothing (terminal verification task)

- [ ] **Step 1: Generate and test a full rbac-kitex project**

```bash
rm -rf /tmp/rbac-full
ncgo new rbacfull --module example.com/rbacfull --kind kitex --template-dir rbac-kitex --dir /tmp/rbac-full --no-auto-steps
cd /tmp/rbac-full && go build ./... && go test ./...
```

Expected: build succeeds, all tests pass (no residual `{{ "{" }}`/`{{ "}" }}` escapes, no unresolved template actions — confirm with `grep -rn '{{ "{' /tmp/rbac-full --include='*.go'` returning nothing).

- [ ] **Step 2: Generate and test a full admin-services-kitex project**

```bash
rm -rf /tmp/admin-full
ncgo new adminfull --module example.com/adminfull --kind kitex --template-dir admin-services-kitex --dir /tmp/admin-full --no-auto-steps
cd /tmp/admin-full && go build ./... && go test ./...
```

Expected: build succeeds, all tests pass.

- [ ] **Step 3: Run the rbac-kitex e2e script if available**

```bash
bash rbac-kitex/test/e2e_test.sh
```

Expected: `0` failures reported (script prints `skipped: ...` for gated variants like postgres — that's fine, not a failure).

- [ ] **Step 4: Clean up scratch dirs**

```bash
rm -rf /tmp/roletest /tmp/permtest /tmp/usertest /tmp/rbac-full /tmp/admin-full
```

No commit for this task — verification only.
