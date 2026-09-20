# Code Review Report — Issue #77 (merged, merge commit `18a5be5`)

**Date:** 2026-09-20
**Branch:** `feat/77-password-reset-atomic-redemption` (merged into `main` via `git merge --no-ff`, merge commit `18a5be5`)
**Range reviewed:** `7719fb1..18a5be5`, 6 commits, 7 files changed, 746 insertions(+), 12 deletions(-)
**Reviewer:** Fresh, independent gf-review pass on the already-merged result (dispatched by the orchestrator), model: Sonnet 5. Not a rubber-stamp of the prior 3 per-task reviews or the prior final whole-branch (opus) review — this pass re-derives its own verdict from the code on `main`.

## Scope

Fixes a TOCTOU race in `user-kitex`'s `ConfirmPasswordReset`: previously the flow was `GetValid` (read-only check) → `setPassword` → best-effort `MarkUsed`, so two concurrent requests carrying the same still-valid credential could both pass the read-then-check before either marked the token used, letting both redeem it. The fix adds a new `passwordreset.Repository.ConsumeValid(ctx, credentialHash) (Token, error)` method that atomically validates-and-marks-used in one step (a single `UPDATE ... WHERE credential_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING *` for `SQLRepository`; mutex-held check-and-mark for `MemoryRepository`), switches `ConfirmPasswordReset` to call it instead of `GetValid`, and removes the now-redundant post-`setPassword` `MarkUsed` call. Includes a concurrency regression test (`TestConfirmPasswordReset_ConcurrentCalls_OnlyOneSucceeds`) and four new `ConsumeValid`-specific repository unit tests.

Commits in range: `89195c7` (design/plan docs), `e456f1c` (`ConsumeValid` added to interface + both implementations + SQL query + repo tests), `36e20a1` (service switched to consume atomically), `9ce71db` (concurrency regression test), `4b83618` (final-review follow-up: pin phone-mismatch-after-consumption assertion, strengthen concurrency test, guide-interface doc comments), `18a5be5` (merge commit).

## Independent verification performed

Rendered the template with `ncgo new --template-dir user-kitex --module example.com/verify77 --kind kitex --db postgres` into a scratch module, ran `make sqlc && go mod tidy`, then://

- `go build ./...` — clean, no errors.
- `go vet ./...` — clean, no warnings.
- `go test ./...` — all 18 packages pass (`internal/application/user`, `internal/infrastructure/passwordreset`, etc.).
- `go test ./internal/application/user/... -run TestConfirmPasswordReset -race -v -count=20` — all `TestConfirmPasswordReset_*` tests, including `TestConfirmPasswordReset_ConcurrentCalls_OnlyOneSucceeds`, pass on all 20 iterations with no `WARNING: DATA RACE`.
- `go test ./internal/infrastructure/passwordreset/... -race -v -count=5` — all `ConsumeValid`/`GetValid`/`MarkUsed`/`InvalidateForUser` repository tests pass on all 5 iterations, race-clean.
- Inspected the sqlc-generated `ConsumeValidPasswordResetToken` (`internal/db/gen/password_reset_token.sql.go`): a single parameterized `UPDATE ... RETURNING` statement, `:one` query mapped correctly onto `PasswordResetToken`'s 7 columns — confirms the atomicity claim isn't just template comments but produces a real single-statement, single-round-trip DB operation.

## Strengths

