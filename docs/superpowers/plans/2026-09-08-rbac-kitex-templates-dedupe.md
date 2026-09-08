# rbac-kitex 模板去重 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 清理 `rbac-kitex/kitex-template` 目录下 9 组重复声明同一输出 `path:` 的模板文件（自动导出版本 vs 手工版本），并把该目录纳入 CI 重复路径检查。

**Architecture:** 每组重复按内容 diff 结论分两类处理：(a) 纯冗余（两份内容语义等价，仅转义/缩进不同）→ 直接删除多余一份；(b) 需要合并（其中一份含另一份没有的真实内容）→ 先把缺失字段/逻辑移植进保留的那份，再删除被合并掉的那份。全部改动完成后用 `scripts/check-duplicate-template-paths.sh` 和 `ncgo new scratch` 渲染+编译验证。

**Tech Stack:** YAML 模板文件（ncgo 模板 DSL）、Go 1.22、Kitex、bash

**Spec:** `docs/superpowers/specs/2026-09-08-kitex-templates-duplicate-cleanup-design.md`

## Global Constraints

- 判定规则：优先保留能正确使用模板变量（`{{ToLower .ServiceName}}` / `{{ToLower .ServiceInfo.ServiceName}}` / `{{.Module}}`）的版本；硬编码具体服务名/DSN 等字面值的版本视为缺陷，即使它是"exported"版本
- 每组处理完立即用 `scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template` 复核，不要攒到最后一次性验证
- 最终必须能通过 `ncgo new scratch --module github.com/acme/scratch --kind kitex --db none --dir /tmp/scratch-rbac-kitex --template-dir rbac-kitex/kitex-template && cd /tmp/scratch-rbac-kitex && go build ./... && go vet ./...`
- 目录：`rbac-kitex/kitex-template/`；工作目录：仓库根目录

---

### Task 1: 合并 `conf/dev/conf.yaml` 的 auth 字段，删除导出版重复

**Files:**
- Modify: `rbac-kitex/kitex-template/conf_dev.yaml`
- Delete: `rbac-kitex/kitex-template/conf_dev_conf_yaml.yaml`

**Interfaces:**
- Consumes: 无（YAML 配置模板，无跨任务类型依赖）
- Produces: `conf_dev.yaml` 渲染出的 `conf/dev/conf.yaml` 里新增 `auth.jwt_secret`、`auth.access_ttl_seconds`、`auth.refresh_ttl_seconds`、`auth.token_store` 三个键，供 Task 2 合并后的 `Config.Auth`（`AuthConfig.JWTSecret` 等字段）通过 `config.LoadYAML[Config]` 反序列化读取

- [ ] **Step 1: 确认当前重复（RED）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template 2>&1 | grep -A2 "conf/dev/conf.yaml"`
Expected: 输出显示 `conf_dev.yaml` 与 `conf_dev_conf_yaml.yaml` 两个文件都声明了 `path: conf/dev/conf.yaml`

- [ ] **Step 2: 编辑 `conf_dev.yaml`，在 `auth.caller_allowlist` 块后追加 auth 顶层字段**

把文件中这一段（第 34-45 行）：

```yaml
  # 调用方鉴权配置
  auth:
    caller_allowlist:
      # 是否启用调用方白名单校验
      enabled: false
      # 从哪个请求头读取调用方服务名
      header: x-caller-service
      # allowed_callers 中填写允许访问当前服务的上游服务名
      # 运维建议：开启 enabled 且 allow_missing=false 时，这里必须显式配置
      allowed_callers: []
      # 是否允许请求头缺失；false 时缺失会被拒绝
      allow_missing: false
