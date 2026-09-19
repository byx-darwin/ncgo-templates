# Issue Triage Report — 2026-09-19

Context: Phase 4 post-delivery periodic triage, run after merging Issue #71
(forgot-password self-reset). Scope: **all open Issues** in
`byx-darwin/ncgo-templates`, not limited to #71.

CLI used: `gf` (per skill requirement — not `gh`).

## Coverage

`gf issue list --state open --limit 100` returned **3** open Issues, no
`pagination.truncated` flag present / no evidence of truncation (well under
the limit). Coverage is complete.

None of the 3 Issues previously carried `triage:done` — this is treated as a
first-time or since-relabeled triage pass for all of them.

## Classification & Actions

| # | Title | Type | Priority | Action |
|---|-------|------|----------|--------|
| 74 | chore(ci): main 分支 pull_request-only 触发器 + paths 过滤器导致连续 3 次零 CI 运行 | `type:bug` | `priority:high` | Labeled `type:bug`, `priority:high`, `triage:done` |
| 73 | fix(base-hertz,admin-bff-hertz,ratelimit-hertz): rate-limit and idempotency middleware register before identity is known | `type:bug` | `priority:high` | Labeled `type:bug`, `priority:high`, `triage:done` |
| 71 | feat(user-kitex): 终端用户忘记密码自助重置 | `type:feature` | `priority:medium` | Labeled `type:feature`, `priority:medium`, `triage:done` |

## Priority-Ranked Summary

### 🟠 High (2 — 67%)

- **#74** — CI on `main` has produced zero runs across 3 consecutive pipeline
  analyses (#72, #69, #70) because the only workflow is `pull_request`-only
  and this repo merges locally (no PR). `paths:` filter also misses several
  service directories (`user-kitex`, `user-bff-hertz`, `base-hertz`,
  `ratelimit-hertz`). Effectively there is **no post-merge CI verification on
  main today** — undermines confidence in every subsequent merge, including
  #71's. Needs an explicit decision (add push trigger + fix paths, or
  formally accept no post-merge CI).
- **#73** — Security/DoS-relevant: `RateLimit` and `Idempotency` middleware
  are registered before identity (AK/Uid) is resolved in 3 packages
  (`base-hertz`, `admin-bff-hertz`, `ratelimit-hertz`), so their
  identity-scoped branches are dead code. This is a follow-on from #66/#72 and
  is a structural (not just data) defect — worth flagging as
  **security-relevant** even though no active exploit is reported.

### 🟡 Medium (1 — 33%)

- **#71** — The forgot-password self-reset feature issue. **Note:** this
  Issue's branch (`feat/71-forgot-password-self-reset`) has already been
  merged to `main` (see recent commit log), but the Issue itself is still
  open with unchecked acceptance criteria. Recommend closing #71 manually if
  the merged work satisfies its goal — out of scope for this triage pass
  (label-only, no state changes).

### 🟢 Low (0 — 0%)

None.

## Type Distribution

| Type | Count | % |
|------|-------|---|
| `type:bug` | 2 | 67% |
| `type:feature` | 1 | 33% |

## Notes / Out-of-scope observations

- No duplicates found among the 3 open Issues.
- #71 appears to be delivered-but-unclosed; flagged above but not acted on
  (triage only labels, never closes/edits body per skill scope).
- #73 has security/DoS-mitigation implications and is worth prioritizing in
  the next planning cycle even though not classified `priority:urgent`
  (no active production impact confirmed).
