# Pipeline Analysis Report — 2026-09-18 (Issue #69)

## Scope
- Branch: `main`
- Latest commit: `346a1508c81927cad72c734d406d9a05f5736e21` (merge of `fix/69-admin-bff-hertz-terminal-user-upgrade-doc`, docs-only README change)
- Window: 7 days → widened to 30 days → widened to 90 days (all empty)

## Data Sufficiency
`gf pipeline report --branch main --days 7|30|90` all returned `totalRuns: 0,
successRate: 0.0, avgDurationSecs: 0.0, topFailures: []`.
`gf pipeline status --branch main` returned an empty run list.

No analyzable pipeline runs exist for `main` in the queried windows, so
success-rate trend, failure-pattern, and duration-bottleneck analysis cannot
be performed. No flaky-test signal is available either (requires ≥2
intermittent failures on the same job, which requires runs to exist first).

Root cause (unchanged from the prior report): the only workflow in this repo,
`.github/workflows/template-build-check.yml`, triggers on `pull_request`
with a `paths:` filter covering only `rbac-kitex/**`, `admin-services-kitex/**`,
`admin-bff-hertz/**`, `rule-center/**`, `scripts/**`, and the workflow file
itself. Issue #69's change is a docs-only README edit, delivered via a local
merge (`346a150`) rather than a PR — so it would not have triggered this
workflow even if it were in scope. `base-hertz` and `ratelimit-hertz` remain
outside the path filter entirely, and local-merge delivery (seen across
recent history, e.g. `346a150`, `0fe1e1b`) bypasses `pull_request`-triggered
CI altogether.

## Verdict
⚠️ Insufficient data — not a pipeline health finding, a CI coverage gap.

## Repeat-Finding Note (Escalation Watch)
This is the **2nd consecutive report** with the same "zero runs / insufficient
data" outcome for `main` (previous: `docs/pipeline-analysis-report-2026-09-18-issue72.md`,
same day). No remediation has landed between the two reports. Per this
skill's escalation rule, this is not yet a 3-streak — but if a third report
lands with the same outcome and no fix/Issue in between, the next report MUST
escalate explicitly and prompt for a concrete decision (fix the workflow
trigger/paths, or accept the coverage gap).

## Suggestion (non-blocking, for user decision)
Unchanged from the prior report — repeating because no action has been taken:
1. Add `push` (or at least merges to `main`) as a trigger alongside
   `pull_request`, since this repo delivers via local merges more often than
   PRs.
2. Widen the `paths:` filter to include `base-hertz/**` and
   `ratelimit-hertz/**`, currently unmonitored by CI.
3. Consider whether docs-only changes should be excluded via `paths-ignore`
   rather than left as an implicit "no CI ran" gap — right now there's no way
   to distinguish "docs change correctly skipped" from "CI is broken and
   never ran."

Not created as an Issue — per this skill's read-only scope, that decision is
left to the user.
