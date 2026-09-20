# Password Reset Atomic Redemption Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the TOCTOU race in `user-kitex`'s `ConfirmPasswordReset` by replacing the non-atomic `GetValid` → `setPassword` → `MarkUsed` sequence with a single atomic check-and-consume step at the top of the function, so two concurrent redemptions of the same credential can never both succeed.

**Architecture:** Add one new `Repository` method, `ConsumeValid`, to the `passwordreset` package (`user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml`, which renders to `internal/infrastructure/passwordreset/repository.go`). `SQLRepository.ConsumeValid` issues a single atomic `UPDATE ... WHERE credential_hash=$1 AND used_at IS NULL AND expires_at>now() RETURNING *` (added as a new sqlc query). `MemoryRepository.ConsumeValid` performs the equivalent check-and-mark inside one critical section (single `Lock`/`Unlock` pair, no calls out to the existing `GetValid`/`MarkUsed` methods). `ConfirmPasswordReset` in `internal/application/user/user_service.go` calls `ConsumeValid` where it currently calls `GetValid`, and no longer calls `MarkUsed` afterward. `GetValid` and `MarkUsed` remain in the interface unchanged (other tests and any future callers still use them); only `ConfirmPasswordReset`'s call site changes.

**Tech Stack:** Go, sqlc (`sqlc generate`), pgx v5, `sync.Mutex`, Go's built-in `testing` package + `go test -race` for the concurrency assertion. This repo is a template project — all Go source lives as `body:` fields inside `.yaml` files under `user-kitex/kitex-template/`; verification requires rendering the template into a real module (`ncgo new --template-dir`) and running `go build/vet/test` there, matching the pattern used in commit `bea6e34`.

**Spec:** `docs/superpowers/specs/2026-09-20-password-reset-atomic-redemption-design.md`

## Global Constraints

- All edits happen in the **template YAML files** (`user-kitex/kitex-template/*.yaml`), never in a rendered output directory — the `body:` field's Go source uses `{{ "{" }}` / `{{ "}" }}` for literal braces and `{{.Module}}` for the module path placeholder; preserve this escaping exactly.
- `GetValid` and `MarkUsed` stay in the `Repository` interface and both implementations — do not remove or rename them (existing repository tests call them directly).
- No new migration — reuse the existing `password_reset_tokens` table (`internal/db/schema/000004_password_reset_tokens.sql`), no schema change.
- No public API change — RPC signatures and IDL are untouched.
- After any change to `internal/db/query/password_reset_token.sql`, `make sqlc` (or equivalent `sqlc generate -f internal/db/sqlc.yaml` in the rendered module) must be re-run before `go build` succeeds, because `SQLRepository.ConsumeValid` calls a generated method that does not exist until sqlc regenerates `internal/db/gen`.
- Verification for every task: render the template via `ncgo new --template-dir` into a temp module, then `go build ./... && go vet ./... && go test ./...` (add `-race` for the concurrency test in Task 3) from that temp module — mirrors the verification note in commit `bea6e34`.

---

### Task 1: Add `ConsumeValid` to the `passwordreset` Repository (SQL query + interface + both implementations + repository-level tests)

**Files:**
- Modify: `user-kitex/kitex-template/internal_db_query_password_reset_token_sql.yaml` (renders to `internal/db/query/password_reset_token.sql`)
- Modify: `user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml` (renders to `internal/infrastructure/passwordreset/repository.go`)
- Modify: `user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_test_go.yaml` (renders to `internal/infrastructure/passwordreset/repository_test.go`)

