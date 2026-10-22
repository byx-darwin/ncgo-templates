# Application account system

The user approved this design through the conversation and delegated all remaining choices to the recommended defaults, with explicit authorization to implement, commit, open PRs and merge after verification. No further design approval is required. Backend: ncgo-templates. Frontend: ncgo-admin-web-template. Admin operator authentication remains unchanged.

## Account rules
- One UUID user pool across all clients; no username registration/login. Nickname is display-only, nonunique, generated privately for phone/email registration; initial OAuth nickname/avatar are imported once.
- Mainland +86 phone and normalized email support OTP and account-level password login. Code login creates a user only after successful verification. Password login never creates a user.
- OAuth first login creates a user; identities are scoped to provider configuration instance, never auto-merged by names or email. Contact and OAuth identity conflicts are rejected.
- Password is optional; verified bound phone/email may establish/reset it. Existing password changes verify the old password. Password reset never creates an account and does not reveal whether one exists.
- Bind operations require recent proof of an existing account identity, plus target contact OTP or target OAuth authorization. Replace/unbind are atomic and retain at least one usable login identity. Password alone is not an identity.
- Binding retains sessions; changing password, reset, ban, admin force logout, identity replacement/unbind revoke all prior sessions. Logout revokes only the current session. Unban never revives old sessions.
- Access JWT lifetime 15 minutes, includes session ID/client. Sessions expire after 30 days inactivity; verified activity/refresh slides expiry. Refresh credentials are opaque, hashed at rest and rotated atomically. Every protected request verifies persistent session state; fail closed on unavailable storage.

## OTP and delivery
- 6 digits; 5-minute expiry; 60-second resend cooldown; latest code per subject/purpose/client only; atomically consumed once; 5 bad attempts invalidate the code. Purpose, target, acting user and client are bound. Send and verify limits apply by subject and IP, backed by shared PostgreSQL counters.
- Separate login, reauth, bind, replace and reset purposes. Initial password setup consumes a recent contact-code reauthentication proof. Unknown-account recovery produces the same public response as existing-account recovery.
- Real Aliyun and Tencent SMS adapters, selectable by administrator per environment; SMTP with TLS and timeouts. Runtime sends never log secrets, codes or reset credentials. Tests use local HTTP/SMTP fixtures, not live providers.

## Dynamic configuration
- Environment is server-controlled (ACCOUNT_ENVIRONMENT), never trusted from a public request. A stable client_id selects its login availability. Public availability is discovery only; every new login/code/OAuth operation rechecks configured allowance.
- Config kinds: method (phone_code/phone_password/email_code/email_password), oauth, sms, smtp. Multiple instances per OAuth platform, with client allowlists, display name/icon/order, enabled flag, public settings and private secrets.
- Built-in OAuth adapters: WeChat web/app/mini-program, Alipay, GitHub, Google, generic OIDC. Verify provider responses (including Alipay RSA2 and OIDC ID token signature/issuer/audience/nonce). Bind state to config/client/purpose/user and PKCE verifier; single-use callback state. Return URLs are explicitly allowlisted. Callback config IDs cannot override stored state.
- Config credentials encrypted using AES-GCM under a deployment-supplied base64 32-byte ACCOUNT_CONFIG_KEY. No default production key, no plaintext read/export. Omitted/empty secret updates preserve existing secrets; public/admin responses expose only has_secret. Secrets and encrypted blobs never enter audit detail.
- Code login methods require ready transports before enabling and discovery; password methods do not depend on a delivery transport. Enabled SMTP/SMS selection is unambiguous per environment. Configuration changes take effect without restart.
- Admin APIs provide list/save/test configs. Real test sends require explicit admin action and target. Admin JWT/RBAC gates auth-config:read/update/test; actions audited.
- Admin UI page offers login policy, OAuth applications, SMS, SMTP tabs and write-only secret editing. No application-user login UI is added to the administrator login page.

## Persistence and compatibility
- Extend existing users table with unique nonempty phone/email indexes and account state; preserve UUIDs and existing admin management consumers. Old username self-service RPCs return explicit unsupported errors; do not retain a username backdoor.
- Add migration/schema for configs, codes/rate limits, sessions, OAuth states and one-time grants. SQL repository operations enforce uniqueness and transactional writes. Persistent session revoker also wires existing admin ban/password reset/force logout.
- Existing old helper code may remain only for compatibility of admin/internal tests, not as reachable public self-service endpoints. New service methods live in focused account/config packages.
- UserService gains typed Account* RPCs alongside existing admin methods. Proto copies remain synchronized across user-kitex, user-bff-hertz, admin-bff-hertz and micro-admin where present. Bump all changed template package versions.

