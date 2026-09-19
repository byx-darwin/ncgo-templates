# Design: 终端用户忘记密码自助重置

**Issue:** #71
**Status:** Approved (chat), pending written-spec review
**Depends on:** Plan 4（Issue #70，`user-kitex` 密码修改/重置 + 审计日志），已合并
**Out of scope:** 邮件/短信真实发送能力的接入（SMTP/短信网关账号与 SDK）— 本设计只定义可插拔接口 + stub 实现，真实接入留待后续独立 Issue

## Context

Issue #70（Plan 4）brainstorming 阶段明确把"忘记密码"的终端用户自助重置流程拆出来，因为它需要邮件/短信发送基础设施，而 `ncgo-templates` 仓库目前完全没有这类能力（无 SMTP client、无短信网关 SDK、无相关配置项）。Plan 4 已经实现了两个需要登录态/管理员权限的场景：
- `ChangePassword`（终端用户自助改密码，需验证旧密码）
- `ResetPassword`（管理员强制重置，`admin-bff-hertz` 侧，无需旧密码）

本设计补齐第三种场景：终端用户**忘记密码、无法登录**时，通过预留在账号上的邮箱或手机号收到重置凭证，自助完成密码重置，全程无需管理员介入。

### 现状调研摘要

- `User` 实体（`user-kitex/internal/domain/user/entity.go`）已有 `Email`/`Phone` 字段，但 `users` 表 schema 对二者**没有唯一约束**（允许重复甚至为空），仓库也**没有**按 email/phone 查询用户的 repository 方法（`GetByEmail`/`GetByPhone` 均不存在）。
- 密码更新的公共路径是 `Repository.UpdatePassword(ctx, id, passwordHash)`（裸哈希覆盖），Plan 4 已经把这条路径接到 `ChangePassword`/`ResetPassword` 两个 usecase 上。
- `audit_log` 基础设施（`internal/infrastructure/audit`，Writer/Reader）已在 Plan 4 建好，可直接复用写入点。
- 限流机制目前只在 `user-bff-hertz`/`admin-bff-hertz`（Hertz 层）有实现（`middleware.RateLimit` + `ratelimit.Resolver`），Kitex 层无限流；Plan 4 已经用这套机制给自助改密码/管理员重置端点各加了一个 phase，本设计沿用同一套机制。
- JWT 黑名单（`blacklist.Revoke`）是"尽力而为"机制（写入黑名单但中间件不读取校验），Plan 4 已经在密码变更后调用它强制旧 token 下线，本设计沿用不修复。
- 仓库无任何邮件/短信发送代码或配置项，也无定时任务基础设施（因此不做 token 自动清理）。

## Goals

1. `user-kitex` 新增两个无需登录态的 RPC：`RequestPasswordReset`（发起重置，按邮箱或手机号查找账号并下发凭证）、`ConfirmPasswordReset`（凭证换新密码）
2. `user-kitex` 补齐 `GetByEmail`/`GetByPhone` 查询能力，并为 `email`/`phone` 补充部分唯一约束（仅非空值唯一）
3. 新增 `password_reset_tokens` 表存储重置凭证（哈希存储、有效期、单次使用）
4. 新增 `internal/infrastructure/notify` 抽象（`EmailSender`/`SMSSender` 接口 + stub 实现），真实发送能力留待后续 Issue
5. `user-bff-hertz` 新增两个公开端点（无需 JWT，但需限流）转发上述 RPC
6. 全程遵循防枚举原则：无论账号是否存在都返回相同的成功提示；凭证校验失败统一错误信息，不区分"不存在/已过期/已使用"

## 架构概览

```
终端用户（未登录）
  │
  ▼
user-bff-hertz
  POST /password-reset/request  { identifier, channel }   ─┐ 限流：按 IP + 按 identifier
  POST /password-reset/confirm  { credential, new_password}─┘ 限流：按 IP
  │ （无 JWT 校验，公开路由）
  ▼
user-kitex (RPC)
  RequestPasswordReset(identifier, channel)
  ConfirmPasswordReset(credential, new_password)
  │
  ├─ user.Repository: GetByEmail / GetByPhone / UpdatePassword
  ├─ PasswordResetRepository: CreateResetToken / GetValidResetToken /
  │                            InvalidateUserTokens / MarkTokenUsed
  ├─ notify.EmailSender / notify.SMSSender（stub 实现）
  ├─ auth.Blacklist.Revoke（复用 Plan 4 机制，强制旧 token 下线）
  └─ audit.Writer（复用 Plan 4 基础设施）
```