```

替换为：

```yaml
  # 调用方鉴权配置
  auth:
    caller_allowlist:
      # 是否启用调用方白名单校验
      enabled: false
      # 从哪个请求头读取调用方服务名
      header: x-caller-service
      # allowed_callers 中填写允许访问当前服务的上游服务名
      # 运维建议：开启 enabled 且 allow_missing=false 时，这里必须显式配置
      allowed_callers: []
      # 是否允许请求头缺失；false 时缺失会被拒绝
      allow_missing: false
    # JWT 签名密钥；生产环境必须通过环境变量/密钥管理覆盖，不能使用此默认值
    jwt_secret: "dev-secret-change-me"
    # access token 有效期，单位秒
    access_ttl_seconds: 3600
    # refresh token 有效期，单位秒
    refresh_ttl_seconds: 604800
    # token 存储方式：memory | redis
    token_store: "memory"
```

- [ ] **Step 3: 删除导出版重复文件**

Run: `git rm rbac-kitex/kitex-template/conf_dev_conf_yaml.yaml`

- [ ] **Step 4: 验证该组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template 2>&1 | grep "conf/dev/conf.yaml"`
Expected: 无输出（该 path 不再出现在重复列表里）

- [ ] **Step 5: Commit**

```bash
git add rbac-kitex/kitex-template/conf_dev.yaml
git commit -m "fix(rbac-kitex): merge auth JWT fields into conf/dev/conf.yaml, drop duplicate export"
```

---

### Task 2: 合并 `internal/base/conf/conf.go` 的 Auth 结构体/校验，删除导出版重复

**Files:**
- Modify: `rbac-kitex/kitex-template/conf.yaml`
- Delete: `rbac-kitex/kitex-template/internal_base_conf_conf_go.yaml`

**Interfaces:**
- Consumes: Task 1 产出的 `conf/dev/conf.yaml` 新增 YAML 键（字段名必须与本任务新增的 Go struct tag 完全一致：`jwt_secret`/`access_ttl_seconds`/`refresh_ttl_seconds`/`token_store`）
- Produces: `Config.Auth` 新增字段 `JWTSecret string`、`AccessTTLSeconds int`、`RefreshTTLSeconds int`、`TokenStore string`、`RedisAddr string`，供 Task 4（server.go）里的 `cfg.Auth.JWTSecret`、`cfg.Auth.TokenStore`、`cfg.Auth.RedisAddr`、`cfg.Auth.AccessTTLSeconds`、`cfg.Auth.RefreshTTLSeconds` 引用

- [ ] **Step 1: 确认当前重复（RED）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template 2>&1 | grep -A2 "internal/base/conf/conf.go"`
Expected: 显示 `conf.yaml` 与 `internal_base_conf_conf_go.yaml` 都声明 `path: internal/base/conf/conf.go`

- [ ] **Step 2: 在 `conf.yaml` 的 `AuthConfig` struct 里新增字段**

把（第 52-54 行）：

```go
  type AuthConfig struct {
      CallerAllowlist CallerAllowlistConfig `json:"caller_allowlist" yaml:"caller_allowlist"`
  }
```

替换为：

```go
  type AuthConfig struct {
      CallerAllowlist   CallerAllowlistConfig `json:"caller_allowlist" yaml:"caller_allowlist"`
      JWTSecret         string                `json:"jwt_secret" yaml:"jwt_secret"`
      AccessTTLSeconds  int                   `json:"access_ttl_seconds" yaml:"access_ttl_seconds"`
      RefreshTTLSeconds int                   `json:"refresh_ttl_seconds" yaml:"refresh_ttl_seconds"`
      TokenStore        string                `json:"token_store" yaml:"token_store"` // memory | redis (seam)
      RedisAddr         string                `json:"redis_addr" yaml:"redis_addr"`
  }
```

- [ ] **Step 3: 在 `Default()` 的 `Auth:` 字面量里新增默认值**

把（第 248 行）：

```go
          Auth: AuthConfig{CallerAllowlist: CallerAllowlistConfig{Header: "x-caller-service"}},
```

替换为：

```go
          Auth: AuthConfig{
              CallerAllowlist:   CallerAllowlistConfig{Header: "x-caller-service"},
              JWTSecret:         "dev-secret-change-me",
              AccessTTLSeconds:  3600,
              RefreshTTLSeconds: 604800,
              TokenStore:        "memory",
          },
