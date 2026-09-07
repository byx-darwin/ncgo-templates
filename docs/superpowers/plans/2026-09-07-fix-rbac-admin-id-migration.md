# rbac-kitex/admin-services-kitex ID 类型迁移修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `rbac-kitex` 与 `admin-services-kitex` 两个 ncgo 模板渲染出的项目恢复可编译（`go build ./... && go vet ./...`，admin-services-kitex 还需 `go test ./...` 通过），并新增 CI 校验防止回归。

**Architecture:** rbac-kitex 只需修 3 处独立遗留类型问题。admin-services-kitex 需要把 user/role/permission/menu 四个业务域从 `int64` ID 完整迁移到 `string` ID（DB schema → domain → repository → application → handler，自底向上依次修复，每完成一层用 `ncgo new` 渲染 + `go build` 验证编译错误减少），Rule Center 域保持 `int64` 不变（回退 4 处被误标为 string 的 proto 字段）。

**Tech Stack:** Go, ncgo 模板 YAML（`body:` 字段是 Go 源码模板，`{{ "{" }}`/`{{ "}" }}` 转义花括号），PostgreSQL + sqlc，protobuf/kitex，GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-09-06-fix-rbac-audit-validatetoken-types-design.md`

## Global Constraints

- 所有改动都是模板文件（`.yaml` 里的 `body:` 字段），不是直接的 `.go` 文件；编辑时保持原有缩进和 `{{ "{" }}`/`{{ "}" }}` 转义写法不变，只改动花括号内部的实际代码逻辑。
- 每完成一个任务，必须用以下命令实际渲染验证（`<template>` 替换为 `rbac-kitex` 或 `admin-services-kitex`，`<dir>` 每次用新的临时目录避免脏状态）：
  ```bash
  rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
  ncgo new scratch --module github.com/acme/scratch --kind kitex \
    --dir /tmp/ncgo-verify --template-dir <template>
  cd /tmp/ncgo-verify && go build ./... && go vet ./...
  ```
- `ncgo` 二进制已安装在 `$(go env GOPATH)/bin/ncgo`，确保其在 `PATH` 中（`command -v ncgo` 验证）。
- rbac-kitex 与 admin-services-kitex 是两个独立目录，互不影响；任务之间除非明确写明依赖，否则可并行开发，但**建议按顺序执行**，因为 admin-services-kitex 内部任务之间存在编译依赖（schema → domain → repo → application → handler）。
- 每个任务改完自己的文件后，admin-services-kitex 的整体渲染在该任务完成时**不要求**必须编译通过（因为后续任务还没开始）——只需确认该任务改动的文件本身没有引入新的、与本任务无关的语法错误。**只有最后的 Task 10（全量验证）要求两个模板都完全编译通过**。
- 涉及 `admin-services-kitex/idl/admin.proto` 的改动必须在 Task 2（Proto 字段调整）里一次性完成，因为 IDL 变更会重新生成 `kitex_gen` 代码，影响后续所有依赖它的任务。

---

### Task 1: 修复 rbac-kitex 的 3 类遗留类型问题

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_auth_auth_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_infrastructure_token_redis_go.yaml`

**Interfaces:**
- 不影响其他任务（rbac-kitex 与 admin-services-kitex 是独立目录）。

- [ ] **Step 1: 修复 role service 的 audit.Write 调用**

在 `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml` 里，把所有 4 处：
```go
_ = s.audit.Write(ctx, 0, "role.create", in.Code, "{{ "{" }}{{ "}" }}")
```
```go
_ = s.audit.Write(ctx, 0, "role.update", fmt.Sprint(in.ID), "{{ "{" }}{{ "}" }}")
```
```go
_ = s.audit.Write(ctx, 0, "role.delete", fmt.Sprint(id), "{{ "{" }}{{ "}" }}")
```
```go
_ = s.audit.Write(ctx, 0, "role.grant_permissions", fmt.Sprint(roleID), "{{ "{" }}{{ "}" }}")
```
的 `ctx, 0,` 改成 `ctx, "",`（其余参数不变）。

- [ ] **Step 2: 修复 user service 的 audit.Write 调用**

在 `rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml` 里，把所有 4 处 `s.audit.Write(ctx, 0, "user.create"/"user.update"/"user.delete"/"user.assign_roles", ...)` 的 `ctx, 0,` 改成 `ctx, "",`。

- [ ] **Step 3: 修复 permission service 的 audit.Write 调用**

在 `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml` 里，把所有 3 处 `s.audit.Write(ctx, 0, "permission.create"/"permission.update"/"permission.delete", ...)` 的 `ctx, 0,` 改成 `ctx, "",`。

- [ ] **Step 4: 修复 auth service 的 ValidateToken 失败分支**

在 `rbac-kitex/kitex-template/internal_application_auth_auth_service_go.yaml` 里，把两处：
```go
		return 0, nil, false
```
改成：
```go
		return "", nil, false
```

- [ ] **Step 5: 修复 RedisStore.GetRefresh 的遗留类型问题**

