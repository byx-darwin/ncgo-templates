# RBAC ID 方案回退（BIGSERIAL + users.uuid）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `rbac-kitex` 与 `admin-services-kitex` 两个模板的 `users`/`roles`/`permissions` 主键从 `TEXT` 改回 `BIGSERIAL` 自增整数，`users` 表新增应用层生成的 `uuid TEXT UNIQUE` 列作为对外标识，`roles`/`permissions` 对外 ID 改为内部整数的十进制字符串形式，同时保持 JWT/Casbin 身份标识、DTO/proto 外部契约类型不变。

**Architecture:** Schema/migration/sqlc query 三处一起把主键列类型改回 `BIGSERIAL`/`BIGINT` 并给 `users` 加 `uuid` 列；domain 实体与 repository 接口把 `ID`/`id` 参数类型从 `string` 改为 `int64`（`user.User` 另加 `UUID string` 字段）；repository 实现层用 `github.com/google/uuid` 的 `uuid.NewV7()` 在 `Save()` 时生成 UUID 并新增 `GetByUUID`；application service 层是唯一做"外部字符串 ⇄ 内部 int64"边界转换的地方（users 用 `GetByUUID` 解析，roles/permissions 用 `strconv`），service 对外方法签名（`*Input.ID string` 等）保持不变，因此 handler 层的 DTO 构造代码零改动；只有 handler 里从 domain 实体读字段构建 `v1.User`/`v1.Role`/`v1.Permission`/`v1.Menu`（`toV1User` 等辅助函数）以及 `GetRoleCodes(ctx, u.ID)` 调用点需要跟着实体字段类型变化同步修正（因为它们直接引用了改类型的字段）。两个模板的对应文件逐字节相同（除 import 路径/注释等无关差异），改动逐一对称应用，不做跨模板去重。

**Tech Stack:** Go 1.22+, PostgreSQL, sqlc, pgx/v5, Kitex, Casbin v2, `github.com/golang-jwt/jwt/v5`, `github.com/google/uuid`（新增依赖，通过 `go mod tidy` 自动补齐 go.mod，不需要手工编辑任何模板文件声明依赖）。

**Spec:** `docs/superpowers/specs/2026-09-07-rbac-id-scheme-revert-design.md`

## Global Constraints

- JWT `Claims.Uid` 与 Casbin 策略主体（subject）永远是 UUID 字符串，本次改动完全不touch `internal/infrastructure/auth/jwt.go`、`internal/infrastructure/casbin/adapter.go` 和 `internal/infrastructure/casbin/enforcer.go` —— 这两个文件不在任何 Task 的 Files 列表里。
- DTO（`usersvc.*Input`、`rolesvc.*Input`、`permsvc.*Input`/`ListPermissionsFilter`）与 proto/`v1.*` 字段类型保持 `string` 不变；int64⇄UUID/字符串的转换只发生在 repository 实现（`internal/repository/**/repo.go`）与 application service（`internal/application/**/*_service.go`）内部。
- 两个模板（`rbac-kitex`、`admin-services-kitex`）各自独立维护一份文件，本次逐一对称修改，不做去重（去重是 Issue #43 的范围，不在本次任务内）。
- 不实现真实 Postgres 集成测试；`internal_repository_user_repo_test_go.yaml` 里已有的 postgres round-trip 测试保持"gated on pg_isready + POSTGRES_DSN"的现状，只做类型适配，不新增真实 DB 断言。
- 不修改 `casbin_rule`、`audit_log`、`rate_limit_rules`（已是 `BIGSERIAL`/不受影响）。
- `uuid.NewV7()` 只在 `internal/repository/user/repo.go` 的 `Save()` 里调用一次；import 语句直接写 `"github.com/google/uuid"`，不需要修改任何 `go.mod`/`go.sum` 模板文件，`make tidy`/`go mod tidy` 会自动补齐依赖声明。
- 每个 Task 完成后用该 Task Files 里列出的 Go 包范围跑 `go test`（见下方"渲染 + 局部测试"命令模板）；只有最后一个 Task（handler + 全量验收）要求整个渲染项目 `go build ./...` 且 `go test ./...` 全绿。

**渲染 + 局部测试命令模板**（每个 Task 的验证步骤都基于此，仅替换 `TPL_DIR`/`MOD`/`PKG`）：

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
TPL_DIR="$REPO_ROOT/rbac-kitex"           # admin-services-kitex 任务改成 "$REPO_ROOT/admin-services-kitex"
MOD="example.com/rbac-e2e"                # admin-services-kitex 任务改成 "example.com/admin-e2e"
DIR="$(mktemp -d)"
ncgo new tplcheck --module "$MOD" --kind kitex --template-dir "$TPL_DIR" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck"
make sqlc
go test ./internal/domain/...            # 按 Task 替换成该 Task Files 覆盖的包路径
```

若 `ncgo`/`kitex`/`protoc`/`sqlc` 任一工具缺失，按 `rbac-kitex/test/e2e_test.sh` 的既有约定打印 `skipped: <工具> 未安装` 并停止该验证步骤，不算作失败，但也不能跳过代码编辑本身。

---

### Task 1: rbac-kitex — Schema + Migration + sqlc Query 改动

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_db_schema_000001_rbac_sql.yaml`
- Modify: `rbac-kitex/kitex-template/migration_init.yaml`
- Modify: `rbac-kitex/kitex-template/internal_db_query_rbac_sql.yaml`

**Interfaces:**
- Produces: `users(id BIGSERIAL, uuid TEXT UNIQUE NOT NULL, ...)`、`roles(id BIGSERIAL, ...)`、`permissions(id BIGSERIAL, ..., parent_id BIGINT, ...)`、`user_roles(user_id BIGINT, role_id BIGINT)`、`role_permissions(role_id BIGINT, permission_id BIGINT)` 表结构；sqlc 查询 `CreateUser`（新增 uuid 列）、新增 `GetUserByUUID`、`ListPermissionsFiltered`（parent_id 用 `bigint` 0 哨兵值代替空字符串）、`ListPermissionsByRoleIDs`（`role_id = ANY($1::bigint[])`）。这些是 Task 3/4 里 `internal/db/gen` 生成代码的类型来源。

这个 Task 没有独立的 Go 单元测试（纯 SQL/DDL），用 `make sqlc` 渲染验证语法与类型推导正确性即可；`go build`/`go test` 的绿灯留到 Task 3（repository 层）一起验证。

- [ ] **Step 1: 重写 schema 文件**

编辑 `rbac-kitex/kitex-template/internal_db_schema_000001_rbac_sql.yaml`，把 `body:` 整体替换为：

```yaml
# ncgo exported template — internal/db/schema/000001_rbac.sql
path: internal/db/schema/000001_rbac.sql
update_behavior:
    type: cover
body: |-
    CREATE TABLE users (
        id BIGSERIAL PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        nickname TEXT,
        avatar TEXT,
        email TEXT,
        phone TEXT,
        status INTEGER NOT NULL DEFAULT 1,  -- 1=enabled, 0=disabled
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE roles (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 1,
        remark TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE permissions (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('catalog','menu','button','api')),
        name TEXT NOT NULL,
        parent_id BIGINT REFERENCES permissions(id),  -- no ON DELETE CASCADE; app-layer cascade
        path TEXT,
        icon TEXT,
        route_name TEXT,
        redirect TEXT,
        keep_alive BOOLEAN,
        hide_in_menu BOOLEAN,
        is_external BOOLEAN,
        method TEXT CHECK (method IS NULL OR method IN ('GET','POST','PUT','DELETE')),
        sort INTEGER,
        status INTEGER NOT NULL DEFAULT 1,
        description TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (code, type)
    );

    CREATE INDEX idx_permissions_parent ON permissions(parent_id);
    CREATE INDEX idx_permissions_type ON permissions(type);

    CREATE TABLE user_roles (
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, role_id)
    );

    CREATE TABLE role_permissions (
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        permission_id BIGINT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
        PRIMARY KEY (role_id, permission_id)
    );

    CREATE TABLE casbin_rule (
        id BIGSERIAL PRIMARY KEY,
        ptype TEXT NOT NULL,
        v0 TEXT NOT NULL DEFAULT '',
        v1 TEXT NOT NULL DEFAULT '',
        v2 TEXT NOT NULL DEFAULT '',
        v3 TEXT NOT NULL DEFAULT '',
        v4 TEXT NOT NULL DEFAULT '',
        v5 TEXT NOT NULL DEFAULT '',
        UNIQUE (ptype, v0, v1, v2, v3, v4, v5)
    );

    CREATE TABLE audit_log (
        id BIGSERIAL PRIMARY KEY,
        actor_uid TEXT,
        action TEXT NOT NULL,
        target TEXT NOT NULL DEFAULT '',
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX idx_casbin_rule_policy ON casbin_rule(ptype, v0, v1, v2);
```

- [ ] **Step 2: 重写 migration 文件**

编辑 `rbac-kitex/kitex-template/migration_init.yaml`，把 `body:` 整体替换为（Up 部分与 schema 一致，Down 部分不变）：

```yaml
# ncgo exported template — internal/db/migrations/000001_init.sql
path: internal/db/migrations/000001_init.sql
update_behavior:
    type: cover
body: |-
    -- +goose Up
    CREATE TABLE users (
        id BIGSERIAL PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        nickname TEXT,
        avatar TEXT,
        email TEXT,
        phone TEXT,
        status INTEGER NOT NULL DEFAULT 1,  -- 1=enabled, 0=disabled
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE roles (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 1,
        remark TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE permissions (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('catalog','menu','button','api')),
        name TEXT NOT NULL,
        parent_id BIGINT REFERENCES permissions(id),  -- no ON DELETE CASCADE; app-layer cascade
        path TEXT,
        icon TEXT,
        route_name TEXT,
        redirect TEXT,
        keep_alive BOOLEAN,
        hide_in_menu BOOLEAN,
        is_external BOOLEAN,
        method TEXT CHECK (method IS NULL OR method IN ('GET','POST','PUT','DELETE')),
        sort INTEGER,
        status INTEGER NOT NULL DEFAULT 1,
        description TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (code, type)
    );

    CREATE INDEX idx_permissions_parent ON permissions(parent_id);
    CREATE INDEX idx_permissions_type ON permissions(type);

    CREATE TABLE user_roles (
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, role_id)
    );

    CREATE TABLE role_permissions (
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        permission_id BIGINT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
        PRIMARY KEY (role_id, permission_id)
    );

    CREATE TABLE casbin_rule (
        id BIGSERIAL PRIMARY KEY,
        ptype TEXT NOT NULL,
        v0 TEXT NOT NULL DEFAULT '',
        v1 TEXT NOT NULL DEFAULT '',
        v2 TEXT NOT NULL DEFAULT '',
        v3 TEXT NOT NULL DEFAULT '',
        v4 TEXT NOT NULL DEFAULT '',
        v5 TEXT NOT NULL DEFAULT '',
        UNIQUE (ptype, v0, v1, v2, v3, v4, v5)
    );

    CREATE TABLE audit_log (
        id BIGSERIAL PRIMARY KEY,
        actor_uid TEXT,
        action TEXT NOT NULL,
        target TEXT NOT NULL DEFAULT '',
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX idx_casbin_rule_policy ON casbin_rule(ptype, v0, v1, v2);

    -- +goose Down
    DROP TABLE IF EXISTS audit_log;
    DROP TABLE IF EXISTS casbin_rule;
    DROP TABLE IF EXISTS role_permissions;
    DROP TABLE IF EXISTS user_roles;
    DROP TABLE IF EXISTS permissions;
    DROP TABLE IF EXISTS roles;
    DROP TABLE IF EXISTS users;
```

- [ ] **Step 3: 重写 sqlc query 文件**

编辑 `rbac-kitex/kitex-template/internal_db_query_rbac_sql.yaml`，把 `body:` 整体替换为（相对原文件的关键改动：`CreateUser` 加 `uuid` 列并新增第一个参数；新增 `GetUserByUUID`；`ListPermissionsByRoleIDs` 的数组 cast 从 `::text[]` 改成 `::bigint[]`；`ListPermissionsFiltered` 的 parent_id 判空条件从 `$2 = ''` 改成 `$2::bigint = 0`）：

```yaml
# ncgo exported template — internal/db/query/rbac.sql
path: internal/db/query/rbac.sql
update_behavior:
    type: cover
body: |-
    -- name: CreateUser :one
    INSERT INTO users (uuid, username, password_hash, nickname, avatar, email, phone, status)
    VALUES ($1, $2, $3, $4, $5, $6, $7, 1) RETURNING *;
    -- name: GetUserByID :one
    SELECT * FROM users WHERE id = $1;
    -- name: GetUserByUUID :one
    SELECT * FROM users WHERE uuid = $1;
    -- name: GetUserByUsername :one
    SELECT * FROM users WHERE username = $1;
    -- name: ListUsers :many
    SELECT * FROM users ORDER BY id LIMIT $1 OFFSET $2;
    -- name: CountUsers :one
    SELECT count(*) FROM users;
    -- name: UpdateUser :one
    UPDATE users SET
        username = COALESCE($2, username),
        nickname = COALESCE($3, nickname),
        avatar = COALESCE($4, avatar),
        email = COALESCE($5, email),
        phone = COALESCE($6, phone),
        status = COALESCE($7, status),
        updated_at = now()
    WHERE id = $1 RETURNING *;
    -- name: UpdateUserPassword :one
    UPDATE users SET password_hash = $1, updated_at = now() WHERE id = $2 RETURNING *;
    -- name: DeleteUser :exec
    DELETE FROM users WHERE id = $1;
    -- name: AddUserRole :exec
    INSERT INTO user_roles (user_id, role_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;
    -- name: RemoveUserRole :exec
    DELETE FROM user_roles WHERE user_id = $1 AND role_id = $2;
    -- name: ClearUserRoles :exec
    DELETE FROM user_roles WHERE user_id = $1;
    -- name: ListRolesByUserID :many
    SELECT r.* FROM roles r JOIN user_roles ur ON ur.role_id = r.id WHERE ur.user_id = $1 ORDER BY r.id;
    -- name: ListRoleIDsByUserID :many
    SELECT role_id FROM user_roles WHERE user_id = $1;

    -- name: CreateRole :one
    INSERT INTO roles (code, name, status, remark) VALUES ($1, $2, 1, $3) RETURNING *;
    -- name: GetRoleByID :one
    SELECT * FROM roles WHERE id = $1;
    -- name: GetRoleByCode :one
    SELECT * FROM roles WHERE code = $1;
    -- name: ListRoles :many
    SELECT * FROM roles ORDER BY id LIMIT $1 OFFSET $2;
    -- name: CountRoles :one
    SELECT count(*) FROM roles;
    -- name: UpdateRole :one
    UPDATE roles SET
        name = COALESCE($2, name),
        status = COALESCE($3, status),
        remark = COALESCE($4, remark),
        updated_at = now()
    WHERE id = $1 RETURNING *;
    -- name: DeleteRole :exec
    DELETE FROM roles WHERE id = $1;
    -- name: AddRolePermission :exec
    INSERT INTO role_permissions (role_id, permission_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;
    -- name: RemoveRolePermission :exec
    DELETE FROM role_permissions WHERE role_id = $1 AND permission_id = $2;
    -- name: ClearRolePermissions :exec
    DELETE FROM role_permissions WHERE role_id = $1;
    -- name: ListPermissionCodesByRoleID :many
    SELECT p.code FROM permissions p
    JOIN role_permissions rp ON rp.permission_id = p.id
    WHERE rp.role_id = $1
    ORDER BY p.code;
    -- name: ListPermissionIDsByCodes :many
    SELECT id, code FROM permissions WHERE code = ANY($1::text[]);
    -- name: ListPermissionsByRoleIDs :many
    SELECT DISTINCT p.* FROM permissions p JOIN role_permissions rp ON rp.permission_id = p.id WHERE rp.role_id = ANY($1::bigint[]) ORDER BY p.id;

    -- Permission queries (revised for single tree)

    -- name: CreatePermission :one
    INSERT INTO permissions (code, type, name, parent_id, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, method, sort, status, description)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) RETURNING *;

    -- name: GetPermissionByID :one
    SELECT * FROM permissions WHERE id = $1;

    -- name: GetPermissionByCode :many
    SELECT * FROM permissions WHERE code = $1 ORDER BY type;

    -- name: GetPermissionByCodeAndType :one
    SELECT * FROM permissions WHERE code = $1 AND type = $2;

    -- name: ListPermissions :many
    SELECT * FROM permissions ORDER BY sort NULLS LAST, id LIMIT $1 OFFSET $2;
    -- name: CountPermissions :one
    SELECT count(*) FROM permissions;

    -- name: ListPermissionsFiltered :many
    SELECT * FROM permissions
    WHERE ($1 = '' OR type = $1)
      AND ($2::bigint = 0 OR parent_id = $2::bigint)
      AND ($3 < 0 OR status = $3)
    ORDER BY sort NULLS LAST, id
    LIMIT $4 OFFSET $5;

    -- name: ListPermissionsByCodes :many
    SELECT * FROM permissions WHERE code = ANY($1::text[]) ORDER BY code, type;

    -- name: UpdatePermission :one
    UPDATE permissions SET
        code = COALESCE($2, code),
        type = COALESCE($3, type),
        name = COALESCE($4, name),
        parent_id = COALESCE($5, parent_id),
        path = COALESCE($6, path),
        icon = COALESCE($7, icon),
        route_name = COALESCE($8, route_name),
        redirect = COALESCE($9, redirect),
        keep_alive = COALESCE($10, keep_alive),
        hide_in_menu = COALESCE($11, hide_in_menu),
        is_external = COALESCE($12, is_external),
        method = COALESCE($13, method),
        sort = COALESCE($14, sort),
        status = COALESCE($15, status),
        description = COALESCE($16, description),
        updated_at = now()
    WHERE id = $1 RETURNING *;

    -- name: DeletePermission :exec
    DELETE FROM permissions WHERE id = $1;

    -- name: ListChildPermissionIDs :many
    SELECT id FROM permissions WHERE parent_id = $1;

    -- Menu read-only queries (view over permissions WHERE type IN ('catalog','menu'))

    -- name: ListMenusAsTree :many
    SELECT id, code, name, parent_id, type, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, sort
    FROM permissions
    WHERE type IN ('catalog', 'menu') AND status = 1
    ORDER BY sort NULLS LAST, id;

    -- name: ListMenusByParentID :many
    SELECT id, code, name, parent_id, type, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, sort
    FROM permissions
    WHERE type IN ('catalog', 'menu') AND status = 1 AND parent_id = $1
    ORDER BY sort NULLS LAST, id;

    -- name: ListCasbinRules :many
    SELECT ptype, v0, v1, v2, v3, v4, v5 FROM casbin_rule ORDER BY id;
    -- name: InsertCasbinRule :one
    INSERT INTO casbin_rule (ptype, v0, v1, v2, v3, v4, v5) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (ptype, v0, v1, v2, v3, v4, v5) DO NOTHING RETURNING id;
    -- name: DeleteCasbinRule :exec
    DELETE FROM casbin_rule WHERE ptype = $1 AND v0 = $2 AND v1 = $3 AND v2 = $4 AND v3 = $5 AND v4 = $6 AND v5 = $7;
    -- name: ClearCasbinRules :exec
    DELETE FROM casbin_rule;
    -- name: DeleteCasbinRuleFiltered :exec
    DELETE FROM casbin_rule WHERE ptype = $1
      AND ($2 = '' OR v0 = $2) AND ($3 = '' OR v1 = $3) AND ($4 = '' OR v2 = $4)
      AND ($5 = '' OR v3 = $5) AND ($6 = '' OR v4 = $6) AND ($7 = '' OR v5 = $7);
    -- name: CountCasbinRules :one
    SELECT count(*) FROM casbin_rule;

    -- name: InsertAuditLog :one
    INSERT INTO audit_log (actor_uid, action, target, detail_json) VALUES ($1, $2, $3, $4) RETURNING id;
```

- [ ] **Step 4: 渲染验证 sqlc 生成成功**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc
```

Expected: sqlc 生成成功退出码 0；生成的 `internal/db/gen/models.go` 里 `User.ID`/`Role.ID`/`Permission.ID` 均为 `int64`，`User` 新增 `UUID string` 字段，`Permission.ParentID` 为 `*int64`。若 `ncgo`/`sqlc` 未安装，打印 `skipped: sqlc 未安装` 并跳过，不算失败。

- [ ] **Step 5: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_db_schema_000001_rbac_sql.yaml rbac-kitex/kitex-template/migration_init.yaml rbac-kitex/kitex-template/internal_db_query_rbac_sql.yaml
git commit -m "feat(rbac-kitex): revert users/roles/permissions PK to BIGSERIAL, add users.uuid"
```

---

### Task 2: rbac-kitex — Domain 实体 + Repository 接口 + Domain 单测

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_domain_user_entity_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_role_entity_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_permission_entity_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_menu_entity_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_user_repository_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_role_repository_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_permission_repository_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_menu_repository_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml`

**Interfaces:**
- Produces: `user.User{ID int64; UUID string; Username string; PasswordHash string; Nickname string; Avatar string; Email string; Phone string; Status int}`；`role.Role{ID int64; Code string; Name string; Status int; Remark string}`；`permission.Permission{ID int64; ...; ParentID int64 /* 0=root */; ...}`；`permission.New(code, typ, name string, parentID int64, path, icon, routeName, redirect string, keepAlive, hideInMenu, isExternal *bool, method string, sort int32, status int, description string) (*Permission, error)`；`menu.Menu{ID int64; ParentID int64; ...}`；`user.Repository`/`role.Repository`/`permission.Repository`/`menu.Repository` 接口方法签名全部把 `id string`/`parentID string`/`roleIDs []string` 改成 `int64`/`[]int64`，并给 `user.Repository` 新增 `GetByUUID(ctx, uuid string) (*User, error)`。
- Consumes: 无（domain 层不依赖 repository/application/handler）。

这一 Task 的测试可以在渲染后独立跑 `go test ./internal/domain/...`（domain 包互不依赖 repository/application，编译范围小、反馈快）。

- [ ] **Step 1: 写/改失败测试 —— permission entity_test.go 的 `New` 调用改用 int64 parentID**

编辑 `rbac-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml`，把 `body:` 替换为（所有 `New(...)` 调用的第 4 个参数从 `""` 改成 `0`）：

```yaml
# ncgo exported template — internal/domain/permission/entity_test.go
path: internal/domain/permission/entity_test.go
update_behavior:
    type: skip
body: |
    package permission

    import (
    	"strings"
    	"testing"
    )

    func boolPtr(b bool) *bool {{ "{" }} return &b {{ "}" }}

    func TestNewRejectsUnknownType(t *testing.T) {{ "{" }}
    	p, err := New("user:create", "bogus", "Create User", 0, "", "", "", "", nil, nil, nil, "", 0, StatusEnabled, "")
    	if err == nil {{ "{" }}
    		t.Fatalf("New with type=bogus = %+v, want error", p)
    	{{ "}" }}
    	var ve ValidationError
    	_ = ve
    {{ "}" }}

    func TestNewAPIRequiresMethod(t *testing.T) {{ "{" }}
    	p, err := New("user:create", TypeAPI, "Create User", 0, "", "", "", "", nil, nil, nil, "", 0, StatusEnabled, "")
    	if err == nil {{ "{" }}
    		t.Fatalf("New(api, no method) = %+v, want error", p)
    	{{ "}" }}
    	if !strings.Contains(err.Error(), "method") {{ "{" }}
    		t.Fatalf("error = %v, want method validation", err)
    	{{ "}" }}
    {{ "}" }}

    func TestNewAPIRejectsInvalidMethod(t *testing.T) {{ "{" }}
    	p, err := New("user:create", TypeAPI, "Create User", 0, "", "", "", "", nil, nil, nil, "PATCH", 0, StatusEnabled, "")
    	if err == nil {{ "{" }}
    		t.Fatalf("New(api, PATCH) = %+v, want error", p)
    	{{ "}" }}
    {{ "}" }}

    func TestNewAPIAcceptsValidMethods(t *testing.T) {{ "{" }}
    	for _, m := range []string{{ "{" }}"GET", "POST", "PUT", "DELETE", "get"{{ "}" }} {{ "{" }}
    		p, err := New("user:create", TypeAPI, "Create User", 0, "", "", "", "", nil, nil, nil, m, 0, StatusEnabled, "")
    		if err != nil {{ "{" }}
    			t.Fatalf("New(api, %s): %v", m, err)
    		{{ "}" }}
    		if p.Method != strings.ToUpper(m) {{ "{" }}
    			t.Fatalf("method = %q, want %q", p.Method, strings.ToUpper(m))
    		{{ "}" }}
    	{{ "}" }}
    {{ "}" }}

    func TestNewMenuTypeClearsMethod(t *testing.T) {{ "{" }}
    	for _, typ := range []string{{ "{" }}TypeCatalog, TypeMenu, TypeButton{{ "}" }} {{ "{" }}
    		p, err := New("x:"+typ, typ, typ, 0, "", "", "", "", nil, nil, nil, "GET", 0, StatusEnabled, "")
    		if err != nil {{ "{" }}
    			t.Fatalf("New(%s): %v", typ, err)
    		{{ "}" }}
    		if p.Method != "" {{ "{" }}
    			t.Fatalf("type=%s method = %q, want empty", typ, p.Method)
    		{{ "}" }}
    	{{ "}" }}
    {{ "}" }}

    func TestNewAcceptsValidCatalog(t *testing.T) {{ "{" }}
    	p, err := New("system", TypeCatalog, "System", 0, "/system", "setting", "", "", nil, nil, boolPtr(false), "", 1, StatusEnabled, "System module")
    	if err != nil {{ "{" }}
    		t.Fatalf("New: %v", err)
    	{{ "}" }}
    	if p.Code != "system" || p.Type != TypeCatalog || p.Name != "System" {{ "{" }}
    		t.Fatalf("got %+v", p)
    	{{ "}" }}
    	if p.Path != "/system" || p.Icon != "setting" {{ "{" }}
    		t.Fatalf("tree fields: path=%q icon=%q", p.Path, p.Icon)
    	{{ "}" }}
    	if p.Status != StatusEnabled {{ "{" }}
    		t.Fatalf("status = %d, want %d", p.Status, StatusEnabled)
    	{{ "}" }}
    {{ "}" }}

    func TestNewRejectsEmptyCode(t *testing.T) {{ "{" }}
    	_, err := New("", TypeMenu, "Name", 0, "", "", "", "", nil, nil, nil, "", 0, StatusEnabled, "")
    	if err == nil {{ "{" }}
    		t.Fatal("want error for empty code")
    	{{ "}" }}
    {{ "}" }}

    func TestNewRejectsEmptyName(t *testing.T) {{ "{" }}
    	_, err := New("code", TypeMenu, "", 0, "", "", "", "", nil, nil, nil, "", 0, StatusEnabled, "")
    	if err == nil {{ "{" }}
    		t.Fatal("want error for empty name")
    	{{ "}" }}
    {{ "}" }}

    func TestStatusConstants(t *testing.T) {{ "{" }}
    	if StatusEnabled != 1 {{ "{" }}
    		t.Fatalf("StatusEnabled = %d, want 1", StatusEnabled)
    	{{ "}" }}
    	if StatusDisabled != 0 {{ "{" }}
    		t.Fatalf("StatusDisabled = %d, want 0", StatusDisabled)
    	{{ "}" }}
    {{ "}" }}

    func TestTypeConstants(t *testing.T) {{ "{" }}
    	if TypeCatalog != "catalog" || TypeMenu != "menu" || TypeButton != "button" || TypeAPI != "api" {{ "{" }}
    		t.Fatal("type constants mismatch")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 写/改失败测试 —— menu entity_test.go 用 int64 ID/ParentID 字面量**

