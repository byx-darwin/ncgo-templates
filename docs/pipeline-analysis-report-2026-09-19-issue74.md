# Pipeline Analysis Report — 2026-09-19 (Issue #74)

## Scope
- Branch: `main`
- Fix under evaluation: merge commit `3e693a4a5812ea8f10eef6fbe6f13067bba79248`
  (`Merge branch 'feat/74-ci-push-trigger' (#74)`), which adds a `push`
  trigger scoped to `main` and completes the `paths:` filter in
  `.github/workflows/template-build-check.yml` to also cover `user-kitex/**`,
  `user-bff-hertz/**`, `base-hertz/**`, and `ratelimit-hertz/**`.
- Window: 7 / 30 / 90 days, all queried.

## Data Sufficiency
`gf pipeline report --branch main --days 7` → `totalRuns: 0, successRate:
0.0, avgDurationSecs: 0.0, topFailures: []`. `gf pipeline status --branch
main` → empty run list. Identical to the last three reports
(#72, #69, #70): no analyzable runs exist for `main`.

## Root Cause of Continued Zero Runs — NOT a CI-side issue this time
Verified the workflow file as committed on local `main` — the fix is present
and correct in isolation:

```yaml
on:
  push:
    branches: [main]
    paths: &watched-paths [ ...rbac-kitex, admin-services-kitex,
      admin-bff-hertz, rule-center, user-kitex, user-bff-hertz, base-hertz,
      ratelimit-hertz, scripts, workflow file itself, '!**/*.md' ]
  pull_request:
    paths: *watched-paths
```

However, checking whether the merge actually reached GitHub (`git fetch
origin main` + `git rev-list --left-right --count main...origin/main`):

```
local main:  3e693a4a5812ea8f10eef6fbe6f13067bba79248
origin/main: 0fb06dcde128f7f612843b1508480f3b7430cd3d
ahead/behind: 14 0
```

**Local `main` is 14 commits ahead of `origin/main`. The #74 merge commit —
along with the entire #73 fix chain before it — has not been pushed to
GitHub.** GitHub Actions' `push` trigger fires on events received by GitHub;
it cannot fire on a commit that only exists in the local repository. This is
the actual and sufficient explanation for the continued `totalRuns: 0` —
independent of whether the workflow fix itself is correct. This is expected
"not pushed yet," not a CI queue-lag or platform failure.

## Secondary Finding — job matrix not widened alongside the paths filter
The `paths:` filter (and thus the trigger scope) now covers `user-kitex/**`,
`user-bff-hertz/**`, `base-hertz/**`, and `ratelimit-hertz/**`, but the
`build-check` job's matrix still only renders/builds:
`rbac-kitex`, `admin-services-kitex`, `admin-bff-hertz`, `rule-center`.
So even once pushed and firing correctly, a change confined to
`user-kitex/**`, `user-bff-hertz/**`, `base-hertz/**`, or `ratelimit-hertz/**`
will trigger a run, but that run's `build-check` job will not actually
build/vet the changed template — it will only re-verify the four
already-covered templates. This does not block the "zero CI runs" fix from
working, but it means coverage is still incomplete for those four
directories once runs resume.

## Verdict
⚠️ Not yet verifiable / one blocking action outstanding, plus one follow-up
gap. The workflow-trigger fix is expected to resolve the "zero CI runs on
main" pattern *once pushed*, but as of this report it has not been pushed to
`origin/main`, so no run — successful or otherwise — could possibly exist
yet. This is a distinct, actionable blocker, not the passive "CI queue lag"
scenario anticipated going in.

## Escalation Note
This is the **4th consecutive report** with a "zero runs on main" outcome
(after #72, #69, #70). Unlike the prior three, the blocker is no longer "no
fix has landed" — the fix (#74) is committed — it is "the fix has not been
pushed to the remote the CI platform observes." Recommend: `git push origin
main` (or whatever remote-sync step this delivery workflow uses) to actually
publish commits `0fb06dc..3e693a4` to GitHub, then re-run this analysis to
confirm the `push` trigger fires and `build-check` succeeds.

## Suggestions
1. **Blocking**: Push local `main` (currently 14 commits / includes #73 and
   #74 fixes) to `origin/main`. Until this happens, the #74 fix cannot be
   observed to work at all — GitHub has no visibility into local-only
   commits.
2. After pushing, re-run `gf pipeline report --branch main --days 1` to
   confirm a run was created and inspect its conclusion.
3. Widen the `build-check` job's matrix to include `user-kitex`,
   `user-bff-hertz`, `base-hertz`, and `ratelimit-hertz` so the newly
   watched paths are actually exercised by a build/vet step, not just used
   as a trigger filter.

Not created as an Issue — per this skill's read-only scope, that decision is
left to the user.

## Update (post-push verification)

`main` was pushed to `origin/main` (`0fb06dc..3e693a4`). The `push` trigger
**fired as designed** — three consecutive runs were observed on `main` for
the first time in this workflow's history:

| Run | Commit | Result | Finding |
|---|---|---|---|
| [35452556751](https://github.com/byx-darwin/ncgo-templates/actions/runs/35452556751) | `3e693a4` (#74 trigger fix) | ❌ failure | `build-check (admin-bff-hertz)` — `hz new` exits with `GOPATH is not set` |
| [35454130355](https://github.com/byx-darwin/ncgo-templates/actions/runs/35454130355) | `cd7b52e` (+ GOPATH fix) | ❌ failure | GOPATH fix confirmed working (env shown in log); next blocker — `hz new` exits with `protoc is not installed` |
| [35454363053](https://github.com/byx-darwin/ncgo-templates/actions/runs/35454363053) | `88426ee` (+ protoc fix) | ❌ failure | GOPATH + protoc fixes both confirmed working (render succeeded); next blocker — `go build ./...` fails with `missing go.sum entry` for `github.com/byx-darwin/go-tools/go-common@v0.3.0` and its subpackages |

### Final Verdict for #74's own scope

✅ **#74's acceptance criteria are met and verified**: the `push` trigger on
`main` fires correctly, and the completed `paths:` filter (including
`user-kitex/**`, `user-bff-hertz/**`, `base-hertz/**`, `ratelimit-hertz/**`)
is confirmed valid YAML and in effect. "Zero CI runs on main" — the pattern
reported 4 times running (#72, #69, #70, and initially this report) — is
now resolved: the workflow demonstrably runs on every push to main.

⚠️ **Separate, pre-existing finding**: this is the *first time this workflow
has ever executed* (`gh run list` showed no history before this), and doing
so surfaced three independent environment/build gaps in `build-check`
(GOPATH export, protoc install, go.sum entries) that are orthogonal to the
trigger/paths fix. The first two were fixed opportunistically during this
delivery (commits `f93724f`/`cd7b52e` and `0d24571`/`88426ee`, both on
`main`). The third (go.sum) and full matrix-branch validation (rbac-kitex,
admin-services-kitex, admin-bff-hertz never reached Build/Vet due to
fail-fast cancellation) are tracked separately in
[#82](https://github.com/byx-darwin/ncgo-templates/issues/82) — out of
scope for #74's AC, which was limited to trigger conditions and the paths
filter, not build-time correctness of the rendered templates.

