# rbac-kitex / admin-services-kitex：ID 方案回退为 int64 自增 + users 增加对外 UUID（设计）

对应 Issue #46（范围已重新定义，见下方"范围变化说明"），并将一并关闭 Issue #38。

## 背景

PR #36（"refactor(rbac): sync templates to s-web alignment decisions (string ID +
ValidateToken)"）把 `rbac-kitex` 的 `users`/`roles`/`permissions` 主键从
`int64`/`BIGSERIAL` 迁移为 `string`（意图为 UUID），并同步到
`admin-services-kitex`。但这次迁移只改了 Go 类型层，DB schema/migration 的
`id` 列既没有 `DEFAULT` 表达式，写入语句也不显式传 `id` 值——导致真实
INSERT 会因主键 NOT NULL 约束违反而失败（Issue #38、#46 分别在两个仓库场景下
报告了同一根因）。

## 范围变化说明

Issue #46 的评论进一步提出：与其把 UUID 生成机制补齐（继续走 string 主键路线），
不如评估"UUID v4 随机写入导致 B-tree 索引碎片化，写入性能劣于自增整数"的问题，
建议改用时间有序的 UUID v7。

经过与用户逐项确认（brainstorming 会话记录），最终方向从"补完 string 主键的
UUID 生成机制"升级为**反向重构**：

- `users`/`roles`/`permissions` 主键**改回 `BIGSERIAL` 自增整数**（恢复 PR #36
  之前的方案），而不是继续在 string 主键上补 UUID 生成逻辑。
- `users` 表单独新增一个 **`uuid TEXT UNIQUE` 列**，作为对外标识（RPC/DTO 暴露
  给调用方的 `id` 字段值），由应用层生成 UUID v7（`github.com/google/uuid`
  `NewV7()`），不使用 PostgreSQL 原生 `gen_random_uuid()`（那是 v4）。
- `roles`/`permissions` 不新增 UUID 列，对外 `id` 字段就是内部自增 ID 的十进制
  字符串形式（`strconv` 纯格式转换，无需额外查库）。

这个方向与 s-web/`ncgo` 仓库 Issue #75 / PR #76 锁定的"string ID"对齐决策不再
完全一致（`roles`/`permissions` 对外仍是 string，但语义从"UUID"变成"自增ID的
字符串形式"；`users` 对外仍是 UUID 字符串，形式不变，仅内部实现变化）。用户已
明确确认**本仓库范围内直接实施，不等待跨仓库协调**（详见会话记录）。

## 目标

1. `users`/`roles`/`permissions` 三张表的 INSERT 在真实 Postgres 上能够成功
   写入，不再依赖"字符串主键但无生成机制"的错误状态。
2. `users` 表获得一个稳定、不可预测、不泄露注册顺序信息的对外标识（UUID
   v7），同时保留自增主键在 JOIN/索引上的性能优势。
3. `roles`/`permissions` 恢复自增主键的简单性和索引效率，对外 ID 语义从
   "UUID" 改为"整数的字符串形式"。
4. `rbac-kitex` 与 `admin-services-kitex` 两个模板保持对称实现（各自独立文件，
   不做去重，去重是 Issue #43 的范围）。
5. JWT/Casbin 身份标识、DTO/proto 对外字段类型均保持现状不变（`string`），把
   int64↔UUID 的转换完全封闭在 repository 与 application service 内部，
   handler/DTO/proto 契约零改动。

## 非目标

- 不处理 Issue #43（模板内重复声明同路径 yaml 文件）——本次改动会在已存在的
  重复文件里各自应用一份，不做合并去重。
- 不实现真实 Postgres 集成测试（超出本次范围，Issue 中建议的"渲染 + 真实
  INSERT 校验"留待后续单独跟踪）。
- 不修改 `casbin_rule`、`audit_log`、`rate_limit_rules`（已是 `BIGSERIAL`，
  不受影响）。
- 不引入雪花算法（Snowflake）——已评估，因其需要机器号协调机制，与"模板可能
  被部署为任意副本数"的场景不匹配，成本高于收益。
- 不跨仓库同步修改 `ncgo` 仓库的 s-web 对齐锁定决策文档（用户已确认无需协调，
  直接改本仓库）。

## 设计详情

### A. Schema 改动

`rbac-kitex/kitex-template/internal_db_schema_000001_rbac_sql.yaml`、
`rbac-kitex/kitex-template/migration_init.yaml`、
`admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml`、
`admin-services-kitex/kitex-template/migration_init.yaml` 四个文件同步修改：

```sql
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,              -- 改回自增，内部使用（JOIN/外键）
    uuid TEXT NOT NULL UNIQUE,             -- 新增：对外标识，应用层生成 UUID v7
    username TEXT NOT NULL UNIQUE,
    ...                                     -- 其余列不变
);

CREATE TABLE roles (
    id BIGSERIAL PRIMARY KEY,              -- 改回自增
    ...
);

CREATE TABLE permissions (
    id BIGSERIAL PRIMARY KEY,              -- 改回自增
    ...
    parent_id BIGINT REFERENCES permissions(id),
    ...
);

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
```

`casbin_rule`、`audit_log`、`rate_limit_rules` 不变（已是 `BIGSERIAL`）。

这是模板的初始建表脚本（无需兼容历史数据的真实部署），直接整体重写
`CREATE TABLE`，不涉及 `ALTER TABLE`。

### B. ID 生成与领域模型

- `users.uuid`：应用层调用 `github.com/google/uuid`（`uuid.NewV7()`）在
  `Save()` 时生成，显式写入 INSERT。依赖通过现有 `make tidy` /
  `test/e2e_test.sh` 里的 `go mod tidy` 自动补齐，无需新增模板文件。