```

- [ ] **Step 4: 在 `Validate()` 里新增 JWT/TokenStore 校验**

把（第 296-303 行）：

```go
      if c.Auth.CallerAllowlist.Enabled {
          if c.Auth.CallerAllowlist.Header == "" {
              return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth.caller_allowlist.header is empty")
          }
          if !c.Auth.CallerAllowlist.AllowMissing && len(c.Auth.CallerAllowlist.AllowedCallers) == 0 {
              return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth.caller_allowlist.allowed_callers is empty")
          }
      }
```

替换为：

```go
      if c.Auth.CallerAllowlist.Enabled {
          if c.Auth.CallerAllowlist.Header == "" {
              return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth.caller_allowlist.header is empty")
          }
          if !c.Auth.CallerAllowlist.AllowMissing && len(c.Auth.CallerAllowlist.AllowedCallers) == 0 {
              return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth.caller_allowlist.allowed_callers is empty")
          }
      }
      if c.Auth.JWTSecret == "" {
          return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth.jwt_secret is empty")
      }
      if c.Auth.AccessTTLSeconds <= 0 || c.Auth.RefreshTTLSeconds <= 0 {
          return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth token TTLs must be positive")
      }
      switch c.Auth.TokenStore {
      case "", "memory", "redis":
      default:
          return goerror.In("config").Code(frameworkerror.CodeConfigInvalid).Public("config_invalid").New("auth.token_store must be memory or redis")
      }
```

- [ ] **Step 5: 删除导出版重复文件**

Run: `git rm rbac-kitex/kitex-template/internal_base_conf_conf_go.yaml`

- [ ] **Step 6: 验证该组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template 2>&1 | grep "internal/base/conf/conf.go"`
Expected: 无输出

- [ ] **Step 7: Commit**

```bash
git add rbac-kitex/kitex-template/conf.yaml
git commit -m "fix(rbac-kitex): merge JWT/token-store fields into conf.go template, drop duplicate export"
```

---

### Task 3: 删除 `internal/base/data/data.go` 的导出版重复

**Files:**
- Delete: `rbac-kitex/kitex-template/internal_base_data_data_go.yaml`
- Keep unchanged: `rbac-kitex/kitex-template/data.yaml`

**Interfaces:**
- Consumes: 无
- Produces: 无新接口（纯删除，两份内容语义一致，仅大括号转义/缩进不同）

- [ ] **Step 1: 复核两份内容语义一致（RED 前置检查）**

Run: `diff <(grep -v '^\s*$' rbac-kitex/kitex-template/data.yaml) <(grep -v '^\s*$' rbac-kitex/kitex-template/internal_base_data_data_go.yaml) | grep -viE '^\s*[<>]\s*(#|type:|body:|package|import|\)|\{\{|\}\})' | grep '^[<>]'`
Expected: 无实质性输出（唯一差异应是转义写法 `{` vs `{{ "{" }}`、`body: |-` vs `body: |`、缩进空格数，不应有函数签名/字段/逻辑级别的差异）。若发现除转义/缩进外的其它差异，STOP 并按 Task 1/2 的合并模式处理，不要直接删除。

- [ ] **Step 2: 删除导出版重复文件**

Run: `git rm rbac-kitex/kitex-template/internal_base_data_data_go.yaml`

- [ ] **Step 3: 验证该组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template 2>&1 | grep "internal/base/data/data.go"`
Expected: 无输出

- [ ] **Step 4: Commit**

```bash
git add -A rbac-kitex/kitex-template/internal_base_data_data_go.yaml
git commit -m "chore(rbac-kitex): drop redundant exported duplicate of data.go template"
```

---

### Task 4: 删除 `internal/base/server/server.go` 的硬编码版本，保留正确参数化的版本

**Files:**
- Delete: `rbac-kitex/kitex-template/server.yaml`
- Keep unchanged: `rbac-kitex/kitex-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes: Task 2 产出的 `Config.Auth.RedisAddr`（`internal_base_server_server_go.yaml` 里 `token.NewRedisStore(cfg.Auth.RedisAddr, "{{ToLower .ServiceName}}")` 依赖该字段存在）
- Produces: 无新接口

