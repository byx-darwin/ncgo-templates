# Investigation: ncgo base-hertz DDD 模式 & response.go 使用

**Workflow**: wf-2026-08-24-001
**Date**: 2026-08-24
**Status**: Complete

## 调查问题

1. ncgo 调用 base-hertz 模板生成的项目是否遵循 ncgo DDD 模式？
2. HTTP 回复是否调用 `github.com/byx-darwin/go-tools/go-framework/hertz/response.go`？
3. 参考 `/Users/xs/Documents/workspce/xiaosuan/iproost/proxy/api-src/services/edge-bff` 代码模式

## 调查结果

### Q1: base-hertz 生成项目是否遵循 ncgo DDD 模式？

**结论：✅ 是，遵循 ncgo DDD 分层模式**

base-hertz 模板生成的项目目录结构：

```
internal/
├── base/                 # 基础设施层
│   ├── conf/            # 配置加载
│   ├── data/            # 数据连接（postgres, redis）
│   └── server/          # 服务器启动 & DDD 装配
├── handler/             # 接口层（HTTP handlers）
│   ├── pb/              # Protobuf 自动生成的 handler
│   ├── health/          # 健康检查
│   └── resource.go      # 资源 CRUD 模板
├── pkg/                 # 公共包
│   ├── middleware/      # 中间件（JWT/CORS/签名/幂等）
│   ├── response/        # 响应助手（包装 framework）
│   ├── errcode/         # 错误码定义
│   └── i18n/            # 国际化
├── repository/          # 仓储层
│   └── rate_limit_rule.go
└── router/              # 路由层
```

**DDD 分层证据**：

1. **Handler 层明确委托给 UseCase**：
   `internal_handler_pb_{{ToLower_ServiceName}}_service_go.yaml` 模板：
   ```go
   type Handler struct {
       uc useCase  // 业务逻辑接口
   }
   type useCase interface {
       Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error)
   }
   ```
   Handler 不处理业务逻辑，仅 bind → delegate → respond。

2. **server.go 有 DDD 装配标记**：
   ```go
   // ncgo:wire:ddd — Wire DDD layers (data -> repository -> usecase)
   ```
   通过 `samber/do` 依赖注入容器装配 data → repository → usecase。

3. **分层职责清晰**：
   - Handler: HTTP 协议适配（Bind/Validate → usecase → response）
   - UseCase: 业务逻辑编排（调用 repository 或 RPC）
   - Repository: 数据访问抽象
   - Data: 数据库连接池管理
   - Base/Server: 启动装配

**与 edge-bff 参考代码对比**：

edge-bff 目录结构（更完整的 DDD 实现）：
```
internal/
├── base/           ├── handler/         ├── model/
├── usecase/        ├── repository/      ├── db/
├── pkg/            ├── router/          └── pb/
```

admin-bff-hertz（base-hertz 生成）与 edge-bff 的关键差异：

| 特征 | base-hertz 生成 | edge-bff 参考 |
|------|----------------|---------------|
| handler → usecase 委托 | ✅ 有（模板定义 useCase 接口） | ✅ 有（DeviceService） |
| repository 层 | ✅ 有（rate_limit_rule） | ✅ 有（device/, telemetry/） |
| model 层 | ❌ 模板未生成（用 pb 代替） | ✅ 有（internal/model/） |
| usecase 模板 | ❌ 无（需开发者创建） | ✅ 有（device_service.go） |
| DB 层（db/migrations 等） | ✅ base/data 提供连接 | ✅ 有完整 db/ 目录 |

**结论**：base-hertz 遵循 ncgo DDD 骨架模式，handler → usecase → repository → data 分层清晰。但 usecase 目录和 model 目录需要开发者自行创建（模板仅定义了 useCase 接口供实现）。edge-bff 是一个更成熟的 DDD 实例。

---

### Q2: HTTP 回复是否调用 go-tools/go-framework/hertz/response.go？

**结论：✅ 是，间接调用（通过生成代码的 wrapper）**

**调用链**：

```
Handler code (e.g. admin-bff-hertz)
  └── response.OK(c, resp)           # 调用生成的 internal/pkg/response/
      └── hertzframework.Success()   # 调用 go-tools/go-framework/hertz
          └── defaultResponder.Success()   # Responder 实例方法
              └── r.reply() → r.writeResponse() → c.JSON/c.ProtoBuf
```

**生成代码的 response.go 内容**：

