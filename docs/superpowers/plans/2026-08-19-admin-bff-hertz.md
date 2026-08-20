# admin-bff-hertz Implementation Plan (Revised)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a Hertz HTTP BFF template that provides admin API gateway functionality with JWT auth, RBAC authorization via RPC call to rbac-kitex, and rate-limit rule management via RPC call to rule-center.

**Architecture:** Thin BFF layer using Hertz framework with JWT middleware for authentication, Authz middleware calling rbac-kitex Enforce RPC for authorization, handlers that proxy to backend RPC services. Build via ncgo workflow: write Go project → `ncgo export templates` → assemble template package.

**Tech Stack:** Go 1.24+, Hertz (HTTP), Kitex (gRPC client), ncgo CLI, PostgreSQL (for generated project), JWT (HS256)

**Spec:** docs/superpowers/specs/2026-08-19-admin-bff-hertz-design.md

## Global Constraints

- Template kind: `hertz`
- Template name: `admin-bff-hertz`
- Build method: `ncgo new` → hand-write Go code → `ncgo export templates` → assemble package
- Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`
- JWT algorithm: HS256 (RS256/JWKS as documented TODO seam)
- Authz pattern: Handler declares `RequirePermission("code")`, middleware calls rbac-kitex Enforce RPC
- pkg/client structure: `rbac/` + `rulecenter/` (by backend service, not by proto service)
- Route prefix: `/api/v1/`
- Audit logging: handled by rbac-kitex, not BFF
- Rate-limit: BFF manages rules (CRUD), does NOT enforce rate-limit on itself
- All tests hermetic (mock RPC clients, skip postgres/redis if unavailable)

## Build Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase A: Create Go Project (in worktree or temp directory)    │
├─────────────────────────────────────────────────────────────────┤
│  1. ncgo new admin-bff --kind hertz --db postgres              │
│  2. Hand-write Go code:                                        │
│     - internal/pkg/middleware/jwt.go + authz.go                │
│     - internal/handler/auth.go, user.go, role.go, ...          │
│     - pkg/client/rbac/client.go + rulecenter/client.go         │
│     - internal/base/conf/conf.go (extend with JWT/gRPC config) │
│     - internal/router/register.go                              │
│     - internal/base/server/server.go (wire clients)            │
│  3. go build ./... && go test ./... (hermetic, mock clients)   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Phase B: Export to Template                                   │
├─────────────────────────────────────────────────────────────────┤
│  4. ncgo export templates --kind hertz                         │
│     → Generates hertz-template/*.yaml from Go source           │
│  5. Assemble admin-bff-hertz/ package:                         │
│     - template.yaml                                            │
│     - hertz-template/*.yaml (from export)                      │
│     - idl/auth.proto + rule_center.proto                       │
│     - README.md                                                │
│     - test/e2e_test.sh                                         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  Phase C: Verification                                         │
├─────────────────────────────────────────────────────────────────┤
│  6. ncgo new test-bff --template admin-bff-hertz               │
│  7. go build ./... && go test ./...                            │
│  8. Verify generated project structure matches spec            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Task 1: Create Worktree + Generate Base Project

**Files:**
- Create: `.worktree/feat-12-admin-bff-hertz/` (worktree directory)
- Generate: Base Hertz project via `ncgo new`

**Interfaces:**
- Consumes: ncgo CLI, base-hertz template
- Produces: Working Hertz project directory

- [ ] **Step 1: Create worktree**

```bash
git worktree add .worktree/feat-12-admin-bff-hertz -b feat/12-admin-bff-hertz
```

- [ ] **Step 2: Generate base Hertz project**

```bash
cd .worktree/feat-12-admin-bff-hertz
ncgo new admin-bff --module github.com/byx-darwin/ncgo-templates/admin-bff-hertz --kind hertz --db postgres
```

- [ ] **Step 3: Verify base project builds**

```bash
cd admin-bff
go build ./...
go test ./...
```

Expected: Build succeeds, tests pass (base template is hermetic).

- [ ] **Step 4: Commit**

```bash
git add .
git commit -m "chore: scaffold base hertz project for admin-bff"
```

---

## Task 2: Extend Configuration

**Files:**
- Modify: `internal/base/conf/conf.go`
- Modify: `conf/dev/conf.yaml`

**Interfaces:**
- Consumes: Base conf structure
- Produces: Extended Config with JWTConfig + GRPCConfig sections

- [ ] **Step 1: Write failing test**

```go
// internal/base/conf/conf_test.go
package conf_test