`admin-bff-hertz` 不涉及本流程（纯终端用户自助场景，管理员强制重置已由 Plan 4 的 `ResetPassword` RPC 覆盖）。

## 数据模型

### 用户表约束补充

新迁移 `user-kitex/internal/db/schema/000003_user_contact_unique.sql`：

```sql
CREATE UNIQUE INDEX idx_users_email_unique ON users (email) WHERE email <> '';
CREATE UNIQUE INDEX idx_users_phone_unique ON users (phone) WHERE phone <> '';
```

使用部分唯一索引而非列级 `UNIQUE`，允许多个空值共存，只约束非空值唯一。实现阶段需要先检查现有数据（测试库/迁移脚本）是否已存在重复 email/phone；若有，需要先清洗数据再建索引，否则迁移会失败。

### 密码重置凭证表

新迁移 `user-kitex/internal/db/schema/000004_password_reset_tokens.sql`：

```sql
CREATE TABLE password_reset_tokens (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel TEXT NOT NULL,          -- 'email' | 'sms'
    credential_hash TEXT NOT NULL,  -- token/验证码的哈希，不存明文
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_password_reset_tokens_user_id ON password_reset_tokens(user_id);
```

**保留策略：不实现自动清理**（YAGNI，与 `audit_log` 保留策略一致，仓库无定时任务基础设施），记为 Open Follow-up。

### Repository 接口新增

`user-kitex/internal/domain/user/repository.go`：

```go
GetByEmail(ctx context.Context, email string) (*User, error)
GetByPhone(ctx context.Context, phone string) (*User, error)
```

新增 `PasswordResetRepository`（沿用 `audit.Writer`/`audit.Reader` 的独立接口风格，而非塞进 `user.Repository`，因为凭证生命周期与 User 聚合无关）：

```go
type ResetToken struct {
    ID              ID
    UserID          ID
    Channel         string
    CredentialHash  string
    ExpiresAt       time.Time
    UsedAt          *time.Time
    CreatedAt       time.Time
}

type PasswordResetRepository interface {
    CreateResetToken(ctx context.Context, t *ResetToken) error
    GetValidResetToken(ctx context.Context, credentialHash string) (*ResetToken, error) // 未过期且未使用；查不到/已失效均返回 ErrNotFound
    InvalidateUserTokens(ctx context.Context, userID ID) error // 标记该用户所有未使用 token 为已使用
    MarkTokenUsed(ctx context.Context, id ID) error
}
```

生产环境走 sqlc 生成的 SQL 实现；测试用内存实现（`MemoryPasswordResetRepository`，沿用 `audit.MemoryWriter` 模式）。

## 通知发送基础设施

新增 `user-kitex/internal/infrastructure/notify`：

```go
type EmailSender interface {
    SendPasswordResetLink(ctx context.Context, to, resetLink string) error
}
type SMSSender interface {
    SendPasswordResetCode(ctx context.Context, to, code string) error
}
```

- 生产 wiring 先接 stub 实现（`LogEmailSender`/`LogSMSSender`，记录到 logger，供人工核对/测试断言用），真实 SMTP/短信网关接入是独立 Issue（需要确定服务商账号、SDK、配置项）
- 配置项预留 `cfg.Notify.Provider`（如 `"log"`），仿照 `cfg.Database.Enabled` 的开关先例，方便后续切换真实实现而不改动 usecase 代码

## 凭证生成

- **邮件**：32 字节 `crypto/rand` 随机数，`base64url` 编码后拼进链接（`https://<bff-domain>/reset-password?token=xxx`），有效期 **15 分钟**
- **短信**：6 位数字验证码（`crypto/rand` 生成），有效期 **5 分钟**
- 两者存库前都做哈希（复用 `auth` 包已有的哈希原语，避免库泄露后凭证被直接使用；哈希算法与 `auth.HashPassword` 保持一致的包内实现，不引入新依赖）

## 限流

复用 Plan 4 已确认可行的 `middleware.RateLimit` 机制，在 `user-bff-hertz` 路由层新增两个 phase：

- `POST /password-reset/request`：按 IP + 按 identifier 双维度限流（各 5 次/小时），防止短信/邮件轰炸和账号枚举
- `POST /password-reset/confirm`：按 IP 限流（10 次/小时），防止验证码暴力枚举

