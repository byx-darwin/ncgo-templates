# ConfirmPasswordReset 失败路径审计设计

- Issue: #76 — user-kitex: ConfirmPasswordReset failure path has no audit trail
- 分类: bounded（改动集中在既有函数的失败分支 + 一个测试，无跨模块/架构影响）
- 状态: approved

## 背景

`setPassword` 的旧密码校验失败路径会写入 `user.password_change.failure` 审计条目
（模仿 `auth.login.failure`），使暴力破解尝试在审计中可见。但 `ConfirmPasswordReset`
（忘记密码/短信重置确认路径）的所有失败分支目前**完全不写审计**。

结合 #75（SMS 验证码缺乏账号级绑定），针对 SMS 重置码的分布式暴力破解目前不会
留下任何审计信号，安全监控无法据此告警。

## 目标

在不削弱反枚举保证的前提下，让 `ConfirmPasswordReset` 的失败路径在审计中可见：
- 调用方可见的响应内容和可观察时序都不能变化
- 审计条目本身也不能区分具体失败原因（同一个 Action 字符串，不带原因相关的
  `DetailJSON`）

## 现状（探索结果）

`internal/application/user/user_service.go`
（对应模板 `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`）
中 `ConfirmPasswordReset` 有 4 个凭证校验失败分支，均无审计写入：

1. `resetRepo.GetValid` 失败 —— token 不存在/过期/已使用（`ErrNotFound` 或其他错误）。
   此时**不知道用户是谁**（token 查找本身失败）。
2. SMS 渠道但 `phone == ""`。此时已经从 `resetRepo.GetValid` 拿到了 `tok`，
   即 `tok.UserID` **已知**。
3. SMS 渠道下 `repo.GetByID(ctx, tok.UserID)` 查用户失败。`tok.UserID` 已知。
4. SMS 渠道下 `u.Phone != phone`（手机号不匹配）。`tok.UserID` 已知。

对照组 `setPassword`：
```go
_ = s.audit.Write(ctx, audit.Entry{ActorUID: uid, Action: "user.password_change.failure", IPAddress: clientIP, UserAgent: userAgent})
```
`audit.Entry` 结构（`internal/infrastructure/audit/writer.go`）：
`ActorUID, Action, Target, IPAddress, UserAgent, DetailJSON, CreatedAt`。
`Action` 是普通字符串字面量，代码库中没有集中的常量/枚举定义。

## 设计

在上述 4 个失败分支各自的 `return errors.New(...)` **之前**，插入一次
`_ = s.audit.Write(ctx, audit.Entry{...})` 调用，与 `setPassword` 保持一致的
fire-and-forget 语义（丢弃 `Write` 的错误返回值，不阻塞、不改变返回时机）。

- **Action**：4 个分支统一使用字面量 `"user.password_reset_confirm.failure"`，
  不因分支不同而变化，也不附带说明失败原因的 `DetailJSON`。
- **ActorUID / Target**（已与用户确认，选定方案 A）：
  - 分支 1（token 查找失败，用户身份未知）：`ActorUID`/`Target` 留空。
  - 分支 2/3/4（SMS 渠道，`tok.UserID` 已知）：`ActorUID: tok.UserID.String()`
    （`Target` 同样填 `tok.UserID.String()`，与 `setPassword` 现有写法一致，
    即 target 缺省回退为 actor 自身）。
- **IPAddress / UserAgent**：`ConfirmPasswordReset` 当前签名没有这两个参数
  （对照 `setPassword` 是由上层 handler 传入 `clientIP`/`userAgent`）。本次改动
  范围内不新增参数改造调用链——沿用现状留空字符串，与 issue 验收标准（只要求
  "写入审计条目 + 不泄露原因"）不冲突。若后续需要 IP/UA，可作为独立 issue 跟进。
- **不在 scope 内**：`setPassword` 内部失败（例如新密码格式非法）不属于"凭证失败"，
  维持现状不新增审计；`resetRepo.MarkUsed` 失败（发生在密码已修改成功之后）也不
  属于本次范围。

## 测试

在 `internal/application/user/user_service_test.go`
（模板 `internal_application_user_user_service_test_go.yaml`）现有的失败路径测试中
追加审计断言，或新增一个聚合测试：

- 对 4 个失败场景（未知/过期凭证、SMS 缺手机号、SMS 用户查找失败、SMS 手机号不匹配）
  分别断言：
  - `len(aw.Entries()) == 1`
  - `aw.Entries()[0].Action == "user.password_reset_confirm.failure"`
  - `DetailJSON` 不包含任何区分具体失败原因的信息（例如断言其为空或不包含
    "expired"/"reused"/"phone" 等字样）
- 对分支 2/3/4，额外断言 `ActorUID == tok.UserID.String()`（需要测试从
  `passwordreset.MemoryRepository` 先创建 token 拿到已知 UID）。
- 对分支 1，额外断言 `ActorUID == ""`。
- 复用现有 `newTestServiceWithReset()` 测试基建（已提供 `*audit.MemoryWriter`）。

## 影响范围

- `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`
  （`ConfirmPasswordReset` 函数体）
- `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`
  （新增/追加测试断言）

不改变对外 API、响应结构或时序；`audit.Writer` 接口和 `Entry` 结构不变。