在 `rbac-kitex/kitex-template/internal_infrastructure_token_redis_go.yaml` 里，把：
```go
func (s *RedisStore) GetRefresh(ctx context.Context, refreshToken string) (string, error) {
	return 0, errors.New("token: redis store not wired in v1 (seam; see NewRedisStore)")
}
```
的 `return 0, errors.New(...)` 改成 `return "", errors.New(...)`（函数签名已经是 `(string, error)`，不用改）。

- [ ] **Step 6: 渲染验证**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir rbac-kitex
cd /tmp/ncgo-verify && go build ./... && go vet ./...
```
Expected: 无输出，退出码 0。

- [ ] **Step 7: Commit**

```bash
git add rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml \
        rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml \
        rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml \
        rbac-kitex/kitex-template/internal_application_auth_auth_service_go.yaml \
        rbac-kitex/kitex-template/internal_infrastructure_token_redis_go.yaml
git commit -m "fix(rbac-kitex): correct leftover int64 literals after string ID migration"
```

---

### Task 2: admin.proto 字段调整

**Files:**
- Modify: `admin-services-kitex/idl/admin.proto`

**Interfaces:**
- Produces: `ValidateTokenResp` 消息字段 `roles`（`repeated string`，字段号 2，原名 `role_codes`）供 Task 8（handler 层）使用；`RateLimitRule.id`、`CreateRuleResp.id`、`UpdateRuleReq.id`、`DeleteRuleReq.id` 恢复为 `int64`，供 Rule Center 相关代码（不在本计划改动范围内）保持不变。

- [ ] **Step 1: 修改 ValidateTokenResp 字段名**

在 `admin-services-kitex/idl/admin.proto` 里找到（约 73 行）：
```protobuf
  repeated string role_codes = 2;
```
改成：
```protobuf
  repeated string roles = 2;
```
（字段号 `2` 保持不变，只改字段名。）

- [ ] **Step 2: 回退 Rule Center 的 4 处 id 字段类型**

在同一文件里，把以下 4 处 `string id = 1;` 改成 `int64 id = 1;`：
- `CreateRuleResp` message（约 278 行）
- `UpdateRuleReq` message（约 282 行）
- `DeleteRuleReq` message（约 297 行）
- `RateLimitRule` message（约 317 行）

用以下命令定位精确行号后再编辑（每次改完重新 grep 确认剩余数量减少）：
```bash
grep -n "string id = 1;" admin-services-kitex/idl/admin.proto
```

- [ ] **Step 3: 确认改动数量正确**

```bash
grep -n "role_codes\|repeated string roles" admin-services-kitex/idl/admin.proto
# 期望：role_codes 不再出现，roles 出现一次

grep -c "int64 id = 1;" admin-services-kitex/idl/admin.proto
# 期望：至少包含本次新增的 4 处（如果之前已有其他 int64 id = 1，数量会更多，只要确认新增的 4 处都在即可）
```

- [ ] **Step 4: Commit**

```bash
git add admin-services-kitex/idl/admin.proto
git commit -m "fix(admin-services-kitex): rename ValidateTokenResp field, revert Rule Center id to int64"
```

---

### Task 3: admin-services-kitex DB schema + query SQL 迁移

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml`

**Interfaces:**
- Produces: `users.id`/`roles.id`/`permissions.id`/`permissions.parent_id`/
  `user_roles.user_id`/`user_roles.role_id`/`role_permissions.role_id`/
  `role_permissions.permission_id`/`audit_log.actor_uid` 全部为 `TEXT` 类型，
  供 Task 4~7 的 domain/repository/application 层代码使用（sqlc 会在
  `ncgo new` 渲染时根据这个 schema 重新生成 Go 类型，无需手动改
  `internal/db/gen` 代码）。
- `casbin_rule.id`、`audit_log.id`、`rate_limit_rules.*` 保持不变。

**依赖**: 无（这是 admin-services-kitex 迁移链条的第一层）。

- [ ] **Step 1: 修改 DB schema 的 ID 列类型**

在 `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml` 里做以下替换（用 `grep -n "BIGSERIAL\|BIGINT" admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml` 先定位当前行号）：

| 表.列 | 改动前 | 改动后 |
|---|---|---|
| `users.id` | `id BIGSERIAL PRIMARY KEY,` | `id TEXT PRIMARY KEY,` |
| `roles.id` | `id BIGSERIAL PRIMARY KEY,` | `id TEXT PRIMARY KEY,` |
| `permissions.id` | `id BIGSERIAL PRIMARY KEY,` | `id TEXT PRIMARY KEY,` |
| `permissions.parent_id` | `parent_id BIGINT REFERENCES permissions(id),` | `parent_id TEXT REFERENCES permissions(id),` |
| `user_roles.user_id` | `user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,` | `user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,` |
| `user_roles.role_id` | `role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,` | `role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,` |
| `role_permissions.role_id` | `role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,` | `role_id TEXT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,` |
| `role_permissions.permission_id` | `permission_id BIGINT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,` | `permission_id TEXT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,` |
| `audit_log.actor_uid` | `actor_uid BIGINT,` | `actor_uid TEXT,` |

