# Design: SMS 重置验证码绑定账号标识，收敛暴力枚举面

**Issue:** #75
**Status:** Approved (chat), pending written-spec review
**Depends on:** Issue #71（终端用户忘记密码自助重置），已合并
**Out of scope:** email 渠道（32 字节 base64url token，15 分钟 TTL，密钥空间 2^128，本身不存在暴力枚举风险，不做任何改动）；per-token 失败次数计数器（用户决策：本次不做，见下方"被否决的方案"）

## Context

Issue #75 在 Issue #71 review 阶段发现：`ConfirmPasswordReset` 只接受 `credential` + `new_password`，`GetValidPasswordResetToken` 纯粹按 `credential_hash` 在**全体用户**范围内查找，不做任何账号标识校验。SMS 渠道下发的是 6 位数字验证码（`crypto/rand` 生成，1,000,000 种可能），TTL 5 分钟，唯一的防线是 `user-bff-hertz` 层的 IP 限流（`password_reset_confirm` phase，10 次/小时）。

### 现状调研摘要

- `ConfirmPasswordReset(ctx, credential, newPassword)`（`user-kitex/kitex-template/internal_application_user_user_service_go.yaml` ~L556）：`hashCredential(credential)` 后调用 `resetRepo.GetValid`，成功即直接改密码，不做任何身份匹配。
- `password_reset_tokens` 表（`internal_db_schema_000004_password_reset_tokens_sql.yaml`）：`id, user_id, channel, credential_hash(UNIQUE), expires_at, used_at, created_at`——**没有 `attempts` 字段**，也没有任何应用层失败计数。
- `GetValidPasswordResetToken` SQL 查询（`internal_db_query_password_reset_token_sql.yaml`）：`WHERE credential_hash = ? AND used_at IS NULL AND expires_at > now()`，不带 `user_id`/`channel` 过滤。
- SMS 验证码生成：`generateSMSCode()`（同文件 ~L454），4 字节 `crypto/rand` → `uint32 % 1,000,000` → `%06d`；`smsResetCodeTTL = 5 * time.Minute`。对照组：email token 32 字节 base64url，TTL 15 分钟，密钥空间远大于可行暴力枚举范围。
- `User` 实体已有 `Email`/`Phone` 字段（`internal_domain_user_entity_go.yaml`），`user.Repository` 已有 `GetByEmail`/`GetByPhone`（Issue #71 引入，供 `RequestPasswordReset` 使用）。
- IP 限流：`user-bff-hertz` 的 `PasswordResetConfirm` phase，`KeyBy: ["ip"]`，`MaxRequests: 10`，`WindowSeconds: 3600`（`conf.yaml` ~L440）。这是当前唯一的防御层，且是**跨账号共享**的——攻击者只要把猜测请求分散到多个源 IP，就完全绕过它。
- Issue #71 建立的防枚举原则（本设计继续遵守）：`RequestPasswordReset` 无论账号是否存在都返回成功；`ConfirmPasswordReset` 把"不存在/已过期/已使用/不匹配"全部折叠成同一个通用错误，不给攻击者任何区分信号。

### 真正的漏洞是什么

`credential_hash` 唯一索引保证系统中至多一行匹配某个哈希值，但**匹配到哪个账号完全由运气决定**——攻击者不需要事先知道任何目标身份。设系统中有 N 个未过期的 SMS token，那么任意一次随机猜测命中"某个账号"的概率 ≈ N / 1,000,000，且一旦命中就直接重置了**那个账号**的密码，攻击者甚至不知道自己攻陷的是谁。IP 限流只按来源 IP 计数，对"广撒网、瞄的是随便哪个账号"这种攻击模式没有约束力——把猜测请求分散到 M 个 IP，总猜测预算就是 10×M 次/小时，与目标账号数量无关。

## 被否决的方案

Issue 里提出"and/or 增加 per-token 失败计数器"。已与用户确认：**本次只做账号标识绑定，不做计数器**。理由（决策记录，非本设计的论证责任）：标识绑定已经把"命中任意账号"的攻击面收敛为"命中指定账号"，配合已有的 IP 限流（10 次/小时/IP）已经让针对单一已知账号的暴力枚举变得不可行（1,000,000 种可能 ÷ 10 次/小时 ≈ 11 年）；计数器是纯 schema 新增改动，后续如认为有必要可以独立立项，不阻塞本次修复。

## Goals

