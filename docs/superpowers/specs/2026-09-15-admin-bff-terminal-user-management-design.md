# admin-bff-hertz 集成终端用户管理 — 设计文档（Plan 3 of 3）

## 背景

这是"微服务模版 + 管理中台 + 第三方登录用户体系"三段式工作的最后一段：

- **Plan 1**（已合并 main）：`user-kitex` — 终端用户账号 RPC 服务（本地密码 + 第三方 OAuth2/OIDC 登录，管理端 RPC：`ListUsers`/`BanUser`/`UnbanUser`/`ForceLogout`/`ListUserIdentities`/`UnbindProvider`）。
- **Plan 2**（已合并 main）：`user-bff-hertz` — 面向终端用户自己的 HTTP 网关（注册/登录/OAuth/绑定解绑）。
- **Plan 3**（本文档）：把"运营/客服在管理中台里查看和管理终端用户"这件事接进已有的 `admin-bff-hertz` 管理中台，而不是新建一套独立后台（该决策在 Plan 1 brainstorming 阶段已确认）。

## 范围

**本次包含：**
1. 终端用户列表/详情查询（`ListUsers` + `ListUserIdentities` 拼合）
2. 封禁/解封账号（`BanUser`/`UnbanUser`），封禁时自动附带强制下线（`ForceLogout`）
3. 管理员代用户强制解绑第三方身份（新增专门的 `AdminUnbindProvider` RPC，与终端用户自助解绑的 `UnbindProvider` 区分开）

**本次不包含（拆分为未来独立计划）：**
- 登录/操作审计日志查询 — `user-kitex` 目前没有任何审计日志存储/写入点/查询 RPC，是一个从零开始的子系统，工作量与前三项不是一个量级，用户已确认拆分。

## 与现有资源的命名冲突

`admin-bff-hertz` 已有一套 `/api/v1/users` + `user:list/read/create/update/delete` 权限，管理的是**后台管理员账号**（走 `rbacservice`）。Plan 3 管理的是 `user-kitex` 的**终端 C 端用户**，是完全不同的资源，必须避免撞名：

- 路由前缀：`/api/v1/terminal-users`（而非 `/users`）
- 权限码：`terminal_user:list` / `terminal_user:read` / `terminal_user:ban` / `terminal_user:unban` / `terminal_user:unbind-identity`

权限码不需要数据库迁移——沿用 `rate_limit:*` 的先例，权限本身只是字符串约定，由 `RequirePermission(code)` 在 BFF 层校验，实际授权通过现有的 Permission 管理 API（`/api/v1/permissions`）手动创建、分配给角色。

## user-kitex 的小幅扩展：新增 `AdminUnbindProvider` RPC

`user-kitex` 现有的 `UnbindProvider(uid, provider)` 是为"已认证的终端用户自助解绑"设计的——虽然 proto 字段本身不限制传入任意 uid，但语义上这是终端用户自助操作的 RPC，混用会让审计和权限边界变得模糊。管理员代第三方用户强制解绑，是另一种信任模型（服务间调用 + RBAC 授权，而非"调用者对自己的 uid 做操作"），因此新增一个独立的 RPC：

```protobuf
message AdminUnbindProviderReq {
  // uid is the target end-user, specified by an admin operator via
  // admin-bff-hertz. Trust boundary: admin-bff-hertz's own RBAC
  // authorization (terminal_user:unbind-identity permission) gates this
  // call — user-kitex does not re-verify the caller's identity, matching
  // the existing admin RPC surface (BanUser/UnbanUser/ForceLogout/ListUsers
  // already work this way: no per-call caller-identity check, trust is
  // placed in the calling BFF having already authorized the operator).
  string uid = 1;
  string provider = 2;
}
message AdminUnbindProviderResp {}
```

`service UserService` 新增一行：`rpc AdminUnbindProvider(AdminUnbindProviderReq) returns (AdminUnbindProviderResp);`

Service 层复用现有 `UnbindProvider` 的核心解绑逻辑（同一个 usecase 函数，两个 handler 入口），避免重复实现。

## admin-bff-hertz 的集成

