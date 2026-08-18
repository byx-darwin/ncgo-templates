# Code Review — PR #2: refactor(ratelimit-hertz) 基于 base-hertz 重新调整

- **workflow:** wf-2026-08-18-001 · Phase 4 gf-review
- **PR:** https://github.com/byx-darwin/ncgo-templates/pull/2 (base `main` ← `worktree-agent-…`)
- **Scope:** 49 files, +3685 / −1758
- **Verdict:** ✅ Comment / Approve-with-followups（hermetic 范围内无阻塞项）

## 验收标准核对（Issue #1）

| AC | 结果 | 证据 |
|----|------|------|
| 全部 `.yaml` 无残留 `{{ "{" }}`/`{{ "}" }}` | ✅ | `grep -rln … ratelimit-hertz/` = 0（含 `{{ "{{" }}` 变体也已清零） |
| 头部注释 / `|-` 块 / `{{if}}` 与 base 一致 | ✅ | server/conf 等抽查为 `# Hertz custom template —` + `body: |-` + 真 `{{if .WithDatabase}}` |
| 9 重叠文件除限流叠加外与 base diff 一致 | ✅ | main/errcode/middleware/response/Makefile body 与 base 相同；server/conf 仅限流叠加 |
| server.go 补齐 wiring + 注入限流中间件 | ✅ | `health.Register(h)`、`router.GeneratedRegister(h)`、`if cfg.RateLimit.Enabled { pre_auth+post_auth }`、`{{if .WithDatabase}}` DDD 块 |
| README 重构为 base 章节结构 | ✅ | Use/Contents/Variables/Features/Structure/Configuration/Development/License |
| 新增 e2e_test.sh，hermetic 必跑 | ✅ | 生成→无残留断言→`go build`→`go test` 全绿 |
| redis/postgres 变体 gated + 显式 skip | ✅ | 无本地服务时打印 `skipped: <原因>`，非静默 |

## 优点
- 严格 TDD：先落 RED e2e 锚点，再逐组转绿；9 个独立提交对应任务边界，可审。
- 诚实报告：机器导出实为 4 种转义形态（含 `{{"{{"}}` 复合字面量），已全部识别处理，未伪造通过。
- 重叠文件真正采用 base 基座（body 逐字一致），达成「共享基座」目标。

## 跟进项（不阻塞本 PR 的 hermetic 交付）
1. **postgres 门未真正可用**：ratelimit 未随附 `internal/db/gen`（sqlc），base 的 `{{if .WithDatabase}}` data 分支在 `--db postgres` 下会缺依赖。当前 e2e 对 postgres 变体 gated+skip，故不破坏 hermetic 门；启用 postgres 前需补 sqlc 生成物。→ 建议开独立 Issue。
2. **ncgo `loop_service` 上游限制**：Hertz IDL 无法生成 per-service 路由/handler（base-hertz 同样受影响）。当前用 `router/pb/middleware.go` 自带 `Register`/`Ping` 兜底 `pb.Register`。→ 属上游 ncgo 缺陷，建议单独追踪。
3. `internal_router_pb_{svc}.go` 与 `handler/pb/{svc}_service.go` 已改风格但当前 ncgo 流程下不触发；保留合理，待上游修复后复用。

## 结论
风格对齐、wiring 补齐、限流能力保留、端到端 hermetic 基线通过、无残留转义——达成 Issue #1 全部验收。两处跟进项均为**预先存在的 ncgo 能力边界**（非本次回归），且已被 gated 隔离，不阻塞合并。建议合并并另开 Issue 追踪跟进项 1、2。
