# admin-services-kitex 模板去重 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 清理 `admin-services-kitex/kitex-template` 目录下 19 组重复声明同一输出 `path:` 的模板文件，并把该目录纳入 CI 重复路径检查。

**Architecture:** 与 rbac-kitex（#57）方法论一致：按内容 diff 结论分两类处理——(a) 纯冗余，直接删除多余一份；(b) 需要合并，先把缺失字段移植进保留的那份再删除。本次 19 组中只有 2 组（conf/dev/conf.yaml、conf.go）需要合并 Auth JWT/token-store 字段；1 组（server.go）是从 rbac-kitex 整份复制粘贴遗留的过期文件，直接删除；其余 16 组是纯格式/转义差异的冗余。

**Tech Stack:** YAML 模板文件（ncgo 模板 DSL）、Go 1.22、Kitex、bash

**Spec:** `docs/superpowers/specs/2026-09-08-kitex-templates-duplicate-cleanup-design.md`

## Global Constraints

- 判定规则：优先保留能正确使用模板变量（`{{ToLower .ServiceName}}` / `{{ToLower .ServiceInfo.ServiceName}}` / `{{.Module}}`）的版本；硬编码具体服务名/DSN/其它服务专属内容的版本视为缺陷
- **合并范围严格限定为"存活模板实际引用的字段"**：已验证 `internal_base_server_server_go.yaml`（保留的 server.go）只引用 `cfg.Auth.JWTSecret`/`TokenStore`/`RedisAddr`/`AccessTTLSeconds`/`RefreshTTLSeconds`；导出版 `internal_base_conf_conf_go.yaml` 额外声明的顶层 `Redis RedisConfig` 字段和 `conf_dev_conf_yaml.yaml` 的顶层 `redis:`/`rate_limit:` YAML 块，经排查**没有任何存活模板引用**（`internal/base/middleware/ratelimit.go` 里的 `cfg.Redis` 是 `RateLimitConfig.Redis`，与顶层字段同名但不同结构体；`conf.yaml` 现有的 `RateLimitConfig`/`Default()` 本来就已经完整存在，与本次去重无关）——**不合并这两块，避免引入死代码**
- 每组处理完立即用 `scripts/check-duplicate-template-paths.sh admin-services-kitex/kitex-template` 复核
- 最终必须能通过 `ncgo new scratch --module github.com/acme/scratch --kind kitex --db none --dir /tmp/scratch-admin-services-kitex --template-dir admin-services-kitex && cd /tmp/scratch-admin-services-kitex && go build ./... && go vet ./...`
- 目录：`admin-services-kitex/kitex-template/`；工作目录：仓库根目录

---

### Task 1: 合并 `conf/dev/conf.yaml` 的 auth 字段，删除导出版重复

**Files:**
- Modify: `admin-services-kitex/kitex-template/conf_dev.yaml`
- Delete: `admin-services-kitex/kitex-template/conf_dev_conf_yaml.yaml`

**Interfaces:**
- Consumes: 无
- Produces: `conf_dev.yaml` 渲染出的 `conf/dev/conf.yaml` 里新增 `auth.jwt_secret`、`auth.access_ttl_seconds`、`auth.refresh_ttl_seconds`、`auth.token_store`、`auth.redis_addr` 五个键，供 Task 2 合并后的 `Config.Auth`（`AuthConfig.JWTSecret` 等字段）通过 `config.LoadYAML[Config]` 反序列化读取。**注意**：`Load()` 用 YAML 解析结果整体替换 `Default()`（`*cfg = *loaded`），所以这些键在 YAML 里缺失会导致对应字段变成 Go 零值（`JWTSecret=""`），进而在 Task 2 新增的 `Validate()` 校验里报错——这不是文档性补充，是功能必需。

- [ ] **Step 1: 确认当前重复（RED）**

Run: `bash scripts/check-duplicate-template-paths.sh admin-services-kitex/kitex-template 2>&1 | grep -A2 "conf/dev/conf.yaml"`
Expected: 显示 `conf_dev.yaml` 与 `conf_dev_conf_yaml.yaml` 都声明 `path: conf/dev/conf.yaml`

- [ ] **Step 2: 编辑 `conf_dev.yaml`，在 `auth.caller_allowlist` 块前追加 auth 顶层字段**

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
    # JWT 签名密钥；生产环境必须通过环境变量/密钥管理覆盖，不能使用此默认值
    jwt_secret: "dev-secret-change-me"
    # access token 有效期，单位秒
    access_ttl_seconds: 3600
    # refresh token 有效期，单位秒
    refresh_ttl_seconds: 604800
    # token 存储方式：memory | redis
    token_store: "memory"
    # 当 token_store=redis 时使用的 Redis 地址
    redis_addr: "127.0.0.1:6379"
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