**背景**：两份文件内容几乎逐字节相同（都是 `# ncgo exported template` 注释头），唯一差异在这一行：`server.yaml` 写死 `token.NewRedisStore(cfg.Auth.RedisAddr, "rbac")`，而 `internal_base_server_server_go.yaml` 正确使用 `token.NewRedisStore(cfg.Auth.RedisAddr, "{{ToLower .ServiceName}}")`。保留后者，删除前者。

- [ ] **Step 1: 复核差异仅限该硬编码行（RED 前置检查）**

Run: `diff rbac-kitex/kitex-template/server.yaml rbac-kitex/kitex-template/internal_base_server_server_go.yaml`
Expected: 只有一行差异——`"rbac"` vs `"{{ToLower .ServiceName}}"`

- [ ] **Step 2: 删除硬编码版本**

Run: `git rm rbac-kitex/kitex-template/server.yaml`

- [ ] **Step 3: 验证该组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template 2>&1 | grep "internal/base/server/server.go"`
Expected: 无输出

- [ ] **Step 4: Commit**

```bash
git add -A rbac-kitex/kitex-template/server.yaml
git commit -m "fix(rbac-kitex): drop server.go template with hardcoded token-store service name"
```

---

### Task 5: 删除 `interceptor.go` / `interceptor_test.go` / `rpcerror.go` / `rpcerror_test.go` / `main.go` 的导出版重复

**Files:**
- Delete: `rbac-kitex/kitex-template/internal_pkg_interceptor_interceptor_go.yaml`
- Delete: `rbac-kitex/kitex-template/internal_pkg_interceptor_interceptor_test_go.yaml`
- Delete: `rbac-kitex/kitex-template/internal_pkg_rpcerror_rpcerror_go.yaml`
- Delete: `rbac-kitex/kitex-template/internal_pkg_rpcerror_rpcerror_test_go.yaml`
- Delete: `rbac-kitex/kitex-template/main_go.yaml`
- Keep unchanged: `interceptor.yaml`、`interceptor_test.yaml`、`rpcerror.yaml`、`rpcerror_test.yaml`、`main.yaml`

**Interfaces:**
- Consumes: 无
- Produces: 无新接口（5 组均已在设计文档 diff 阶段确认内容语义一致，仅转义/缩进不同）

- [ ] **Step 1: 逐组复核语义一致（RED 前置检查）**

Run:
```bash
for pair in \
  "interceptor.yaml internal_pkg_interceptor_interceptor_go.yaml" \
  "interceptor_test.yaml internal_pkg_interceptor_interceptor_test_go.yaml" \
  "rpcerror.yaml internal_pkg_rpcerror_rpcerror_go.yaml" \
  "rpcerror_test.yaml internal_pkg_rpcerror_rpcerror_test_go.yaml" \
  "main.yaml main_go.yaml"; do
  read -r a b <<< "$pair"
  echo "=== $a vs $b ==="
  diff <(grep -v '^\s*$' "rbac-kitex/kitex-template/$a") <(grep -v '^\s*$' "rbac-kitex/kitex-template/$b") \
    | grep -viE '^\s*[<>]\s*(#|type:|body:|package|import|\)|\{\{|\}\})' | grep '^[<>]'
done
```
Expected: 每组都无实质性输出。若某组出现字段/逻辑级别差异，STOP，改用 Task 1/2 的合并模式单独处理该组，不要在本任务里直接删除。

- [ ] **Step 2: 删除 5 个导出版重复文件**

Run:
```bash
git rm \
  rbac-kitex/kitex-template/internal_pkg_interceptor_interceptor_go.yaml \
  rbac-kitex/kitex-template/internal_pkg_interceptor_interceptor_test_go.yaml \
  rbac-kitex/kitex-template/internal_pkg_rpcerror_rpcerror_go.yaml \
  rbac-kitex/kitex-template/internal_pkg_rpcerror_rpcerror_test_go.yaml \
  rbac-kitex/kitex-template/main_go.yaml
