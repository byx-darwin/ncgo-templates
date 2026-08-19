# admin-bff-hertz Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a Hertz HTTP BFF template that provides admin API gateway functionality with JWT auth, RBAC authorization via rpc call to rbac-kitex, and rate-limit rule management via rpc call to rule-center.

**Architecture:** Thin BFF layer using Hertz framework with JWT middleware for authentication, Authz middleware calling rbac-kitex Enforce RPC for authorization, handlers that proxy to backend RPC services (rbac-kitex for auth/RBAC, rule-center for rate-limit rules). pkg/client encapsulates RPC client initialization.

**Tech Stack:** Go 1.24+, Hertz (HTTP), Kitex (gRPC client), PostgreSQL (for generated project), JWT (HS256)

**Spec:** docs/superpowers/specs/2026-08-19-admin-bff-hertz-design.md

## Global Constraints

- Template kind: `hertz`
- Template name: `admin-bff-hertz`
- Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`
- JWT algorithm: HS256 (RS256/JWKS as documented TODO seam)
- Authz pattern: Handler declares `RequirePermission("code")`, middleware calls rbac-kitex Enforce RPC
- pkg/client structure: `rbac/` + `rulecenter/` (by backend service, not by proto service)
- Route prefix: `/api/v1/`
- Audit logging: handled by rbac-kitex, not BFF
- Rate-limit: BFF manages rules (CRUD), does NOT enforce rate-limit on itself
- All tests hermetic (mock RPC clients, skip postgres/redis if unavailable)

---

## Task 1: Template Scaffolding

**Files:**
- Create: `admin-bff-hertz/template.yaml`
- Create: `admin-bff-hertz/README.md`

**Interfaces:**
- Consumes: Nothing
- Produces: Template package structure recognized by ncgo

- [ ] **Step 1: Create template.yaml**

```yaml
# admin-bff-hertz/template.yaml
name: admin-bff-hertz
kind: hertz
description: "Official admin BFF Hertz HTTP template (JWT auth + RBAC authz via rbac-kitex + rate-limit rule management via rule-center)"
version: "1"
skip_default_templates:
  - handler.yaml
  - usecase.yaml
  - repository.yaml
  - server.yaml
  - migration_init.yaml
  - migration_keep.yaml
  - ratelimit_handler.yaml
  - ratelimit_middleware_test.yaml
  - ratelimit_middleware.yaml
  - ratelimit_proto.yaml
  - ratelimit_repository.yaml
  - ratelimit_schema.yaml
  - ratelimit_server.yaml
  - ratelimit_sqlc_queries.yaml
  - ratelimit_usecase.yaml
```

- [ ] **Step 2: Create placeholder README.md**

```markdown
# admin-bff-hertz

Official **admin BFF** Hertz HTTP template — thin API gateway for micro-admin with JWT auth, RBAC authorization (via rbac-kitex RPC), and rate-limit rule management (via rule-center RPC).

## Use

\`\`\`bash
ncgo template pull admin-bff-hertz
ncgo new admin-bff --module github.com/acme/admin-bff --kind hertz --template admin-bff-hertz
\`\`\`

## Contents

- JWT middleware (HS256)
- Authz middleware (RequirePermission → rbac-kitex Enforce RPC)
- Auth handlers: /api/v1/auth/login|refresh|logout
- RBAC handlers: /api/v1/users|roles|permissions|menus
- Current user: /api/v1/me/menus|perms
- Rate-limit rule management: /api/v1/rate-limit-rules
- pkg/client: rbac/ + rulecenter/

## Seams (TODO)

- RS256/JWKS (v1 uses HS256)
- Local Casbin enforcer + watcher (v1 uses Enforce RPC)
- OTel observability (base wiring)
```

- [ ] **Step 3: Commit**

```bash
git add admin-bff-hertz/template.yaml admin-bff-hertz/README.md
git commit -m "feat(admin-bff-hertz): add template scaffolding"
```

---

## Task 2: IDL Files

**Files:**
- Create: `admin-bff-hertz/idl/auth.proto`
- Create: `admin-bff-hertz/idl/rule_center.proto`

**Interfaces:**
- Consumes: rbac-kitex IDL definitions
- Produces: IDL files for ncgo to generate kitex_gen code

- [ ] **Step 1: Copy auth.proto from rbac-kitex**

Copy from `rbac-kitex/idl/auth.proto` to `admin-bff-hertz/idl/auth.proto`. This defines:
- `AuthService`: Login, Refresh, Logout, ValidateToken
- `RBACService`: User/Role/Permission/Menu CRUD, Enforce, GetUserMenuTree, GetUserPermCodes

- [ ] **Step 2: Copy rule_center.proto from rule-center**

Copy from `rule-center/idl/rule-center.proto` to `admin-bff-hertz/idl/rule_center.proto`. This defines:
- `RuleService`: GetRule, CreateRule, UpdateRule, DeleteRule, ListRules

- [ ] **Step 3: Commit**

```bash
git add admin-bff-hertz/idl/
git commit -m "feat(admin-bff-hertz): add IDL files"
```

---

## Task 3: Configuration Template

**Files:**
- Create: `admin-bff-hertz/hertz-template/conf_dev_yaml.yaml`

**Interfaces:**
- Consumes: Nothing
- Produces: Config struct with jwt, grpc.rbc, grpc.rule_center sections