1. `ConfirmPasswordReset` 的 SMS 路径要求调用方提供 `phone`，服务端校验其与该 token 归属账号的手机号一致，不一致按现有通用错误处理
2. email 路径完全不变（`phone` 参数被忽略）
3. 不引入任何 schema 迁移——校验基于已取出的 token 的 `UserID` 做内存比较，不新增 SQL 查询或索引
4. 更新受影响的 Kitex IDL / BFF 请求体 / 服务层签名 / 相关测试

## 架构概览

```
终端用户（未登录，持有短信验证码）
  │
  ▼
user-bff-hertz
  POST /auth/password-reset/confirm { credential, new_password, phone? }
  │ phone 为新增可选字段；email 流程留空即可，SMS 流程必填
  ▼
user-kitex (RPC)
  ConfirmPasswordReset(credential, phone, new_password)
  │
  ├─ resetRepo.GetValid(hashCredential(credential))   ← 查询不变，无 schema 改动
  ├─ 若 token.Channel == "sms":
  │     require phone != "" AND phone == user(token.UserID).Phone
  │     不满足 → 复用现有"凭证无效或已过期"通用错误
  ├─ 若 token.Channel == "email": phone 被忽略，行为不变
  └─ 通过后：setPassword(...) → resetRepo.MarkUsed(...)（不变）
```

`RequestPasswordReset`、`admin-bff-hertz`、`password_reset_tokens` 表结构均不涉及。

## 接口变更

### Kitex IDL

`ConfirmPasswordResetRequest` 新增可选字段 `phone`（string，不设默认值语义，空字符串表示"未提供"）。这是本设计中唯一的公共 API 变更；由于 `ncgo-templates` 是模板生成器，实际改动落在对应的 IDL 模板与生成产物里。

### 应用服务层

`ConfirmPasswordReset` 签名从 `(ctx, credential, newPassword)` 变为 `(ctx, credential, phone, newPassword)`。唯一调用方是 Kitex handler，改动是内部的、非渐进式的（无需兼容旧签名）。

新增校验逻辑（在 `resetRepo.GetValid` 成功之后、`setPassword` 之前）：

```go
if tok.Channel == "sms" {
    if phone == "" {
        return errGenericInvalidCredential
    }
    u, err := s.repo.GetByID(ctx, tok.UserID) // user.Repository.GetByID(ctx, id ID) (*User, error)，已存在，无需新增
    if err != nil || u.Phone != phone {
        return errGenericInvalidCredential
    }
}
```

（`ConfirmPasswordReset` 目前只持有 `tok.UserID`，直接以 `tok.UserID.String()` 传给 `setPassword`，本身并未取出 `*User`；新增这一次 `s.repo.GetByID` 调用是本设计唯一新增的读操作，且是已有方法，非新增接口。）

`errGenericInvalidCredential` 复用现有的通用错误变量/字符串（当前是 `"user: reset credential is invalid or expired"`），确保"验证码猜对但手机号不对"与"验证码猜错"在响应上完全不可区分，不引入新的可枚举信号或时间侧信道（两条路径都已经完成了一次 token 查询，开销量级一致）。

### BFF 层

`POST /auth/password-reset/confirm` 请求体新增可选 JSON 字段 `phone`，透传给 RPC。响应体/错误码不变。

## 错误处理

- token 不存在/已过期/已使用：现有通用错误，不变。
- SMS token 但 `phone` 缺失或与账号不符：**同一个**通用错误（新增分支，复用错误值）。
- email token：`phone` 是否提供、提供了什么值，一律忽略，行为与 #71 合并时完全一致。

## 测试计划

在既有测试文件基础上新增用例（延续 Issue #71 的测试组织方式，不新建测试文件）：

- `internal_application_user_user_service_test_go.yaml`：
  - `TestConfirmPasswordReset_SMSChannel_CorrectPhone_Succeeds`
  - `TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError`
  - `TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError`
  - `TestConfirmPasswordReset_EmailChannel_PhoneIgnored_Succeeds`（回归：确认 email 路径不受影响）
- `internal_router_userbffservice_test_go.yaml`：补充 `phone` 字段透传的请求体断言（沿用现有 `TestPasswordResetConfirm_*` 系列的组织方式）
- `internal_infrastructure_passwordreset_repository_test_go.yaml`：无需改动（查询逻辑本身未变）

## 影响范围小结

- 改动文件：Kitex IDL（confirm 请求定义）、`internal_application_user_user_service_go.yaml`、`user-bff-hertz` 对应 handler/DTO 的 `.yaml` 模板、上述三个测试文件
- 不改动：`password_reset_tokens` 表结构、`RequestPasswordReset`、email 渠道逻辑、`admin-bff-hertz`
- 无数据库迁移
