# Design: base-hertz hardcoded acme/scratch import breaks fresh generation (Issue #80)

## Classification

Bounded — one-line template fix plus a new e2e regression test script,
copying an established pattern already used by two sibling templates. No new
subsystem, no interface change.

## Problem

`base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`
(introduced in `deaf3d2`, unrelated to #73) hardcodes:

```go
"github.com/acme/scratch/internal/base/conf"
"github.com/acme/scratch/internal/pkg/ratelimit"
```

instead of the module-templating convention `{{.Module}}` used by every
other file in `base-hertz/hertz-template/` (confirmed via
`grep -rn '{{.Module}}' base-hertz/hertz-template/*.yaml`, 15+ hits) and by
the equivalent file in `ratelimit-hertz/hertz-template/`, which already uses
`"{{.Module}}/internal/base/conf"` / `"{{.Module}}/internal/pkg/ratelimit"`.

Effect: `ncgo new --template-dir base-hertz ...` on a fresh module produces a
project where `go mod tidy` fails (`cannot find module
github.com/acme/scratch/...`). ncgo treats codegen failures as non-blocking,
so the scaffold still lands on disk, but it's unusable until manually
patched.

`base-hertz` also has no `test/e2e_test.sh` (unlike `ratelimit-hertz` /
`admin-bff-hertz`), so nothing in this repo's own suite would have caught
this — it surfaced only via manual generation during #73's review.

## Scope (confirmed with user — Option B)

1. Fix the hardcoded import (mandatory AC).
2. Add `base-hertz/test/e2e_test.sh`, modeled on
   `ratelimit-hertz/test/e2e_test.sh`, so this class of bug is caught
   automatically going forward (soft AC in the issue, promoted to in-scope
   per user decision).

## Fix

### 1. Import path

In `base-hertz/hertz-template/internal_pkg_middleware_rate_limit_test_go.yaml`,
lines 26-27:

```diff
-    	"github.com/acme/scratch/internal/base/conf"
-    	"github.com/acme/scratch/internal/pkg/ratelimit"
+    	"{{.Module}}/internal/base/conf"
+    	"{{.Module}}/internal/pkg/ratelimit"
```

No other occurrences of `acme/scratch` exist under `base-hertz/` (verified by
`grep -rn "acme/scratch" base-hertz/`).

### 2. `base-hertz/test/e2e_test.sh`

`base-hertz` has no `--infra`/`--db` variant flags exercised by its own
template surface the way `ratelimit-hertz` does (redis/postgres are
config-driven, not generation-flag-driven) — confirm this by reading
`base-hertz`'s `ncgo.yaml`/template metadata before writing the script, and
adapt scope accordingly (do not fabricate flags `ncgo new` doesn't accept).
Minimum required content, following the `ratelimit-hertz`/`admin-bff-hertz`
pattern (`log`/`skip`/`fail` helpers, `ESC_OPEN`/`ESC_CLOSE` residual-escape
guard, generate-to-tmpdir, `assert_no_residual`, `go_build`, `go_test`,
nonzero exit on any `FAILS`):

- Baseline hermetic generation (`ncgo new --template-dir base-hertz ...`
  into a tmp dir with a real module path, e.g. `example.com/bh-e2e`).
- `assert_no_residual`: no leftover `{{...}}` template actions and no
  brace-escape artifacts in generated `.go` files — this is the exact
  regression class Issue #80 is about, so it must be the first assertion.
- `go mod tidy && go build ./... && go vet ./... && go test ./...` in the
  generated project (matches the issue's stated acceptance command).
- If `base-hertz` supports a redis-backed rate-limit config variant reachable
  through generation flags or a post-generation config edit, gate an
  additional variant on `redis-cli`/`redis ping` availability the same way
  `ratelimit-hertz`'s script does; otherwise the hermetic baseline alone is
  sufficient and the script should say so in a comment rather than fabricate
  an untested variant.

## Testing

- `grep -rn "acme/scratch" base-hertz/hertz-template/` → no output.
- Fresh `ncgo new --template-dir base-hertz ...` project:
  `go mod tidy && go build ./... && go vet ./... && go test ./...` all pass.
- New `base-hertz/test/e2e_test.sh` run locally, exits 0.

## Non-goals

- Not touching `ratelimit-hertz` or `admin-bff-hertz` — their equivalent
  files already use `{{.Module}}` and already have `e2e_test.sh`.
- Not adding redis/postgres variants to the new script beyond what
  `base-hertz`'s actual generation surface supports — no fabricated flags.