**Interfaces:**
- Produces: `Repository.ConsumeValid(ctx context.Context, credentialHash string) (Token, error)` — on success returns the now-consumed `Token` (same fields as `GetValid`'s return, with `UsedAt` now non-nil server-side though the in-memory struct returned does not need to set it); on any invalid case (no match, already used, expired) returns `passwordreset.ErrNotFound`, identical contract to `GetValid`. Task 2 calls this method by name.

- [ ] **Step 1: Write the failing repository tests for `MemoryRepository.ConsumeValid`**

Add to `user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_test_go.yaml`, inside the existing `body:` block, after `TestMemoryRepository_InvalidateForUser_InvalidatesAllUnused`:

```go
func TestMemoryRepository_ConsumeValid_MarksUsedAndReturnsToken(t *testing.T) {{ "{" }}
	r := passwordreset.NewMemoryRepository()
	ctx := context.Background()
	userID := uuid.New()
	tok := passwordreset.Token{{ "{" }}
		ID:             uuid.New(),
		UserID:         userID,
		Channel:        "email",
		CredentialHash: "hash-consume",
		ExpiresAt:      time.Now().Add(15 * time.Minute),
	{{ "}" }}
	_ = r.Create(ctx, tok)

	got, err := r.ConsumeValid(ctx, "hash-consume")
	if err != nil {{ "{" }}
		t.Fatalf("ConsumeValid: %v", err)
	{{ "}" }}
	if got.UserID != userID {{ "{" }}
		t.Fatalf("ConsumeValid.UserID = %v, want %v", got.UserID, userID)
	{{ "}" }}

	if _, err := r.GetValid(ctx, "hash-consume"); err != passwordreset.ErrNotFound {{ "{" }}
		t.Fatalf("expected token to be marked used after ConsumeValid, GetValid err = %v", err)
	{{ "}" }}
{{ "}" }}

func TestMemoryRepository_ConsumeValid_SecondCallFails(t *testing.T) {{ "{" }}
	r := passwordreset.NewMemoryRepository()
	ctx := context.Background()
	tok := passwordreset.Token{{ "{" }}
		ID:             uuid.New(),
		UserID:         uuid.New(),
		Channel:        "email",
		CredentialHash: "hash-double-consume",
		ExpiresAt:      time.Now().Add(15 * time.Minute),
	{{ "}" }}
	_ = r.Create(ctx, tok)

	if _, err := r.ConsumeValid(ctx, "hash-double-consume"); err != nil {{ "{" }}
		t.Fatalf("first ConsumeValid: %v", err)
	{{ "}" }}
	if _, err := r.ConsumeValid(ctx, "hash-double-consume"); err != passwordreset.ErrNotFound {{ "{" }}
		t.Fatalf("expected ErrNotFound on second ConsumeValid, got %v", err)
	{{ "}" }}
{{ "}" }}

func TestMemoryRepository_ConsumeValid_ExpiredRejected(t *testing.T) {{ "{" }}
	r := passwordreset.NewMemoryRepository()
	ctx := context.Background()
	tok := passwordreset.Token{{ "{" }}
		ID:             uuid.New(),
		UserID:         uuid.New(),
		Channel:        "sms",
		CredentialHash: "hash-expired-consume",
		ExpiresAt:      time.Now().Add(-1 * time.Minute),
	{{ "}" }}
	_ = r.Create(ctx, tok)

	if _, err := r.ConsumeValid(ctx, "hash-expired-consume"); err != passwordreset.ErrNotFound {{ "{" }}
		t.Fatalf("expected ErrNotFound for expired token, got %v", err)
	{{ "}" }}
{{ "}" }}

func TestMemoryRepository_ConsumeValid_UnknownCredentialFails(t *testing.T) {{ "{" }}
	r := passwordreset.NewMemoryRepository()
	if _, err := r.ConsumeValid(context.Background(), "no-such-hash"); err != passwordreset.ErrNotFound {{ "{" }}
		t.Fatalf("expected ErrNotFound for unknown credential, got %v", err)
	{{ "}" }}
{{ "}" }}
```

- [ ] **Step 2: Render the template and run the new tests to verify they fail**

```bash
ncgo new --template-dir user-kitex/kitex-template --output /tmp/ncgo-verify-77 --module example.com/verify77
cd /tmp/ncgo-verify-77
go test ./internal/infrastructure/passwordreset/... -run TestMemoryRepository_ConsumeValid -v
```

Expected: FAIL — `r.ConsumeValid undefined (type *passwordreset.MemoryRepository has no field or method ConsumeValid)`.

- [ ] **Step 3: Add the new sqlc query**

In `user-kitex/kitex-template/internal_db_query_password_reset_token_sql.yaml`, append to the `body:` block (after `MarkPasswordResetTokenUsed`):

```sql
-- name: ConsumeValidPasswordResetToken :one
UPDATE password_reset_tokens
SET used_at = now()
WHERE credential_hash = sqlc.arg('credential_hash')
  AND used_at IS NULL
  AND expires_at > now()
RETURNING *;
```

- [ ] **Step 4: Add `ConsumeValid` to the `Repository` interface and both implementations**

In `user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml`, edit the `body:` block:

Add to the `Repository` interface, after `GetValid`'s doc comment and signature:

```go
	// ConsumeValid atomically validates and marks credentialHash's token as
	// used in a single step, closing the check-then-act race between
	// validation and marking a token used (Issue #77). Semantics otherwise
	// match GetValid: any invalid case (no match, already used, expired)
	// returns ErrNotFound, and callers must not distinguish these to avoid
	// leaking which condition failed.
	ConsumeValid(ctx context.Context, credentialHash string) (Token, error)
```

Add to `SQLRepository`, after its `GetValid` method:

```go
func (r *SQLRepository) ConsumeValid(ctx context.Context, credentialHash string) (Token, error) {{ "{" }}
	row, err := r.q.ConsumeValidPasswordResetToken(ctx, &amp;gen.ConsumeValidPasswordResetTokenParams{{ "{" }}CredentialHash: credentialHash{{ "}" }})
	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
		return Token{{ "{" }}{{ "}" }}, ErrNotFound
	{{ "}" }}
	if err != nil {{ "{" }}
		return Token{{ "{" }}{{ "}" }}, err
	{{ "}" }}
	return Token{{ "{" }}
		ID:             row.ID.Bytes,
		UserID:         row.UserID.Bytes,
		Channel:        row.Channel,
		CredentialHash: row.CredentialHash,
		ExpiresAt:      fromPgTimestamptz(row.ExpiresAt),
		CreatedAt:      fromPgTimestamptz(row.CreatedAt),
	{{ "}" }}, nil
{{ "}" }}
```

Add to `MemoryRepository`, after its `GetValid` method:

```go
func (r *MemoryRepository) ConsumeValid(ctx context.Context, credentialHash string) (Token, error) {{ "{" }}
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	for id, t := range r.tokens {{ "{" }}
		if t.CredentialHash != credentialHash {{ "{" }}
			continue
		{{ "}" }}
		if t.UsedAt != nil || now.After(t.ExpiresAt) {{ "{" }}
			return Token{{ "{" }}{{ "}" }}, ErrNotFound
		{{ "}" }}
		t.UsedAt = &amp;now
		r.tokens[id] = t
		return t, nil
	{{ "}" }}
	return Token{{ "{" }}{{ "}" }}, ErrNotFound
{{ "}" }}
```

Note: unlike `GetValid`+`MarkUsed` (two separate lock/unlock pairs), this holds `r.mu` for the entire find-check-mark sequence — this is what makes it safe under concurrent calls with the same `credentialHash`.

- [ ] **Step 5: Regenerate sqlc code and run the tests to verify they pass**

```bash
cd /tmp/ncgo-verify-77
make sqlc
go build ./... && go vet ./...
go test ./internal/infrastructure/passwordreset/... -run TestMemoryRepository_ConsumeValid -v
```

Expected: PASS for all four new tests. Also re-run the full existing suite for this package to confirm no regression: `go test ./internal/infrastructure/passwordreset/... -v`.

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_db_query_password_reset_token_sql.yaml \
        user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml \
        user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_test_go.yaml
git commit -m "feat(user-kitex): add atomic ConsumeValid to passwordreset.Repository"
```

---

### Task 2: Switch `ConfirmPasswordReset` to `ConsumeValid`

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml` (renders to `internal/application/user/user_service.go`)

**Interfaces:**
- Consumes: `Repository.ConsumeValid(ctx context.Context, credentialHash string) (Token, error)` from Task 1 — same error contract as `GetValid` (`ErrNotFound` on any invalid case).
- Produces: no new exported symbols; `ConfirmPasswordReset`'s external behavior (signature, error strings, audit actions) is unchanged — only its internal call to the repository changes.

- [ ] **Step 1: Confirm existing tests currently pass (baseline before the change)**

```bash
ncgo new --template-dir user-kitex/kitex-template --output /tmp/ncgo-verify-77 --module example.com/verify77
cd /tmp/ncgo-verify-77
go test ./internal/application/user/... -run TestConfirmPasswordReset -v
```

Expected: all 7 existing `TestConfirmPasswordReset_*` tests PASS (this is the pre-change baseline; no assertions changed yet, since `MemoryRepository` already satisfies both `GetValid` and `ConsumeValid` after Task 1).

- [ ] **Step 2: Replace `GetValid` with `ConsumeValid` and drop the trailing `MarkUsed` call**

In `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`, inside the `body:` block, replace the whole `ConfirmPasswordReset` function:

Old (for reference — replace this entire block):
```go
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, phone, newPassword string) error {{ "{" }}
	tok, err := s.resetRepo.GetValid(ctx, hashCredential(credential))
	...
	if err := s.setPassword(ctx, tok.UserID.String(), nil, newPassword, "user.password_reset_confirmed", "", "", ""); err != nil {{ "{" }}
		return err
	{{ "}" }}
	if err := s.resetRepo.MarkUsed(ctx, tok.ID); err != nil {{ "{" }}
		log.Printf("user: ConfirmPasswordReset MarkUsed failed: %v", err)
	{{ "}" }}
	return nil
{{ "}" }}
```

New:
```go
// ConfirmPasswordReset validates credential against the stored token,
// then sets uid's password to newPassword via the shared setPassword
// helper (same path as admin-forced reset). All failure modes — no
// matching token, expired, already used, or (SMS channel only) a
// missing/mismatched phone — return the same generic error so a caller
// cannot distinguish them (see design doc's anti-enumeration section).
// phone is required and checked only when the matched token's Channel
// is "sms"; it is ignored entirely for "email" tokens (Issue #75).
//
// The credential is consumed atomically up front via ConsumeValid,
// closing a TOCTOU race where two concurrent requests carrying the same
// still-valid credential could both pass a plain read-then-check before
// either marked the token used (Issue #77). One consequence: if the SMS
// phone check below fails, or setPassword itself errors, the credential
// has already been burned and cannot be retried — the caller must
// request a new reset. This trade-off was chosen deliberately so that,
// under concurrency, at most one caller can ever complete a reset with a
// given credential.
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, phone, newPassword string) error {{ "{" }}
	tok, err := s.resetRepo.ConsumeValid(ctx, hashCredential(credential))
	if err != nil {{ "{" }}
		if !errors.Is(err, passwordreset.ErrNotFound) {{ "{" }}
			log.Printf("user: ConfirmPasswordReset lookup failed: %v", err)
		{{ "}" }}
		// The token lookup itself failed, so the caller's identity is not
		// known here — record the failure without an actor/target rather
		// than guessing, to avoid attributing it to the wrong account.
		// Action is identical across every ConfirmPasswordReset failure
		// branch and carries no detail, preserving anti-enumeration.
		_ = s.audit.Write(ctx, audit.Entry{{ "{" }}Action: "user.password_reset_confirm.failure"{{ "}" }})
		return errors.New("user: reset credential is invalid or expired")
	{{ "}" }}
	if tok.Channel == "sms" {{ "{" }}
		if phone == "" {{ "{" }}
			_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: tok.UserID.String(), Target: tok.UserID.String(), Action: "user.password_reset_confirm.failure"{{ "}" }})
			return errors.New("user: reset credential is invalid or expired")
		{{ "}" }}
		u, err := s.repo.GetByID(ctx, tok.UserID)
		if err != nil {{ "{" }}
			if !errors.Is(err, user.ErrNotFound) {{ "{" }}
				log.Printf("user: ConfirmPasswordReset phone lookup failed: %v", err)
			{{ "}" }}
			_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: tok.UserID.String(), Target: tok.UserID.String(), Action: "user.password_reset_confirm.failure"{{ "}" }})
			return errors.New("user: reset credential is invalid or expired")
		{{ "}" }}
		if u.Phone != phone {{ "{" }}
			_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: tok.UserID.String(), Target: tok.UserID.String(), Action: "user.password_reset_confirm.failure"{{ "}" }})
			return errors.New("user: reset credential is invalid or expired")
		{{ "}" }}
	{{ "}" }}
	return s.setPassword(ctx, tok.UserID.String(), nil, newPassword, "user.password_reset_confirmed", "", "", "")
{{ "}" }}
```

Note: the tail simplifies to `return s.setPassword(...)` directly since there is no longer a `MarkUsed` call after it.

- [ ] **Step 3: Re-run the existing `ConfirmPasswordReset` tests to verify they still pass unchanged**

```bash
cd /tmp/ncgo-verify-77
# re-render since the template changed
ncgo new --template-dir user-kitex/kitex-template --output /tmp/ncgo-verify-77 --module example.com/verify77 --force
cd /tmp/ncgo-verify-77
go build ./... && go vet ./...
go test ./internal/application/user/... -run TestConfirmPasswordReset -v
```

Expected: all 7 existing tests PASS with no modification needed to their assertions (they only observe `ConfirmPasswordReset`'s external behavior — return value, updated password, audit entries — none of which changed).

- [ ] **Step 4: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_go.yaml
git commit -m "fix(user-kitex): consume password-reset credential atomically in ConfirmPasswordReset"
```

---

### Task 3: Add the concurrency regression test

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml` (renders to `internal/application/user/user_service_test.go`)

**Interfaces:**
- Consumes: `newTestServiceWithReset() (*Service, *passwordreset.MemoryRepository, *notify.LogEmailSender, *notify.LogSMSSender, *audit.MemoryWriter)` (existing helper, unchanged), `svc.ConfirmPasswordReset(ctx, credential, phone, newPassword string) error` (unchanged signature from Task 2), `extractTokenFromLink(t *testing.T, link string) string` (existing helper, unchanged).
- Produces: no new exported symbols — this is a test-only addition.

- [ ] **Step 1: Write the failing (well, initially-should-already-pass-if-fix-is-correct, but written before verifying) concurrency test**

Add to `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`, inside the `body:` block, after `TestConfirmPasswordReset_ReusedCredential_Rejected` (needs `"sync"` added to the import block — see Step 1a):

Step 1a — add the import. In the same file's `body:` block, update the import list from:
```go
import (
	"context"
	"net/url"
	"testing"
	"time"

	"{{.Module}}/internal/domain/user"
	"{{.Module}}/internal/infrastructure/audit"
	"{{.Module}}/internal/infrastructure/auth"
	"{{.Module}}/internal/infrastructure/notify"
	"{{.Module}}/internal/infrastructure/passwordreset"
	"{{.Module}}/internal/pkg/oauth"
)
```
to:
```go
import (
	"context"
	"net/url"
	"sync"
	"testing"
	"time"

	"{{.Module}}/internal/domain/user"
	"{{.Module}}/internal/infrastructure/audit"
	"{{.Module}}/internal/infrastructure/auth"
	"{{.Module}}/internal/infrastructure/notify"
	"{{.Module}}/internal/infrastructure/passwordreset"
	"{{.Module}}/internal/pkg/oauth"
)
```

Step 1b — add the test:

```go
// TestConfirmPasswordReset_ConcurrentCalls_OnlyOneSucceeds is the
// regression test for Issue #77 (TOCTOU race on password-reset token
// redemption): two goroutines racing to redeem the same still-valid
// credential must not both succeed. Run with `go test -race` to also
// catch any data-race regression in ConsumeValid's locking.
func TestConfirmPasswordReset_ConcurrentCalls_OnlyOneSucceeds(t *testing.T) {{ "{" }}
	svc, _, es, _, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "frank", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "frank@example.com"
	_ = svc.RequestPasswordReset(ctx, "frank@example.com", "email")
	token := extractTokenFromLink(t, es.Sent()[0].Link)

	const attempts = 2
	errs := make([]error, attempts)
	var wg sync.WaitGroup
	wg.Add(attempts)
	for i := 0; i < attempts; i++ {{ "{" }}
		i := i
		go func() {{ "{" }}
			defer wg.Done()
			errs[i] = svc.ConfirmPasswordReset(ctx, token, "", "concurrent-new-password")
		{{ "}" }}()
	{{ "}" }}
	wg.Wait()

	successes := 0
	for _, err := range errs {{ "{" }}
		if err == nil {{ "{" }}
			successes++
		{{ "}" }}
	{{ "}" }}
	if successes != 1 {{ "{" }}
		t.Fatalf("expected exactly 1 successful redemption out of %d concurrent calls, got %d (errs=%v)", attempts, successes, errs)
	{{ "}" }}
{{ "}" }}
```

- [ ] **Step 2: Render, build, and run the new test with the race detector**

```bash
ncgo new --template-dir user-kitex/kitex-template --output /tmp/ncgo-verify-77 --module example.com/verify77 --force
cd /tmp/ncgo-verify-77
go build ./... && go vet ./...
go test ./internal/application/user/... -run TestConfirmPasswordReset_ConcurrentCalls_OnlyOneSucceeds -race -v -count=10
```

Expected: PASS on all 10 runs (`-count=10` guards against a flaky race window), with no `WARNING: DATA RACE` output. If Task 1/2 were implemented correctly, this passes without further code changes — this test exists purely to prove the fix and guard against regression.

- [ ] **Step 3: Run the full module test suite as final verification**

```bash
cd /tmp/ncgo-verify-77
go build ./... && go vet ./...
go test ./... -race
```

Expected: PASS across the whole rendered module (mirrors the verification note in commit `bea6e34`).

- [ ] **Step 4: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "test(user-kitex): add concurrency regression test for password-reset redemption (Issue #77)"
```

---

## Self-Review Notes

- **Spec coverage:** Design doc's three acceptance criteria are each covered: SQLRepository atomic UPDATE...RETURNING → Task 1 Step 3-4; MemoryRepository holding its lock across check-and-mark → Task 1 Step 4; concurrency test asserting only one success → Task 3. The design doc's "GetValid/MarkUsed stay in the interface" decision is honored in Task 1 (additive change only) and Task 2 (only the call site changes).
- **Type consistency:** `ConsumeValid(ctx context.Context, credentialHash string) (Token, error)` signature is identical across its Task 1 definition (interface + both implementations) and its Task 2 call site. `gen.ConsumeValidPasswordResetTokenParams{{ "{" }}CredentialHash: credentialHash{{ "}" }}` follows the exact naming pattern sqlc already generates for `GetValidPasswordResetTokenParams` (confirmed against the existing `GetValid` implementation), so no placeholder type was invented.
- **No placeholders:** every step has literal code; no "add appropriate error handling" style steps remain.
