# base-hertz: 补齐缺失的 internal/pkg/ratelimit 包（Issue #42）

## 问题

`base-hertz` 模板的 `internal_repository_rate_limit_rule_go.yaml` import 了
`{{.Module}}/internal/pkg/ratelimit`，`server.go` 也引用了
`repository.NewRateLimitRuleRepository()`，但模板目录下没有任何文件生成
`internal/pkg/ratelimit` 包本身，按该模板生成的项目 `go build` 直接失败。

## 根因

对比 `ratelimit-hertz` 模板发现，`base-hertz` 的 `conf.go` 已包含完整的
`RateLimitConfig`（`Source`/`GRPC`/`RuleCenter`/`Database` 等字段及校验逻辑），
`internal/repository/rate_limit_rule.go` 也已就位——这些都是从 `ratelimit-hertz`
完整搬迁过来的。真正缺失的是：

1. `internal/pkg/ratelimit/{resolver,store}.go`（+ test）——被 repository.go
   import 但未生成的包本身
2. `internal/pkg/middleware/rate_limit.go`（+ test）——限流中间件实现
3. `server.go` 中的中间件装配代码块
   （`if cfg.RateLimit.Enabled { ... h.Use(middleware.RateLimit(...)) ... }`）
   及对应 import

即 `base-hertz` 原本就打算内置完整限流能力（配置与仓储层均已就位），只是
合并时漏拷贝了核心包与装配代码。这对应 Issue 中的**方案 1**（补齐），
而非方案 2（删除）——方案 2 会留下 `RateLimitConfig`/repository 孤立死代码。

## 方案

从 `ratelimit-hertz` 逐字节复制以下模板文件到 `base-hertz`：

- `internal_pkg_ratelimit_resolver_go.yaml`
- `internal_pkg_ratelimit_resolver_test_go.yaml`
- `internal_pkg_ratelimit_store_go.yaml`
- `internal_pkg_ratelimit_store_test_go.yaml`
- `internal_pkg_middleware_rate_limit_go.yaml`
- `internal_pkg_middleware_rate_limit_test_go.yaml`

修改 `base-hertz/hertz-template/internal_base_server_server_go.yaml`：

- 新增 import `"{{.Module}}/internal/pkg/ratelimit"`
- 新增中间件装配代码块（`if cfg.RateLimit.Enabled { rlResolver := ratelimit.NewResolver(...); h.Use(middleware.RateLimit("pre_auth", ...)); h.Use(middleware.RateLimit("post_auth", ...)) }`），插入位置对齐 `ratelimit-hertz` 的相对顺序（health 注册之前）
- **保留** base-hertz 现有的 DDD 装配代码（`pbhandler`/`usecasepb` import 及
  `pbhandler.SetDefaultUseCase(...)`）——这是 base-hertz 独有功能，
  `ratelimit-hertz` 没有，diff 时不能整体覆盖

**不改动**：`repository.NewRateLimitRuleRepository()` 弃元返回值的写法——
`ratelimit-hertz` 源模板本身就是这样（未接入 DatabaseHook），属于既有设计，
不在本 issue 范围内。

## 验证

- 模板渲染 + `go build`：生成一个使用 `base-hertz` 模板且 `WithDatabase=true`
  的项目，确认编译通过
- 复制过来的 `_test_go.yaml` 随包一起生成，跑 `go test ./internal/pkg/ratelimit/...`
  `./internal/pkg/middleware/...`

## 影响范围

仅 `base-hertz/hertz-template/` 目录下的模板文件，不影响其他模板
（`ratelimit-hertz` 为只读复制源，未修改）。
