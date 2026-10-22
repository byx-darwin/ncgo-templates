# user-kitex

Application accounts with mainland Chinese phone numbers, email and administrator-configured OAuth applications. The administrator's own RBAC login remains a separate service.

## Account behavior

- Phone/email verification-code login creates an account after verification if necessary. Password login only authenticates existing accounts. Username registration/login is disabled.
- A single UUID user pool is shared by all clients. Password is optional and shared by bound phone/email identities; nickname is display-only and may repeat. New users enter immediately without completing a profile.
- OAuth supports WeChat website/App/mini-program, Alipay website/App, GitHub, Google and OIDC. Each configured application is a separate identity namespace. First login registers automatically; contacts returned by providers are never silently bound and accounts are never merged.
- Binding requires recent proof of the current account and verification of the new identity; occupied identities are rejected. Replacing/unbinding is atomic, retains a usable login method, and revokes old sessions. A passwordless contact with only password login enabled is not a usable method.
- Initial password setup requires phone/email code reauthentication. Changing an existing password requires the old password; recovery verifies a bound contact, never creates an account and uses a non-enumerating response.
- Multiple device sessions are supported. Logout affects the current device. Password changes/reset, ban, administrator force logout and identity replacement/unbinding revoke all old sessions and pending OAuth grants. Unban does not revive old sessions.
- Access credentials default to 15 minutes. Persistent sessions expire after 30 days inactivity and slide on authenticated use. Refresh credentials rotate atomically and are hashed in storage. Every protected request verifies the persistent session; unavailable storage fails closed.
- OTPs are six digits, valid for five minutes; resend cooldown is 60 seconds and five bad attempts invalidate a code. Codes are HMAC-hashed and bound to purpose, client, contact and acting user where applicable. Subject/IP limits are persistent across replicas.

## Generate and initialize

```bash
ncgo new user --module github.com/acme/user --kind kitex \
  --template-dir /path/to/ncgo-templates/user-kitex --no-auto-steps
cd user
make sqlc
go mod tidy
go build ./...
make migrate-up DATABASE_URL='postgres://...'
```

Apply all migrations, including `000005_application_accounts.sql`, before starting the updated service. Existing generated projects must update the service/handler/repository sources, regenerate Kitex and sqlc, then apply migrations together. This is a new application account contract; old username and UID-only self-service RPCs explicitly reject calls. Old administrative RPCs remain, with transactional session revocation.

Set deployment secrets outside the management UI:

```bash
export ACCOUNT_ENVIRONMENT=production
export ACCOUNT_CONFIG_KEY="$(openssl rand -base64 32)"
export ACCOUNT_JWT_SECRET="$(openssl rand -hex 32)"
```

`ACCOUNT_CONFIG_KEY` must decode to exactly 32 bytes and must remain stable across restarts and replicas. It encrypts stored provider credentials using AES-GCM; changing it without a credential migration makes existing ciphertext unreadable. `ACCOUNT_JWT_SECRET` overrides `auth.jwt_secret`; use a private random value of at least 32 bytes. The shipped development signing placeholder is rejected in production. No credential is supplied by this repository.

PostgreSQL is mandatory for the new account operations. Redis is optional for this service's new account flow; the application BFF may still use Redis for shared rate limits/idempotency. OAuth callback state and one-minute exchange grants are in PostgreSQL. Callback results contain no access token, refresh token or reauthentication proof: those are created only when the hashed one-use grant is redeemed.

## Management configuration

Use the separate `admin-bff-hertz` with its `grpc.terminal_user` pointed at this service. The management frontend's `/system/auth` page calls:

- `GET /api/v1/auth-configs` → `{environment, configs}`; requires `auth-config:read`.
- `POST /api/v1/auth-configs` → redacted saved configuration; requires `auth-config:update`.
- `POST /api/v1/auth-configs/:id/test` with an explicit `{target}` → test delivery; requires `auth-config:test`.

Apply the updated deterministic permission seed (`cmd/permgen`) so the menu and action permissions exist. The environment is fixed by the server, not a public request or editable environment selector.

Configuration kinds are `method`, `oauth`, `sms` and `smtp`. Every enabled method/OAuth application requires an explicit client allowlist; an empty list allows no client. Methods are `phone_code`, `phone_password`, `email_code`, `email_password`. Code methods require one ready enabled SMS/SMTP transport. Password methods do not depend on delivery transport availability. Disabling a channel stops new login/binding while existing sessions continue, including ordinary renewal.