```go
package response

import (
    hertzframework "github.com/byx-darwin/go-tools/go-framework/hertz"
    // ...
)

// NewResponder 创建框架 Responder 实例
func NewResponder() *hertzframework.Responder {
    return hertzframework.NewResponder()
}

// OK 便捷函数 → 调用框架
func OK(c *app.RequestContext, data any) {
    hertzframework.Success(c, data)
}

// Err 便捷函数 → 调用框架
func Err(c *app.RequestContext, err error) {
    hertzframework.Error(context.Background(), c, err, "")
}

// BindError 便捷函数 → 调用框架
func BindError(c *app.RequestContext, err error) {
    hertzframework.Error(context.Background(), c, err, "bind_error")
}
```

**go-tools/go-framework/hertz/response.go 提供的核心能力**：

1. `Responder` 结构体 — 持有配置（debug, translator, errorRouter, reqID 等）
2. `Middleware()` — 注入 RequestID / Lang / Responder 到上下文
3. `Success/Error/Reply` — 统一响应格式（JSON/Protobuf 内容协商）
4. `ErrorRouter` 接口 — RPC 错误到 HTTP 响应的路由映射
5. `Translator` 接口 — i18n 翻译支持
6. 包级便捷函数 `Success/Error/Reply` — 使用默认 Responder

**与 edge-bff 参考代码对比**：

edge-bff 的 response.go 使用完全相同的模式：
```go
package response

import (
    hertzframework "github.com/byx-darwin/go-tools/go-framework/hertz"
)

func NewResponder() *hertzframework.Responder {
    return hertzframework.NewResponder(
        hertzframework.WithErrorRouter(&hertzframework.RPCErrorRouter{}),
    )
}

func OK(c *app.RequestContext, data any) {
    hertzframework.Success(c, data)
}

func Err(c *app.RequestContext, err error) {
    hertzframework.Error(context.Background(), c, err, "")
}

func BindError(c *app.RequestContext, err error) {
    hertzframework.Error(context.Background(), c, err, "bind_error")
}
```

**唯一差异**：edge-bff 在 `NewResponder()` 中启用了 `WithErrorRouter(&RPCErrorRouter{})`，而 base-hertz 模板默认未启用。这是因为 edge-bff 是 BFF 服务需要处理 RPC 错误路由。

---

### Q3: 与 edge-bff 参考代码的模式一致性

| 模式 | base-hertz 模板 | edge-bff 参考 | 一致？ |
|------|----------------|---------------|--------|
| Handler → UseCase 委托 | ✅ `h.uc.Ping(ctx, &req)` | ✅ `h.deviceService.Register(ctx, &req)` | ✅ |
| response.OK/Err/BindError | ✅ 相同签名 | ✅ 相同签名 | ✅ |
| go-framework/hertz 调用 | ✅ `hertzframework.Success/Error` | ✅ `hertzframework.Success/Error` | ✅ |
| 错误码定义方式 | ✅ `frameworkerror.Code*` 复用 | ✅ `frameworkerror.Code*` 复用 | ✅ |
| goerror 包装 | ✅ `goerror.In().Code().Public().Errorf()` | ✅ `goerror.In().Code().Public().Wrap()` | ✅ |
| DDD 分层 | ✅ handler/repo/data | ✅ handler/usecase/repo/db/model | ✅ |
| Middleware 装配 | ✅ responder.Middleware() | ✅ responder.Middleware() | ✅ |

## 总结

1. **ncgo base-hertz 生成的项目完全遵循 ncgo DDD 模式**
   - 清晰的分层：interface (handler) → application (usecase) → domain (repository) → infrastructure (data)
   - 依赖方向正确：handler 依赖 usecase 接口，usecase 实现由外部注入
   - server.go 通过 `samber/do` DI 容器装配各层

2. **HTTP 回复统一使用 `go-tools/go-framework/hertz/response.go`**
   - 生成代码的 `internal/pkg/response/response.go` 是对框架的薄包装
   - 添加了项目级别的错误码定义和 HTTP 状态映射
   - 核心响应逻辑（Success/Error/Reply）委托给框架

3. **与 edge-bff 参考代码模式高度一致**
   - 相同的 handler → service 委托模式
   - 相同的 response.OK/Err/BindError 使用方式
   - 相同的 go-framework/hertz 底层调用
   - 差异仅在于 edge-bff 额外配置了 RPCErrorRouter 和完整的 usecase 实现

## 可能的改进方向（非本次调查范围）

1. base-hertz 模板可考虑添加 usecase 目录脚手架模板
2. 可考虑默认启用 `WithErrorRouter(&RPCErrorRouter{})` 在 BFF 类型服务中
3. 可考虑添加 `internal/model/` 模板用于非 protobuf 场景
