# user-bff-hertz 设计（Plan 2 of 3）

## 背景与目标

`user-kitex`（Plan 1）已交付并合入 `main`：提供终端用户账号领域服务的 RPC 能力（本地注册/登录、第三方 OAuth 登录/绑定/解绑、管理端 RPC）。但 RPC 服务不能直接被浏览器/前端调用。本次新增 `user-bff-hertz`：一个 HTTP 网关模板，把 `user-kitex` 的能力翻译成浏览器友好的 REST API，遵循仓库里 `admin-bff-hertz`（HTTP BFF）+ `admin-services-kitex`（RPC 权威服务）的既有配对模式。

## 范围边界

本次交付 `user-bff-hertz` 模板本身，以及对已合并的 `user-kitex` 的一处小扩展（OAuth state payload 增加可选 `uid` 字段，见下文）。`admin-bff-hertz` 的终端用户管理接口集成属于 Plan 3，不在本次范围内。

## 整体架构

```
浏览器/前端 SPA
  │
  ├─ POST /auth/register                                         (JSON)
  ├─ POST /auth/login                                             (JSON)
  ├─ GET  /auth/oauth/:provider/start                             → 302 第三方授权页
  ├─ GET  /auth/oauth/:provider/callback                          → 302 回前端，带一次性 code
  ├─ POST /auth/oauth/exchange        { code }                    (JSON，兑换真正的 JWT)
  ├─ GET  /auth/oauth/:provider/bind-start     [JWT 鉴权]         → 302 第三方授权页
  ├─ GET  /auth/oauth/:provider/bind-callback                     → 302 回前端
  └─ DELETE /auth/oauth/:provider/bind          [JWT 鉴权]        (JSON)
       ↓ gRPC
  user-kitex（已合并，本次做一处小扩展）
```

`user-bff-hertz` 自己维护一份**一次性 code → JWT** 的短命映射（Redis，TTL 60 秒，单次消费，与 `user-kitex` 内部的 OAuth CSRF state 机制完全独立、互不影响）：OAuth 登录回调在 `user-kitex` 侧完成账号创建/登录并拿到 JWT 后，`user-bff-hertz` 生成一个 code、把 `code -> JWT` 写入 Redis，然后 302 带 code 回前端配置的 `redirect_uri`；前端立即用 `POST /auth/oauth/exchange` 换真正的 JWT。这样 JWT 本身不会出现在 URL 里（避免浏览器历史/Referrer/服务端访问日志泄露）。

## 对 `user-kitex` 的扩展

`oauth.StateStore` 的 payload（当前已携带 `provider`/`purpose`）新增可选 `uid` 字段：

- 登录流程（`OAuthStart`）：`uid` 留空。
- 绑定流程：`user-bff-hertz` 的 `bind-start` 调用同一个 `OAuthStart` RPC，但请求体新增一个可选 `uid` 字段（从当前请求已验证的 JWT 中取，`user-bff-hertz` 侧的 JWT 中间件已经做了这一步鉴权）。`uid` 非空时，`OAuthStart` 按 `purpose="bind"` 处理并把 `uid` 一并存进 state。
- `OAuthCallback`/`BindProvider` 消费 state 时，若 `purpose="bind"`，直接从 state 里取出 `uid` 使用，**不再依赖客户端在请求体里显式传 `uid`**。

这个改动同时修补了 Plan 1 最终审查遗留的 I4（uid 信任边界未强制）——原来 `BindProviderReq.uid`/`UnbindProviderReq.uid` 是客户端可控字段，只在文档里警告"调用方必须从已验证 JWT 注入"；绑定流程改造后，`uid` 从服务端自己维护的 state 里取，不再信任客户端传入的绑定用的 uid 字段（`UnbindProviderReq.uid` 仍是客户端字段，因为解绑走 JWT 鉴权后的直接 JSON 调用，`user-bff-hertz` 的 JWT 中间件已验证身份，可以放心从验证后的上下文取 uid 再转发，不存在同样的信任问题）。

## 中间件

- **CORS**：前端 SPA 跨域访问必需。
- **JWT 鉴权**：复用 `base-hertz`/`admin-bff-hertz` 现有的 `Authorization: Bearer <token>` 中间件约定与 `Claims{Uid, Roles}` 格式（`user-kitex` 签发的 JWT 与此完全兼容）。仅保护 `bind-start`/`bind-callback`（发起时需要）/`DELETE bind` 三个接口；注册/登录/OAuth 登录流程/`exchange` 本身不需要（用户还没登录）。
- **幂等性**：复用 `admin-bff-hertz` 的幂等性中间件，挂在 `POST /auth/register` 上（防止网络重试导致重复注册请求打到后端两次）。
- **限流**：复用 `admin-bff-hertz` 那套基于 `rule-center` 动态规则的限流中间件（而非自包含的简单实现），挂在 `POST /auth/login`、`POST /auth/register` 上防爆破。这意味着 `user-bff-hertz` 与 `admin-bff-hertz` 一样，需要对 `rule-center` 建立 gRPC 依赖——这是本次设计里唯一让 `user-bff-hertz` 依赖 `user-kitex` 之外的另一个服务的地方，权衡后接受，因为限流阈值统一在管理中台配置，比写死在代码里更符合仓库现有的运营心智。
- **不包含**：API 签名中间件（终端用户公开 API 通常不需要）。

## 数据流：三条关键路径

1. **本地注册/登录**：`user-bff-hertz` handler 直接把 JSON body 映射到 `user-kitex` 的 `Register`/`Login` RPC 请求，RPC 返回值原样映射为 JSON 响应（`{uid, token}`）。
2. **OAuth 登录**：`start` 调用 `user-kitex.OAuthStart(provider)` 拿到 `redirect_url`，302 过去；`callback` 调用 `user-kitex.OAuthCallback(provider, state, code)` 拿到 `{uid, token}`，`user-bff-hertz` 生成一次性 code 存入自己的 Redis，302 回前端；`exchange` 用 code 查 Redis 换出 JWT 返回给前端，同时删除该 code（单次消费）。
3. **绑定/解绑**：`bind-start` 先过 JWT 中间件拿到 `uid`，调用扩展后的 `OAuthStart(provider, uid)`；`bind-callback` 调用 `user-kitex.OAuthCallback`（走 `purpose="bind"` 分支，内部转发到 `BindProvider` 语义，`uid` 从 state 取）；成功后 302 回前端一个确认页面/参数（不需要再兑换 JWT，因为用户已经登录，绑定动作本身不产生新 token）。`DELETE bind` 直接透传 JWT 中间件解出的 `uid` + provider 给 `user-kitex.UnbindProvider`。

## 错误处理

复用现有 `RPCErrorRouter` 约定，把 `user-kitex` 的 RPC 错误映射为对应 HTTP 状态码（如"invalid credentials"→401，"username already taken"→409）。`exchange` 接口的 code 不存在/已消费/过期统一返回 401（不区分具体原因，避免给攻击者可枚举的信息）。

## 测试

Handler 层测试覆盖注册/登录/OAuth 发起-回调-兑换/绑定-解绑全流程，参考 `admin-bff-hertz/test` 的现有结构（mock `user-kitex` 的 gRPC client）。一次性 code 存取逻辑单独测试（生成、消费、重复消费失败、过期）。
