# Application Account System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Execute continuously; the user has authorized remaining design decisions, implementation, commits, PRs and merging.

**Goal:** Deliver phone/email OTP/password and multi-provider application accounts with persistent sessions and administrator-configured login channels.
**Architecture:** Focused account and accountconfig application packages in user-kitex, typed Account* RPCs, HTTP adapters in app/admin BFFs, and a management page in the user-selected admin frontend. PostgreSQL is the shared transactional authority for credentials, OTP state, sessions and configuration; existing operator authentication remains separate.
**Tech Stack:** Go, Kitex/protobuf, Hertz, pgx/PostgreSQL, JWT, provider HTTP protocols, SMTP, React/Ant Design/Umi/TypeScript.
**Spec:** docs/superpowers/specs/2026-10-22-application-account-system.md

## Global Constraints
- No username application entry; +86 only; six-digit codes, 5 minutes, 60-second resend, five bad attempts.
- 15-minute access tokens, 30-day sliding inactivity; no auto-merge; secret encryption and redaction; admin login unchanged.
- Preserve existing unrelated changes; user authorized both repositories, PRs and merge after verification.

## Review Focus
- Concurrent OTP callbacks must not create duplicate users or accept replay.
- Identity mutation must preserve a usable method, prevent stolen-session rebinding, and atomically revoke sessions.
- Disabling a method/config or changing environment/client must not bypass server authorization.
- Refresh/logout/revoke races must not resurrect sessions; unban must not revive sessions.
- SMTP/OAuth/SMS failure diagnostics must never expose credentials/codes; malicious callbacks cannot redirect or bind arbitrary accounts.

### Task 1: Configured provider and notification subsystem
Files: new user-kitex templates for internal/application/accountconfig/* and migration/schema portions owned by coordinator; existing oauth adapters only if needed.
Interfaces: exact Config/Manager API in spec. Coordinator supplies PostgreSQL migration and account service consumes methods.
- [x] Write meaningful failing encryption, masking, policy, SMTP, Aliyun/Tencent signing, OAuth fixture tests.
- [x] Implement real providers, configuration storage and gated enable/test operations.
- [x] Run package tests/build/vet and export actual Go into template YAML.
- [x] Review and integrate with caller.

### Task 2: Account persistence, identities, OTP and sessions
Files: new internal/application/account/* templates; user.proto typed Account* messages; migration/schema 000005; user service handler and server wiring; old self-service disable and existing admin session revocation.
Interfaces: uses accountconfig API. Produces typed Account* RPCs and persistent session verification.
- [x] Tests first: OTP flow, password non-registration, normalize/uniqueness, identity proofs and mutation, session expiration/rotation/revocation.
- [x] Implement transactional PostgreSQL storage with real-database integration fixtures, account service and RPC adapters.
- [x] Generate Kitex/sqlc, verify package tests/build/vet. Synchronize proto copies.

### Task 3: App and administrator HTTP adapters
Files: user-bff-hertz router/auth/OAuth/middleware templates and tests; admin-bff-hertz config handler/router/authz/routes tests and seeds.
Interfaces: typed Account* RPC contract (coordinator writes IDL before task starts). HTTP JSON contracts in spec.
- [x] Test route contracts and session-backed authorization; ensure no username/legacy fallback or arbitrary UID forwarding.
- [x] Implement login/code/refresh/me/security/OAuth endpoints and admin config APIs, RBAC and seed updates.
- [x] Render and run full generated build/vet/tests, then export templates.

### Task 4: Management frontend
Repository: user-selected ncgo-admin-web-template. Files: /system/auth config page, typed service/DTOs, routes/access/locales/tests and application-user admin fields as needed.
Interfaces: /api/v1/auth-configs DTO/route contract in spec. Admin operator login stays unchanged.
- [x] Add failing tests for endpoint contracts, masking/preserve-secret behavior and permission-dependent controls.
- [x] Implement accessible tabbed policy/OAuth/SMS/SMTP editor and tests, with write-only secrets and explicit test delivery.
- [x] Run repo-mandated Biome, tsc, test, build, browser security and UI verification.

### Task 5: Integration, review and delivery
- [x] Synchronize proto/client/seed/documentation and template versions, add reproducible account generation verification script.
- [x] Test generated user, app BFF, admin BFF and regressions; exercise PostgreSQL transaction cases using real local PostgreSQL when available.
- [x] Independent review and fixes, including OAuth alias handling, one-time hashed grants, replacement and concurrent unbind/login regression.
- [x] Commit focused changes in both repos.
- [ ] Create and attach PRs; merge only after checks pass. Synchronize local main and remove merged local feature branches when safe.

## Verification evidence

- Rendered user-kitex, user-bff-hertz and admin-bff-hertz: full build, vet and tests; PostgreSQL account/config/handler race suites and deterministic permission seed consistency. Reproducible via `scripts/test-application-accounts.sh` and the added PostgreSQL CI job.
- Frontend: Biome check, TypeScript, 101 tests across 11 files, production build and source/bundle browser-secret scan; desktop/mobile configuration editor exercised with fixtures.
- Independent backend and frontend review findings were fixed and re-reviewed. Real SMS/email/OAuth provider accounts require deployment credentials; live provider traffic was not exercised.