**不要修改**：`casbin_rule` 表的 `id BIGSERIAL PRIMARY KEY`、`audit_log.id`、`rate_limit_rules` 表的任何列（这些不在本次迁移范围内，`menus` 表——如果 admin schema 里有独立的 menus 表定义，其 `id`/`parent_id` 也要按同样规则改成 TEXT，先用 `grep -n "menus\|BIGSERIAL\|BIGINT" admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml` 确认是否存在单独的 `menus` 表定义，如果 menu 数据其实是复用 `permissions` 表（无独立表），则以上 8 处已覆盖，无需额外操作）。

- [ ] **Step 2: 修改 query SQL 里的类型转换与哨兵值**

在 `admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml` 里：

找到 `ListPermissionsByRoleIDs` 查询里的：
```sql
rp.role_id = ANY($1::bigint[])
```
改成：
```sql
rp.role_id = ANY($1::text[])
```

找到 `ListPermissionsFiltered` 查询里的：
```sql
AND ($2 < 0 OR parent_id = $2)
```
改成：
```sql
AND ($2 = '' OR parent_id = $2)
```

（先用 `grep -n "bigint\[\]\|\$2 < 0" admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml` 定位精确行号。）

- [ ] **Step 3: 渲染验证（预期仍然编译失败，但错误应该出现在 domain/repository 层而非 schema 层）**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir admin-services-kitex
cd /tmp/ncgo-verify && go build ./... 2>&1 | head -20
```
Expected: 渲染本身（`ncgo new` 命令）成功完成，不报 SQL/sqlc 相关错误；`go build` 的报错应该是 domain 层（如 `internal/domain/user`）的 `int64`/`string` 类型不匹配，而不是 sqlc 生成失败的错误。如果 `ncgo new` 阶段就失败（sqlc 报错），说明 schema/query SQL 语法有问题，需要检查 Step 1/2 的改动。

- [ ] **Step 4: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml \
        admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml
git commit -m "fix(admin-services-kitex): migrate RBAC table ID columns from BIGSERIAL to TEXT"
```

---

### Task 4: admin-services-kitex domain 层迁移（实体 + repository 接口 + domain service）

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_domain_user_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_role_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_permission_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_menu_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_user_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_role_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_permission_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_menu_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_role_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_role_service_test_go.yaml`

**Interfaces:**
- Consumes: Task 3 产出的 TEXT 类型 DB 列（sqlc 渲染时自动生成对应 Go `string` 字段，无需手动处理）。
- Produces: `user.User.ID string`、`role.Role.ID string`、`permission.Permission.ID/ParentID string`、`menu.Menu.ID/ParentID string`；四个 repository 接口的所有 ID 相关方法参数改为 `string`（`Count(ctx) (int64, error)` 除外，这是计数值不是 ID，保持 `int64`）；`role.Assign(ctx, roleID string, ...)`。供 Task 5（repository 实现）、Task 6（application 层）使用。

**依赖**: Task 3（DB schema 必须先改完，虽然这里改的是 Go 代码不直接依赖 schema 渲染结果，但保持任务顺序一致，避免中间状态混乱）。

- [ ] **Step 1: 修改 domain 实体的 ID 字段类型**

`internal_domain_user_entity_go.yaml`：找到 `type User struct` 里的 `ID int64` 改成 `ID string`。

`internal_domain_role_entity_go.yaml`：找到 `type Role struct` 里的 `ID int64` 改成 `ID string`。

`internal_domain_permission_entity_go.yaml`：
- `type Permission struct` 里的 `ID int64` 改成 `ID string`
- `ParentID int64 // 0=root` 改成 `ParentID string // empty=root`
- 构造函数 `func New(..., parentID int64, ...)` 的参数类型改成 `parentID string`

`internal_domain_menu_entity_go.yaml`：
- `type Menu struct` 里的 `ID int64` 改成 `ID string`，`ParentID int64` 改成 `ParentID string`
- 树构建逻辑里的 `byID := make(map[int64]*Node, len(items))` 改成 `map[string]*Node`

- [ ] **Step 2: 修改配套的 domain 实体测试文件字面量**

`internal_domain_menu_entity_test_go.yaml`：把测试数据里所有 `ID: 1, ParentID: 0`（或类似的整数字面量，通常有 5 处）改成对应的字符串字面量，例如 `ID: 1` → `ID: "1"`，`ParentID: 0` → `ParentID: ""`（根 节点用空字符串表示无父节点，非根节点用父节点 ID 的字符串形式，如 `ParentID: 1` → `ParentID: "1"`）。先用 `grep -n "ID: [0-9]\|ParentID: [0-9]" admin-services-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml` 定位全部位置。

`internal_domain_permission_entity_test_go.yaml`：找到所有 `New(...)` 调用里第 4 个参数（parentID）传入整数字面量 `0` 的地方（约 8 处：16, 25, 35, 43, 55, 66, 82, 89 行附近），改成 `""`。先用 `grep -n "New(" admin-services-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml` 确认每处调用的参数位置。

- [ ] **Step 3: 修改 repository 接口签名**