import (
    "testing"
    
    "{{.Module}}/internal/base/conf"
)

func TestConfig_HasJWTSection(t *testing.T) {
    cfg := conf.Get()
    if cfg.JWT.Secret == "" {
        t.Error("expected JWT.Secret to be configured")
    }
    if cfg.JWT.AccessTokenTTLSeconds <= 0 {
        t.Error("expected JWT.AccessTokenTTLSeconds > 0")
    }
}

func TestConfig_HasGRPCSection(t *testing.T) {
    cfg := conf.Get()
    if cfg.GRPC.RBAC.ServiceName == "" {
        t.Error("expected GRPC.RBAC.ServiceName to be configured")
    }
    if cfg.GRPC.RuleCenter.ServiceName == "" {
        t.Error("expected GRPC.RuleCenter.ServiceName to be configured")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/base/conf/... -v`
Expected: FAIL with "cfg.JWT undefined" or similar

- [ ] **Step 3: Extend conf.go**

```go
// internal/base/conf/conf.go
package conf

import (
    "sync"
    
    gfconfig "github.com/byx-darwin/go-tools/go-framework/config"
)

type Config struct {
    Server gfconfig.ServerConfig `yaml:"server"`
    JWT    JWTConfig             `yaml:"jwt"`
    GRPC   GRPCConfig            `yaml:"grpc"`
}

type JWTConfig struct {
    Secret                 string `yaml:"secret"`
    AccessTokenTTLSeconds  int    `yaml:"access_token_ttl_seconds"`
    RefreshTokenTTLSeconds int    `yaml:"refresh_token_ttl_seconds"`
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

- [ ] **Step 4: Update conf/dev/conf.yaml**

```yaml
# conf/dev/conf.yaml
server:
  addr: ":8888"
  registry:
    name: "admin-bff"
    address: ""

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

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/base/conf/... -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add internal/base/conf/ conf/dev/conf.yaml
git commit -m "feat(conf): extend config with JWT and gRPC sections"
```

---

## Task 3: pkg/client — RBAC Client

**Files:**
- Create: `pkg/client/rbac/client.go`
- Create: `pkg/client/rbac/client_test.go`

**Interfaces:**
- Consumes: conf.ClientConfig, authservice client, rbacservice client
- Produces: `rbac.Client` with AuthService() and RBACService() methods

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

First, generate the kitex client code:

```bash
ncgo add rpc authservice --proto idl/auth.proto
ncgo add rpc rbacservice --proto idl/auth.proto
```

Then implement the wrapper:

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
    authCfg := authserviceclient.Config{
        ServiceName:                "authservice",
        HostPorts:                  cfg.HostPorts,
        RPCTimeoutSeconds:          cfg.RPCTimeoutSeconds,
        ConnectTimeoutMilliseconds: cfg.ConnectTimeoutMilliseconds,
        EnableMetaInfo:             cfg.EnableMetaInfo,
    }
    authCli, err := authserviceclient.New(ctx, authCfg)
    if err != nil {
        return nil, err
    }
    
    rbacCfg := rbacserviceclient.Config{
        ServiceName:                "rbacservice",
        HostPorts:                  cfg.HostPorts,
        RPCTimeoutSeconds:          cfg.RPCTimeoutSeconds,
        ConnectTimeoutMilliseconds: cfg.ConnectTimeoutMilliseconds,
        EnableMetaInfo:             cfg.EnableMetaInfo,
    }
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./pkg/client/rbac/... -v`
Expected: PASS (if kitex clients generated successfully)

- [ ] **Step 5: Commit**

```bash
git add pkg/client/rbac/ idl/
git commit -m "feat(pkg/client): add rbac client wrapper"
```

---

## Task 4: pkg/client — RuleCenter Client

**Files:**
- Create: `pkg/client/rulecenter/client.go`
- Create: `pkg/client/rulecenter/client_test.go`

**Interfaces:**
- Consumes: conf.ClientConfig, rulecenterservice client
- Produces: `rulecenter.Client` with RuleService() method

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
Expected: FAIL

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
git add pkg/client/rulecenter/
git commit -m "feat(pkg/client): add rulecenter client wrapper"
```

---

## Task 5: JWT Middleware

**Files:**
- Create: `internal/pkg/middleware/jwt.go`
- Create: `internal/pkg/middleware/jwt_test.go`

**Interfaces:**
- Consumes: JWT secret from config
- Produces: `middleware.JWT(secret string, publicPaths ...string) app.HandlerFunc`
- Side effects: Sets claims in context via `SetClaims(ctx, claims)`

- [ ] **Step 1: Write failing test**

```go
// internal/pkg/middleware/jwt_test.go
package middleware_test

import (
    "context"
    "testing"
    "time"
    
    "github.com/cloudwego/hertz/pkg/app"
    "github.com/golang-jwt/jwt/v5"
    
    "{{.Module}}/internal/pkg/middleware"
)

func TestJWT_ValidToken_SetsClaims(t *testing.T) {
    secret := "test-secret"
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
        "uuid":  "user-123",
        "roles": []interface{}{"admin"},
        "exp":   time.Now().Add(time.Hour).Unix(),
    })
    tokenStr, _ := token.SignedString([]byte(secret))
    
    mw := middleware.JWT(secret)
    
    ctx := context.Background()
    c := &app.RequestContext{}
    c.Request.Header.Set("Authorization", "Bearer "+tokenStr)
    
    called := false
    handler := func(ctx context.Context, c *app.RequestContext) {
        called = true
        claims, ok := middleware.GetClaims(c)
        if !ok {
            t.Fatal("expected claims in context")
        }
        if claims.UUID != "user-123" {
            t.Errorf("expected UUID user-123, got %s", claims.UUID)
        }
        c.Next(ctx)
    }
    
    mw(handler)(ctx, c)
    
    if !called {
        t.Error("expected handler to be called")
    }
}

func TestJWT_ExpiredToken_Aborts(t *testing.T) {
    secret := "test-secret"
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
        "uuid": "user-123",
        "exp":  time.Now().Add(-time.Hour).Unix(),
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
Expected: FAIL

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
    c.Set("claims", claims)
}

func GetClaims(c *app.RequestContext) (Claims, bool) {
    val, exists := c.Get("claims")
    if !exists {
        return Claims{}, false
    }
    claims, ok := val.(Claims)
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
git add internal/pkg/middleware/jwt.go internal/pkg/middleware/jwt_test.go
git commit -m "feat(middleware): add JWT middleware"
```

---

## Task 6: Authz Middleware with RequirePermission

**Files:**
- Create: `internal/pkg/middleware/authz.go`
- Create: `internal/pkg/middleware/authz_test.go`

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
    mock_rbac "{{.Module}}/pkg/client/rbac/mock"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

func TestAuthz_WithPermission_Allowed(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()
    
    mockRBAC := mock_rbac.NewMockClient(ctrl)
    mockRBACService := mock_rbac.NewMockRBACService(ctrl)
    mockRBAC.EXPECT().RBACService().Return(mockRBACService).AnyTimes()
    mockRBACService.EXPECT().Enforce(gomock.Any(), &api.EnforceRequest{
        Sub: "user-123",
        Obj: "user:create",
        Act: "execute",
    }).Return(&api.EnforceResponse{Allowed: true}, nil)
    
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
    mockRBACService := mock_rbac.NewMockRBACService(ctrl)
    mockRBAC.EXPECT().RBACService().Return(mockRBACService).AnyTimes()
    mockRBACService.EXPECT().Enforce(gomock.Any(), gomock.Any()).Return(&api.EnforceResponse{Allowed: false}, nil)
    
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
Expected: FAIL

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
    c.Set("permission", code)
}

func GetPermission(c *app.RequestContext) string {
    val, exists := c.Get("permission")
    if !exists {
        return ""
    }
    code, _ := val.(string)
    return code
}

func RequirePermission(code string) app.HandlerFunc {
    return func(ctx context.Context, c *app.RequestContext) {
        SetPermission(c, code)
        c.Next(ctx)
    }
}

func Authz(rbacCli rbac.Client) app.HandlerFunc {
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
git add internal/pkg/middleware/authz.go internal/pkg/middleware/authz_test.go
git commit -m "feat(middleware): add Authz middleware with RequirePermission"
```

---

## Task 7: Auth Handlers

**Files:**
- Create: `internal/handler/auth.go`
- Create: `internal/handler/auth_test.go`

**Interfaces:**
- Consumes: rbac.Client
- Produces: `handler.AuthHandler` with Login, Refresh, Logout methods

- [ ] **Step 1: Write failing test**

```go
// internal/handler/auth_test.go
package handler_test

import (
    "context"
    "encoding/json"
    "testing"
    
    "github.com/cloudwego/hertz/pkg/app"
    "go.uber.org/mock/gomock"
    
    "{{.Module}}/internal/handler"
    mock_rbac "{{.Module}}/pkg/client/rbac/mock"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

func TestAuthHandler_Login_Success(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()
    
    mockRBAC := mock_rbac.NewMockClient(ctrl)
    mockAuthService := mock_rbac.NewMockAuthService(ctrl)
    mockRBAC.EXPECT().AuthService().Return(mockAuthService).AnyTimes()
    
    mockAuthService.EXPECT().Login(gomock.Any(), &api.LoginRequest{
        Username: "admin",
        Password: "secret",
    }).Return(&api.LoginResponse{
        AccessToken:  "access-token",
        RefreshToken: "refresh-token",
        ExpiresIn:    7200,
    }, nil)
    
    h := handler.NewAuthHandler(mockRBAC)
    
    ctx := context.Background()
    c := &app.RequestContext{}
    body, _ := json.Marshal(map[string]string{
        "username": "admin",
        "password": "secret",
    })
    c.Request.SetBody(body)
    
    h.Login(ctx, c)
    
    // Verify response (simplified - in real test would parse response)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/handler/... -v -run TestAuthHandler`
Expected: FAIL

- [ ] **Step 3: Implement AuthHandler**

```go
// internal/handler/auth.go
package handler

import (
    "context"
    "encoding/json"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/middleware"
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rbac"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

type AuthHandler struct {
    rbacCli rbac.Client
}

func NewAuthHandler(rbacCli rbac.Client) *AuthHandler {
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
git add internal/handler/auth.go internal/handler/auth_test.go
git commit -m "feat(handler): add auth handlers"
```

---

## Task 8: RBAC Handlers

**Files:**
- Create: `internal/handler/user.go`
- Create: `internal/handler/role.go`
- Create: `internal/handler/permission.go`
- Create: `internal/handler/menu.go`

**Interfaces:**
- Consumes: rbac.Client
- Produces: UserHandler, RoleHandler, PermissionHandler, MenuHandler

- [ ] **Step 1: Implement UserHandler (CRUD for /api/v1/users)**

```go
// internal/handler/user.go
package handler

import (
    "context"
    "encoding/json"
    "strconv"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rbac"
    api "{{.Module}}/kitex_gen/api/rbac/v1"
)

type UserHandler struct {
    rbacCli rbac.Client
}

func NewUserHandler(rbacCli rbac.Client) *UserHandler {
    return &UserHandler{rbacCli: rbacCli}
}

func (h *UserHandler) List(ctx context.Context, c *app.RequestContext) {
    resp, err := h.rbacCli.RBACService().ListUsers(ctx, &api.ListUsersRequest{})
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, resp.Users)
}

func (h *UserHandler) Get(ctx context.Context, c *app.RequestContext) {
    idStr := c.Param("id")
    id, _ := strconv.ParseInt(idStr, 10, 64)
    
    resp, err := h.rbacCli.RBACService().GetUser(ctx, &api.GetUserRequest{Id: id})
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, resp.User)
}

func (h *UserHandler) Create(ctx context.Context, c *app.RequestContext) {
    var req api.CreateUserRequest
    if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
        response.ErrorCode(c, response.CodeInvalidParam)
        return
    }
    
    resp, err := h.rbacCli.RBACService().CreateUser(ctx, &req)
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, resp.User)
}

func (h *UserHandler) Update(ctx context.Context, c *app.RequestContext) {
    idStr := c.Param("id")
    id, _ := strconv.ParseInt(idStr, 10, 64)
    
    var req api.UpdateUserRequest
    if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
        response.ErrorCode(c, response.CodeInvalidParam)
        return
    }
    req.Id = id
    
    resp, err := h.rbacCli.RBACService().UpdateUser(ctx, &req)
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, resp.User)
}

func (h *UserHandler) Delete(ctx context.Context, c *app.RequestContext) {
    idStr := c.Param("id")
    id, _ := strconv.ParseInt(idStr, 10, 64)
    
    _, err := h.rbacCli.RBACService().DeleteUser(ctx, &api.DeleteUserRequest{Id: id})
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, map[string]string{"status": "deleted"})
}
```

- [ ] **Step 2: Implement RoleHandler, PermissionHandler, MenuHandler similarly**

(Follow same pattern for Role, Permission, Menu CRUD operations)

- [ ] **Step 3: Commit**

```bash
git add internal/handler/user.go internal/handler/role.go internal/handler/permission.go internal/handler/menu.go
git commit -m "feat(handler): add RBAC handlers"
```

---

## Task 9: Current User Handlers

**Files:**
- Create: `internal/handler/current_user.go`

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
    rbacCli rbac.Client
}

func NewCurrentUserHandler(rbacCli rbac.Client) *CurrentUserHandler {
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
git add internal/handler/current_user.go
git commit -m "feat(handler): add current user handlers"
```

---

## Task 10: Rate Limit Rule Handlers

**Files:**
- Create: `internal/handler/rate_limit.go`

**Interfaces:**
- Consumes: rulecenter.Client
- Produces: RateLimitHandler with CRUD methods

- [ ] **Step 1: Implement RateLimitHandler**

```go
// internal/handler/rate_limit.go
package handler

import (
    "context"
    "encoding/json"
    "strconv"
    
    "github.com/cloudwego/hertz/pkg/app"
    
    "{{.Module}}/internal/pkg/response"
    "{{.Module}}/pkg/client/rulecenter"
    api "{{.Module}}/kitex_gen/api/ratelimit/v1"
)

type RateLimitHandler struct {
    rulecenterCli rulecenter.Client
}

func NewRateLimitHandler(rulecenterCli rulecenter.Client) *RateLimitHandler {
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

func (h *RateLimitHandler) Update(ctx context.Context, c *app.RequestContext) {
    idStr := c.Param("id")
    id, _ := strconv.ParseInt(idStr, 10, 64)
    
    var req api.UpdateRuleRequest
    if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
        response.ErrorCode(c, response.CodeInvalidParam)
        return
    }
    req.Id = id
    
    resp, err := h.rulecenterCli.RuleService().UpdateRule(ctx, &req)
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, resp.Rule)
}

func (h *RateLimitHandler) Delete(ctx context.Context, c *app.RequestContext) {
    idStr := c.Param("id")
    id, _ := strconv.ParseInt(idStr, 10, 64)
    
    _, err := h.rulecenterCli.RuleService().DeleteRule(ctx, &api.DeleteRuleRequest{Id: id})
    if err != nil {
        response.ErrorCode(c, response.CodeInternalError)
        return
    }
    response.JSON(c, map[string]string{"status": "deleted"})
}
```

- [ ] **Step 2: Commit**

```bash
git add internal/handler/rate_limit.go
git commit -m "feat(handler): add rate limit rule handlers"
```

---

## Task 11: Router Registration

**Files:**
- Create: `internal/router/register.go`

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

func Register(h *server.Hertz, rbacCli rbac.Client, rulecenterCli rulecenter.Client) {
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
    protected := api.Group("")
    protected.Use(middleware.JWT(cfg.JWT.Secret))
    
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
git add internal/router/register.go
git commit -m "feat(router): add route registration"
```

---

## Task 12: Server Entry Point

**Files:**
- Modify: `internal/base/server/server.go`

**Interfaces:**
- Consumes: Config, clients, router
- Produces: Server startup with middleware chain

- [ ] **Step 1: Update server.go to initialize clients and register routes**

```go
// internal/base/server/server.go
package server

import (
    "context"
    "log"
    
    hertzframework "github.com/byx-darwin/go-tools/go-framework/hertz"
    
    "{{.Module}}/internal/base/conf"
    "{{.Module}}/internal/handler/health"
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
git add internal/base/server/server.go
git commit -m "feat(server): wire clients and router"
```

---

## Task 13: Export to Template + Assemble Package

**Files:**
- Create: `admin-bff-hertz/` directory (in repo root)
- Export: hertz-template/*.yaml via `ncgo export`

- [ ] **Step 1: Export templates**

```bash
cd .worktree/feat-12-admin-bff-hertz/admin-bff
ncgo export templates --kind hertz --output ../../../admin-bff-hertz/hertz-template/
```

- [ ] **Step 2: Assemble template package**

Copy IDL files:

```bash
mkdir -p ../../../admin-bff-hertz/idl
cp idl/*.proto ../../../admin-bff-hertz/idl/
```

Create template.yaml:

```yaml
# admin-bff-hertz/template.yaml
name: admin-bff-hertz
kind: hertz
description: "Official admin BFF Hertz HTTP template (JWT auth + RBAC authz via rbac-kitex + rate-limit rule management via rule-center)"
version: "1"
```

- [ ] **Step 3: Commit template package**

```bash
cd ../../..
git add admin-bff-hertz/
git commit -m "feat(admin-bff-hertz): export template package"
```

---

## Task 14: Verification

**Files:**
- Create: `admin-bff-hertz/test/e2e_test.sh`

- [ ] **Step 1: Create e2e test script**

```bash
#!/bin/bash
set -e

echo "=== E2E Test: admin-bff-hertz ==="

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "Generating project from template..."
ncgo new test-bff --module github.com/test/bff --kind hertz --template admin-bff-hertz

cd test-bff

echo "Building..."
go build ./...

echo "Running tests..."
go test ./...

cd /
rm -rf "$TMPDIR"

echo "=== E2E Test PASSED ==="
```

- [ ] **Step 2: Run e2e test**

```bash
chmod +x admin-bff-hertz/test/e2e_test.sh
./admin-bff-hertz/test/e2e_test.sh
```

Expected: Project generates, builds, and tests pass.

- [ ] **Step 3: Commit**

```bash
git add admin-bff-hertz/test/
git commit -m "test(admin-bff-hertz): add e2e verification"
```

---

## Summary

This revised plan follows the ncgo workflow:

1. ✅ Create worktree + generate base Hertz project
2. ✅ Extend configuration (JWT, gRPC sections)
3. ✅ pkg/client (rbac + rulecenter wrappers)
4. ✅ JWT middleware (HS256, public paths skip)
5. ✅ Authz middleware (RequirePermission → Enforce RPC)
6. ✅ Auth handlers (login, refresh, logout)
7. ✅ RBAC handlers (user, role, permission, menu)
8. ✅ Current user handlers (menus, perms)
9. ✅ Rate limit handlers (rule CRUD)
10. ✅ Router registration (with permission decorators)
11. ✅ Server entry point (wire clients)
12. ✅ Export to template via `ncgo export`
13. ✅ Assemble admin-bff-hertz/ package
14. ✅ E2E verification

Total: 14 tasks, TDD-style for Go code, then export to YAML templates.
