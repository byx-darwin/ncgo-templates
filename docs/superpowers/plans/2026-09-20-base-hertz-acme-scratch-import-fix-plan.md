# Plan: fix base-hertz acme/scratch import + add e2e_test.sh (Issue #80)

Design doc: `docs/superpowers/specs/2026-09-20-base-hertz-acme-scratch-import-fix-design.md`

## Task 1 — Fix hardcoded import (score: 1 file changed, no module boundary /
public API / migration → simple, batch in main agent)

File: `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`

RED: `grep -rn "acme/scratch" base-hertz/hertz-template/` currently returns 2
lines (26-27). Generating a fresh project and running `go mod tidy` fails
with `cannot find module github.com/acme/scratch/...`.

GREEN: replace both lines with `"{{.Module}}/internal/base/conf"` and
`"{{.Module}}/internal/pkg/ratelimit"`.

Verify: `grep -rn "acme/scratch" base-hertz/hertz-template/` → no output.

## Task 2 — Add `base-hertz/test/e2e_test.sh` (score: 1 new file, no module
boundary crossing, no public API change → simple, batch in main agent)

Model on `ratelimit-hertz/test/e2e_test.sh` structure (helpers, escape
guards, `assert_no_residual`, `go_build`/`go_test`), scoped down since
`base-hertz` has:
- no db/sqlc templates (confirmed: no `*db*`/`*sqlc*` files under
  `base-hertz/hertz-template/`) → no postgres variant.
- `rate_limit.backend` defaulting to `"memory"` in `conf_dev_conf_yaml.yaml`
  with no `--infra redis` wiring to flip it (confirmed: `--infra` only
  referenced in `ratelimit-hertz`'s conf yaml, not base-hertz's) → no redis
  variant; add a comment explaining why, so this isn't mistaken for an
  oversight later.

Content:
1. Generate a fresh project via `ncgo new --template-dir base-hertz --module
   example.com/bh-e2e ...` into a tmpdir.
2. `assert_no_residual` — no leftover `{{...}}` actions / brace-escape
   artifacts in generated `.go` files (this is the exact bug class of #80).
3. `go mod tidy && go build ./... && go vet ./... && go test ./...` — matches
   the issue's literal acceptance command.
4. `chmod +x` the script; make it executable like its siblings.

Verify: run the script locally, exit 0.

## Batching Decision

Both tasks score ≤ 4 (simple) → batch in main agent, single review pass
(no independent subagent dispatch needed) per gf-workflow's complexity
formula (`min(files,5)*1`, no cross-module/public-API/migration flags set
for either task).

## Testing Plan

- `grep -rn "acme/scratch" base-hertz/hertz-template/` → empty.
- Fresh-generate `base-hertz`, run `go mod tidy && go build ./... && go vet
  ./... && go test ./...` → all pass.
- Run new `base-hertz/test/e2e_test.sh` directly → exit 0.

## Rollback

Single commit, two files touched (1 modified + 1 new); revertable with
`git revert` if the e2e script proves flaky in CI.