（`refresh_ttl_seconds` 取 604800，与 Task 2 合并进 conf.go 的 `Default()` 字面量保持一致——被删除的导出版 YAML 里写的是 86400，与其自身 Go `Default()` 里的 604800 不一致，这是导出快照的历史遗留错误，不沿用）

- [ ] **Step 3: 删除导出版重复文件**

Run: `git rm admin-services-kitex/kitex-template/conf_dev_conf_yaml.yaml`

- [ ] **Step 4: 验证该组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh admin-services-kitex/kitex-template 2>&1 | grep "conf/dev/conf.yaml"`
Expected: 无输出

- [ ] **Step 5: Commit**

```bash
git add admin-services-kitex/kitex-template/conf_dev.yaml
git commit -m "fix(admin-services-kitex): merge auth JWT fields into conf/dev/conf.yaml, drop duplicate export"
```

---

### Task 2: 合并 `internal/base/conf/conf.go` 的 Auth 结构体/校验，删除导出版重复

**Files:**
- Modify: `admin-services-kitex/kitex-template/conf.yaml`
- Delete: `admin-services-kitex/kitex-template/internal_base_conf_conf_go.yaml`

**Interfaces:**
- Consumes: Task 1 产出的 YAML 键（字段名必须与本任务新增的 Go struct tag 完全一致）
- Produces: `Config.Auth` 新增字段 `JWTSecret string`、`AccessTTLSeconds int`、`RefreshTTLSeconds int`、`TokenStore string`、`RedisAddr string`，供 Task 3 里保留的 server.go 模板引用（`cfg.Auth.JWTSecret`、`cfg.Auth.TokenStore`、`cfg.Auth.RedisAddr`、`cfg.Auth.AccessTTLSeconds`、`cfg.Auth.RefreshTTLSeconds`）

**范围说明**：`internal_base_conf_conf_go.yaml`（待删除的导出版）里额外声明的顶层 `Redis RedisConfig` 字段（插在 `Database` 和 `RateLimit` 之间）**不要合并**——已确认没有任何存活模板引用 `cfg.Redis`（顶层），只有 `cfg.RateLimit.Redis`（已存在于 `conf.yaml` 现有的 `RateLimitConfig` 结构体里，与本次去重无关）。

- [ ] **Step 1: 确认当前重复（RED）**

Run: `bash scripts/check-duplicate-template-paths.sh admin-services-kitex/kitex-template 2>&1 | grep -A2 "internal/base/conf/conf.go"`
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

Run: `git rm admin-services-kitex/kitex-template/internal_base_conf_conf_go.yaml`

- [ ] **Step 6: 验证该组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh admin-services-kitex/kitex-template 2>&1 | grep "internal/base/conf/conf.go"`
Expected: 无输出

- [ ] **Step 7: Commit**

```bash
git add admin-services-kitex/kitex-template/conf.yaml
git commit -m "fix(admin-services-kitex): merge JWT/token-store fields into conf.go template, drop duplicate export"
```

---

### Task 3: 批量删除 17 组纯冗余重复（含 1 组跨服务复制粘贴遗留）

**Files:**
- Delete（跨服务复制粘贴遗留，注释头写着 "Edited for rbac-kitex"、硬编码 `"rbac"`、缺失 RuleService 相关 handler/repo 依赖注入）：
  - `admin-services-kitex/kitex-template/server.yaml`
- Delete（内容语义与保留版一致，仅转义/缩进/注释头差异，已逐组核实无字段级差异）：
  - `admin-services-kitex/kitex-template/data.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_middleware_test.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_middleware.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_handler.yaml`
  - `admin-services-kitex/kitex-template/interceptor_test.yaml`
  - `admin-services-kitex/kitex-template/interceptor.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_shared_rule_center_client.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_shared_resolver_test.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_shared_resolver.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_shared_store_test.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_shared_store.yaml`
  - `admin-services-kitex/kitex-template/rpcerror_test.yaml`
  - `admin-services-kitex/kitex-template/rpcerror.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_repository.yaml`
  - `admin-services-kitex/kitex-template/ratelimit_usecase.yaml`
  - `admin-services-kitex/kitex-template/main.yaml`