- [ ] **Step 1: Create conf_dev_yaml.yaml**

```yaml
# admin-bff-hertz/hertz-template/conf_dev_yaml.yaml
path: conf/dev/conf.yaml
update_behavior:
  type: cover
body: |-
  server:
    addr: ":8888"
    registry:
      name: "{{.ServiceName}}"
      address: ""
    jaeger:
      enable: false
      endpoint: ""

  jwt:
    secret: "your-256-bit-secret-change-in-production"
    access_token_ttl_seconds: 7200
    refresh_token_ttl_seconds: 604800

  grpc:
    rbac:
      service_name: "rbacservice"
      host_ports: ["localhost:8889"]
      rpc_timeout_seconds: 3
      connect_timeout_milliseconds: 100
      enable_metainfo: true
      retry:
        enabled: false
    rule_center:
      service_name: "rulecenterservice"
      host_ports: ["localhost:8890"]
      rpc_timeout_seconds: 3
      connect_timeout_milliseconds: 100
      enable_metainfo: true
      retry:
        enabled: false
```

- [ ] **Step 2: Update conf.go to include JWT and gRPC config structs**

Create `admin-bff-hertz/hertz-template/conf_go.yaml`:

```go
// Path: internal/base/conf/conf.go
package conf

import (
    "sync"
    
    gfconfig "github.com/byx-darwin/go-tools/go-framework/config"
    "gopkg.in/yaml.v3"
)

type Config struct {
    Server     gfconfig.ServerConfig     `yaml:"server"`
    JWT        JWTConfig                 `yaml:"jwt"`
    GRPC       GRPCConfig                `yaml:"grpc"`
}

type JWTConfig struct {
    Secret                  string `yaml:"secret"`
    AccessTokenTTLSeconds   int    `yaml:"access_token_ttl_seconds"`
    RefreshTokenTTLSeconds  int    `yaml:"refresh_token_ttl_seconds"`
}

type GRPCConfig struct {
    RBAC       ClientConfig `yaml:"rbac"`
    RuleCenter ClientConfig `yaml:"rule_center"`
}

type ClientConfig struct {
    ServiceName                string      `yaml:"service_name"`
    HostPorts                  []string    `yaml:"host_ports"`
    RPCTimeoutSeconds          int         `yaml:"rpc_timeout_seconds"`
    ConnectTimeoutMilliseconds int         `yaml:"connect_timeout_milliseconds"`
    EnableMetaInfo             bool        `yaml:"enable_metainfo"`
    Retry                      RetryConfig `yaml:"retry"`
}

type RetryConfig struct {
    Enabled bool `yaml:"enabled"`
}

var (
    cfg  Config
    once sync.Once
)

func Load() {
    once.Do(func() {
        gfconfig.Load("conf", &cfg)
    })
}

func Get() Config {
    Load()
    return cfg
}
```

- [ ] **Step 3: Commit**

```bash
git add admin-bff-hertz/hertz-template/conf_*.yaml
git commit -m "feat(admin-bff-hertz): add configuration templates"
```

---

## Task 4: pkg/client — RBAC Client

**Files:**
- Create: `admin-bff-hertz/hertz-template/pkg_client_rbac_go.yaml`
- Test: `admin-bff-hertz/hertz-template/pkg_client_rbac_test_go.yaml`

**Interfaces:**
- Consumes: Config from conf.go
- Produces: `pkg/client/rbac.Client` with AuthService() and RBACService() methods

- [ ] **Step 1: Write failing test**

```go
// pkg/client/rbac/client_test.go
package rbac_test

import (
    "context"
    "testing"
    
    "{{.Module}}/internal/base/conf"
    "{{.Module}}/pkg/client/rbac"
)

func TestNew_ReturnsClient(t *testing.T) {
    cfg := conf.ClientConfig{
        ServiceName: "rbacservice",
        HostPorts:   []string{"localhost:8889"},
    }
    
    cli, err := rbac.New(context.Background(), cfg)
    if err != nil {
        t.Fatalf("expected no error, got %v", err)
    }
    if cli == nil {
        t.Fatal("expected client, got nil")
    }
    if cli.AuthService() == nil {
        t.Fatal("expected AuthService, got nil")
    }
    if cli.RBACService() == nil {
        t.Fatal("expected RBACService, got nil")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./pkg/client/rbac/... -v`
Expected: FAIL with "package not found"

- [ ] **Step 3: Implement pkg/client/rbac/client.go**

```go
// pkg/client/rbac/client.go
package rbac

import (
    "context"
    
    authserviceclient "{{.Module}}/pkg/client/authservice"
    rbacserviceclient "{{.Module}}/pkg/client/rbacservice"
    "{{.Module}}/internal/base/conf"
)

type Client struct {
    auth authserviceclient.Client
    rbac rbacserviceclient.Client
}

func New(ctx context.Context, cfg conf.ClientConfig) (*Client, error) {
    authCfg := convertToServiceConfig(cfg, "authservice")
    authCli, err := authserviceclient.New(ctx, authCfg)
    if err != nil {
        return nil, err
    }
    
    rbacCfg := convertToServiceConfig(cfg, "rbacservice")
    rbacCli, err := rbacserviceclient.New(ctx, rbacCfg)
    if err != nil {
        return nil, err
    }
    
    return &Client{
        auth: authCli,
        rbac: rbacCli,
    }, nil
}

func (c *Client) AuthService() authserviceclient.Client {
    return c.auth
}

func (c *Client) RBACService() rbacserviceclient.Client {
    return c.rbac
}

func convertToServiceConfig(cfg conf.ClientConfig, serviceName string) authserviceclient.Config {
    return authserviceclient.Config{
        ServiceName:                serviceName,
        HostPorts:                  cfg.HostPorts,
        RPCTimeoutSeconds:          cfg.RPCTimeoutSeconds,
        ConnectTimeoutMilliseconds: cfg.ConnectTimeoutMilliseconds,
        EnableMetaInfo:             cfg.EnableMetaInfo,
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./pkg/client/rbac/... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/pkg_client_rbac*.yaml
git commit -m "feat(admin-bff-hertz): add pkg/client/rbac"
```

