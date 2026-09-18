# Pipeline Analysis Report — 2026-09-18 (Issue #72)

## Scope
- Branch: `main`
- Window: 7 days, then widened to 30 days (both empty)

## Data Sufficiency
`gf pipeline report --branch main --days 30` returned `totalRuns: 0` for both
windows — no analyzable pipeline runs.

Likely cause: `.github/workflows/template-build-check.yml` is scoped to
`pull_request` events with a `paths:` filter (`rbac-kitex/**`,
`admin-services-kitex/**`, `admin-bff-hertz/**`, `rule-center/**`,
`scripts/**`, and the workflow file itself). This repo's recent history
(including Issue #72's delivery) has used **local merges** rather than PRs,
and `base-hertz`/`ratelimit-hertz` are outside the workflow's path filter —
so no CI runs exist to analyze regardless of delivery mode.

## Verdict
⚠️ Insufficient data — not a health finding, a coverage gap. No success-rate,
failure-pattern, or duration analysis possible with zero runs.

## Suggestion (non-blocking, for user decision)
Consider widening `template-build-check.yml`'s path filter to cover
`base-hertz/**` and `ratelimit-hertz/**` (currently unmonitored by CI), and/or
triggering it on `push` to `main` in addition to `pull_request`, if PR-based
delivery becomes more common than local merges. Not created as an Issue —
per this skill's read-only scope, that decision is left to the user.
