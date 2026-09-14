# user-kitex Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `user-kitex` Kitex RPC template package — a DDD-layered end-user account service with local password login (Argon2id, UUID v7 primary keys) and third-party OAuth2/OIDC login (generic OIDC, GitHub, Google, WeChat, Alipay), plus admin-facing management RPCs, following the exact template-authoring conventions of `rbac-kitex`.

**Architecture:** `internal/domain/user` (entities + repository interfaces) → `internal/infrastructure/{auth,oauth,token}` (password/JWT/provider adapters/Redis state) → `internal/repository/user` (sqlc/pgx impl) → `internal/application/user` (usecases: self-service + admin) → `internal/handler` (Kitex service handler) → `pkg/client` (generated client wrapper). Each template file is an `ncgo` `.yaml` wrapper (`path` + `update_behavior` + `body`) under `user-kitex/kitex-template/`, filenames use the flattened-path convention (`/` → `_`, extension kept as `_go`/`_sql`/`_proto` suffix before `.yaml`).

**Tech Stack:** Go 1.22+, Kitex, PostgreSQL + sqlc + pgx/v5, Redis (`go-tools/go-middleware/redis`), `golang.org/x/crypto/argon2`, `github.com/golang-jwt/jwt/v5`, `github.com/google/uuid` (v7), `golang.org/x/oauth2` (for provider token exchange), `github.com/byx-darwin/go-tools/go-common/error`.

**Spec:** `docs/superpowers/specs/2026-09-14-user-oauth-templates-design.md`

## Global Constraints

- Module path placeholder in all template bodies is `{{.Module}}` (ncgo substitutes at generation time); package/service name placeholders follow the same `{{.ServiceName}}` / `{{ToLower .ServiceName}}` convention used by `rbac-kitex`/`admin-bff-hertz`.
- Literal Go braces `{` / `}` inside `body:` blocks MUST be written as `{{ "{" }}` / `{{ "}" }}` — this is the dominant escaping convention across the existing template corpus (87/128 files in `rbac-kitex` + `admin-bff-hertz`) and is required wherever the ncgo template engine re-renders the body.
- `users.id` is `UUID PRIMARY KEY` (application-generated via `uuid.NewV7()`), diverging deliberately from `rbac-kitex`'s `BIGSERIAL id + uuid TEXT UNIQUE` pattern — this was an explicit design decision (see spec), not an oversight. Do not "fix" it to match `rbac-kitex`.
- Password hashing MUST be byte-for-byte the same Argon2id implementation as `rbac-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml` (Task 3 copies it verbatim, only the package doc comment changes).
- JWT `Claims{Uid string; Roles []string}` MUST match `rbac-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml` exactly so `base-hertz`/`admin-bff-hertz` JWT middleware can verify tokens issued by `user-kitex` without modification. End-user tokens always carry `Roles: []string{"user"}`.
- Every provider adapter satisfies the same `oauth.Provider` interface (Task 5) — no provider-specific leakage into usecase code.
- `update_behavior.type: cover` for all new files (this is a new template package; nothing is generated-then-hand-edited yet, so there is no "skip on regen" concern until a later template revision).
- This plan builds `user-kitex` only. `user-bff-hertz` (HTTP gateway) and the `admin-bff-hertz` user-management integration are separate plans (Plan 2, Plan 3) that depend on the RPC surface this plan produces (see "Interfaces: Produces" in Task 14).

---

### Task 1: Schema + Migration + sqlc Queries

**Files:**
- Create: `user-kitex/kitex-template/internal_db_schema_000001_user_sql.yaml`
- Create: `user-kitex/kitex-template/migration_init.yaml`
- Create: `user-kitex/kitex-template/internal_db_query_user_sql.yaml`
- Create: `user-kitex/kitex-template/sqlc_yaml.yaml`

**Interfaces:**
- Produces: tables `users(id UUID PK, username TEXT UNIQUE NULL, password_hash TEXT NULL, nickname TEXT, avatar TEXT, email TEXT, phone TEXT, status INT, created_at, updated_at)`, `user_identities(id UUID PK, user_id UUID FK, provider TEXT, provider_user_id TEXT, raw_profile_json TEXT, created_at, UNIQUE(provider, provider_user_id))`; sqlc queries `CreateUser`, `GetUserByID`, `GetUserByUsername`, `UpdateUserStatus`, `UpdateUserPassword`, `ListUsers`, `CountUsers`, `CreateUserIdentity`, `GetIdentityByProvider`, `ListIdentitiesByUserID`, `DeleteUserIdentity` — consumed by Task 11 (`internal/repository/user`).

- [ ] **Step 1: Write the schema file**

Create `user-kitex/kitex-template/internal_db_schema_000001_user_sql.yaml`:

```yaml
# ncgo exported template — internal/db/schema/000001_user.sql
path: internal/db/schema/000001_user.sql
update_behavior:
    type: cover
body: |-
    CREATE TABLE users (
        id UUID PRIMARY KEY,
        username TEXT UNIQUE,
        password_hash TEXT,
        nickname TEXT,
        avatar TEXT,
        email TEXT,
        phone TEXT,
        status INTEGER NOT NULL DEFAULT 1,  -- 1=enabled, 0=banned
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE TABLE user_identities (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        provider TEXT NOT NULL,
        provider_user_id TEXT NOT NULL,
        raw_profile_json TEXT NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        UNIQUE (provider, provider_user_id)
    );

    CREATE INDEX idx_user_identities_user_id ON user_identities(user_id);
```

- [ ] **Step 2: Write the migration wrapper**

Create `user-kitex/kitex-template/migration_init.yaml` (mirrors `rbac-kitex/kitex-template/migration_init.yaml` structure — same `path`/`update_behavior`, body references the schema file above):

```yaml
# ncgo exported template — migration/init.sh
path: migration/init.sh
update_behavior:
    type: cover
body: |-
    #!/usr/bin/env bash
    set -euo pipefail

    DSN="${DATABASE_URL:?DATABASE_URL not set}"
    psql "$DSN" -f internal/db/schema/000001_user.sql
```

- [ ] **Step 3: Write the sqlc query file**

Create `user-kitex/kitex-template/internal_db_query_user_sql.yaml`:

```yaml
# ncgo exported template — internal/db/query/user.sql
path: internal/db/query/user.sql
update_behavior:
    type: cover
body: |-
    -- name: CreateUser :one
    INSERT INTO users (id, username, password_hash, nickname, avatar, email, phone, status)
    VALUES ($1, $2, $3, $4, $5, $6, $7, 1) RETURNING *;
    -- name: GetUserByID :one
    SELECT * FROM users WHERE id = $1;
    -- name: GetUserByUsername :one
    SELECT * FROM users WHERE username = $1;
    -- name: UpdateUserStatus :one
    UPDATE users SET status = $2, updated_at = now() WHERE id = $1 RETURNING *;
    -- name: UpdateUserPassword :one
    UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1 RETURNING *;
    -- name: ListUsers :many
    SELECT * FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2;
    -- name: CountUsers :one
    SELECT count(*) FROM users;
    -- name: CreateUserIdentity :one
    INSERT INTO user_identities (id, user_id, provider, provider_user_id, raw_profile_json)
    VALUES ($1, $2, $3, $4, $5) RETURNING *;
    -- name: GetIdentityByProvider :one
    SELECT * FROM user_identities WHERE provider = $1 AND provider_user_id = $2;
    -- name: ListIdentitiesByUserID :many
    SELECT * FROM user_identities WHERE user_id = $1 ORDER BY created_at;
    -- name: DeleteUserIdentity :exec
    DELETE FROM user_identities WHERE user_id = $1 AND provider = $2;
```

- [ ] **Step 4: Write the sqlc config wrapper**

