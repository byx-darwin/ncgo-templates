# Pipeline Analysis Report — 2026-09-20 (Post-merge check, PR #78)

## Scope
- Branch: `main`
- Trigger context: routine post-delivery check after merging PR #78
  (`Merge branch 'feat/78-ratelimit-identifier-dimension' (#78)`, local
  commit `018c76e546fb8a3fab4d2d9705d7464f3746101c`) — adds an identifier
  dimension to the ratelimit package's `Lookup`/`BuildKey` and wires it into
  `user-bff-hertz`'s password-reset handlers.
- Windows queried: `--days 7` and `--days 30` (identical results — no runs
  older than 5h exist in either window).
- Read-only: no pipelines triggered/retried/cancelled; no CI config edited.

## Finding 1 (Blocking) — The #78 merge has not reached GitHub; no CI run exists for it
`git fetch origin main` + `git rev-list fc29a6b..HEAD` shows **local `main`
is 9 commits ahead of `origin/main`**; `origin/main` is still at `fc29a6b`
(the pre-#78, post-#77 commit). The `018c76e` merge commit for #78 exists
only in the local repository. GitHub Actions' `push`/`pull_request` triggers
fire on events GitHub receives — a commit that was never pushed cannot have
produced a run, successful or otherwise. **This is the identical
"local-merge-not-pushed" pattern previously diagnosed and fixed-by-pushing
in the #74 report** (`docs/pipeline-analysis-report-2026-09-19-issue74.md`).
None of the 6 runs analyzed below correspond to #78's changes — they all
predate it (latest run: `2026-09-20T02:45:01Z`; merge commit authored
`2026-09-20T05:59:05Z`/13:59+08:00, ~21 min before this check, ~4h before
`origin/main` was re-fetched).
**Action needed: `git push origin main` to actually publish #78, then
re-run this analysis.**

## Finding 2 (Pre-existing, unrelated to #78) — main is 0% success over the last 6 runs, all same root cause
- `totalRuns: 6`, `successRate: 0.0`, `avgDurationSecs: ~90` (7d and 30d
  windows identical — this workflow's entire run history is these 6 runs).
- All 6 runs (`35452556751` → `35484789178`, spanning 2026-09-19 15:40 to
  2026-09-20 02:45) fail at `build-check (rbac-kitex, kitex, none)` with the
  same error, first captured in the #74 report:
  ```
  ##[error]internal/base/conf/conf.go:11:2: missing go.sum entry for module
  providing package github.com/byx-darwin/go-tools/go-common/error
  ...
  ##[error]Process completed with exit code 1.
  ```
  `go mod tidy` also logs a non-blocking VCS lookup failure for an unrelated
  placeholder module (`github.com/acme/scratch`) but the actual failure is
  the missing `go.sum` entries for `github.com/byx-darwin/go-tools/go-common@v0.3.0`.
- **Not flaky** — 6/6 identical failures, same step, same message: a
  persistent, 100%-reproducible defect, not intermittent.
- **Already tracked**: Issue [#82](https://github.com/byx-darwin/ncgo-templates/issues/82)
  (opened 2026-09-19, still `open`) covers exactly this, with an unchecked
  AC item for the root-cause fix. No commit addressing it has landed since
  #82 was opened — the 3 runs added since then (`35475228567`,
  `35481492703`, `35484789178`) reproduce the identical failure.
- Because `build-check`'s matrix strategy defaults to fail-fast, once
  `rbac-kitex` fails the other matrix legs (`admin-services-kitex`,
  `admin-bff-hertz`, `rule-center`) get cancelled before reaching Build/Vet
  in every one of these runs — this is also called out as an open AC item
  in #82 (disable fail-fast to get independent per-branch signal).

## Finding 3 (Coverage gap, relevant to #78 once pushed) — `build-check` matrix does not cover the service #78 actually changed
`.github/workflows/template-build-check.yml`'s trigger `paths:` filter
watches `user-bff-hertz/**` (among others), but the `build-check` job's
`matrix.include` still only has 4 legs: `rbac-kitex`, `admin-services-kitex`,
`admin-bff-hertz`, `rule-center` — `user-bff-hertz` (where #78's
password-reset rate-limit wiring lives) is not one of them. This means: a
push touching only `user-bff-hertz/**` will trigger the workflow (path
filter matches) but `build-check` will only re-verify the four unrelated
templates — it will never actually build/vet the code #78 changed. This gap
was already flagged as suggestion 3 in the #74 report and does not appear to
have its own tracked remediation (it is adjacent to, but not explicitly an
AC item of, #82). **Once #78 is pushed, its own CI run will "pass or fail"
without ever compiling the changed handler code**, until this matrix is
widened.

## Duration
Average run duration ~90s across all 6 runs — fast, because every run fails
early in `build-check`'s Build step rather than running to completion; not a
bottleneck. No duration-based findings.

## Flaky Tests
None observed — all 6 failures are identical and 100% reproducible, which
rules out flakiness for this failure mode. No other test signal exists (no
run has gotten far enough to execute template-level tests).

## Escalation Note
The go.sum failure (Finding 2) has now appeared in 2 consecutive reports
(#74's post-push update section, and this one), but unlike the earlier
"zero CI runs" streak (#72/#69/#70/#74, which escalated), remediation *has*
been initiated — Issue #82 was opened the same day the failure first
appeared and remains open with unchecked ACs. Per the skill's escalation
rule this does not yet require a fresh escalation callout (a tracking Issue
already exists), but it is now flagged here as a distinct blocking item
(Finding 1) that #82 does not cover: the #78 delivery itself has not reached
GitHub at all, independent of whether #82 is fixed.

## Suggestions (priority order)
1. **Blocking**: `git push origin main` to publish the #78 merge commit to
   GitHub so a CI run can exist for it at all.
2. **Blocking (pre-existing, tracked in #82)**: Fix the missing
   `go.sum` entries for `github.com/byx-darwin/go-tools/go-common@v0.3.0` in
   the `ncgo new`-rendered templates' `go.mod`/`go.sum` generation — 6/6
   runs currently fail here regardless of what changed.
3. **High**: Widen `build-check`'s `matrix.include` to add `user-bff-hertz`
   (and ideally `user-kitex`, `base-hertz`, `ratelimit-hertz`, matching the
   trigger's `paths:` scope) so #78-style changes are actually compiled by
   CI, not just used to fire the workflow.
4. **Medium (tracked in #82's optional AC)**: Disable `fail-fast` on the
   `build-check` matrix so each template branch reports its own result
   instead of being cancelled by the first failure — needed to get real
   per-branch signal once Finding 2 is fixed.

Not created as an Issue — per this skill's read-only scope, that decision is
left to the user. Suggestion 3 in particular may warrant its own tracking
Issue separate from #82, since #82's scope is the go.sum root cause, not
matrix coverage.
