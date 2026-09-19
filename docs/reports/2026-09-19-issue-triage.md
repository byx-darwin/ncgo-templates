# Issue Triage Report — 2026-09-19

## Scope

- Source: `gf issue list --state open --limit 100`
- Total open issues fetched: 8 (#73–#80). No `pagination.truncated` flag observed; fetch treated as complete.
- Already triaged (skipped, idempotent): #73, #74 (both already carry `type:*` / `priority:*` / `triage:done`).
- Newly triaged this run: #75, #76, #77, #78, #79, #80.

## Priority-ranked results (newly triaged)

### 🟠 priority:high (3)

| # | Title | Type | Rationale |
|---|-------|------|-----------|
| 80 | base-hertz hardcoded `acme/scratch` import breaks fresh project generation | type:bug | Blocks the repo's core path — every fresh `ncgo new --template-dir base-hertz` scaffold fails `go mod tidy`. No existing e2e test catches it. |
| 78 | ratelimit KeyBy has no identifier dimension, only IP | type:bug | Security-relevant gap: IP rotation trivially bypasses per-account throttling, affecting password-reset and any future identifier-scoped endpoint. |
| 75 | user-kitex SMS reset code has no per-user binding, 6-digit global search space | type:bug | Security-relevant brute-force exposure on password reset; currently only mitigated by IP-based rate limiting, which #78 shows is bypassable. |

### 🟡 priority:medium (3)

| # | Title | Type | Rationale |
|---|-------|------|-----------|
| 79 | ratelimit-hertz memory-backend RateLimit still opens idle Redis pool | type:bug | Resource-waste bug (unused connection pool + dial noise), not a correctness/security break; no user-facing impact when Redis is reachable. |
| 77 | user-kitex TOCTOU race on password-reset token redemption | type:bug | Issue author explicitly assesses real-world severity as low (attacker already holds a valid credential); straightforward atomicity fix. |
| 76 | user-kitex ConfirmPasswordReset failure path has no audit trail | type:enhancement | Observability/monitoring gap, not an exploitable defect itself; compounds with #75 but doesn't independently weaken security posture. |

### Already triaged prior to this run (unchanged)

| # | Title | Type | Priority |
|---|-------|------|----------|
| 74 | CI main-branch pull_request-only trigger + paths filter → zero CI runs | type:bug | priority:high |
| 73 | rate-limit/idempotency middleware registration order (AK/Uid unreachable) | type:bug | priority:high — **note:** fix merged via commit `fda3707`; issue is still open on GitHub. Not closed by this triage run (out of scope — triage only adds labels, does not close issues). |

## Summary table

| Priority | Count | % of newly triaged |
|----------|-------|---------------------|
| 🔴 urgent | 0 | 0% |
| 🟠 high | 3 | 50% |
| 🟡 medium | 3 | 50% |
| 🟢 low | 0 | 0% |

| Type | Count |
|------|-------|
| type:bug | 5 |
| type:enhancement | 1 |

## Findings requiring attention

1. **#73 appears stale/inconsistent**: its fix was merged to `main` via commit `fda3707` (confirmed in this repo's git log), but the GitHub issue is still `state: open`. Triage scope is label-only (per the gf-issue-triage skill's "out of scope" rule — it does not close issues), so #73 was left open and its existing `type:bug` / `priority:high` / `triage:done` labels were left unchanged. Recommend a human/maintainer explicitly close #73 given the merge, or confirm whether it's intentionally kept open pending a follow-up (e.g. the README documentation update mentioned in its own acceptance criteria).
2. No duplicates, no ambiguous (`type:unknown`) issues, and no truncated-pagination risk were encountered in this run.

## Labels applied

```
gf issue add-label 80 --label "type:bug" --label "priority:high" --label "triage:done"
gf issue add-label 79 --label "type:bug" --label "priority:medium" --label "triage:done"
gf issue add-label 78 --label "type:bug" --label "priority:high" --label "triage:done"
gf issue add-label 77 --label "type:bug" --label "priority:medium" --label "triage:done"
gf issue add-label 76 --label "type:enhancement" --label "priority:medium" --label "triage:done"
gf issue add-label 75 --label "type:bug" --label "priority:high" --label "triage:done"
```
