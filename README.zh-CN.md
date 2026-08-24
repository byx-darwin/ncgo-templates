# ncgo 官方模板仓库

[English](README.md)

[ncgo](https://github.com/byx-darwin/ncgo) 的官方模板仓库 — AI 友好的 Go 微服务脚手架 CLI。

使用 ncgo 注册表客户端浏览和消费这些模板：

```bash
ncgo template list
ncgo template pull base-kitex
ncgo new my-svc --module github.com/acme/my-svc --kind kitex --template base-kitex
```

注册表 URL 默认指向本仓库；可通过 `--registry <url>` 或 `NCGO_REGISTRY` 环境变量覆盖。

## 模板列表

### HTTP 服务 (Hertz)

| 包名 | 描述 | 使用方式 |
|---|---|---|
| `base-hertz` | 标准 Hertz HTTP 服务（DDD 分层 + JWT + 签名 + 幂等性） | ✅ `ncgo new --kind hertz --template base-hertz` |
| `ratelimit-hertz` | 带限流执行的 Hertz HTTP 服务（两阶段：认证前 + 认证后） | ✅ `ncgo new --kind hertz --template ratelimit-hertz` |
| `admin-bff-hertz` | 带 RBAC 授权的 Admin BFF（JWT + Casbin + gRPC 调用权限服务） | ✅ `ncgo new --kind hertz --template admin-bff-hertz` |

### RPC 服务 (Kitex)

| 包名 | 描述 | 使用方式 |
|---|---|---|
| `base-kitex` | 标准 Kitex RPC 服务（分层布局 + 健康检查） | ✅ `ncgo new --kind kitex --template base-kitex` |
| `rbac-kitex` | RBAC + 权限认证服务（DDD、Casbin sqlc 适配器、JWT 登录、审计） | ✅ `ncgo new --kind kitex --template rbac-kitex` |
| `admin-services-kitex` | 合并的 Admin 权限服务（RBAC + 规则中心合二为一） | ✅ `ncgo new --kind kitex --template admin-services-kitex` |
| `rule-center` | 限流规则中心服务（独立版） | ⚠️ 资源就绪；建议使用合并版 `admin-services-kitex` |

### 工作区 (Micro)

| 包名 | 描述 | 使用方式 |
|---|---|---|
| `micro` | 微服务工作区参考（多服务布局 + 共享 compose/pre-commit） | ⚠️ 参考模板；使用 `ncgo add rpc/bff` 添加服务 |
| `micro-admin` | Admin 工作区组合（admin-services-kitex + admin-bff-hertz） | ⚠️ 组合包；详见 README 设置指南 |

### DDD 模式

所有服务模板遵循 DDD 分层架构：

```
internal/
├── handler/          # HTTP/gRPC 处理器 — 绑定、委托、响应
├── usecase/          # 业务逻辑 — 实现处理器接口
├── repository/       # 数据访问 — 数据库查询
├── model/            # 领域类型 — 用于非 protobuf 场景
└── pkg/response/     # 响应辅助工具（含 RPCErrorRouter）
```

**核心特性：**
- `NewResponder()` 默认启用 `RPCErrorRouter`（将 `go-common/error` 映射为 HTTP 状态码）
- JWT `Claims` 包含 `Roles []string` 字段，用于基于权限的访问控制
- 统一的 `auth.token` 配置（替代旧的 `jwt` 配置）

## 包结构

每个模板包是一个目录，包含：

```
<package>/
├── template.yaml            # 元数据：name / kind / description / version
├── <kind>-template/*.yaml   # 代码模板（与 ncgo 内置资源格式相同）
├── idl/*.proto              # 可选的变量化 IDL
└── README.md
```

通过 `ncgo export templates` 导出的包直接映射到此布局（添加 `template.yaml` + `README.md` 即可贡献）。

## 贡献指南

模板通过官方审核流程管理 — 参见 [`CONTRIBUTING.md`](CONTRIBUTING.md) 了解分支 / PR 流程。

## 相关链接

- [ncgo CLI](https://github.com/byx-darwin/ncgo) — 脚手架 CLI 工具
- [base-hertz](base-hertz/) — HTTP 服务模板
- [rbac-kitex](rbac-kitex/) — RBAC 权限服务模板
- [admin-services-kitex](admin-services-kitex/) — 合并的 Admin 权限服务
- [micro-admin](micro-admin/) — Admin 工作区组合
