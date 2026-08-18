# 设计文档：基于 base-hertz 重新调整 ratelimit-hertz 模版

- **日期**：2026-08-18
- **workflow**：wf-2026-08-18-001（gf-workflow，full 模式）
- **分类**：架构级（跨 ~45 个模板文件的作者风格重构 + 新增端到端测试）

## 1. 背景与问题

仓库内有两个 Hertz 模板包：

- **base-hertz**：手写、干净的参考模版。
  - 扁平文件名（`server_go.yaml`），共 14 个文件。
  - `body: |-` 块标量，**字面量花括号**。
  - 真正的 `{{if .WithDatabase}}…{{end}}` 条件。
  - 描述性头部注释（`# Hertz custom template — <path>`）。
  - **完整 wiring**：`health.Register(h)`、`router.GeneratedRegister(h)`、DDD/DB 条件块。
- **ratelimit-hertz**：ncgo 机器导出的模版。
  - 路径编码文件名（`internal_pkg_middleware_cors_go.yaml`），共 ~45 个文件。
  - 每个花括号被转义为 `{{ "{" }}` / `{{ "}" }}`，可读性/可维护性差。
  - 通用头部注释（`# ncgo exported template — <path>`）。
  - **wiring 不完整**：server.go 有空的 "Register routes"，未注册 health/router，无 WithDatabase 条件。
  - 但携带**完整的限流 + 中间件 + i18n 栈**（限流的核心价值）。

**目标**：让 ratelimit-hertz 全面对齐 base-hertz 的规范与作者风格，同时**完整保留限流能力**；并新增「ncgo 加载模版后」的端到端测试，保证还原后的模版能真实生成、编译、通过测试。

## 2. 决策记录（brainstorming 澄清结论）

| # | 决策点 | 结论 |
|---|--------|------|
| 1 | 重构目标 | **全面对齐规范**（风格 + wiring + README + 变量约定），保留限流能力 |
| 2 | 文件名约定 | **保留路径编码名**（~45 文件，中间件众多，路径编码避免歧义） |
| 3 | 9 个重叠基础文件 | **以 base 内容为基座 + 限流叠加** |
| 4 | 测试文件（~15 个 `*_test_go.yaml`） | **保留并改风格**（不丢弃） |
| 5 | 端到端测试形式 | **shell 脚本** `ratelimit-hertz/test/e2e_test.sh` |
| 6 | 端到端依赖范围 | **hermetic(memory) 基线 + redis 变体 + postgres 变体**，后两者按服务可用性 gated（不可用则 skip） |

## 3. 文件清单与映射

### 3.1 重叠的 9 个基础文件（以 base 内容为基座）

| 目标路径 | base 文件 | ratelimit 文件 | 处理 |
|----------|-----------|----------------|------|
| `main.go` | `main_go.yaml` | `main_go.yaml` | 采用 base 内容 |
| `internal/base/server/server.go` | `server_go.yaml` | `internal_base_server_server_go.yaml` | base 基座 + 限流中间件注入 + 补齐 health/router/WithDatabase wiring |
| `internal/base/conf/conf.go` | `conf_go.yaml` | `internal_base_conf_conf_go.yaml` | base 基座 + `rate_limit` 配置结构 |
| `internal/base/data/data.go` | `data_go.yaml` | `internal_base_data_data_go.yaml` | base 基座 + redis 相关 |
| `internal/pkg/errcode/errcode.go` | `errcode_go.yaml` | `internal_pkg_errcode_errcode_go.yaml` | base 基座 + 限流所需错误码 |
| `internal/pkg/middleware/middleware.go` | `middleware_go.yaml` | `internal_pkg_middleware_middleware_go.yaml` | base 基座 + 限流中间件装配 |
| `internal/pkg/response/response.go` | `response_go.yaml` | `internal_pkg_response_response_go.yaml` | 采用 base 内容（保留限流所需扩展） |
| `conf/dev/conf.yaml` | `conf_dev_yaml.yaml` | `conf_dev_conf_yaml.yaml` | base 基座 + `rate_limit:` 段 |
| `Makefile` | `makefile_yaml.yaml` | `Makefile.yaml` | 采用 base 内容 |

> 注：base-hertz 的 `server.go` 已引用 `repository.NewRateLimitRuleRepository`，两模板本已概念重叠，叠加限流内容不冲突。

### 3.2 限流专属文件（保留内容，原地改风格 + 补齐注册）