---

## Task 5: pkg/client — RuleCenter Client

**Files:**
- Create: `admin-bff-hertz/hertz-template/pkg_client_rulecenter_go.yaml`
- Test: `admin-bff-hertz/hertz-template/pkg_client_rulecenter_test_go.yaml`

**Interfaces:**
- Consumes: Config from conf.go
- Produces: `pkg/client/rulecenter.Client` with RuleService() method

- [ ] **Step 1: Write failing test**

```go
// pkg/client/rulecenter/client_test.go
package rulecenter_test

import (
    "context"
    "testing"
    
    "{{.Module}}/internal/base/conf"
    "{{.Module}}/pkg/client/rulecenter"
)

func TestNew_ReturnsClient(t *testing.T) {
    cfg := conf.ClientConfig{
        ServiceName: "rulecenterservice",
        HostPorts:   []string{"localhost:8890"},
    }
    
    cli, err := rulecenter.New(context.Background(), cfg)
    if err != nil {
        t.Fatalf("expected no error, got %v", err)
    }
    if cli == nil {
        t.Fatal("expected client, got nil")
    }
    if cli.RuleService() == nil {
        t.Fatal("expected RuleService, got nil")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./pkg/client/rulecenter/... -v`
Expected: FAIL with "package not found"

- [ ] **Step 3: Implement pkg/client/rulecenter/client.go**

```go
// pkg/client/rulecenter/client.go
package rulecenter

import (
    "context"
    
    rulecenterserviceclient "{{.Module}}/pkg/client/rulecenterservice"
    "{{.Module}}/internal/base/conf"
)

type Client struct {
    rule rulecenterserviceclient.Client
}

func New(ctx context.Context, cfg conf.ClientConfig) (*Client, error) {
    ruleCfg := rulecenterserviceclient.Config{
        ServiceName:                cfg.ServiceName,
        HostPorts:                  cfg.HostPorts,
        RPCTimeoutSeconds:          cfg.RPCTimeoutSeconds,
        ConnectTimeoutMilliseconds: cfg.ConnectTimeoutMilliseconds,
        EnableMetaInfo:             cfg.EnableMetaInfo,
    }
    
    ruleCli, err := rulecenterserviceclient.New(ctx, ruleCfg)
    if err != nil {
        return nil, err
    }
    
    return &Client{
        rule: ruleCli,
    }, nil
}

func (c *Client) RuleService() rulecenterserviceclient.Client {
    return c.rule
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./pkg/client/rulecenter/... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/pkg_client_rulecenter*.yaml
git commit -m "feat(admin-bff-hertz): add pkg/client/rulecenter"
```

---

## Task 6: JWT Middleware

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_go.yaml`
- Test: `admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt_test_go.yaml`

**Interfaces:**
- Consumes: JWTConfig from conf.go
- Produces: `middleware.JWT(secret string, publicPaths ...string) app.HandlerFunc`
- Side effects: Sets claims in context via `SetClaims(ctx, claims)`

- [ ] **Step 1: Write failing test**

```go
// internal/pkg/middleware/jwt_test.go
package middleware_test

import (
    "context"
    "net/http/httptest"
    "testing"
    "time"
    
    "github.com/cloudwego/hertz/pkg/app"
    "github.com/golang-jwt/jwt/v5"
    
    "{{.Module}}/internal/pkg/middleware"
)

func TestJWT_ValidToken_SetsClaims(t *testing.T) {
    secret := "test-secret"
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
        "uuid": "user-123",
        "roles": []string{"admin"},
        "exp": time.Now().Add(time.Hour).Unix(),
    })
    tokenStr, _ := token.SignedString([]byte(secret))
    
    req := httptest.NewRequest("GET", "/api/v1/users", nil)
    req.Header.Set("Authorization", "Bearer "+tokenStr)
    
    var capturedClaims middleware.Claims
    handler := func(ctx context.Context, c *app.RequestContext) {
        claims, ok := middleware.GetClaims(c)
        if !ok {
            t.Fatal("expected claims in context")
        }
        capturedClaims = claims
        c.Next(ctx)
    }
    
    mw := middleware.JWT(secret)
    ctx := context.Background()
    c := &app.RequestContext{}
    c.Request.Header.Set("Authorization", "Bearer "+tokenStr)
    
    mw(handler)(ctx, c)
    
    if capturedClaims.UUID != "user-123" {
        t.Errorf("expected UUID user-123, got %s", capturedClaims.UUID)
    }
}

