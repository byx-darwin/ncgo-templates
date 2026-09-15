# Issue Triage Report — 2026-09-15 (Issue #67)

Context: `gf-issue-triage` run against Issue #67 (`feat(admin-bff-hertz): 集成终端用户管理（调用 user-kitex 管理端 RPC，Plan 3 of 3）`), triggered post-delivery — `admin-bff-hertz` gained terminal-user management (list/get/ban/unban/unbind-identity for end-user accounts) plus a security-critical fix (RBAC Authz middleware was a complete no-op on every protected route; now fixed). Merged to `main` at commit `60894dd`. Issue #67 itself was still `open` and untriaged at scan time.

## Summary

| Metric | Value |
|---|---|
| Open Issues scanned | 1 (#67, targeted) |
| Already `triage:done` (skipped) | 0 |
| Newly triaged | 1 |
| Duplicates marked | 0 |
| `type:unknown` | 0 |

## Priority-Ranked Table

| Priority | # | Issue | Type | Notes |
|---|---|---|---|---|
| 🔴 urgent | 1 | [#67](https://github.com/byx-darwin/ncgo-templates/issues/67) `feat(admin-bff-hertz): 集成终端用户管理（调用 user-kitex 管理端 RPC，Plan 3 of 3）` | `type:feature` | Third and final plan of a three-part series (Plan 1: `user-kitex`, Plan 2: `user-bff-hertz`, both already merged). Adds `/api/v1/terminal-users` route group to `admin-bff-hertz` (list/get/ban/unban/unbind-identity) plus a new `AdminUnbindProvider` RPC on `user-kitex`. Delivery also surfaced and fixed a security-critical defect: the RBAC Authz middleware was a complete no-op on every protected route in `admin-bff-hertz`, meaning permission checks were not actually being enforced anywhere prior to this fix. Delivered and merged to `main` (commit `60894dd`); Issue remains open with unchecked acceptance-criteria boxes and is left untouched here per skill scope (triage only, no state/body changes). |

### Priority breakdown

| Priority | Count | % |
|---|---|---|
| 🔴 urgent | 1 | 100% |
| 🟠 high | 0 | 0% |
| 🟡 medium | 0 | 0% |
| 🟢 low | 0 | 0% |

### Type breakdown

| Type | Count | % |
|---|---|---|
| `type:bug` | 0 | 0% |
| `type:feature` | 1 | 100% |
| `type:enhancement` | 0 | 0% |
| `type:docs` | 0 | 0% |
| `type:question` | 0 | 0% |
| `type:unknown` | 0 | 0% |

## Classification Rationale — #67

- **Type**: `type:feature` — the issue's own scope and title are additive: a new `terminal-user` management surface (list/get/ban/unban/unbind-identity) wired into the existing `admin-bff-hertz` admin console, backed by a new `AdminUnbindProvider` RPC on `user-kitex`. The RBAC Authz no-op fix discovered and repaired during this delivery is a defect fix, but per skill convention one type label is applied per Issue and the Issue's primary, titled scope is the new capability — the security fix is called out explicitly in the Priority rationale and Notes column instead of splitting the type label.
- **Priority**: `priority:urgent` — the discovered defect (RBAC Authz middleware being a complete no-op on every protected route) is a security-relevance finding per the skill's priority table ("production outage / security / blocked" → urgent). Until this delivery's fix, every permission-gated route in `admin-bff-hertz` — including the newly added terminal-user ban/unban/unbind-identity actions and all pre-existing admin routes — was effectively unprotected. This crosses the urgent threshold even though the fix has already landed on `main`; the classification reflects the severity of what was found and fixed, consistent with keeping ≤10% of triaged issues at `urgent` (this run: 1 of 1, a deliberate exception given the security nature, not a default).

## Actions Taken

```
gf issue add-label 67 --label "type:feature" --label "priority:urgent" --label "triage:done"
```

## Related Open Issues Found (Not Triaged — Out of Scope)

While fetching Issue #67, two related open Issues surfaced from the same Plan 3 review, discovered as follow-on findings. Both remain untriaged and unlabeled; they were not targeted by this run's scope (Issue #67 only) and are left for a future triage pass:

- [#68](https://github.com/byx-darwin/ncgo-templates/issues/68) `fix(admin-bff-hertz): add Validate() guard for GRPC.Authority.HostPorts (startup panic on empty config)` — pre-existing gap on `main`, unguarded index into `cfg.GRPC.Authority.HostPorts[0]` can panic at startup.
- [#69](https://github.com/byx-darwin/ncgo-templates/issues/69) `docs(admin-bff-hertz): existing deployments fail to boot after upgrading past terminal-user management without config changes` — new required config field from Plan 3 lacks upgrade-path guidance/guard, risking boot failures on existing deployments.

## Out of Scope (per skill boundaries)

- Did not close Issue #67 or check off its acceptance-criteria boxes, despite the underlying work being merged — closing/editing body content is out of scope for this skill (`gf-issue` handles edits; issue closure is a separate decision for the repo owner).
- Did not triage Issues #68 and #69 — this run's scope was Issue #67 only, per explicit instruction.
- Did not analyze requirement completeness (that's `gf-issue-review`).
- Did not compute label distribution stats beyond this run (that's `gf-label-stats`).

## Archiving Note

This is the 3rd `issue-triage-report-*.md` under `docs/superpowers/reports/` (after `issue-triage-report-2026-09-14.md` and `issue-triage-report-2026-09-15.md`); below the 5-file archive threshold, so no archival action taken this run.
