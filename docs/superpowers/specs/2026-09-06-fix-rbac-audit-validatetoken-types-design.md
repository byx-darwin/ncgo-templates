# admin-services-kitex 补齐 int64→string ID 迁移 + rbac-kitex 编译修复（设计）

对应 Issue #37（范围已扩大，见下方“范围升级说明”）。

## 背景

PR #36（"refactor(rbac): sync templates to s-web alignment decisions (string ID +
ValidateToken)"）把 RBAC 相关的 ID 类型从 `int64` 迁移为 `string`。这项迁移在
`rbac-kitex` 模板里做得很完整，但在 `admin-services-kitex`（整合 RBAC + Rule
Center 的合并服务模板）里**从未真正执行**：它的 proto/IDL 与部分 handler 代码
已经假设 string ID（大概率是从 rbac-kitex 复制过来的接口约定），但 DB
schema、domain 实体、repository 接口/实现、domain service、application
service 全部还停留在 `int64`/`BIGSERIAL`/`BIGINT`，导致按模板渲染出的项目
完全无法编译。

Issue #37 最初只报告了其中一小部分表现（`audit.Write` 调用点传 `0`、
`ValidateToken` 失败分支返回 `0`）。经过实际渲染验证（`ncgo new
--template-dir admin-services-kitex` + `go build ./...`），发现这是同一个根因
（admin-services-kitex 的 int64→string 迁移从未完成）触发的一大批编译错误，
覆盖 DB schema、domain、repository、application service、handler、IDL 六层。

## 范围升级说明

最初按 bounded 路径批准的设计（仅改 `s.audit.Write(ctx, 0, ...)` →
`s.audit.Write(ctx, "", ...)` 与 `ValidateToken` 的 `return 0, nil, false` →
`return "", nil, false`，共 26 处）在实际渲染验证时发现严重不足：

1. rbac-kitex 额外发现 `internal_infrastructure_token_redis_go.yaml` 的
   `RedisStore.GetRefresh` 同款遗留问题（`return 0, ...` 应为 `return "",
   ...`）。
2. admin-services-kitex 的问题规模远超两处遗留——整个 user/role/permission/menu
   业务域的 domain/repository/DB schema 从未迁移到 string，只改 audit/
   ValidateToken 两处无法让项目编译通过。

据此升级为架构性变更：**把 admin-services-kitex 的 user/role/permission/menu
四个域完整迁移到 string ID**，与 rbac-kitex 已合并、已评审的实现对齐；Rule
Center 域保持 int64 不变，仅修正 admin.proto 里被误标成 string 的字段。

## 目标

1. `rbac-kitex` 恢复可编译（audit.Write / ValidateToken / RedisStore.GetRefresh
   三类遗留类型不匹配）。
2. `admin-services-kitex` 完整完成 int64→string 迁移，恢复可编译，且与
   rbac-kitex 的实现模式保持一致。
3. Rule Center 域的 ID 类型（int64）与其独立模板 `rule-center/` 保持一致，
   通过修正 proto 字段类型解决，不迁移其 DB schema/domain。
4. 新增 CI 校验：渲染两个模板为真实项目并跑 `go build ./... && go vet
   ./...`，防止此类问题再次漏网合并。

## 非目标

- 不实现"审计 actorUID 从上下文获取真实操作人"（留给独立 Issue，本次仍使用
  空字符串占位）。
- 不迁移 Rule Center 的 DB schema/domain 到 string（保持 int64，与其独立模板
  一致）。
- 不修复 rbac-kitex 的 ID 生成机制是否完整可用（TEXT 主键无 DEFAULT 表达式的
  问题，如果存在，超出本次范围，需要时另开 Issue）。

## 修复范围详情

### A. rbac-kitex（3 类遗留问题，均为独立文件的孤立修复）

| 文件 | 改动 |
|---|---|
| `internal_application_{role,user,permission}_*_service_go.yaml` | `s.audit.Write(ctx, 0, ...)` → `s.audit.Write(ctx, "", ...)`（11 处：role 4、user 4、permission 3） |
| `internal_application_auth_auth_service_go.yaml` | `ValidateToken` 失败分支 `return 0, nil, false` → `return "", nil, false`（2 处） |
| `internal_infrastructure_token_redis_go.yaml` | `RedisStore.GetRefresh` 的 `return 0, errors.New(...)` → `return "", errors.New(...)` |

### B. admin-services-kitex（系统性 int64→string 迁移）

**B1. DB schema** — `internal_db_schema_000001_admin_sql.yaml`：
`users.id`、`roles.id`、`permissions.id`/`parent_id`、`user_roles.user_id`/
`role_id`、`role_permissions.role_id`/`permission_id`、`audit_log.actor_uid`
从 `BIGSERIAL`/`BIGINT` 改为 `TEXT`。`casbin_rule.id`、`audit_log.id`、
`rate_limit_rules.*` 不变。

**B2. Query SQL** — `internal_db_query_admin_sql.yaml`：
`ListPermissionsByRoleIDs` 的 `ANY($1::bigint[])` → `ANY($1::text[])`；
`ListPermissionsFiltered` 的 parentID 过滤哨兵值从 `$2 < 0` 改为 `$2 = ''`
（与 rbac-kitex 一致）。

