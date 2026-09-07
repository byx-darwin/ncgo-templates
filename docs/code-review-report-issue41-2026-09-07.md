# Code Review Report — Issue #41 (local merge, no PR)

**Date:** 2026-09-07
**Branch:** `feat/41-rulecenter-match-kind-check-constraint` (merged locally into `main` at `6d98901`, no PR — delivery_mode=local_merge)
**Reviewer:** final whole-branch review, dispatched by `superpowers:subagent-driven-development`, model: opus

## Scope

Widens the `rate_limit_rules.match_kind` CHECK constraint in the `admin-services-kitex` and `rule-center` templates from `('exact', 'pattern')` to `('exact', 'prefix', 'glob', 'regex')`, matching the value domain already implemented by the usecase/resolver layer. Adds a gated Postgres integration test to each template's `rulecenter` repository package, covering all four `match_kind` values.

## Strengths

- Precise, complete fix: exactly 4 CHECK-constraint occurrences updated, no stale `'pattern'`-only constraint left in the repo.
- Root-cause confirmed correct: `CreateRule` passes `req.MatchKind` straight through to the DB with no application-layer validation — the CHECK constraint is the only domain gate, so fixing it there is the right (and only necessary) fix point.
- Scope strictly controlled: diff touches only the 4 constraint files + 2 new test files + design/plan docs; no proto/usecase/resolver/middleware changes.
- New tests faithfully mirror the existing gated-integration-test convention (`internal_repository_user_repo_test_go.yaml`), including exact skip-gating logic and wording.
- Correct per-template brace-escaping convention used in each new file.
- Migration-compatibility concern investigated and ruled out: `ncgo-templates` only scaffolds new projects; `migration_init.yaml` is `update_behavior: skip`, so re-running ncgo against an already-generated project never rewrites its applied migration history.

## Issues

### Critical (Must Fix)
None.

### Important (Should Fix)
None.

### Minor (Nice to Have)
1. Tests only assert acceptance of the 4 valid values, not rejection of invalid ones (e.g., deleting the whole CHECK constraint would still pass). Optional: add a negative subtest inserting an invalid `match_kind` and asserting an error.
2. Already-generated downstream projects that migrated on the old constraint won't get this fix automatically (their applied migration history isn't touched by re-running ncgo). Worth a one-line note in the Issue #41 closing comment so downstream maintainers know to write their own follow-up migration if needed.
3. `matchKind := matchKind` (pre-1.22 loop-capture idiom) and the `id == 0` sanity check are cosmetic/conventional, consistent with the existing sibling test file's style — not worth a fix cycle.
4. `rule-center` is not in `.github/workflows/template-build-check.yml`'s CI matrix/paths, so this template's new test doesn't get CI-rendered/compiled verification (only `admin-services-kitex` and `rbac-kitex` are). Pre-existing gap, out of scope for this fix; possible future improvement.

**Out-of-scope observation (not actioned in this fix):** the resolver does case-insensitive `match_kind` matching (`strings.ToLower`) while `CreateRule` doesn't normalize before the case-sensitive DB CHECK — a pre-existing, unrelated minor inconsistency between the application layer and the storage layer's value domains.

## Assessment

**Ready to merge:** Yes (already merged locally at `6d98901`)

**Reasoning:** Implementation matches the plan task-by-task — 4 constraint edits precise and complete, no scope leakage, 2 new tests faithfully replicate the established gated-integration-test pattern and would have caught the original bug. Migration-compatibility risk investigated and confirmed non-issue. All remaining items are optional strengthenings, none block merge.