- `roles`/`permissions.id`：继续用 `BIGSERIAL` 数据库自增，`RETURNING *`
  自动回填，Go 端不需要生成逻辑。

领域实体字段：

```go
// internal/domain/user
type User struct {
    ID   int64   // 内部主键，仅供 repository 内部 JOIN 使用，不进入 DTO/proto
    UUID string  // 对外标识，DTO/proto 的 "id" 字段映射到这里
    ...
}

// internal/domain/role, internal/domain/permission
type Role struct {
    ID int64   // 直接对应 BIGSERIAL 主键；DTO 转换时 strconv 成 string 对外暴露
    ...
}
```

### C. Repository / Handler 边界转换

Repository 接口（以 user 为例）：

```go
type Repository interface {
    GetByID(ctx context.Context, id int64) (*User, error)       // 改为 int64，内部用
    GetByUUID(ctx context.Context, uuid string) (*User, error)  // 新增，外部入口用
    GetByUsername(ctx context.Context, username string) (*User, error)
    List(ctx context.Context, limit, offset int32) ([]*User, error)
    Count(ctx context.Context) (int64, error)
    Save(ctx context.Context, u *User) (*User, error)           // 生成 UUID v7，写入 uuid 列
    Update(ctx context.Context, u *User) (*User, error)         // 按 u.ID (int64) 更新
    UpdatePassword(ctx context.Context, id int64, passwordHash string) error
    Delete(ctx context.Context, id int64) error
    SetStatus(ctx context.Context, id int64, status int) error
}
```

Role/Permission 的 Repository 接口同样把 `id string` 参数改为 `id int64`
（纯签名类型变更，方法数量不变）。

Handler/DTO 层转换：
- **users**：RPC 请求的 `in.ID` 视为 UUID，handler 先调用
  `repo.GetByUUID(ctx, in.ID)` 拿到 `domain.User`（含内部 `ID int64`），后续
  Update/Delete/SetStatus 调用用 `u.ID`。
- **roles/permissions**：`in.ID` 是 int64 的字符串形式，handler 用
  `strconv.ParseInt(in.ID, 10, 64)` 直接转换，非法输入返回明确的参数错误，
  不查库。
- DTO 输出：users 输出 `u.UUID`；roles/permissions 输出
  `strconv.FormatInt(r.ID, 10)`。

### D. Auth/Casbin 身份标识

保持现状：**JWT `Claims.Uid` 和 Casbin 策略主体（subject）继续使用 UUID
字符串**，不改变已有认证/鉴权语义。

涉及 `user_roles` DB 外键操作又要同步 Casbin 的场景（`AssignRoles`、
`DeleteRolesForUser` 等），在**应用服务层**（`internal/application/user/
user_service.go`，而非最外层 RPC handler）里先用 `repo.GetByUUID` 解析出
内部 `int64 ID`，再传给 repository 操作 `user_roles`；Casbin 一侧
（`enforcer.DeleteRolesForUser`/`AddRoleForUser` 等）继续直接传 UUID
字符串——Casbin 策略主体本身是自由字符串，不依赖数据库外键类型。

这是本次改动里最细致、最容易出错的部分（同一方法内 UUID→int64 解析与
DB/Casbin 双路操作并存），实现时需要重点补充测试覆盖。

### E. 测试策略

- 现有 fake repository 单元测试（`internal_repository_user_repo_test_go.yaml`
  等）补充：`Save()` 生成的 `UUID` 非空且版本位符合 v7；`GetByUUID` 能查到
  刚插入的记录；`GetByID(int64)` 与 `GetByUUID(string)` 返回一致实体。
- Role/Permission 测试补充 `ID int64` 相关的 strconv 边界用例（非法字符串 ID
  输入时返回明确错误，而非 panic）。
- 已知局限：现有测试全部基于内存 fake repository，不触达真实 Postgres 约束，
  本次不新增真实 DB 集成测试（Issue 建议的"渲染 + 真实 INSERT 校验"超出本次
  范围）。类型一致性通过编译期检查 + fake 测试覆盖，足以避免"字段类型不匹配
  导致编译失败"和"忘记生成 ID 导致插入失败"这两类问题重现。

### F. 影响范围

`rbac-kitex/kitex-template/` 与 `admin-services-kitex/kitex-template/`
两边对称各改一份（不做去重，Issue #43 范围）：

- `internal_db_schema_000001_{rbac,admin}_sql.yaml`（schema 重写）
- `migration_init.yaml`（两个模板各一份，goose migration 重写）
- `internal_db_query_{rbac,admin}_sql.yaml`（sqlc：users INSERT 加 uuid 列，
  新增 `GetUserByUUID` 查询）
- `internal_repository_{user,role,permission}_repo_go.yaml`（两个模板各一份，
  共 6 个文件）
- `internal_domain_{user,role,permission}_repository_go.yaml`（接口签名，
  共 6 个文件）
- `internal_domain_user_entity_go.yaml`（新增 UUID 字段，两个模板各一份）
- `internal_application_{user,role,permission}_{user,role,permission}_service_go.yaml`
  （UUID→int64 解析逻辑，共 6 个文件）
- `internal_application_{user,role,permission}_dto_go.yaml`（DTO 转换）
- 对应的 `_test_go.yaml` 测试文件

**Issue 归档**：本次方向与 Issue #38/#46 原本"补完 string 主键的 ID 生成
机制"的前提相反，PR 描述里用 `Closes #38` `Closes #46` 一并关闭——它们描述的
问题在新方案下不再存在。