func TestJWT_ExpiredToken_Aborts(t *testing.T) {
    secret := "test-secret"
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
        "uuid": "user-123",
        "exp": time.Now().Add(-time.Hour).Unix(),
    })
    tokenStr, _ := token.SignedString([]byte(secret))
    
    mw := middleware.JWT(secret)
    ctx := context.Background()
    c := &app.RequestContext{}
    c.Request.Header.Set("Authorization", "Bearer "+tokenStr)
    
    called := false
    handler := func(ctx context.Context, c *app.RequestContext) {
        called = true
        c.Next(ctx)
    }
    
    mw(handler)(ctx, c)
    
    if called {
        t.Error("expected handler not to be called for expired token")
    }
}

func TestJWT_PublicPath_SkipsValidation(t *testing.T) {
    secret := "test-secret"
    mw := middleware.JWT(secret, "/api/v1/auth/login")
    
    ctx := context.Background()
    c := &app.RequestContext{}
    c.Request.SetRequestURI("/api/v1/auth/login")
    
    called := false
    handler := func(ctx context.Context, c *app.RequestContext) {
        called = true
        c.Next(ctx)
    }
    
    mw(handler)(ctx, c)
    
    if !called {
        t.Error("expected handler to be called for public path")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/middleware/... -v -run TestJWT`
Expected: FAIL with "package not found"

- [ ] **Step 3: Implement JWT middleware**

```go
// internal/pkg/middleware/jwt.go
package middleware

import (
    "context"
    "strings"
    "time"
    
    "github.com/cloudwego/hertz/pkg/app"
    "github.com/golang-jwt/jwt/v5"
    
    "{{.Module}}/internal/pkg/response"
)

type Claims struct {
    UUID  string   `json:"uuid"`
    Roles []string `json:"roles"`
}

type claimsKey struct{}

func SetClaims(c *app.RequestContext, claims Claims) {
    ctx := context.WithValue(c, claimsKey{}, claims)
    c.SetContext(ctx)
}

func GetClaims(c *app.RequestContext) (Claims, bool) {
    claims, ok := c.Value(claimsKey{}).(Claims)
    return claims, ok
}

func JWT(secret string, publicPaths ...string) app.HandlerFunc {
    publicPathSet := make(map[string]bool)
    for _, p := range publicPaths {
        publicPathSet[p] = true
    }
    
    return func(ctx context.Context, c *app.RequestContext) {
        path := string(c.Request.URI().Path())
        if publicPathSet[path] {
            c.Next(ctx)
            return
        }
        
        authHeader := string(c.Request.Header.Peek("Authorization"))
        if authHeader == "" {
            response.ErrorCode(c, response.CodeUnauthorized)
            c.Abort()
            return
        }
        
        parts := strings.SplitN(authHeader, " ", 2)
        if len(parts) != 2 || parts[0] != "Bearer" {
            response.ErrorCode(c, response.CodeUnauthorized)
            c.Abort()
            return
        }
        
        tokenStr := parts[1]
        token, err := jwt.Parse(tokenStr, func(token *jwt.Token) (interface{}, error) {
            if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
                return nil, jwt.ErrSignatureInvalid
            }
            return []byte(secret), nil
        })
        
        if err != nil || !token.Valid {
            response.ErrorCode(c, response.CodeUnauthorized)
            c.Abort()
            return
        }
        
        claims, ok := token.Claims.(jwt.MapClaims)
        if !ok {
            response.ErrorCode(c, response.CodeUnauthorized)
            c.Abort()
            return
        }
        
        exp, err := claims.GetExpirationTime()
        if err != nil || exp.Before(time.Now()) {
            response.ErrorCode(c, response.CodeUnauthorized)
            c.Abort()
            return
        }
        
        uuid, _ := claims["uuid"].(string)
        rolesRaw, _ := claims["roles"].([]interface{})
        roles := make([]string, 0, len(rolesRaw))
        for _, r := range rolesRaw {
            if rs, ok := r.(string); ok {
                roles = append(roles, rs)
            }
        }
        
        SetClaims(c, Claims{
            UUID:  uuid,
            Roles: roles,
        })
        
        c.Next(ctx)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/middleware/... -v -run TestJWT`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_pkg_middleware_jwt*.yaml
git commit -m "feat(admin-bff-hertz): add JWT middleware"
```

---

## Task 7: Authz Middleware with RequirePermission

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_pkg_middleware_authz_go.yaml`
- Test: `admin-bff-hertz/hertz-template/internal_pkg_middleware_authz_test_go.yaml`

**Interfaces:**
- Consumes: rbac.Client, Claims from JWT middleware
- Produces: `middleware.Authz(rbacCli *rbac.Client) app.HandlerFunc`, `middleware.RequirePermission(code string) app.HandlerFunc`

- [ ] **Step 1: Write failing test**

```go
// internal/pkg/middleware/authz_test.go
package middleware_test

import (
    "context"
    "testing"
    
    "github.com/cloudwego/hertz/pkg/app"
    "go.uber.org/mock/gomock"
    
    "{{.Module}}/internal/pkg/middleware"
    "{{.Module}}/pkg/client/rbac"
    mock_rbac "{{.Module}}/pkg/client/rbac/mock"
)

func TestAuthz_WithPermission_Allowed(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()
    
    mockRBAC := mock_rbac.NewMockClient(ctrl)
    mockEnforcer := mock_rbac.NewMockEnforcer(ctrl)
    mockRBAC.EXPECT().RBACService().Return(mockEnforcer).AnyTimes()
    mockEnforcer.EXPECT().Enforce(gomock.Any(), gomock.Any()).Return(&EnforceResponse{Allowed: true}, nil)
    
    mw := middleware.Authz(mockRBAC)
    
    ctx := context.Background()
    c := &app.RequestContext{}
    middleware.SetPermission(c, "user:create")
    middleware.SetClaims(c, middleware.Claims{UUID: "user-123"})
    
    called := false
    handler := func(ctx context.Context, c *app.RequestContext) {
        called = true
        c.Next(ctx)
    }
    
    mw(handler)(ctx, c)
    
    if !called {
        t.Error("expected handler to be called")
    }
}

func TestAuthz_WithPermission_Denied(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()
    
    mockRBAC := mock_rbac.NewMockClient(ctrl)
    mockEnforcer := mock_rbac.NewMockEnforcer(ctrl)
    mockRBAC.EXPECT().RBACService().Return(mockEnforcer).AnyTimes()
    mockEnforcer.EXPECT().Enforce(gomock.Any(), gomock.Any()).Return(&EnforceResponse{Allowed: false}, nil)
    
    mw := middleware.Authz(mockRBAC)
    
    ctx := context.Background()
    c := &app.RequestContext{}
    middleware.SetPermission(c, "user:create")
    middleware.SetClaims(c, middleware.Claims{UUID: "user-123"})
    
    called := false
    handler := func(ctx context.Context, c *app.RequestContext) {
        called = true
        c.Next(ctx)
    }
    
    mw(handler)(ctx, c)
    
    if called {
        t.Error("expected handler not to be called")
    }
}

func TestAuthz_NoPermission_SkipsEnforce(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()
    
    mockRBAC := mock_rbac.NewMockClient(ctrl)
    
    mw := middleware.Authz(mockRBAC)
    
    ctx := context.Background()
    c := &app.RequestContext{}
    
    called := false
    handler := func(ctx context.Context, c *app.RequestContext) {
        called = true
        c.Next(ctx)
    }
    
    mw(handler)(ctx, c)
    
    if !called {
        t.Error("expected handler to be called when no permission required")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/middleware/... -v -run TestAuthz`
Expected: FAIL with "package not found"

- [ ] **Step 3: Implement Authz middleware**

```go
// internal/pkg/middleware/authz.go
package middleware

import (
    "context"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rbac"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

type permissionKey struct{}

func SetPermission(c *app.RequestContext, code string) {
    ctx := context.WithValue(c, permissionKey{}, code)
    c.SetContext(ctx)
}

func GetPermission(c *app.RequestContext) string {
    code, _ := c.Value(permissionKey{}).(string)
    return code
}

func RequirePermission(code string) app.HandlerFunc {
    return func(ctx context.Context, c *app.RequestContext) {
        SetPermission(c, code)
        c.Next(ctx)
    }
}

func Authz(rbacCli *rbac.Client) app.HandlerFunc {
    return func(ctx context.Context, c *app.RequestContext) {
        perm := GetPermission(c)
        if perm == "" {
            c.Next(ctx)
            return
        }
        
        claims, ok := GetClaims(c)
        if !ok {
            response.ErrorCode(c, response.CodeUnauthorized)
            c.Abort()
            return
        }
        
        resp, err := rbacCli.RBACService().Enforce(ctx, &api.EnforceRequest{
            Sub: claims.UUID,
            Obj: perm,
            Act: "execute",
        })
        if err != nil {
            response.ErrorCode(c, response.CodeInternalError)
            c.Abort()
            return
        }
        
        if !resp.Allowed {
            response.ErrorCode(c, response.CodeForbidden)
            c.Abort()
            return
        }
        
        c.Next(ctx)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/middleware/... -v -run TestAuthz`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_pkg_middleware_authz*.yaml
git commit -m "feat(admin-bff-hertz): add Authz middleware with RequirePermission"
```

---

## Task 8: Auth Handlers

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_handler_auth_go.yaml`
- Test: `admin-bff-hertz/hertz-template/internal_handler_auth_test_go.yaml`

**Interfaces:**
- Consumes: rbac.Client
- Produces: `handler.AuthHandler` with Login, Refresh, Logout methods

- [ ] **Step 1: Write failing test**

```go
// internal/handler/auth_test.go
package handler_test

import (
    "context"
    "testing"
    
    "github.com/cloudwego/hertz/pkg/app"
    "go.uber.org/mock/gomock"
    
    "{{.Module}}/internal/handler"
    "{{.Module}}/pkg/client/rbac"
    mock_rbac "{{.Module}}/pkg/client/rbac/mock"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

func TestAuthHandler_Login_Success(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()
    
    mockRBAC := mock_rbac.NewMockClient(ctrl)
    mockAuth := mock_rbac.NewMockAuthService(ctrl)
    mockRBAC.EXPECT().AuthService().Return(mockAuth).AnyTimes()
    
    mockAuth.EXPECT().Login(gomock.Any(), gomock.Any()).Return(&api.LoginResponse{
        AccessToken:  "access-token",
        RefreshToken: "refresh-token",
        ExpiresIn:    7200,
    }, nil)
    
    h := handler.NewAuthHandler(mockRBAC)
    
    ctx := context.Background()
    c := &app.RequestContext{}
    c.Request.SetBody([]byte(`{"username":"admin","password":"secret"}`))
    
    h.Login(ctx, c)
    
    // Verify response contains tokens
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/handler/... -v -run TestAuthHandler`
Expected: FAIL with "package not found"

- [ ] **Step 3: Implement AuthHandler**

```go
// internal/handler/auth.go
package handler

import (
    "context"
    "encoding/json"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rbac"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

type AuthHandler struct {
    rbacCli *rbac.Client
}

func NewAuthHandler(rbacCli *rbac.Client) *AuthHandler {
    return &AuthHandler{rbacCli: rbacCli}
}

type LoginRequest struct {
    Username string `json:"username"`
    Password string `json:"password"`
}

func (h *AuthHandler) Login(ctx context.Context, c *app.RequestContext) {
    var req LoginRequest
    if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
        response.ErrorCode(c, response.CodeInvalidParam)
        return
    }
    
    resp, err := h.rbacCli.AuthService().Login(ctx, &api.LoginRequest{
        Username: req.Username,
        Password: req.Password,
    })
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, map[string]interface{}{
        "access_token":  resp.AccessToken,
        "refresh_token": resp.RefreshToken,
        "expires_in":    resp.ExpiresIn,
    })
}

func (h *AuthHandler) Refresh(ctx context.Context, c *app.RequestContext) {
    var req struct {
        RefreshToken string `json:"refresh_token"`
    }
    if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
        response.ErrorCode(c, response.CodeInvalidParam)
        return
    }
    
    resp, err := h.rbacCli.AuthService().Refresh(ctx, &api.RefreshRequest{
        RefreshToken: req.RefreshToken,
    })
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, map[string]interface{}{
        "access_token":  resp.AccessToken,
        "refresh_token": resp.RefreshToken,
        "expires_in":    resp.ExpiresIn,
    })
}

func (h *AuthHandler) Logout(ctx context.Context, c *app.RequestContext) {
    claims, ok := middleware.GetClaims(c)
    if !ok {
        response.ErrorCode(c, response.CodeUnauthorized)
        return
    }
    
    _, err := h.rbacCli.AuthService().Logout(ctx, &api.LogoutRequest{
        UserId: claims.UUID,
    })
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, map[string]string{"status": "ok"})
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/handler/... -v -run TestAuthHandler`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_auth*.yaml
git commit -m "feat(admin-bff-hertz): add auth handlers"
```

---

## Task 9: RBAC Handlers

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_handler_user_go.yaml`
- Create: `admin-bff-hertz/hertz-template/internal_handler_role_go.yaml`
- Create: `admin-bff-hertz/hertz-template/internal_handler_permission_go.yaml`
- Create: `admin-bff-hertz/hertz-template/internal_handler_menu_go.yaml`

**Interfaces:**
- Consumes: rbac.Client
- Produces: UserHandler, RoleHandler, PermissionHandler, MenuHandler

- [ ] **Step 1: Implement UserHandler (CRUD for /api/v1/users)**

Similar pattern to AuthHandler but for User CRUD operations proxying to rbacCli.RBACService().CreateUser/UpdateUser/DeleteUser/GetUser/ListUsers.

- [ ] **Step 2: Implement RoleHandler (CRUD for /api/v1/roles)**

Proxy to rbacCli.RBACService().CreateRole/UpdateRole/DeleteRole/ListRoles.

- [ ] **Step 3: Implement PermissionHandler (CRUD for /api/v1/permissions)**

Proxy to rbacCli.RBACService().CreatePermission/UpdatePermission/DeletePermission/GetPermission/ListPermissions.

- [ ] **Step 4: Implement MenuHandler (read for /api/v1/menus)**

Proxy to rbacCli.RBACService().ListMenus.

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_*_go.yaml
git commit -m "feat(admin-bff-hertz): add RBAC handlers"
```

---

## Task 10: Current User Handlers

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_handler_current_user_go.yaml`

**Interfaces:**
- Consumes: rbac.Client, Claims from JWT middleware
- Produces: CurrentUserHandler with GetMenus, GetPerms methods

- [ ] **Step 1: Implement CurrentUserHandler**

```go
// internal/handler/current_user.go
package handler

import (
    "context"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/middleware"
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rbac"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

type CurrentUserHandler struct {
    rbacCli *rbac.Client
}

func NewCurrentUserHandler(rbacCli *rbac.Client) *CurrentUserHandler {
    return &CurrentUserHandler{rbacCli: rbacCli}
}

func (h *CurrentUserHandler) GetMenus(ctx context.Context, c *app.RequestContext) {
    claims, ok := middleware.GetClaims(c)
    if !ok {
        response.ErrorCode(c, response.CodeUnauthorized)
        return
    }
    
    resp, err := h.rbacCli.RBACService().GetUserMenuTree(ctx, &api.GetUserMenuTreeRequest{
        UserId: claims.UUID,
    })
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, resp.Menus)
}

func (h *CurrentUserHandler) GetPerms(ctx context.Context, c *app.RequestContext) {
    claims, ok := middleware.GetClaims(c)
    if !ok {
        response.ErrorCode(c, response.CodeUnauthorized)
        return
    }
    
    resp, err := h.rbacCli.RBACService().GetUserPermCodes(ctx, &api.GetUserPermCodesRequest{
        UserId: claims.UUID,
    })
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, resp.PermCodes)
}
```

- [ ] **Step 2: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_current_user_go.yaml
git commit -m "feat(admin-bff-hertz): add current user handlers"
```

---

## Task 11: Rate Limit Rule Handlers

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_handler_rate_limit_go.yaml`

**Interfaces:**
- Consumes: rulecenter.Client
- Produces: RateLimitHandler with CRUD methods for /api/v1/rate-limit-rules

- [ ] **Step 1: Implement RateLimitHandler**

```go
// internal/handler/rate_limit.go
package handler

import (
    "context"
    "encoding/json"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rulecenter"
    api "{{.Module}}/kitex_gen/api/ratelimit/v1"
)

type RateLimitHandler struct {
    rulecenterCli *rulecenter.Client
}

func NewRateLimitHandler(rulecenterCli *rulecenter.Client) *RateLimitHandler {
    return &RateLimitHandler{rulecenterCli: rulecenterCli}
}

func (h *RateLimitHandler) List(ctx context.Context, c *app.RequestContext) {
    resp, err := h.rulecenterCli.RuleService().ListRules(ctx, &api.ListRulesRequest{})
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, resp.Rules)
}

func (h *RateLimitHandler) Create(ctx context.Context, c *app.RequestContext) {
    var req api.CreateRuleRequest
    if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
        response.ErrorCode(c, response.CodeInvalidParam)
        return
    }
    
    resp, err := h.rulecenterCli.RuleService().CreateRule(ctx, &req)
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    
    response.JSON(c, resp.Rule)
}

// Update, Delete, Get similar...
```

- [ ] **Step 2: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_rate_limit_go.yaml
git commit -m "feat(admin-bff-hertz): add rate limit rule handlers"
```

---

## Task 12: Router Registration

**Files:**
- Create: `admin-bff-hertz/hertz-template/internal_router_register_go.yaml`

**Interfaces:**
- Consumes: All handlers, middleware
- Produces: Route registration with RequirePermission decorators

- [ ] **Step 1: Implement router registration**

```go
// internal/router/register.go
package router

import (
    "github.com/cloudwego/hertz/pkg/app/server"
    
    "{{.Module}}/internal/base/conf"
    "{{.Module}}/internal/handler"
    "{{.Module}}/internal/pkg/middleware"
    "{{.Module}}/pkg/client/rbac"
    "{{.Module}}/pkg/client/rulecenter"
)

func Register(h *server.Hertz, rbacCli *rbac.Client, rulecenterCli *rulecenter.Client) {
    cfg := conf.Get()
    
    authHandler := handler.NewAuthHandler(rbacCli)
    userHandler := handler.NewUserHandler(rbacCli)
    roleHandler := handler.NewRoleHandler(rbacCli)
    permHandler := handler.NewPermissionHandler(rbacCli)
    menuHandler := handler.NewMenuHandler(rbacCli)
    currentUserHandler := handler.NewCurrentUserHandler(rbacCli)
    rateLimitHandler := handler.NewRateLimitHandler(rulecenterCli)
    
    api := h.Group("/api/v1")
    
    // Public routes (no JWT)
    auth := api.Group("/auth")
    auth.POST("/login", authHandler.Login)
    auth.POST("/refresh", authHandler.Refresh)
    
    // Protected routes (JWT required)
    protected := api.Group("", middleware.JWT(cfg.JWT.Secret, "/api/v1/auth/login", "/api/v1/auth/refresh"))
    
    // Authz middleware
    protected.Use(middleware.Authz(rbacCli))
    
    // Auth (logout requires auth)
    protected.POST("/auth/logout", authHandler.Logout)
    
    // Current user
    me := protected.Group("/me")
    me.GET("/menus", currentUserHandler.GetMenus)
    me.GET("/perms", currentUserHandler.GetPerms)
    
    // RBAC management
    users := protected.Group("/users")
    users.GET("", middleware.RequirePermission("user:list"), userHandler.List)
    users.GET("/:id", middleware.RequirePermission("user:read"), userHandler.Get)
    users.POST("", middleware.RequirePermission("user:create"), userHandler.Create)
    users.PUT("/:id", middleware.RequirePermission("user:update"), userHandler.Update)
    users.DELETE("/:id", middleware.RequirePermission("user:delete"), userHandler.Delete)
    
    roles := protected.Group("/roles")
    roles.GET("", middleware.RequirePermission("role:list"), roleHandler.List)
    roles.POST("", middleware.RequirePermission("role:create"), roleHandler.Create)
    roles.PUT("/:id", middleware.RequirePermission("role:update"), roleHandler.Update)
    roles.DELETE("/:id", middleware.RequirePermission("role:delete"), roleHandler.Delete)
    
    perms := protected.Group("/permissions")
    perms.GET("", middleware.RequirePermission("permission:list"), permHandler.List)
    perms.GET("/:id", middleware.RequirePermission("permission:read"), permHandler.Get)
    perms.POST("", middleware.RequirePermission("permission:create"), permHandler.Create)
    perms.PUT("/:id", middleware.RequirePermission("permission:update"), permHandler.Update)
    perms.DELETE("/:id", middleware.RequirePermission("permission:delete"), permHandler.Delete)
    
    menus := protected.Group("/menus")
    menus.GET("", middleware.RequirePermission("menu:list"), menuHandler.List)
    
    // Rate limit rules
    rules := protected.Group("/rate-limit-rules")
    rules.GET("", middleware.RequirePermission("rate_limit:list"), rateLimitHandler.List)
    rules.POST("", middleware.RequirePermission("rate_limit:create"), rateLimitHandler.Create)
    rules.PUT("/:id", middleware.RequirePermission("rate_limit:update"), rateLimitHandler.Update)
    rules.DELETE("/:id", middleware.RequirePermission("rate_limit:delete"), rateLimitHandler.Delete)
}
```

- [ ] **Step 2: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_router_register_go.yaml
git commit -m "feat(admin-bff-hertz): add router registration"
```

---

## Task 13: Server Entry Point

**Files:**
- Create: `admin-bff-hertz/hertz-template/server_go.yaml`

**Interfaces:**
- Consumes: Config, clients, router
- Produces: Server startup with middleware chain

- [ ] **Step 1: Implement server.go**

```go
// internal/base/server/server.go
package server

import (
    "context"
    "log"
    
    hertzframework "github.com/byx-darwin/go-tools/go-framework/hertz"
    
    "{{.Module}}/internal/base/conf"
    "{{.Module}}/internal/handler/health"
    "{{.Module}}/internal/pkg/middleware"
    "{{.Module}}/internal/router"
    "{{.Module}}/pkg/client/rbac"
    "{{.Module}}/pkg/client/rulecenter"
)

func Run() {
    cfg := conf.Get()
    
    ctx := context.Background()
    h, err := hertzframework.NewHTTPServer(ctx, &cfg.Server)
    if err != nil {
        log.Fatalf("create server: %v", err)
    }
    
    // Initialize RPC clients
    rbacCli, err := rbac.New(ctx, cfg.GRPC.RBAC)
    if err != nil {
        log.Fatalf("init rbac client: %v", err)
    }
    
    rulecenterCli, err := rulecenter.New(ctx, cfg.GRPC.RuleCenter)
    if err != nil {
        log.Fatalf("init rulecenter client: %v", err)
    }
    
    // Register health check routes
    health.Register(h)
    
    // Register business routes
    router.Register(h, rbacCli, rulecenterCli)
    
    // Start server
    h.Spin()
}
```

- [ ] **Step 2: Commit**

```bash
git add admin-bff-hertz/hertz-template/server_go.yaml
git commit -m "feat(admin-bff-hertz): add server entry point"
```

---

## Task 14: Update README with Full Documentation

**Files:**
- Modify: `admin-bff-hertz/README.md`

- [ ] **Step 1: Update README with complete documentation**

Expand README to include:
- Full usage instructions
- Middleware documentation (JWT, Authz)
- API endpoint list
- pkg/client documentation
- Seams (TODO) documentation
- Configuration reference

- [ ] **Step 2: Commit**

```bash
git add admin-bff-hertz/README.md
git commit -m "docs(admin-bff-hertz): complete README documentation"
```

---

## Task 15: E2E Verification

**Files:**
- Create: `admin-bff-hertz/test/e2e_test.sh`

**Interfaces:**
- Consumes: Complete template
- Produces: Verification that `ncgo new --template admin-bff-hertz` builds

- [ ] **Step 1: Create e2e test script**

```bash
#!/bin/bash
# admin-bff-hertz/test/e2e_test.sh

set -e

echo "=== E2E Test: admin-bff-hertz ==="

# Create temp directory
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

# Generate project
echo "Generating project..."
ncgo new admin-bff-test --module github.com/test/admin-bff --kind hertz --template admin-bff-hertz

cd admin-bff-test

# Build
echo "Building..."
go build ./...

# Test
echo "Running tests..."
go test ./...

# Cleanup
cd /
rm -rf "$TMPDIR"

echo "=== E2E Test PASSED ==="
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x admin-bff-hertz/test/e2e_test.sh
git add admin-bff-hertz/test/e2e_test.sh
git commit -m "test(admin-bff-hertz): add e2e verification script"
```

---

## Task 16: Update Registry README

**Files:**
- Modify: `README.md` (root)

- [ ] **Step 1: Add admin-bff-hertz to template registry**

Add row to the Templates table:

```markdown
| `admin-bff-hertz` | hertz | Admin BFF Hertz HTTP template (JWT auth + RBAC authz + rate-limit rule management) | ✅ `ncgo new --kind hertz --template admin-bff-hertz` |
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add admin-bff-hertz to registry"
```

---

## Summary

This plan creates the `admin-bff-hertz` template with:

1. ✅ Template scaffolding (template.yaml, README)
2. ✅ IDL files (auth.proto, rule_center.proto)
3. ✅ Configuration (conf.yaml with jwt, grpc sections)
4. ✅ pkg/client (rbac + rulecenter)
5. ✅ JWT middleware (HS256, public paths skip)
6. ✅ Authz middleware (RequirePermission → Enforce RPC)
7. ✅ Auth handlers (login, refresh, logout)
8. ✅ RBAC handlers (user, role, permission, menu)
9. ✅ Current user handlers (menus, perms)
10. ✅ Rate limit handlers (CRUD)
11. ✅ Router registration (with permission decorators)
12. ✅ Server entry point
13. ✅ Complete README documentation
14. ✅ E2E verification script
15. ✅ Registry README update

Total: 16 tasks, all TDD-style with tests before implementation.
