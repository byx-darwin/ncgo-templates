# Code Review Report — Issue #76 (merged locally, merge commit `c999e72`)

**Date:** 2026-09-20
**Branch:** `feat/76-confirm-password-reset-audit` (merged into `main` via `--no-ff`, merge commit `c999e7206a6579058a84ca96118887d35a2d2a7e`)
**Range reviewed:** `4936286..bea6e34` (docs commit → implementation commit tip before merge), 2 files changed, 72 insertions(+), 4 deletions(-)
**Reviewer:** gf-workflow Phase 4 delivery code-review-report, dispatched during Phase 3 task review (general-purpose subagent), model: Sonnet 5

## Scope

Adds a generic `user.password_reset_confirm.failure` audit entry to all four credential-validation failure branches of `user-kitex`'s `ConfirmPasswordReset` (unknown/expired/reused token, SMS missing phone, SMS user-lookup failure, SMS phone mismatch), mirroring the existing `setPassword` → `user.password_change.failure` fire-and-forget audit pattern. Per the approved design (`docs/superpowers/specs/2026-09-20-confirm-password-reset-failure-audit-design.md`), the Action string and absence of `DetailJSON` are identical across all four branches (anti-enumeration requirement); `ActorUID`/`Target` are populated with `tok.UserID.String()` when known (the three SMS-channel branches) and left empty when the token lookup itself fails (identity unknown).

This is a `standard`-mode gf-workflow run. The change was reviewed once, at Task-completion time in Phase 3 (batched implementation — both plan tasks are mechanical single-function edits, complexity score 2, below the "simple" threshold for per-task subagent review), by an independent subagent given the diff, design doc, and plan. This report is the formal Phase 4 delivery record, not a separate pass.

## Strengths

- **Anti-enumeration property verified by direct comparison of all 4 call sites**: every branch writes the identical literal `Action: "user.password_reset_confirm.failure"` with no `DetailJSON`, so the audit record itself cannot be used to distinguish which specific failure occurred.
- **Fire-and-forget semantics preserved**: every new call is `_ = s.audit.Write(ctx, audit.Entry{...})`, placed immediately before the pre-existing `return errors.New(...)`; no control-flow, return-value, or response-text change; consistent with the established (non-goroutine) "fire-and-forget" convention already used by `setPassword`'s `user.password_change.failure` write.
- **ActorUID/Target rule matches the approved design (Option A)**: empty on the token-lookup-failure branch (identity unknown), `tok.UserID.String()` on the three SMS-channel branches (identity known via the already-fetched token).
- **No signature or exported-symbol changes**: `ConfirmPasswordReset`'s signature is untouched; no new types.
- **Tests assert both the write and the non-leakage property**: `TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError` and `TestConfirmPasswordReset_ReusedCredential_Rejected` assert the audit entry's `Action`, empty `ActorUID`/`Target`, and empty `DetailJSON`; `TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError` / `..._WrongPhone_ReturnsGenericError` assert `ActorUID == regOut.Uid` and empty `DetailJSON`.
- **Legitimate, minimal deviation from the plan's draft assertions, verified correct**: the plan's draft tests asserted `len(aw.Entries()) == 1`, but `RequestPasswordReset` in test setup already writes a `user.password_reset_requested` entry before the confirm-path failure, so the committed tests instead filter `aw.Entries()` by `Action` and fail (`t.Fatalf`) if no matching entry is found — this does not weaken the assertions (a wrong `ActorUID`/`Target` still fails the test) and correctly accounts for the pre-existing audit write from setup.
- **Verified against the real build**: the implementer rendered the template via `ncgo new --template-dir` into a temp Go module and ran `go build ./...`, `go vet ./...`, and `go test ./...` across the whole module (34 packages) — all passed, including all 7 `TestConfirmPasswordReset_*` tests.

## Issues

### Critical (Must Fix)
None.

### Important (Should Fix)
None.

### Minor (Nice to Have)
1. The SMS "user lookup fails" branch (`s.repo.GetByID` returning an error for an SMS-channel token) has no dedicated test — this is an explicitly documented, pre-existing scope cut in the plan's Global Constraints (the test-only `fakeRepo` has no way to make a previously-registered user's `GetByID` fail without new test infrastructure), not a new gap introduced by this change. The code shape at that call site is identical to the two adjacent, tested SMS branches, so risk is low.
2. The two SMS failure tests call `aw.Entries()` multiple times inside their filtering loop; hoisting to a local variable (`entries := aw.Entries()`) would be marginally cleaner. Does not affect correctness — `audit.MemoryWriter.Entries()` returns a fresh copy each call.

## Assessment

**Ready to merge:** Yes (already merged via `c999e72`)

**Reasoning:** The security-relevant property this change delivers — audit visibility for `ConfirmPasswordReset` failures without weakening anti-enumeration — was independently verified by direct inspection of all four call sites (identical Action string, no DetailJSON) and by the identity-known/identity-unknown ActorUID/Target split matching the approved design. Test coverage exercises both the audit-write requirement and the non-leakage requirement for three of the four failure branches, with the fourth's absence being a documented, low-risk, pre-existing test-infrastructure limitation rather than a defect in this change. No Critical or Important issues found. The 2 Minor items above do not block the already-completed merge.
