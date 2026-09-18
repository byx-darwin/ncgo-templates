# Design: user-kitex 密码修改/重置 + 审计日志子系统（Plan 4 of 4）

**Issue:** #70
**Status:** Approved (chat), pending written-spec review
**Depends on:** Plan 3 (admin-bff-hertz terminal-user-management, Issues #67-69)
**Out of scope:** 忘记密码的终端用户自助重置（需邮件/短信基础设施）— 已拆分为 Issue #71

## Context

三段式工作（Plan 1: `user-kitex`、Plan 2: `user-bff-hertz`、Plan 3: `admin-bff-hertz` 终端用户管理）完成后拆出的独立计划。Plan 3 brainstorming 阶段明确把"登录/操作审计日志查询"拆出来，因为 `user-kitex` 目前没有任何审计日志存储/写入点/查询 RPC，是一个从零开始的子系统。范围澄清后确认一并补上密码修改/重置功能本身（`user-kitex` 目前完全没有——`Repository.UpdatePassword` 只在数据层存在，无任何 usecase/handler 调用）。

### 现状调研摘要

- `user-kitex` 是 DDD 分层：`internal/domain/user`（实体+仓储接口）、`internal/repository/user`（sqlc 实现）、`internal/application/{user,useradmin}`（自助/管理员两个 usecase 服务）、`internal/handler`（Kitex handler）。
- `Repository.UpdatePassword(ctx, id, passwordHash) error` 是裸哈希覆盖，无旧密码校验；旧密码校验目前只存在于 `Login` 流程（`auth.VerifyPassword`）。
- `rbac-kitex`/`admin-services-kitex` 已有审计日志**写入**模式（`audit_log` 表 + `audit.Writer` 接口 + 各 usecase 注入写点），可直接复用到 `user-kitex`；但**查询**端在整个仓库中完全没有先例（无 List/Get RPC、无 handler 范式），本次从零设计。
- `Ban`/`Unban`/`ForceLogout`/`AdminUnbindProvider` 目前不写任何日志/审计记录。
- `ForceLogout` 依赖的 Redis 黑名单（`Blacklist.Revoke`）是"尽力而为"机制——写入黑名单，但 JWT 中间件从不读取校验，是一个既有缺口，本计划沿用该机制（不修复该缺口，仅复用其"尽力而为"语义）。
- Kitex 层无限流机制；限流目前只在 Hertz(BFF) 层有完整实现（`middleware.RateLimit` + `ratelimit.Resolver`），且 `resolver.go` 里 `PreAuth`/`PostAuth` 两个 phase 名是硬编码的。
- IDL 位于 `user-kitex/idl/user.proto`；新增 RPC 后 `make update` 重新生成 `kitex_gen`；新增 sqlc 查询后 `make sqlc` 重新生成 `internal/db/gen`。

## Goals

1. `user-kitex` 新增密码修改/重置功能：自助改密码（验证旧密码）、管理员强制重置（无需旧密码）
2. `user-kitex` 新增审计日志子系统：存储 + 写入点（登录、绑定/解绑、管理员操作、密码修改/重置）+ 查询 RPC
3. `admin-bff-hertz` 新增审计日志查询接口，接入 Plan 3 已建好的终端用户管理区域

## 审计日志表结构

新表 `audit_log`（`user-kitex/internal/db/schema/`，新增 schema 文件）：

```sql
CREATE TABLE audit_log (
    id BIGSERIAL PRIMARY KEY,
    actor_uid TEXT,
    action TEXT NOT NULL,
    target TEXT NOT NULL DEFAULT '',
    ip_address TEXT NOT NULL DEFAULT '',
    user_agent TEXT NOT NULL DEFAULT '',
    detail_json TEXT NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_log_actor_created ON audit_log(actor_uid, created_at);
CREATE INDEX idx_audit_log_action_created ON audit_log(action, created_at);
```

与 rbac-kitex 的 4 字段版本相比，`ip_address`/`user_agent` 被提升为顶层列而非塞进 `detail_json`——登录审计场景高频按这两个维度过滤。

**保留策略：本计划不实现自动清理/分区**（YAGNI，仓库目前没有定时任务基础设施）。在文档中明确标注为未来工作。

## 审计日志基础设施（`internal/infrastructure/audit`）

沿用 rbac-kitex 的 `Writer` 接口不变，新增查询侧：

```go
type Entry struct {
    ActorUID, Action, Target, IPAddress, UserAgent, DetailJSON string
    CreatedAt time.Time
}

type Writer interface {
    Write(ctx context.Context, e Entry) error
}

type ListFilter struct {
    ActorUID           string     // 必填
    Action             *string
    StartTime, EndTime *time.Time
    Limit, Offset      int
}

type Reader interface {
    List(ctx context.Context, f ListFilter) ([]Entry, int64, error) // 返回条目 + 总数
}
```

`SQLWriter`/`SQLReader` 基于 sqlc 新查询（`InsertAuditLog`、`ListAuditLog`、`CountAuditLog`），`ListAuditLog` 按 `actor_uid` 必填 + `action`/时间范围可选过滤，分页仿照现有 `ListUsers`（`LIMIT $n OFFSET $m`）。`MemoryWriter`/`MemoryReader` 作为测试替身（沿用 rbac-kitex 已有 `MemoryWriter` 模式）。

生产环境 wiring 与 rbac-kitex 一致：`cfg.Database.Enabled` 为真时用 `NewSQLWriter`/`NewSQLReader`，否则用内存版（保证无 DB 场景仍可无痛启动）。

## 写点（Write Points）

每个 usecase 方法在**操作成功后**执行 best-effort 写入（`_ = writer.Write(...)`，错误不阻断主流程），action 命名沿用 `<domain>.<verb>` 惯例：

| Usecase 方法 | Action | 备注 |
|---|---|---|
| `usersvc.Login` | `auth.login.success` / `auth.login.failure` | 本地密码 + OAuth 分支都覆盖；失败也要记（含用户名枚举防护路径） |
| `usersvc.OAuthCallback` | `auth.login.success` / `auth.login.failure` | 第三方登录成功/失败 |
| `usersvc.BindProvider` | `identity.bind` | |
| `usersvc.UnbindProvider` | `identity.unbind` | 含自助与管理员代操作两条调用路径 |
| `usersvc.ChangePassword`（新增） | `user.password_change` | |
| `useradminsvc.BanUser` | `user.ban` | |
| `useradminsvc.UnbanUser` | `user.unban` | |
| `useradminsvc.ForceLogout` | `user.force_logout` | |
| `useradminsvc.ResetPassword`（新增） | `user.password_reset` | |

`detail_json` 按事件类型放差异化字段（如登录失败原因、OAuth provider 名）；`target` 为被操作用户的 UID（对自助操作 = actor_uid 本身）。

## 密码修改/重置

**两个独立 RPC**（而非单一 RPC 带标志位），与 `AdminUnbindProvider` 直调 `usersvc.UnbindProvider` 的既有先例一致：

```proto
// ChangePassword 由已登录终端用户发起，需验证旧密码。
rpc ChangePassword(ChangePasswordReq) returns (ChangePasswordResp);

// ResetPassword 由管理员发起（经 admin-bff-hertz RBAC 校验后调用），
// user-kitex 信任调用方的权限校验，不再重复校验，同 AdminUnbindProvider 的信任模型。
rpc ResetPassword(ResetPasswordReq) returns (ResetPasswordResp);
```

两者共享一个私有 helper（`usersvc` 内部），流程：
1. `ChangePassword` 额外前置 `auth.VerifyPassword(oldPassword, u.PasswordHash)` 校验；`ResetPassword` 跳过此步
2. `auth.HashPassword(newPassword)`
3. `repo.UpdatePassword(ctx, uid, newHash)`
4. `blacklist.Revoke(ctx, uid)` —— 复用 `ForceLogout` 的既有机制强制旧 token 下线（尽力而为，沿用现状，不修复黑名单读取缺口）
5. 审计写入

**限流**：`user-bff-hertz`（自助改密码端点）与 `admin-bff-hertz`（管理员重置端点）路由上各加一个 `middleware.RateLimit` phase。需要先确认 `internal/pkg/ratelimit/resolver.go` 是否允许新增 phase 名（当前只硬编码 `PreAuth`/`PostAuth`）——若不允许，需要在实现阶段一并扩展该 fragment，这是本计划范围内的必要前置修改，不是单独 Issue。

## 查询接口

**`user-kitex`** 新增 `ListAuditLogs` RPC：

```proto
rpc ListAuditLogs(ListAuditLogsReq) returns (ListAuditLogsResp);
```
入参：`actor_uid`（必填）、`action`（可选）、`start_time`/`end_time`（可选，RFC3339）、`limit`/`offset`。

**`admin-bff-hertz`** 新增端点，挂载到 Plan 3 的终端用户区域：

```go
terminalUsers.GET("/:uid/audit-logs",
    middleware.RequirePermission("terminal_user:audit-log:read"),
    middleware.Authz(rbacCli),
    terminalUserHandler.ListAuditLogs)
```

`Authz` 中间件严格保持 per-route（紧跟在 `RequirePermission` 之后）挂载顺序，与 Plan 3 既有路由一致，不使用 group 级别 `Use()`（避免重现 Plan 3 修复过的中间件顺序 bug）。复用已存在的 `userCli`（无需新增 Kitex client 配置）。

**范围边界：仅管理员可查询**（不新增终端用户自助查看审计历史的端点，`user-bff-hertz` 本次不改动）。

## Testing

- `usersvc.ChangePassword`/`useradminsvc.ResetPassword`：旧密码校验成功/失败、哈希更新、黑名单调用、审计写入（用 `MemoryWriter` 断言写入内容）
- `audit.SQLReader.List`：过滤维度组合（actor_uid only / + action / + 时间范围）、分页边界
- 各写点：使用 `MemoryWriter` 断言每个既有 usecase 方法调用后产生了预期 `Entry`
- `admin-bff-hertz` handler：权限校验、`Authz` 顺序、RPC 转发正确性（沿用 Plan 3 handler 测试模式）

## Open Follow-ups（非本计划范围，仅记录）

- 审计日志保留/清理机制 —— 待仓库具备定时任务基础设施后补齐
- JWT 黑名单"写了没人读"的缺口修复 —— 需要改动 `base-hertz` 中间件，影响面超出本计划，建议后续独立 Issue
- 终端用户自助查看审计历史 —— 如有需求再拆 Issue
