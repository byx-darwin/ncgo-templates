# 第三方登录用户体系模板（user-kitex + user-bff-hertz）设计

## 背景与目标

仓库当前已有面向"运营/管理员"的账号体系（`rbac-kitex`/`admin-services-kitex` 的 RBAC 用户），但没有面向"终端产品用户"的账号体系。本次新增一对模板包，为终端用户提供：

- 本地账号密码登录（可选，与第三方绑定并存）
- 第三方登录：通用 OAuth2/OIDC、微信/支付宝等国内厂商、GitHub/Google 等国际厂商
- 管理中台（复用现有 `micro-admin`）对终端用户的管理能力（列表、封禁、强制下线）

## 范围边界

本次 workflow（`ncgo-templates` 仓库）**只交付模板资产本身**。"生成阶段按 provider 变量裁剪文件"这一能力依赖 `ncgo` CLI 生成器（`github.com/byx-darwin/ncgo`，独立仓库）新增按需生成支持，作为另一条独立 workflow 在 `ncgo` 仓库处理，不在本次范围内。本次先按仓库现有约定交付：**所有 provider adapter 代码全部生成，通过 `conf.yaml` 的 `enabled: bool` 开关控制启用**（与 `admin-bff-hertz` 的签名/幂等可选特性同一模式）。README/`template.yaml` 中注明"⚠️ 生成阶段按需选择依赖 ncgo 侧后续支持"。

## 整体架构

新增一对服务模板，延续仓库现有 kitex（RPC 领域服务）+ hertz（HTTP 网关）配对模式，对标 `rbac-kitex` + `admin-bff-hertz`：

```
终端用户 → user-bff-hertz (HTTP)  → gRPC → user-kitex (RPC) → PostgreSQL + Redis
                ↑ OAuth 回调                      ↑
运营/管理员 → admin-bff-hertz (已有) → gRPC ────────┘ （新增"用户管理"接口分组）
```

- **`user-kitex`**：终端用户账号领域服务——本地账号密码、第三方账号绑定、JWT 签发、终端用户管理类 RPC。
- **`user-bff-hertz`**：对外暴露注册、本地登录、OAuth 发起/回调、绑定/解绑 API，调用 `user-kitex`。
- 管理中台侧不新建组件：`admin-bff-hertz` 增加"终端用户管理"接口分组，内部新增一个 gRPC client 连 `user-kitex`，复用其现有 Casbin RBAC 鉴权中间件（要求运营人员具备 `user:manage` 权限）。
- `user-kitex` 的"终端用户"账号域与 `admin-services-kitex` 的"运营 RBAC 账号"域是两个独立的域，不合并、不共享用户表。

## 数据模型

`user-kitex` 单独采用**纯 UUID v7 主键**方案（与 `rbac-kitex` 的 BIGSERIAL+uuid 列模式不同，是 `rbac-kitex` 回退后仍保留的既有选型，`user-kitex` 是独立选型，不跟随）：

- `users`：`id UUID PRIMARY KEY`（应用层 `uuid.NewV7()` 生成）、用户名（可空，纯第三方登录用户可无）、密码哈希（可空）、状态（正常/封禁）、时间戳
- `user_identities`：第三方绑定表，`id UUID PRIMARY KEY`，`user_id UUID NOT NULL REFERENCES users(id)`，`(provider, provider_user_id)` 唯一索引
- `oauth_states`（Redis，短 TTL）：OAuth 流程防 CSRF 的 state 参数，value 关联发起时的 provider + redirect 信息

密码哈希：直接复用 `rbac-kitex` 现有的 `internal/infrastructure/auth/password.go`（Argon2id，`golang.org/x/crypto/argon2`，标准参数 m=65536,t=3,p=4），保持仓库内密码哈希方案统一，不重新选型。

## OAuth Provider 抽象层

`internal/pkg/oauth/` 定义统一接口：

```go
type Provider interface {
    AuthURL(state string) string
    ExchangeCode(ctx context.Context, code string) (Token, error)
    FetchUserInfo(ctx context.Context, token Token) (ProviderUserInfo, error)
}
```

`wechat`、`alipay`、`github`、`google`、`oidc`（通用 OIDC）各自一个适配器实现文件，通过 `conf.yaml` 的 `oauth.providers.<name>.enabled` 配置驱动注册。新增供应商 = 新增一个适配器文件，登录/绑定核心流程不变。

## JWT 与鉴权

`user-kitex` 签发的 JWT 复用仓库现有 `auth.token` 中间件与 `Claims{Roles []string}` 约定（与 `base-hertz`/`rbac-kitex` 完全一致），使得共用中间件无需改动。终端用户的 `Roles` 固定为 `["user"]`，与运营 RBAC 的角色体系语义上不冲突（不同的鉴权域）。

## 管理中台集成细节

`admin-bff-hertz` 新增 `internal/handler/user_admin/`：

- `ListUsers`（分页/搜索）
- `BanUser` / `UnbanUser`
- `ForceLogout`（吊销 JWT，写入 Redis 黑名单）
- `ListUserIdentities`（查看某用户绑定的第三方账号）

均要求 Casbin 策略中 `user:manage` 权限。`user-kitex` 侧新增对应管理类 RPC 方法，与终端用户自服务 RPC（`Register`/`Login`/`OAuthCallback`/`BindProvider`/`UnbindProvider`）在同一服务里按 handler 分组区分，不拆成两个 kitex 服务。

## 错误处理

复用现有 `go-common/error` + `RPCErrorRouter` 约定：

- 第三方账号已被其他用户绑定 → 409
- OAuth state 校验失败/过期 → 401
- 本地账号密码错误 → 401
- 用户被封禁 → 403

## 测试

- `user-kitex`：每个 usecase 和 provider adapter 单测，第三方 HTTP 调用通过 mock client 模拟响应；参考 `rbac-kitex/test` 现有集成测试结构
- `user-bff-hertz`：handler 层测试覆盖登录/回调/绑定流程；参考 `admin-bff-hertz/test` 结构
- `admin-bff-hertz` 新增的用户管理接口：补充对应 handler 测试

## 后续跟进（不在本次范围）

- `ncgo` 仓库：生成阶段按 `--var providers=...` 裁剪文件的能力（独立 workflow）
- 待上述能力就绪后，回到本仓库做一次小 PR，把 `user-kitex`/`user-bff-hertz` 的 provider 选择接上真正的按需生成
