# Issue #80 — base-hertz hardcoded acme/scratch import — Code Review

**Delivery type:** Merge commit `29ad876d39f67fefe0e705a352c4a649e0df664e` on `main`, merging the fix for Issue #80 ("fix(base-hertz): hardcoded github.com/acme/scratch import breaks fresh project generation"). Pre-merge `main` tip was `ce46859`.
**Reviewed diff:** `git diff ce46859...29ad876d39f67fefe0e705a352c4a649e0df664e`
**Verdict:** No blocking issues. No correctness findings.

---

## 1. Scope of change

- `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml` — 2-line import fix
- `base-hertz/test/e2e_test.sh` — new file (94 lines), modeled on `ratelimit-hertz/test/e2e_test.sh`
- `docs/superpowers/specs/2026-09-20-base-hertz-acme-scratch-import-fix-design.md`,
  `docs/superpowers/plans/2026-09-20-base-hertz-acme-scratch-import-fix-plan.md` — workflow
  artifacts, already reviewed/approved earlier in this workflow, excluded from code review scope.

This is exactly the pre-existing issue flagged (but out of scope) in the
Issue #79 review at `docs/superpowers/reviews/2026-09-20-issue79-ratelimit-memory-backend-redis-dial-review.md`
section 2.2.

## 2. Correctness review

### 2.1 Confirmed correct

- `github.com/acme/scratch/internal/base/conf` / `.../internal/pkg/ratelimit`
  → `{{.Module}}/internal/base/conf` / `{{.Module}}/internal/pkg/ratelimit`,
  matching the convention used by every other file in
  `base-hertz/hertz-template/` (15+ existing occurrences of `{{.Module}}`)
  and by the equivalent file in `ratelimit-hertz/hertz-template/`.
- Verified empirically (not just by inspection): reverted the fix locally,
  re-ran `base-hertz/test/e2e_test.sh`, confirmed it fails with exactly the
  expected class of error (residual `acme/scratch` detected, then
  `go build` fails on missing go.sum entries for a nonexistent module) —
  i.e. the new e2e script's `assert_no_residual` genuinely catches this
  regression class, not just a script that happens to pass. Restored the
  fix, re-ran, confirmed 全部必跑通过 (exit 0).
- `grep -rn "acme/scratch" base-hertz/hertz-template/` returns nothing after
  the fix (acceptance criterion #1 met).
- Fresh `ncgo new --template-dir base-hertz --module example.com/bh-e2e ...`
  followed by `go mod tidy && go build ./... && go vet ./... && go test ./...`
  all exit 0 (acceptance criterion #2 met).
- `base-hertz/test/e2e_test.sh` added, matching the `ratelimit-hertz`/
  `admin-bff-hertz` script pattern in structure (helpers, brace-escape
  guards, `assert_no_residual`, tmpdir generation and cleanup), with a
  documented, verified scope reduction: no postgres variant (base-hertz has
  no db/sqlc template files — confirmed by directory listing) and no redis
  variant (base-hertz's `rate_limit.backend` defaults to `"memory"` in
  `conf_dev_conf_yaml.yaml` with no `--infra`-driven backend switch, unlike
  `ratelimit-hertz` — adding an untested "redis variant" would not have
  exercised a different code path) (acceptance criterion #3 addressed —
  "consider adding" satisfied).
- Script made executable (`chmod +x`), matching its siblings' file mode.

### 2.2 Pre-existing, out-of-scope observation (noted, not a new finding)

- `.github/workflows/template-build-check.yml`'s `build-check` matrix does
  not include `base-hertz` or `ratelimit-hertz` at all — this is why neither
  template's regressions are caught by CI, and why both rely on their own
  local `test/e2e_test.sh`. Not touched here; out of scope for Issue #80
  (issue only asked for the template fix + local e2e script, not a CI
  matrix change).

### 2.3 Findings

None. No correctness bugs were identified in the diff.

## 3. Summary

The fix correctly replaces the hardcoded placeholder module path with the
project's `{{.Module}}` templating convention, verified against both a
positive case (fix applied, full `go mod tidy`/`build`/`vet`/`test` chain
passes) and a negative case (fix reverted, new e2e script correctly fails).
The new `base-hertz/test/e2e_test.sh` closes the coverage gap that let this
bug ship undetected, with an explicitly justified reduced scope relative to
its `ratelimit-hertz` model. No correctness issues found.
