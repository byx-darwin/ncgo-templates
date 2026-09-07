# base-hertz: 删除残留的 rate-limit 死代码（Issue #42）

> **修订记录**：初版结论(方案 1：补齐限流能力)在执行阶段被推翻，见下方
> 「根因（修订）」。当前版本采纳 **方案 2（删除）**。

## 问题

`base-hertz` 模板的 `internal_repository_rate_limit_rule_go.yaml` import 了
`{{.Module}}/internal/pkg/ratelimit`，`server.go` 也引用了
`repository.NewRateLimitRuleRepository()`，但模板目录下没有任何文件生成
`internal/pkg/ratelimit` 包本身，按该模板生成的项目 `go build` 直接失败。

## 根因（修订）

初版分析认为 `base-hertz` 的 `conf.go` 已有完整 `RateLimitConfig` 和
repository 层，因此判断"原本就打算内置完整限流能力，只是漏拷贝了核心包"，
采纳方案 1。**这个结论是错的**，在 Phase 3 执行阶段（Task 1 RED 复现）
核对仓库文档时被推翻，证据如下：

1. `base-hertz/README.md` 第 15 行明确写着：**"This template does NOT
   include rate limiting. For services that need rate limiting, use
   `ratelimit-hertz` instead."**——base-hertz 的官方定位就是不带限流。
2. 引入 `RateLimitConfig` 的提交 `6aefd85`（"完善 Hertz 模板体系，统一中间件
   和错误码"）的提交信息明确写道：**"base-hertz（基础 HTTP 服务）...移除
   rate_limit（基础服务不限流）"**。
3. 但该提交的实际 diff 显示：`conf.go` 的 `RateLimitConfig`（及其 7 个子
   类型、默认值、校验逻辑，共 44 处引用）、`internal/repository/rate_limit_rule.go`、
   以及 `server.go` 里的 `repository.NewRateLimitRuleRepository()` 调用，
   都是**这次提交自己引入的**——说明当时"移除"并不彻底：只是没有生成
   `internal/pkg/ratelimit` 包和中间件装配代码，却把配置层/仓储层的死代码
   留了下来。

结论：这不是"漏拷贝导致的未完成功能"，而是**清理不彻底导致的残留死代码**。
`base-hertz` 本就不该有限流能力，正确修复是 Issue 中的**方案 2（删除）**，
且需要比 Issue 原描述更彻底——不仅删 repository 文件和 server.go 里的调用，
还要删掉 `conf.go` 里孤立的 `RateLimitConfig` 相关类型/默认值/校验函数。

## 方案

### 1. 删除 repository 模板文件

- `base-hertz/hertz-template/internal_repository_rate_limit_rule_go.yaml`
- `base-hertz/hertz-template/internal_repository_rate_limit_rule_test_go.yaml`

### 2. 清理 `server.go`（`internal_base_server_server_go.yaml`）

- 删除 `repository.NewRateLimitRuleRepository()` 调用（第 114 行）
- 删除现已无用的 `"{{.Module}}/internal/repository"` import（第 26 行；
  删除 repository 文件后，这是 `internal/repository` 包在 base-hertz 唯一的
  实现，import 会变成"imported and not used"编译错误）
- **保留** `dbData = do.MustInvoke[*data.Data](injector)` 及其上方的
  `do.New()`/`ProvideValue` 依赖注入脚手架——这段代码带有 `ncgo:wire:ddd`
  标记，是给后续 `ncgo add repository` 之类工具/开发者接入自己仓储层的
  扩展点，不是 rate-limit 专属代码，删除会超出本 issue 范围

### 3. 清理 `conf.go`（`internal_base_conf_conf_go.yaml`）

删除以下内容（均为 `RateLimitConfig` 专属，不影响 `RedisConfig`/
`MemoryCacheConfig`——这两个类型仍被 `Idempotency`/`Auth.Signature.Nonce`
复用，保留不动）：

- 顶层 `Config` 结构体的 `RateLimit RateLimitConfig` 字段
- 类型定义：`RateLimitConfig`、`StaticLimitConfig`、`RateLimitSourceConfig`、
  `RateLimitGRPCConfig`、`RateLimitDatabaseConfig`、`RateLimitPhaseConfig`、
  `RateLimitMatchConfig`、`RateLimitRuleConfig`（共 8 个类型）
- 默认值构造里的 `RateLimit: RateLimitConfig{...}` 字面量块
- `c.RateLimit.Redis = mergeRedisConfig(c.RateLimit.Redis, c.Redis)`
- `Validate()` 里的 `if c.RateLimit.Enabled { ... }` 校验块
- 四个校验辅助函数：`validateRateLimitPhase`、`validateRateLimitMatch`、
  `normalizeRateLimitMatch`、`validateRateLimitRule`

### 4. 更新 `conf_dev_conf_yaml.yaml` 里过时的注释

第 42 行注释"Redis 连接配置：作为共享默认值供 rate_limit / idempotency /
signature nonce 复用"提到的 `rate_limit` 已不存在，更新为
"idempotency / signature nonce"。

**不改动 `README.md`**——README 已经准确描述了 base-hertz 不含限流，本次
修复正是让代码与文档保持一致。

## 验证

- 模板渲染 + `go build`：生成一个使用 `base-hertz` 模板且
  `WithDatabase=true` 的项目，确认编译通过（RED：修复前应复现 Issue 描述的
  编译失败；GREEN：修复后应编译通过）
- `go test ./...`：确认没有引入回归
- `grep -rn "RateLimit\|ratelimit" <生成项目>`：确认生成代码里不再有任何
  rate-limit 残留引用

## 影响范围

仅 `base-hertz/hertz-template/` 目录下的 3 个模板文件
（`internal_base_server_server_go.yaml`、`internal_base_conf_conf_go.yaml`、
`conf_dev_conf_yaml.yaml`）及 2 个待删除文件，不影响其他模板。