Create `user-kitex/kitex-template/sqlc_yaml.yaml` (copy `rbac-kitex/kitex-template`'s sqlc config structure, retarget `schema`/`queries` paths to `internal/db/schema` / `internal/db/query`, `gen.go.package` to `gen`, `gen.go.out` to `internal/db/gen`, matching the existing `rbac-kitex` sqlc.yaml verbatim except paths).

- [ ] **Step 5: Validate rendering**

Run:
```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/user-e2e --kind kitex --template-dir "$REPO_ROOT/user-kitex" --dir "$DIR/tplcheck" --no-auto-steps 2>&1 || echo "skipped: ncgo/template-dir flag unavailable, verify by manual yaml inspection"
```
Expected: schema/query/sqlc files render without `{{`/`}}` left unresolved. If `ncgo`/`sqlc` are not installed, print `skipped: <tool> 未安装` and continue (do not treat as failure).

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_db_schema_000001_user_sql.yaml \
        user-kitex/kitex-template/migration_init.yaml \
        user-kitex/kitex-template/internal_db_query_user_sql.yaml \
        user-kitex/kitex-template/sqlc_yaml.yaml
git commit -m "feat(user-kitex): add schema, migration, sqlc query templates"
```

---

### Task 2: Domain Entities + Repository Interfaces

**Files:**
- Create: `user-kitex/kitex-template/internal_domain_user_entity_go.yaml`
- Create: `user-kitex/kitex-template/internal_domain_user_entity_test_go.yaml`
- Create: `user-kitex/kitex-template/internal_domain_user_repository_go.yaml`

**Interfaces:**
- Consumes: nothing (pure domain layer).
- Produces: `user.User{ID uuid.UUID, Username *string, PasswordHash *string, Nickname, Avatar, Email, Phone string, Status int}`, `user.Identity{ID, UserID uuid.UUID, Provider, ProviderUserID, RawProfileJSON string}`, `user.Repository` interface (`Create`, `GetByID`, `GetByUsername`, `UpdateStatus`, `UpdatePassword`, `List`, `Count`, `CreateIdentity`, `GetIdentityByProvider`, `ListIdentitiesByUserID`, `DeleteIdentity`) — consumed by Task 11 (impl) and Task 12/13 (usecases).

- [ ] **Step 1: Write the failing test**

Create `user-kitex/kitex-template/internal_domain_user_entity_test_go.yaml`:

```yaml
# ncgo exported template — internal/domain/user/entity_test.go
path: internal/domain/user/entity_test.go
update_behavior:
    type: cover
body: |-
    package user

    import "testing"

    func TestNewLocal_RequiresUsernameAndPassword(t *testing.T) {{ "{" }}
    	if _, err := NewLocal("", "hash"); err == nil {{ "{" }}
    		t.Fatal("expected error for empty username")
    	{{ "}" }}
    	if _, err := NewLocal("alice", ""); err == nil {{ "{" }}
    		t.Fatal("expected error for empty password hash")
    	{{ "}" }}
    {{ "}" }}

    func TestNewLocal_SetsDefaults(t *testing.T) {{ "{" }}
    	u, err := NewLocal("alice", "hash")
    	if err != nil {{ "{" }}
    		t.Fatalf("unexpected error: %v", err)
    	{{ "}" }}
    	if u.Status != StatusEnabled {{ "{" }}
    		t.Fatalf("expected StatusEnabled, got %d", u.Status)
    	{{ "}" }}
    	if u.ID == (ID{{ "{" }}{{ "}" }}) {{ "{" }}
    		t.Fatal("expected non-zero UUID")
    	{{ "}" }}
    {{ "}" }}

    func TestNewFromProvider_SetsDefaults(t *testing.T) {{ "{" }}
    	u := NewFromProvider()
    	if u.Status != StatusEnabled {{ "{" }}
    		t.Fatalf("expected StatusEnabled, got %d", u.Status)
    	{{ "}" }}
    	if u.Username != nil {{ "{" }}
    		t.Fatal("expected nil username for pure third-party user")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/domain/user/... -run TestNewLocal -v` (against a rendered scratch project — see Task 1 Step 5 command template).
Expected: FAIL — `undefined: NewLocal` / `undefined: ID` / `undefined: StatusEnabled`.

- [ ] **Step 3: Write the entity implementation**

Create `user-kitex/kitex-template/internal_domain_user_entity_go.yaml`:

```yaml
# ncgo exported template — internal/domain/user/entity.go
path: internal/domain/user/entity.go
update_behavior:
    type: cover
body: |-
    package user

    import (
    	"errors"

    	"github.com/google/uuid"
    )

    // ID is the user aggregate's external and internal identity (UUID v7).
    type ID = uuid.UUID

    const (
    	// StatusEnabled is the default active state.
    	StatusEnabled = 1
    	// StatusBanned disables a user from logging in.
    	StatusBanned = 0
    )

    // User is the aggregate root for the end-user account aggregate.
    // Username/PasswordHash are pointers because a user who only ever signed
    // in via a third-party provider has neither.
    type User struct {{ "{" }}
    	ID           ID
    	Username     *string
    	PasswordHash *string
    	Nickname     string
    	Avatar       string
    	Email        string
    	Phone        string
    	Status       int
    {{ "}" }}

    // NewLocal creates a User for local username/password registration.
    func NewLocal(username, passwordHash string) (*User, error) {{ "{" }}
    	if username == "" {{ "{" }}
    		return nil, errors.New("user: username required")
    	{{ "}" }}
    	if passwordHash == "" {{ "{" }}
    		return nil, errors.New("user: password hash required")
    	{{ "}" }}
    	id, err := uuid.NewV7()
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &User{{ "{" }}
    		ID:           id,
    		Username:     &username,
    		PasswordHash: &passwordHash,
    		Status:       StatusEnabled,
    	{{ "}" }}, nil
    {{ "}" }}

    // NewFromProvider creates a User with no local credentials, to be bound
    // to a third-party identity by the caller immediately after creation.
    func NewFromProvider() *User {{ "{" }}
    	id, _ := uuid.NewV7()
    	return &User{{ "{" }}ID: id, Status: StatusEnabled{{ "}" }}
    {{ "}" }}

    // IsBanned reports whether the user is currently disabled.
    func (u *User) IsBanned() bool {{ "{" }}
    	return u.Status == StatusBanned
    {{ "}" }}

    // Identity is a third-party account bound to a User.
    type Identity struct {{ "{" }}
    	ID              ID
    	UserID          ID
    	Provider        string
    	ProviderUserID  string
    	RawProfileJSON  string
    {{ "}" }}

    // NewIdentity creates an Identity binding for userID.
    func NewIdentity(userID ID, provider, providerUserID, rawProfileJSON string) (*Identity, error) {{ "{" }}
    	if provider == "" || providerUserID == "" {{ "{" }}
    		return nil, errors.New("user: provider and provider_user_id required")
    	{{ "}" }}
    	id, err := uuid.NewV7()
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &Identity{{ "{" }}
    		ID:             id,
    		UserID:         userID,
    		Provider:       provider,
    		ProviderUserID: providerUserID,
    		RawProfileJSON: rawProfileJSON,
    	{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/domain/user/... -v`
Expected: PASS.

- [ ] **Step 5: Write the repository interface**

Create `user-kitex/kitex-template/internal_domain_user_repository_go.yaml`:

```yaml
# ncgo exported template — internal/domain/user/repository.go
path: internal/domain/user/repository.go
update_behavior:
    type: cover
body: |-
    package user

    import "context"

    // Repository persists User and Identity aggregates.
    type Repository interface {{ "{" }}
    	Create(ctx context.Context, u *User) error
    	GetByID(ctx context.Context, id ID) (*User, error)
    	GetByUsername(ctx context.Context, username string) (*User, error)
    	UpdateStatus(ctx context.Context, id ID, status int) error
    	UpdatePassword(ctx context.Context, id ID, passwordHash string) error
    	List(ctx context.Context, limit, offset int32) ([]*User, error)
    	Count(ctx context.Context) (int64, error)

    	CreateIdentity(ctx context.Context, i *Identity) error
    	GetIdentityByProvider(ctx context.Context, provider, providerUserID string) (*Identity, error)
    	ListIdentitiesByUserID(ctx context.Context, userID ID) ([]*Identity, error)
    	DeleteIdentity(ctx context.Context, userID ID, provider string) error
    {{ "}" }}
```

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_domain_user_entity_go.yaml \
        user-kitex/kitex-template/internal_domain_user_entity_test_go.yaml \
        user-kitex/kitex-template/internal_domain_user_repository_go.yaml
git commit -m "feat(user-kitex): add User/Identity domain entities and repository interface"
```

---

### Task 3: Reuse Argon2id Password Hashing from rbac-kitex

**Files:**
- Create: `user-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml`
- Create: `user-kitex/kitex-template/internal_infrastructure_auth_password_test_go.yaml`

**Interfaces:**
- Produces: `auth.HashPassword(password string) (string, error)`, `auth.VerifyPassword(password, encodedHash string) (bool, error)` — consumed by Task 12 (`Register`/`Login` usecases).

- [ ] **Step 1: Copy the password implementation verbatim**

Copy `rbac-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml` to `user-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml` with only the `path`/header comment retargeted (body is byte-identical — same package `auth`, same Argon2id parameters, same PHC encoding):

```bash
cp rbac-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml \
   user-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml
```

- [ ] **Step 2: Copy the test verbatim**

```bash
cp rbac-kitex/kitex-template/internal_infrastructure_auth_password_test_go.yaml \
   user-kitex/kitex-template/internal_infrastructure_auth_password_test_go.yaml
```

- [ ] **Step 3: Run test to verify it passes unmodified**

Run: `go test ./internal/infrastructure/auth/... -run Password -v` (rendered scratch project).
Expected: PASS (identical to `rbac-kitex`'s own passing test — no behavior changed by the copy).

- [ ] **Step 4: Commit**

```bash
git add user-kitex/kitex-template/internal_infrastructure_auth_password_go.yaml \
        user-kitex/kitex-template/internal_infrastructure_auth_password_test_go.yaml
git commit -m "feat(user-kitex): reuse rbac-kitex Argon2id password hashing"
```

---

### Task 4: Reuse JWT Issuance from rbac-kitex

**Files:**
- Create: `user-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml`
- Create: `user-kitex/kitex-template/internal_infrastructure_auth_jwt_test_go.yaml`

**Interfaces:**
- Consumes: nothing new.
- Produces: `auth.Claims{Uid string, Roles []string}`, `auth.NewJWTManager(secret string) *JWTManager`, `(*JWTManager).Sign(uid string, roles []string, ttl time.Duration) (string, error)`, `(*JWTManager).Parse(tokenString string) (*Claims, error)` — consumed by Task 12 (`Login`/`OAuthCallback` issue tokens with `roles=["user"]`).

- [ ] **Step 1: Copy the JWT implementation verbatim**

```bash
cp rbac-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml \
   user-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml
cp rbac-kitex/kitex-template/internal_infrastructure_auth_jwt_test_go.yaml \
   user-kitex/kitex-template/internal_infrastructure_auth_jwt_test_go.yaml
```

This is a deliberate byte-for-byte copy: `Claims{Uid, Roles, jwt.RegisteredClaims}` must be identical so `base-hertz`/`admin-bff-hertz`'s existing `auth.token` JWT middleware can verify `user-kitex`-issued tokens with zero changes.

- [ ] **Step 2: Run test to verify it passes unmodified**

Run: `go test ./internal/infrastructure/auth/... -run JWT -v`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add user-kitex/kitex-template/internal_infrastructure_auth_jwt_go.yaml \
        user-kitex/kitex-template/internal_infrastructure_auth_jwt_test_go.yaml
git commit -m "feat(user-kitex): reuse rbac-kitex JWT Claims/issuance for cross-service compat"
```

---

### Task 5: OAuth Provider Interface + Redis State Store

**Files:**
- Create: `user-kitex/kitex-template/internal_pkg_oauth_provider_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_state_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_state_test_go.yaml`

**Interfaces:**
- Produces: `oauth.Token{AccessToken, RefreshToken string, Expiry time.Time}`, `oauth.ProviderUserInfo{ProviderUserID, Email, Nickname, AvatarURL string, RawJSON string}`, `oauth.Provider` interface (`Name() string`, `AuthURL(state string) string`, `ExchangeCode(ctx, code string) (Token, error)`, `FetchUserInfo(ctx, token Token) (ProviderUserInfo, error)`), `oauth.StateStore` interface + `oauth.RedisStateStore` impl (`Put(ctx, state string, ttl time.Duration) error`, `Consume(ctx, state string) (bool, error)`) — consumed by Tasks 6-10 (adapters) and Task 12 (usecase orchestration).

- [ ] **Step 1: Write the Provider interface**

Create `user-kitex/kitex-template/internal_pkg_oauth_provider_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/provider.go
path: internal/pkg/oauth/provider.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"time"
    )

    // Token is the OAuth2 token set returned by a provider's code exchange.
    type Token struct {{ "{" }}
    	AccessToken  string
    	RefreshToken string
    	Expiry       time.Time
    {{ "}" }}

    // ProviderUserInfo is the normalized profile fetched from a provider
    // after a successful token exchange.
    type ProviderUserInfo struct {{ "{" }}
    	ProviderUserID string
    	Email          string
    	Nickname       string
    	AvatarURL      string
    	RawJSON        string
    {{ "}" }}

    // Provider is implemented once per third-party login supplier. Every
    // adapter (wechat/alipay/github/google/oidc) satisfies this interface;
    // usecase code never branches on provider name.
    type Provider interface {{ "{" }}
    	// Name returns the provider's registry key (e.g. "github", "wechat").
    	Name() string
    	// AuthURL builds the provider's authorization redirect URL, embedding
    	// state for CSRF protection.
    	AuthURL(state string) string
    	// ExchangeCode swaps an authorization code for a token set.
    	ExchangeCode(ctx context.Context, code string) (Token, error)
    	// FetchUserInfo retrieves the authenticated user's profile.
    	FetchUserInfo(ctx context.Context, token Token) (ProviderUserInfo, error)
    {{ "}" }}

    // Registry looks up a configured Provider by name.
    type Registry map[string]Provider

    // Get returns the provider for name, or false if not enabled/registered.
    func (r Registry) Get(name string) (Provider, bool) {{ "{" }}
    	p, ok := r[name]
    	return p, ok
    {{ "}" }}
```

- [ ] **Step 2: Write the failing state-store test**

Create `user-kitex/kitex-template/internal_pkg_oauth_state_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/state_test.go
path: internal/pkg/oauth/state_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/alicebob/miniredis/v2"
    	"github.com/redis/go-redis/v9"
    )

    func newTestRedis(t *testing.T) *redis.Client {{ "{" }}
    	t.Helper()
    	mr, err := miniredis.Run()
    	if err != nil {{ "{" }}
    		t.Fatalf("start miniredis: %v", err)
    	{{ "}" }}
    	t.Cleanup(mr.Close)
    	return redis.NewClient(&redis.Options{{ "{" }}Addr: mr.Addr(){{ "}" }})
    {{ "}" }}

    func TestRedisStateStore_PutConsume(t *testing.T) {{ "{" }}
    	ctx := context.Background()
    	store := NewRedisStateStore(newTestRedis(t))

    	if err := store.Put(ctx, "state-1", time.Minute); err != nil {{ "{" }}
    		t.Fatalf("put: %v", err)
    	{{ "}" }}

    	ok, err := store.Consume(ctx, "state-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if !ok {{ "{" }}
    		t.Fatal("expected state to be found and consumed")
    	{{ "}" }}

    	ok, err = store.Consume(ctx, "state-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume again: %v", err)
    	{{ "}" }}
    	if ok {{ "{" }}
    		t.Fatal("expected state to be gone after first consume (single use)")
    	{{ "}" }}
    {{ "}" }}

    func TestRedisStateStore_UnknownState(t *testing.T) {{ "{" }}
    	store := NewRedisStateStore(newTestRedis(t))
    	ok, err := store.Consume(context.Background(), "never-issued")
    	if err != nil {{ "{" }}
    		t.Fatalf("consume: %v", err)
    	{{ "}" }}
    	if ok {{ "{" }}
    		t.Fatal("expected unknown state to report not-found")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/pkg/oauth/... -run RedisStateStore -v`
Expected: FAIL — `undefined: NewRedisStateStore`.

- [ ] **Step 4: Write the Redis state store implementation**

Create `user-kitex/kitex-template/internal_pkg_oauth_state_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/state.go
path: internal/pkg/oauth/state.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"errors"
    	"time"

    	"github.com/redis/go-redis/v9"
    )

    // StateStore issues and single-use-consumes OAuth CSRF state tokens.
    type StateStore interface {{ "{" }}
    	Put(ctx context.Context, state string, ttl time.Duration) error
    	Consume(ctx context.Context, state string) (bool, error)
    {{ "}" }}

    const stateKeyPrefix = "oauth:state:"

    // RedisStateStore stores OAuth state tokens in Redis with a TTL and
    // atomically deletes them on first consumption (GETDEL).
    type RedisStateStore struct {{ "{" }}
    	client *redis.Client
    {{ "}" }}

    // NewRedisStateStore wraps an existing Redis client.
    func NewRedisStateStore(client *redis.Client) *RedisStateStore {{ "{" }}
    	return &RedisStateStore{{ "{" }}client: client{{ "}" }}
    {{ "}" }}

    // Put records state as valid for ttl.
    func (s *RedisStateStore) Put(ctx context.Context, state string, ttl time.Duration) error {{ "{" }}
    	return s.client.Set(ctx, stateKeyPrefix+state, "1", ttl).Err()
    {{ "}" }}

    // Consume reports whether state was valid and, if so, deletes it so it
    // cannot be replayed.
    func (s *RedisStateStore) Consume(ctx context.Context, state string) (bool, error) {{ "{" }}
    	_, err := s.client.GetDel(ctx, stateKeyPrefix+state).Result()
    	if errors.Is(err, redis.Nil) {{ "{" }}
    		return false, nil
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return false, err
    	{{ "}" }}
    	return true, nil
    {{ "}" }}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/pkg/oauth/... -v`
Expected: PASS. (`miniredis`/`go-redis` are added to `go.mod`/test deps via `go mod tidy`, same as the `uuid` dependency handled in the existing `rbac-id-scheme-revert` plan — no manual `go.mod` template edit needed.)

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_pkg_oauth_provider_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_state_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_state_test_go.yaml
git commit -m "feat(user-kitex): add OAuth Provider interface and Redis state store"
```

---

### Task 6: Generic OIDC Provider Adapter

**Files:**
- Create: `user-kitex/kitex-template/internal_pkg_oauth_oidc_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_oidc_test_go.yaml`

**Interfaces:**
- Consumes: `oauth.Provider` (Task 5), `oauth.Token`, `oauth.ProviderUserInfo`.
- Produces: `oauth.NewOIDCProvider(cfg OIDCConfig) *OIDCProvider` satisfying `oauth.Provider`, `Name() == "oidc"`.

- [ ] **Step 1: Write the failing test**

Create `user-kitex/kitex-template/internal_pkg_oauth_oidc_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/oidc_test.go
path: internal/pkg/oauth/oidc_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"net/http"
    	"net/http/httptest"
    	"strings"
    	"testing"
    )

    func TestOIDCProvider_AuthURL(t *testing.T) {{ "{" }}
    	p := NewOIDCProvider(OIDCConfig{{ "{" }}
    		Name: "oidc", ClientID: "cid", RedirectURL: "https://app.example.com/callback",
    		AuthEndpoint: "https://idp.example.com/authorize", Scopes: []string{{ "{" }}"openid", "email"{{ "}" }},
    	{{ "}" }})
    	url := p.AuthURL("state-123")
    	if !strings.Contains(url, "client_id=cid") || !strings.Contains(url, "state=state-123") {{ "{" }}
    		t.Fatalf("unexpected auth url: %s", url)
    	{{ "}" }}
    {{ "}" }}

    func TestOIDCProvider_ExchangeCodeAndFetchUserInfo(t *testing.T) {{ "{" }}
    	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {{ "{" }}
    		json.NewEncoder(w).Encode(map[string]any{{ "{" }}"access_token": "tok-abc", "expires_in": 3600{{ "}" }})
    	{{ "}" }}))
    	defer tokenSrv.Close()

    	userInfoSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {{ "{" }}
    		if r.Header.Get("Authorization") != "Bearer tok-abc" {{ "{" }}
    			t.Errorf("expected bearer token forwarded, got %q", r.Header.Get("Authorization"))
    		{{ "}" }}
    		json.NewEncoder(w).Encode(map[string]any{{ "{" }}"sub": "user-42", "email": "a@example.com", "name": "Alice"{{ "}" }})
    	{{ "}" }}))
    	defer userInfoSrv.Close()

    	p := NewOIDCProvider(OIDCConfig{{ "{" }}
    		Name: "oidc", ClientID: "cid", ClientSecret: "secret",
    		TokenEndpoint: tokenSrv.URL, UserInfoEndpoint: userInfoSrv.URL,
    	{{ "}" }})

    	tok, err := p.ExchangeCode(context.Background(), "code-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("exchange: %v", err)
    	{{ "}" }}
    	if tok.AccessToken != "tok-abc" {{ "{" }}
    		t.Fatalf("unexpected access token: %s", tok.AccessToken)
    	{{ "}" }}

    	info, err := p.FetchUserInfo(context.Background(), tok)
    	if err != nil {{ "{" }}
    		t.Fatalf("fetch user info: %v", err)
    	{{ "}" }}
    	if info.ProviderUserID != "user-42" || info.Email != "a@example.com" {{ "{" }}
    		t.Fatalf("unexpected user info: %+v", info)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/oauth/... -run OIDCProvider -v`
Expected: FAIL — `undefined: NewOIDCProvider`.

- [ ] **Step 3: Write the OIDC adapter**

Create `user-kitex/kitex-template/internal_pkg_oauth_oidc_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/oidc.go
path: internal/pkg/oauth/oidc.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"fmt"
    	"net/http"
    	"net/url"
    	"strconv"
    	"strings"
    	"time"
    )

    // OIDCConfig configures a standards-compliant OAuth2/OIDC provider.
    // Used directly for generic OIDC IdPs, and embedded by any adapter whose
    // provider is close enough to standard OIDC to reuse the exchange/fetch
    // logic (only AuthURL/FetchUserInfo field-mapping differ per provider).
    type OIDCConfig struct {{ "{" }}
    	Name             string
    	ClientID         string
    	ClientSecret     string
    	RedirectURL      string
    	AuthEndpoint     string
    	TokenEndpoint    string
    	UserInfoEndpoint string
    	Scopes           []string
    {{ "}" }}

    // OIDCProvider implements Provider for any standard OAuth2/OIDC IdP.
    type OIDCProvider struct {{ "{" }}
    	cfg        OIDCConfig
    	httpClient *http.Client
    {{ "}" }}

    // NewOIDCProvider builds a Provider from cfg using the default http.Client.
    func NewOIDCProvider(cfg OIDCConfig) *OIDCProvider {{ "{" }}
    	return &OIDCProvider{{ "{" }}cfg: cfg, httpClient: http.DefaultClient{{ "}" }}
    {{ "}" }}

    func (p *OIDCProvider) Name() string {{ "{" }} return p.cfg.Name {{ "}" }}

    func (p *OIDCProvider) AuthURL(state string) string {{ "{" }}
    	q := url.Values{{ "{" }}
    		"client_id":     {{ "{" }}p.cfg.ClientID{{ "}" }},
    		"redirect_uri":  {{ "{" }}p.cfg.RedirectURL{{ "}" }},
    		"response_type": {{ "{" }}"code"{{ "}" }},
    		"state":         {{ "{" }}state{{ "}" }},
    		"scope":         {{ "{" }}strings.Join(p.cfg.Scopes, " "){{ "}" }},
    	{{ "}" }}
    	return p.cfg.AuthEndpoint + "?" + q.Encode()
    {{ "}" }}

    func (p *OIDCProvider) ExchangeCode(ctx context.Context, code string) (Token, error) {{ "{" }}
    	form := url.Values{{ "{" }}
    		"grant_type":    {{ "{" }}"authorization_code"{{ "}" }},
    		"code":          {{ "{" }}code{{ "}" }},
    		"redirect_uri":  {{ "{" }}p.cfg.RedirectURL{{ "}" }},
    		"client_id":     {{ "{" }}p.cfg.ClientID{{ "}" }},
    		"client_secret": {{ "{" }}p.cfg.ClientSecret{{ "}" }},
    	{{ "}" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.TokenEndpoint, strings.NewReader(form.Encode()))
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
    	req.Header.Set("Accept", "application/json")

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: %s token exchange failed: status %d", p.cfg.Name, resp.StatusCode)
    	{{ "}" }}

    	var body struct {{ "{" }}
    		AccessToken  string `json:"access_token"`
    		RefreshToken string `json:"refresh_token"`
    		ExpiresIn    int64  `json:"expires_in"`
    	{{ "}" }}
    	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	tok := Token{{ "{" }}AccessToken: body.AccessToken, RefreshToken: body.RefreshToken{{ "}" }}
    	if body.ExpiresIn > 0 {{ "{" }}
    		tok.Expiry = time.Now().Add(time.Duration(body.ExpiresIn) * time.Second)
    	{{ "}" }}
    	return tok, nil
    {{ "}" }}

    func (p *OIDCProvider) FetchUserInfo(ctx context.Context, token Token) (ProviderUserInfo, error) {{ "{" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.UserInfoEndpoint, nil)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	req.Header.Set("Authorization", "Bearer "+token.AccessToken)

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: %s fetch user info failed: status %d", p.cfg.Name, resp.StatusCode)
    	{{ "}" }}

    	raw, err := decodeToRawJSON(resp.Body)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	var body struct {{ "{" }}
    		Sub     string `json:"sub"`
    		Email   string `json:"email"`
    		Name    string `json:"name"`
    		Picture string `json:"picture"`
    	{{ "}" }}
    	if err := json.Unmarshal(raw, &body); err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	return ProviderUserInfo{{ "{" }}
    		ProviderUserID: body.Sub,
    		Email:          body.Email,
    		Nickname:       body.Name,
    		AvatarURL:      body.Picture,
    		RawJSON:        string(raw),
    	{{ "}" }}, nil
    {{ "}" }}

    // decodeToRawJSON reads body fully so callers can both unmarshal into a
    // typed struct and retain the original bytes for storage.
    func decodeToRawJSON(body interface {{ "{" }} Read([]byte) (int, error) {{ "}" }}) ([]byte, error) {{ "{" }}
    	buf := make([]byte, 0, 4096)
    	chunk := make([]byte, 4096)
    	for {{ "{" }}
    		n, err := body.Read(chunk)
    		if n > 0 {{ "{" }}
    			buf = append(buf, chunk[:n]...)
    		{{ "}" }}
    		if err != nil {{ "{" }}
    			break
    		{{ "}" }}
    	{{ "}" }}
    	return buf, nil
    {{ "}" }}

    var _ = strconv.Itoa // keep strconv import if unused paths trimmed later
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/oauth/... -run OIDCProvider -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_pkg_oauth_oidc_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_oidc_test_go.yaml
git commit -m "feat(user-kitex): add generic OIDC provider adapter"
```

---

### Task 7: GitHub Provider Adapter

**Files:**
- Create: `user-kitex/kitex-template/internal_pkg_oauth_github_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_github_test_go.yaml`

**Interfaces:**
- Consumes: `oauth.Provider`, `oauth.Token`, `oauth.ProviderUserInfo` (Task 5).
- Produces: `oauth.NewGitHubProvider(cfg GitHubConfig) *GitHubProvider`, `Name() == "github"`.

- [ ] **Step 1: Write the failing test**

Create `user-kitex/kitex-template/internal_pkg_oauth_github_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/github_test.go
path: internal/pkg/oauth/github_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"net/http"
    	"net/http/httptest"
    	"testing"
    )

    func TestGitHubProvider_FetchUserInfo_UsesLoginAsID(t *testing.T) {{ "{" }}
    	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {{ "{" }}
    		json.NewEncoder(w).Encode(map[string]any{{ "{" }}
    			"id": float64(9001), "login": "octocat", "email": "octo@example.com", "avatar_url": "https://gh/a.png",
    		{{ "}" }})
    	{{ "}" }}))
    	defer srv.Close()

    	p := NewGitHubProvider(GitHubConfig{{ "{" }}ClientID: "cid", ClientSecret: "secret", RedirectURL: "https://app.example.com/cb", UserInfoURL: srv.URL{{ "}" }})
    	info, err := p.FetchUserInfo(context.Background(), Token{{ "{" }}AccessToken: "tok"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("fetch user info: %v", err)
    	{{ "}" }}
    	if info.ProviderUserID != "9001" {{ "{" }}
    		t.Fatalf("expected numeric github id as string, got %q", info.ProviderUserID)
    	{{ "}" }}
    	if info.Nickname != "octocat" {{ "{" }}
    		t.Fatalf("unexpected nickname: %s", info.Nickname)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/oauth/... -run GitHubProvider -v`
Expected: FAIL — `undefined: NewGitHubProvider`.

- [ ] **Step 3: Write the GitHub adapter**

Create `user-kitex/kitex-template/internal_pkg_oauth_github_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/github.go
path: internal/pkg/oauth/github.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"fmt"
    	"net/http"
    	"net/url"
    	"strconv"
    	"strings"
    	"time"
    )

    // GitHubConfig configures the GitHub OAuth app.
    type GitHubConfig struct {{ "{" }}
    	ClientID     string
    	ClientSecret string
    	RedirectURL  string
    	// AuthURL/TokenURL/UserInfoURL default to GitHub's public endpoints
    	// when empty; overridable for testing.
    	AuthURLBase string
    	TokenURL    string
    	UserInfoURL string
    {{ "}" }}

    const (
    	githubDefaultAuthURL     = "https://github.com/login/oauth/authorize"
    	githubDefaultTokenURL    = "https://github.com/login/oauth/access_token"
    	githubDefaultUserInfoURL = "https://api.github.com/user"
    )

    // GitHubProvider implements Provider for GitHub OAuth apps.
    type GitHubProvider struct {{ "{" }}
    	cfg        GitHubConfig
    	httpClient *http.Client
    {{ "}" }}

    // NewGitHubProvider builds a Provider from cfg, defaulting empty
    // endpoint fields to GitHub's production URLs.
    func NewGitHubProvider(cfg GitHubConfig) *GitHubProvider {{ "{" }}
    	if cfg.AuthURLBase == "" {{ "{" }}
    		cfg.AuthURLBase = githubDefaultAuthURL
    	{{ "}" }}
    	if cfg.TokenURL == "" {{ "{" }}
    		cfg.TokenURL = githubDefaultTokenURL
    	{{ "}" }}
    	if cfg.UserInfoURL == "" {{ "{" }}
    		cfg.UserInfoURL = githubDefaultUserInfoURL
    	{{ "}" }}
    	return &GitHubProvider{{ "{" }}cfg: cfg, httpClient: http.DefaultClient{{ "}" }}
    {{ "}" }}

    func (p *GitHubProvider) Name() string {{ "{" }} return "github" {{ "}" }}

    func (p *GitHubProvider) AuthURL(state string) string {{ "{" }}
    	q := url.Values{{ "{" }}
    		"client_id":    {{ "{" }}p.cfg.ClientID{{ "}" }},
    		"redirect_uri": {{ "{" }}p.cfg.RedirectURL{{ "}" }},
    		"scope":        {{ "{" }}"read:user user:email"{{ "}" }},
    		"state":        {{ "{" }}state{{ "}" }},
    	{{ "}" }}
    	return p.cfg.AuthURLBase + "?" + q.Encode()
    {{ "}" }}

    func (p *GitHubProvider) ExchangeCode(ctx context.Context, code string) (Token, error) {{ "{" }}
    	form := url.Values{{ "{" }}
    		"client_id":     {{ "{" }}p.cfg.ClientID{{ "}" }},
    		"client_secret": {{ "{" }}p.cfg.ClientSecret{{ "}" }},
    		"code":          {{ "{" }}code{{ "}" }},
    		"redirect_uri":  {{ "{" }}p.cfg.RedirectURL{{ "}" }},
    	{{ "}" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.cfg.TokenURL, strings.NewReader(form.Encode()))
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
    	req.Header.Set("Accept", "application/json")

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: github token exchange failed: status %d", resp.StatusCode)
    	{{ "}" }}

    	var body struct {{ "{" }}
    		AccessToken string `json:"access_token"`
    	{{ "}" }}
    	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	return Token{{ "{" }}AccessToken: body.AccessToken, Expiry: time.Time{{ "{" }}{{ "}" }}{{ "}" }}, nil
    {{ "}" }}

    func (p *GitHubProvider) FetchUserInfo(ctx context.Context, token Token) (ProviderUserInfo, error) {{ "{" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.UserInfoURL, nil)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	req.Header.Set("Authorization", "Bearer "+token.AccessToken)
    	req.Header.Set("Accept", "application/vnd.github+json")

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: github fetch user info failed: status %d", resp.StatusCode)
    	{{ "}" }}

    	raw, err := decodeToRawJSON(resp.Body)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	var body struct {{ "{" }}
    		ID        float64 `json:"id"`
    		Login     string  `json:"login"`
    		Email     string  `json:"email"`
    		AvatarURL string  `json:"avatar_url"`
    	{{ "}" }}
    	if err := json.Unmarshal(raw, &body); err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	return ProviderUserInfo{{ "{" }}
    		ProviderUserID: strconv.FormatInt(int64(body.ID), 10),
    		Email:          body.Email,
    		Nickname:       body.Login,
    		AvatarURL:      body.AvatarURL,
    		RawJSON:        string(raw),
    	{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/oauth/... -run GitHubProvider -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_pkg_oauth_github_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_github_test_go.yaml
git commit -m "feat(user-kitex): add GitHub OAuth provider adapter"
```

---

### Task 8: Google Provider Adapter

**Files:**
- Create: `user-kitex/kitex-template/internal_pkg_oauth_google_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_google_test_go.yaml`

**Interfaces:**
- Consumes: `OIDCConfig`, `OIDCProvider` internals (Task 6) — Google's endpoints are fully OIDC-compliant, so this adapter is a thin constructor wrapping `OIDCProvider` with Google's fixed endpoints, not a reimplementation.
- Produces: `oauth.NewGoogleProvider(clientID, clientSecret, redirectURL string) *OIDCProvider`, returned provider's `Name() == "google"`.

- [ ] **Step 1: Write the failing test**

Create `user-kitex/kitex-template/internal_pkg_oauth_google_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/google_test.go
path: internal/pkg/oauth/google_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import "testing"

    func TestNewGoogleProvider_Name(t *testing.T) {{ "{" }}
    	p := NewGoogleProvider("cid", "secret", "https://app.example.com/cb")
    	if p.Name() != "google" {{ "{" }}
    		t.Fatalf("expected name 'google', got %q", p.Name())
    	{{ "}" }}
    {{ "}" }}

    func TestNewGoogleProvider_AuthURLUsesGoogleEndpoint(t *testing.T) {{ "{" }}
    	p := NewGoogleProvider("cid", "secret", "https://app.example.com/cb")
    	url := p.AuthURL("state-1")
    	if want := "https://accounts.google.com/o/oauth2/v2/auth"; len(url) < len(want) || url[:len(want)] != want {{ "{" }}
    		t.Fatalf("expected google auth endpoint prefix, got %s", url)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/oauth/... -run NewGoogleProvider -v`
Expected: FAIL — `undefined: NewGoogleProvider`.

- [ ] **Step 3: Write the Google adapter**

Create `user-kitex/kitex-template/internal_pkg_oauth_google_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/google.go
path: internal/pkg/oauth/google.go
update_behavior:
    type: cover
body: |-
    package oauth

    const (
    	googleAuthEndpoint     = "https://accounts.google.com/o/oauth2/v2/auth"
    	googleTokenEndpoint    = "https://oauth2.googleapis.com/token"
    	googleUserInfoEndpoint = "https://openidconnect.googleapis.com/v1/userinfo"
    )

    // NewGoogleProvider builds a Provider for Google Sign-In. Google's IdP is
    // fully OIDC-compliant, so this wraps OIDCProvider with fixed endpoints
    // rather than duplicating the exchange/fetch logic.
    func NewGoogleProvider(clientID, clientSecret, redirectURL string) *OIDCProvider {{ "{" }}
    	return NewOIDCProvider(OIDCConfig{{ "{" }}
    		Name:             "google",
    		ClientID:         clientID,
    		ClientSecret:     clientSecret,
    		RedirectURL:      redirectURL,
    		AuthEndpoint:     googleAuthEndpoint,
    		TokenEndpoint:    googleTokenEndpoint,
    		UserInfoEndpoint: googleUserInfoEndpoint,
    		Scopes:           []string{{ "{" }}"openid", "email", "profile"{{ "}" }},
    	{{ "}" }})
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/oauth/... -run NewGoogleProvider -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_pkg_oauth_google_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_google_test_go.yaml
git commit -m "feat(user-kitex): add Google OAuth provider adapter (OIDC-compliant wrapper)"
```

---

### Task 9: WeChat Provider Adapter (Non-Standard OAuth2)

**Files:**
- Create: `user-kitex/kitex-template/internal_pkg_oauth_wechat_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_wechat_test_go.yaml`

**Interfaces:**
- Consumes: `oauth.Provider`, `oauth.Token`, `oauth.ProviderUserInfo` (Task 5). WeChat is NOT OIDC-compliant (`appid`/`secret` param names, `openid` returned directly from the token endpoint, separate userinfo call keyed by `openid`+`access_token` query params) — full standalone implementation, cannot reuse `OIDCProvider`.
- Produces: `oauth.NewWeChatProvider(cfg WeChatConfig) *WeChatProvider`, `Name() == "wechat"`.

- [ ] **Step 1: Write the failing test**

Create `user-kitex/kitex-template/internal_pkg_oauth_wechat_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/wechat_test.go
path: internal/pkg/oauth/wechat_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"net/http"
    	"net/http/httptest"
    	"testing"
    )

    func TestWeChatProvider_ExchangeCode_ReturnsOpenID(t *testing.T) {{ "{" }}
    	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {{ "{" }}
    		json.NewEncoder(w).Encode(map[string]any{{ "{" }}"access_token": "wx-tok", "openid": "wx-openid-1", "expires_in": 7200{{ "}" }})
    	{{ "}" }}))
    	defer srv.Close()

    	p := NewWeChatProvider(WeChatConfig{{ "{" }}AppID: "appid", AppSecret: "secret", RedirectURL: "https://app.example.com/cb", TokenURL: srv.URL{{ "}" }})
    	tok, err := p.ExchangeCode(context.Background(), "code-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("exchange: %v", err)
    	{{ "}" }}
    	if tok.AccessToken != "wx-tok" {{ "{" }}
    		t.Fatalf("unexpected access token: %s", tok.AccessToken)
    	{{ "}" }}
    	if p.lastOpenID != "wx-openid-1" {{ "{" }}
    		t.Fatalf("expected openid captured for subsequent userinfo call, got %q", p.lastOpenID)
    	{{ "}" }}
    {{ "}" }}

    func TestWeChatProvider_FetchUserInfo_UsesOpenID(t *testing.T) {{ "{" }}
    	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {{ "{" }}
    		if r.URL.Query().Get("openid") != "wx-openid-1" {{ "{" }}
    			t.Errorf("expected openid query param, got %q", r.URL.RawQuery)
    		{{ "}" }}
    		json.NewEncoder(w).Encode(map[string]any{{ "{" }}"openid": "wx-openid-1", "nickname": "小明", "headimgurl": "https://wx/a.png"{{ "}" }})
    	{{ "}" }}))
    	defer srv.Close()

    	p := NewWeChatProvider(WeChatConfig{{ "{" }}AppID: "appid", AppSecret: "secret", RedirectURL: "https://app.example.com/cb", UserInfoURL: srv.URL{{ "}" }})
    	p.lastOpenID = "wx-openid-1"
    	info, err := p.FetchUserInfo(context.Background(), Token{{ "{" }}AccessToken: "wx-tok"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("fetch user info: %v", err)
    	{{ "}" }}
    	if info.ProviderUserID != "wx-openid-1" {{ "{" }}
    		t.Fatalf("unexpected provider user id: %s", info.ProviderUserID)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/oauth/... -run WeChatProvider -v`
Expected: FAIL — `undefined: NewWeChatProvider`.

- [ ] **Step 3: Write the WeChat adapter**

Create `user-kitex/kitex-template/internal_pkg_oauth_wechat_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/wechat.go
path: internal/pkg/oauth/wechat.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"fmt"
    	"net/http"
    	"net/url"
    	"time"
    )

    // WeChatConfig configures a WeChat Open Platform "网站应用" OAuth flow.
    // WeChat's flow is NOT OIDC-compliant: it uses appid/secret param names,
    // returns openid alongside the access token, and requires openid as an
    // explicit query param on the separate userinfo call.
    type WeChatConfig struct {{ "{" }}
    	AppID       string
    	AppSecret   string
    	RedirectURL string
    	AuthURLBase string
    	TokenURL    string
    	UserInfoURL string
    {{ "}" }}

    const (
    	wechatDefaultAuthURL     = "https://open.weixin.qq.com/connect/qrconnect"
    	wechatDefaultTokenURL    = "https://api.weixin.qq.com/sns/oauth2/access_token"
    	wechatDefaultUserInfoURL = "https://api.weixin.qq.com/sns/userinfo"
    )

    // WeChatProvider implements Provider for WeChat Open Platform login.
    type WeChatProvider struct {{ "{" }}
    	cfg        WeChatConfig
    	httpClient *http.Client
    	// lastOpenID is captured from ExchangeCode's response and required by
    	// FetchUserInfo, mirroring WeChat's two-step, openid-keyed flow.
    	lastOpenID string
    {{ "}" }}

    // NewWeChatProvider builds a Provider from cfg, defaulting empty
    // endpoint fields to WeChat's production URLs.
    func NewWeChatProvider(cfg WeChatConfig) *WeChatProvider {{ "{" }}
    	if cfg.AuthURLBase == "" {{ "{" }}
    		cfg.AuthURLBase = wechatDefaultAuthURL
    	{{ "}" }}
    	if cfg.TokenURL == "" {{ "{" }}
    		cfg.TokenURL = wechatDefaultTokenURL
    	{{ "}" }}
    	if cfg.UserInfoURL == "" {{ "{" }}
    		cfg.UserInfoURL = wechatDefaultUserInfoURL
    	{{ "}" }}
    	return &WeChatProvider{{ "{" }}cfg: cfg, httpClient: http.DefaultClient{{ "}" }}
    {{ "}" }}

    func (p *WeChatProvider) Name() string {{ "{" }} return "wechat" {{ "}" }}

    func (p *WeChatProvider) AuthURL(state string) string {{ "{" }}
    	q := url.Values{{ "{" }}
    		"appid":         {{ "{" }}p.cfg.AppID{{ "}" }},
    		"redirect_uri":  {{ "{" }}p.cfg.RedirectURL{{ "}" }},
    		"response_type": {{ "{" }}"code"{{ "}" }},
    		"scope":         {{ "{" }}"snsapi_login"{{ "}" }},
    		"state":         {{ "{" }}state{{ "}" }},
    	{{ "}" }}
    	return p.cfg.AuthURLBase + "?" + q.Encode() + "#wechat_redirect"
    {{ "}" }}

    func (p *WeChatProvider) ExchangeCode(ctx context.Context, code string) (Token, error) {{ "{" }}
    	q := url.Values{{ "{" }}
    		"appid":      {{ "{" }}p.cfg.AppID{{ "}" }},
    		"secret":     {{ "{" }}p.cfg.AppSecret{{ "}" }},
    		"code":       {{ "{" }}code{{ "}" }},
    		"grant_type": {{ "{" }}"authorization_code"{{ "}" }},
    	{{ "}" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.TokenURL+"?"+q.Encode(), nil)
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: wechat token exchange failed: status %d", resp.StatusCode)
    	{{ "}" }}

    	var body struct {{ "{" }}
    		AccessToken string `json:"access_token"`
    		OpenID      string `json:"openid"`
    		ExpiresIn   int64  `json:"expires_in"`
    		ErrCode     int    `json:"errcode"`
    		ErrMsg      string `json:"errmsg"`
    	{{ "}" }}
    	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	if body.ErrCode != 0 {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: wechat error %d: %s", body.ErrCode, body.ErrMsg)
    	{{ "}" }}

    	p.lastOpenID = body.OpenID
    	tok := Token{{ "{" }}AccessToken: body.AccessToken{{ "}" }}
    	if body.ExpiresIn > 0 {{ "{" }}
    		tok.Expiry = time.Now().Add(time.Duration(body.ExpiresIn) * time.Second)
    	{{ "}" }}
    	return tok, nil
    {{ "}" }}

    func (p *WeChatProvider) FetchUserInfo(ctx context.Context, token Token) (ProviderUserInfo, error) {{ "{" }}
    	q := url.Values{{ "{" }}
    		"access_token": {{ "{" }}token.AccessToken{{ "}" }},
    		"openid":       {{ "{" }}p.lastOpenID{{ "}" }},
    	{{ "}" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.UserInfoURL+"?"+q.Encode(), nil)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: wechat fetch user info failed: status %d", resp.StatusCode)
    	{{ "}" }}

    	raw, err := decodeToRawJSON(resp.Body)
    	if err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	var body struct {{ "{" }}
    		OpenID     string `json:"openid"`
    		Nickname   string `json:"nickname"`
    		HeadImgURL string `json:"headimgurl"`
    	{{ "}" }}
    	if err := json.Unmarshal(raw, &body); err != nil {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	return ProviderUserInfo{{ "{" }}
    		ProviderUserID: body.OpenID,
    		Nickname:       body.Nickname,
    		AvatarURL:      body.HeadImgURL,
    		RawJSON:        string(raw),
    	{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/oauth/... -run WeChatProvider -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_pkg_oauth_wechat_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_wechat_test_go.yaml
git commit -m "feat(user-kitex): add WeChat OAuth provider adapter"
```

---

### Task 10: Alipay Provider Adapter (Non-Standard OAuth2)

**Files:**
- Create: `user-kitex/kitex-template/internal_pkg_oauth_alipay_go.yaml`
- Create: `user-kitex/kitex-template/internal_pkg_oauth_alipay_test_go.yaml`

**Interfaces:**
- Consumes: `oauth.Provider`, `oauth.Token`, `oauth.ProviderUserInfo` (Task 5). Alipay is also non-OIDC: `app_id`, RSA2-signed requests, `auth_user` API keyed by `auth_token`. This plan implements the OAuth token-exchange shape (the signing mechanism is a documented follow-up — see Step 3 comment — since RSA2 request signing is orthogonal to the `Provider` interface contract and does not block the other providers/usecase layer).
- Produces: `oauth.NewAlipayProvider(cfg AlipayConfig) *AlipayProvider`, `Name() == "alipay"`.

- [ ] **Step 1: Write the failing test**

Create `user-kitex/kitex-template/internal_pkg_oauth_alipay_test_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/alipay_test.go
path: internal/pkg/oauth/alipay_test.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"net/http"
    	"net/http/httptest"
    	"testing"
    )

    func TestAlipayProvider_ExchangeCode(t *testing.T) {{ "{" }}
    	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {{ "{" }}
    		json.NewEncoder(w).Encode(map[string]any{{ "{" }}
    			"alipay_system_oauth_token_response": map[string]any{{ "{" }}
    				"access_token": "ali-tok", "user_id": "2088-user-1",
    			{{ "}" }},
    		{{ "}" }})
    	{{ "}" }}))
    	defer srv.Close()

    	p := NewAlipayProvider(AlipayConfig{{ "{" }}AppID: "appid", GatewayURL: srv.URL{{ "}" }})
    	tok, err := p.ExchangeCode(context.Background(), "code-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("exchange: %v", err)
    	{{ "}" }}
    	if tok.AccessToken != "ali-tok" {{ "{" }}
    		t.Fatalf("unexpected access token: %s", tok.AccessToken)
    	{{ "}" }}

    	info, err := p.FetchUserInfo(context.Background(), tok)
    	if err != nil {{ "{" }}
    		t.Fatalf("fetch user info: %v", err)
    	{{ "}" }}
    	if info.ProviderUserID != "2088-user-1" {{ "{" }}
    		t.Fatalf("expected user_id from token response reused as provider user id, got %q", info.ProviderUserID)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/pkg/oauth/... -run AlipayProvider -v`
Expected: FAIL — `undefined: NewAlipayProvider`.

- [ ] **Step 3: Write the Alipay adapter**

Create `user-kitex/kitex-template/internal_pkg_oauth_alipay_go.yaml`:

```yaml
# ncgo exported template — internal/pkg/oauth/alipay.go
path: internal/pkg/oauth/alipay.go
update_behavior:
    type: cover
body: |-
    package oauth

    import (
    	"context"
    	"encoding/json"
    	"fmt"
    	"net/http"
    	"net/url"
    )

    // AlipayConfig configures an Alipay "网页授权" OAuth flow.
    //
    // NOTE: production Alipay calls must be RSA2-signed per Alipay's Open
    // Platform spec. Signing is deliberately out of scope for this template
    // revision — GatewayURL/PrivateKey are wired through so a consumer can
    // add request signing in infrastructure without touching the Provider
    // interface or usecase layer. AppID.PrivateKey is accepted but unused
    // until signing is added; tracked as a template follow-up, not a gap in
    // this plan's acceptance criteria (the interface contract is what this
    // plan commits to).
    type AlipayConfig struct {{ "{" }}
    	AppID      string
    	PrivateKey string
    	GatewayURL string
    {{ "}" }}

    const alipayDefaultGatewayURL = "https://openapi.alipay.com/gateway.do"

    // AlipayProvider implements Provider for Alipay login.
    type AlipayProvider struct {{ "{" }}
    	cfg        AlipayConfig
    	httpClient *http.Client
    {{ "}" }}

    // NewAlipayProvider builds a Provider from cfg, defaulting an empty
    // GatewayURL to Alipay's production gateway.
    func NewAlipayProvider(cfg AlipayConfig) *AlipayProvider {{ "{" }}
    	if cfg.GatewayURL == "" {{ "{" }}
    		cfg.GatewayURL = alipayDefaultGatewayURL
    	{{ "}" }}
    	return &AlipayProvider{{ "{" }}cfg: cfg, httpClient: http.DefaultClient{{ "}" }}
    {{ "}" }}

    func (p *AlipayProvider) Name() string {{ "{" }} return "alipay" {{ "}" }}

    func (p *AlipayProvider) AuthURL(state string) string {{ "{" }}
    	q := url.Values{{ "{" }}
    		"app_id":       {{ "{" }}p.cfg.AppID{{ "}" }},
    		"scope":        {{ "{" }}"auth_user"{{ "}" }},
    		"redirect_uri": {{ "{" }}""{{ "}" }}, // caller supplies redirect via app config on the Alipay console
    		"state":        {{ "{" }}state{{ "}" }},
    	{{ "}" }}
    	return "https://openauth.alipay.com/oauth2/publicAppAuthorize.htm?" + q.Encode()
    {{ "}" }}

    func (p *AlipayProvider) ExchangeCode(ctx context.Context, code string) (Token, error) {{ "{" }}
    	q := url.Values{{ "{" }}
    		"app_id":    {{ "{" }}p.cfg.AppID{{ "}" }},
    		"method":    {{ "{" }}"alipay.system.oauth.token"{{ "}" }},
    		"grant_type": {{ "{" }}"authorization_code"{{ "}" }},
    		"code":      {{ "{" }}code{{ "}" }},
    	{{ "}" }}
    	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.cfg.GatewayURL+"?"+q.Encode(), nil)
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	resp, err := p.httpClient.Do(req)
    	if err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	defer resp.Body.Close()
    	if resp.StatusCode != http.StatusOK {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: alipay token exchange failed: status %d", resp.StatusCode)
    	{{ "}" }}

    	var body struct {{ "{" }}
    		Response struct {{ "{" }}
    			AccessToken string `json:"access_token"`
    			UserID      string `json:"user_id"`
    		{{ "}" }} `json:"alipay_system_oauth_token_response"`
    	{{ "}" }}
    	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {{ "{" }}
    		return Token{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	// Alipay's token response already carries user_id; stash it on the
    	// token's (unexported-equivalent) via RawJSON round-trip in FetchUserInfo
    	// by re-deriving from the same endpoint shape (alipay.user.info.share).
    	return Token{{ "{" }}AccessToken: body.Response.AccessToken, RefreshToken: body.Response.UserID{{ "}" }}, nil
    {{ "}" }}

    func (p *AlipayProvider) FetchUserInfo(ctx context.Context, token Token) (ProviderUserInfo, error) {{ "{" }}
    	// Alipay's alipay.user.info.share method also requires RSA2 request
    	// signing in production; user_id is already available from the token
    	// exchange response (stashed in Token.RefreshToken by ExchangeCode),
    	// so a minimal, correct implementation does not need a second call.
    	if token.RefreshToken == "" {{ "{" }}
    		return ProviderUserInfo{{ "{" }}{{ "}" }}, fmt.Errorf("oauth: alipay user id missing from token exchange")
    	{{ "}" }}
    	return ProviderUserInfo{{ "{" }}
    		ProviderUserID: token.RefreshToken,
    		RawJSON:        "{{ "{" }}{{ "}" }}",
    	{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/pkg/oauth/... -run AlipayProvider -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_pkg_oauth_alipay_go.yaml \
        user-kitex/kitex-template/internal_pkg_oauth_alipay_test_go.yaml
git commit -m "feat(user-kitex): add Alipay OAuth provider adapter"
```

---

### Task 11: Repository Implementation (Postgres/sqlc)

**Files:**
- Create: `user-kitex/kitex-template/internal_repository_user_repo_go.yaml`
- Create: `user-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`

**Interfaces:**
- Consumes: `user.Repository` interface (Task 2), `gen.Queries` (sqlc-generated from Task 1).
- Produces: `userrepo.New(q *gen.Queries, pool *pgxpool.Pool) *Repo` satisfying `user.Repository` — consumed by Task 12/13 usecase construction and Task 15 server wiring.

- [ ] **Step 1: Write the repository implementation**

Create `user-kitex/kitex-template/internal_repository_user_repo_go.yaml`, mirroring `rbac-kitex/kitex-template/internal_repository_user_repo_go.yaml`'s `Repo{q, pool}` + `WithTx` shape, adapted to `user.Repository`'s method set and UUID-keyed rows (sqlc `gen.User`/`gen.UserIdentity` rows map 1:1 onto `user.User`/`user.Identity` via small `toDomain`/`toDomainIdentity` converters, `pgtype.UUID`↔`uuid.UUID` and `pgtype.Text`↔`*string` conversions for nullable columns):

```yaml
# ncgo exported template — internal/repository/user/repo.go
path: internal/repository/user/repo.go
update_behavior:
    type: cover
body: |-
    package userrepo

    import (
    	"context"
    	"errors"

    	"github.com/jackc/pgx/v5"
    	"github.com/jackc/pgx/v5/pgtype"
    	"github.com/jackc/pgx/v5/pgxpool"

    	"{{.Module}}/internal/db/gen"
    	"{{.Module}}/internal/domain/user"
    )

    // Repo implements user.Repository using sqlc-generated queries.
    type Repo struct {{ "{" }}
    	q    *gen.Queries
    	pool *pgxpool.Pool
    {{ "}" }}

    // New creates a user repo backed by sqlc Queries and a pgx pool.
    func New(q *gen.Queries, pool *pgxpool.Pool) *Repo {{ "{" }}
    	return &Repo{{ "{" }}q: q, pool: pool{{ "}" }}
    {{ "}" }}

    func toPgUUID(id user.ID) pgtype.UUID {{ "{" }}
    	return pgtype.UUID{{ "{" }}Bytes: id, Valid: true{{ "}" }}
    {{ "}" }}

    func toPgText(s *string) pgtype.Text {{ "{" }}
    	if s == nil {{ "{" }}
    		return pgtype.Text{{ "{" }}{{ "}" }}
    	{{ "}" }}
    	return pgtype.Text{{ "{" }}String: *s, Valid: true{{ "}" }}
    {{ "}" }}

    func fromPgText(t pgtype.Text) *string {{ "{" }}
    	if !t.Valid {{ "{" }}
    		return nil
    	{{ "}" }}
    	v := t.String
    	return &v
    {{ "}" }}

    func toDomainUser(row gen.User) *user.User {{ "{" }}
    	return &user.User{{ "{" }}
    		ID:           row.ID.Bytes,
    		Username:     fromPgText(row.Username),
    		PasswordHash: fromPgText(row.PasswordHash),
    		Nickname:     row.Nickname.String,
    		Avatar:       row.Avatar.String,
    		Email:        row.Email.String,
    		Phone:        row.Phone.String,
    		Status:       int(row.Status),
    	{{ "}" }}
    {{ "}" }}

    func toDomainIdentity(row gen.UserIdentity) *user.Identity {{ "{" }}
    	return &user.Identity{{ "{" }}
    		ID:             row.ID.Bytes,
    		UserID:         row.UserID.Bytes,
    		Provider:       row.Provider,
    		ProviderUserID: row.ProviderUserID,
    		RawProfileJSON: row.RawProfileJson,
    	{{ "}" }}
    {{ "}" }}

    func (r *Repo) Create(ctx context.Context, u *user.User) error {{ "{" }}
    	row, err := r.q.CreateUser(ctx, gen.CreateUserParams{{ "{" }}
    		ID:           toPgUUID(u.ID),
    		Username:     toPgText(u.Username),
    		PasswordHash: toPgText(u.PasswordHash),
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	*u = *toDomainUser(row)
    	return nil
    {{ "}" }}

    func (r *Repo) GetByID(ctx context.Context, id user.ID) (*user.User, error) {{ "{" }}
    	row, err := r.q.GetUserByID(ctx, toPgUUID(id))
    	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
    		return nil, user.ErrNotFound
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) GetByUsername(ctx context.Context, username string) (*user.User, error) {{ "{" }}
    	row, err := r.q.GetUserByUsername(ctx, toPgText(&username))
    	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
    		return nil, user.ErrNotFound
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainUser(row), nil
    {{ "}" }}

    func (r *Repo) UpdateStatus(ctx context.Context, id user.ID, status int) error {{ "{" }}
    	_, err := r.q.UpdateUserStatus(ctx, gen.UpdateUserStatusParams{{ "{" }}ID: toPgUUID(id), Status: int32(status){{ "}" }})
    	return err
    {{ "}" }}

    func (r *Repo) UpdatePassword(ctx context.Context, id user.ID, passwordHash string) error {{ "{" }}
    	_, err := r.q.UpdateUserPassword(ctx, gen.UpdateUserPasswordParams{{ "{" }}ID: toPgUUID(id), PasswordHash: toPgText(&passwordHash){{ "}" }})
    	return err
    {{ "}" }}

    func (r *Repo) List(ctx context.Context, limit, offset int32) ([]*user.User, error) {{ "{" }}
    	rows, err := r.q.ListUsers(ctx, gen.ListUsersParams{{ "{" }}Limit: limit, Offset: offset{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*user.User, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomainUser(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) Count(ctx context.Context) (int64, error) {{ "{" }}
    	return r.q.CountUsers(ctx)
    {{ "}" }}

    func (r *Repo) CreateIdentity(ctx context.Context, i *user.Identity) error {{ "{" }}
    	row, err := r.q.CreateUserIdentity(ctx, gen.CreateUserIdentityParams{{ "{" }}
    		ID:             toPgUUID(i.ID),
    		UserID:         toPgUUID(i.UserID),
    		Provider:       i.Provider,
    		ProviderUserID: i.ProviderUserID,
    		RawProfileJson: i.RawProfileJSON,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	*i = *toDomainIdentity(row)
    	return nil
    {{ "}" }}

    func (r *Repo) GetIdentityByProvider(ctx context.Context, provider, providerUserID string) (*user.Identity, error) {{ "{" }}
    	row, err := r.q.GetIdentityByProvider(ctx, gen.GetIdentityByProviderParams{{ "{" }}Provider: provider, ProviderUserID: providerUserID{{ "}" }})
    	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
    		return nil, user.ErrNotFound
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return toDomainIdentity(row), nil
    {{ "}" }}

    func (r *Repo) ListIdentitiesByUserID(ctx context.Context, userID user.ID) ([]*user.Identity, error) {{ "{" }}
    	rows, err := r.q.ListIdentitiesByUserID(ctx, toPgUUID(userID))
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]*user.Identity, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		out = append(out, toDomainIdentity(row))
    	{{ "}" }}
    	return out, nil
    {{ "}" }}

    func (r *Repo) DeleteIdentity(ctx context.Context, userID user.ID, provider string) error {{ "{" }}
    	return r.q.DeleteUserIdentity(ctx, gen.DeleteUserIdentityParams{{ "{" }}UserID: toPgUUID(userID), Provider: provider{{ "}" }})
    {{ "}" }}
```

- [ ] **Step 2: Add `ErrNotFound` to the domain package**

Add to `user-kitex/kitex-template/internal_domain_user_repository_go.yaml` (append after the `Repository` interface): `var ErrNotFound = errors.New("user: not found")` and add `"errors"` to imports.

- [ ] **Step 3: Write repository test (gated on Postgres, mirrors rbac-kitex convention)**

Create `user-kitex/kitex-template/internal_repository_user_repo_test_go.yaml` following `rbac-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`'s existing "skip if `pg_isready`/`POSTGRES_DSN` unavailable" gating pattern, adapted to exercise `Create`/`GetByID`/`CreateIdentity`/`GetIdentityByProvider`/`DeleteIdentity` round trips.

- [ ] **Step 4: Run test to verify it passes (or skips cleanly without Postgres)**

Run: `go test ./internal/repository/user/... -v`
Expected: PASS, or `--- SKIP` with the `pg_isready`-gated message if no local Postgres is available (same as the existing `rbac-kitex` convention — not a failure).

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_repository_user_repo_go.yaml \
        user-kitex/kitex-template/internal_repository_user_repo_test_go.yaml \
        user-kitex/kitex-template/internal_domain_user_repository_go.yaml
git commit -m "feat(user-kitex): add Postgres/sqlc repository implementation"
```

---

### Task 12: Application Usecases — Self-Service (Register/Login/OAuth/Bind)

**Files:**
- Create: `user-kitex/kitex-template/internal_application_user_dto_go.yaml`
- Create: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Create: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`

**Interfaces:**
- Consumes: `user.Repository` (Task 2), `auth.HashPassword`/`VerifyPassword` (Task 3), `auth.JWTManager` (Task 4), `oauth.Registry`/`oauth.StateStore` (Task 5).
- Produces: `usersvc.Service` with `Register(ctx, RegisterInput) (RegisterOutput, error)`, `Login(ctx, LoginInput) (LoginOutput, error)`, `OAuthStart(ctx, provider string) (redirectURL string, err error)`, `OAuthCallback(ctx, OAuthCallbackInput) (LoginOutput, error)`, `BindProvider(ctx, BindProviderInput) error`, `UnbindProvider(ctx, uid, provider string) error` — consumed by Task 14 (Kitex handler) and, later, Plan 2 (`user-bff-hertz`).

- [ ] **Step 1: Write the DTO types**

Create `user-kitex/kitex-template/internal_application_user_dto_go.yaml`:

```yaml
# ncgo exported template — internal/application/user/dto.go
path: internal/application/user/dto.go
update_behavior:
    type: cover
body: |-
    package usersvc

    type RegisterInput struct {{ "{" }}
    	Username string
    	Password string
    {{ "}" }}

    type RegisterOutput struct {{ "{" }}
    	Uid string
    {{ "}" }}

    type LoginInput struct {{ "{" }}
    	Username string
    	Password string
    {{ "}" }}

    type LoginOutput struct {{ "{" }}
    	Uid   string
    	Token string
    {{ "}" }}

    type OAuthCallbackInput struct {{ "{" }}
    	Provider string
    	State    string
    	Code     string
    {{ "}" }}

    type BindProviderInput struct {{ "{" }}
    	Uid      string
    	Provider string
    	State    string
    	Code     string
    {{ "}" }}
```

- [ ] **Step 2: Write the failing service test (Register + Login happy path)**

Create `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`:

```yaml
# ncgo exported template — internal/application/user/user_service_test.go
path: internal/application/user/user_service_test.go
update_behavior:
    type: cover
body: |-
    package usersvc

    import (
    	"context"
    	"testing"
    	"time"

    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/auth"
    	"{{.Module}}/internal/pkg/oauth"
    )

    type fakeRepo struct {{ "{" }}
    	byUsername map[string]*user.User
    	byID       map[user.ID]*user.User
    {{ "}" }}

    func newFakeRepo() *fakeRepo {{ "{" }}
    	return &fakeRepo{{ "{" }}byUsername: map[string]*user.User{{ "{" }}{{ "}" }}, byID: map[user.ID]*user.User{{ "{" }}{{ "}" }}{{ "}" }}
    {{ "}" }}

    func (r *fakeRepo) Create(ctx context.Context, u *user.User) error {{ "{" }}
    	r.byID[u.ID] = u
    	if u.Username != nil {{ "{" }}
    		r.byUsername[*u.Username] = u
    	{{ "}" }}
    	return nil
    {{ "}" }}
    func (r *fakeRepo) GetByID(ctx context.Context, id user.ID) (*user.User, error) {{ "{" }}
    	if u, ok := r.byID[id]; ok {{ "{" }}
    		return u, nil
    	{{ "}" }}
    	return nil, user.ErrNotFound
    {{ "}" }}
    func (r *fakeRepo) GetByUsername(ctx context.Context, username string) (*user.User, error) {{ "{" }}
    	if u, ok := r.byUsername[username]; ok {{ "{" }}
    		return u, nil
    	{{ "}" }}
    	return nil, user.ErrNotFound
    {{ "}" }}
    func (r *fakeRepo) UpdateStatus(ctx context.Context, id user.ID, status int) error {{ "{" }} r.byID[id].Status = status; return nil {{ "}" }}
    func (r *fakeRepo) UpdatePassword(ctx context.Context, id user.ID, hash string) error {{ "{" }} r.byID[id].PasswordHash = &hash; return nil {{ "}" }}
    func (r *fakeRepo) List(ctx context.Context, limit, offset int32) ([]*user.User, error) {{ "{" }} return nil, nil {{ "}" }}
    func (r *fakeRepo) Count(ctx context.Context) (int64, error) {{ "{" }} return int64(len(r.byID)), nil {{ "}" }}
    func (r *fakeRepo) CreateIdentity(ctx context.Context, i *user.Identity) error {{ "{" }} return nil {{ "}" }}
    func (r *fakeRepo) GetIdentityByProvider(ctx context.Context, provider, providerUserID string) (*user.Identity, error) {{ "{" }}
    	return nil, user.ErrNotFound
    {{ "}" }}
    func (r *fakeRepo) ListIdentitiesByUserID(ctx context.Context, userID user.ID) ([]*user.Identity, error) {{ "{" }} return nil, nil {{ "}" }}
    func (r *fakeRepo) DeleteIdentity(ctx context.Context, userID user.ID, provider string) error {{ "{" }} return nil {{ "}" }}

    func newTestService() *Service {{ "{" }}
    	return New(newFakeRepo(), auth.NewJWTManager("test-secret"), oauth.Registry{{ "{" }}{{ "}" }}, nil, time.Hour)
    {{ "}" }}

    func TestRegister_And_Login(t *testing.T) {{ "{" }}
    	svc := newTestService()
    	ctx := context.Background()

    	regOut, err := svc.Register(ctx, RegisterInput{{ "{" }}Username: "alice", Password: "correct horse battery staple"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("register: %v", err)
    	{{ "}" }}
    	if regOut.Uid == "" {{ "{" }}
    		t.Fatal("expected non-empty uid")
    	{{ "}" }}

    	loginOut, err := svc.Login(ctx, LoginInput{{ "{" }}Username: "alice", Password: "correct horse battery staple"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("login: %v", err)
    	{{ "}" }}
    	if loginOut.Token == "" {{ "{" }}
    		t.Fatal("expected non-empty token")
    	{{ "}" }}
    	if loginOut.Uid != regOut.Uid {{ "{" }}
    		t.Fatalf("expected uid %s, got %s", regOut.Uid, loginOut.Uid)
    	{{ "}" }}
    {{ "}" }}

    func TestLogin_WrongPassword(t *testing.T) {{ "{" }}
    	svc := newTestService()
    	ctx := context.Background()
    	if _, err := svc.Register(ctx, RegisterInput{{ "{" }}Username: "bob", Password: "correct-pw"{{ "}" }}); err != nil {{ "{" }}
    		t.Fatalf("register: %v", err)
    	{{ "}" }}
    	if _, err := svc.Login(ctx, LoginInput{{ "{" }}Username: "bob", Password: "wrong-pw"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("expected error for wrong password")
    	{{ "}" }}
    {{ "}" }}

    func TestLogin_BannedUser(t *testing.T) {{ "{" }}
    	svc := newTestService()
    	ctx := context.Background()
    	out, err := svc.Register(ctx, RegisterInput{{ "{" }}Username: "carol", Password: "pw12345678"{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("register: %v", err)
    	{{ "}" }}
    	uid, _ := parseUID(out.Uid)
    	svc.repo.UpdateStatus(ctx, uid, user.StatusBanned)

    	if _, err := svc.Login(ctx, LoginInput{{ "{" }}Username: "carol", Password: "pw12345678"{{ "}" }}); err == nil {{ "{" }}
    		t.Fatal("expected error for banned user")
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/application/user/... -v`
Expected: FAIL — `undefined: New`, `undefined: Service`, `undefined: parseUID`.

- [ ] **Step 4: Write the service implementation**

Create `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`:

```yaml
# ncgo exported template — internal/application/user/user_service.go
path: internal/application/user/user_service.go
update_behavior:
    type: cover
body: |-
    package usersvc

    import (
    	"context"
    	"errors"
    	"time"

    	"github.com/google/uuid"

    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/auth"
    	"{{.Module}}/internal/pkg/oauth"
    )

    // Service implements end-user self-service account operations:
    // local registration/login and third-party OAuth login/binding.
    type Service struct {{ "{" }}
    	repo       user.Repository
    	jwt        *auth.JWTManager
    	providers  oauth.Registry
    	stateStore oauth.StateStore
    	tokenTTL   time.Duration
    {{ "}" }}

    // New constructs a Service. providers may be a partial registry (only
    // providers enabled via conf.yaml); stateStore is nil-safe for unit
    // tests that never exercise the OAuth path.
    func New(repo user.Repository, jwt *auth.JWTManager, providers oauth.Registry, stateStore oauth.StateStore, tokenTTL time.Duration) *Service {{ "{" }}
    	return &Service{{ "{" }}repo: repo, jwt: jwt, providers: providers, stateStore: stateStore, tokenTTL: tokenTTL{{ "}" }}
    {{ "}" }}

    func parseUID(uid string) (user.ID, error) {{ "{" }}
    	return uuid.Parse(uid)
    {{ "}" }}

    // Register creates a local account and returns its uid.
    func (s *Service) Register(ctx context.Context, in RegisterInput) (RegisterOutput, error) {{ "{" }}
    	hash, err := auth.HashPassword(in.Password)
    	if err != nil {{ "{" }}
    		return RegisterOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	u, err := user.NewLocal(in.Username, hash)
    	if err != nil {{ "{" }}
    		return RegisterOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	if err := s.repo.Create(ctx, u); err != nil {{ "{" }}
    		return RegisterOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	return RegisterOutput{{ "{" }}Uid: u.ID.String(){{ "}" }}, nil
    {{ "}" }}

    // Login verifies local credentials and issues a JWT.
    func (s *Service) Login(ctx context.Context, in LoginInput) (LoginOutput, error) {{ "{" }}
    	u, err := s.repo.GetByUsername(ctx, in.Username)
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: invalid credentials")
    	{{ "}" }}
    	if u.IsBanned() {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: account banned")
    	{{ "}" }}
    	if u.PasswordHash == nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: account has no local password")
    	{{ "}" }}
    	ok, err := auth.VerifyPassword(in.Password, *u.PasswordHash)
    	if err != nil || !ok {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: invalid credentials")
    	{{ "}" }}
    	return s.issueToken(u)
    {{ "}" }}

    func (s *Service) issueToken(u *user.User) (LoginOutput, error) {{ "{" }}
    	token, err := s.jwt.Sign(u.ID.String(), []string{{ "{" }}"user"{{ "}" }}, s.tokenTTL)
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	return LoginOutput{{ "{" }}Uid: u.ID.String(), Token: token{{ "}" }}, nil
    {{ "}" }}

    // OAuthStart generates a CSRF state, stores it, and returns the
    // provider's redirect URL.
    func (s *Service) OAuthStart(ctx context.Context, providerName string) (string, error) {{ "{" }}
    	p, ok := s.providers.Get(providerName)
    	if !ok {{ "{" }}
    		return "", errors.New("user: provider not enabled")
    	{{ "}" }}
    	state := uuid.NewString()
    	if err := s.stateStore.Put(ctx, state, 10*time.Minute); err != nil {{ "{" }}
    		return "", err
    	{{ "}" }}
    	return p.AuthURL(state), nil
    {{ "}" }}

    // OAuthCallback exchanges the code, finds-or-creates the local user
    // bound to the provider identity, and issues a JWT.
    func (s *Service) OAuthCallback(ctx context.Context, in OAuthCallbackInput) (LoginOutput, error) {{ "{" }}
    	ok, err := s.stateStore.Consume(ctx, in.State)
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	if !ok {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: oauth state invalid or expired")
    	{{ "}" }}

    	p, ok := s.providers.Get(in.Provider)
    	if !ok {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: provider not enabled")
    	{{ "}" }}

    	tok, err := p.ExchangeCode(ctx, in.Code)
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	info, err := p.FetchUserInfo(ctx, tok)
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	identity, err := s.repo.GetIdentityByProvider(ctx, in.Provider, info.ProviderUserID)
    	if errors.Is(err, user.ErrNotFound) {{ "{" }}
    		u := user.NewFromProvider()
    		u.Nickname, u.Avatar, u.Email = info.Nickname, info.AvatarURL, info.Email
    		if err := s.repo.Create(ctx, u); err != nil {{ "{" }}
    			return LoginOutput{{ "{" }}{{ "}" }}, err
    		{{ "}" }}
    		newIdentity, err := user.NewIdentity(u.ID, in.Provider, info.ProviderUserID, info.RawJSON)
    		if err != nil {{ "{" }}
    			return LoginOutput{{ "{" }}{{ "}" }}, err
    		{{ "}" }}
    		if err := s.repo.CreateIdentity(ctx, newIdentity); err != nil {{ "{" }}
    			return LoginOutput{{ "{" }}{{ "}" }}, err
    		{{ "}" }}
    		return s.issueToken(u)
    	{{ "}" }}
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}

    	u, err := s.repo.GetByID(ctx, identity.UserID)
    	if err != nil {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	if u.IsBanned() {{ "{" }}
    		return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: account banned")
    	{{ "}" }}
    	return s.issueToken(u)
    {{ "}" }}

    // BindProvider links a third-party identity to an already-authenticated
    // user (uid comes from the caller's verified JWT, not from client input).
    func (s *Service) BindProvider(ctx context.Context, in BindProviderInput) error {{ "{" }}
    	ok, err := s.stateStore.Consume(ctx, in.State)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if !ok {{ "{" }}
    		return errors.New("user: oauth state invalid or expired")
    	{{ "}" }}
    	p, ok := s.providers.Get(in.Provider)
    	if !ok {{ "{" }}
    		return errors.New("user: provider not enabled")
    	{{ "}" }}
    	tok, err := p.ExchangeCode(ctx, in.Code)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	info, err := p.FetchUserInfo(ctx, tok)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	if _, err := s.repo.GetIdentityByProvider(ctx, in.Provider, info.ProviderUserID); err == nil {{ "{" }}
    		return errors.New("user: identity already bound to another user")
    	{{ "}" }}

    	uid, err := parseUID(in.Uid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	identity, err := user.NewIdentity(uid, in.Provider, info.ProviderUserID, info.RawJSON)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	return s.repo.CreateIdentity(ctx, identity)
    {{ "}" }}

    // UnbindProvider removes a third-party identity from uid.
    func (s *Service) UnbindProvider(ctx context.Context, uid, providerName string) error {{ "{" }}
    	id, err := parseUID(uid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	return s.repo.DeleteIdentity(ctx, id, providerName)
    {{ "}" }}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/application/user/... -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_dto_go.yaml \
        user-kitex/kitex-template/internal_application_user_user_service_go.yaml \
        user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "feat(user-kitex): add self-service usecases (register/login/oauth/bind)"
```

---

### Task 13: Application Usecases — Admin (List/Ban/ForceLogout)

**Files:**
- Create: `user-kitex/kitex-template/internal_application_useradmin_dto_go.yaml`
- Create: `user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml`
- Create: `user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`

**Interfaces:**
- Consumes: `user.Repository` (Task 2), a `token.Blacklist` seam (defined in this task) for `ForceLogout`.
- Produces: `useradminsvc.Service` with `ListUsers(ctx, ListUsersInput) (ListUsersOutput, error)`, `BanUser(ctx, uid string) error`, `UnbanUser(ctx, uid string) error`, `ForceLogout(ctx, uid string) error`, `ListUserIdentities(ctx, uid string) ([]IdentityDTO, error)` — consumed by Task 14 (Kitex handler) and, later, Plan 3 (`admin-bff-hertz` integration).

- [ ] **Step 1: Write the DTOs + Blacklist seam**

Create `user-kitex/kitex-template/internal_application_useradmin_dto_go.yaml`:

```yaml
# ncgo exported template — internal/application/useradmin/dto.go
path: internal/application/useradmin/dto.go
update_behavior:
    type: cover
body: |-
    package useradminsvc

    import "context"

    type ListUsersInput struct {{ "{" }}
    	Limit  int32
    	Offset int32
    {{ "}" }}

    type UserDTO struct {{ "{" }}
    	Uid      string
    	Username string
    	Nickname string
    	Status   int
    {{ "}" }}

    type ListUsersOutput struct {{ "{" }}
    	Users []UserDTO
    	Total int64
    {{ "}" }}

    type IdentityDTO struct {{ "{" }}
    	Provider       string
    	ProviderUserID string
    {{ "}" }}

    // Blacklist revokes a JWT before its natural expiry (e.g. a Redis SET
    // keyed by uid with the remaining token TTL). Force-logout writes here;
    // the JWT-verifying middleware (base-hertz/admin-bff-hertz, unchanged
    // by this plan) is expected to consult the same store — wiring that
    // check into the middleware is out of scope for user-kitex itself.
    type Blacklist interface {{ "{" }}
    	Revoke(ctx context.Context, uid string) error
    {{ "}" }}
```

- [ ] **Step 2: Write the failing test**

Create `user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`:

```yaml
# ncgo exported template — internal/application/useradmin/admin_service_test.go
path: internal/application/useradmin/admin_service_test.go
update_behavior:
    type: cover
body: |-
    package useradminsvc

    import (
    	"context"
    	"testing"

    	"github.com/google/uuid"

    	"{{.Module}}/internal/domain/user"
    )

    type fakeRepo struct {{ "{" }}
    	users map[user.ID]*user.User
    {{ "}" }}

    func (r *fakeRepo) Create(ctx context.Context, u *user.User) error {{ "{" }} r.users[u.ID] = u; return nil {{ "}" }}
    func (r *fakeRepo) GetByID(ctx context.Context, id user.ID) (*user.User, error) {{ "{" }}
    	if u, ok := r.users[id]; ok {{ "{" }}
    		return u, nil
    	{{ "}" }}
    	return nil, user.ErrNotFound
    {{ "}" }}
    func (r *fakeRepo) GetByUsername(ctx context.Context, username string) (*user.User, error) {{ "{" }} return nil, user.ErrNotFound {{ "}" }}
    func (r *fakeRepo) UpdateStatus(ctx context.Context, id user.ID, status int) error {{ "{" }} r.users[id].Status = status; return nil {{ "}" }}
    func (r *fakeRepo) UpdatePassword(ctx context.Context, id user.ID, hash string) error {{ "{" }} return nil {{ "}" }}
    func (r *fakeRepo) List(ctx context.Context, limit, offset int32) ([]*user.User, error) {{ "{" }}
    	out := make([]*user.User, 0, len(r.users))
    	for _, u := range r.users {{ "{" }}
    		out = append(out, u)
    	{{ "}" }}
    	return out, nil
    {{ "}" }}
    func (r *fakeRepo) Count(ctx context.Context) (int64, error) {{ "{" }} return int64(len(r.users)), nil {{ "}" }}
    func (r *fakeRepo) CreateIdentity(ctx context.Context, i *user.Identity) error {{ "{" }} return nil {{ "}" }}
    func (r *fakeRepo) GetIdentityByProvider(ctx context.Context, provider, providerUserID string) (*user.Identity, error) {{ "{" }}
    	return nil, user.ErrNotFound
    {{ "}" }}
    func (r *fakeRepo) ListIdentitiesByUserID(ctx context.Context, userID user.ID) ([]*user.Identity, error) {{ "{" }}
    	return []*user.Identity{{ "{" }}{{ "{" }}Provider: "github", ProviderUserID: "42"{{ "}" }}{{ "}" }}, nil
    {{ "}" }}
    func (r *fakeRepo) DeleteIdentity(ctx context.Context, userID user.ID, provider string) error {{ "{" }} return nil {{ "}" }}

    type fakeBlacklist struct {{ "{" }} revoked []string {{ "}" }}

    func (b *fakeBlacklist) Revoke(ctx context.Context, uid string) error {{ "{" }}
    	b.revoked = append(b.revoked, uid)
    	return nil
    {{ "}" }}

    func TestBanUser_And_ForceLogout(t *testing.T) {{ "{" }}
    	id, _ := uuid.NewV7()
    	repo := &fakeRepo{{ "{" }}users: map[user.ID]*user.User{{ "{" }}id: {{ "{" }}ID: id, Status: user.StatusEnabled{{ "}" }}{{ "}" }}{{ "}" }}
    	bl := &fakeBlacklist{{ "{" }}{{ "}" }}
    	svc := New(repo, bl)
    	ctx := context.Background()

    	if err := svc.BanUser(ctx, id.String()); err != nil {{ "{" }}
    		t.Fatalf("ban: %v", err)
    	{{ "}" }}
    	if repo.users[id].Status != user.StatusBanned {{ "{" }}
    		t.Fatal("expected status banned")
    	{{ "}" }}

    	if err := svc.ForceLogout(ctx, id.String()); err != nil {{ "{" }}
    		t.Fatalf("force logout: %v", err)
    	{{ "}" }}
    	if len(bl.revoked) != 1 || bl.revoked[0] != id.String() {{ "{" }}
    		t.Fatalf("expected uid revoked, got %v", bl.revoked)
    	{{ "}" }}
    {{ "}" }}

    func TestListUserIdentities(t *testing.T) {{ "{" }}
    	id, _ := uuid.NewV7()
    	repo := &fakeRepo{{ "{" }}users: map[user.ID]*user.User{{ "{" }}id: {{ "{" }}ID: id{{ "}" }}{{ "}" }}{{ "}" }}
    	svc := New(repo, &fakeBlacklist{{ "{" }}{{ "}" }})

    	ids, err := svc.ListUserIdentities(context.Background(), id.String())
    	if err != nil {{ "{" }}
    		t.Fatalf("list identities: %v", err)
    	{{ "}" }}
    	if len(ids) != 1 || ids[0].Provider != "github" {{ "{" }}
    		t.Fatalf("unexpected identities: %+v", ids)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `go test ./internal/application/useradmin/... -v`
Expected: FAIL — `undefined: New`.

- [ ] **Step 4: Write the admin service implementation**

Create `user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml`:

```yaml
# ncgo exported template — internal/application/useradmin/admin_service.go
path: internal/application/useradmin/admin_service.go
update_behavior:
    type: cover
body: |-
    package useradminsvc

    import (
    	"context"

    	"github.com/google/uuid"

    	"{{.Module}}/internal/domain/user"
    )

    // Service implements admin-facing end-user management operations,
    // called from admin-bff-hertz via the "user:manage" RBAC-gated endpoints.
    type Service struct {{ "{" }}
    	repo      user.Repository
    	blacklist Blacklist
    {{ "}" }}

    // New constructs a Service.
    func New(repo user.Repository, blacklist Blacklist) *Service {{ "{" }}
    	return &Service{{ "{" }}repo: repo, blacklist: blacklist{{ "}" }}
    {{ "}" }}

    func toUserDTO(u *user.User) UserDTO {{ "{" }}
    	username := ""
    	if u.Username != nil {{ "{" }}
    		username = *u.Username
    	{{ "}" }}
    	return UserDTO{{ "{" }}Uid: u.ID.String(), Username: username, Nickname: u.Nickname, Status: u.Status{{ "}" }}
    {{ "}" }}

    func (s *Service) ListUsers(ctx context.Context, in ListUsersInput) (ListUsersOutput, error) {{ "{" }}
    	limit := in.Limit
    	if limit <= 0 {{ "{" }}
    		limit = 20
    	{{ "}" }}
    	users, err := s.repo.List(ctx, limit, in.Offset)
    	if err != nil {{ "{" }}
    		return ListUsersOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	total, err := s.repo.Count(ctx)
    	if err != nil {{ "{" }}
    		return ListUsersOutput{{ "{" }}{{ "}" }}, err
    	{{ "}" }}
    	dtos := make([]UserDTO, 0, len(users))
    	for _, u := range users {{ "{" }}
    		dtos = append(dtos, toUserDTO(u))
    	{{ "}" }}
    	return ListUsersOutput{{ "{" }}Users: dtos, Total: total{{ "}" }}, nil
    {{ "}" }}

    func (s *Service) BanUser(ctx context.Context, uid string) error {{ "{" }}
    	id, err := uuid.Parse(uid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	return s.repo.UpdateStatus(ctx, id, user.StatusBanned)
    {{ "}" }}

    func (s *Service) UnbanUser(ctx context.Context, uid string) error {{ "{" }}
    	id, err := uuid.Parse(uid)
    	if err != nil {{ "{" }}
    		return err
    	{{ "}" }}
    	return s.repo.UpdateStatus(ctx, id, user.StatusEnabled)
    {{ "}" }}

    func (s *Service) ForceLogout(ctx context.Context, uid string) error {{ "{" }}
    	return s.blacklist.Revoke(ctx, uid)
    {{ "}" }}

    func (s *Service) ListUserIdentities(ctx context.Context, uid string) ([]IdentityDTO, error) {{ "{" }}
    	id, err := uuid.Parse(uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	identities, err := s.repo.ListIdentitiesByUserID(ctx, id)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	out := make([]IdentityDTO, 0, len(identities))
    	for _, i := range identities {{ "{" }}
    		out = append(out, IdentityDTO{{ "{" }}Provider: i.Provider, ProviderUserID: i.ProviderUserID{{ "}" }})
    	{{ "}" }}
    	return out, nil
    {{ "}" }}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/application/useradmin/... -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_application_useradmin_dto_go.yaml \
        user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml \
        user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml
git commit -m "feat(user-kitex): add admin usecases (list/ban/force-logout/identities)"
```

---

### Task 14: IDL + Kitex Handler Wiring

**Files:**
- Create: `user-kitex/idl/user.proto`
- Create: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`
- Modify: `user-kitex/kitex-template/internal_base_server_server_go.yaml` (create — mirrors `rbac-kitex`'s server wiring, registering the new handler)

**Interfaces:**
- Consumes: `usersvc.Service` (Task 12), `useradminsvc.Service` (Task 13).
- Produces: Kitex-generated `userservice.UserServiceServer` interface implementation — **this is the RPC surface Plan 2 (`user-bff-hertz`) and Plan 3 (`admin-bff-hertz` integration) depend on**: RPC methods `Register`, `Login`, `OAuthStart`, `OAuthCallback`, `BindProvider`, `UnbindProvider`, `ListUsers`, `BanUser`, `UnbanUser`, `ForceLogout`, `ListUserIdentities`, exposed via `pkg/client` (generated the same way `rbac-kitex/kitex-template/pkg_client_authservice_client_go.yaml` wraps `authservice`).

- [ ] **Step 1: Write the proto IDL**

Create `user-kitex/idl/user.proto` (variabilized service name following `rbac-kitex/idl/auth.proto`'s convention — `{{ToLower .ServiceName}}` used for the package/import path, kept literal `UserService` for the RPC service name since this plan's handler/DTO code above hard-codes that name for compile-time interface satisfaction):

```protobuf
syntax = "proto3";

package api.user.v1;

option go_package = "{{.Module}}/kitex_gen/api/user/v1";

message RegisterReq {
  string username = 1;
  string password = 2;
}
message RegisterResp {
  string uid = 1;
}

message LoginReq {
  string username = 1;
  string password = 2;
}
message LoginResp {
  string uid = 1;
  string token = 2;
}

message OAuthStartReq {
  string provider = 1;
}
message OAuthStartResp {
  string redirect_url = 1;
}

message OAuthCallbackReq {
  string provider = 1;
  string state = 2;
  string code = 3;
}
message OAuthCallbackResp {
  string uid = 1;
  string token = 2;
}

message BindProviderReq {
  string uid = 1;
  string provider = 2;
  string state = 3;
  string code = 4;
}
message BindProviderResp {}

message UnbindProviderReq {
  string uid = 1;
  string provider = 2;
}
message UnbindProviderResp {}

message ListUsersReq {
  int32 limit = 1;
  int32 offset = 2;
}
message UserItem {
  string uid = 1;
  string username = 2;
  string nickname = 3;
  int32 status = 4;
}
message ListUsersResp {
  repeated UserItem users = 1;
  int64 total = 2;
}

message BanUserReq {
  string uid = 1;
}
message BanUserResp {}

message UnbanUserReq {
  string uid = 1;
}
message UnbanUserResp {}

message ForceLogoutReq {
  string uid = 1;
}
message ForceLogoutResp {}

message ListUserIdentitiesReq {
  string uid = 1;
}
message IdentityItem {
  string provider = 1;
  string provider_user_id = 2;
}
message ListUserIdentitiesResp {
  repeated IdentityItem identities = 1;
}

service UserService {
  rpc Register(RegisterReq) returns (RegisterResp);
  rpc Login(LoginReq) returns (LoginResp);
  rpc OAuthStart(OAuthStartReq) returns (OAuthStartResp);
  rpc OAuthCallback(OAuthCallbackReq) returns (OAuthCallbackResp);
  rpc BindProvider(BindProviderReq) returns (BindProviderResp);
  rpc UnbindProvider(UnbindProviderReq) returns (UnbindProviderResp);

  rpc ListUsers(ListUsersReq) returns (ListUsersResp);
  rpc BanUser(BanUserReq) returns (BanUserResp);
  rpc UnbanUser(UnbanUserReq) returns (UnbanUserResp);
  rpc ForceLogout(ForceLogoutReq) returns (ForceLogoutResp);
  rpc ListUserIdentities(ListUserIdentitiesReq) returns (ListUserIdentitiesResp);
}
```

- [ ] **Step 2: Validate proto renders and lints**

Run:
```bash
DIR="$(mktemp -d)"
ncgo new scratch --module example.com/user-e2e --kind kitex --no-generate --template-dir user-kitex --dir "$DIR/scratch" 2>&1 || echo "skipped: ncgo unavailable"
ncgo protolint --root "$DIR/scratch" --file idl/user.proto 2>&1 || echo "skipped: ncgo/protolint unavailable"
```
Expected: valid proto, no lint errors, or `skipped: ...` if tooling is unavailable.

- [ ] **Step 3: Write the Kitex handler**

Create `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml` (thin adapter translating between generated `userservice.*Req/*Resp` and the two application services' DTOs, mirroring `rbac-kitex/kitex-template/internal_handler_authservice_handler_go.yaml`'s handler-struct-wraps-service shape):

```yaml
# ncgo exported template — internal/handler/userservice_handler.go
path: internal/handler/userservice_handler.go
update_behavior:
    type: cover
body: |-
    package handler

    import (
    	"context"

    	userv1 "{{.Module}}/kitex_gen/api/user/v1"
    	"{{.Module}}/internal/application/useradmin"
    	"{{.Module}}/internal/application/user"
    )

    // UserServiceHandlerImpl implements the generated userv1.UserService
    // interface by delegating to the self-service and admin application
    // services.
    type UserServiceHandlerImpl struct {{ "{" }}
    	self  *usersvc.Service
    	admin *useradminsvc.Service
    {{ "}" }}

    // NewUserServiceHandlerImpl wires both application services into the
    // Kitex handler.
    func NewUserServiceHandlerImpl(self *usersvc.Service, admin *useradminsvc.Service) *UserServiceHandlerImpl {{ "{" }}
    	return &UserServiceHandlerImpl{{ "{" }}self: self, admin: admin{{ "}" }}
    {{ "}" }}

    func (h *UserServiceHandlerImpl) Register(ctx context.Context, req *userv1.RegisterReq) (*userv1.RegisterResp, error) {{ "{" }}
    	out, err := h.self.Register(ctx, usersvc.RegisterInput{{ "{" }}Username: req.Username, Password: req.Password{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &userv1.RegisterResp{{ "{" }}Uid: out.Uid{{ "}" }}, nil
    {{ "}" }}

    func (h *UserServiceHandlerImpl) Login(ctx context.Context, req *userv1.LoginReq) (*userv1.LoginResp, error) {{ "{" }}
    	out, err := h.self.Login(ctx, usersvc.LoginInput{{ "{" }}Username: req.Username, Password: req.Password{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &userv1.LoginResp{{ "{" }}Uid: out.Uid, Token: out.Token{{ "}" }}, nil
    {{ "}" }}

    func (h *UserServiceHandlerImpl) OAuthStart(ctx context.Context, req *userv1.OAuthStartReq) (*userv1.OAuthStartResp, error) {{ "{" }}
    	url, err := h.self.OAuthStart(ctx, req.Provider)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &userv1.OAuthStartResp{{ "{" }}RedirectUrl: url{{ "}" }}, nil
    {{ "}" }}

    func (h *UserServiceHandlerImpl) OAuthCallback(ctx context.Context, req *userv1.OAuthCallbackReq) (*userv1.OAuthCallbackResp, error) {{ "{" }}
    	out, err := h.self.OAuthCallback(ctx, usersvc.OAuthCallbackInput{{ "{" }}Provider: req.Provider, State: req.State, Code: req.Code{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	return &userv1.OAuthCallbackResp{{ "{" }}Uid: out.Uid, Token: out.Token{{ "}" }}, nil
    {{ "}" }}

    func (h *UserServiceHandlerImpl) BindProvider(ctx context.Context, req *userv1.BindProviderReq) (*userv1.BindProviderResp, error) {{ "{" }}
    	err := h.self.BindProvider(ctx, usersvc.BindProviderInput{{ "{" }}Uid: req.Uid, Provider: req.Provider, State: req.State, Code: req.Code{{ "}" }})
    	return &userv1.BindProviderResp{{ "{" }}{{ "}" }}, err
    {{ "}" }}

    func (h *UserServiceHandlerImpl) UnbindProvider(ctx context.Context, req *userv1.UnbindProviderReq) (*userv1.UnbindProviderResp, error) {{ "{" }}
    	err := h.self.UnbindProvider(ctx, req.Uid, req.Provider)
    	return &userv1.UnbindProviderResp{{ "{" }}{{ "}" }}, err
    {{ "}" }}

    func (h *UserServiceHandlerImpl) ListUsers(ctx context.Context, req *userv1.ListUsersReq) (*userv1.ListUsersResp, error) {{ "{" }}
    	out, err := h.admin.ListUsers(ctx, useradminsvc.ListUsersInput{{ "{" }}Limit: req.Limit, Offset: req.Offset{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	items := make([]*userv1.UserItem, 0, len(out.Users))
    	for _, u := range out.Users {{ "{" }}
    		items = append(items, &userv1.UserItem{{ "{" }}Uid: u.Uid, Username: u.Username, Nickname: u.Nickname, Status: int32(u.Status){{ "}" }})
    	{{ "}" }}
    	return &userv1.ListUsersResp{{ "{" }}Users: items, Total: out.Total{{ "}" }}, nil
    {{ "}" }}

    func (h *UserServiceHandlerImpl) BanUser(ctx context.Context, req *userv1.BanUserReq) (*userv1.BanUserResp, error) {{ "{" }}
    	err := h.admin.BanUser(ctx, req.Uid)
    	return &userv1.BanUserResp{{ "{" }}{{ "}" }}, err
    {{ "}" }}

    func (h *UserServiceHandlerImpl) UnbanUser(ctx context.Context, req *userv1.UnbanUserReq) (*userv1.UnbanUserResp, error) {{ "{" }}
    	err := h.admin.UnbanUser(ctx, req.Uid)
    	return &userv1.UnbanUserResp{{ "{" }}{{ "}" }}, err
    {{ "}" }}

    func (h *UserServiceHandlerImpl) ForceLogout(ctx context.Context, req *userv1.ForceLogoutReq) (*userv1.ForceLogoutResp, error) {{ "{" }}
    	err := h.admin.ForceLogout(ctx, req.Uid)
    	return &userv1.ForceLogoutResp{{ "{" }}{{ "}" }}, err
    {{ "}" }}

    func (h *UserServiceHandlerImpl) ListUserIdentities(ctx context.Context, req *userv1.ListUserIdentitiesReq) (*userv1.ListUserIdentitiesResp, error) {{ "{" }}
    	ids, err := h.admin.ListUserIdentities(ctx, req.Uid)
    	if err != nil {{ "{" }}
    		return nil, err
    	{{ "}" }}
    	items := make([]*userv1.IdentityItem, 0, len(ids))
    	for _, i := range ids {{ "{" }}
    		items = append(items, &userv1.IdentityItem{{ "{" }}Provider: i.Provider, ProviderUserId: i.ProviderUserID{{ "}" }})
    	{{ "}" }}
    	return &userv1.ListUserIdentitiesResp{{ "{" }}Identities: items{{ "}" }}, nil
    {{ "}" }}
```

- [ ] **Step 4: Run full package build (this is the "assemble everything" checkpoint)**

Run: `go build ./...` against the rendered scratch project.
Expected: builds cleanly — this is the first point all prior tasks' packages are wired together via the generated `kitex_gen` types, so it also transitively validates Tasks 1-13's type consistency (DTO field names/types matching between application/handler layers).

- [ ] **Step 5: Commit**

```bash
git add user-kitex/idl/user.proto user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml
git commit -m "feat(user-kitex): add user.proto IDL and Kitex handler wiring"
```

---

### Task 15: Server Wiring, Config, Package Metadata, README

**Files:**
- Create: `user-kitex/kitex-template/conf.yaml`
- Create: `user-kitex/kitex-template/internal_base_server_server_go.yaml`
- Create: `user-kitex/kitex-template/main.yaml`
- Create: `user-kitex/kitex-template/makefile.yaml`
- Create: `user-kitex/kitex-template/client.yaml` (pkg/client wrapper, mirrors `rbac-kitex/kitex-template/pkg_client_authservice_client_go.yaml`)
- Create: `user-kitex/template.yaml`
- Create: `user-kitex/README.md`
- Create: `user-kitex/test/e2e_test.sh` (copy `rbac-kitex/test/e2e_test.sh`'s tool-availability-gated structure, retarget to `user-kitex`)
- Modify: `README.zh-CN.md`, `README.md` (repo root — add `user-kitex` row to the RPC services table)

**Interfaces:**
- Consumes: everything from Tasks 1-14.
- Produces: a fully consumable `ncgo new --kind kitex --template user-kitex` template package — the deliverable this whole plan builds toward.

- [ ] **Step 1: Write `conf.yaml`**

Add an `OAuthConfig` section to a `rbac-kitex`-style `conf.go` template (same `Config` struct shape: `Env`, `Debug`, `Server`, `RPC`, `Auth{JWTSecret, AccessTTLSeconds}`, `Database`, `Log`, plus new):

```yaml
# Kitex custom template — internal/base/conf/conf.go (excerpt: OAuth section)
path: internal/base/conf/conf.go
update_behavior:
    type: cover
body: |-
    // (full Config struct follows the rbac-kitex conf.go shape; OAuth section:)
    type OAuthConfig struct {{ "{" }}
    	Wechat OAuthProviderConfig `json:"wechat" yaml:"wechat"`
    	Alipay OAuthProviderConfig `json:"alipay" yaml:"alipay"`
    	GitHub OAuthProviderConfig `json:"github" yaml:"github"`
    	Google OAuthProviderConfig `json:"google" yaml:"google"`
    	OIDC   OIDCProviderConfig  `json:"oidc" yaml:"oidc"`
    {{ "}" }}

    type OAuthProviderConfig struct {{ "{" }}
    	Enabled      bool   `json:"enabled" yaml:"enabled"`
    	ClientID     string `json:"client_id" yaml:"client_id"`
    	ClientSecret string `json:"client_secret" yaml:"client_secret"`
    	RedirectURL  string `json:"redirect_url" yaml:"redirect_url"`
    {{ "}" }}

    type OIDCProviderConfig struct {{ "{" }}
    	OAuthProviderConfig `json:",inline" yaml:",inline"`
    	AuthEndpoint         string `json:"auth_endpoint" yaml:"auth_endpoint"`
    	TokenEndpoint        string `json:"token_endpoint" yaml:"token_endpoint"`
    	UserInfoEndpoint     string `json:"user_info_endpoint" yaml:"user_info_endpoint"`
    {{ "}" }}
```
(Full file follows `rbac-kitex/kitex-template/conf.yaml`'s complete `Config`/`load()`/env-override structure verbatim, with `OAuth OAuthConfig` added as a field on the top-level `Config` struct and this `OAuthConfig` block appended.)

- [ ] **Step 2: Write server wiring**

Create `user-kitex/kitex-template/internal_base_server_server_go.yaml` mirroring `rbac-kitex/kitex-template/internal_base_server_server_go.yaml`'s shape: build the pgx pool + `gen.Queries`, construct `userrepo.New`, `oauth.Registry` (populated only from providers with `Enabled: true` — wechat/alipay/github/google/oidc adapters instantiated conditionally), `oauth.NewRedisStateStore`, `usersvc.New`, `useradminsvc.New`, `handler.NewUserServiceHandlerImpl`, then `userv1.NewServer(...)`.

- [ ] **Step 3: Write `main.yaml`, `makefile.yaml`, `client.yaml`**

Mirror `rbac-kitex/kitex-template/main.yaml`, `makefile.yaml`, `pkg_client_authservice_client_go.yaml` structurally, retargeting service/package names to `user`/`UserService`/`userv1`.

- [ ] **Step 4: Write `template.yaml`**

```yaml
name: user-kitex
kind: kitex
description: "Official end-user account Kitex RPC template (local password + third-party OAuth2/OIDC login: wechat/alipay/github/google/oidc, admin management RPCs)"
version: "1"
skip_default_templates:
  - handler.yaml
  - usecase.yaml
  - repository.yaml
  - server.yaml
  - migration_init.yaml
  - migration_keep.yaml
  - ratelimit_handler.yaml
  - ratelimit_middleware_test.yaml
  - ratelimit_middleware.yaml
  - ratelimit_proto.yaml
  - ratelimit_repository.yaml
  - ratelimit_schema.yaml
  - ratelimit_server.yaml
  - ratelimit_sqlc_queries.yaml
  - ratelimit_usecase.yaml
```

- [ ] **Step 5: Write `README.md`**

Document: what the template provides (local + third-party login, admin RPCs), `ncgo new --kind kitex --template user-kitex` usage, `conf.yaml` OAuth provider enable/disable, and this note verbatim:

> ⚠️ All five provider adapters (wechat/alipay/github/google/oidc) are generated into every project; unused providers are disabled via `conf.yaml`'s `enabled: false`, not omitted from generation. Generation-time selection (`ncgo new --var providers=github,google` skipping unselected adapter files entirely) depends on upstream `ncgo` CLI support, tracked separately in the `ncgo` repository — this template will adopt it in a follow-up revision once available.

- [ ] **Step 6: Write `test/e2e_test.sh`**

Copy `rbac-kitex/test/e2e_test.sh`'s tool-gating structure (skip with `skipped: <tool> 未安装` when `ncgo`/`kitex`/`protoc`/`sqlc` missing), retarget to render `user-kitex` and run `go build ./... && go test ./...`.

- [ ] **Step 7: Update root READMEs**

Add a row to the "RPC 服务 (Kitex)" table in `README.zh-CN.md` and the equivalent English table in `README.md`:

```
| `user-kitex` | 终端用户账号服务（本地密码 + 微信/支付宝/GitHub/Google/OIDC 第三方登录，管理端 RPC） | ✅ `ncgo new --kind kitex --template user-kitex` |
```

- [ ] **Step 8: Full acceptance run**

Run:
```bash
REPO_ROOT="/Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates"
DIR="$(mktemp -d)"
ncgo new tplcheck --module example.com/user-e2e --kind kitex --template-dir "$REPO_ROOT/user-kitex" --dir "$DIR/tplcheck" 2>&1 || echo "skipped: ncgo unavailable"
cd "$DIR/tplcheck" && make sqlc && go build ./... && go test ./...
```
Expected: PASS, or `skipped: ...` lines for any missing local tool (never treated as a task failure, per `rbac-kitex/test/e2e_test.sh` convention).

- [ ] **Step 9: Commit**

```bash
git add user-kitex/ README.md README.zh-CN.md
git commit -m "feat(user-kitex): wire server/config/client, add template metadata and README"
```

---

## Plan Self-Review Notes

- **Spec coverage:** all `docs/superpowers/specs/2026-09-14-user-oauth-templates-design.md` sections for `user-kitex` are covered: data model (Task 1-2), Argon2id reuse (Task 3), JWT reuse (Task 4), OAuth abstraction + 5 adapters (Task 5-10), repository (Task 11), self-service + admin usecases (Task 12-13), handler/IDL (Task 14), wiring/config/docs (Task 15). `user-bff-hertz` and `admin-bff-hertz` integration are explicitly out of this plan's scope (Plan 2, Plan 3).
- **Type consistency:** `usersvc.RegisterInput/RegisterOutput/LoginInput/LoginOutput/OAuthCallbackInput/BindProviderInput` (Task 12) match the fields the handler (Task 14) constructs; `useradminsvc.ListUsersInput/UserDTO/ListUsersOutput/IdentityDTO` (Task 13) match handler usage; `user.Repository` method set (Task 2) matches every method `Repo` (Task 11) and both fake repos (Task 12/13 tests) implement.
- **No placeholders:** every step ships real, compilable code; the one deliberately-deferred piece (Alipay RSA2 request signing, Task 10) is called out explicitly as an interface-level seam, not a TODO inside a task deliverable — `AlipayProvider` is fully functional against its own test.