**新增 RPC 客户端**：`admin-bff-hertz/idl/user.proto`（拷贝自 `user-kitex/idl/user.proto`，含新增的 `AdminUnbindProvider`），复用 Plan 2 已验证的生产接线方式——`ncgo add kitex-client terminaluser --service UserService --idl idl/user.proto` 在生成时本地产出 `kitex_gen/api/user/v1/userservice`，与 `user-kitex` 项目完全解耦（这是 Plan 2 Task 9 踩过坑、独立验证过的正确生产路径，不是猜测）。

**新增 handler**：`internal/handler/terminal_user.go`
- `List(ctx)` → 调 `ListUsers(limit, offset)`，返回分页列表
- `Get(ctx)` → 调 `ListUsers` 过滤单条（或视情况直接遍历，因为 `user-kitex` 没有单独的 `GetUser` RPC）+ `ListUserIdentities(uid)`，拼成详情视图（用户资料 + 绑定的第三方身份列表）
- `Ban(ctx)` → 依次调 `BanUser(uid)` 后 `ForceLogout(uid)`（用户已确认：封禁自动踢下线；`ForceLogout` 失败时的处理策略——是否让整个请求失败——留给实现任务时读 `ForceLogout` 已有的 no-op 降级设计后决定，不阻塞设计）
- `Unban(ctx)` → 调 `UnbanUser(uid)`
- `UnbindIdentity(ctx)` → 调新增的 `AdminUnbindProvider(uid, provider)`

**路由**（`internal_router_adminbffservice_go.yaml` 追加）：
```
terminalUsers := protected.Group("/terminal-users")
terminalUsers.GET("", middleware.RequirePermission("terminal_user:list"), terminalUserHandler.List)
terminalUsers.GET("/:uid", middleware.RequirePermission("terminal_user:read"), terminalUserHandler.Get)
terminalUsers.POST("/:uid/ban", middleware.RequirePermission("terminal_user:ban"), terminalUserHandler.Ban)
terminalUsers.POST("/:uid/unban", middleware.RequirePermission("terminal_user:unban"), terminalUserHandler.Unban)
terminalUsers.DELETE("/:uid/identities/:provider", middleware.RequirePermission("terminal_user:unbind-identity"), terminalUserHandler.UnbindIdentity)
```

**Server 接线**：`Register{{.ServiceName}}BffServiceRoutes` 的签名新增一个 `userCli userservice.Client` 参数；`server.go` 按 Plan 2 已验证的模式构造该客户端（`userservice.NewClient(cfg.RPC.TerminalUserService.ServiceName, client.WithHostPorts(...))`），`conf.go` 新增对应的 `RPC.TerminalUserService` 配置段。

## 测试与验收标准

沿用 Plan 1/2 建立的规范：
- 每个任务用真实 `ncgo new --template-dir` + `ncgo add kitex-client`（这次两个：一个给现有 `authservice`/`rbacservice`/`ruleservice` 走的老 idl，一个新增的 `user.proto`）+ `go build/vet/test/race` 全量验证，不用"跨渲染拷贝 kitex_gen"这种测试捷径。
- `AdminUnbindProvider` 需要一个测试验证：不接受来自 HTTP 请求体的任意 uid 覆盖 RBAC 已授权范围之外的操作（即信任边界测试——虽然 `user-kitex` 侧不做身份校验，但 `admin-bff-hertz` 侧的 `RequirePermission` 中间件必须先于 handler 执行，需要路由测试覆盖，参照 Plan 2 Task 9 fix round 的 `bind-callback` 教训，不能只做 handler 单测）。
- README 补充 `terminal_user:*` 权限码说明（沿用 `rate_limit:*` 权限码的文档先例）。

## 已知遗留 / Seams

- 审计日志查询：拆分为未来独立计划（用户已确认）。
- `ForceLogout` 在 Redis 未启用时是 no-op（`noopBlacklist`），封禁后"自动踢下线"这个承诺在无 Redis 环境下不完全生效——沿用 `user-kitex` 已有的设计权衡，只需要在 `admin-bff-hertz` 的 README 里同样说明这个限制，不在本计划范围内解决。