编辑 `rbac-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/menu/entity_test.go
path: internal/domain/menu/entity_test.go
update_behavior:
    type: skip
body: |
    package menu

    import "testing"

    func TestBuildTree(t *testing.T) {{ "{" }}
    	items := []*Menu{{ "{" }}
    		{{ "{" }}ID: 1, ParentID: 0, Type: TypeCatalog, Name: "System", Sort: 2{{ "}" }},
    		{{ "{" }}ID: 2, ParentID: 1, Type: TypeMenu, Name: "Users", Sort: 1{{ "}" }},
    		{{ "{" }}ID: 3, ParentID: 1, Type: TypeMenu, Name: "Roles", Sort: 2{{ "}" }},
    		{{ "{" }}ID: 4, ParentID: 0, Type: TypeCatalog, Name: "Dashboard", Sort: 1{{ "}" }},
    		{{ "{" }}ID: 5, ParentID: 999, Type: TypeMenu, Name: "Orphan", Sort: 10{{ "}" }},
    	{{ "}" }}

    	roots := BuildTree(items)

    	if len(roots) != 3 {{ "{" }}
    		t.Fatalf("len(roots) = %d, want 3 (Dashboard, System, Orphan)", len(roots))
    	{{ "}" }}
    	// roots ordered by Sort then ID: Dashboard(1), System(2), Orphan(10).
    	if roots[0].Menu.Name != "Dashboard" {{ "{" }}
    		t.Fatalf("roots[0] = %q, want Dashboard", roots[0].Menu.Name)
    	{{ "}" }}
    	if roots[1].Menu.Name != "System" {{ "{" }}
    		t.Fatalf("roots[1] = %q, want System", roots[1].Menu.Name)
    	{{ "}" }}
    	if roots[2].Menu.Name != "Orphan" {{ "{" }}
    		t.Fatalf("roots[2] = %q, want Orphan", roots[2].Menu.Name)
    	{{ "}" }}
    	// System has two children ordered by Sort: Users(1), Roles(2)
    	sys := roots[1]
    	if len(sys.Children) != 2 {{ "{" }}
    		t.Fatalf("System children = %d, want 2", len(sys.Children))
    	{{ "}" }}
    	if sys.Children[0].Menu.Name != "Users" || sys.Children[1].Menu.Name != "Roles" {{ "{" }}
    		t.Fatalf("System children = [%s %s], want [Users Roles]", sys.Children[0].Menu.Name, sys.Children[1].Menu.Name)
    	{{ "}" }}
    {{ "}" }}

    func TestBuildTreeEmpty(t *testing.T) {{ "{" }}
    	roots := BuildTree(nil)
    	if roots != nil {{ "{" }}
    		t.Fatalf("BuildTree(nil) = %v, want nil", roots)
    	{{ "}" }}
    {{ "}" }}

    func TestTypeConstants(t *testing.T) {{ "{" }}
    	if TypeCatalog != "catalog" || TypeMenu != "menu" {{ "{" }}
    		t.Fatal("menu type constants mismatch")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 3: 运行测试，确认在当前实体/接口定义下编译失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && go test ./internal/domain/...
```

Expected: FAIL —— `permission.New` 参数数量/类型不匹配（第 4 个实参 `int` 不能赋给形参 `string`），`menu.Menu` 字面量 `ID: 1` 不能赋给 `string` 字段。

- [ ] **Step 4: 实现 domain 实体改动 —— user entity**

编辑 `rbac-kitex/kitex-template/internal_domain_user_entity_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/user/entity.go
path: internal/domain/user/entity.go
update_behavior:
    type: skip
body: |
    package user

    import "strings"

    const (
    	// StatusEnabled is the default active state.
    	StatusEnabled = 1
    	// StatusDisabled disables a user from logging in.
    	StatusDisabled = 0
    )

    // User is the aggregate root for the user aggregate.
    type User struct {{ "{" }}
    	ID           int64  // internal auto-increment primary key; JOIN/foreign-key use only
    	UUID         string // external identity, generated by the repository (uuid.NewV7)
    	Username     string
    	PasswordHash string
    	Nickname     string
    	Avatar       string
    	Email        string
    	Phone        string
    	Status       int // StatusEnabled (1) or StatusDisabled (0)
    {{ "}" }}

    // New creates a User with default status enabled. It validates the username.
    func New(username, passwordHash string) (*User, error) {{ "{" }}
    	username = strings.TrimSpace(username)
    	if len(username) < 3 {{ "{" }}
    		return nil, ValidationError{{ "{" }}Field: "username", Msg: "must be at least 3 characters"{{ "}" }}
    	{{ "}" }}
    	return &User{{ "{" }}
    		Username:     username,
    		PasswordHash: passwordHash,
    		Status:       StatusEnabled,
    	{{ "}" }}, nil
    {{ "}" }}

    // SetStatus validates and applies an account status.
    func (u *User) SetStatus(status int) error {{ "{" }}
    	if status != StatusEnabled && status != StatusDisabled {{ "{" }}
    		return ValidationError{{ "{" }}Field: "status", Msg: "must be 1 (enabled) or 0 (disabled)"{{ "}" }}
    	{{ "}" }}
    	u.Status = status
    	return nil
    {{ "}" }}
```

- [ ] **Step 5: 实现 domain 实体改动 —— role entity**

编辑 `rbac-kitex/kitex-template/internal_domain_role_entity_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/role/entity.go
path: internal/domain/role/entity.go
update_behavior:
    type: skip
body: |
    package role

    import "strings"

    const (
    	// StatusEnabled is the default active state.
    	StatusEnabled = 1
    	// StatusDisabled disables a role.
    	StatusDisabled = 0
    )

    // Role is the aggregate root for the role aggregate.
    type Role struct {{ "{" }}
    	ID     int64
    	Code   string
    	Name   string
    	Status int // StatusEnabled (1) or StatusDisabled (0)
    	Remark string
    {{ "}" }}

    // New creates a Role. The code must be non-empty and is the value referenced
    // by Casbin policies (p.sub / g.v1).
    func New(code, name string) (*Role, error) {{ "{" }}
    	code = strings.TrimSpace(code)
    	if code == "" {{ "{" }}
    		return nil, ValidationError{{ "{" }}Field: "code", Msg: "must not be empty"{{ "}" }}
    	{{ "}" }}
    	return &Role{{ "{" }}Code: code, Name: name, Status: StatusEnabled{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 6: 实现 domain 实体改动 —— permission entity（`New` 的 parentID 改成 int64）**

编辑 `rbac-kitex/kitex-template/internal_domain_permission_entity_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/permission/entity.go
path: internal/domain/permission/entity.go
update_behavior:
    type: skip
