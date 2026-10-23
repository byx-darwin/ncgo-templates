# Application accounts: local integration, 2026-10-23

Freshly generated `admin-services-kitex`, `user-kitex`, `admin-bff-hertz` and
`user-bff-hertz` services were built and started with the standalone admin
frontend. PostgreSQL and Redis use dedicated Docker containers and a separate
volume; existing local databases were not modified. Authority migrations reached
v4 and account migrations reached v5. Generated permissions matched the checked-in
seed, and permissions plus the admin/operator user seed were applied successfully.

## Measured checks

- Real browser: administrator login, application configuration menu, method
  configuration save, SMTP edit with blank credentials, credentials not echoed,
  and explicit SMTP test delivery to the local mailbox.
- HTTP: per-client method discovery; unknown password login never registers;
  email OTP auto-registration, resend cooldown, incorrect-code and replay denial.
- Contact proof for initial password; password change revokes old sessions;
  multiple devices, current-device logout, refresh rotation and replay denial.
- Recovery has identical known/unknown responses; reset invalidates all previous
  access/refresh credentials and accepts the new password.
- Local OIDC: verified RS256 ID token, issuer/audience/nonce and PKCE, first-login
  registration, existing-account binding, single-use exchange and reauth grants.
- Occupied contact binding is rejected without merging users. Replacing an email
  preserves UID, revokes old sessions and allows login via the replacement;
  replacing it back behaves identically. Removing the last usable OAuth identity
  through the administrator API is rejected.
- Disabling password login takes effect immediately while existing sessions and
  refresh continue. Administrator ban revokes sessions; unban cannot revive them.
- Configuration reads omit secrets; blank updates preserve encrypted credentials;
  PostgreSQL contains ciphertext rather than the test password. Config save/test
  actions have audit records. Anonymous access returns 401; the restricted
  operator cannot read/save/test configuration (403).
- Fresh template build/vet/full tests, PostgreSQL race suites and deterministic
  seed consistency passed. Authority build/vet/full tests passed. Independent
  review reran wire/error regressions with the race detector and found no blockers.

## Runtime issues fixed

1. BFF protobuf RPC connections lacked TTHeader, so Kitex business errors could be
   lost and decoded as empty success. Both BFFs now use TTHeader with the client
   metadata handler; real TCP tests cover successful and rejected calls.
2. Untyped errors were adapted to business status zero, which Kitex treats as
   success. User/authority adapters now return a nonzero generic internal error
   without exposing private details. Tests reject zero status and secret leakage.

The local authority uses its supported default memory token store. The existing
Redis token-store seam is not implemented and was not enabled for this run.
Application accounts continue to use their PostgreSQL persistent sessions.

## Scope and local access

Admin frontend: `http://localhost:8000/system/auth`; admin BFF:
`http://127.0.0.1:8080`; application API: `http://127.0.0.1:8081` with
`X-Client-ID: local-web`. The seeded local administrator is `admin / Admin@123`.
The local run directory is `$HOME/.cache/ncgo-account-local-20261023`, containing
startup/stop scripts, generated services, private configuration, logs and the
local test account. Secrets and runtime token files were not committed.

SMTP and OIDC used local protocol servers, not production accounts. On macOS,
only the generated local account-service copy explicitly loads the fixture CA;
TLS verification remains enabled and the system trust store is unchanged.
That test CA bootstrap is not exported into product templates. SMS, WeChat,
Alipay, GitHub and Google require real deployment credentials and were not tested
against live provider accounts. Services remain running for manual inspection.