- Keep unchanged（对应的保留版，路径与上面一一对应，见 Step 1 的完整映射表）

**Interfaces:**
- Consumes: 无
- Produces: 无新接口（纯删除）

- [ ] **Step 1: 逐组复核语义一致 / 确认跨服务遗留（RED 前置检查）**

对下表每一行运行归一化 diff（剥离缩进、注释头、`body: |` vs `body: |-`、`{` 与 `{{ "{" }}` 转义差异后比较）：

| KEEP（保留） | DELETE（删除） |
|---|---|
| `internal_base_server_server_go.yaml` | `server.yaml` |
| `internal_base_data_data_go.yaml` | `data.yaml` |
| `internal_base_middleware_ratelimit_test_go.yaml` | `ratelimit_middleware_test.yaml` |
| `internal_base_middleware_ratelimit_go.yaml` | `ratelimit_middleware.yaml` |
| `internal_handler_rulecenter_handler_go.yaml` | `ratelimit_handler.yaml` |
| `internal_pkg_interceptor_interceptor_test_go.yaml` | `interceptor_test.yaml` |
| `internal_pkg_interceptor_interceptor_go.yaml` | `interceptor.yaml` |
| `internal_pkg_middleware_rule_center_client_go.yaml` | `ratelimit_shared_rule_center_client.yaml` |
| `internal_pkg_ratelimit_resolver_test_go.yaml` | `ratelimit_shared_resolver_test.yaml` |
| `internal_pkg_ratelimit_resolver_go.yaml` | `ratelimit_shared_resolver.yaml` |
| `internal_pkg_ratelimit_store_test_go.yaml` | `ratelimit_shared_store_test.yaml` |
| `internal_pkg_ratelimit_store_go.yaml` | `ratelimit_shared_store.yaml` |
| `internal_pkg_rpcerror_rpcerror_test_go.yaml` | `rpcerror_test.yaml` |
| `internal_pkg_rpcerror_rpcerror_go.yaml` | `rpcerror.yaml` |
| `internal_repository_rulecenter_repo_go.yaml` | `ratelimit_repository.yaml` |
| `internal_usecase_rulecenter_usecase_go.yaml` | `ratelimit_usecase.yaml` |
| `main_go.yaml` | `main.yaml` |

对 `server.yaml` 单独确认（不是格式化 diff，是完整内容审查）：`head -6 admin-services-kitex/kitex-template/server.yaml` 应显示注释 `// Code generated by kitex generator. Edited for rbac-kitex.`，且 `grep -c "rulehandler\|rulerepo" admin-services-kitex/kitex-template/server.yaml` 应为 0（证明这是从 rbac-kitex 整份复制、从未适配 admin-services-kitex 的 RuleService 依赖）。

对其余 16 组：若归一化 diff 发现除转义/缩进/注释头外的字段、函数签名、逻辑分支级别差异，STOP 并报告该组具体差异，不要删除，改用 Task 1/2 的合并模式单独处理。

- [ ] **Step 2: 删除全部 17 个文件**

Run:
```bash
git rm \
  admin-services-kitex/kitex-template/server.yaml \
  admin-services-kitex/kitex-template/data.yaml \
  admin-services-kitex/kitex-template/ratelimit_middleware_test.yaml \
  admin-services-kitex/kitex-template/ratelimit_middleware.yaml \
  admin-services-kitex/kitex-template/ratelimit_handler.yaml \
  admin-services-kitex/kitex-template/interceptor_test.yaml \
  admin-services-kitex/kitex-template/interceptor.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_rule_center_client.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_resolver_test.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_resolver.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_store_test.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_store.yaml \
  admin-services-kitex/kitex-template/rpcerror_test.yaml \
  admin-services-kitex/kitex-template/rpcerror.yaml \
  admin-services-kitex/kitex-template/ratelimit_repository.yaml \
  admin-services-kitex/kitex-template/ratelimit_usecase.yaml \
  admin-services-kitex/kitex-template/main.yaml
```

