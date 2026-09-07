# Code Review Report — #47 ID 方案回退（rbac-kitex + admin-services-kitex）

**Merge commit:** `aef8d1c1c0f0d5b6d543497f581ed5ed5e634566`（本地合并到 `main`，无 PR）
**分支:** `feat/47-rbac-id-scheme-revert`
**关联 Issue:** #47（同时 Closes #38、#46）
**审查方式:** `superpowers:subagent-driven-development` 内建的最终全分支审查（独立于各 Task 的逐任务审查），因交付方式为本地合并、未走 GitHub PR 流程，故未通过 `gf-review` 提交平台侧审查结论，改以本文档留存审查记录。

## 范围

58 个文件，+856/-467 行，覆盖 `rbac-kitex`/`admin-services-kitex` 两个模板的 schema/migration/sqlc query/domain/repository/application service/handler 全链路，把 `users`/`roles`/`permissions` 主键从 `TEXT` 改回 `BIGSERIAL`，`users` 新增应用层生成（UUID v7）的 `uuid` 列作为对外标识。

## 审查过程

- 16 个计划任务级审查（14 个计划任务 + 2 个执行中发现的计划外缺口修复 Task 6b/12b），逐一 spec 合规性 + 代码质量 + 范围检查，全部通过。
- 1 次最终全分支审查（sonnet，独立复现两个模板的完整 `go build ./...`/`go test ./...`），确认：UUID/int64 边界在所有入口一致；JWT/Casbin 身份全程不泄漏 int64；两个模板逐文件 diff 确认对称；发现 1 个 Important 级别真实回归（`permission_service.go` 的 `Update` 无法把 `ParentID` 清空回根节点）。
- 1 轮修复 + 范围复审：修复已应用到两个模板，新增回归测试 `TestUpdateClearsParentIDToRoot`，复审确认无新增破坏。

完整执行记录（含每个 Task 的证据、发现、裁决）：`.worktree` 已清理前的 SDD ledger 内容见下方"执行记录摘录"。

## 结论

**Ready to merge: Yes（已合并）**

核心架构改动（主键回退、UUID 外部标识、边界转换封闭在 repository/application 层、JWT/Casbin/DTO/proto 契约零改动）正确且一致，唯一发现的真实问题已修复并复审通过，无残留 Critical/Important 问题。

## 执行记录摘录（SDD Ledger 关键条目）

```
Task 1-14: 全部 complete, review clean
Task 6b（ad-hoc）: rbac-kitex auth_service.go UUID/int64 边界修复，review clean
Task 12b（ad-hoc）: admin-services-kitex 镜像修复，review clean
Final Review: Ready to merge WITH FIXES —— 1 个 Important 发现（permission Update ParentID 回根节点回归）
Final Review Fix: 已修复两个模板 + 新增回归测试，scoped re-review 确认 ADDRESSED，无新增破坏
```