```

- [ ] **Step 3: 验证全部重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rbac-kitex/kitex-template; echo "exit=$?"`
Expected: 无重复输出，`exit=0`

- [ ] **Step 4: Commit**

```bash
git add -A rbac-kitex/kitex-template/internal_pkg_interceptor_interceptor_go.yaml \
  rbac-kitex/kitex-template/internal_pkg_interceptor_interceptor_test_go.yaml \
  rbac-kitex/kitex-template/internal_pkg_rpcerror_rpcerror_go.yaml \
  rbac-kitex/kitex-template/internal_pkg_rpcerror_rpcerror_test_go.yaml \
  rbac-kitex/kitex-template/main_go.yaml
git commit -m "chore(rbac-kitex): drop remaining redundant exported template duplicates"
```

---

### Task 6: 渲染 + 编译验证，接入 CI 重复路径检查

**Files:**
- Modify: `.github/workflows/template-build-check.yml`

**Interfaces:**
- Consumes: Task 1-5 清理后的 `rbac-kitex/kitex-template`（必须先完成全部前置任务，本任务才能通过）
- Produces: 无（终态验证 + CI 收口）

- [ ] **Step 1: 本地渲染 + 编译验证（RED 前置：先确认命令可执行）**

Run:
```bash
go install github.com/byx-darwin/ncgo@latest
ncgo new scratch \
  --module github.com/acme/scratch \
  --kind kitex \
  --db none \
  --dir /tmp/scratch-rbac-kitex \
  --template-dir rbac-kitex/kitex-template
cd /tmp/scratch-rbac-kitex
go build ./...
go vet ./...
cd -
```
Expected: `go build ./...` 与 `go vet ./...` 均无错误退出（exit 0）。若编译失败，报错信息会指出具体缺失的字段/类型——回到对应 Task 修正后重新执行本步骤，不要跳过。

- [ ] **Step 2: 把 `rbac-kitex/kitex-template` 加入 CI 重复检查列表**

编辑 `.github/workflows/template-build-check.yml`，把（第 24-27 行）：

```yaml
      # rbac-kitex, admin-services-kitex, and rule-center still have unresolved duplicate
      # path: declarations (tracked as Issue #52 follow-ups); add them here once cleaned up.
      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template
```

替换为：

```yaml
      # admin-services-kitex and rule-center still have unresolved duplicate
      # path: declarations (tracked as Issue #43 follow-ups); add them here once cleaned up.
      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template
```

- [ ] **Step 3: 验证 CI 配置改动本身语法正确**

Run: `bash scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template; echo "exit=$?"`
Expected: 无重复输出，`exit=0`（与 CI 里新命令行为一致）

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/template-build-check.yml
git commit -m "ci(templates): add rbac-kitex/kitex-template to duplicate-path check"
```

---

## Self-Review Checklist（执行前已完成）

- **Spec 覆盖**：设计文档里 rbac-kitex 判定方法论（默认保留导出版、例外情况需 diff 判定）已逐组落实到 Task 1-5；CI 收口对应 Task 6。
- **占位符扫描**：无 TBD/TODO，所有 diff/替换块均为实际内容。
- **类型一致性**：`AuthConfig` 新增字段名（`JWTSecret`/`AccessTTLSeconds`/`RefreshTTLSeconds`/`TokenStore`/`RedisAddr`）在 Task 2 定义、Task 4 引用处完全一致；YAML 字段名（`jwt_secret`/`access_ttl_seconds`/`refresh_ttl_seconds`/`token_store`）在 Task 1（YAML 值）与 Task 2（struct tag）完全一致。
