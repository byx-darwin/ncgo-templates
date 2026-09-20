# Design: user-kitex 密码重置凭证原子消费（修复 TOCTOU 竞态）

**Issue:** #77
**Status:** Approved (chat, bounded path)
**Depends on:** #76（`ConfirmPasswordReset` 失败路径审计，已合并）

## Context

`internal/application/user/user_service.go` 的 `ConfirmPasswordReset` 当前时序：

```
GetValid(检查) → [SMS 分支: 查手机号] → setPassword(改密码) → MarkUsed(标记已用)
```

`passwordreset.SQLRepository.GetValid` 是一条普通 `SELECT ... WHERE used_at IS NULL AND expires_at > now()`；`MarkUsed` 是一条普通 `UPDATE ... WHERE id = $1`（不带 `used_at IS NULL` 条件，也不返回受影响行数）。`MemoryRepository` 的 `GetValid`/`MarkUsed` 各自独立加锁，未跨越整个"检查-使用-标记"序列持锁。

两个并发请求携带同一枚仍然有效的凭证，可能都先后通过 `GetValid`，都执行 `setPassword`，都能"成功"标记已用——凭证被重复兑现。真实风险评估为低（持有凭证者本来就具备完整重置能力），但修复本身直接。

## Goal

让密码重置凭证的"校验+消费"成为单一原子操作，确保并发场景下同一凭证只有一次兑现能成功。

## 设计决策：原子消费点前移

评估过两个方案：

- **方案 A（采用）**：原子消费点放在函数最前面。用一条原子 `UPDATE ... WHERE credential_hash=$1 AND used_at IS NULL AND expires_at>now() RETURNING *` 替换原来的 `GetValid`，拿到凭证即视为"已兑现"并标记 `used_at`；SMS 手机号校验、`setPassword` 都在这之后进行。
- **方案 B（放弃）**：把原子消费步骤保留在 `setPassword` 成功之后（贴近现状"仅密码真正改成功才标记已用"的语义）。但这样两个并发请求会都先通过前置的非原子读取校验、都执行 `setPassword`，只是最终谁先标记已用无法决定"只有一个请求整体成功"——不满足验收标准"两个并发调用只有一个成功"。

**结论：采用方案 A。** 代价（已与用户确认接受）：若 SMS 手机号校验失败，或 `setPassword` 本身报错（哈希/DB 层的边缘故障），凭证也会被烧掉——用户必须重新发起一次找回密码流程，而不能用同一凭证重试。这是一个刻意接受的行为变化，权衡如下：
1. Issue 明确要求"两个并发调用只有一个成功"，只有把原子消费点前移到最前面才能保证。
2. 现状已评估真实风险为低；提前烧掉凭证进一步收紧了防猜测面（一次凭证只能尝试一次），是安全性上的净改善。
3. `setPassword` 失败是边缘场景，现有测试也未覆盖失败重试路径。

## 变更范围

### 1. SQL 查询（`internal/db/query/password_reset_token.sql`）

新增一条原子消费查询，与现有 `GetValidPasswordResetToken`/`MarkPasswordResetTokenUsed` 并存（两者仍保留，供仓储测试与潜在其他调用方使用，未来若确认无其他调用方可再清理）：

```sql
-- name: ConsumeValidPasswordResetToken :one
UPDATE password_reset_tokens
SET used_at = now()
WHERE credential_hash = sqlc.arg('credential_hash')
  AND used_at IS NULL
  AND expires_at > now()
RETURNING *;
```

### 2. Repository（`internal/infrastructure/passwordreset/repository.go`）

- `Repository` 接口新增：
  ```go
  // ConsumeValid atomically validates and marks credentialHash's token as
  // used in one step, closing the TOCTOU window between check and mark
  // (Issue #77). Semantics otherwise match GetValid: any invalid case
  // (no match, used, expired) returns ErrNotFound, and a caller must not
  // distinguish these (anti-enumeration).
  ConsumeValid(ctx context.Context, credentialHash string) (Token, error)
  ```
- `SQLRepository.ConsumeValid`：调用新增的 `ConsumeValidPasswordResetToken` sqlc 查询；`pgx.ErrNoRows` → `ErrNotFound`，其余错误透传，成功时映射为 `Token`（与 `GetValid` 的映射逻辑一致）。
- `MemoryRepository.ConsumeValid`：单次 `r.mu.Lock()`/`defer Unlock()` 临界区内完成"查找匹配凭证 → 校验未用/未过期 → 置位 `UsedAt` → 写回 map → 返回副本"的完整序列，不再拆成两次独立加锁的调用。
- `GetValid`、`MarkUsed` 方法本身保留在接口与两个实现中不动（现有仓储测试继续有效），只是 `ConfirmPasswordReset` 改为不再调用它们。

### 3. Service（`internal/application/user/user_service.go`）

`ConfirmPasswordReset`：
- 首行 `s.resetRepo.GetValid(...)` 替换为 `s.resetRepo.ConsumeValid(...)`。
- 移除函数末尾原来"改密码成功后再补调 `MarkUsed`"的代码块（不再需要，凭证已在函数开头原子消费）。
- 更新函数头部注释，说明凭证在校验通过的同一时刻即被消费，SMS 校验/改密码失败也不会恢复凭证有效性（附 Issue #77 引用）。

### 4. 测试

- `internal/application/user/user_service_test.go`：现有 `ConfirmPasswordReset` 相关用例中，fake `resetRepo` 需要实现新的 `ConsumeValid`（原先配置 `GetValid` 返回值、断言 `MarkUsed` 被调用的地方，改为配置/断言 `ConsumeValid`）。
- 新增并发测试：两个 goroutine 使用同一枚有效凭证同时调用 `ConfirmPasswordReset`（基于 `MemoryRepository`），断言恰好一个返回 `nil`、另一个返回统一的 "reset credential is invalid or expired" 错误；用 `go test -race` 验证。
- `internal/infrastructure/passwordreset/repository_test.go`：为 `MemoryRepository.ConsumeValid` 补充等价的单测（有效凭证消费成功、二次消费失败、过期凭证消费失败），并视仓储测试现有基础设施决定是否需要对 `SQLRepository.ConsumeValid` 做集成测试。

## 影响范围确认

- 不跨模块边界（仅 `passwordreset` 包 + `user` 应用层的 `ConfirmPasswordReset`）。
- 不改变公开 API（RPC 签名、请求/响应结构不变）。
- 不需要新迁移（复用现有 `password_reset_tokens` 表结构，只新增一条 sqlc 查询）。
- 结论：符合 gf-workflow 的 standard 模式判定，无需升级为 full。