对以下 4 个文件，把所有方法签名里代表 ID 的参数从 `int64`/`[]int64` 改成 `string`/`[]string`（**不要改** `Count(ctx context.Context) (int64, error)` 这类返回计数值的方法）：

`internal_domain_user_repository_go.yaml`：`GetByID(ctx, id int64)` → `id string`；`UpdatePassword(ctx, id int64, ...)` → `id string`；`Delete(ctx, id int64)` → `id string`；`SetStatus(ctx, id int64, ...)` → `id string`。

`internal_domain_role_repository_go.yaml`：`GetByID(ctx, id int64)` → `id string`；`Delete(ctx, id int64)` → `id string`。

`internal_domain_permission_repository_go.yaml`：`GetByID(ctx, id int64)` → `id string`；`ListFiltered(ctx, ..., parentID int64, ...)` → `parentID string`；`ListByRoleIDs(ctx, roleIDs []int64)` → `roleIDs []string`；`ListChildren(ctx, parentID int64)` → `parentID string`；`Delete(ctx, id int64)` → `id string`。

`internal_domain_menu_repository_go.yaml`：`ListMenusByParentID(ctx, parentID int64)` → `parentID string`。

用 `grep -n "int64" admin-services-kitex/kitex-template/internal_domain_{user,role,permission,menu}_repository_go.yaml` 逐个确认改完后该文件里不再有 ID 相关的 `int64`（`Count` 方法的 `int64` 除外）。

- [ ] **Step 4: 修改 domain service 的 Assign 方法**

`internal_domain_role_service_go.yaml`：找到：
```go
func Assign(ctx context.Context, roleID int64, ...) error {
	if roleID <= 0 {
		return ValidationError{Field: "roleID", Msg: "must be positive"}
	}
	...
}
```
改成：
```go
func Assign(ctx context.Context, roleID string, ...) error {
	if roleID == "" {
		return ValidationError{Field: "roleID", Msg: "must not be empty"}
	}
	...
}
```
（省略号部分保持函数原有的其余逻辑不变，只改函数签名和这段校验逻辑。先用 `Read` 工具读取该文件确认完整函数体再编辑。）

`internal_domain_role_service_test_go.yaml`：把测试里的 `Assign(ctx, 0, ...)` 改成 `Assign(ctx, "", ...)`，`Assign(ctx, 1, ...)` 改成 `Assign(ctx, "1", ...)`（先用 `grep -n "Assign(ctx" admin-services-kitex/kitex-template/internal_domain_role_service_test_go.yaml` 定位全部调用点，约 3 处：36, 39, 46 行附近）。

- [ ] **Step 5: 渲染验证**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir admin-services-kitex
cd /tmp/ncgo-verify && go build ./internal/domain/... 2>&1 | head -30
```
Expected: `internal/domain/user`、`internal/domain/role`、`internal/domain/permission`、`internal/domain/menu` 四个包本身不再报 ID 类型相关的编译错误（可能仍有其他包因依赖它们而报错，属于后续任务范围，暂不用管）。

- [ ] **Step 6: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_domain_user_entity_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_role_entity_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_permission_entity_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_menu_entity_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_user_repository_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_role_repository_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_permission_repository_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_menu_repository_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_role_service_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml \
        admin-services-kitex/kitex-template/internal_domain_role_service_test_go.yaml
git commit -m "fix(admin-services-kitex): migrate domain layer ID types from int64 to string"
```

---