body: |
    package permission

    import "strings"

    const (
    	// TypeCatalog is a top-level classification node in the permission tree.
    	TypeCatalog = "catalog"
    	// TypeMenu is a navigation menu node in the permission tree.
    	TypeMenu = "menu"
    	// TypeButton is a frontend button-level permission.
    	TypeButton = "button"
    	// TypeAPI is a backend API endpoint permission.
    	TypeAPI = "api"

    	// StatusEnabled marks an active permission.
    	StatusEnabled = 1
    	// StatusDisabled marks a disabled permission.
    	StatusDisabled = 0
    )

    // validTypes is the set of allowed permission types.
    var validTypes = map[string]bool{{ "{" }}
    	TypeCatalog: true,
    	TypeMenu:    true,
    	TypeButton:  true,
    	TypeAPI:     true,
    {{ "}" }}

    // validMethods is the set of allowed HTTP methods for api-type permissions.
    var validMethods = map[string]bool{{ "{" }}
    	"GET":    true,
    	"POST":   true,
    	"PUT":    true,
    	"DELETE": true,
    {{ "}" }}

    // Permission is the aggregate root for the permission aggregate.
    // It represents a single tree node with type ∈ {{ "{" }}catalog, menu, button, api{{ "}" }}.
    type Permission struct {{ "{" }}
    	ID          int64
    	Code        string
    	Type        string
    	Name        string
    	ParentID    int64 // 0 = root
    	Path        string
    	Icon        string
    	RouteName   string
    	Redirect    string
    	KeepAlive   *bool
    	HideInMenu  *bool
    	IsExternal  *bool
    	Method      string // required when Type=api
    	Sort        int32
    	Status      int // StatusEnabled or StatusDisabled
    	Description string
    {{ "}" }}

    // New creates a Permission with full validation:
    //   - type ∈ {{ "{" }}catalog, menu, button, api{{ "}" }}
    //   - when type = api, method is required and ∈ {{ "{" }}GET, POST, PUT, DELETE{{ "}" }}
    //   - when type ∈ {{ "{" }}catalog, menu{{ "}" }}, tree fields may be filled
    //   - when type = button, tree fields should be empty (not enforced, just allowed)
    //   - parentID = 0 means root (no parent)
    func New(code, typ, name string, parentID int64, path, icon, routeName, redirect string, keepAlive, hideInMenu, isExternal *bool, method string, sort int32, status int, description string) (*Permission, error) {{ "{" }}
    	code = strings.TrimSpace(code)
    	if code == "" {{ "{" }}
    		return nil, ValidationError{{ "{" }}Field: "code", Msg: "must not be empty"{{ "}" }}
    	{{ "}" }}
    	if !validTypes[typ] {{ "{" }}
    		return nil, ValidationError{{ "{" }}Field: "type", Msg: "must be catalog, menu, button, or api"{{ "}" }}
    	{{ "}" }}
    	name = strings.TrimSpace(name)
    	if name == "" {{ "{" }}
    		return nil, ValidationError{{ "{" }}Field: "name", Msg: "must not be empty"{{ "}" }}
    	{{ "}" }}
    	if typ == TypeAPI {{ "{" }}
    		method = strings.ToUpper(strings.TrimSpace(method))
    		if !validMethods[method] {{ "{" }}
    			return nil, ValidationError{{ "{" }}Field: "method", Msg: "required when type=api; must be GET, POST, PUT, or DELETE"{{ "}" }}
    		{{ "}" }}
    	{{ "}" }} else {{ "{" }}
    		method = ""
    	{{ "}" }}
    	if status != StatusEnabled && status != StatusDisabled {{ "{" }}
    		status = StatusEnabled
    	{{ "}" }}
    	return &Permission{{ "{" }}
    		Code:        code,
    		Type:        typ,
    		Name:        name,
    		ParentID:    parentID,
    		Path:        path,
    		Icon:        icon,
    		RouteName:   routeName,
    		Redirect:    redirect,
    		KeepAlive:   keepAlive,
    		HideInMenu:  hideInMenu,
    		IsExternal:  isExternal,
    		Method:      method,
    		Sort:        sort,
    		Status:      status,
    		Description: description,
    	{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 7: 实现 domain 实体改动 —— menu entity**

编辑 `rbac-kitex/kitex-template/internal_domain_menu_entity_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/menu/entity.go
path: internal/domain/menu/entity.go
update_behavior:
    type: skip
body: |
    package menu

    import "sort"

    const (
    	// TypeCatalog is a top-level classification node.
    	TypeCatalog = "catalog"
    	// TypeMenu is a navigation menu node.
    	TypeMenu = "menu"
    )

    // Menu is a read-only view over the permissions table (WHERE type IN ('catalog','menu')).
    // It does not have its own write path — writes go through the permission aggregate.
    type Menu struct {{ "{" }}
    	ID         int64
    	Code       string // permission code
    	Name       string
    	ParentID   int64 // 0 = root
    	Type       string // catalog | menu
    	Path       string
    	Icon       string
    	RouteName  string
    	Redirect   string
    	KeepAlive  *bool
    	HideInMenu *bool
    	IsExternal *bool
    	Sort       int32
    {{ "}" }}

    // Node is a menu tree node.
    type Node struct {{ "{" }}
    	Menu     *Menu
    	Children []*Node
    {{ "}" }}

    // BuildTree assembles a flat menu list into a forest ordered by Sort then
    // ID. Nodes whose parent is absent hang as roots (orphans).
    func BuildTree(items []*Menu) []*Node {{ "{" }}
    	if len(items) == 0 {{ "{" }}
    		return nil
    	{{ "}" }}
    	byID := make(map[int64]*Node, len(items))
    	for _, m := range items {{ "{" }}
    		if m == nil {{ "{" }}
    			continue
    		{{ "}" }}
    		byID[m.ID] = &Node{{ "{" }}Menu: m{{ "}" }}
    	{{ "}" }}
    	var roots []*Node
    	for _, n := range byID {{ "{" }}
    		parent := n.Menu.ParentID
    		if p, ok := byID[parent]; ok && parent != n.Menu.ID {{ "{" }}
    			p.Children = append(p.Children, n)
    		{{ "}" }} else {{ "{" }}
    			roots = append(roots, n)
    		{{ "}" }}
    	{{ "}" }}
    	sortNodes(roots)
    	for _, n := range byID {{ "{" }}
    		sortNodes(n.Children)
    	{{ "}" }}
    	return roots
    {{ "}" }}

    func sortNodes(nodes []*Node) {{ "{" }}
    	sort.SliceStable(nodes, func(i, j int) bool {{ "{" }}
    		if nodes[i].Menu.Sort == nodes[j].Menu.Sort {{ "{" }}
    			return nodes[i].Menu.ID < nodes[j].Menu.ID
    		{{ "}" }}
    		return nodes[i].Menu.Sort < nodes[j].Menu.Sort
    	{{ "}" }})
    {{ "}" }}
```

- [ ] **Step 8: 实现 repository 接口改动 —— user/role/permission/menu**

编辑 `rbac-kitex/kitex-template/internal_domain_user_repository_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/user/repository.go
path: internal/domain/user/repository.go
update_behavior:
    type: skip
body: |
    package user

    import (
    	"context"
    	"fmt"
    )

    // Repository is the persistence port for the user aggregate.
    type Repository interface {{ "{" }}
    	GetByID(ctx context.Context, id int64) (*User, error)
    	GetByUUID(ctx context.Context, uuid string) (*User, error)
    	GetByUsername(ctx context.Context, username string) (*User, error)
    	List(ctx context.Context, limit, offset int32) ([]*User, error)
    	Count(ctx context.Context) (int64, error)
    	Save(ctx context.Context, u *User) (*User, error)
    	Update(ctx context.Context, u *User) (*User, error)
    	UpdatePassword(ctx context.Context, id int64, passwordHash string) error
    	Delete(ctx context.Context, id int64) error
    	SetStatus(ctx context.Context, id int64, status int) error
    {{ "}" }}

    // NotFoundError is returned when a user does not exist.
    type NotFoundError struct {{ "{" }}
    	Key string
    {{ "}" }}

    func (e NotFoundError) Error() string {{ "{" }}
    	return fmt.Sprintf("user not found: %s", e.Key)
    {{ "}" }}

    // ValidationError is returned when user input violates a domain rule.
    type ValidationError struct {{ "{" }}
    	Field string
    	Msg   string
    {{ "}" }}

    func (e ValidationError) Error() string {{ "{" }}
    	return fmt.Sprintf("user validation error: %s %s", e.Field, e.Msg)
    {{ "}" }}
```

编辑 `rbac-kitex/kitex-template/internal_domain_role_repository_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/role/repository.go
path: internal/domain/role/repository.go
update_behavior:
    type: skip
body: |
    package role

    import (
    	"context"
    	"fmt"
    )

    // Repository is the persistence port for the role aggregate.
    type Repository interface {{ "{" }}
    	GetByID(ctx context.Context, id int64) (*Role, error)
    	GetByCode(ctx context.Context, code string) (*Role, error)
    	List(ctx context.Context, limit, offset int32) ([]*Role, error)
    	Count(ctx context.Context) (int64, error)
    	Save(ctx context.Context, r *Role) (*Role, error)
    	Delete(ctx context.Context, id int64) error
    {{ "}" }}

    // NotFoundError is returned when a role does not exist.
    type NotFoundError struct {{ "{" }}
    	Key string
    {{ "}" }}

    func (e NotFoundError) Error() string {{ "{" }}
    	return fmt.Sprintf("role not found: %s", e.Key)
    {{ "}" }}

    // ValidationError is returned when role input violates a domain rule.
    type ValidationError struct {{ "{" }}
    	Field string
    	Msg   string
    {{ "}" }}

    func (e ValidationError) Error() string {{ "{" }}
    	return fmt.Sprintf("role validation error: %s %s", e.Field, e.Msg)
    {{ "}" }}
```

编辑 `rbac-kitex/kitex-template/internal_domain_permission_repository_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/permission/repository.go
path: internal/domain/permission/repository.go
update_behavior:
    type: skip
body: |
    package permission

    import (
    	"context"
    	"fmt"
    )

    // Repository is the persistence port for the permission aggregate.
    type Repository interface {{ "{" }}
    	GetByID(ctx context.Context, id int64) (*Permission, error)
    	GetByCode(ctx context.Context, code string) ([]*Permission, error)
    	GetByCodeAndType(ctx context.Context, code, typ string) (*Permission, error)
    	List(ctx context.Context, limit, offset int32) ([]*Permission, error)
    	ListFiltered(ctx context.Context, typ string, parentID int64, status int, limit, offset int32) ([]*Permission, error)
    	ListByCodes(ctx context.Context, codes []string) ([]*Permission, error)
    	ListByRoleIDs(ctx context.Context, roleIDs []int64) ([]*Permission, error)
    	ListChildren(ctx context.Context, parentID int64) ([]*Permission, error)
    	Save(ctx context.Context, p *Permission) (*Permission, error)
    	Update(ctx context.Context, p *Permission) (*Permission, error)
    	Delete(ctx context.Context, id int64) error
    {{ "}" }}

    // NotFoundError is returned when a permission does not exist.
    type NotFoundError struct {{ "{" }}
    	Key string
    {{ "}" }}

    func (e NotFoundError) Error() string {{ "{" }}
    	return fmt.Sprintf("permission not found: %s", e.Key)
    {{ "}" }}

    // ValidationError is returned when permission input violates a domain rule.
    type ValidationError struct {{ "{" }}
    	Field string
    	Msg   string
    {{ "}" }}

    func (e ValidationError) Error() string {{ "{" }}
    	return fmt.Sprintf("permission validation error: %s %s", e.Field, e.Msg)
    {{ "}" }}
```

编辑 `rbac-kitex/kitex-template/internal_domain_menu_repository_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/domain/menu/repository.go
path: internal/domain/menu/repository.go
update_behavior:
    type: skip
body: |
    package menu

    import (
    	"context"
    	"fmt"
    )

    // Repository is the persistence port for the menu read-only query aggregate.
    // It queries the permissions table filtered by type ∈ {{ "{" }}catalog, menu{{ "}" }}.
    type Repository interface {{ "{" }}
    	ListMenusAsTree(ctx context.Context) ([]*Menu, error)
    	ListMenusByParentID(ctx context.Context, parentID int64) ([]*Menu, error)
    {{ "}" }}

    // NotFoundError is returned when a menu does not exist.
    type NotFoundError struct {{ "{" }}
    	Key string
    {{ "}" }}

    func (e NotFoundError) Error() string {{ "{" }}
    	return fmt.Sprintf("menu not found: %s", e.Key)
    {{ "}" }}

    // ValidationError is returned when menu input violates a domain rule.
    type ValidationError struct {{ "{" }}
    	Field string
    	Msg   string
    {{ "}" }}

    func (e ValidationError) Error() string {{ "{" }}
    	return fmt.Sprintf("menu validation error: %s %s", e.Field, e.Msg)
    {{ "}" }}
```

- [ ] **Step 9: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && go test ./internal/domain/...
```

Expected: PASS（`internal/domain/user`、`internal/domain/role`、`internal/domain/permission`、`internal/domain/menu` 全部编译通过且测试通过）。

- [ ] **Step 10: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_domain_user_entity_go.yaml rbac-kitex/kitex-template/internal_domain_role_entity_go.yaml rbac-kitex/kitex-template/internal_domain_permission_entity_go.yaml rbac-kitex/kitex-template/internal_domain_menu_entity_go.yaml rbac-kitex/kitex-template/internal_domain_user_repository_go.yaml rbac-kitex/kitex-template/internal_domain_role_repository_go.yaml rbac-kitex/kitex-template/internal_domain_permission_repository_go.yaml rbac-kitex/kitex-template/internal_domain_menu_repository_go.yaml rbac-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml rbac-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml
git commit -m "feat(rbac-kitex): switch domain entities/repository interfaces to int64 IDs + user.UUID"
```

---

### Task 3: rbac-kitex — User Repository 实现（uuid.NewV7 + GetByUUID）

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_repository_user_repo_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`

**Interfaces:**
- Consumes: `user.User{ID int64; UUID string; ...}`（Task 2）、`user.Repository` 接口（Task 2）、`gen.Queries.CreateUser`/`GetUserByID`/`GetUserByUUID`/... （Task 1 sqlc 生成）。
- Produces: `userrepo.Repo` 实现 `user.Repository` 全部方法 + `GetByUUID(ctx, uuid string) (*user.User, error)`；`AssignRoles(ctx, uid int64, roleIDs []int64) error`、`ListRoles(ctx, uid int64) ([]*role.Role, error)`、`ListRoleIDs(ctx, uid int64) ([]int64, error)`（这三个方法不在 `user.Repository` 里但被 Task 5 的 `usersvc.UserRepo` 依赖）。

- [ ] **Step 1: 改测试 —— postgres round-trip 测试改用 int64/UUID 断言**

编辑 `rbac-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/repository/user/repo_test.go
path: internal/repository/user/repo_test.go
update_behavior:
    type: skip
loop_service: true
body: |
    package userrepo

    import (
    	"context"
    	"os"
    	"os/exec"
    	"testing"
    	"time"

    	"github.com/jackc/pgx/v5/pgxpool"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/user"
    )

    // TestUserRepoPostgresRoundTrip exercises the user repo against a real
    // postgres. It is gated on `pg_isready` plus a reachable POSTGRES_DSN so the
    // happy-path seed/test/e2e runs stay hermetic. When the gate is absent the
    // test prints an explicit `skipped:` line instead of silently passing.
    func TestUserRepoPostgresRoundTrip(t *testing.T) {{ "{" }}
    	if _, err := exec.LookPath("pg_isready"); err != nil {{ "{" }}
    		t.Skipf("skipped: pg_isready not installed (install postgres client to run)")
    	{{ "}" }}
    	dsn := os.Getenv("POSTGRES_DSN")
    	if dsn == "" {{ "{" }}
    		t.Skipf("skipped: POSTGRES_DSN not set")
    	{{ "}" }}
    	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    	defer cancel()
    	pool, err := pgxpool.New(ctx, dsn)
    	if err != nil {{ "{" }}
    		t.Fatalf("connect postgres: %v", err)
    	{{ "}" }}
    	defer pool.Close()
    	if err := pool.Ping(ctx); err != nil {{ "{" }}
    		t.Fatalf("ping postgres: %v", err)
    	{{ "}" }}

    	q := gen.New(pool)
    	repo := New(q, pool)

    	// Create → GetByUUID → GetByUsername → SetStatus → Delete round-trip.
    	created, err := repo.Save(ctx, &user.User{{ "{" }}
    		Username:     "integration-user",
    		PasswordHash: "argon2hash-placeholder",
    		Status:       user.StatusEnabled,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Save(create): %v", err)
    	{{ "}" }}
    	if created.ID == 0 {{ "{" }}
    		t.Fatal("created user has id 0")
    	{{ "}" }}
    	if created.UUID == "" {{ "{" }}
    		t.Fatal("created user has empty uuid")
    	{{ "}" }}

    	byUUID, err := repo.GetByUUID(ctx, created.UUID)
    	if err != nil {{ "{" }}
    		t.Fatalf("GetByUUID: %v", err)
    	{{ "}" }}
    	if byUUID.ID != created.ID {{ "{" }}
    		t.Fatalf("GetByUUID.ID = %d, want %d", byUUID.ID, created.ID)
    	{{ "}" }}

    	got, err := repo.GetByUsername(ctx, created.Username)
    	if err != nil {{ "{" }}
    		t.Fatalf("GetByUsername: %v", err)
    	{{ "}" }}
    	if got.Username != created.Username {{ "{" }}
    		t.Fatalf("got username %q, want %q", got.Username, created.Username)
    	{{ "}" }}

    	if err := repo.SetStatus(ctx, created.ID, user.StatusDisabled); err != nil {{ "{" }}
    		t.Fatalf("SetStatus: %v", err)
    	{{ "}" }}
    	got, err = repo.GetByID(ctx, created.ID)
    	if err != nil {{ "{" }}
    		t.Fatalf("GetByID after SetStatus: %v", err)
    	{{ "}" }}
    	if got.Status != user.StatusDisabled {{ "{" }}
    		t.Fatalf("status = %d, want %d", got.Status, user.StatusDisabled)
    	{{ "}" }}

    	if err := repo.Delete(ctx, created.ID); err != nil {{ "{" }}
    		t.Fatalf("Delete: %v", err)
    	{{ "}" }}
    	if _, err := repo.GetByID(ctx, created.ID); err == nil {{ "{" }}
    		t.Fatal("GetByID after Delete: want error")
    	{{ "}" }} else if _, ok := err.(user.NotFoundError); !ok {{ "{" }}
    		t.Fatalf("GetByID after Delete error = %v, want user.NotFoundError", err)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 运行测试，确认失败（编译失败：`created.ID == 0` 与旧 `Repo` 方法签名 `id string` 不匹配）**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/repository/user/...
```

Expected: FAIL —— `repo.GetByUUID` undefined（尚未实现），`repo.SetStatus(ctx, created.ID, ...)` 参数类型不匹配（`created.ID` 是 `int64`，旧 `Repo.SetStatus` 仍是 `id string`）。

- [ ] **Step 3: 实现 —— user repo.go 改用 int64 + uuid.NewV7 + GetByUUID**

编辑 `rbac-kitex/kitex-template/internal_repository_user_repo_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/repository/user/repo.go
path: internal/repository/user/repo.go
update_behavior:
    type: skip
loop_service: true
body: |
    package userrepo

    import (
    	"context"
    	"errors"
    	"fmt"

    	"github.com/google/uuid"
    	"github.com/jackc/pgx/v5"
    	"github.com/jackc/pgx/v5/pgxpool"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    )

    // Repo implements user.Repository using sqlc queries.
    type Repo struct {{ "{" }}
    	q    *gen.Queries
    	pool *pgxpool.Pool
    {{ "}" }}

    // New creates a user repo backed by sqlc Queries and a pgx pool.
    func New(q *gen.Queries, pool *pgxpool.Pool) *Repo {{ "{" }}
    	return &Repo{{ "{" }}q: q, pool: pool{{ "}" }}
    {{ "}" }}

    // WithTx executes fn inside a database transaction.
    func (r *Repo) WithTx(ctx context.Context, fn func(*Repo) error) (err error) {{ "{" }}
    	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{{ "{" }}{{ "}" }})
    	if err != nil {{ "{" }}
    		return fmt.Errorf("user repository begin transaction: %w", err)
    	{{ "}" }}
    	defer func() {{ "{" }}
    		if p := recover(); p != nil {{ "{" }}
    			_ = tx.Rollback(ctx)
    			panic(p)
    		{{ "}" }}
    		if err != nil {{ "{" }}
    			_ = tx.Rollback(ctx)
    		{{ "}" }}
    	{{ "}" }}()
    	txRepo := &Repo{{ "{" }}q: r.q.WithTx(tx), pool: r.pool{{ "}" }}
    	if err = fn(txRepo); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if err = tx.Commit(ctx); err != nil {{ "{" }}
    		return fmt.Errorf("user repository commit transaction: %w", err)
    	{{ "}" }}
    	return nil
    {{ "}" }}

    func (r *Repo) GetByID(ctx context.Context, id int64) (*user.User, error) {{ "{" }}
    	row, err := r.q.GetUserByID(ctx, id)
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, id)
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) GetByUUID(ctx context.Context, uuidStr string) (*user.User, error) {{ "{" }}
    	row, err := r.q.GetUserByUUID(ctx, uuidStr)
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, uuidStr)
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) GetByUsername(ctx context.Context, username string) (*user.User, error) {{ "{" }}
    	row, err := r.q.GetUserByUsername(ctx, username)
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, username)
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) List(ctx context.Context, limit, offset int32) ([]*user.User, error) {{ "{" }}
    	rows, err := r.q.ListUsers(ctx, gen.ListUsersParams{{ "{" }}Limit: limit, Offset: offset{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*user.User, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomainUser(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) Count(ctx context.Context) (int64, error) {{ "{" }}
    	return r.q.CountUsers(ctx)
    {{ "}" }}

    func (r *Repo) Save(ctx context.Context, u *user.User) (*user.User, error) {{ "{" }}
    	if u == nil {{ "{" }}
    		return nil, errors.New("user repository: nil user")
    	{{ "}" }}
    	if u.ID != 0 {{ "{" }}
    		return nil, errors.New("user repository: use Update for existing users")
    	{{ "}" }}
    	newUUID, err := uuid.NewV7()
    	if err != nil {{ "{" }}
    		return nil, fmt.Errorf("user repository: generate uuid: %w", err)
    	{{ "}" }}
    	var nickname, avatar, email, phone *string
    	if u.Nickname != "" {{ "{" }}
    		nickname = &u.Nickname
    	{{ "}" }}
    	if u.Avatar != "" {{ "{" }}
    		avatar = &u.Avatar
    	{{ "}" }}
    	if u.Email != "" {{ "{" }}
    		email = &u.Email
    	{{ "}" }}
    	if u.Phone != "" {{ "{" }}
    		phone = &u.Phone
    	{{ "}" }}
    	row, err := r.q.CreateUser(ctx, gen.CreateUserParams{{ "{" }}
    		UUID:         newUUID.String(),
    		Username:     u.Username,
    		PasswordHash: u.PasswordHash,
    		Nickname:     nickname,
    		Avatar:       avatar,
    		Email:        email,
    		Phone:        phone,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) Update(ctx context.Context, u *user.User) (*user.User, error) {{ "{" }}
    	if u == nil {{ "{" }}
    		return nil, errors.New("user repository: nil user")
    	{{ "}" }}
    	var nickname, avatar, email, phone *string
    	if u.Nickname != "" {{ "{" }}
    		nickname = &u.Nickname
    	{{ "}" }}
    	if u.Avatar != "" {{ "{" }}
    		avatar = &u.Avatar
    	{{ "}" }}
    	if u.Email != "" {{ "{" }}
    		email = &u.Email
    	{{ "}" }}
    	if u.Phone != "" {{ "{" }}
    		phone = &u.Phone
    	{{ "}" }}
    	row, err := r.q.UpdateUser(ctx, gen.UpdateUserParams{{ "{" }}
    		ID:       u.ID,
    		Username: u.Username,
    		Nickname: nickname,
    		Avatar:   avatar,
    		Email:    email,
    		Phone:    phone,
    		Status:   int32(u.Status),
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, u.ID)
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) UpdatePassword(ctx context.Context, id int64, passwordHash string) error {{ "{" }}
    	_, err := r.q.UpdateUserPassword(ctx, gen.UpdateUserPasswordParams{{ "{" }}
    		PasswordHash: passwordHash,
    		ID:           id,
    	{{ "}" }})
    	return err
    {{ "}" }}

    func (r *Repo) Delete(ctx context.Context, id int64) error {{ "{" }}
    	return r.q.DeleteUser(ctx, id)
    {{ "}" }}

    func (r *Repo) SetStatus(ctx context.Context, id int64, status int) error {{ "{" }}
    	_, err := r.q.UpdateUser(ctx, gen.UpdateUserParams{{ "{" }}
    		ID:     id,
    		Status: int32(status),
    	{{ "}" }})
    	return mapErr(err, id)
    {{ "}" }}

    // AssignRoles replaces the user's role set with the given role IDs.
    func (r *Repo) AssignRoles(ctx context.Context, uid int64, roleIDs []int64) error {{ "{" }}
    	if err := r.q.ClearUserRoles(ctx, uid); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	for _, rid := range roleIDs {{ "{" }}
    		if err := r.q.AddUserRole(ctx, gen.AddUserRoleParams{{ "{" }}UserID: uid, RoleID: rid{{ "}" }}); err != nil {{ "{" }}
    			return err
    		{{ "}" }}
    	{{ "}" }}
    	return nil
    {{ "}" }}

    // ClearRoles removes every role from the user.
    func (r *Repo) ClearRoles(ctx context.Context, uid int64) error {{ "{" }}
    	return r.q.ClearUserRoles(ctx, uid)
    {{ "}" }}

    // ListRoles returns the roles assigned to the user.
    func (r *Repo) ListRoles(ctx context.Context, uid int64) ([]*role.Role, error) {{ "{" }}
    	rows, err := r.q.ListRolesByUserID(ctx, uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*role.Role, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomainRole(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    // ListRoleIDs returns the role IDs assigned to the user.
    func (r *Repo) ListRoleIDs(ctx context.Context, uid int64) ([]int64, error) {{ "{" }}
    	return r.q.ListRoleIDsByUserID(ctx, uid)
    {{ "}" }}

    func toDomainUser(row gen.User) *user.User {{ "{" }}
    	u := &user.User{{ "{" }}
    		ID:           row.ID,
    		UUID:         row.UUID,
    		Username:     row.Username,
    		PasswordHash: row.PasswordHash,
    		Status:       int(row.Status),
    	{{ "}" }}
    	if row.Nickname != nil {{ "{" }}
    		u.Nickname = *row.Nickname
    	{{ "}" }}
    	if row.Avatar != nil {{ "{" }}
    		u.Avatar = *row.Avatar
    	{{ "}" }}
    	if row.Email != nil {{ "{" }}
    		u.Email = *row.Email
    	{{ "}" }}
    	if row.Phone != nil {{ "{" }}
    		u.Phone = *row.Phone
    	{{ "}" }}
    	return u
    {{ "}" }}

    func toDomainRole(row gen.Role) *role.Role {{ "{" }}
    	r := &role.Role{{ "{" }}
    		ID:     row.ID,
    		Code:   row.Code,
    		Name:   row.Name,
    		Status: int(row.Status),
    	{{ "}" }}
    	if row.Remark != nil {{ "{" }}
    		r.Remark = *row.Remark
    	{{ "}" }}
    	return r
    {{ "}" }}

    func mapErr(err error, key any) error {{ "{" }}
    	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
    		return user.NotFoundError{{ "{" }}Key: fmt.Sprint(key){{ "}" }}
    	{{ "}" }}
    	return err
    {{ "}" }}
```

- [ ] **Step 4: 重新运行测试，确认通过（或按 gate 规则显式 skip）**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go build ./internal/repository/... && go test ./internal/repository/user/...
```

Expected: `go build` 成功；`go test` 要么因缺少 `pg_isready`/`POSTGRES_DSN` 打印 `--- SKIP` 并整体 PASS，要么在配好本地 Postgres 时真正跑通 round-trip。两种结果都视为该 Step 通过，禁止的是编译错误或非 skip 的 FAIL。

- [ ] **Step 5: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_repository_user_repo_go.yaml rbac-kitex/kitex-template/internal_repository_user_repo_test_go.yaml
git commit -m "feat(rbac-kitex): user repo generates UUID v7 on Save, adds GetByUUID"
```

---

### Task 4: rbac-kitex — Role/Permission/Menu Repository 实现

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_repository_role_repo_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_repository_permission_repo_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_repository_menu_repo_go.yaml`

**Interfaces:**
- Consumes: `role.Role`/`permission.Permission`/`menu.Menu`（int64 字段，Task 2）、`role.Repository`/`permission.Repository`/`menu.Repository`（Task 2）、`gen.Queries`（Task 1，`ListPermissionsByRoleIDs` 接受 `[]int64`，`ListChildPermissionIDs`/`ListMenusByParentID` 接受 `*int64`）。
- Produces: `rolerepo.Repo`（含 `AssignPermissions(ctx, roleID int64, permissionIDs []int64)`、`ListPermissions(ctx, roleIDs []int64)`、`ListPermissionCodes(ctx, roleID int64)`）、`permissionrepo.Repo`（`ListFiltered(ctx, typ string, parentID int64, ...)`、`ListByRoleIDs(ctx, roleIDs []int64)`、`ListChildren(ctx, parentID int64)`）、`menurepo.Repo`（`ListMenusByParentID(ctx, parentID int64)`）。这三者没有独立单测文件，靠 Task 5/6 的 application service 测试间接覆盖，本 Task 用 `go build` 作为编译正确性的直接验证。

没有测试文件需要先改；这是纯粹的类型改动任务，用 `go build` 作为通过/失败判据（相当于把"编译错误"当作 TDD 里的失败断言）。

- [ ] **Step 1: 运行 build，确认在 Task 2/3 之后、本 Task 之前编译失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go build ./internal/repository/...
```

Expected: FAIL —— `internal/repository/role`/`internal/repository/permission`/`internal/repository/menu` 仍用 `string` 签名，无法满足 Task 2 改后的 `role.Repository`/`permission.Repository`/`menu.Repository` 接口，且直接调用 `gen.Queries` 的参数类型（`int64`/`[]int64`/`*int64`）与旧代码的 `string`/`[]string`/`*string` 不匹配。

- [ ] **Step 2: 实现 —— role repo.go**

编辑 `rbac-kitex/kitex-template/internal_repository_role_repo_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/repository/role/repo.go
path: internal/repository/role/repo.go
update_behavior:
    type: skip
loop_service: true
body: |
    package rolerepo

    import (
    	"context"
    	"errors"
    	"fmt"

    	"github.com/jackc/pgx/v5"
    	"github.com/jackc/pgx/v5/pgxpool"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    )

    // Repo implements role.Repository using sqlc queries.
    type Repo struct {{ "{" }}
    	q    *gen.Queries
    	pool *pgxpool.Pool
    {{ "}" }}

    // New creates a role repo backed by sqlc Queries and a pgx pool.
    func New(q *gen.Queries, pool *pgxpool.Pool) *Repo {{ "{" }}
    	return &Repo{{ "{" }}q: q, pool: pool{{ "}" }}
    {{ "}" }}

    // WithTx executes fn inside a database transaction.
    func (r *Repo) WithTx(ctx context.Context, fn func(*Repo) error) (err error) {{ "{" }}
    	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{{ "{" }}{{ "}" }})
    	if err != nil {{ "{" }}
    		return fmt.Errorf("role repository begin transaction: %w", err)
    	{{ "}" }}
    	defer func() {{ "{" }}
    		if p := recover(); p != nil {{ "{" }}
    			_ = tx.Rollback(ctx)
    			panic(p)
    		{{ "}" }}
    		if err != nil {{ "{" }}
    			_ = tx.Rollback(ctx)
    		{{ "}" }}
    	{{ "}" }}()
    	txRepo := &Repo{{ "{" }}q: r.q.WithTx(tx), pool: r.pool{{ "}" }}
    	if err = fn(txRepo); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if err = tx.Commit(ctx); err != nil {{ "{" }}
    		return fmt.Errorf("role repository commit transaction: %w", err)
    	{{ "}" }}
    	return nil
    {{ "}" }}

    func (r *Repo) GetByID(ctx context.Context, id int64) (*role.Role, error) {{ "{" }}
    	row, err := r.q.GetRoleByID(ctx, id)
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, id)
    	{{ "}" }}
    	return toDomainRole(row), nil
    {{ "}" }}

    func (r *Repo) GetByCode(ctx context.Context, code string) (*role.Role, error) {{ "{" }}
    	row, err := r.q.GetRoleByCode(ctx, code)
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, code)
    	{{ "}" }}
    	return toDomainRole(row), nil
    {{ "}" }}

    func (r *Repo) List(ctx context.Context, limit, offset int32) ([]*role.Role, error) {{ "{" }}
    	rows, err := r.q.ListRoles(ctx, gen.ListRolesParams{{ "{" }}Limit: limit, Offset: offset{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*role.Role, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomainRole(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) Count(ctx context.Context) (int64, error) {{ "{" }}
    	return r.q.CountRoles(ctx)
    {{ "}" }}

    func (r *Repo) Save(ctx context.Context, rl *role.Role) (*role.Role, error) {{ "{" }}
    	if rl == nil {{ "{" }}
    		return nil, errors.New("role repository: nil role")
    	{{ "}" }}
    	if rl.ID != 0 {{ "{" }}
    		return nil, errors.New("role repository: use Update for existing roles")
    	{{ "}" }}
    	var remark *string
    	if rl.Remark != "" {{ "{" }}
    		remark = &rl.Remark
    	{{ "}" }}
    	row, err := r.q.CreateRole(ctx, gen.CreateRoleParams{{ "{" }}Code: rl.Code, Name: rl.Name, Remark: remark{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainRole(row), nil
    {{ "}" }}

    func (r *Repo) Update(ctx context.Context, rl *role.Role) (*role.Role, error) {{ "{" }}
    	if rl == nil {{ "{" }}
    		return nil, errors.New("role repository: nil role")
    	{{ "}" }}
    	var remark *string
    	if rl.Remark != "" {{ "{" }}
    		remark = &rl.Remark
    	{{ "}" }}
    	row, err := r.q.UpdateRole(ctx, gen.UpdateRoleParams{{ "{" }}
    		ID:     rl.ID,
    		Name:   rl.Name,
    		Status: int32(rl.Status),
    		Remark: remark,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, rl.ID)
    	{{ "}" }}
    	return toDomainRole(row), nil
    {{ "}" }}

    func (r *Repo) Delete(ctx context.Context, id int64) error {{ "{" }}
    	return r.q.DeleteRole(ctx, id)
    {{ "}" }}

    // AssignPermissions replaces the role's permission set with the given IDs.
    func (r *Repo) AssignPermissions(ctx context.Context, roleID int64, permissionIDs []int64) error {{ "{" }}
    	if err := r.q.ClearRolePermissions(ctx, roleID); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	for _, pid := range permissionIDs {{ "{" }}
    		if err := r.q.AddRolePermission(ctx, gen.AddRolePermissionParams{{ "{" }}RoleID: roleID, PermissionID: pid{{ "}" }}); err != nil {{ "{" }}
    			return err
    		{{ "}" }}
    	{{ "}" }}
    	return nil
    {{ "}" }}

    // ClearPermissions removes every permission from the role.
    func (r *Repo) ClearPermissions(ctx context.Context, roleID int64) error {{ "{" }}
    	return r.q.ClearRolePermissions(ctx, roleID)
    {{ "}" }}

    // ListPermissions returns the permissions granted to the given role IDs.
    func (r *Repo) ListPermissions(ctx context.Context, roleIDs []int64) ([]*permission.Permission, error) {{ "{" }}
    	rows, err := r.q.ListPermissionsByRoleIDs(ctx, roleIDs)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*permission.Permission, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomainPermission(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    // ListPermissionCodes returns the permission codes granted to the role.
    func (r *Repo) ListPermissionCodes(ctx context.Context, roleID int64) ([]string, error) {{ "{" }}
    	return r.q.ListPermissionCodesByRoleID(ctx, roleID)
    {{ "}" }}

    // ListPermissionIDsByCodes resolves permission codes to (id, code) pairs.
    func (r *Repo) ListPermissionIDsByCodes(ctx context.Context, codes []string) ([]gen.ListPermissionIDsByCodesRow, error) {{ "{" }}
    	return r.q.ListPermissionIDsByCodes(ctx, codes)
    {{ "}" }}

    func toDomainRole(row gen.Role) *role.Role {{ "{" }}
    	r := &role.Role{{ "{" }}
    		ID:     row.ID,
    		Code:   row.Code,
    		Name:   row.Name,
    		Status: int(row.Status),
    	{{ "}" }}
    	if row.Remark != nil {{ "{" }}
    		r.Remark = *row.Remark
    	{{ "}" }}
    	return r
    {{ "}" }}

    func toDomainPermission(row gen.Permission) *permission.Permission {{ "{" }}
    	p := &permission.Permission{{ "{" }}
    		ID:         row.ID,
    		Code:       row.Code,
    		Type:       row.Type,
    		Name:       row.Name,
    		KeepAlive:  row.KeepAlive,
    		HideInMenu: row.HideInMenu,
    		IsExternal: row.IsExternal,
    		Status:     int(row.Status),
    	{{ "}" }}
    	if row.ParentID != nil {{ "{" }}
    		p.ParentID = *row.ParentID
    	{{ "}" }}
    	if row.Path != nil {{ "{" }}
    		p.Path = *row.Path
    	{{ "}" }}
    	if row.Icon != nil {{ "{" }}
    		p.Icon = *row.Icon
    	{{ "}" }}
    	if row.RouteName != nil {{ "{" }}
    		p.RouteName = *row.RouteName
    	{{ "}" }}
    	if row.Redirect != nil {{ "{" }}
    		p.Redirect = *row.Redirect
    	{{ "}" }}
    	if row.Method != nil {{ "{" }}
    		p.Method = *row.Method
    	{{ "}" }}
    	if row.Sort != nil {{ "{" }}
    		p.Sort = *row.Sort
    	{{ "}" }}
    	if row.Description != nil {{ "{" }}
    		p.Description = *row.Description
    	{{ "}" }}
    	return p
    {{ "}" }}

    func mapErr(err error, key any) error {{ "{" }}
    	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
    		return role.NotFoundError{{ "{" }}Key: fmt.Sprint(key){{ "}" }}
    	{{ "}" }}
    	return err
    {{ "}" }}
```

- [ ] **Step 3: 实现 —— permission repo.go**

编辑 `rbac-kitex/kitex-template/internal_repository_permission_repo_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/repository/permission/repo.go
path: internal/repository/permission/repo.go
update_behavior:
    type: skip
loop_service: true
body: |
    package permissionrepo

    import (
    	"context"
    	"errors"
    	"fmt"

    	"github.com/jackc/pgx/v5"
    	"github.com/jackc/pgx/v5/pgxpool"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/permission"
    )

    // Repo implements permission.Repository using sqlc queries.
    type Repo struct {{ "{" }}
    	q    *gen.Queries
    	pool *pgxpool.Pool
    {{ "}" }}

    // New creates a permission repo backed by sqlc Queries and a pgx pool.
    func New(q *gen.Queries, pool *pgxpool.Pool) *Repo {{ "{" }}
    	return &Repo{{ "{" }}q: q, pool: pool{{ "}" }}
    {{ "}" }}

    // WithTx executes fn inside a database transaction.
    func (r *Repo) WithTx(ctx context.Context, fn func(*Repo) error) (err error) {{ "{" }}
    	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{{ "{" }}{{ "}" }})
    	if err != nil {{ "{" }}
    		return fmt.Errorf("permission repository begin transaction: %w", err)
    	{{ "}" }}
    	defer func() {{ "{" }}
    		if p := recover(); p != nil {{ "{" }}
    			_ = tx.Rollback(ctx)
    			panic(p)
    		{{ "}" }}
    		if err != nil {{ "{" }}
    			_ = tx.Rollback(ctx)
    		{{ "}" }}
    	{{ "}" }}()
    	txRepo := &Repo{{ "{" }}q: r.q.WithTx(tx), pool: r.pool{{ "}" }}
    	if err = fn(txRepo); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if err = tx.Commit(ctx); err != nil {{ "{" }}
    		return fmt.Errorf("permission repository commit transaction: %w", err)
    	{{ "}" }}
    	return nil
    {{ "}" }}

    func (r *Repo) GetByID(ctx context.Context, id int64) (*permission.Permission, error) {{ "{" }}
    	row, err := r.q.GetPermissionByID(ctx, id)
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, id)
    	{{ "}" }}
    	return toDomain(row), nil
    {{ "}" }}

    func (r *Repo) GetByCode(ctx context.Context, code string) ([]*permission.Permission, error) {{ "{" }}
    	rows, err := r.q.GetPermissionByCode(ctx, code)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*permission.Permission, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomain(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) GetByCodeAndType(ctx context.Context, code, typ string) (*permission.Permission, error) {{ "{" }}
    	row, err := r.q.GetPermissionByCodeAndType(ctx, gen.GetPermissionByCodeAndTypeParams{{ "{" }}Code: code, Type: typ{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, mapErr(err, code+":"+typ)
    	{{ "}" }}
    	return toDomain(row), nil
    {{ "}" }}

    func (r *Repo) List(ctx context.Context, limit, offset int32) ([]*permission.Permission, error) {{ "{" }}
    	rows, err := r.q.ListPermissions(ctx, gen.ListPermissionsParams{{ "{" }}Limit: limit, Offset: offset{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainSlice(rows), nil
    {{ "}" }}

    func (r *Repo) Count(ctx context.Context) (int64, error) {{ "{" }}
    	return r.q.CountPermissions(ctx)
    {{ "}" }}

    func (r *Repo) ListFiltered(ctx context.Context, typ string, parentID int64, status int, limit, offset int32) ([]*permission.Permission, error) {{ "{" }}
    	rows, err := r.q.ListPermissionsFiltered(ctx, gen.ListPermissionsFilteredParams{{ "{" }}
    		Column1: typ,
    		Column2: parentID,
    		Column3: status,
    		Limit:   limit,
    		Offset:  offset,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainSlice(rows), nil
    {{ "}" }}

    func (r *Repo) ListByCodes(ctx context.Context, codes []string) ([]*permission.Permission, error) {{ "{" }}
    	rows, err := r.q.ListPermissionsByCodes(ctx, codes)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainSlice(rows), nil
    {{ "}" }}

    func (r *Repo) ListByRoleIDs(ctx context.Context, roleIDs []int64) ([]*permission.Permission, error) {{ "{" }}
    	rows, err := r.q.ListPermissionsByRoleIDs(ctx, roleIDs)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainSlice(rows), nil
    {{ "}" }}

    func (r *Repo) ListChildren(ctx context.Context, parentID int64) ([]*permission.Permission, error) {{ "{" }}
    	pid := parentID
    	rows, err := r.q.ListChildPermissionIDs(ctx, &pid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*permission.Permission, 0, len(rows))
    	for _, id := range rows {{ "{" }}
    		p, err := r.q.GetPermissionByID(ctx, id)
    		if err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    		out = append(out, toDomain(p))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) Save(ctx context.Context, p *permission.Permission) (*permission.Permission, error) {{ "{" }}
    	if p == nil {{ "{" }}
    		return nil, errors.New("permission repository: nil permission")
    	{{ "}" }}
    	var parentID *int64
    	if p.ParentID != 0 {{ "{" }}
    		parentID = &p.ParentID
    	{{ "}" }}
    	var path, icon, routeName, redirect, method, description *string
    	if p.Path != "" {{ "{" }}
    		path = &p.Path
    	{{ "}" }}
    	if p.Icon != "" {{ "{" }}
    		icon = &p.Icon
    	{{ "}" }}
    	if p.RouteName != "" {{ "{" }}
    		routeName = &p.RouteName
    	{{ "}" }}
    	if p.Redirect != "" {{ "{" }}
    		redirect = &p.Redirect
    	{{ "}" }}
    	if p.Method != "" {{ "{" }}
    		method = &p.Method
    	{{ "}" }}
    	if p.Description != "" {{ "{" }}
    		description = &p.Description
    	{{ "}" }}
    	var sort *int32
    	if p.Sort != 0 {{ "{" }}
    		sort = &p.Sort
    	{{ "}" }}
    	row, err := r.q.CreatePermission(ctx, gen.CreatePermissionParams{{ "{" }}
    		Code:        p.Code,
    		Type:        p.Type,
    		Name:        p.Name,
    		ParentID:    parentID,
    		Path:        path,
    		Icon:        icon,
    		RouteName:   routeName,
    		Redirect:    redirect,
    		KeepAlive:   p.KeepAlive,
    		HideInMenu:  p.HideInMenu,
    		IsExternal:  p.IsExternal,
    		Method:      method,
    		Sort:        sort,
    		Status:      int32(p.Status),
    		Description: description,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomain(row), nil
    {{ "}" }}

    func (r *Repo) Update(ctx context.Context, p *permission.Permission) (*permission.Permission, error) {{ "{" }}
    	if p == nil {{ "{" }}
    		return nil, errors.New("permission repository: nil permission")
    	{{ "}" }}
    	var parentID *int64
    	if p.ParentID != 0 {{ "{" }}
    		parentID = &p.ParentID
    	{{ "}" }}
    	var path, icon, routeName, redirect, method, description *string
    	if p.Path != "" {{ "{" }}
    		path = &p.Path
    	{{ "}" }}
    	if p.Icon != "" {{ "{" }}
    		icon = &p.Icon
    	{{ "}" }}
    	if p.RouteName != "" {{ "{" }}
    		routeName = &p.RouteName
    	{{ "}" }}
    	if p.Redirect != "" {{ "{" }}
    		redirect = &p.Redirect
    	{{ "}" }}
    	if p.Method != "" {{ "{" }}
    		method = &p.Method
    	{{ "}" }}
    	if p.Description != "" {{ "{" }}
    		description = &p.Description
    	{{ "}" }}
    	var sort *int32
    	if p.Sort != 0 {{ "{" }}
    		sort = &p.Sort
    	{{ "}" }}
    	row, err := r.q.UpdatePermission(ctx, gen.UpdatePermissionParams{{ "{" }}
    		ID:          p.ID,
    		Code:        p.Code,
    		Type:        p.Type,
    		Name:        p.Name,
    		ParentID:    parentID,
    		Path:        path,
    		Icon:        icon,
    		RouteName:   routeName,
    		Redirect:    redirect,
    		KeepAlive:   p.KeepAlive,
    		HideInMenu:  p.HideInMenu,
    		IsExternal:  p.IsExternal,
    		Method:      method,
    		Sort:        sort,
    		Status:      int32(p.Status),
    		Description: description,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomain(row), nil
    {{ "}" }}

    func (r *Repo) Delete(ctx context.Context, id int64) error {{ "{" }}
    	return r.q.DeletePermission(ctx, id)
    {{ "}" }}

    func toDomain(row gen.Permission) *permission.Permission {{ "{" }}
    	p := &permission.Permission{{ "{" }}
    		ID:         row.ID,
    		Code:       row.Code,
    		Type:       row.Type,
    		Name:       row.Name,
    		KeepAlive:  row.KeepAlive,
    		HideInMenu: row.HideInMenu,
    		IsExternal: row.IsExternal,
    		Sort:       derefInt32(row.Sort),
    		Status:     int(row.Status),
    	{{ "}" }}
    	if row.ParentID != nil {{ "{" }}
    		p.ParentID = *row.ParentID
    	{{ "}" }}
    	if row.Path != nil {{ "{" }}
    		p.Path = *row.Path
    	{{ "}" }}
    	if row.Icon != nil {{ "{" }}
    		p.Icon = *row.Icon
    	{{ "}" }}
    	if row.RouteName != nil {{ "{" }}
    		p.RouteName = *row.RouteName
    	{{ "}" }}
    	if row.Redirect != nil {{ "{" }}
    		p.Redirect = *row.Redirect
    	{{ "}" }}
    	if row.Method != nil {{ "{" }}
    		p.Method = *row.Method
    	{{ "}" }}
    	if row.Description != nil {{ "{" }}
    		p.Description = *row.Description
    	{{ "}" }}
    	return p
    {{ "}" }}

    func toDomainSlice(rows []gen.Permission) []*permission.Permission {{ "{" }}
    	out := make([]*permission.Permission, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomain(row))
    	{{ "}" }}
    	return out
    {{ "}" }}

    func derefInt32(v *int32) int32 {{ "{" }}
    	if v != nil {{ "{" }}
    		return *v
    	{{ "}" }}
    	return 0
    {{ "}" }}

    func mapErr(err error, key any) error {{ "{" }}
    	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
    		return permission.NotFoundError{{ "{" }}Key: fmt.Sprint(key){{ "}" }}
    	{{ "}" }}
    	return err
    {{ "}" }}
```

- [ ] **Step 4: 实现 —— menu repo.go**

编辑 `rbac-kitex/kitex-template/internal_repository_menu_repo_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/repository/menu/repo.go
path: internal/repository/menu/repo.go
update_behavior:
    type: skip
loop_service: true
body: |
    package menurepo

    import (
    	"context"
    	"fmt"

    	"github.com/jackc/pgx/v5/pgxpool"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/menu"
    )

    // Repo implements menu.Repository (read-only) using sqlc queries.
    type Repo struct {{ "{" }}
    	q    *gen.Queries
    	pool *pgxpool.Pool
    {{ "}" }}

    // New creates a menu repo backed by sqlc Queries and a pgx pool.
    func New(q *gen.Queries, pool *pgxpool.Pool) *Repo {{ "{" }}
    	return &Repo{{ "{" }}q: q, pool: pool{{ "}" }}
    {{ "}" }}

    func (r *Repo) ListMenusAsTree(ctx context.Context) ([]*menu.Menu, error) {{ "{" }}
    	rows, err := r.q.ListMenusAsTree(ctx)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*menu.Menu, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toMenuFromTreeRow(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) ListMenusByParentID(ctx context.Context, parentID int64) ([]*menu.Menu, error) {{ "{" }}
    	pid := parentID
    	rows, err := r.q.ListMenusByParentID(ctx, &pid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*menu.Menu, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toMenuFromParentRow(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func toMenuFromTreeRow(row gen.ListMenusAsTreeRow) *menu.Menu {{ "{" }}
    	m := &menu.Menu{{ "{" }}
    		ID:         row.ID,
    		Code:       row.Code,
    		Name:       row.Name,
    		Type:       row.Type,
    		KeepAlive:  row.KeepAlive,
    		HideInMenu: row.HideInMenu,
    		IsExternal: row.IsExternal,
    	{{ "}" }}
    	if row.ParentID != nil {{ "{" }}
    		m.ParentID = *row.ParentID
    	{{ "}" }}
    	if row.Path != nil {{ "{" }}
    		m.Path = *row.Path
    	{{ "}" }}
    	if row.Icon != nil {{ "{" }}
    		m.Icon = *row.Icon
    	{{ "}" }}
    	if row.RouteName != nil {{ "{" }}
    		m.RouteName = *row.RouteName
    	{{ "}" }}
    	if row.Redirect != nil {{ "{" }}
    		m.Redirect = *row.Redirect
    	{{ "}" }}
    	if row.Sort != nil {{ "{" }}
    		m.Sort = *row.Sort
    	{{ "}" }}
    	return m
    {{ "}" }}

    func toMenuFromParentRow(row gen.ListMenusByParentIDRow) *menu.Menu {{ "{" }}
    	m := &menu.Menu{{ "{" }}
    		ID:         row.ID,
    		Code:       row.Code,
    		Name:       row.Name,
    		Type:       row.Type,
    		KeepAlive:  row.KeepAlive,
    		HideInMenu: row.HideInMenu,
    		IsExternal: row.IsExternal,
    	{{ "}" }}
    	if row.ParentID != nil {{ "{" }}
    		m.ParentID = *row.ParentID
    	{{ "}" }}
    	if row.Path != nil {{ "{" }}
    		m.Path = *row.Path
    	{{ "}" }}
    	if row.Icon != nil {{ "{" }}
    		m.Icon = *row.Icon
    	{{ "}" }}
    	if row.RouteName != nil {{ "{" }}
    		m.RouteName = *row.RouteName
    	{{ "}" }}
    	if row.Redirect != nil {{ "{" }}
    		m.Redirect = *row.Redirect
    	{{ "}" }}
    	if row.Sort != nil {{ "{" }}
    		m.Sort = *row.Sort
    	{{ "}" }}
    	return m
    {{ "}" }}

    func mapErr(err error, key any) error {{ "{" }}
    	return fmt.Errorf("menu repo: %v (key=%v)", err, key)
    {{ "}" }}
```

- [ ] **Step 5: 重新运行 build，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go build ./internal/repository/...
```

Expected: PASS（`go build` 退出码 0）。

- [ ] **Step 6: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_repository_role_repo_go.yaml rbac-kitex/kitex-template/internal_repository_permission_repo_go.yaml rbac-kitex/kitex-template/internal_repository_menu_repo_go.yaml
git commit -m "feat(rbac-kitex): switch role/permission/menu repositories to int64 IDs"
```

---

### Task 5: rbac-kitex — User Application Service（UUID 边界转换）+ 测试

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`

**Interfaces:**
- Consumes: `user.User{ID int64; UUID string; ...}`（Task 2）、`role.Role{ID int64; ...}`（Task 2）、`userrepo.Repo`（Task 3，结构性满足下面的 `UserRepo`）。
- Produces: `usersvc.UserRepo` 接口（`GetByID(ctx, id int64)`、`GetByUUID(ctx, uuid string)`、`UpdatePassword(ctx, id int64, ...)`、`Delete(ctx, id int64)`、`SetStatus(ctx, id int64, status int)`、`AssignRoles(ctx, uid int64, roleIDs []int64)`、`ListRoles(ctx, uid int64)`、`ListRoleIDs(ctx, uid int64)`）；`usersvc.Service` 的**外部方法签名保持字符串不变**（`Update(ctx, in UpdateUserInput)` 其中 `in.ID string` 是 UUID、`Delete(ctx, id string)`、`Get(ctx, id string)`、`GetRoleCodes(ctx, uid string)`、`AssignRoles(ctx, uid string, roleIDs []string)`），内部用 `GetByUUID`/`strconv.ParseInt` 解析成 int64 再调用 repo；`usersvc.CreateUserInput`/`usersvc.UpdateUserInput` DTO 字段类型不变（不需要修改 `internal_application_user_dto_go.yaml`，已核对该文件不引用实体 ID 字段类型，本 Task 不涉及）。

- [ ] **Step 1: 改测试 —— fakeUserRepo 改用 int64 存储 + GetByUUID，断言改用 UUID**

编辑 `rbac-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/user/user_service_test.go
path: internal/application/user/user_service_test.go
update_behavior:
    type: skip
body: |
    package usersvc

    import (
    	"context"
    	"fmt"
    	"strings"
    	"testing"

    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/casbin"
    )

    type fakeUserRepo struct {{ "{" }}
    	users     map[int64]*user.User
    	byUUID    map[string]int64
    	nextID    int64
    	roleDefs  map[int64]*role.Role
    	rolesByID map[int64][]*role.Role
    {{ "}" }}

    func (f *fakeUserRepo) GetByID(ctx context.Context, id int64) (*user.User, error) {{ "{" }}
    	u, ok := f.users[id]
    	if !ok {{ "{" }}
    		return nil, user.NotFoundError{{ "{" }}Key: fmt.Sprint(id){{ "}" }}
    	{{ "}" }}
    	return u, nil
    {{ "}" }}

    func (f *fakeUserRepo) GetByUUID(ctx context.Context, uuid string) (*user.User, error) {{ "{" }}
    	id, ok := f.byUUID[uuid]
    	if !ok {{ "{" }}
    		return nil, user.NotFoundError{{ "{" }}Key: uuid{{ "}" }}
    	{{ "}" }}
    	return f.users[id], nil
    {{ "}" }}

    func (f *fakeUserRepo) GetByUsername(ctx context.Context, username string) (*user.User, error) {{ "{" }}
    	for _, u := range f.users {{ "{" }}
    		if u.Username == username {{ "{" }}
    			return u, nil
    		{{ "}" }}
    	{{ "}" }}
    	return nil, user.NotFoundError{{ "{" }}Key: username{{ "}" }}
    {{ "}" }}

    func (f *fakeUserRepo) List(ctx context.Context, limit, offset int32) ([]*user.User, error) {{ "{" }}
    	var out []*user.User
    	for _, u := range f.users {{ "{" }}
    		out = append(out, u)
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (f *fakeUserRepo) Count(ctx context.Context) (int64, error) {{ "{" }} return int64(len(f.users)), nil {{ "}" }}

    func (f *fakeUserRepo) Save(ctx context.Context, u *user.User) (*user.User, error) {{ "{" }}
    	if u.ID == 0 {{ "{" }}
    		f.nextID++
    		u.ID = f.nextID
    		u.UUID = fmt.Sprintf("uuid-%d", u.ID)
    	{{ "}" }}
    	f.users[u.ID] = u
    	f.byUUID[u.UUID] = u.ID
    	return u, nil
    {{ "}" }}

    func (f *fakeUserRepo) Update(ctx context.Context, u *user.User) (*user.User, error) {{ "{" }}
    	f.users[u.ID] = u
    	return u, nil
    {{ "}" }}

    func (f *fakeUserRepo) UpdatePassword(ctx context.Context, id int64, passwordHash string) error {{ "{" }}
    	if u, ok := f.users[id]; ok {{ "{" }}
    		u.PasswordHash = passwordHash
    		return nil
    	{{ "}" }}
    	return user.NotFoundError{{ "{" }}Key: fmt.Sprint(id){{ "}" }}
    {{ "}" }}

    func (f *fakeUserRepo) Delete(ctx context.Context, id int64) error {{ "{" }}
    	delete(f.users, id)
    	return nil
    {{ "}" }}

    func (f *fakeUserRepo) SetStatus(ctx context.Context, id int64, status int) error {{ "{" }}
    	if u, ok := f.users[id]; ok {{ "{" }}
    		u.Status = status
    		return nil
    	{{ "}" }}
    	return user.NotFoundError{{ "{" }}Key: fmt.Sprint(id){{ "}" }}
    {{ "}" }}

    func (f *fakeUserRepo) AssignRoles(ctx context.Context, uid int64, roleIDs []int64) error {{ "{" }}
    	roles := make([]*role.Role, 0, len(roleIDs))
    	for _, rid := range roleIDs {{ "{" }}
    		if r, ok := f.roleDefs[rid]; ok {{ "{" }}
    			roles = append(roles, r)
    		{{ "}" }}
    	{{ "}" }}
    	f.rolesByID[uid] = roles
    	return nil
    {{ "}" }}

    func (f *fakeUserRepo) ListRoles(ctx context.Context, uid int64) ([]*role.Role, error) {{ "{" }}
    	return f.rolesByID[uid], nil
    {{ "}" }}

    func (f *fakeUserRepo) ListRoleIDs(ctx context.Context, uid int64) ([]int64, error) {{ "{" }}
    	roles := f.rolesByID[uid]
    	ids := make([]int64, 0, len(roles))
    	for _, r := range roles {{ "{" }}
    		ids = append(ids, r.ID)
    	{{ "}" }}
    	return ids, nil
    {{ "}" }}

    func newUserService(t *testing.T) (*Service, *fakeUserRepo, *casbin.MemoryPolicyStore, *audit.MemoryWriter, *casbin.Enforcer) {{ "{" }}
    	t.Helper()
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
    	svc := New(repo, e, aud)
    	return svc, repo, store, aud, e
    {{ "}" }}

    func TestCreateHashesPassword(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, repo, _, _, _ := newUserService(t)

    	created, err := svc.Create(ctx, CreateUserInput{{ "{" }}Username: "bob", Password: "Passw0rd!"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	if created.UUID == "" {{ "{" }}
    		t.Fatal("created user has empty uuid")
    	{{ "}" }}
    	if created.PasswordHash == "Passw0rd!" {{ "{" }}
    		t.Fatal("password was stored in plaintext")
    	{{ "}" }}
    	if !strings.HasPrefix(created.PasswordHash, "$argon2id$") {{ "{" }}
    		t.Fatalf("password hash %q does not look like argon2id", created.PasswordHash)
    	{{ "}" }}
    	if _, err := repo.GetByUsername(ctx, "bob"); err != nil {{ "{" }}
    		t.Fatalf("GetByUsername(bob): %v", err)
    	{{ "}" }}
    {{ "}" }}

    func TestCreateRejectsShortPassword(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _, _, _ := newUserService(t)
    	if _, err := svc.Create(ctx, CreateUserInput{{ "{" }}Username: "bob", Password: "short"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("Create(short password) = nil, want error")
    	{{ "}" }}
    {{ "}" }}

    func TestUpdateStatusInt(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _, _, _ := newUserService(t)
    	created, err := svc.Create(ctx, CreateUserInput{{ "{" }}Username: "alice", Password: "Passw0rd!"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	disabled := user.StatusDisabled
    	updated, err := svc.Update(ctx, UpdateUserInput{{ "{" }}ID: created.UUID, Status: &disabled{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Update: %v", err)
    	{{ "}" }}
    	if updated.Status != user.StatusDisabled {{ "{" }}
    		t.Fatalf("Status = %d, want %d", updated.Status, user.StatusDisabled)
    	{{ "}" }}
    {{ "}" }}

    func TestAssignRolesSyncsCasbin(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, repo, _, _, e := newUserService(t)

    	created, err := svc.Create(ctx, CreateUserInput{{ "{" }}Username: "carol", Password: "Passw0rd!"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	repo.roleDefs[1] = &role.Role{{ "{" }}ID: 1, Code: "admin", Name: "Admin"{{ "}" }}
    	repo.rolesByID[created.ID] = nil
    	if _, err := e.AddPolicy("admin", "user:create", "POST"); err != nil {{ "{" }}
    		t.Fatalf("AddPolicy: %v", err)
    	{{ "}" }}

    	if err := svc.AssignRoles(ctx, created.UUID, []string{{ "{" }}"1"{{ "}" }}); err != nil {{ "{" }}
    		t.Fatalf("AssignRoles: %v", err)
    	{{ "}" }}
    	roles, err := repo.ListRoles(ctx, created.ID)
    	if err != nil {{ "{" }}
    		t.Fatalf("ListRoles: %v", err)
    	{{ "}" }}
    	if len(roles) != 1 || roles[0].Code != "admin" {{ "{" }}
    		t.Fatalf("roles = %+v, want [admin]", roles)
    	{{ "}" }}
    	if allowed, _ := e.Enforce(created.UUID, "user:create", "POST"); !allowed {{ "{" }}
    		t.Fatal("Enforce(uid, user:create, POST) = false, want true")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 运行测试，确认失败（编译失败：旧 `Service` 仍按 `id string` 直接调用 repo，且 `fakeUserRepo` 新字段/方法与旧 `UserRepo` 接口不匹配）**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/user/...
```

Expected: FAIL —— `*fakeUserRepo does not implement UserRepo`（缺 `GetByUUID`，`GetByID`/`AssignRoles`/... 参数类型不匹配）。

- [ ] **Step 3: 实现 —— user_service.go 加入 UUID/strconv 边界转换**

编辑 `rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/user/user_service.go
path: internal/application/user/user_service.go
update_behavior:
    type: skip
body: |
    package usersvc

    import (
    	"context"
    	"strconv"

    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/audit"
    	authinfra "{{.Module}}/internal/infrastructure/auth"
    )

    // UserRepo is the user persistence + role-assignment port consumed by the service.
    type UserRepo interface {{ "{" }}
    	GetByID(ctx context.Context, id int64) (*user.User, error)
    	GetByUUID(ctx context.Context, uuid string) (*user.User, error)
    	GetByUsername(ctx context.Context, username string) (*user.User, error)
    	List(ctx context.Context, limit, offset int32) ([]*user.User, error)
    	Count(ctx context.Context) (int64, error)
    	Save(ctx context.Context, u *user.User) (*user.User, error)
    	Update(ctx context.Context, u *user.User) (*user.User, error)
    	UpdatePassword(ctx context.Context, id int64, passwordHash string) error
    	Delete(ctx context.Context, id int64) error
    	SetStatus(ctx context.Context, id int64, status int) error
    	AssignRoles(ctx context.Context, uid int64, roleIDs []int64) error
    	ListRoles(ctx context.Context, uid int64) ([]*role.Role, error)
    	ListRoleIDs(ctx context.Context, uid int64) ([]int64, error)
    {{ "}" }}

    // Enforcer syncs role bindings into Casbin (g links).
    type Enforcer interface {{ "{" }}
    	DeleteRolesForUser(user string, domain ...string) (bool, error)
    	AddRoleForUser(user string, role string, domain ...string) (bool, error)
    {{ "}" }}

    // Service implements the user management use cases. Public methods that
    // take an "id"/"uid" string treat it as the external UUID and resolve it to
    // the internal int64 primary key via UserRepo.GetByUUID before touching
    // user_roles or other int64-keyed foreign keys. Casbin always sees the
    // original UUID string, never the internal ID.
    type Service struct {{ "{" }}
    	users    UserRepo
    	enforcer Enforcer
    	audit    audit.Writer
    {{ "}" }}

    // New creates the user application service.
    func New(users UserRepo, enforcer Enforcer, audit audit.Writer) *Service {{ "{" }}
    	return &Service{{ "{" }}users: users, enforcer: enforcer, audit: audit{{ "}" }}
    {{ "}" }}

    // Create hashes the password and persists a new user.
    func (s *Service) Create(ctx context.Context, in CreateUserInput) (*user.User, error) {{ "{" }}
    	if err := user.ValidatePassword(in.Password); err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	hash, err := authinfra.HashPassword(in.Password)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	u, err := user.New(in.Username, hash)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	u.Nickname = in.Nickname
    	u.Avatar = in.Avatar
    	u.Email = in.Email
    	u.Phone = in.Phone
    	saved, err := s.users.Save(ctx, u)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "user.create", in.Username, "{{ "{" }}{{ "}" }}")
    	return saved, nil
    {{ "}" }}

    // Update applies optional field changes. in.ID is the external UUID.
    func (s *Service) Update(ctx context.Context, in UpdateUserInput) (*user.User, error) {{ "{" }}
    	u, err := s.users.GetByUUID(ctx, in.ID)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	if in.Status != nil {{ "{" }}
    		if err := u.SetStatus(*in.Status); err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    	{{ "}" }}
    	if in.Password != nil {{ "{" }}
    		if err := user.ValidatePassword(*in.Password); err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    		hash, err := authinfra.HashPassword(*in.Password)
    		if err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    		if err := s.users.UpdatePassword(ctx, u.ID, hash); err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    	{{ "}" }}
    	if in.Nickname != nil {{ "{" }}
    		u.Nickname = *in.Nickname
    	{{ "}" }}
    	if in.Avatar != nil {{ "{" }}
    		u.Avatar = *in.Avatar
    	{{ "}" }}
    	if in.Email != nil {{ "{" }}
    		u.Email = *in.Email
    	{{ "}" }}
    	if in.Phone != nil {{ "{" }}
    		u.Phone = *in.Phone
    	{{ "}" }}
    	updated, err := s.users.Update(ctx, u)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "user.update", in.ID, "{{ "{" }}{{ "}" }}")
    	return updated, nil
    {{ "}" }}

    // Delete removes a user identified by external UUID.
    func (s *Service) Delete(ctx context.Context, id string) error {{ "{" }}
    	u, err := s.users.GetByUUID(ctx, id)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if err := s.users.Delete(ctx, u.ID); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	_, _ = s.enforcer.DeleteRolesForUser(id)
    	_ = s.audit.Write(ctx, "", "user.delete", id, "{{ "{" }}{{ "}" }}")
    	return nil
    {{ "}" }}

    // Get returns a single user identified by external UUID.
    func (s *Service) Get(ctx context.Context, id string) (*user.User, error) {{ "{" }}
    	return s.users.GetByUUID(ctx, id)
    {{ "}" }}

    // GetRoleCodes returns the role codes assigned to a user (for RPC responses).
    // uid is the external UUID.
    func (s *Service) GetRoleCodes(ctx context.Context, uid string) ([]string, error) {{ "{" }}
    	u, err := s.users.GetByUUID(ctx, uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	roles, err := s.users.ListRoles(ctx, u.ID)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	codes := make([]string, 0, len(roles))
    	for _, r := range roles {{ "{" }}
    		codes = append(codes, r.Code)
    	{{ "}" }}
    	return codes, nil
    {{ "}" }}

    // List returns a page of users and the total count.
    func (s *Service) List(ctx context.Context, page, pageSize int32) ([]*user.User, int32, error) {{ "{" }}
    	offset := int32(0)
    	if page > 1 {{ "{" }}
    		offset = (page - 1) * pageSize
    	{{ "}" }}
    	users, err := s.users.List(ctx, pageSize, offset)
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	total, err := s.users.Count(ctx)
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	return users, int32(total), nil
    {{ "}" }}

    // AssignRoles replaces the user's role set and syncs the Casbin g links.
    // uid is the external UUID; roleIDs are decimal-string role primary keys.
    func (s *Service) AssignRoles(ctx context.Context, uid string, roleIDs []string) error {{ "{" }}
    	u, err := s.users.GetByUUID(ctx, uid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	ids := make([]int64, 0, len(roleIDs))
    	for _, rid := range roleIDs {{ "{" }}
    		id, err := strconv.ParseInt(rid, 10, 64)
    		if err != nil {{ "{" }}
    			return role.ValidationError{{ "{" }}Field: "role_id", Msg: "must be a valid integer id: " + rid{{ "}" }}
    		{{ "}" }}
    		ids = append(ids, id)
    	{{ "}" }}
    	if err := s.users.AssignRoles(ctx, u.ID, ids); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	roles, err := s.users.ListRoles(ctx, u.ID)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	_, _ = s.enforcer.DeleteRolesForUser(uid)
    	for _, r := range roles {{ "{" }}
    		if _, err := s.enforcer.AddRoleForUser(uid, r.Code); err != nil {{ "{" }}
    			return err
    		{{ "}" }}
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "user.assign_roles", uid, "{{ "{" }}{{ "}" }}")
    	return nil
    {{ "}" }}
```

- [ ] **Step 4: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/user/...
```

Expected: PASS（`TestCreateHashesPassword`、`TestCreateRejectsShortPassword`、`TestUpdateStatusInt`、`TestAssignRolesSyncsCasbin` 全部通过）。

- [ ] **Step 5: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_application_user_user_service_go.yaml rbac-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "feat(rbac-kitex): user service resolves external UUID to internal int64 ID"
```

---

### Task 6: rbac-kitex — Role/Permission Application Service + Menu Query Service（strconv 边界转换）

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml`
- Modify: `rbac-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml`

**Interfaces:**
- Consumes: `role.Role`/`permission.Permission`/`user.User`/`menu.Menu`（int64 字段，Task 2）、`rolerepo.Repo`/`permissionrepo.Repo`/`userrepo.Repo`/`menurepo.Repo`（Task 3/4）。
- Produces: `rolesvc.RoleRepo`（`GetByID(ctx, id int64)`、`Delete(ctx, id int64)`、`AssignPermissions(ctx, roleID int64, permissionIDs []int64)`、`ListPermissionCodes(ctx, roleID int64)`）；`rolesvc.Service` 外部方法签名不变（`Update(ctx, in UpdateRoleInput)` 其中 `in.ID string`、`Delete(ctx, id string)`、`GrantPermissions(ctx, roleID string, permissionCodes []string)`），内部用 `strconv.ParseInt` 解析；`permsvc.PermRepo`（`GetByID(ctx, id int64)`、`ListFiltered(ctx, typ string, parentID int64, ...)`、`ListChildren(ctx, parentID int64)`、`Delete(ctx, id int64)`）；`permsvc.Service` 外部方法签名不变（`Create(ctx, in CreatePermissionInput)` 其中 `in.ParentID string`、`Update`/`Get`/`Delete`/`List` 均保持 string 契约），内部用 `strconv.ParseInt`/`FormatInt`；`menusvc.UserRoleReader`（`GetByUUID(ctx, uuid string) (*user.User, error)`、`ListRoles(ctx, uid int64) ([]*role.Role, error)`）、`menusvc.PermReader.ListByRoleIDs(ctx, roleIDs []int64)`；`menusvc.QueryService.UserPermCodes(ctx, uid string)`/`UserMenuTree(ctx, uid string)` 外部签名不变（uid 仍是 UUID 字符串），内部先 `GetByUUID` 解析。role/permission 的 `dto.go`（`CreateRoleInput`/`UpdateRoleInput`/`CreatePermissionInput`/`UpdatePermissionInput`/`ListPermissionsFilter`）字段类型全部保持 `string`，本 Task 不修改对应 `internal_application_role_dto_go.yaml`/`internal_application_permission_dto_go.yaml`（已核对二者无需改动）。

- [ ] **Step 1: 改测试 —— role_service_test.go fakeRoleRepo 改用 int64**

编辑 `rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/role/role_service_test.go
path: internal/application/role/role_service_test.go
update_behavior:
    type: skip
body: |
    package rolesvc

    import (
    	"context"
    	"fmt"
    	"testing"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/casbin"
    )

    type fakeRoleRepo struct {{ "{" }}
    	roles map[int64]*role.Role
    	next  int64
    {{ "}" }}

    func (f *fakeRoleRepo) GetByID(ctx context.Context, id int64) (*role.Role, error) {{ "{" }}
    	r, ok := f.roles[id]
    	if !ok {{ "{" }}
    		return nil, role.NotFoundError{{ "{" }}Key: fmt.Sprint(id){{ "}" }}
    	{{ "}" }}
    	return r, nil
    {{ "}" }}

    func (f *fakeRoleRepo) GetByCode(ctx context.Context, code string) (*role.Role, error) {{ "{" }}
    	for _, r := range f.roles {{ "{" }}
    		if r.Code == code {{ "{" }}
    			return r, nil
    		{{ "}" }}
    	{{ "}" }}
    	return nil, role.NotFoundError{{ "{" }}Key: code{{ "}" }}
    {{ "}" }}

    func (f *fakeRoleRepo) List(ctx context.Context, limit, offset int32) ([]*role.Role, error) {{ "{" }}
    	var out []*role.Role
    	for _, r := range f.roles {{ "{" }}
    		out = append(out, r)
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (f *fakeRoleRepo) Count(ctx context.Context) (int64, error) {{ "{" }} return int64(len(f.roles)), nil {{ "}" }}

    func (f *fakeRoleRepo) Save(ctx context.Context, r *role.Role) (*role.Role, error) {{ "{" }}
    	if r.ID == 0 {{ "{" }}
    		f.next++
    		r.ID = f.next
    	{{ "}" }}
    	f.roles[r.ID] = r
    	return r, nil
    {{ "}" }}

    func (f *fakeRoleRepo) Update(ctx context.Context, r *role.Role) (*role.Role, error) {{ "{" }}
    	f.roles[r.ID] = r
    	return r, nil
    {{ "}" }}

    func (f *fakeRoleRepo) Delete(ctx context.Context, id int64) error {{ "{" }}
    	delete(f.roles, id)
    	return nil
    {{ "}" }}

    func (f *fakeRoleRepo) AssignPermissions(ctx context.Context, roleID int64, permissionIDs []int64) error {{ "{" }}
    	return nil
    {{ "}" }}

    func (f *fakeRoleRepo) ListPermissionCodes(ctx context.Context, roleID int64) ([]string, error) {{ "{" }}
    	return nil, nil
    {{ "}" }}

    func (f *fakeRoleRepo) ListPermissionIDsByCodes(ctx context.Context, codes []string) ([]gen.ListPermissionIDsByCodesRow, error) {{ "{" }}
    	out := make([]gen.ListPermissionIDsByCodesRow, 0, len(codes))
    	for i, c := range codes {{ "{" }}
    		out = append(out, gen.ListPermissionIDsByCodesRow{{ "{" }}ID: int64(i + 1), Code: c{{ "}" }})
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    type fakePermReader struct {{ "{" }}
    	perms map[string]*permission.Permission
    {{ "}" }}

    func (f *fakePermReader) ListByCodes(ctx context.Context, codes []string) ([]*permission.Permission, error) {{ "{" }}
    	var out []*permission.Permission
    	for _, c := range codes {{ "{" }}
    		if p, ok := f.perms[c]; ok {{ "{" }}
    			out = append(out, p)
    		{{ "}" }}
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func newRoleService(t *testing.T) (*Service, *casbin.MemoryPolicyStore, *audit.MemoryWriter) {{ "{" }}
    	t.Helper()
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
    	return New(roles, perms, e, aud), store, aud
    {{ "}" }}

    func TestGrantPermissionsByCodeSyncsCasbin(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, store, aud := newRoleService(t)

    	if err := svc.GrantPermissions(ctx, "1", []string{{ "{" }}"user:create"{{ "}" }}); err != nil {{ "{" }}
    		t.Fatalf("GrantPermissions: %v", err)
    	{{ "}" }}
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", "user:create", "POST"); !allowed {{ "{" }}
    		t.Fatal("Enforce(admin, user:create, POST) = false, want true")
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", "user:delete", "DELETE"); allowed {{ "{" }}
    		t.Fatal("Enforce(admin, user:delete, DELETE) = true, want false")
    	{{ "}" }}
    	entries := aud.Entries()
    	if len(entries) == 0 || entries[0].Action != "role.grant_permissions" {{ "{" }}
    		t.Fatalf("audit entries = %+v, want role.grant_permissions", entries)
    	{{ "}" }}
    {{ "}" }}

    func TestGrantPermissionsUnknownCode(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newRoleService(t)
    	err := svc.GrantPermissions(ctx, "1", []string{{ "{" }}"nonexistent:code"{{ "}" }})
    	if err == nil {{ "{" }}
    		t.Fatal("GrantPermissions(unknown code) = nil, want error")
    	{{ "}" }}
    {{ "}" }}

    func TestCreateValidatesRole(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newRoleService(t)
    	if _, err := svc.Create(ctx, CreateRoleInput{{ "{" }}Code: "", Name: "Bad"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("Create(empty code) = nil, want error")
    	{{ "}" }}
    {{ "}" }}

    func TestUpdateRejectsNonIntegerID(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newRoleService(t)
    	if _, err := svc.Update(ctx, UpdateRoleInput{{ "{" }}ID: "not-a-number", Name: "X"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("Update(non-integer id) = nil, want error")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 改测试 —— permission_service_test.go fakePermRepo 改用 int64**

编辑 `rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/permission/permission_service_test.go
path: internal/application/permission/permission_service_test.go
update_behavior:
    type: skip
body: |
    package permsvc

    import (
    	"context"
    	"fmt"
    	"testing"

    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/casbin"
    )

    type fakePermRepo struct {{ "{" }}
    	perms map[int64]*permission.Permission
    	next  int64
    {{ "}" }}

    func (f *fakePermRepo) GetByID(ctx context.Context, id int64) (*permission.Permission, error) {{ "{" }}
    	p, ok := f.perms[id]
    	if !ok {{ "{" }}
    		return nil, permission.NotFoundError{{ "{" }}Key: fmt.Sprint(id){{ "}" }}
    	{{ "}" }}
    	return p, nil
    {{ "}" }}

    func (f *fakePermRepo) List(ctx context.Context, limit, offset int32) ([]*permission.Permission, error) {{ "{" }}
    	var out []*permission.Permission
    	for _, p := range f.perms {{ "{" }}
    		out = append(out, p)
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (f *fakePermRepo) ListFiltered(ctx context.Context, typ string, parentID int64, status int, limit, offset int32) ([]*permission.Permission, error) {{ "{" }}
    	return f.List(ctx, limit, offset)
    {{ "}" }}

    func (f *fakePermRepo) ListChildren(ctx context.Context, parentID int64) ([]*permission.Permission, error) {{ "{" }}
    	var out []*permission.Permission
    	for _, p := range f.perms {{ "{" }}
    		if p.ParentID == parentID {{ "{" }}
    			out = append(out, p)
    		{{ "}" }}
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (f *fakePermRepo) Count(ctx context.Context) (int64, error) {{ "{" }} return int64(len(f.perms)), nil {{ "}" }}

    func (f *fakePermRepo) Save(ctx context.Context, p *permission.Permission) (*permission.Permission, error) {{ "{" }}
    	if p.ID == 0 {{ "{" }}
    		f.next++
    		p.ID = f.next
    	{{ "}" }}
    	f.perms[p.ID] = p
    	return p, nil
    {{ "}" }}

    func (f *fakePermRepo) Update(ctx context.Context, p *permission.Permission) (*permission.Permission, error) {{ "{" }}
    	f.perms[p.ID] = p
    	return p, nil
    {{ "}" }}

    func (f *fakePermRepo) Delete(ctx context.Context, id int64) error {{ "{" }}
    	delete(f.perms, id)
    	return nil
    {{ "}" }}

    func newPermService(t *testing.T) (*Service, *casbin.Enforcer, *audit.MemoryWriter) {{ "{" }}
    	t.Helper()
    	store := casbin.NewMemoryPolicyStore()
    	e, err := casbin.NewEnforcer(store)
    	if err != nil {{ "{" }}
    		t.Fatalf("NewEnforcer: %v", err)
    	{{ "}" }}
    	repo := &fakePermRepo{{ "{" }}perms: map[int64]*permission.Permission{{ "{" }}{{ "}}" }}
    	aud := audit.NewMemoryWriter()
    	return New(repo, e, aud), e, aud
    {{ "}" }}

    func TestCreateRejectsUnknownType(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newPermService(t)
    	if _, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "x", Type: "bogus", Name: "X"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("Create(bogus type) = nil, want error")
    	{{ "}" }}
    {{ "}" }}

    func TestCreateAPIRequiresMethod(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newPermService(t)
    	if _, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "user:create", Type: permission.TypeAPI, Name: "Create User"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("Create(api, no method) = nil, want error")
    	{{ "}" }}
    {{ "}" }}

    func TestCreateAPINormalizesMethod(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newPermService(t)
    	p, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "user:create", Type: permission.TypeAPI, Name: "Create User", Method: "post"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	if p.Method != "POST" {{ "{" }}
    		t.Fatalf("method = %q, want POST", p.Method)
    	{{ "}" }}
    {{ "}" }}

    func TestCreateRejectsNonIntegerParentID(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newPermService(t)
    	if _, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "x", Type: permission.TypeMenu, Name: "X", ParentID: "not-a-number"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("Create(non-integer parent_id) = nil, want error")
    	{{ "}" }}
    {{ "}" }}

    func TestUpdateChangesFields(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newPermService(t)
    	p, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "user:create", Type: permission.TypeAPI, Name: "Create User", Method: "POST"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	newName := "Updated Name"
    	updated, err := svc.Update(ctx, UpdatePermissionInput{{ "{" }}ID: fmt.Sprint(p.ID), Name: &newName{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Update: %v", err)
    	{{ "}" }}
    	if updated.Name != "Updated Name" {{ "{" }}
    		t.Fatalf("Name = %q, want Updated Name", updated.Name)
    	{{ "}" }}
    {{ "}" }}

    func TestDeleteCascadesChildren(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, _, _ := newPermService(t)

    	parent, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "system", Type: permission.TypeCatalog, Name: "System"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create parent: %v", err)
    	{{ "}" }}
    	child, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "system:user", Type: permission.TypeMenu, Name: "Users", ParentID: fmt.Sprint(parent.ID){{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create child: %v", err)
    	{{ "}" }}

    	if err := svc.Delete(ctx, fmt.Sprint(parent.ID)); err != nil {{ "{" }}
    		t.Fatalf("Delete: %v", err)
    	{{ "}" }}
    	// Both parent and child should be deleted.
    	if _, err := svc.Get(ctx, fmt.Sprint(parent.ID)); err == nil {{ "{" }}
    		t.Fatal("parent should be deleted")
    	{{ "}" }}
    	if _, err := svc.Get(ctx, fmt.Sprint(child.ID)); err == nil {{ "{" }}
    		t.Fatal("child should be cascade-deleted")
    	{{ "}" }}
    {{ "}" }}

    func TestDeleteRemovesCasbinPolicy(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	svc, e, _ := newPermService(t)

    	p, err := svc.Create(ctx, CreatePermissionInput{{ "{" }}Code: "user:delete", Type: permission.TypeAPI, Name: "Delete User", Method: "DELETE"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}
    	if _, err := e.AddPolicy("admin", p.Code, "DELETE"); err != nil {{ "{" }}
    		t.Fatalf("AddPolicy: %v", err)
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", p.Code, "DELETE"); !allowed {{ "{" }}
    		t.Fatal("Enforce before delete = false, want true")
    	{{ "}" }}

    	if err := svc.Delete(ctx, fmt.Sprint(p.ID)); err != nil {{ "{" }}
    		t.Fatalf("Delete: %v", err)
    	{{ "}" }}
    	if allowed, _ := e.Enforce("admin", p.Code, "DELETE"); allowed {{ "{" }}
    		t.Fatal("Enforce after delete = true, want false")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 3: 改测试 —— menu_query_service_test.go fakeUserRoleReader/fakePermReader 改用 int64**

编辑 `rbac-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/menu/menu_query_service_test.go
path: internal/application/menu/menu_query_service_test.go
update_behavior:
    type: skip
body: |
    package menusvc

    import (
    	"context"
    	"testing"

    	"{{.Module}}/internal/domain/menu"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    )

    type fakeMenuRepo struct {{ "{" }}
    	menus []*menu.Menu
    {{ "}" }}

    func (f *fakeMenuRepo) ListMenusAsTree(ctx context.Context) ([]*menu.Menu, error) {{ "{" }}
    	return f.menus, nil
    {{ "}" }}

    type fakeUserRoleReader struct {{ "{" }}
    	roles []*role.Role
    {{ "}" }}

    func (f *fakeUserRoleReader) GetByUUID(ctx context.Context, uuid string) (*user.User, error) {{ "{" }}
    	return &user.User{{ "{" }}ID: 1, UUID: uuid{{ "}" }}, nil
    {{ "}" }}

    func (f *fakeUserRoleReader) ListRoles(ctx context.Context, uid int64) ([]*role.Role, error) {{ "{" }}
    	return f.roles, nil
    {{ "}" }}

    type fakePermReader struct {{ "{" }}
    	allPerms  []*permission.Permission
    	rolePerms []*permission.Permission
    {{ "}" }}

    func (f *fakePermReader) ListByRoleIDs(ctx context.Context, roleIDs []int64) ([]*permission.Permission, error) {{ "{" }}
    	return f.rolePerms, nil
    {{ "}" }}

    func (f *fakePermReader) List(ctx context.Context, limit, offset int32) ([]*permission.Permission, error) {{ "{" }}
    	return f.allPerms, nil
    {{ "}" }}

    func TestListMenus(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	repo := &fakeMenuRepo{{ "{" }}menus: []*menu.Menu{{ "{" }}
    		{{ "{" }}ID: 1, Code: "system", Name: "System", Type: menu.TypeCatalog, Sort: 1{{ "}" }},
    		{{ "{" }}ID: 2, Code: "system:user", Name: "Users", ParentID: 1, Type: menu.TypeMenu, Sort: 1{{ "}" }},
    	{{ "}}" }}
    	qs := New(repo, &fakeUserRoleReader{{ "{" }}{{ "}" }}, &fakePermReader{{ "{" }}{{ "}" }})
    	menus, err := qs.ListMenus(ctx)
    	if err != nil {{ "{" }}
    		t.Fatalf("ListMenus: %v", err)
    	{{ "}" }}
    	if len(menus) != 2 {{ "{" }}
    		t.Fatalf("len = %d, want 2", len(menus))
    	{{ "}" }}
    {{ "}" }}

    func TestUserPermCodesAdmin(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	qs := New(&fakeMenuRepo{{ "{" }}{{ "}" }}, &fakeUserRoleReader{{ "{" }}roles: []*role.Role{{ "{{" }}ID: 1, Code: "admin"{{ "}}" }}{{ "}" }}, &fakePermReader{{ "{" }}allPerms: []*permission.Permission{{ "{" }}
    		{{ "{" }}Code: "user:create"{{ "}" }},
    		{{ "{" }}Code: "user:delete"{{ "}" }},
    	{{ "}}" }})
    	codes, err := qs.UserPermCodes(ctx, "uuid-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("UserPermCodes: %v", err)
    	{{ "}" }}
    	if len(codes) != 2 {{ "{" }}
    		t.Fatalf("codes = %v, want 2 entries", codes)
    	{{ "}" }}
    {{ "}" }}

    func TestUserPermCodesNormal(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	qs := New(&fakeMenuRepo{{ "{" }}{{ "}" }}, &fakeUserRoleReader{{ "{" }}roles: []*role.Role{{ "{{" }}ID: 1, Code: "editor"{{ "}}" }}{{ "}" }}, &fakePermReader{{ "{" }}rolePerms: []*permission.Permission{{ "{" }}
    		{{ "{" }}Code: "user:create"{{ "}" }},
    	{{ "}}" }})
    	codes, err := qs.UserPermCodes(ctx, "uuid-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("UserPermCodes: %v", err)
    	{{ "}" }}
    	if len(codes) != 1 || codes[0] != "user:create" {{ "{" }}
    		t.Fatalf("codes = %v, want [user:create]", codes)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 4: 运行测试，确认失败（编译失败：旧 service/query-service 仍按 string 直接调用 repo，fake 类型与新接口不匹配）**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/role/... ./internal/application/permission/... ./internal/application/menu/...
```

Expected: FAIL —— 三个包均编译失败（`*fakeRoleRepo`/`*fakePermRepo`/`*fakeUserRoleReader`/`*fakePermReader` 与旧接口方法签名不匹配）。

- [ ] **Step 5: 实现 —— role_service.go**

编辑 `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/role/role_service.go
path: internal/application/role/role_service.go
update_behavior:
    type: skip
body: |
    package rolesvc

    import (
    	"context"
    	"strconv"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/infrastructure/audit"
    )

    // RoleRepo is the role persistence + permission-assignment port.
    type RoleRepo interface {{ "{" }}
    	GetByID(ctx context.Context, id int64) (*role.Role, error)
    	GetByCode(ctx context.Context, code string) (*role.Role, error)
    	List(ctx context.Context, limit, offset int32) ([]*role.Role, error)
    	Count(ctx context.Context) (int64, error)
    	Save(ctx context.Context, r *role.Role) (*role.Role, error)
    	Update(ctx context.Context, r *role.Role) (*role.Role, error)
    	Delete(ctx context.Context, id int64) error
    	AssignPermissions(ctx context.Context, roleID int64, permissionIDs []int64) error
    	ListPermissionCodes(ctx context.Context, roleID int64) ([]string, error)
    	ListPermissionIDsByCodes(ctx context.Context, codes []string) ([]gen.ListPermissionIDsByCodesRow, error)
    {{ "}" }}

    // PermReader resolves permissions for the grant use case.
    type PermReader interface {{ "{" }}
    	ListByCodes(ctx context.Context, codes []string) ([]*permission.Permission, error)
    {{ "}" }}

    // Enforcer syncs permission grants into Casbin (p policies).
    type Enforcer interface {{ "{" }}
    	AddPolicy(params ...any) (bool, error)
    	RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error)
    {{ "}" }}

    // Service implements the role management use cases. Public methods take the
    // external decimal-string role id and resolve it to the internal int64
    // primary key via strconv before calling RoleRepo.
    type Service struct {{ "{" }}
    	roles    RoleRepo
    	perms    PermReader
    	enforcer Enforcer
    	audit    audit.Writer
    {{ "}" }}

    // New creates the role application service.
    func New(roles RoleRepo, perms PermReader, enforcer Enforcer, audit audit.Writer) *Service {{ "{" }}
    	return &Service{{ "{" }}roles: roles, perms: perms, enforcer: enforcer, audit: audit{{ "}" }}
    {{ "}" }}

    // Create persists a new role.
    func (s *Service) Create(ctx context.Context, in CreateRoleInput) (*role.Role, error) {{ "{" }}
    	r, err := role.New(in.Code, in.Name)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	if in.Remark != "" {{ "{" }}
    		r.Remark = in.Remark
    	{{ "}" }}
    	saved, err := s.roles.Save(ctx, r)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "role.create", in.Code, "{{ "{" }}{{ "}" }}")
    	return saved, nil
    {{ "}" }}

    // Update renames a role and optionally changes status/remark. in.ID is the
    // decimal-string form of the internal int64 primary key.
    func (s *Service) Update(ctx context.Context, in UpdateRoleInput) (*role.Role, error) {{ "{" }}
    	id, err := strconv.ParseInt(in.ID, 10, 64)
    	if err != nil {{ "{" }}
    		return nil, role.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	r, err := s.roles.GetByID(ctx, id)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	r.Name = in.Name
    	if in.Status != nil {{ "{" }}
    		r.Status = *in.Status
    	{{ "}" }}
    	if in.Remark != nil {{ "{" }}
    		r.Remark = *in.Remark
    	{{ "}" }}
    	saved, err := s.roles.Update(ctx, r)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "role.update", in.ID, "{{ "{" }}{{ "}" }}")
    	return saved, nil
    {{ "}" }}

    // Delete removes a role identified by its decimal-string id.
    func (s *Service) Delete(ctx context.Context, id string) error {{ "{" }}
    	rid, err := strconv.ParseInt(id, 10, 64)
    	if err != nil {{ "{" }}
    		return role.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	if err := s.roles.Delete(ctx, rid); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "role.delete", id, "{{ "{" }}{{ "}" }}")
    	return nil
    {{ "}" }}

    // List returns a page of roles and the total count.
    func (s *Service) List(ctx context.Context, page, pageSize int32) ([]*role.Role, int32, error) {{ "{" }}
    	offset := int32(0)
    	if page > 1 {{ "{" }}
    		offset = (page - 1) * pageSize
    	{{ "}" }}
    	roles, err := s.roles.List(ctx, pageSize, offset)
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	total, err := s.roles.Count(ctx)
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	return roles, int32(total), nil
    {{ "}" }}

    // GrantPermissions assigns permissions to a role using permission codes (not IDs).
    // roleID is the decimal-string form of the internal int64 primary key.
    // Unknown codes produce a domain error.
    func (s *Service) GrantPermissions(ctx context.Context, roleID string, permissionCodes []string) error {{ "{" }}
    	if err := role.Assign(ctx, roleID, permissionCodes); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	rid, err := strconv.ParseInt(roleID, 10, 64)
    	if err != nil {{ "{" }}
    		return role.ValidationError{{ "{" }}Field: "role_id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	r, err := s.roles.GetByID(ctx, rid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	// Resolve codes → permissions
    	perms, err := s.perms.ListByCodes(ctx, permissionCodes)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	// Check all codes were resolved
    	resolved := make(map[string]bool, len(perms))
    	for _, p := range perms {{ "{" }}
    		resolved[p.Code] = true
    	{{ "}" }}
    	for _, c := range permissionCodes {{ "{" }}
    		if !resolved[c] {{ "{" }}
    			return permission.NotFoundError{{ "{" }}Key: c{{ "}" }}
    		{{ "}" }}
    	{{ "}" }}
    	// Resolve codes → IDs for the role_permissions join table
    	rows, err := s.roles.ListPermissionIDsByCodes(ctx, permissionCodes)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	ids := make([]int64, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		ids = append(ids, row.ID)
    	{{ "}" }}
    	if err := s.roles.AssignPermissions(ctx, rid, ids); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	// Sync Casbin policies: clear existing then add new.
    	_, _ = s.enforcer.RemoveFilteredPolicy(0, r.Code)
    	for _, p := range perms {{ "{" }}
    		if _, err := s.enforcer.AddPolicy(r.Code, p.Code, p.Method); err != nil {{ "{" }}
    			return err
    		{{ "}" }}
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "role.grant_permissions", roleID, "{{ "{" }}{{ "}" }}")
    	return nil
    {{ "}" }}
```

- [ ] **Step 6: 实现 —— permission_service.go**

编辑 `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/permission/permission_service.go
path: internal/application/permission/permission_service.go
update_behavior:
    type: skip
body: |
    package permsvc

    import (
    	"context"
    	"strconv"

    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/infrastructure/audit"
    )

    // PermRepo is the permission persistence port consumed by the service.
    type PermRepo interface {{ "{" }}
    	GetByID(ctx context.Context, id int64) (*permission.Permission, error)
    	List(ctx context.Context, limit, offset int32) ([]*permission.Permission, error)
    	ListFiltered(ctx context.Context, typ string, parentID int64, status int, limit, offset int32) ([]*permission.Permission, error)
    	ListChildren(ctx context.Context, parentID int64) ([]*permission.Permission, error)
    	Count(ctx context.Context) (int64, error)
    	Save(ctx context.Context, p *permission.Permission) (*permission.Permission, error)
    	Update(ctx context.Context, p *permission.Permission) (*permission.Permission, error)
    	Delete(ctx context.Context, id int64) error
    {{ "}" }}

    // Enforcer removes stale Casbin policies when a permission is deleted.
    type Enforcer interface {{ "{" }}
    	RemoveFilteredPolicy(fieldIndex int, fieldValues ...string) (bool, error)
    {{ "}" }}

    // Service implements the permission management use cases. Public methods
    // take the external decimal-string permission id (and parent_id) and
    // resolve them to internal int64 keys via strconv before calling PermRepo.
    // A parent_id of "" means root (internal 0).
    type Service struct {{ "{" }}
    	perms    PermRepo
    	enforcer Enforcer
    	audit    audit.Writer
    {{ "}" }}

    // New creates the permission application service.
    func New(perms PermRepo, enforcer Enforcer, audit audit.Writer) *Service {{ "{" }}
    	return &Service{{ "{" }}perms: perms, enforcer: enforcer, audit: audit{{ "}" }}
    {{ "}" }}

    // Create persists a new permission (validating type via the domain).
    func (s *Service) Create(ctx context.Context, in CreatePermissionInput) (*permission.Permission, error) {{ "{" }}
    	var parentID int64
    	if in.ParentID != "" {{ "{" }}
    		pid, err := strconv.ParseInt(in.ParentID, 10, 64)
    		if err != nil {{ "{" }}
    			return nil, permission.ValidationError{{ "{" }}Field: "parent_id", Msg: "must be a valid integer id"{{ "}" }}
    		{{ "}" }}
    		parentID = pid
    	{{ "}" }}
    	p, err := permission.New(in.Code, in.Type, in.Name, parentID, in.Path, in.Icon, in.RouteName, in.Redirect, in.KeepAlive, in.HideInMenu, in.IsExternal, in.Method, in.Sort, in.Status, in.Description)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	saved, err := s.perms.Save(ctx, p)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "permission.create", in.Code, "{{ "{" }}{{ "}" }}")
    	return saved, nil
    {{ "}" }}

    // Update modifies an existing permission.
    func (s *Service) Update(ctx context.Context, in UpdatePermissionInput) (*permission.Permission, error) {{ "{" }}
    	id, err := strconv.ParseInt(in.ID, 10, 64)
    	if err != nil {{ "{" }}
    		return nil, permission.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	p, err := s.perms.GetByID(ctx, id)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	if in.Code != nil {{ "{" }}
    		p.Code = *in.Code
    	{{ "}" }}
    	if in.Type != nil {{ "{" }}
    		p.Type = *in.Type
    	{{ "}" }}
    	if in.Name != nil {{ "{" }}
    		p.Name = *in.Name
    	{{ "}" }}
    	if in.ParentID != nil {{ "{" }}
    		pid, err := strconv.ParseInt(*in.ParentID, 10, 64)
    		if err != nil {{ "{" }}
    			return nil, permission.ValidationError{{ "{" }}Field: "parent_id", Msg: "must be a valid integer id"{{ "}" }}
    		{{ "}" }}
    		p.ParentID = pid
    	{{ "}" }}
    	if in.Path != nil {{ "{" }}
    		p.Path = *in.Path
    	{{ "}" }}
    	if in.Icon != nil {{ "{" }}
    		p.Icon = *in.Icon
    	{{ "}" }}
    	if in.RouteName != nil {{ "{" }}
    		p.RouteName = *in.RouteName
    	{{ "}" }}
    	if in.Redirect != nil {{ "{" }}
    		p.Redirect = *in.Redirect
    	{{ "}" }}
    	if in.KeepAlive != nil {{ "{" }}
    		p.KeepAlive = in.KeepAlive
    	{{ "}" }}
    	if in.HideInMenu != nil {{ "{" }}
    		p.HideInMenu = in.HideInMenu
    	{{ "}" }}
    	if in.IsExternal != nil {{ "{" }}
    		p.IsExternal = in.IsExternal
    	{{ "}" }}
    	if in.Method != nil {{ "{" }}
    		p.Method = *in.Method
    	{{ "}" }}
    	if in.Sort != nil {{ "{" }}
    		p.Sort = *in.Sort
    	{{ "}" }}
    	if in.Status != nil {{ "{" }}
    		p.Status = *in.Status
    	{{ "}" }}
    	if in.Description != nil {{ "{" }}
    		p.Description = *in.Description
    	{{ "}" }}
    	updated, err := s.perms.Update(ctx, p)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	_ = s.audit.Write(ctx, "", "permission.update", in.ID, "{{ "{" }}{{ "}" }}")
    	return updated, nil
    {{ "}" }}

    // Get returns a single permission by decimal-string ID.
    func (s *Service) Get(ctx context.Context, id string) (*permission.Permission, error) {{ "{" }}
    	pid, err := strconv.ParseInt(id, 10, 64)
    	if err != nil {{ "{" }}
    		return nil, permission.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	return s.perms.GetByID(ctx, pid)
    {{ "}" }}

    // Delete removes a permission and cascades to children (tree semantics).
    // Also removes stale Casbin policies.
    func (s *Service) Delete(ctx context.Context, id string) error {{ "{" }}
    	pid, err := strconv.ParseInt(id, 10, 64)
    	if err != nil {{ "{" }}
    		return permission.ValidationError{{ "{" }}Field: "id", Msg: "must be a valid integer id"{{ "}" }}
    	{{ "}" }}
    	p, err := s.perms.GetByID(ctx, pid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	// Cascade: delete children recursively (DFS post-order).
    	if err := s.cascadeDelete(ctx, pid); err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	_, _ = s.enforcer.RemoveFilteredPolicy(1, p.Code)
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
    	return s.perms.Delete(ctx, parentID)
    {{ "}" }}

    // List returns a page of permissions and the total count.
    func (s *Service) List(ctx context.Context, filter ListPermissionsFilter) ([]*permission.Permission, int32, error) {{ "{" }}
    	offset := int32(0)
    	if filter.Page > 1 {{ "{" }}
    		offset = (filter.Page - 1) * filter.PageSize
    	{{ "}" }}
    	var perms []*permission.Permission
    	var err error
    	if filter.Type != "" || filter.ParentID != "" || filter.Status >= 0 {{ "{" }}
    		status := filter.Status
    		if status == 0 {{ "{" }}
    			status = -1 // no filter
    		{{ "}" }}
    		var parentID int64
    		if filter.ParentID != "" {{ "{" }}
    			parentID, err = strconv.ParseInt(filter.ParentID, 10, 64)
    			if err != nil {{ "{" }}
    				return nil, 0, permission.ValidationError{{ "{" }}Field: "parent_id", Msg: "must be a valid integer id"{{ "}" }}
    			{{ "}" }}
    		{{ "}" }}
    		perms, err = s.perms.ListFiltered(ctx, filter.Type, parentID, status, filter.PageSize, offset)
    	{{ "}" }} else {{ "{" }}
    		perms, err = s.perms.List(ctx, filter.PageSize, offset)
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	total, err := s.perms.Count(ctx)
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	return perms, int32(total), nil
    {{ "}" }}
```

- [ ] **Step 7: 实现 —— menu_query_service.go 加入 UUID 解析**

编辑 `rbac-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml`，把 `body:` 替换为：

```yaml
# ncgo exported template — internal/application/menu/menu_query_service.go
path: internal/application/menu/menu_query_service.go
update_behavior:
    type: skip
body: |
    package menusvc

    import (
    	"context"
    	"math"

    	"{{.Module}}/internal/domain/menu"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    )

    // AdminRoleCode grants full menu/permission visibility.
    const AdminRoleCode = "admin"

    // MenuRepo is the read-only menu persistence port consumed by the service.
    type MenuRepo interface {{ "{" }}
    	ListMenusAsTree(ctx context.Context) ([]*menu.Menu, error)
    {{ "}" }}

    // UserRoleReader resolves a user's external UUID to its internal int64 ID
    // and lists its roles for menu/permission visibility.
    type UserRoleReader interface {{ "{" }}
    	GetByUUID(ctx context.Context, uuid string) (*user.User, error)
    	ListRoles(ctx context.Context, uid int64) ([]*role.Role, error)
    {{ "}" }}

    // PermReader resolves a user's granted permissions.
    type PermReader interface {{ "{" }}
    	ListByRoleIDs(ctx context.Context, roleIDs []int64) ([]*permission.Permission, error)
    	List(ctx context.Context, limit, offset int32) ([]*permission.Permission, error)
    {{ "}" }}

    // QueryService implements the read-only menu use cases.
    type QueryService struct {{ "{" }}
    	menus MenuRepo
    	users UserRoleReader
    	perms PermReader
    {{ "}" }}

    // New creates the menu query service.
    func New(menus MenuRepo, users UserRoleReader, perms PermReader) *QueryService {{ "{" }}
    	return &QueryService{{ "{" }}menus: menus, users: users, perms: perms{{ "}" }}
    {{ "}" }}

    // ListMenus returns every enabled menu (catalog+menu types) as a flat list.
    func (s *QueryService) ListMenus(ctx context.Context) ([]*menu.Menu, error) {{ "{" }}
    	return s.menus.ListMenusAsTree(ctx)
    {{ "}" }}

    // UserPermCodes returns the unified permission codes visible to a user. uid
    // is the external UUID. The admin role sees every permission.
    func (s *QueryService) UserPermCodes(ctx context.Context, uid string) ([]string, error) {{ "{" }}
    	u, err := s.users.GetByUUID(ctx, uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	roles, err := s.users.ListRoles(ctx, u.ID)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	if hasRole(roles, AdminRoleCode) {{ "{" }}
    		all, err := s.perms.List(ctx, math.MaxInt32, 0)
    		if err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    		codes := make([]string, 0, len(all))
    		for _, p := range all {{ "{" }}
    			codes = append(codes, p.Code)
    		{{ "}" }}
    		return codes, nil
    	{{ "}" }}
    	roleIDs := make([]int64, 0, len(roles))
    	for _, r := range roles {{ "{" }}
    		roleIDs = append(roleIDs, r.ID)
    	{{ "}" }}
    	perms, err := s.perms.ListByRoleIDs(ctx, roleIDs)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	seen := map[string]bool{{ "{" }}{{ "}" }}
    	codes := make([]string, 0, len(perms))
    	for _, p := range perms {{ "{" }}
    		if seen[p.Code] {{ "{" }}
    			continue
    		{{ "}" }}
    		seen[p.Code] = true
    		codes = append(codes, p.Code)
    	{{ "}" }}
    	return codes, nil
    {{ "}" }}

    // UserMenuTree returns the menu forest visible to a user. uid is the
    // external UUID. The admin role sees the full menu tree; other users only
    // see menus whose code they hold.
    func (s *QueryService) UserMenuTree(ctx context.Context, uid string) ([]*menu.Node, error) {{ "{" }}
    	u, err := s.users.GetByUUID(ctx, uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	roles, err := s.users.ListRoles(ctx, u.ID)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	if hasRole(roles, AdminRoleCode) {{ "{" }}
    		items, err := s.menus.ListMenusAsTree(ctx)
    		if err != nil {{ "{" }}
    			return nil, err
    		{{ "}" }}
    		return menu.BuildTree(items), nil
    	{{ "}" }}
    	codes, err := s.UserPermCodes(ctx, uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	// Filter the full menu tree to only include menus whose code is in the user's codes.
    	items, err := s.menus.ListMenusAsTree(ctx)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	codeSet := make(map[string]bool, len(codes))
    	for _, c := range codes {{ "{" }}
    		codeSet[c] = true
    	{{ "}" }}
    	filtered := make([]*menu.Menu, 0, len(items))
    	for _, m := range items {{ "{" }}
    		if codeSet[m.Code] {{ "{" }}
    			filtered = append(filtered, m)
    		{{ "}" }}
    	{{ "}" }}
    	return menu.BuildTree(filtered), nil
    {{ "}" }}

    func hasRole(roles []*role.Role, code string) bool {{ "{" }}
    	for _, r := range roles {{ "{" }}
    		if r.Code == code {{ "{" }}
    			return true
    		{{ "}" }}
    	{{ "}" }}
    	return false
    {{ "}" }}
```

- [ ] **Step 8: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/rbac-e2e --kind kitex --template-dir "$REPO_ROOT/rbac-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/...
```

Expected: PASS（`internal/application/role`、`internal/application/permission`、`internal/application/menu`、`internal/application/user` 全部通过）。

- [ ] **Step 9: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml rbac-kitex/kitex-template/internal_application_role_role_service_test_go.yaml rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml rbac-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml rbac-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml rbac-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml
git commit -m "feat(rbac-kitex): role/permission services and menu query service resolve external string IDs to int64"
```

---

### Task 7: rbac-kitex — Handler 输出转换（strconv/UUID）+ 全量验收

**Files:**
- Modify: `rbac-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml`

**Interfaces:**
- Consumes: `user.User{ID int64; UUID string}`、`role.Role{ID int64}`、`permission.Permission{ID int64; ParentID int64}`、`menu.Menu{ID int64; ParentID int64}`（Task 2）；`usersvc.Service.GetRoleCodes(ctx, uid string)`（Task 5，uid 为外部 UUID）。
- Produces: `toV1User`/`toV1Role`/`toV1Permission`/`toV1Menu` 辅助函数正确地把 int64 内部字段格式化成 `v1.*` 的 `string` 字段；这是本次改动里**唯一**需要改的 handler 代码——RPC 方法体本身（`CreateUser`/`UpdateUser`/`AssignRolesToUser`/`GrantPermissionsToRole`/`CreatePermission`/`UpdatePermission`/`ListPermissions`/`UpdateRole` 等）逐一核对后确认不需要改动，因为它们把 `req.Id`/`req.ParentId`/`req.RoleIds`/`req.PermissionCodes` 等 `string`/`[]string` 字段原样传给 service（DTO 契约不变）。

这是本次改动系列的收尾 Task：完成后整个 `rbac-kitex` 渲染项目要 `go build ./...` 且 `go test ./...` 全绿（除已知 gated-skip 的 postgres 测试）。

- [ ] **Step 1: 运行全量 build+test，确认失败（`toV1User` 等函数把 `int64` 字段直接赋给 `string` proto 字段，编译失败）**

```bash
bash /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates/rbac-kitex/test/e2e_test.sh
```

Expected: FAIL —— `hermetic go build` 失败：`cannot use u.ID (variable of type int64) as string value in struct literal`（`toV1User`/`toV1Role`/`toV1Permission`/`toV1Menu` 三处），以及 `s.user.GetRoleCodes(ctx, u.ID)` 参数类型不匹配（`GetRoleCodes` 期望 `string`，`u.ID` 现在是 `int64`）。若 `ncgo`/`kitex`/`protoc`/`sqlc` 任一工具缺失，脚本会打印 `skipped: <工具> 未安装` 并以退出码 0 结束——此时改为手动用 Task 1-6 里的 `ncgo new` + `go build ./...` 命令验证到同等程度即可。

- [ ] **Step 2: 实现 —— handler.go 的 toV1* 辅助函数与 GetRoleCodes 调用点改为 UUID/strconv 输出**

编辑 `rbac-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml`，把 `body:` 替换为（相对原文件的改动：import 增加 `"strconv"`；四处 `s.user.GetRoleCodes(ctx, u.ID)` 改成 `s.user.GetRoleCodes(ctx, u.UUID)`；`toV1User` 的 `Id: u.ID` 改成 `Id: u.UUID`；`toV1Role` 的 `Id: r.ID` 改成 `Id: strconv.FormatInt(r.ID, 10)`；`toV1Permission`/`toV1Menu` 的 `Id`/`ParentId` 改用 `strconv.FormatInt`/新增的 `formatParentID` helper；其余 RPC 方法体逐字节不变）：

```yaml
# ncgo exported template — internal/handler/rbacservice/handler.go
path: internal/handler/rbacservice/handler.go
update_behavior:
    type: skip
body: |
    // Code generated by kitex generator. Edited for rbac-kitex.

    package rbacservicehandler

    import (
    	"context"
    	"strconv"

    	menusvc "{{.Module}}/internal/application/menu"
    	permsvc "{{.Module}}/internal/application/permission"
    	rbacsvc "{{.Module}}/internal/application/rbac"
    	rolesvc "{{.Module}}/internal/application/role"
    	usersvc "{{.Module}}/internal/application/user"
    	"{{.Module}}/internal/domain/menu"
    	"{{.Module}}/internal/domain/permission"
    	"{{.Module}}/internal/domain/role"
    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/pkg/rpcerror"
    	v1 "{{.Module}}/kitex_gen/api/rbac/v1"
    )

    // RBACServiceImpl implements the Kitex-generated RBACService server interface.
    type RBACServiceImpl struct {{ "{" }}
    	user       *usersvc.Service
    	role       *rolesvc.Service
    	permission *permsvc.Service
    	menuQuery  *menusvc.QueryService
    	rbac       *rbacsvc.EnforceService
    {{ "}" }}

    // NewRBACServiceImpl creates a Kitex handler with its application services.
    func NewRBACServiceImpl(
    	userSvc *usersvc.Service,
    	roleSvc *rolesvc.Service,
    	permSvc *permsvc.Service,
    	menuQuerySvc *menusvc.QueryService,
    	rbacSvc *rbacsvc.EnforceService,
    ) *RBACServiceImpl {{ "{" }}
    	return &RBACServiceImpl{{ "{" }}
    		user:       userSvc,
    		role:       roleSvc,
    		permission: permSvc,
    		menuQuery:  menuQuerySvc,
    		rbac:       rbacSvc,
    	{{ "}" }}
    {{ "}" }}

    // CreateUser implements the RBACService RPC method.
    func (s *RBACServiceImpl) CreateUser(ctx context.Context, req *v1.CreateUserReq) (resp *v1.UserResp, err error) {{ "{" }}
    	u, err := s.user.Create(ctx, usersvc.CreateUserInput{{ "{" }}
    		Username: req.Username, Password: req.Password,
    		Nickname: req.Nickname, Avatar: req.Avatar,
    		Email: req.Email, Phone: req.Phone,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	roles, err := s.user.GetRoleCodes(ctx, u.UUID)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.UserResp{{ "{" }}User: toV1User(u, roles){{ "}" }}, nil
    {{ "}" }}

    // UpdateUser implements the RBACService RPC method.
    func (s *RBACServiceImpl) UpdateUser(ctx context.Context, req *v1.UpdateUserReq) (resp *v1.UserResp, err error) {{ "{" }}
    	in := usersvc.UpdateUserInput{{ "{" }}ID: req.Id, Password: req.Password, Status: int32PtrToInt(req.Status){{ "}" }}
    	if req.Nickname != nil {{ "{" }}
    		in.Nickname = req.Nickname
    	{{ "}" }}
    	if req.Avatar != nil {{ "{" }}
    		in.Avatar = req.Avatar
    	{{ "}" }}
    	if req.Email != nil {{ "{" }}
    		in.Email = req.Email
    	{{ "}" }}
    	if req.Phone != nil {{ "{" }}
    		in.Phone = req.Phone
    	{{ "}" }}
    	u, err := s.user.Update(ctx, in)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	roles, err := s.user.GetRoleCodes(ctx, u.UUID)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.UserResp{{ "{" }}User: toV1User(u, roles){{ "}" }}, nil
    {{ "}" }}

    // DeleteUser implements the RBACService RPC method.
    func (s *RBACServiceImpl) DeleteUser(ctx context.Context, req *v1.DeleteUserReq) (resp *v1.EmptyResp, err error) {{ "{" }}
    	if err := s.user.Delete(ctx, req.Id); err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.EmptyResp{{ "{" }}{{ "}" }}, nil
    {{ "}" }}

    // GetUser implements the RBACService RPC method.
    func (s *RBACServiceImpl) GetUser(ctx context.Context, req *v1.GetUserReq) (resp *v1.UserResp, err error) {{ "{" }}
    	u, err := s.user.Get(ctx, req.Id)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	roles, err := s.user.GetRoleCodes(ctx, u.UUID)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.UserResp{{ "{" }}User: toV1User(u, roles){{ "}" }}, nil
    {{ "}" }}

    // ListUsers implements the RBACService RPC method.
    func (s *RBACServiceImpl) ListUsers(ctx context.Context, req *v1.ListUsersReq) (resp *v1.ListUsersResp, err error) {{ "{" }}
    	users, total, err := s.user.List(ctx, req.Page, req.PageSize)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	out := make([]*v1.User, 0, len(users))
    	for _, u := range users {{ "{" }}
    		roles, err := s.user.GetRoleCodes(ctx, u.UUID)
    		if err != nil {{ "{" }}
    			return nil, rpcerror.ToBizError(err)
    		{{ "}" }}
    		out = append(out, toV1User(u, roles))
    	{{ "}" }}
    	return &v1.ListUsersResp{{ "{" }}Users: out, Total: total{{ "}" }}, nil
    {{ "}" }}

    // CreateRole implements the RBACService RPC method.
    func (s *RBACServiceImpl) CreateRole(ctx context.Context, req *v1.CreateRoleReq) (resp *v1.RoleResp, err error) {{ "{" }}
    	r, err := s.role.Create(ctx, rolesvc.CreateRoleInput{{ "{" }}Code: req.Code, Name: req.Name, Remark: req.Remark{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.RoleResp{{ "{" }}Role: toV1Role(r, nil){{ "}" }}, nil
    {{ "}" }}

    // UpdateRole implements the RBACService RPC method.
    func (s *RBACServiceImpl) UpdateRole(ctx context.Context, req *v1.UpdateRoleReq) (resp *v1.RoleResp, err error) {{ "{" }}
    	in := rolesvc.UpdateRoleInput{{ "{" }}ID: req.Id, Name: req.Name, Status: int32PtrToInt(req.Status), Remark: req.Remark{{ "}" }}
    	r, err := s.role.Update(ctx, in)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.RoleResp{{ "{" }}Role: toV1Role(r, nil){{ "}" }}, nil
    {{ "}" }}

    // DeleteRole implements the RBACService RPC method.
    func (s *RBACServiceImpl) DeleteRole(ctx context.Context, req *v1.DeleteRoleReq) (resp *v1.EmptyResp, err error) {{ "{" }}
    	if err := s.role.Delete(ctx, req.Id); err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.EmptyResp{{ "{" }}{{ "}" }}, nil
    {{ "}" }}

    // ListRoles implements the RBACService RPC method.
    func (s *RBACServiceImpl) ListRoles(ctx context.Context, req *v1.ListRolesReq) (resp *v1.ListRolesResp, err error) {{ "{" }}
    	roles, total, err := s.role.List(ctx, req.Page, req.PageSize)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	out := make([]*v1.Role, 0, len(roles))
    	for _, r := range roles {{ "{" }}
    		out = append(out, toV1Role(r, nil))
    	{{ "}" }}
    	return &v1.ListRolesResp{{ "{" }}Roles: out, Total: total{{ "}" }}, nil
    {{ "}" }}

    // CreatePermission implements the RBACService RPC method.
    func (s *RBACServiceImpl) CreatePermission(ctx context.Context, req *v1.CreatePermissionReq) (resp *v1.PermissionResp, err error) {{ "{" }}
    	p, err := s.permission.Create(ctx, permsvc.CreatePermissionInput{{ "{" }}
    		Code: req.Code, Type: req.Type, Name: req.Name, ParentID: req.ParentId,
    		Path: req.Path, Icon: req.Icon, RouteName: req.RouteName, Redirect: req.Redirect,
    		KeepAlive: &req.KeepAlive, HideInMenu: &req.HideInMenu, IsExternal: &req.IsExternal,
    		Method: req.Method, Sort: req.Sort, Status: int(req.Status), Description: req.Description,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.PermissionResp{{ "{" }}Permission: toV1Permission(p){{ "}" }}, nil
    {{ "}" }}

    // UpdatePermission implements the RBACService RPC method.
    func (s *RBACServiceImpl) UpdatePermission(ctx context.Context, req *v1.UpdatePermissionReq) (resp *v1.PermissionResp, err error) {{ "{" }}
    	p, err := s.permission.Update(ctx, permsvc.UpdatePermissionInput{{ "{" }}
    		ID: req.Id, Code: req.Code, Type: req.Type, Name: req.Name, ParentID: req.ParentId,
    		Path: req.Path, Icon: req.Icon, RouteName: req.RouteName, Redirect: req.Redirect,
    		KeepAlive: req.KeepAlive, HideInMenu: req.HideInMenu, IsExternal: req.IsExternal,
    		Method: req.Method, Sort: req.Sort, Status: int32PtrToInt(req.Status), Description: req.Description,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.PermissionResp{{ "{" }}Permission: toV1Permission(p){{ "}" }}, nil
    {{ "}" }}

    // DeletePermission implements the RBACService RPC method.
    func (s *RBACServiceImpl) DeletePermission(ctx context.Context, req *v1.DeletePermissionReq) (resp *v1.EmptyResp, err error) {{ "{" }}
    	if err := s.permission.Delete(ctx, req.Id); err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.EmptyResp{{ "{" }}{{ "}" }}, nil
    {{ "}" }}

    // GetPermission implements the RBACService RPC method.
    func (s *RBACServiceImpl) GetPermission(ctx context.Context, req *v1.GetPermissionReq) (resp *v1.PermissionResp, err error) {{ "{" }}
    	p, err := s.permission.Get(ctx, req.Id)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.PermissionResp{{ "{" }}Permission: toV1Permission(p){{ "}" }}, nil
    {{ "}" }}

    // ListPermissions implements the RBACService RPC method.
    func (s *RBACServiceImpl) ListPermissions(ctx context.Context, req *v1.ListPermissionsReq) (resp *v1.ListPermissionsResp, err error) {{ "{" }}
    	filter := permsvc.ListPermissionsFilter{{ "{" }}Page: req.Page, PageSize: req.PageSize, Status: -1, ParentID: ""{{ "}" }}
    	if req.Type != nil {{ "{" }}
    		filter.Type = *req.Type
    	{{ "}" }}
    	if req.ParentId != nil {{ "{" }}
    		filter.ParentID = *req.ParentId
    	{{ "}" }}
    	if req.Status != nil {{ "{" }}
    		filter.Status = int(*req.Status)
    	{{ "}" }}
    	perms, total, err := s.permission.List(ctx, filter)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	out := make([]*v1.Permission, 0, len(perms))
    	for _, p := range perms {{ "{" }}
    		out = append(out, toV1Permission(p))
    	{{ "}" }}
    	return &v1.ListPermissionsResp{{ "{" }}Permissions: out, Total: total{{ "}" }}, nil
    {{ "}" }}

    // ListMenus implements the RBACService RPC method.
    func (s *RBACServiceImpl) ListMenus(ctx context.Context, req *v1.ListMenusReq) (resp *v1.ListMenusResp, err error) {{ "{" }}
    	menus, err := s.menuQuery.ListMenus(ctx)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	out := make([]*v1.Menu, 0, len(menus))
    	for _, m := range menus {{ "{" }}
    		out = append(out, toV1Menu(m))
    	{{ "}" }}
    	return &v1.ListMenusResp{{ "{" }}Menus: out{{ "}" }}, nil
    {{ "}" }}

    // AssignRolesToUser implements the RBACService RPC method.
    func (s *RBACServiceImpl) AssignRolesToUser(ctx context.Context, req *v1.AssignRolesToUserReq) (resp *v1.EmptyResp, err error) {{ "{" }}
    	if err := s.user.AssignRoles(ctx, req.UserId, req.RoleIds); err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.EmptyResp{{ "{" }}{{ "}" }}, nil
    {{ "}" }}

    // GrantPermissionsToRole implements the RBACService RPC method.
    func (s *RBACServiceImpl) GrantPermissionsToRole(ctx context.Context, req *v1.GrantPermissionsToRoleReq) (resp *v1.EmptyResp, err error) {{ "{" }}
    	if err := s.role.GrantPermissions(ctx, req.RoleId, req.PermissionCodes); err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.EmptyResp{{ "{" }}{{ "}" }}, nil
    {{ "}" }}

    // Enforce implements the RBACService RPC method.
    func (s *RBACServiceImpl) Enforce(ctx context.Context, req *v1.EnforceReq) (resp *v1.EnforceResp, err error) {{ "{" }}
    	allowed, err := s.rbac.Enforce(ctx, req.Uid, req.Obj, req.Act)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.EnforceResp{{ "{" }}Allowed: allowed{{ "}" }}, nil
    {{ "}" }}

    // GetUserMenuTree implements the RBACService RPC method.
    func (s *RBACServiceImpl) GetUserMenuTree(ctx context.Context, req *v1.GetUserMenuTreeReq) (resp *v1.GetUserMenuTreeResp, err error) {{ "{" }}
    	roots, err := s.menuQuery.UserMenuTree(ctx, req.Uid)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.GetUserMenuTreeResp{{ "{" }}Roots: toV1MenuNodes(roots){{ "}" }}, nil
    {{ "}" }}

    // GetUserPermCodes implements the RBACService RPC method.
    func (s *RBACServiceImpl) GetUserPermCodes(ctx context.Context, req *v1.GetUserPermCodesReq) (resp *v1.GetUserPermCodesResp, err error) {{ "{" }}
    	codes, err := s.menuQuery.UserPermCodes(ctx, req.Uid)
    	if err != nil {{ "{" }}
    		return nil, rpcerror.ToBizError(err)
    	{{ "}" }}
    	return &v1.GetUserPermCodesResp{{ "{" }}Codes: codes{{ "}" }}, nil
    {{ "}" }}

    func toV1User(u *user.User, roles []string) *v1.User {{ "{" }}
    	return &v1.User{{ "{" }}
    		Id: u.UUID, Username: u.Username, Status: int32(u.Status), Roles: roles,
    		Nickname: u.Nickname, Avatar: u.Avatar, Email: u.Email, Phone: u.Phone,
    	{{ "}" }}
    {{ "}" }}

    func toV1Role(r *role.Role, permCodes []string) *v1.Role {{ "{" }}
    	return &v1.Role{{ "{" }}
    		Id: strconv.FormatInt(r.ID, 10), Code: r.Code, Name: r.Name,
    		Status: int32(r.Status), Remark: r.Remark, Permissions: permCodes,
    	{{ "}" }}
    {{ "}" }}

    func toV1Permission(p *permission.Permission) *v1.Permission {{ "{" }}
    	vp := &v1.Permission{{ "{" }}
    		Id:          strconv.FormatInt(p.ID, 10),
    		Code:        p.Code,
    		Type:        p.Type,
    		Name:        p.Name,
    		ParentId:    formatParentID(p.ParentID),
    		Path:        p.Path,
    		Icon:        p.Icon,
    		RouteName:   p.RouteName,
    		Redirect:    p.Redirect,
    		Method:      p.Method,
    		Sort:        p.Sort,
    		Status:      int32(p.Status),
    		Description: p.Description,
    	{{ "}" }}
    	if p.KeepAlive != nil {{ "{" }}
    		vp.KeepAlive = *p.KeepAlive
    	{{ "}" }}
    	if p.HideInMenu != nil {{ "{" }}
    		vp.HideInMenu = *p.HideInMenu
    	{{ "}" }}
    	if p.IsExternal != nil {{ "{" }}
    		vp.IsExternal = *p.IsExternal
    	{{ "}" }}
    	return vp
    {{ "}" }}

    func toV1Menu(m *menu.Menu) *v1.Menu {{ "{" }}
    	vm := &v1.Menu{{ "{" }}
    		Id: strconv.FormatInt(m.ID, 10), Code: m.Code, Name: m.Name, ParentId: formatParentID(m.ParentID), Type: m.Type,
    		Path: m.Path, Icon: m.Icon, RouteName: m.RouteName, Redirect: m.Redirect,
    		Sort: m.Sort,
    	{{ "}" }}
    	if m.KeepAlive != nil {{ "{" }}
    		vm.KeepAlive = *m.KeepAlive
    	{{ "}" }}
    	if m.HideInMenu != nil {{ "{" }}
    		vm.HideInMenu = *m.HideInMenu
    	{{ "}" }}
    	if m.IsExternal != nil {{ "{" }}
    		vm.IsExternal = *m.IsExternal
    	{{ "}" }}
    	return vm
    {{ "}" }}

    func toV1MenuNodes(nodes []*menu.Node) []*v1.MenuNode {{ "{" }}
    	out := make([]*v1.MenuNode, 0, len(nodes))
    	for _, n := range nodes {{ "{" }}
    		out = append(out, &v1.MenuNode{{ "{" }}
    			Menu:     toV1Menu(n.Menu),
    			Children: toV1MenuNodes(n.Children),
    		{{ "}" }})
    	{{ "}" }}
    	return out
    {{ "}" }}

    // formatParentID renders an internal parent id as its external decimal
    // string, with 0 (root) rendered as the empty string.
    func formatParentID(id int64) string {{ "{" }}
    	if id == 0 {{ "{" }}
    		return ""
    	{{ "}" }}
    	return strconv.FormatInt(id, 10)
    {{ "}" }}

    func int32PtrToInt(v *int32) *int {{ "{" }}
    	if v == nil {{ "{" }}
    		return nil
    	{{ "}" }}
    	i := int(*v)
    	return &i
    {{ "}" }}
```

- [ ] **Step 3: 重新运行全量 e2e，确认通过**

```bash
bash /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates/rbac-kitex/test/e2e_test.sh
```

Expected: `全部必跑通过`（hermetic 基线的 `make sqlc`/`go build`/`go test` 全部 ok；postgres 变体若无 `pg_isready`/`POSTGRES_DSN` 则打印 `skipped:` 且不计入失败）。若 `ncgo`/`kitex`/`protoc`/`sqlc` 缺失，脚本整体打印 `skipped:` 并退出 0——此时改为跑 Task 1-6 里的 `go test ./internal/...`/`go build ./...` 命令确认同等程度的通过。

- [ ] **Step 4: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add rbac-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml
git commit -m "feat(rbac-kitex): handler renders UUID/decimal-string IDs from int64 domain fields"
```

---

### Task 8: admin-services-kitex — Schema + Migration + sqlc Query 改动

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml`
- Modify: `admin-services-kitex/kitex-template/migration_init.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml`

**Interfaces:** 与 Task 1 相同（`users`/`roles`/`permissions`/`user_roles`/`role_permissions` 表结构、`CreateUser`/`GetUserByUUID`/`ListPermissionsFiltered`/`ListPermissionsByRoleIDs` 查询），额外保留 admin 模板独有的 `rate_limit_rules` 表与查询（不受本次改动影响，原样保留）。

这个 Task 没有独立的 Go 单元测试，用 `make sqlc` 渲染验证。

- [ ] **Step 1: 重写 schema 文件**

编辑 `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml`，把 `body:` 整体替换为：

```yaml
# ncgo exported template — internal/db/schema/000001_admin.sql
path: internal/db/schema/000001_admin.sql
update_behavior:
    type: cover
body: |-
    -- =============================================
    -- RBAC tables (users, roles, permissions)
    -- =============================================

    CREATE TABLE users (
        id BIGSERIAL PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        nickname TEXT,
        avatar TEXT,
        email TEXT,
        phone TEXT,
        status INTEGER NOT NULL DEFAULT 1,  -- 1=enabled, 0=disabled
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE roles (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 1,
        remark TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE permissions (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('catalog','menu','button','api')),
        name TEXT NOT NULL,
        parent_id BIGINT REFERENCES permissions(id),  -- no ON DELETE CASCADE; app-layer cascade
        path TEXT,
        icon TEXT,
        route_name TEXT,
        redirect TEXT,
        keep_alive BOOLEAN,
        hide_in_menu BOOLEAN,
        is_external BOOLEAN,
        method TEXT CHECK (method IS NULL OR method IN ('GET','POST','PUT','DELETE')),
        sort INTEGER,
        status INTEGER NOT NULL DEFAULT 1,
        description TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (code, type)
    );

    CREATE INDEX idx_permissions_parent ON permissions(parent_id);
    CREATE INDEX idx_permissions_type ON permissions(type);

    CREATE TABLE user_roles (
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, role_id)
    );

    CREATE TABLE role_permissions (
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        permission_id BIGINT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
        PRIMARY KEY (role_id, permission_id)
    );

    CREATE TABLE casbin_rule (
        id BIGSERIAL PRIMARY KEY,
        ptype TEXT NOT NULL,
        v0 TEXT NOT NULL DEFAULT '',
        v1 TEXT NOT NULL DEFAULT '',
        v2 TEXT NOT NULL DEFAULT '',
        v3 TEXT NOT NULL DEFAULT '',
        v4 TEXT NOT NULL DEFAULT '',
        v5 TEXT NOT NULL DEFAULT '',
        UNIQUE (ptype, v0, v1, v2, v3, v4, v5)
    );

    CREATE TABLE audit_log (
        id BIGSERIAL PRIMARY KEY,
        actor_uid TEXT,
        action TEXT NOT NULL,
        target TEXT NOT NULL DEFAULT '',
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX idx_casbin_rule_policy ON casbin_rule(ptype, v0, v1, v2);

    -- =============================================
    -- Rate-limit rules table (rule-center)
    -- =============================================

    CREATE TABLE rate_limit_rules (
        id BIGSERIAL PRIMARY KEY,
        service TEXT NOT NULL,
        phase TEXT NOT NULL,
        method TEXT NOT NULL,
        match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'pattern')),
        path TEXT NOT NULL DEFAULT '*',
        path_pattern TEXT NOT NULL DEFAULT '*',
        app_key TEXT,  -- NULL means fallback rule (no app_key match)
        priority INTEGER NOT NULL DEFAULT 0,
        enabled BOOLEAN NOT NULL DEFAULT true,
        key_by TEXT[] NOT NULL DEFAULT ARRAY['ip']::TEXT[],
        strategy TEXT NOT NULL DEFAULT 'fixed_window' CHECK (strategy IN ('fixed_window', 'sliding_window', 'token_bucket')),
        window_seconds INTEGER NOT NULL DEFAULT 60,
        max_requests INTEGER NOT NULL DEFAULT 100,
        requests_per_second DOUBLE PRECISION NOT NULL DEFAULT 0,
        burst INTEGER NOT NULL DEFAULT 0,
        client_ttl_seconds INTEGER NOT NULL DEFAULT 300,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
```

- [ ] **Step 2: 重写 migration 文件**

编辑 `admin-services-kitex/kitex-template/migration_init.yaml`，把 `body:` 整体替换为：

```yaml
# ncgo exported template — internal/db/migrations/000001_init.sql
path: internal/db/migrations/000001_init.sql
update_behavior:
    type: cover
body: |-
    -- +goose Up

    -- =============================================
    -- RBAC tables (users, roles, permissions)
    -- =============================================

    CREATE TABLE users (
        id BIGSERIAL PRIMARY KEY,
        uuid TEXT NOT NULL UNIQUE,
        username TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        nickname TEXT,
        avatar TEXT,
        email TEXT,
        phone TEXT,
        status INTEGER NOT NULL DEFAULT 1,  -- 1=enabled, 0=disabled
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE roles (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 1,
        remark TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE permissions (
        id BIGSERIAL PRIMARY KEY,
        code TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('catalog','menu','button','api')),
        name TEXT NOT NULL,
        parent_id BIGINT REFERENCES permissions(id),  -- no ON DELETE CASCADE; app-layer cascade
        path TEXT,
        icon TEXT,
        route_name TEXT,
        redirect TEXT,
        keep_alive BOOLEAN,
        hide_in_menu BOOLEAN,
        is_external BOOLEAN,
        method TEXT CHECK (method IS NULL OR method IN ('GET','POST','PUT','DELETE')),
        sort INTEGER,
        status INTEGER NOT NULL DEFAULT 1,
        description TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (code, type)
    );

    CREATE INDEX idx_permissions_parent ON permissions(parent_id);
    CREATE INDEX idx_permissions_type ON permissions(type);

    CREATE TABLE user_roles (
        user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        PRIMARY KEY (user_id, role_id)
    );

    CREATE TABLE role_permissions (
        role_id BIGINT NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
        permission_id BIGINT NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
        PRIMARY KEY (role_id, permission_id)
    );

    CREATE TABLE casbin_rule (
        id BIGSERIAL PRIMARY KEY,
        ptype TEXT NOT NULL,
        v0 TEXT NOT NULL DEFAULT '',
        v1 TEXT NOT NULL DEFAULT '',
        v2 TEXT NOT NULL DEFAULT '',
        v3 TEXT NOT NULL DEFAULT '',
        v4 TEXT NOT NULL DEFAULT '',
        v5 TEXT NOT NULL DEFAULT '',
        UNIQUE (ptype, v0, v1, v2, v3, v4, v5)
    );

    CREATE TABLE audit_log (
        id BIGSERIAL PRIMARY KEY,
        actor_uid TEXT,
        action TEXT NOT NULL,
        target TEXT NOT NULL DEFAULT '',
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX idx_casbin_rule_policy ON casbin_rule(ptype, v0, v1, v2);

    -- =============================================
    -- Rate-limit rules table (rule-center)
    -- =============================================

    CREATE TABLE rate_limit_rules (
        id BIGSERIAL PRIMARY KEY,
        service TEXT NOT NULL,
        phase TEXT NOT NULL,
        method TEXT NOT NULL,
        match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'pattern')),
        path TEXT NOT NULL DEFAULT '*',
        path_pattern TEXT NOT NULL DEFAULT '*',
        app_key TEXT,  -- NULL means fallback rule (no app_key match)
        priority INTEGER NOT NULL DEFAULT 0,
        enabled BOOLEAN NOT NULL DEFAULT true,
        key_by TEXT[] NOT NULL DEFAULT ARRAY['ip']::TEXT[],
        strategy TEXT NOT NULL DEFAULT 'fixed_window' CHECK (strategy IN ('fixed_window', 'sliding_window', 'token_bucket')),
        window_seconds INTEGER NOT NULL DEFAULT 60,
        max_requests INTEGER NOT NULL DEFAULT 100,
        requests_per_second DOUBLE PRECISION NOT NULL DEFAULT 0,
        burst INTEGER NOT NULL DEFAULT 0,
        client_ttl_seconds INTEGER NOT NULL DEFAULT 300,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    -- Index for efficient rule lookups
    CREATE INDEX idx_rate_limit_rules_lookup ON rate_limit_rules (service, phase, method, match_kind, enabled, priority DESC);
    CREATE INDEX idx_rate_limit_rules_app_key ON rate_limit_rules (app_key) WHERE app_key IS NOT NULL;

    -- +goose Down
    DROP TABLE IF EXISTS rate_limit_rules;
    DROP TABLE IF EXISTS audit_log;
    DROP TABLE IF EXISTS casbin_rule;
    DROP TABLE IF EXISTS role_permissions;
    DROP TABLE IF EXISTS user_roles;
    DROP TABLE IF EXISTS permissions;
    DROP TABLE IF EXISTS roles;
    DROP TABLE IF EXISTS users;
```

- [ ] **Step 3: 重写 sqlc query 文件**

编辑 `admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml`，把 `body:` 整体替换为（RBAC 部分改动同 Task 1 Step 3；`rate_limit_rules`/`audit_log`/`casbin_rule` 相关查询原样保留不变）：

```yaml
# ncgo exported template — internal/db/query/admin.sql
path: internal/db/query/admin.sql
update_behavior:
    type: cover
body: |-
    -- =============================================
    -- User queries
    -- =============================================

    -- name: CreateUser :one
    INSERT INTO users (uuid, username, password_hash, nickname, avatar, email, phone, status)
    VALUES ($1, $2, $3, $4, $5, $6, $7, 1) RETURNING *;
    -- name: GetUserByID :one
    SELECT * FROM users WHERE id = $1;
    -- name: GetUserByUUID :one
    SELECT * FROM users WHERE uuid = $1;
    -- name: GetUserByUsername :one
    SELECT * FROM users WHERE username = $1;
    -- name: ListUsers :many
    SELECT * FROM users ORDER BY id LIMIT $1 OFFSET $2;
    -- name: CountUsers :one
    SELECT count(*) FROM users;
    -- name: UpdateUser :one
    UPDATE users SET
        username = COALESCE($2, username),
        nickname = COALESCE($3, nickname),
        avatar = COALESCE($4, avatar),
        email = COALESCE($5, email),
        phone = COALESCE($6, phone),
        status = COALESCE($7, status),
        updated_at = now()
    WHERE id = $1 RETURNING *;
    -- name: UpdateUserPassword :one
    UPDATE users SET password_hash = $1, updated_at = now() WHERE id = $2 RETURNING *;
    -- name: DeleteUser :exec
    DELETE FROM users WHERE id = $1;
    -- name: AddUserRole :exec
    INSERT INTO user_roles (user_id, role_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;
    -- name: RemoveUserRole :exec
    DELETE FROM user_roles WHERE user_id = $1 AND role_id = $2;
    -- name: ClearUserRoles :exec
    DELETE FROM user_roles WHERE user_id = $1;
    -- name: ListRolesByUserID :many
    SELECT r.* FROM roles r JOIN user_roles ur ON ur.role_id = r.id WHERE ur.user_id = $1 ORDER BY r.id;
    -- name: ListRoleIDsByUserID :many
    SELECT role_id FROM user_roles WHERE user_id = $1;

    -- =============================================
    -- Role queries
    -- =============================================

    -- name: CreateRole :one
    INSERT INTO roles (code, name, status, remark) VALUES ($1, $2, 1, $3) RETURNING *;
    -- name: GetRoleByID :one
    SELECT * FROM roles WHERE id = $1;
    -- name: GetRoleByCode :one
    SELECT * FROM roles WHERE code = $1;
    -- name: ListRoles :many
    SELECT * FROM roles ORDER BY id LIMIT $1 OFFSET $2;
    -- name: CountRoles :one
    SELECT count(*) FROM roles;
    -- name: UpdateRole :one
    UPDATE roles SET
        name = COALESCE($2, name),
        status = COALESCE($3, status),
        remark = COALESCE($4, remark),
        updated_at = now()
    WHERE id = $1 RETURNING *;
    -- name: DeleteRole :exec
    DELETE FROM roles WHERE id = $1;
    -- name: AddRolePermission :exec
    INSERT INTO role_permissions (role_id, permission_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;
    -- name: RemoveRolePermission :exec
    DELETE FROM role_permissions WHERE role_id = $1 AND permission_id = $2;
    -- name: ClearRolePermissions :exec
    DELETE FROM role_permissions WHERE role_id = $1;
    -- name: ListPermissionCodesByRoleID :many
    SELECT p.code FROM permissions p
    JOIN role_permissions rp ON rp.permission_id = p.id
    WHERE rp.role_id = $1
    ORDER BY p.code;
    -- name: ListPermissionIDsByCodes :many
    SELECT id, code FROM permissions WHERE code = ANY($1::text[]);
    -- name: ListPermissionsByRoleIDs :many
    SELECT DISTINCT p.* FROM permissions p JOIN role_permissions rp ON rp.permission_id = p.id WHERE rp.role_id = ANY($1::bigint[]) ORDER BY p.id;

    -- =============================================
    -- Permission queries
    -- =============================================

    -- name: CreatePermission :one
    INSERT INTO permissions (code, type, name, parent_id, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, method, sort, status, description)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15) RETURNING *;

    -- name: GetPermissionByID :one
    SELECT * FROM permissions WHERE id = $1;

    -- name: GetPermissionByCode :many
    SELECT * FROM permissions WHERE code = $1 ORDER BY type;

    -- name: GetPermissionByCodeAndType :one
    SELECT * FROM permissions WHERE code = $1 AND type = $2;

    -- name: ListPermissions :many
    SELECT * FROM permissions ORDER BY sort NULLS LAST, id LIMIT $1 OFFSET $2;
    -- name: CountPermissions :one
    SELECT count(*) FROM permissions;

    -- name: ListPermissionsFiltered :many
    SELECT * FROM permissions
    WHERE ($1 = '' OR type = $1)
      AND ($2::bigint = 0 OR parent_id = $2::bigint)
      AND ($3 < 0 OR status = $3)
    ORDER BY sort NULLS LAST, id
    LIMIT $4 OFFSET $5;

    -- name: ListPermissionsByCodes :many
    SELECT * FROM permissions WHERE code = ANY($1::text[]) ORDER BY code, type;

    -- name: UpdatePermission :one
    UPDATE permissions SET
        code = COALESCE($2, code),
        type = COALESCE($3, type),
        name = COALESCE($4, name),
        parent_id = COALESCE($5, parent_id),
        path = COALESCE($6, path),
        icon = COALESCE($7, icon),
        route_name = COALESCE($8, route_name),
        redirect = COALESCE($9, redirect),
        keep_alive = COALESCE($10, keep_alive),
        hide_in_menu = COALESCE($11, hide_in_menu),
        is_external = COALESCE($12, is_external),
        method = COALESCE($13, method),
        sort = COALESCE($14, sort),
        status = COALESCE($15, status),
        description = COALESCE($16, description),
        updated_at = now()
    WHERE id = $1 RETURNING *;

    -- name: DeletePermission :exec
    DELETE FROM permissions WHERE id = $1;

    -- name: ListChildPermissionIDs :many
    SELECT id FROM permissions WHERE parent_id = $1;

    -- =============================================
    -- Menu read-only queries (view over permissions WHERE type IN ('catalog','menu'))
    -- =============================================

    -- name: ListMenusAsTree :many
    SELECT id, code, name, parent_id, type, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, sort
    FROM permissions
    WHERE type IN ('catalog', 'menu') AND status = 1
    ORDER BY sort NULLS LAST, id;

    -- name: ListMenusByParentID :many
    SELECT id, code, name, parent_id, type, path, icon, route_name, redirect, keep_alive, hide_in_menu, is_external, sort
    FROM permissions
    WHERE type IN ('catalog', 'menu') AND status = 1 AND parent_id = $1
    ORDER BY sort NULLS LAST, id;

    -- =============================================
    -- Casbin rule queries
    -- =============================================

    -- name: ListCasbinRules :many
    SELECT ptype, v0, v1, v2, v3, v4, v5 FROM casbin_rule ORDER BY id;
    -- name: InsertCasbinRule :one
    INSERT INTO casbin_rule (ptype, v0, v1, v2, v3, v4, v5) VALUES ($1, $2, $3, $4, $5, $6, $7) ON CONFLICT (ptype, v0, v1, v2, v3, v4, v5) DO NOTHING RETURNING id;
    -- name: DeleteCasbinRule :exec
    DELETE FROM casbin_rule WHERE ptype = $1 AND v0 = $2 AND v1 = $3 AND v2 = $4 AND v3 = $5 AND v4 = $6 AND v5 = $7;
    -- name: ClearCasbinRules :exec
    DELETE FROM casbin_rule;
    -- name: DeleteCasbinRuleFiltered :exec
    DELETE FROM casbin_rule WHERE ptype = $1
      AND ($2 = '' OR v0 = $2) AND ($3 = '' OR v1 = $3) AND ($4 = '' OR v2 = $4)
      AND ($5 = '' OR v3 = $5) AND ($6 = '' OR v4 = $6) AND ($7 = '' OR v5 = $7);
    -- name: CountCasbinRules :one
    SELECT count(*) FROM casbin_rule;

    -- =============================================
    -- Audit log queries
    -- =============================================

    -- name: InsertAuditLog :one
    INSERT INTO audit_log (actor_uid, action, target, detail_json) VALUES ($1, $2, $3, $4) RETURNING id;

    -- =============================================
    -- Rate-limit rule queries
    -- =============================================

    -- name: GetRateLimitExactRuleByAppKey :one
    SELECT * FROM rate_limit_rules
    WHERE service = $1 AND phase = $2 AND method = $3 AND match_kind = 'exact' AND (path = $4 OR path = '*') AND app_key = $5 AND enabled = true
    ORDER BY priority DESC, id DESC
    LIMIT 1;

    -- name: GetRateLimitExactRuleFallback :one
    SELECT * FROM rate_limit_rules
    WHERE service = $1 AND phase = $2 AND method = $3 AND match_kind = 'exact' AND (path = $4 OR path = '*') AND app_key IS NULL AND enabled = true
    ORDER BY priority DESC, id DESC
    LIMIT 1;

    -- name: GetRateLimitPatternRuleByAppKey :many
    SELECT * FROM rate_limit_rules
    WHERE service = $1 AND phase = $2 AND method = $3 AND app_key = $4 AND enabled = true AND (path_pattern = '*' OR path = $5)
    ORDER BY priority DESC, id DESC;

    -- name: GetRateLimitPatternRuleFallback :many
    SELECT * FROM rate_limit_rules
    WHERE service = $1 AND phase = $2 AND method = $3 AND app_key IS NULL AND enabled = true AND (path_pattern = '*' OR path = $4)
    ORDER BY priority DESC, id DESC;

    -- name: CreateRateLimitRule :one
    INSERT INTO rate_limit_rules (
        service, phase, method, match_kind, path, path_pattern, app_key,
        priority, enabled, key_by, strategy, window_seconds, max_requests,
        requests_per_second, burst, client_ttl_seconds
    ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16
    ) RETURNING id;

    -- name: UpdateRateLimitRule :exec
    UPDATE rate_limit_rules SET
        enabled = COALESCE(sqlc.narg('enabled'), enabled),
        priority = COALESCE(sqlc.narg('priority'), priority),
        strategy = COALESCE(sqlc.narg('strategy'), strategy),
        window_seconds = COALESCE(sqlc.narg('window_seconds'), window_seconds),
        max_requests = COALESCE(sqlc.narg('max_requests'), max_requests),
        requests_per_second = COALESCE(sqlc.narg('requests_per_second'), requests_per_second),
        burst = COALESCE(sqlc.narg('burst'), burst),
        client_ttl_seconds = COALESCE(sqlc.narg('client_ttl_seconds'), client_ttl_seconds),
        key_by = COALESCE(sqlc.narg('key_by'), key_by),
        updated_at = now()
    WHERE id = $1;

    -- name: DeleteRateLimitRule :exec
    DELETE FROM rate_limit_rules WHERE id = $1;

    -- name: ListRateLimitRules :many
    SELECT * FROM rate_limit_rules
    WHERE (sqlc.narg('service')::text IS NULL OR service = sqlc.narg('service')::text)
      AND (sqlc.narg('phase')::text IS NULL OR phase = sqlc.narg('phase')::text)
    ORDER BY priority DESC, id DESC
    LIMIT sqlc.arg('limit') OFFSET sqlc.arg('offset');

    -- name: CountRateLimitRules :one
    SELECT count(*) FROM rate_limit_rules
    WHERE (sqlc.narg('service')::text IS NULL OR service = sqlc.narg('service')::text)
      AND (sqlc.narg('phase')::text IS NULL OR phase = sqlc.narg('phase')::text);
```

- [ ] **Step 4: 渲染验证 sqlc 生成成功**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc
```

Expected: 同 Task 1 Step 4。若工具缺失打印 `skipped:` 并跳过。

- [ ] **Step 5: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml admin-services-kitex/kitex-template/migration_init.yaml admin-services-kitex/kitex-template/internal_db_query_admin_sql.yaml
git commit -m "feat(admin-services-kitex): revert users/roles/permissions PK to BIGSERIAL, add users.uuid"
```

---

### Task 9: admin-services-kitex — Domain 实体 + Repository 接口 + Domain 单测

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_domain_user_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_role_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_permission_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_menu_entity_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_user_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_role_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_permission_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_menu_repository_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml`

**Interfaces:** 与 Task 2 完全相同（`admin-services-kitex` 的这 10 个文件与 `rbac-kitex` 对应文件逐字节相同，已在调研阶段用 `diff` 核实）。

这一 Task 的测试同样用渲染后 `go test ./internal/domain/...` 验证。

- [ ] **Step 1: 写/改失败测试 —— permission entity_test.go**

编辑 `admin-services-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml`，把 `body:` 替换为与 Task 2 Step 1 完全相同的内容（`path: internal/domain/permission/entity_test.go`，同一份 Go 源码，所有 `New(...)` 调用第 4 个参数从 `""` 改成 `0`）。

- [ ] **Step 2: 写/改失败测试 —— menu entity_test.go**

编辑 `admin-services-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml`，把 `body:` 替换为与 Task 2 Step 2 完全相同的内容（`path: internal/domain/menu/entity_test.go`，`ID`/`ParentID` 全部用 int64 字面量）。

- [ ] **Step 3: 运行测试，确认失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && go test ./internal/domain/...
```

Expected: FAIL，原因同 Task 2 Step 3。

- [ ] **Step 4: 实现 domain 实体改动 —— user/role/permission/menu entity**

依次编辑以下 4 个文件，`body:` 分别替换为与 Task 2 Step 4/5/6/7 完全相同的内容（仅 `path:` 字段一致地保持各自原值 `internal/domain/user/entity.go`/`internal/domain/role/entity.go`/`internal/domain/permission/entity.go`/`internal/domain/menu/entity.go`，Go 源码逐字节相同）：
- `admin-services-kitex/kitex-template/internal_domain_user_entity_go.yaml`
- `admin-services-kitex/kitex-template/internal_domain_role_entity_go.yaml`
- `admin-services-kitex/kitex-template/internal_domain_permission_entity_go.yaml`
- `admin-services-kitex/kitex-template/internal_domain_menu_entity_go.yaml`

- [ ] **Step 5: 实现 repository 接口改动 —— user/role/permission/menu**

依次编辑以下 4 个文件，`body:` 分别替换为与 Task 2 Step 8 完全相同的内容：
- `admin-services-kitex/kitex-template/internal_domain_user_repository_go.yaml`
- `admin-services-kitex/kitex-template/internal_domain_role_repository_go.yaml`
- `admin-services-kitex/kitex-template/internal_domain_permission_repository_go.yaml`
- `admin-services-kitex/kitex-template/internal_domain_menu_repository_go.yaml`

- [ ] **Step 6: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && go test ./internal/domain/...
```

Expected: PASS。

- [ ] **Step 7: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_domain_user_entity_go.yaml admin-services-kitex/kitex-template/internal_domain_role_entity_go.yaml admin-services-kitex/kitex-template/internal_domain_permission_entity_go.yaml admin-services-kitex/kitex-template/internal_domain_menu_entity_go.yaml admin-services-kitex/kitex-template/internal_domain_user_repository_go.yaml admin-services-kitex/kitex-template/internal_domain_role_repository_go.yaml admin-services-kitex/kitex-template/internal_domain_permission_repository_go.yaml admin-services-kitex/kitex-template/internal_domain_menu_repository_go.yaml admin-services-kitex/kitex-template/internal_domain_permission_entity_test_go.yaml admin-services-kitex/kitex-template/internal_domain_menu_entity_test_go.yaml
git commit -m "feat(admin-services-kitex): switch domain entities/repository interfaces to int64 IDs + user.UUID"
```

---

### Task 10: admin-services-kitex — User Repository 实现（uuid.NewV7 + GetByUUID）

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_repository_user_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`

**Interfaces:** 与 Task 3 完全相同（两个模板此文件逐字节相同，已用 `diff` 核实）。

- [ ] **Step 1: 改测试**

编辑 `admin-services-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`，把 `body:` 替换为与 Task 3 Step 1 完全相同的 Go 源码（`path: internal/repository/user/repo_test.go`，`package userrepo`，`TestUserRepoPostgresRoundTrip` 用 `created.ID == 0`/`created.UUID == ""`/`repo.GetByUUID` 断言）。

- [ ] **Step 2: 运行测试，确认失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/repository/user/...
```

Expected: FAIL，原因同 Task 3 Step 2。

- [ ] **Step 3: 实现**

编辑 `admin-services-kitex/kitex-template/internal_repository_user_repo_go.yaml`，把 `body:` 替换为与 Task 3 Step 3 完全相同的 Go 源码（`path: internal/repository/user/repo.go`，含 `import "github.com/google/uuid"`、`Save` 生成 `uuid.NewV7()`、新增 `GetByUUID`、`AssignRoles`/`ListRoles`/`ListRoleIDs` 均为 int64）。

- [ ] **Step 4: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go build ./internal/repository/... && go test ./internal/repository/user/...
```

Expected: PASS 或按 gate 规则显式 SKIP（同 Task 3 Step 4）。

- [ ] **Step 5: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_repository_user_repo_go.yaml admin-services-kitex/kitex-template/internal_repository_user_repo_test_go.yaml
git commit -m "feat(admin-services-kitex): user repo generates UUID v7 on Save, adds GetByUUID"
```

---

### Task 11: admin-services-kitex — Role/Permission/Menu Repository 实现

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_repository_role_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_permission_repo_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_repository_menu_repo_go.yaml`

**Interfaces:** 与 Task 4 完全相同（三个文件在两个模板间逐字节相同，已用 `diff` 核实）。

- [ ] **Step 1: 运行 build，确认失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go build ./internal/repository/...
```

Expected: FAIL，原因同 Task 4 Step 1。

- [ ] **Step 2: 实现 —— role repo.go**

编辑 `admin-services-kitex/kitex-template/internal_repository_role_repo_go.yaml`，把 `body:` 替换为与 Task 4 Step 2 完全相同的 Go 源码（`path: internal/repository/role/repo.go`）。

- [ ] **Step 3: 实现 —— permission repo.go**

编辑 `admin-services-kitex/kitex-template/internal_repository_permission_repo_go.yaml`，把 `body:` 替换为与 Task 4 Step 3 完全相同的 Go 源码（`path: internal/repository/permission/repo.go`）。

- [ ] **Step 4: 实现 —— menu repo.go**

编辑 `admin-services-kitex/kitex-template/internal_repository_menu_repo_go.yaml`，把 `body:` 替换为与 Task 4 Step 4 完全相同的 Go 源码（`path: internal/repository/menu/repo.go`）。

- [ ] **Step 5: 重新运行 build，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go build ./internal/repository/...
```

Expected: PASS。

- [ ] **Step 6: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_repository_role_repo_go.yaml admin-services-kitex/kitex-template/internal_repository_permission_repo_go.yaml admin-services-kitex/kitex-template/internal_repository_menu_repo_go.yaml
git commit -m "feat(admin-services-kitex): switch role/permission/menu repositories to int64 IDs"
```

---

### Task 12: admin-services-kitex — User Application Service（UUID 边界转换）+ 测试

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`

**Interfaces:** 与 Task 5 完全相同。`internal_application_user_user_service_go.yaml` 两个模板逐字节相同；`internal_application_user_user_service_test_go.yaml` 原文件有一处已知无关差异（`t.Fatal` 的消息原文分别是 `"created user has empty id"` / `"created user has id 0"`），本 Task 用与 Task 5 相同的统一文案 `"created user has empty uuid"` 覆盖两边，不再保留这个历史差异。

- [ ] **Step 1: 改测试**

编辑 `admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`，把 `body:` 替换为与 Task 5 Step 1 完全相同的 Go 源码（`path: internal/application/user/user_service_test.go`，`fakeUserRepo` 用 `map[int64]*user.User` + `byUUID map[string]int64`，`TestAssignRolesSyncsCasbin` 用 `created.UUID` 调用 `AssignRoles`/`Enforce`）。

- [ ] **Step 2: 运行测试，确认失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/user/...
```

Expected: FAIL，原因同 Task 5 Step 2。

- [ ] **Step 3: 实现**

编辑 `admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml`，把 `body:` 替换为与 Task 5 Step 3 完全相同的 Go 源码（`path: internal/application/user/user_service.go`，`UserRepo` 接口全部 int64/`GetByUUID`，`Service.Update`/`Delete`/`Get`/`GetRoleCodes`/`AssignRoles` 外部签名保持 string，内部 `GetByUUID`/`strconv.ParseInt` 解析）。

- [ ] **Step 4: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/user/...
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_application_user_user_service_go.yaml admin-services-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "feat(admin-services-kitex): user service resolves external UUID to internal int64 ID"
```

---

### Task 13: admin-services-kitex — Role/Permission Application Service + Menu Query Service

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml`
- Modify: `admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml`

**Interfaces:** 与 Task 6 完全相同（六个文件在两个模板间逐字节相同，已用 `diff` 核实）。

- [ ] **Step 1: 改测试 —— role_service_test.go**

编辑 `admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml`，把 `body:` 替换为与 Task 6 Step 1 完全相同的 Go 源码（`path: internal/application/role/role_service_test.go`，`fakeRoleRepo` 用 `map[int64]*role.Role`，新增 `TestUpdateRejectsNonIntegerID`）。

- [ ] **Step 2: 改测试 —— permission_service_test.go**

编辑 `admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml`，把 `body:` 替换为与 Task 6 Step 2 完全相同的 Go 源码（`path: internal/application/permission/permission_service_test.go`，`fakePermRepo` 用 `map[int64]*permission.Permission`，`Update`/`Delete`/`Get` 调用用 `fmt.Sprint(p.ID)`，新增 `TestCreateRejectsNonIntegerParentID`）。

- [ ] **Step 3: 改测试 —— menu_query_service_test.go**

编辑 `admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml`，把 `body:` 替换为与 Task 6 Step 3 完全相同的 Go 源码（`path: internal/application/menu/menu_query_service_test.go`，`fakeUserRoleReader` 新增 `GetByUUID`，`ListRoles`/`fakePermReader.ListByRoleIDs` 改用 `int64`）。

- [ ] **Step 4: 运行测试，确认失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/role/... ./internal/application/permission/... ./internal/application/menu/...
```

Expected: FAIL，原因同 Task 6 Step 4。

- [ ] **Step 5: 实现 —— role_service.go**

编辑 `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml`，把 `body:` 替换为与 Task 6 Step 5 完全相同的 Go 源码（`path: internal/application/role/role_service.go`）。

- [ ] **Step 6: 实现 —— permission_service.go**

编辑 `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml`，把 `body:` 替换为与 Task 6 Step 6 完全相同的 Go 源码（`path: internal/application/permission/permission_service.go`）。

- [ ] **Step 7: 实现 —— menu_query_service.go**

编辑 `admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml`，把 `body:` 替换为与 Task 6 Step 7 完全相同的 Go 源码（`path: internal/application/menu/menu_query_service.go`）。

- [ ] **Step 8: 重新运行测试，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/tplcheck" --no-auto-steps
cd "$DIR/tplcheck" && make sqlc && go test ./internal/application/...
```

Expected: PASS。

- [ ] **Step 9: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml admin-services-kitex/kitex-template/internal_application_role_role_service_test_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml admin-services-kitex/kitex-template/internal_application_permission_permission_service_test_go.yaml admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_go.yaml admin-services-kitex/kitex-template/internal_application_menu_menu_query_service_test_go.yaml
git commit -m "feat(admin-services-kitex): role/permission services and menu query service resolve external string IDs to int64"
```

---

### Task 14: admin-services-kitex — Handler 输出转换（strconv/UUID）+ 全量验收

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml`

**Interfaces:** 与 Task 7 完全相同，唯一差异是 proto import 路径：`v1 "{{.Module}}/kitex_gen/api/admin/v1"`（而不是 rbac-kitex 的 `api/rbac/v1`）——这是两个模板本来就有的既存差异，不是本次改动引入的。

`admin-services-kitex` 没有 `test/e2e_test.sh`（只有 `rbac-kitex` 有），因此本 Task 的全量验收改用手动渲染 + `go build ./...` + `go test ./...`。

- [ ] **Step 1: 运行全量 build+test，确认失败**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new admintplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/admintplcheck" --no-auto-steps
cd "$DIR/admintplcheck" && make sqlc && go build ./...
```

Expected: FAIL，原因同 Task 7 Step 1（`toV1User`/`toV1Role`/`toV1Permission`/`toV1Menu` 类型不匹配，`GetRoleCodes(ctx, u.ID)` 参数类型不匹配）。若 `ncgo`/`kitex`/`protoc`/`sqlc` 缺失则手动确认工具链后跳过，不代表通过。

- [ ] **Step 2: 实现**

编辑 `admin-services-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml`，把 `body:` 替换为与 Task 7 Step 2 完全相同的 Go 源码，仅把 import 块中的

```go
v1 "{{.Module}}/kitex_gen/api/rbac/v1"
```

替换成

```go
v1 "{{.Module}}/kitex_gen/api/admin/v1"
```

其余内容（`import "strconv"`、四处 `GetRoleCodes(ctx, u.UUID)`、`toV1User`/`toV1Role`/`toV1Permission`/`toV1Menu`/`formatParentID` 的实现）逐字节相同。

- [ ] **Step 3: 重新运行全量 build+test，确认通过**

```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new admintplcheck --module example.com/admin-e2e --kind kitex --template-dir "$REPO_ROOT/admin-services-kitex" --dir "$DIR/admintplcheck" --no-auto-steps
cd "$DIR/admintplcheck" && make sqlc && go build ./... && go test ./...
```

Expected: `go build`/`go test` 全部 PASS（postgres 相关测试按现有 gate 规则打印 SKIP 不算失败）。

- [ ] **Step 4: Commit**

```bash
cd /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates
git add admin-services-kitex/kitex-template/internal_handler_rbacservice_handler_go.yaml
git commit -m "feat(admin-services-kitex): handler renders UUID/decimal-string IDs from int64 domain fields"
```

---

## Self-Review

**Spec coverage：**
- A. Schema 改动 → Task 1、8（`users`/`roles`/`permissions`/`user_roles`/`role_permissions` 全部改回 `BIGSERIAL`/`BIGINT`，`users.uuid` 新增，`casbin_rule`/`audit_log`/`rate_limit_rules` 不变）——覆盖。
- B. ID 生成与领域模型 → Task 2/9（`domain.User.UUID`/`Role.ID`/`Permission.ID` int64 化）、Task 3/10（`uuid.NewV7()` 在 `Save()` 生成）——覆盖。
- C. Repository/Handler 边界转换 → Task 2/9（接口签名）、Task 3/4/10/11（repository 实现）、Task 5/6/12/13（application service 内部 `GetByUUID`/`strconv` 转换，DTO 契约不变）、Task 7/14（handler 的 `toV1*` 辅助函数与 `GetRoleCodes` 调用点同步）——覆盖，且发现并修正了设计文档未明确提及、但类型改动后编译必然要求的 handler 辅助函数改动（已在 Task 7/14 的 Interfaces 段落里写明理由）。
- D. Auth/Casbin 身份标识 → Global Constraints 明确声明 `internal/infrastructure/auth/jwt.go`、`internal/infrastructure/casbin/adapter.go`、`internal/infrastructure/casbin/enforcer.go` 不在任何 Task 的 Files 列表里，且 Task 5/12、Task 6/13 的 Service 实现里 Casbin 调用全部使用原始 UUID 字符串或 role.Code，从未使用内部 int64 ID——覆盖。
- E. 测试策略 → 每个改行为的 Task 都遵循"改测试→跑测试确认失败→改实现→跑测试确认通过→commit"的 TDD 顺序；Task 3/10 保留了已有的 postgres-gated round-trip 测试且未新增真实 DB 断言——覆盖。
- F. 影响范围 → Global Constraints 与各 Task 的 Files 列表合计覆盖了设计文档列出的全部文件类别（schema/migration/query/repository ×3/domain repository 接口 ×4/domain 实体/application service ×3 + menu query service/DTO 说明为何不改/测试文件），额外识别出设计文档未列出但确实需要改的 `internal_domain_menu_entity_go.yaml`/`internal_domain_menu_repository_go.yaml`/`internal_repository_menu_repo_go.yaml`/`internal_domain_menu_entity_test_go.yaml`/`internal_application_menu_menu_query_service_go.yaml`/`internal_application_menu_menu_query_service_test_go.yaml`/`internal_handler_rbacservice_handler_go.yaml`（Task 2/6/7 与 Task 9/13/14），已在对应 Task 的 Interfaces 段落说明依据。

**占位符扫描：** 未发现 "TBD"/"实现类似逻辑"/"补充测试" 等空洞描述。Task 9-14（admin-services-kitex 对称任务）采用"把 body 替换为与 Task N Step M 完全相同的 Go 源码"的表述而非重复粘贴整段代码——这是因为已用 `diff` 逐一核实这些文件在两个模板间逐字节相同（Task 3/6/7 的实现文件、多数 Task 2 的 domain 文件），指向的是真实存在、已在本文档中完整写出的代码块，不是"自行发挥"的占位符；Task 12/14 额外用文字说明了与对应 rbac-kitex Task 之间**仅有**的字面差异（`user_service_test.go` 的 Fatal 消息统一措辞、`handler.go` 的 proto import 路径），确保执行者不会遗漏这些差异点。

**类型一致性：** 已核对 `user.User.ID`（`int64`）/`UUID`（`string`）、`role.Role.ID`（`int64`）、`permission.Permission.ID`/`ParentID`（`int64`）、`menu.Menu.ID`/`ParentID`（`int64`）在 Task 2/9（定义）与 Task 3-7/10-14（消费）之间的方法签名前后一致；`usersvc.UserRepo`/`rolesvc.RoleRepo`/`permsvc.PermRepo`/`menusvc.UserRoleReader`/`PermReader` 接口方法签名与对应 fake（测试）实现、真实 repo 实现三者的方法名、参数类型、返回值类型逐一核对一致（例如 `ListRoles(ctx, uid int64) ([]*role.Role, error)` 在 `userrepo.Repo`、`usersvc.UserRepo`、`fakeUserRepo`、`menusvc.UserRoleReader` 四处的签名相同）。未发现类型不一致问题，无需修正。

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-07-rbac-id-scheme-revert.md`. Two execution options:

1. **Subagent-Driven (recommended)** - dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** - execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