## HTTP endpoints
Application: GET /auth/methods; POST /auth/code; POST /auth/login (kind phone/email, mode code/password, identifier, credential); POST /auth/refresh; POST /auth/logout; GET/PATCH /auth/me; POST /auth/reauth; POST /auth/contact; POST /auth/password; POST /auth/password-reset/request|confirm; POST /auth/oauth/:config/start; POST /auth/oauth/:config/callback. OAuth login returns an expiring single-use exchange code; POST /auth/oauth/exchange redeems session tokens. Protected requests use bearer access tokens; identity-changing endpoints extract no user ID from request bodies.
Admin: GET/POST /api/v1/auth-configs; POST /api/v1/auth-configs/:id/test. Config DTO: id,kind,provider,name,environment,clients[],enabled,sort,settings(object),has_secret; writes add secret(object), omitted or empty retains existing value. Test DTO: target. Returns envelope consistent with existing APIs.

## Shared implementation contract
Generated Go module for working source is example.com/account-user. New package internal/application/accountconfig owns Config and Manager:
```
type Config struct { ID string `json:"id"`; Kind string `json:"kind"`; Provider string `json:"provider"`; Name string `json:"name"`; Environment string `json:"environment"`; Clients []string `json:"clients"`; Enabled bool `json:"enabled"`; Sort int `json:"sort"`; Settings map[string]string `json:"settings"`; Secret map[string]string `json:"secret,omitempty"`; HasSecret bool `json:"has_secret"` }
type Method struct { ID string `json:"id"`; Kind string `json:"kind"`; Provider string `json:"provider"`; Name string `json:"name"`; Icon string `json:"icon"`; Sort int `json:"sort"` }
type ExternalIdentity struct { Subject, Nickname, Avatar string }
func New(pool *pgxpool.Pool, environment string, encryptionKey []byte) *Manager
func (m *Manager) List(ctx context.Context) ([]Config,error) // redacted, environment-scoped
func (m *Manager) Save(ctx context.Context,c Config,actor string) (Config,error)
func (m *Manager) Test(ctx context.Context,id,target,actor string) error
func (m *Manager) Methods(ctx context.Context,client string) ([]Method,error)
func (m *Manager) Allowed(ctx context.Context,client,method string) error
func (m *Manager) Enabled(ctx context.Context,id,client string) (Config,error) // decrypted internal only, oauth config
func (m *Manager) SendCode(ctx context.Context,kind,to,purpose,code string) error
func (m *Manager) OAuthStart(ctx context.Context,cfg Config,state,nonce,challenge string) (string,error)
func (m *Manager) OAuthExchange(ctx context.Context,cfg Config,code,verifier,nonce string) (ExternalIdentity,error)
```
Table account_login_configs(id TEXT PRIMARY KEY,environment TEXT NOT NULL,kind TEXT NOT NULL,provider TEXT NOT NULL,name TEXT NOT NULL,clients JSONB NOT NULL,enabled BOOLEAN NOT NULL,sort INTEGER NOT NULL,settings JSONB NOT NULL,secret BYTEA,updated_at TIMESTAMPTZ NOT NULL DEFAULT now()). Audit uses existing audit_log schema or dedicated account_config_audit with only actor/action/config-id/time.

## Verification and integration
Tests must cover OTP anti-replay/wrong-purpose/brute force; concurrent auto-registration and identity uniqueness; atomic replacement/last-method preservation; session rotation/revocation/inactivity/ban; per-client/environment/config gate enforcement; encryption/redaction; signed HTTP/SMTP provider fixtures; OAuth signature/nonce/state/config binding; BFF identity extraction; admin RBAC; UI secret editing and request contracts. Render actual templates, regenerate Kitex/sqlc, build/vet/full test changed packages. Verify full frontend prescribed checks and browser interaction where available. Review all changes independently before PR and merge. Report external integration requiring real credentials honestly; do not claim live provider tests.

## Implementation rulings
- Disabling a login channel blocks new login/binding but preserves existing sessions, including normal refresh. Revocation is performed through logout/ban/password/identity operations, consistent with the approved retained-session rule.
- V1 client return URLs are HTTPS verified links; local HTTP is development-only. Native SDK bootstrap returns app_id/state and (for Alipay) signed auth_info; it does not invent a browser redirect.
- OAuth identity namespace fields (provider, client_id, mode, issuer_url and Alipay pid) are immutable after a configuration is created. Changes use a new application configuration; credential rotation remains supported.
- First password setup requires contact-code reauthentication, while identity binding/replacement may also use password or already-bound OAuth reauthentication.

- Final OAuth exchange contract: AccountOAuthComplete returns only a hashed-at-rest 60-second exchange grant for login/reauth; AccountExchange consumes it and returns either newly minted tokens or a new session-bound reauthentication proof. No plaintext session credentials are staged in Redis or PostgreSQL. Pending grants are revoked along with sessions during security operations.
- OAuth replace is a protected purpose: recent proof of an existing identity plus authorization of the target identity, atomic subject replacement with uniqueness checks, followed by full session revocation.
- Aliyun/Tencent SMS and SMTP support per-purpose templates/subjects, with an explicit default fallback. Admin SMS test targets normalize valid domestic input to +86 before strict validation.