### Task 5: admin-services-kitex repository 实现层迁移

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_repository_user_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_role_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_permission_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_menu_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`

**Interfaces:**
- Consumes: Task 4 产出的 repository 接口签名（`string` 类型的 ID 参数）与 Task 3 产出的 sqlc 生成类型。
- Produces: 四个 repository 实现完整满足 Task 4 定义的接口，供 Task 6（application 层）注入使用。

**依赖**: Task 3、Task 4。

- [ ] **Step 1: 修改 repository 实现的方法签名**

对 `internal_repository_user_repo_go.yaml`、`internal_repository_role_repo_go.yaml`、`internal_repository_permission_repo_go.yaml`、`internal_repository_menu_repo_go.yaml` 四个文件：把所有实现 Task 4 接口的方法（`GetByID`、`Delete`、`UpdatePassword`、`SetStatus`、`AssignRoles`、`ClearRoles`、`ListRoles`、`ListRoleIDs`、`AssignPermissions`、`ClearPermissions`、`ListPermissions`、`ListPermissionCodes`、`ListFiltered`、`ListByRoleIDs`、`ListChildren`、`ListMenusByParentID`）里，凡是签名类型为 `int64`/`[]int64` 的 ID 参数改成 `string`/`[]string`，与 Task 4 的接口定义保持一致（这一步没有 strconv 转换代码需要删除，admin-services-kitex 原本就是直接类型声明，不是转换代码）。

其中 `internal_repository_user_repo_go.yaml` 里额外有一处判空逻辑：
```go
if u.ID != 0 {
```
改成：
```go
if u.ID != "" {
```

`internal_repository_role_repo_go.yaml` 里同样的判空逻辑：
```go
if rl.ID != 0 {
```
改成：
```go
if rl.ID != "" {
```

`internal_repository_permission_repo_go.yaml` 里两处：
```go
var parentID *int64
```
改成：
```go
var parentID *string
```
以及：
```go
if p.ParentID != 0 {
```
改成：
```go
if p.ParentID != "" {
```

用 `grep -n "int64\|!= 0" admin-services-kitex/kitex-template/internal_repository_{user,role,permission,menu}_repo_go.yaml` 确认每个文件改动完整。

- [ ] **Step 2: 修改 repository 测试文件字面量**

`internal_repository_user_repo_test_go.yaml` 第 52 行附近：
```go
if created.ID == 0 {
```
改成：
```go
if created.ID == "" {
```

- [ ] **Step 3: 渲染验证**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir admin-services-kitex
cd /tmp/ncgo-verify && go build ./internal/domain/... ./internal/repository/... 2>&1 | head -30
```
Expected: `internal/repository/user`、`internal/repository/role`、`internal/repository/permission`、`internal/repository/menu` 不再报 ID 类型相关错误。

- [ ] **Step 4: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_repository_user_repo_go.yaml \
        admin-services-kitex/kitex-template/internal_repository_role_repo_go.yaml \
        admin-services-kitex/kitex-template/internal_repository_permission_repo_go.yaml \
        admin-services-kitex/kitex-template/internal_repository_menu_repo_go.yaml \
        admin-services-kitex/kitex-template/internal_repository_user_repo_test_go.yaml
git commit -m "fix(admin-services-kitex): migrate repository implementations to string ID"
```

---

### Task 6: admin-services-kitex audit.Writer / token store 基础设施层迁移

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_audit_writer_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_audit_writer_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_token_memory_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_token_memory_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_token_redis_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_token_store_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_infrastructure_auth_jwt_test_go.yaml`

**Interfaces:**
- Produces: `audit.Writer.Write(ctx, actorUID string, ...)`、`token.Store.SetRefresh(ctx, uid string, ...)`/`GetRefresh(ctx, ...) (string, error)`、`auth.Claims.Uid string`、`JWTManager.Sign(uid string, ...)` —— 供 Task 7（application 层的 auth/role/user/permission service，即 Issue #37 原始范围的 `audit.Write(ctx, 0, ...)` → `""`、`ValidateToken` 的 `return 0, nil, false` → `return "", nil, false` 两处遗留修复）使用。这一步是那两处遗留修复的**前置依赖**：不先改这里的接口签名，Task 7 改完那两行后会在这里产生新的编译错误。

**依赖**: 无直接依赖 Task 3/4/5（这是独立的基础设施包），但逻辑上应在 Task 7 之前完成。

- [ ] **Step 1: 修改 audit.Writer 接口与实现**

`internal_infrastructure_audit_writer_go.yaml`：把 `Entry` 结构体的 `ActorUID`、`Writer` 接口的 `Write` 方法、`SQLWriter.Write`、`MemoryWriter.Write` 里所有代表 actor UID 的参数/字段从 `int64` 改成 `string`。`SQLWriter.Write` 内部如果有 `var actor *int64` 这样的中间变量，改成 `var actor *string`。用 `Read` 工具读取该文件全文，确认每一处 `int64` 出现的上下文都与 actor UID 相关（而不是其他无关字段）后再逐处替换。

`internal_infrastructure_audit_writer_test_go.yaml`：把测试里代表 actor UID 的整数字面量（例如 `7`）改成字符串字面量（`"7"`）。

- [ ] **Step 2: 修改 token store**

`internal_infrastructure_token_memory_go.yaml`：把 `SetRefresh`/`GetRefresh` 方法签名里的 `uid int64`/返回值 `int64` 改成 `string`；**删除**内部用于 int64↔string 转换的 `strconv.FormatInt`/`strconv.ParseInt` 调用代码（直接用 uid 本身，不再转换），如果删除转换代码后 `"strconv"` import 不再被使用，一并删除该 import。

`internal_infrastructure_token_redis_go.yaml`：同样把 `SetRefresh`/`GetRefresh` 签名里的 `uid int64`/返回值 `int64` 改成 `string`（这个文件在 Task 1 已经改过 rbac-kitex 版本的同款问题，这里改的是 admin-services-kitex 的独立副本）。

`internal_infrastructure_token_store_go.yaml`：把 `Store` 接口的 `SetRefresh(ctx, uid int64, ...)`/`GetRefresh(ctx, ...) (uid int64, err error)` 签名改成 `string`。

`internal_infrastructure_token_memory_test_go.yaml`：把测试里的整数字面量（如 `42`）改成字符串字面量（`"42"`）。

- [ ] **Step 3: 修改 JWT**

`internal_infrastructure_auth_jwt_go.yaml`：把 `Claims` 结构体的 `Uid`、`JWTManager.Sign` 方法签名里的 uid 参数从 `int64` 改成 `string`。

`internal_infrastructure_auth_jwt_test_go.yaml`：把测试里的整数字面量（如 `1`）改成字符串字面量（`"1"`）。

- [ ] **Step 4: 渲染验证**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir admin-services-kitex
cd /tmp/ncgo-verify && go build ./internal/infrastructure/... 2>&1 | head -30
```
Expected: `internal/infrastructure/audit`、`internal/infrastructure/token`、`internal/infrastructure/auth` 不再报 ID 类型相关错误。

- [ ] **Step 5: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_infrastructure_audit_writer_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_audit_writer_test_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_token_memory_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_token_memory_test_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_token_redis_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_token_store_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml \
        admin-services-kitex/kitex-template/internal_infrastructure_auth_jwt_test_go.yaml
git commit -m "fix(admin-services-kitex): migrate audit writer, token store, jwt claims to string uid"
```

---

### Task 7: admin-services-kitex application 层迁移（含 Issue #37 原始范围）

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_application_user_dto_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_role_dto_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_dto_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_rbac_dto_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_rbac_enforce_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_auth_auth_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_rbac_enforce_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_auth_auth_service_test_go.yaml`

**Interfaces:**
- Consumes: Task 4/5 的 domain+repository 层 `string` ID，Task 6 的 audit/token/jwt `string` uid 接口。
- Produces: application 层完整对齐 string ID，供 Task 8（handler 层）调用。

**依赖**: Task 3、4、5、6。

- [ ] **Step 1: 修改 dto 字段类型**

`internal_application_user_dto_go.yaml`：`ID int64` → `ID string`（约 18 行）。

`internal_application_role_dto_go.yaml`：`ID int64` → `ID string`（约 15 行）。

`internal_application_permission_dto_go.yaml`：`ID int64` → `ID string`（约 27 行）；`ParentID int64` → `ParentID string`（约 11、48 行，两处不同 struct 里都有）；`*ParentID *int64` → `*string`（约 31 行）。

`internal_application_rbac_dto_go.yaml`：`Uid int64` → `Uid string`（约 6 行）。

用 `grep -n "int64" admin-services-kitex/kitex-template/internal_application_{user,role,permission,rbac}_dto_go.yaml` 确认改完。

- [ ] **Step 2: 修改 user/role service 签名（同步 repository 层改动）**

`internal_application_user_user_service_go.yaml`、`internal_application_role_role_service_go.yaml`：接口定义与实现里所有 ID 相关方法参数从 `int64` 改成 `string`，与 Task 5 的 repository 签名保持一致。

- [ ] **Step 3: 修复 Issue #37 原始范围 —— audit.Write 调用**

`internal_application_role_role_service_go.yaml`：把所有 4 处 `s.audit.Write(ctx, 0, "role.create"/"role.update"/"role.delete"/"role.grant_permissions", ...)` 的 `ctx, 0,` 改成 `ctx, "",`（与 Task 1 的 rbac-kitex 修法一致）。

`internal_application_user_user_service_go.yaml`：同样把 4 处 `s.audit.Write(ctx, 0, "user.create"/"user.update"/"user.delete"/"user.assign_roles", ...)` 的 `ctx, 0,` 改成 `ctx, "",`。

`internal_application_permission_permission_service_go.yaml`：把 3 处 `s.audit.Write(ctx, 0, "permission.create"/"permission.update"/"permission.delete", ...)` 的 `ctx, 0,` 改成 `ctx, "",`。

- [ ] **Step 4: 修改 permission service 的哨兵值过滤逻辑**

`internal_application_permission_permission_service_go.yaml` 里找到约 156-169 行附近的：
```go
if filter.Type != "" || filter.ParentID >= 0 || filter.Status >= 0 {
    ...
    parentID := filter.ParentID
    if parentID == 0 {
        parentID = -1
    }
    perms, err = s.perms.ListFiltered(ctx, filter.Type, parentID, status, filter.PageSize, offset)
```
改成：
```go
if filter.Type != "" || filter.ParentID != "" || filter.Status >= 0 {
    ...
    perms, err = s.perms.ListFiltered(ctx, filter.Type, filter.ParentID, status, filter.PageSize, offset)
```
（省略号 `...` 处是原有的中间逻辑，保持不变；先用 `Read` 工具读取该文件确认完整上下文再编辑，不要盲目按行号替换。）

- [ ] **Step 5: 修改 menu query service**

`internal_application_menu_menu_query_service_go.yaml`：`ListRoles`/`ListByRoleIDs`/`UserPermCodes`/`UserMenuTree` 方法签名里的 ID 相关参数从 `int64`/`[]int64` 改成 `string`/`[]string`；内部的 `roleIDs := make([]int64, ...)` 改成 `make([]string, ...)`。

- [ ] **Step 6: 修改 enforce service**

`internal_application_rbac_enforce_service_go.yaml`：`Enforce(ctx, uid int64, ...)` 改成 `uid string`。

- [ ] **Step 7: 修复 Issue #37 原始范围 —— ValidateToken 与相关签名**

`internal_application_auth_auth_service_go.yaml`：
- `GetByID`/`ListRoles`/`Sign`/内部 `roleCodes(ctx, uid int64)` 等方法签名里的 uid 参数从 `int64` 改成 `string`（对齐 Task 6 的 JWT/token 接口）
- 内部局部变量 `var uid int64` 改成 `var uid string`
- `ValidateToken` 方法的返回值签名 `(uid int64, roles []string, valid bool)` 改成 `(uid string, roles []string, valid bool)`
- `ValidateToken` 的两处失败分支 `return 0, nil, false` 改成 `return "", nil, false`

- [ ] **Step 8: 修改 application 层测试文件字面量**

`internal_application_user_user_service_test_go.yaml`：`map[int64]*...` 改成 `map[string]*...`（3 处）；`u.ID = f.nextID` 改成 `u.ID = fmt.Sprint(f.nextID)`；`repo.roleDefs[1] = ...ID: 1` 改成 `repo.roleDefs["1"] = ...ID: "1"`；`AssignRoles(ctx, created.ID, []int64{1})` 改成 `[]string{"1"}`。

`internal_application_role_role_service_test_go.yaml`：同类改动；`gen.ListPermissionIDsByCodesRow{ID: int64(i+1)}` 改成 `ID: fmt.Sprint(i+1)`。

`internal_application_permission_permission_service_test_go.yaml`：`map[int64]*permission.Permission` 改成 `map[string]*permission.Permission`；`p.ID = f.next` 改成 `p.ID = fmt.Sprint(f.next)`。

`internal_application_menu_menu_query_service_test_go.yaml`：字面量 `ID: 1, ParentID: 1` 改成 `ID: "1", ParentID: "1"`。

`internal_application_rbac_enforce_service_test_go.yaml`：`Enforce(ctx, 1, ...)` 改成 `Enforce(ctx, "1", ...)`。

`internal_application_auth_auth_service_test_go.yaml`：`map[int64]...` 改成 `map[string]...`；`u.ID = 1` 改成 `u.ID = "1"`；`uid != 1` 改成 `uid != "1"`。

对每个测试文件先用 `grep -n "int64\|ID: [0-9]\|== [0-9]\|!= [0-9]" <file>` 定位全部字面量位置，再逐处确认上下文后修改（避免误改无关的数值字面量，比如分页参数、状态码等不需要改动）。

- [ ] **Step 9: 渲染验证**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir admin-services-kitex
cd /tmp/ncgo-verify && go build ./... 2>&1 | head -30
```
Expected: 编译错误应该只剩下 handler 层（Task 8 处理），application 层不应再报错。

- [ ] **Step 10: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_application_user_dto_go.yaml \
        admin-services-kitex/kitex-template/internal_application_role_dto_go.yaml \
        admin-services-kitex/kitex-template/internal_application_permission_dto_go.yaml \
        admin-services-kitex/kitex-template/internal_application_rbac_dto_go.yaml \
        admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_rbac_enforce_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_auth_auth_service_go.yaml \
        admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_rbac_enforce_service_test_go.yaml \
        admin-services-kitex/kitex-template/internal_application_auth_auth_service_test_go.yaml
git commit -m "fix(admin-services-kitex): migrate application layer to string ID, fix audit.Write/ValidateToken"
```

---

### Task 8: admin-services-kitex handler 层修复

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml`

**Interfaces:**
- Consumes: Task 2 的 `ValidateTokenResp.Roles` proto 字段、Task 7 的 application 层 string 签名。
- `internal_handler_authservice_handler_go.yaml` 预期**不需要修改**——它已经写死使用 `Roles` 字段名，Task 2 把 proto 字段改名为 `roles` 后应自动生成匹配的 `Roles` Go 字段，此任务需要验证这一点成立。

**依赖**: Task 2、Task 7。

- [ ] **Step 1: 修改 rbacservice handler 的哨兵值**

`internal_handler_rbacservice_handler_go.yaml` 第 216 行附近：
```go
ListPermissionsFilter{..., ParentID: -1}
```
改成：
```go
ListPermissionsFilter{..., ParentID: ""}
```
（`...` 处是其余字段，保持不变；先用 `Read` 工具确认完整的结构体字面量再编辑。）

- [ ] **Step 2: 渲染验证 authservice handler 是否自动通过**

```bash
rm -rf /tmp/ncgo-verify && mkdir -p /tmp/ncgo-verify
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify --template-dir admin-services-kitex
cd /tmp/ncgo-verify && go build ./internal/handler/... 2>&1
```
Expected: 无输出。如果 `internal/handler/authservice` 仍报 `unknown field Roles` 或类似错误，回到 Task 2 检查 proto 字段名是否改对（应该是 `roles` 而不是其他名字，且 kitex 生成器会把 proto 字段名转成 Go 导出字段名 `Roles`）。

- [ ] **Step 3: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml
git commit -m "fix(admin-services-kitex): update handler filter sentinel to empty string"
```

---

### Task 9: 全量渲染验证（rbac-kitex + admin-services-kitex）

**Files:** 无新增/修改文件，仅验证。

**Interfaces:** 消费 Task 1~8 的全部产出，确认两个模板都能完整渲染并通过编译/测试。

**依赖**: Task 1~8 全部完成。

- [ ] **Step 1: 验证 rbac-kitex**

```bash
rm -rf /tmp/ncgo-verify-rbac && mkdir -p /tmp/ncgo-verify-rbac
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify-rbac --template-dir rbac-kitex
cd /tmp/ncgo-verify-rbac && go build ./... && go vet ./... && go test ./...
```
Expected: 三条命令全部通过（退出码 0）。

- [ ] **Step 2: 验证 admin-services-kitex**

```bash
rm -rf /tmp/ncgo-verify-admin && mkdir -p /tmp/ncgo-verify-admin
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-verify-admin --template-dir admin-services-kitex
cd /tmp/ncgo-verify-admin && go build ./... && go vet ./... && go test ./...
```
Expected: 三条命令全部通过（退出码 0）。如果 `go test` 失败，检查是否有测试文件的字面量遗漏（回到 Task 4/5/6/7 相应的 test 文件补漏）。

- [ ] **Step 3: 如果发现遗漏，记录并修复**

如果 Step 1 或 Step 2 报错，用错误信息定位到具体文件（错误信息里的文件路径去掉 `internal/` 前缀、把 `/` 换成 `_`、把 `.go` 换成 `_go.yaml` 一般就能找到对应模板文件，例如 `internal/domain/user/entity.go` → `internal_domain_user_entity_go.yaml`），修复后回到 Step 1/2 重新验证，直至全部通过。修复的改动归入产生问题的原任务的 commit 范围内（用 `git commit --amend` 或者新增一个 `fix: address remaining <template> build errors` 的 commit，二选一，取决于原任务的 commit 是否已经推送/是否希望保持任务边界清晰——本计划推荐用新 commit，避免 amend 打乱其他任务已经完成的评审）。

---

### Task 10: 新增 CI 校验

**Files:**
- Create: `.github/workflows/template-build-check.yml`

**Interfaces:** 无代码接口，纯 CI 配置。

**依赖**: 无直接依赖，但建议放在最后，确保本地已验证两个模板都能编译通过后再固化为 CI。

- [ ] **Step 1: 编写 workflow 文件**

创建 `.github/workflows/template-build-check.yml`：
```yaml
name: Template Build Check

on:
  pull_request:
    paths:
      - 'rbac-kitex/**'
      - 'admin-services-kitex/**'

jobs:
  build-check:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        template: [rbac-kitex, admin-services-kitex]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Install ncgo
        run: go install github.com/byx-darwin/ncgo@latest

      - name: Render ${{ matrix.template }}
        run: |
          ncgo new scratch \
            --module github.com/acme/scratch \
            --kind kitex \
            --dir /tmp/scratch-${{ matrix.template }} \
            --template-dir ${{ matrix.template }}

      - name: Build
        working-directory: /tmp/scratch-${{ matrix.template }}
        run: go build ./...

      - name: Vet
        working-directory: /tmp/scratch-${{ matrix.template }}
        run: go vet ./...
```

**注意**：`Install ncgo` 步骤里的模块路径 `github.com/byx-darwin/ncgo` 需要在实施时用 `go list -m` 或查阅 `ncgo` 二进制的实际来源仓库确认是否正确（本地 `command -v ncgo` 显示装在 `$(go env GOPATH)/bin/ncgo`，来源仓库路径需要在执行本任务时向用户确认或查找 `go env GOPATH`/`~/go/pkg/mod` 下的实际 module path，不要假设）。

- [ ] **Step 2: 本地验证 workflow 语法**

```bash
# 如果本地有 actionlint，用它校验语法；没有则至少用 yamllint 或 python -c "import yaml; yaml.safe_load(open('.github/workflows/template-build-check.yml'))" 确认 YAML 合法
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/template-build-check.yml'))" && echo "YAML OK"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/template-build-check.yml
git commit -m "ci: add template render + build/vet check for rbac-kitex and admin-services-kitex"
```

- [ ] **Step 4: 推送后在 PR 里确认 CI 实际跑通**

这一步在 Phase 3 交付阶段（推送分支/开 PR 后）验证，本地无法验证 GitHub Actions 是否真的执行成功，需要观察 PR 的 Checks 状态。

---

## Self-Review Notes

- **Spec 覆盖检查**：设计文档 A/B1-B10/C/D 各节均有对应任务（A→Task 1，B1-B2→Task 3，B3-B5→Task 4，B6→Task 5，B9→Task 6，B7-B8, B10→Task 7/8，C→Task 2，D→Task 10），Task 9 补充设计文档里"验证方式"一节要求的全量验证闭环。
- **占位符检查**：已通读全文，未发现 "TBD"/"实现细节后补" 等占位表述；个别步骤要求执行者先 `grep`/`Read` 确认精确行号再编辑，这是因为文件行号会随前序任务改动漂移，不是内容缺失。
- **类型一致性**：Task 4 定义的 repository 接口签名（`string`/`[]string`）与 Task 5 的实现、Task 7 的 application 层调用点保持一致；`Count(ctx) (int64, error)` 在所有任务中一致保留为 `int64`，未被误改。