- [ ] **Step 3: 验证全部重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh admin-services-kitex/kitex-template; echo "exit=$?"`
Expected: 无重复输出，`exit=0`

- [ ] **Step 4: Commit**

```bash
git add -A admin-services-kitex/kitex-template/server.yaml \
  admin-services-kitex/kitex-template/data.yaml \
  admin-services-kitex/kitex-template/ratelimit_middleware_test.yaml \
  admin-services-kitex/kitex-template/ratelimit_middleware.yaml \
  admin-services-kitex/kitex-template/ratelimit_handler.yaml \
  admin-services-kitex/kitex-template/interceptor_test.yaml \
  admin-services-kitex/kitex-template/interceptor.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_rule_center_client.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_resolver_test.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_resolver.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_store_test.yaml \
  admin-services-kitex/kitex-template/ratelimit_shared_store.yaml \
  admin-services-kitex/kitex-template/rpcerror_test.yaml \
  admin-services-kitex/kitex-template/rpcerror.yaml \
  admin-services-kitex/kitex-template/ratelimit_repository.yaml \
  admin-services-kitex/kitex-template/ratelimit_usecase.yaml \
  admin-services-kitex/kitex-template/main.yaml
git commit -m "fix(admin-services-kitex): drop 17 redundant template duplicates (incl. stale rbac-kitex copy of server.go)"
```

---

### Task 4: 渲染 + 编译验证，接入 CI 重复路径检查

**Files:**
- Modify: `.github/workflows/template-build-check.yml`

**Interfaces:**
- Consumes: Task 1-3 清理后的 `admin-services-kitex/kitex-template`（必须先完成全部前置任务，本任务才能通过）
- Produces: 无（终态验证 + CI 收口）

- [ ] **Step 1: 本地渲染 + 编译验证**

Run:
```bash
command -v ncgo || go install github.com/byx-darwin/ncgo@latest
ncgo new scratch \
  --module github.com/acme/scratch \
  --kind kitex \
  --db none \
  --dir /tmp/scratch-admin-services-kitex \
  --template-dir admin-services-kitex
cd /tmp/scratch-admin-services-kitex
go build ./...
go vet ./...
cd -
```
Expected: `go build ./...` 与 `go vet ./...` 均无错误退出（exit 0）。**注意**：`--template-dir` 必须指向模板包目录 `admin-services-kitex`（含 `template.yaml` 清单），不是 `admin-services-kitex/kitex-template` 本身——这是 `ncgo` CLI 的既有用法（与 `.github/workflows/template-build-check.yml` 现有 `build-check` job 的 `matrix.name: admin-services-kitex` 用法一致），不是本任务引入的新约定。若编译失败，报错会指出具体缺失的字段/类型——回到对应 Task 修正后重新执行本步骤。

- [ ] **Step 2: 把 `admin-services-kitex/kitex-template` 加入 CI 重复检查列表**

编辑 `.github/workflows/template-build-check.yml`，把（当前内容，紧跟在上一次 #57 PR 更新后的状态）：

```yaml
      # admin-services-kitex and rule-center still have unresolved duplicate
      # path: declarations (tracked as Issue #43 follow-ups); add them here once cleaned up.
      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template
```

替换为：

```yaml
      # rule-center still has unresolved duplicate path: declarations
      # (tracked as Issue #43 follow-up); add it here once cleaned up.
      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template admin-services-kitex/kitex-template
```

（若实际文件当前内容与上面引用的"当前内容"不完全一致，以 `git show HEAD:.github/workflows/template-build-check.yml` 的真实内容为准，只改 `Check for duplicate path declarations` 这一步的命令行和紧邻的注释，其余不动）

- [ ] **Step 3: 验证 CI 配置改动本身语法正确**

Run: `bash scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template admin-services-kitex/kitex-template; echo "exit=$?"`
Expected: 无重复输出，`exit=0`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/template-build-check.yml
git commit -m "ci(templates): add admin-services-kitex/kitex-template to duplicate-path check"
```

---

## Self-Review Checklist（执行前已完成）

- **Spec 覆盖**：19 组重复全部落实到 Task 1-3（2 组合并 + 1 组跨服务遗留删除 + 16 组纯冗余删除）；CI 收口对应 Task 4。
- **占位符扫描**：无 TBD/TODO，所有代码块均从实际文件内容核实后照抄。
- **类型一致性**：`AuthConfig` 新增字段名在 Task 2 定义、Task 3 里保留的 server.go 引用处完全一致；YAML 字段名在 Task 1（YAML 值）与 Task 2（struct tag）完全一致。
- **范围裁剪**：明确排除了导出版里存在但无存活模板引用的顶层 `Redis` 字段和 `redis:`/`rate_limit:` YAML 块，避免引入死代码（已用 `grep` 核实 `cfg.Redis`/`c.Redis` 的唯一用法是 `RateLimitConfig.Redis`，与顶层字段同名不同源）。
