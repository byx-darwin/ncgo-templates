# JWT Claims uid 字段统一（Issue #66）

## Context

`rbac-kitex`/`admin-services-kitex`/`user-kitex` 签发的 JWT 只携带 `uid` claim（`Claims{Uid string \`json:"uid"\`}`）。但 `base-hertz`/`admin-bff-hertz` 的 JWT 中间件用的 `Claims` 结构体读取的是 `UUID`（`json:"uuid"`）和从未被任何代码赋值的 `UserID`（`json:"user_id"`）——两者用真实 token 解出来永远是空字符串，因为签发端从不设置 `uuid`/`user_id` 这两个 key。

验签本身能通过（签名密钥一致），但身份字段解析结果为空，是一个从未被真实端到端流程覆盖出来的静默 bug，在实现 `user-bff-hertz`（#65）时被发现。

## 根因排查结果

- `base-hertz`/`admin-bff-hertz` 的 `Claims`：`UserID string \`json:"user_id"\``、`UUID string \`json:"uuid"\``、`AK string \`json:"ak"\``、`Roles []string`
- `rbac-kitex`/`admin-services-kitex`/`user-kitex` 的 `Claims`：`Uid string \`json:"uid"\``、`Roles []string`
- 仓库内没有任何地方给 `UserID` 字段赋值（`grep -rln "UserID:"` 全仓库零命中）——它在 `current_user` handler 和 `auth` handler 的 `Logout` 调用里被读取使用，但永远是空字符串，与 `UUID` 是同一根因（签发端从不设置 `user_id` claim）。
- `AK` 字段是独立的 API-key 鉴权路径，与本次 JWT 身份字段修复无关，不动。

## 修复方案

`base-hertz`/`admin-bff-hertz` 的 `Claims` 结构体删除 `UUID` 和 `UserID` 两个字段，合并为单一 `Uid string \`json:"uid"\``，与签发端权威格式保持一致。

### 改动文件（base-hertz + admin-bff-hertz 各一份，模板高度相似）

- `internal_pkg_middleware_jwt_go.yaml` / `internal_pkg_middleware_token_go.yaml`：`Claims` 定义 + token 解析处（`claims["uuid"]` → `claims["uid"]`）
- `internal_pkg_middleware_idempotency_go.yaml`：`claims.UUID` → `claims.Uid`
- `internal_pkg_middleware_rate_limit_go.yaml`：`claims.UUID` → `claims.Uid`
- `internal_pkg_middleware_authz_go.yaml`（仅 admin-bff-hertz）：`claims.UUID` → `claims.Uid`
- `internal_handler_current_user_go.yaml`（仅 admin-bff-hertz）：`claims.UserID` → `claims.Uid`
- `internal_handler_auth_go.yaml`（仅 admin-bff-hertz，`Logout`）：`claims.UserID` → `claims.Uid`
- 对应的 `*_test_go.yaml` 测试文件同步更新字段名

签发端（`rbac-kitex`/`admin-services-kitex`/`user-kitex`）已经是权威格式，不改动。

### 新增集成测试

用 `rbac-kitex`（或 `user-kitex`）的 `JWTManager.Sign` 真实签发一个 token，喂给 `base-hertz`（或 `admin-bff-hertz`）的 JWT 中间件，断言解出的 `Uid` 非空且等于签发时传入的值。放在 `admin-bff-hertz/test` 目录，参考现有 e2e 测试结构。

## 测试策略

TDD：先写失败测试证明当前 bug（真实签发的 token 过中间件后 `Uid` 为空），再做字段重命名让测试通过，再补充跨服务集成测试覆盖真实签发→中间件解析的完整链路。

## 范围外

- `AK` 字段（API-key 鉴权路径）不动
- 签发端（`rbac-kitex`/`admin-services-kitex`/`user-kitex`）不动