若 `internal/pkg/ratelimit/resolver.go` 当前硬编码的 phase 名（`PreAuth`/`PostAuth`）不支持新增 phase，需要在实现阶段扩展该 fragment（Plan 4 已确认这是必要前置修改而非独立 Issue，本设计沿用同一判断）。

## 用例流程

### `RequestPasswordReset(identifier, channel)`

1. 按 `channel` 调 `GetByEmail`/`GetByPhone` 查用户
2. 查不到 → **仍返回通用成功**，不写审计、不发通知、直接返回（防止账号枚举）
3. 查到用户 →
   a. `InvalidateUserTokens(userID)`（标记该用户所有未使用 token 为已使用，确保任意时刻至多一个有效 token）
   b. 生成新凭证（按 channel 走邮件/短信分支）
   c. 哈希凭证 → `CreateResetToken`
   d. 调 `EmailSender.SendPasswordResetLink` / `SMSSender.SendPasswordResetCode`（best-effort：发送失败记录日志，但不影响接口返回通用成功，避免把发送成败作为枚举侧信道）
   e. 审计写入 `user.password_reset_requested`（只在查到用户时写，避免日志本身成为枚举侧信道）
4. 无论 2 还是 3，对调用方的返回值完全一致

### `ConfirmPasswordReset(credential, new_password)`

1. 哈希 `credential` → `GetValidResetToken` 查找（未过期、未使用）
2. 查不到/已过期/已使用 → 统一返回错误"验证码无效或已过期"，不区分具体原因（防止时序/信息侧信道）
3. 查到 → `auth.HashPassword(new_password)` → `repo.UpdatePassword(ctx, uid, newHash)`
4. `MarkTokenUsed(tokenID)`
5. `blacklist.Revoke(ctx, uid)`（复用 Plan 4 机制，强制旧 token 下线，尽力而为）
6. 审计写入 `user.password_reset_confirmed`

## API

### user-kitex IDL 新增（`user-kitex/idl/user.proto`）

```proto
message RequestPasswordResetReq {
  string identifier = 1; // 邮箱地址或手机号，取决于 channel
  string channel = 2;    // "email" | "sms"
}
message RequestPasswordResetResp {} // 恒定返回空成功体，不携带任何账号是否存在的信息

message ConfirmPasswordResetReq {
  string credential = 1;    // 邮件链接中的 token，或短信验证码
  string new_password = 2;
}
message ConfirmPasswordResetResp {}

rpc RequestPasswordReset(RequestPasswordResetReq) returns (RequestPasswordResetResp);
rpc ConfirmPasswordReset(ConfirmPasswordResetReq) returns (ConfirmPasswordResetResp);
```

`channel` 由调用方（`user-bff-hertz`）显式传入，而非由 `identifier` 格式推断——避免邮箱/手机号格式判断的边界歧义（如某些手机号格式可能与邮箱本地部分冲突）。

### user-bff-hertz 新增端点

```
POST /password-reset/request   { "identifier": "...", "channel": "email"|"sms" }
POST /password-reset/confirm   { "credential": "...", "new_password": "..." }
```

不挂载任何 JWT 中间件（公开路由），仅挂限流 phase。

## Testing

沿用 Plan 4 测试模式（`MemoryWriter`/内存版 repository）：

- `GetByEmail`/`GetByPhone`：命中/未命中
- `RequestPasswordReset`：
  - 账号存在/不存在均返回相同成功响应
  - 账号存在时：生成新 token、旧 token 被作废、调用了对应 channel 的 sender（用 stub sender 的内存记录断言发送内容）、写入审计
  - 账号不存在时：不写审计、不调用 sender
- `ConfirmPasswordReset`：
  - 正确凭证 → 密码更新成功、token 标记已用、黑名单撤销被调用、写入审计
  - 凭证不存在/已过期/已使用 → 均返回同一统一错误
- Email/phone 唯一约束迁移：数据库集成测试验证重复非空值插入失败、多个空值可共存
- `user-bff-hertz` handler：限流生效（超过阈值返回 429）、参数校验、RPC 转发正确性

## Open Follow-ups（非本计划范围，仅记录）

- 邮件/短信真实发送能力接入（SMTP/短信网关账号、SDK、配置）— 需要确定服务商后独立 Issue
- 密码重置凭证表的自动清理机制 — 待仓库具备定时任务基础设施后补齐（与 `audit_log` 保留策略一致）
- `ratelimit.Resolver` 的 phase 名扩展如证实当前实现不支持，作为本 Issue 实现阶段的前置修改，不单独立 Issue