- 中间件：`cors`、`error`、`idempotency`、`memory_cache`、`observability`、`rate_limit`、`redis_client`、`signature`、`skip`、`token`
- 限流核心：`ratelimit/resolver`、`ratelimit/store`
- 其它：`i18n`、`handler/health/health`、`handler/pb/{{ToLower .ServiceName}}_service`、`router/register`、`router/pb/{{ToLower .ServiceName}}`、`router/pb/middleware`、`repository/rate_limit_rule`、`base/data/{redis,redis_shared,tx}`
- 对应 `*_test.go` 测试文件：保留并同样改风格

### 3.3 base 独有、ratelimit 未携带的文件

base-hertz 有 DDD 栈（`repository/…repo/repo.go`、`usecase/…/usecase.go`、`db/sqlc.yaml`）。ratelimit-hertz **不引入**这些（它用自己的 `repository/rate_limit_rule.go`），除非 server.go 的 `{{if .WithDatabase}}` 分支需要——按对齐 base wiring 的最小必要引入。

## 4. 作者风格转换规则（适用于所有 `.yaml`）

1. 机器转义 `{{ "{" }}` / `{{ "}" }}` → **字面量 `{` / `}`**，放入 `body: |-` 块标量。
2. 头部注释 `# ncgo exported template — <path>` → `# Hertz custom template — <path>` + 一行用途说明。
3. 生成期分支使用真正的 `{{if .WithDatabase}}…{{end}}`，而非展平输出。
4. `path:` 与 `update_behavior:` 键保持不变。
5. 变量约定统一：`{{.Module}}`、`{{.ServiceName}}`、`{{ToLower .ServiceName}}`。

## 5. 元数据对齐

- `template.yaml`：保持原样（已正确）。
- `README.md`：重构为 base-hertz 章节结构（Use / Contents / Variables / Features / Project Structure / Configuration / Development / License），保留限流专属内容（算法、backend、示例）。

## 6. ncgo 加载模版后的端到端测试（新增）

落地 `ratelimit-hertz/test/e2e_test.sh`，作为交付前核心质量门。

### 6.1 基线（hermetic，必跑）
1. 生成：`ncgo new <tmp-svc> --module <test-mod> --kind hertz --template-dir <repo>/ratelimit-hertz` 到临时目录（默认 `backend: memory`）。
2. 静态断言：产物中**无残留 `{{ ... }}` 未解析标记**、无空的半连接 wiring。
3. 编译：生成项目内 `go build ./...`。
4. 测试：`go test ./...` 跑通模版自带 `*_test.go`。
5. 清理：临时目录用完即删（trap 保证）。

### 6.2 redis 变体（gated）
- 检测本地 Redis（如 `redis-cli ping`）可用 → 生成 `--infra redis` + `backend: redis` 变体，`go build` + `ncgo test rate-limit` 验证限流行为；不可用则 **skip 并打印原因**。

### 6.3 postgres 变体（gated）
- 检测本地 Postgres 可用 → 生成 `--db postgres` 变体，走 `{{if .WithDatabase}}` 分支，`go build ./...` + `go test ./...`；不可用则 **skip 并打印原因**。

> 静默跳过是禁止的：任何被 skip 的变体必须显式输出「skipped: <原因>」。

## 7. 验证策略

交付前质量门 = 静态检查 + 端到端测试：

- (a) 每个 `.yaml` YAML 合法。
- (b) 全仓无残留 `{{ "{" }}` / `{{ "}" }}` 转义。
- (c) 重叠的 9 个文件与 base-hertz 逐一 diff，除已记录的限流叠加外内容一致。
- (d) `e2e_test.sh` 基线通过（生成 → 无残留标记 → build → test）。
- (e) redis / postgres 变体在服务可用时通过、不可用时显式 skip。

## 8. 范围与非目标

- **范围**：仅 `ratelimit-hertz/` 目录内的模板文件、README、新增 test 脚本。
- **非目标**：不改 base-hertz；不改 ncgo CLI；不引入 CI 配置（仓库当前无 `.github/workflows`，脚本可后续接入 CI）。

## 9. 风险

| 风险 | 缓解 |
|------|------|
| 还原转义时误改花括号语义（Go 代码 vs 模板动作） | 端到端 `go build` 兜底；逐文件 gofmt 渲染抽查 |
| redis/postgres 变体在无服务环境失败 | gated skip，仅 hermetic 基线为必跑门 |
| 叠加限流内容破坏 base 基座一致性 | 重叠文件与 base diff 审查（验证 c） |
