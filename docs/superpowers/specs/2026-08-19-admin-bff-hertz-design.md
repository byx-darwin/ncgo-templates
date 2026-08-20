# admin-bff-hertz Design Spec

**Date:** 2026-08-19
**Issue:** [#12](https://github.com/byx-darwin/ncgo-templates/issues/12)
**Status:** Draft

## Overview

`admin-bff-hertz` 是 micro-admin（运营中台）项目的 admin BFF 模板——一个 thin Hertz HTTP API，作为前端与后端 RPC 服务（rbac-kitex、rule-center）之间的网关层。

**Bar:** Reference scaffold（正确的结构 + 可运行的 happy path + 文档化的 production seams）

## Scope

### BFF 职责

| 类别 | 内容 |
|------|------|
| **BFF 中间件** | JWT 解析/验证、Authz（调用 rbac-kitex Enforce RPC） |
| **Auth handlers** | `/api/v1/auth/login` `/refresh` `/logout` → 代理到 rbac-kitex AuthService |
| **RBAC 管理 handlers** | 用户/角色/权限/菜单管理 → 代理到 rbac-kitex RBACService |
| **当前用户 handlers** | `/api/v1/me/menus` 菜单树 + `/api/v1/me/perms` 按钮权限码 |
| **限流规则管理 handlers** | 限流规则 CRUD → 代理到 rule-center RuleService |
| **pkg/client** | `rbac/` (AuthService + RBACService) + `rulecenter/` (RuleService) |

### 不在 Scope

- **BFF 自身限流**：Admin 接口面向内部用户，流量可控，不需要限流
- **审计日志**：由 rbac-kitex 在 RBACService 写操作时记录，BFF 只做 thin proxy

## Architecture

### 项目结构

```
admin-bff-hertz/
├── template.yaml                    # metadata: name / kind / description / version
├── hertz-template/
│   ├── main_go.yaml
│   ├── conf_dev_yaml.yaml           # jwt.secret, rbac/rulecenter gRPC 配置
│   ├── server_go.yaml               # 中间件链 + 路由注册
│   ├── middleware/
│   │   ├── jwt_go.yaml              # JWT 解析/验证 (HS256)
│   │   └── authz_go.yaml            # RequirePermission → Enforce RPC
│   ├── handler/
│   │   ├── auth_go.yaml             # /api/v1/auth/login|refresh|logout
│   │   ├── user_go.yaml             # /api/v1/users CRUD
│   │   ├── role_go.yaml             # /api/v1/roles CRUD
│   │   ├── permission_go.yaml       # /api/v1/permissions CRUD
│   │   ├── menu_go.yaml             # /api/v1/menus (read)
│   │   ├── current_user_go.yaml     # /api/v1/me/menus + /me/perms
│   │   └── rate_limit_go.yaml       # /api/v1/rate-limit-rules CRUD
│   ├── router/
│   │   └── register_go.yaml         # 路由注册（含 RequirePermission）
│   └── pkg/client/
│       ├── rbac_go.yaml             # rbac-kitex 客户端封装
│       └── rulecenter_go.yaml       # rule-center 客户端封装
├── idl/
│   ├── auth.proto                   # 从 rbac-kitex 引用
│   └── rule_center.proto            # 从 rule-center 引用
└── README.md
```

### 中间件链

```
请求 → CORS → JWT (public paths skip) → Authz (RequirePermission) → Handler
```

**JWT middleware:**
- HS256 签名验证（与 rbac-kitex 共享 secret）
- 提取 claims（uid, roles）到 context
- Public paths 跳过：`/login`、`/healthz`、`/readyz`

**Authz middleware:**
- Handler 通过 `RequirePermission("user:create")` 设置所需权限
- 中间件从路由 metadata 获取权限要求
- 调用 rbac-kitex `Enforce(sub=uid, obj=perm_code, act=execute)`
- 拒绝时返回 403 Forbidden

### Authz 模式

```go
// router 注册
api.POST("/users", handler.CreateUser, middleware.RequirePermission("user:create"))

// authz middleware 伪代码
func Authz() app.HandlerFunc {
    return func(ctx context.Context, c *app.RequestContext) {
        perm := GetRequiredPermission(c)  // 从路由 metadata 获取
        if perm == "" { c.Next(ctx); return }
        
        claims := GetClaims(c)
        ok, err := rbacClient.Enforce(ctx, &api.EnforceRequest{
            Sub: claims.UUID,
            Obj: perm,
            Act: "execute",
        })
        if !ok { 
            response.ErrorCode(c, response.CodeForbidden)
            c.Abort()
            return 
        }
        c.Next(ctx)
    }
}
```

### pkg/client 封装

按后端服务分组（非按 proto service）：

```go
// pkg/client/rbac/client.go
type Client struct {
    auth *authservice.Client
    rbac *rbacservice.Client
}
func New(cfg Config) (*Client, error) { ... }
func (c *Client) AuthService() *authservice.Client { return c.auth }
func (c *Client) RBACService() *rbacservice.Client { return c.rbac }

// pkg/client/rulecenter/client.go  
type Client struct { ... }
func (c *Client) RuleService() *rulecenterservice.Client { ... }
```

### 配置

```yaml
# conf/dev/conf.yaml
server:
  addr: ":8888"

jwt:
  secret: "your-256-bit-secret"  # 与 rbac-kitex 共享

grpc:
  rbac:
    address: "localhost:8889"
  rule_center:
    address: "localhost:8890"
```

## Data Flow

### Login Flow

```
POST /api/v1/auth/login {username, password}
  → authHandler.Login()
    → rbacClient.AuthService().Login(ctx, req)
      → rbac-kitex 验证密码 + 生成 JWT
    ← {access_token, refresh_token, expires_in}
  ← 200 OK
```

### RBAC 管理 Flow (with Authz)

```
POST /api/v1/users {username, ...}
  → JWT middleware: 验证 token, 提取 claims
  → Authz middleware: RequirePermission("user:create")
    → rbacClient.RBACService().Enforce(ctx, {sub: uid, obj: "user:create", act: "execute"})
      → rbac-kitex 查询 Casbin 规则
    ← allowed: true
  → userHandler.CreateUser()
    → rbacClient.RBACService().CreateUser(ctx, req)
      → rbac-kitex 创建用户 + 写审计日志
    ← user
  ← 201 Created
```

### 当前用户菜单 Flow

```
GET /api/v1/me/menus
  → JWT middleware: 验证 token
  → Authz middleware: 无 RequirePermission (已登录即可)
  → currentUserHandler.GetMenus()
    → rbacClient.RBACService().GetUserMenuTree(ctx, {user_id: uid})
      → rbac-kitex 查询用户菜单树
    ← menu tree
  ← 200 OK
```

## Seams (Documented TODO, Not Built in v1)

| Seam | 描述 | 代码标记 |
|------|------|----------|
| **RS256/JWKS** | 当前 HS256，预留 RS256/JWKS 扩展点 | `// TODO(RS256)` |
| **Local Enforcer** | 当前通过 RPC 调用 Enforce，可缓存 enforcer + Redis watcher | `// TODO(local-enforcer)` |
| **OTel Observability** | 基础 wiring，启用时需配置 jaeger | `// TODO(otel)` |

## Build Method

1. `ncgo new --kind hertz --db postgres` → 基础 scaffold
2. 手写 DDD + middleware (JWT/Authz) + handlers + pkg/client
3. 手写 tests (hermetic: mock rbac/rulecenter clients)
4. `make sqlc && go build && go test` green
5. `ncgo export templates --kind hertz` → 组装 `admin-bff-hertz/`
6. 验证 `ncgo new --template admin-bff-hertz` 可构建

## Acceptance Criteria

- [ ] `admin-bff-hertz/` package: template.yaml (kind hertz) + hertz-template/* + idl + README
- [ ] JWT middleware: parse/validate, reject expired/tampered; public paths skip
- [ ] Authz middleware: RequirePermission → rbac-kitex Enforce RPC
- [ ] `/api/v1/auth/login|refresh|logout` proxied to rbac-kitex AuthService
- [ ] `/api/v1/me/menus` returns current-user menu tree + button perm codes
- [ ] RBAC management handlers (user/role/permission/menu) proxied to rbac-kitex
- [ ] Rate-limit rule management handlers proxied to rule-center
- [ ] pkg/client: rbac/ + rulecenter/ 按后端服务分组
- [ ] `ncgo new --template admin-bff-hertz && go build ./... && go test ./...` passes
- [ ] README documents seams (RS256/JWKS, local enforcer, OTel)

## Related

- ncgo #72/#73 (DDD export)
- rbac-kitex #10/#11 (authority)
- rule-center (rate-limit)
- micro-admin program design