**B3. Domain 实体**：`internal_domain_{user,role,permission,menu}_entity_go.yaml`
的 `ID`/`ParentID` 字段及相关构造函数参数 `int64` → `string`；
`internal_domain_menu_entity_go.yaml` 的 `map[int64]*Node` → `map[string]*Node`。
配套测试文件里的 `int64` 字面量改为字符串字面量。

**B4. Domain repository 接口**：`internal_domain_{user,role,permission,menu}_repository_go.yaml`
的方法签名（`GetByID`/`Delete`/`ListFiltered`/`ListByRoleIDs`/`ListChildren`/
`ListMenusByParentID` 等）参数类型 `int64`/`[]int64` → `string`/`[]string`。
`Count(ctx) (int64, error)` 保留（计数值非 ID）。

**B5. Domain service**：`internal_domain_role_service_go.yaml` 的 `Assign`
签名与校验逻辑（`roleID <= 0` → `roleID == ""`）。

**B6. Repository 实现**：`internal_repository_{user,role,permission,menu}_repo_go.yaml`
方法签名同步 B4，及 `if x.ID != 0` → `!= ""` 一类判空逻辑改写。

**B7. Application 层**：`internal_application_{user,role,permission,menu}_dto_go.yaml`
的 `ID`/`ParentID`/`Uid` 字段类型；
`internal_application_permission_permission_service_go.yaml` 的 `-1` 哨兵值
过滤逻辑简化为空字符串判断（与 rbac-kitex 一致，代码更简单）；
`internal_application_rbac_enforce_service_go.yaml` 的 `Enforce` 签名；
`internal_application_auth_auth_service_go.yaml` 的 `GetByID`/`ListRoles`/
`Sign`/`ValidateToken` 签名（与 A 的 `return 0, nil, false` 属同一组改动，
签名本身也要同步改，否则光改 return 语句还是编译不过）。

**B8. Handler**：`internal_handler_rbacservice_handler_go.yaml` 的
`ListPermissionsFilter{ParentID: -1}` → `""`；`internal_handler_authservice_handler_go.yaml`
无需改动逻辑代码——它已经写死使用 `Roles` 字段，通过 C 节的 proto 字段改名
即可让其编译通过。

**B9. audit.Writer / token store（与 A 节的两处遗留共享的接口签名）**：
`internal_infrastructure_audit_writer_go.yaml`（`Entry.ActorUID`、
`Writer.Write`、`SQLWriter.Write`、`MemoryWriter.Write` 全部签名）、
`internal_infrastructure_token_{memory,redis,store}_go.yaml`（`SetRefresh`/
`GetRefresh` 签名，并删除 `internal_infrastructure_token_memory_go.yaml` 里
不再需要的 `strconv.FormatInt`/`strconv.ParseInt` 转换代码及其 import）、
`internal_infrastructure_auth_jwt_go.yaml`（`Claims.Uid`、`JWTManager.Sign`
签名）—— 这些是修复 audit.Write/ValidateToken 两处遗留时必然触发的连锁签名
改动，不改会在这批文件里产生新的编译错误。

**B10. 测试文件**：所有以上文件对应的 `*_test_go.yaml` 中硬编码的 `int64`
字面量（`ID: 1`、`map[int64]...`、函数调用传 `0`/`1` 等）改为字符串字面量。

### C. admin.proto

| 字段 | 改动前 | 改动后 | 说明 |
|---|---|---|---|
| `ValidateTokenResp.role_codes` | `repeated string role_codes = 2;` | `repeated string roles = 2;` | 字段号不变，仅改名以匹配 handler.go 已经使用的 `Roles` 字段 |
| `CreateRuleResp.id` | `string id = 1;` | `int64 id = 1;` | Rule Center，回退为其原生 int64 |
| `UpdateRuleReq.id` | `string id = 1;` | `int64 id = 1;` | 同上 |
| `DeleteRuleReq.id` | `string id = 1;` | `int64 id = 1;` | 同上 |
| `RateLimitRule.id` | `string id = 1;` | `int64 id = 1;` | 同上，回退后 `internal_usecase_rulecenter_usecase_go.yaml` 的两处类型转换错误自动消失，无需改动该文件 |

RBAC 侧其余 message 已经是 string，不需要改动。

### D. CI 校验新增

新增 `.github/workflows/template-build-check.yml`：
- 触发条件：PR 改动路径匹配 `rbac-kitex/**` 或 `admin-services-kitex/**`
- 步骤：安装 `ncgo` CLI，用 `ncgo new --template-dir <package> --no-generate`
  （或等效方式）渲染出真实项目，执行 `go build ./... && go vet ./...`
- 两个模板分别渲染、分别校验

## 验证方式

对 rbac-kitex 和 admin-services-kitex 分别执行：
```bash
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/ncgo-scratch --template-dir <rbac-kitex|admin-services-kitex>
cd /tmp/ncgo-scratch && go build ./... && go vet ./... && go test ./...
```
均需全部通过（本设计的所有改动已在审计阶段用此方式端到端验证过一遍，详见
实施计划中每个任务自带的验证步骤）。

## 验收标准

- [ ] rbac-kitex 渲染出的项目 `go build ./... && go vet ./...` 通过
- [ ] admin-services-kitex 渲染出的项目 `go build ./... && go vet ./... && go test ./...` 通过
- [ ] 新增 CI workflow 路径过滤触发正确，在当前分支上能跑通
- [ ] Rule Center 相关功能（proto 回退 int64 后）未被破坏