Credentials are write-only in the UI, encrypted in PostgreSQL and omitted from reads/public discovery/audits. Blank secret values preserve existing credentials. Display settings, availability and credentials can change without restarting. OAuth provider/client ID/mode/issuer and Alipay merchant PID cannot be changed under an existing configuration ID: create a new configuration for a different identity namespace. Secret rotation remains supported.

### Provider fields

| Kind/provider | Public settings | Write-only secrets |
|---|---|---|
| OAuth WeChat | `client_id`, `mode` (`web`, `app`, `miniprogram`), browser `redirect_url`, `return_urls`, optional `icon`/`scopes` | `client_secret` |
| OAuth Alipay | `client_id`, `mode` (`web`, `app`), native `pid`, browser `redirect_url`, `return_urls`, optional `icon`/`scopes` | RSA2 `private_key`, Alipay verification `public_key` (PEM) |
| OAuth GitHub/Google | `client_id`, `redirect_url`, `return_urls`, optional `icon`/`scopes` | `client_secret` |
| OAuth OIDC | Above plus HTTPS `issuer_url`; signature/issuer/audience/nonce are verified | `client_secret` |
| SMS Aliyun | `sign_name`, default `template_id`, optional `code_parameter` (default `code`) and `region` | `access_key_id`, `access_key_secret` |
| SMS Tencent | `sdk_app_id`, `sign_name`, default `template_id`, optional `region` (default `ap-guangzhou`) | `secret_id`, `secret_key` |
| SMTP | `host`, `port`, `tls_mode` (`tls`, `starttls`), `from`, optional `from_name`/`subject` | `username`, `password` |

`return_urls` is a JSON array encoded as a setting string. Use explicitly allowlisted HTTPS client links. Browser callbacks point to `/auth/oauth/<config-id>/callback`; Alipay's `auth_code` alias is accepted. Native SDKs request a bootstrap descriptor and POST the resulting code/state. WeChat native returns `app_id`/`state`; Alipay App also returns signed `auth_info`.

SMS supports `template_login`, `template_bind`, `template_replace`, `template_reauth`, `template_reset`. Configure all five or supply `template_id` as an explicit fallback. SMTP supports corresponding `subject_*` fields and a plain-text `body_template` containing `{code}`, with optional `{purpose}` and `{minutes}`. Live sends never print codes or credentials. Provider test sends are explicit audited administrator actions; test recipients accept domestic 11-digit or `+86` phone format.

Outbound provider HTTP endpoints are fixed; OIDC discovery and SMTP endpoints enforce TLS, DNS/IP and response-size constraints. Only local/development/test deployments may opt into private endpoints with `ACCOUNT_PROVIDER_ALLOW_PRIVATE_ENDPOINTS=1`; production cannot enable this override. These settings are for integration fixtures or private test mail servers.

## Deployment policy

Optional service-side environment overrides (clients cannot supply these):

| Variable | Default |
|---|---:|
| `ACCOUNT_ACCESS_TTL_SECONDS` | 900 |
| `ACCOUNT_SESSION_IDLE_DAYS` | 30 |
| `ACCOUNT_SEND_IP_HOURLY_LIMIT` | 20 |
| `ACCOUNT_SEND_SUBJECT_HOURLY_LIMIT` | 10 |
| `ACCOUNT_VERIFY_IP_QUARTER_HOUR_LIMIT` | 100 |
| `ACCOUNT_VERIFY_SUBJECT_QUARTER_HOUR_LIMIT` | 25 |

Expired session/code/state/grant/proof rows are rejected even before cleanup. Schedule routine deletion of expired rows and old `account_limits` windows according to your operational retention policy; keep account and audit retention separately defined.

## Verification

From this registry:

```bash
ACCOUNT_TEST_DSN='postgres://.../disposable_test_db?sslmode=disable' \
  bash scripts/test-application-accounts.sh
```

The script renders all three participants, regenerates RPC/sqlc/i18n sources, and runs build, vet, full tests and PostgreSQL race tests. Test cases create/drop isolated schemas in the supplied disposable database. Without a DSN, PostgreSQL integration tests explicitly skip. HTTP/TLS/SMTP fixtures verify real protocol signing and validation without sending live SMS/email or using real provider accounts. Production credentials and callback registration still require operator setup.