- **The atomicity claim is real, not just a rename.** The Postgres `UPDATE ... WHERE credential_hash = $1 AND used_at IS NULL AND expires_at > now() RETURNING *` closes the race at the database's row-lock level under normal (READ COMMITTED) isolation: two concurrent `UPDATE`s targeting the same row serialize, and the loser's `WHERE` re-evaluates against the winner's committed `used_at`, returning zero rows (`pgx.ErrNoRows` → `ErrNotFound`). This was verified by reading the generated SQL, not just trusting the migration/query yaml.
- **`MemoryRepository.ConsumeValid` holds its mutex across the entire check-and-mark**, correctly mirroring the DB-level atomicity in the in-memory test double — this is what actually makes the regression test meaningful without a live Postgres instance.
- **Anti-enumeration property preserved.** `ConsumeValid` returns the same `ErrNotFound` for "no match," "already used," and "expired," exactly matching `GetValid`'s existing contract — callers still cannot distinguish failure reasons.
- **The accepted trade-off (credential burned even if `setPassword` fails afterward) is explicitly documented** in the function's doc comment and is a reasonable, deliberate choice: it guarantees "at most one caller completes a reset" is upheld even under partial-failure scenarios, at the cost of the user needing to request a fresh reset if `setPassword` errors post-consumption. This is called out, not silently introduced.
- **`GetValid` and `MarkUsed` are kept in the interface** (not deleted) with updated doc comments steering future callers toward `ConsumeValid` for redemption — a minimal, additive change rather than a wide refactor, keeping blast radius small.
- **Regression test genuinely exercises the race.** `TestConfirmPasswordReset_ConcurrentCalls_OnlyOneSucceeds` launches two goroutines gated on a shared `start` channel to maximize contention, asserts exactly one success, asserts the loser's error is the generic anti-enumeration message (not a different error), and cross-checks the audit log has exactly one `user.password_reset_confirmed` entry — independently verified pass at `-count=20 -race`.
- **Follow-up commit `4b83618` closes a real gap**: it added an assertion (in `TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError`) that the credential is unredeemable *after* a wrong-phone attempt — directly pinning the documented trade-off (credential burned even when the SMS phone check fails downstream) rather than leaving it as an assertion-free comment.
- **sqlc query change is minimal and additive**: a new named query appended to the existing `.sql` file; the pre-existing `GetValidPasswordResetToken` and `MarkPasswordResetTokenUsed` queries are untouched.

## Issues

### Critical (Must Fix)
None.

### Important (Should Fix)
None.

### Minor (Nice to Have)
1. **`GetValid` is now unused in production code paths.** After this change, `ConfirmPasswordReset` no longer calls `GetValid` at all — its only remaining callers in the whole template tree are test files (`internal_infrastructure_passwordreset_repository_test_go.yaml`, and pre-existing tests in `internal_application_user_user_service_test_go.yaml` that assert token state directly against the repository). This is intentional per the design doc ("`GetValid`/`MarkUsed` stay in the interface" for future/other callers) and is not a defect, but it's worth a maintainer note that `GetValid`'s only live justification today is test introspection — if a future refactor removes those direct-repository test assertions, `GetValid` would become entirely dead production code with no compile-time signal (Go doesn't flag unused interface methods).
2. **The concurrency regression test only exercises `MemoryRepository`'s mutex-based atomicity**, not `SQLRepository`'s real `UPDATE ... RETURNING` under actual concurrent Postgres transactions (no live-DB integration test in this suite). This is a reasonable and common scope cut for a unit-test-only regression suite — the SQL statement's correctness was verified by code inspection in this review rather than by a live concurrent-DB test — but a future integration-test pass (if one exists for this repo) would close the last gap in end-to-end confidence.

Neither item blocks the already-completed merge; both are forward-looking notes rather than defects in the delivered code.

## Assessment

**Verdict: Approve.**

**Reasoning:** This review independently re-derived the correctness argument rather than relying on the prior reviews' conclusions. The core claim — a single atomic DB statement replaces a read-then-write race — was verified three ways: (1) reading the actual sqlc-generated Go code to confirm it is one parameterized `UPDATE...RETURNING` round-trip, not multiple statements; (2) reading `MemoryRepository.ConsumeValid` to confirm the mutex is held across the full check-and-mark, not just part of it; (3) rendering the real template into a fresh module and running the full test suite plus the concurrency regression test at `-race -count=20`, with zero failures and zero data races. The anti-enumeration property (identical `ErrNotFound` for all invalid cases) is preserved by direct comparison with `GetValid`'s existing contract. The documented trade-off (burn-on-attempt even if a downstream check like SMS-phone-match fails) is a sound, explicitly-called-out design choice, and the follow-up commit correctly added a test pinning that exact behavior. The two Minor notes above are forward-looking maintenance observations, not defects, and do not block this already-merged change.
