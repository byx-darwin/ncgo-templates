# 终端用户忘记密码自助重置 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `user-kitex` 新增"忘记密码"终端用户自助重置能力（邮箱链接/短信验证码二选一），全程无需登录态、无需管理员介入，并在 `user-bff-hertz` 挂载两个公开端点。

**Architecture:** 新增 `internal/infrastructure/passwordreset`（凭证存取，风格仿照已有的 `internal/infrastructure/audit`）与 `internal/infrastructure/notify`（邮件/短信发送接口 + stub 实现）两个基础设施包；`usersvc.Service` 新增 `RequestPasswordReset`/`ConfirmPasswordReset` 两个方法，复用已有的 `setPassword` 私有 helper 完成实际改密；`user-bff-hertz` 复用已验证可行的 `middleware.RateLimit` 机制新增两个 phase。

**Tech Stack:** Go, Kitex (protobuf IDL), sqlc + pgx/v5 + Postgres, Hertz, `crypto/rand`（凭证生成）、`crypto/sha256`（凭证哈希）

**Spec:** `docs/superpowers/specs/2026-09-19-forgot-password-self-reset-design.md`

## Global Constraints

- `RequestPasswordReset` 无论 identifier 是否命中账号，都返回完全相同的成功响应；`ConfirmPasswordReset` 校验失败一律返回同一个错误，不区分"不存在/已过期/已使用"（防枚举、防信息侧信道，design 已定案）
- 凭证（邮件 token / 短信验证码）落库前必须哈希（`sha256`），不存明文
- 新请求作废该用户之前未使用的所有 token（`InvalidateUserTokens`），任意时刻至多一个有效 token
- 邮件/短信真实发送能力不在本计划范围内——只做 `notify.EmailSender`/`notify.SMSSender` 接口 + 记录到 audit_log 风格的 stub 实现（`LogEmailSender`/`LogSMSSender`）
- `password_reset_tokens` 表不实现自动清理（YAGNI，与 `audit_log` 保留策略一致）
- `email`/`phone` 唯一约束用部分唯一索引（`WHERE email <> ''`），允许多个空值共存
- 修改 `user.proto` 后必须运行 `make update`（`user-kitex/Makefile`）重新生成 `kitex_gen`；修改 schema/query `.sql` 后运行 `make sqlc`
- `user-kitex/kitex-template/*.yaml` 是本仓库的模板源文件（渲染到目标项目的 `path:` 字段所指路径），本计划所有 Go/SQL 代码改动都发生在这些 `.yaml` 文件的 `body:` 块内，字面量大括号需要用 `{{ "{" }}`/`{{ "}" }}` 转义（因为该 body 本身会被 ncgo 的 Go text/template 引擎处理一次）

---

## Task 1: `users` 表 email/phone 部分唯一索引

**Files:**
- Create: `user-kitex/kitex-template/internal_db_schema_000003_user_contact_unique_sql.yaml`

**Interfaces:**
- Produces：`idx_users_email_unique`、`idx_users_phone_unique` 两个部分唯一索引（供后续 `Create`/`GetByEmail`/`GetByPhone` 隐式依赖——重复非空值会在插入时报错，但本计划的 `GetByEmail`/`GetByPhone` 本身不做应用层去重校验，依赖数据库约束兜底）

- [ ] **Step 1: 新建 schema 模板文件**

`user-kitex/kitex-template/internal_db_schema_000003_user_contact_unique_sql.yaml`：
```yaml
# ncgo exported template — internal/db/schema/000003_user_contact_unique.sql
path: internal/db/schema/000003_user_contact_unique.sql
update_behavior:
    type: cover
body: |-
    -- Partial unique indexes: multiple empty-string emails/phones may
    -- coexist (most users never set either), but any non-empty value must
    -- be unique so GetByEmail/GetByPhone can resolve to exactly one
    -- account.
    CREATE UNIQUE INDEX idx_users_email_unique ON users (email) WHERE email <> '';
    CREATE UNIQUE INDEX idx_users_phone_unique ON users (phone) WHERE phone <> '';
```

- [ ] **Step 2: 手工渲染验证迁移可执行**

在一个渲染出的 `user-kitex` 实例里把 `body` 落到 `internal/db/schema/000003_user_contact_unique.sql`，运行：
```bash
make sqlc
```
Expected: 无报错（`sqlc` 只解析 schema 生成类型，不会真的对已有数据跑约束检查；真正的重复数据冲突要等 `goose migrate-up` 对一个已有数据的库执行才会暴露，这不是本 Task 的验证范围——本模板项目没有种子数据，全新数据库上建索引必然成功）

- [ ] **Step 3: Commit**

```bash
git add user-kitex/kitex-template/internal_db_schema_000003_user_contact_unique_sql.yaml
git commit -m "feat(user-kitex): add partial unique indexes on users.email/phone"
```

---

## Task 2: `password_reset_tokens` 表 + sqlc 查询

**Files:**
- Create: `user-kitex/kitex-template/internal_db_schema_000004_password_reset_tokens_sql.yaml`
- Create: `user-kitex/kitex-template/internal_db_query_password_reset_token_sql.yaml`
- Modify: `user-kitex/kitex-template/internal_db_query_user_sql.yaml`（新增 `GetUserByEmail`/`GetUserByPhone`）

**Interfaces:**
- Produces：新表 `password_reset_tokens`；sqlc 生成的 `gen.CreatePasswordResetTokenParams`/`gen.PasswordResetToken`/`gen.GetValidPasswordResetTokenParams`/`gen.InvalidateUserPasswordResetTokensParams`/`gen.MarkPasswordResetTokenUsedParams`；`gen.GetUserByEmailParams`/`gen.GetUserByPhoneParams`（供 Task 3/4 使用）

- [ ] **Step 1: 新建 schema 模板文件**

`user-kitex/kitex-template/internal_db_schema_000004_password_reset_tokens_sql.yaml`：
```yaml
# ncgo exported template — internal/db/schema/000004_password_reset_tokens.sql
path: internal/db/schema/000004_password_reset_tokens.sql
update_behavior:
    type: cover
body: |-
    CREATE TABLE password_reset_tokens (
        id UUID PRIMARY KEY,
        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        channel TEXT NOT NULL,          -- 'email' | 'sms'
        credential_hash TEXT NOT NULL,  -- sha256 hex of the token/code, never the raw value
        expires_at TIMESTAMPTZ NOT NULL,
        used_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX idx_password_reset_tokens_user_id ON password_reset_tokens(user_id);
    CREATE UNIQUE INDEX idx_password_reset_tokens_credential_hash ON password_reset_tokens(credential_hash);
```

- [ ] **Step 2: 新建 sqlc 查询模板文件**

`user-kitex/kitex-template/internal_db_query_password_reset_token_sql.yaml`（沿用 `audit_log.sql` 已确认可行的 `sqlc.arg`/`sqlc.narg` 命名参数风格，避免位置参数与 named 参数混用导致的字段顺序问题）：
```yaml
# ncgo exported template — internal/db/query/password_reset_token.sql
path: internal/db/query/password_reset_token.sql
update_behavior:
    type: cover
body: |-
    -- name: CreatePasswordResetToken :exec
    INSERT INTO password_reset_tokens (id, user_id, channel, credential_hash, expires_at)
    VALUES (sqlc.arg('id'), sqlc.arg('user_id'), sqlc.arg('channel'), sqlc.arg('credential_hash'), sqlc.arg('expires_at'));
    -- name: GetValidPasswordResetToken :one
    SELECT * FROM password_reset_tokens
    WHERE credential_hash = sqlc.arg('credential_hash')
      AND used_at IS NULL
      AND expires_at > now();
    -- name: InvalidateUserPasswordResetTokens :exec
    UPDATE password_reset_tokens SET used_at = now()
    WHERE user_id = sqlc.arg('user_id') AND used_at IS NULL;
    -- name: MarkPasswordResetTokenUsed :exec
    UPDATE password_reset_tokens SET used_at = now() WHERE id = sqlc.arg('id');
```

- [ ] **Step 3: 在既有 `user.sql` 追加两条按 email/phone 查询用户**

修改 `user-kitex/kitex-template/internal_db_query_user_sql.yaml`，在 `-- name: GetUserByUsername :one` 那一行之后插入：
```sql
-- name: GetUserByEmail :one
SELECT * FROM users WHERE email = $1;
-- name: GetUserByPhone :one
SELECT * FROM users WHERE phone = $1;
```

- [ ] **Step 4: 手工渲染验证 SQL 语法**

在渲染出的实例里落地上述三个文件的 `body`，运行：
```bash
make sqlc
```
Expected: 无报错；`internal/db/gen/` 新增 `CreatePasswordResetToken`/`GetValidPasswordResetToken`/`InvalidateUserPasswordResetTokens`/`MarkPasswordResetTokenUsed`/`GetUserByEmail`/`GetUserByPhone` 对应方法与 `PasswordResetToken`（行结构体，含 `ID pgtype.UUID`、`UserID pgtype.UUID`、`Channel string`、`CredentialHash string`、`ExpiresAt pgtype.Timestamptz`、`UsedAt pgtype.Timestamptz`、`CreatedAt pgtype.Timestamptz`）。跑一次 `go build` 记录实际字段名，供 Task 4 对照调整。

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_db_schema_000004_password_reset_tokens_sql.yaml user-kitex/kitex-template/internal_db_query_password_reset_token_sql.yaml user-kitex/kitex-template/internal_db_query_user_sql.yaml
git commit -m "feat(user-kitex): add password_reset_tokens table, sqlc queries, and GetUserByEmail/GetUserByPhone"
```

---

## Task 3: `user.Repository` 新增 `GetByEmail`/`GetByPhone`

**Files:**
- Modify: `user-kitex/kitex-template/internal_domain_user_repository_go.yaml`
- Modify: `user-kitex/kitex-template/internal_repository_user_repo_go.yaml`
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`（`fakeRepo` 补齐两个新方法）
- Modify: `user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`（`fakeRepo` 补齐两个新方法，返回 `user.ErrNotFound` 即可——该测试套件不需要真正命中）
- Test: `user-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`

**Interfaces:**
- Consumes：Task 2 的 `gen.GetUserByEmailParams`/`gen.GetUserByPhoneParams`
- Produces：`user.Repository.GetByEmail(ctx, email string) (*User, error)`、`user.Repository.GetByPhone(ctx, phone string) (*User, error)`（未命中均返回 `user.ErrNotFound`，与既有 `GetByUsername` 行为一致）

- [ ] **Step 1: domain 接口新增两个方法**

修改 `user-kitex/kitex-template/internal_domain_user_repository_go.yaml`，在 `GetByUsername` 一行之后插入：
```go
GetByEmail(ctx context.Context, email string) (*User, error)
GetByPhone(ctx context.Context, phone string) (*User, error)
```

- [ ] **Step 2: 编写集成测试（追加到既有 postgres round-trip 测试文件）**

`user-kitex/kitex-template/internal_repository_user_repo_test_go.yaml` 在既有 `TestUserRepoPostgresRoundTrip` 函数体末尾（`DeleteIdentity` 校验之后、函数结束 `{{ "}" }}` 之前）追加：
```go
	// GetByEmail/GetByPhone round-trip.
	u2, err := user.NewLocal("integration-user-2", "argon2hash-placeholder")
	if err != nil {{ "{" }}
		t.Fatalf("NewLocal: %v", err)
	{{ "}" }}
	u2.Email = "integration@example.com"
	u2.Phone = "13800000000"
	if err := repo.Create(ctx, u2); err != nil {{ "{" }}
		t.Fatalf("Create u2: %v", err)
	{{ "}" }}
	byEmail, err := repo.GetByEmail(ctx, "integration@example.com")
	if err != nil {{ "{" }}
		t.Fatalf("GetByEmail: %v", err)
	{{ "}" }}
	if byEmail.ID != u2.ID {{ "{" }}
		t.Fatalf("GetByEmail.ID = %v, want %v", byEmail.ID, u2.ID)
	{{ "}" }}
	byPhone, err := repo.GetByPhone(ctx, "13800000000")
	if err != nil {{ "{" }}
		t.Fatalf("GetByPhone: %v", err)
	{{ "}" }}
	if byPhone.ID != u2.ID {{ "{" }}
		t.Fatalf("GetByPhone.ID = %v, want %v", byPhone.ID, u2.ID)
	{{ "}" }}
	if _, err := repo.GetByEmail(ctx, "no-such-email@example.com"); !errors.Is(err, user.ErrNotFound) {{ "{" }}
		t.Fatalf("GetByEmail unknown: expected ErrNotFound, got %v", err)
	{{ "}" }}
```
（该文件顶部已 import `"errors"`? 需要确认——若尚未 import，在 import 块补上 `"errors"`）

- [ ] **Step 3: 运行测试确认失败**

Run: `go test ./internal/repository/user/... -run TestUserRepoPostgresRoundTrip -v`（需要本地 postgres，见文件里的 `pg_isready`/`POSTGRES_DSN` 跳过逻辑；无本地 pg 时此步骤跳过，直接进入 Step 4 编码，Step 5 用 `go build` 兜底确认编译）
Expected: 编译失败（`repo.GetByEmail`/`GetByPhone` 尚不存在）

- [ ] **Step 4: 实现 Repo 方法**

修改 `user-kitex/kitex-template/internal_repository_user_repo_go.yaml`，在 `GetByUsername` 方法之后插入：
```go
func (r *Repo) GetByEmail(ctx context.Context, email string) (*user.User, error) {{ "{" }}
	row, err := r.q.GetUserByEmail(ctx, &gen.GetUserByEmailParams{{ "{" }}Email: toPgText(&email){{ "}" }})
	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
		return nil, user.ErrNotFound
	{{ "}" }}
	if err != nil {{ "{" }}
		return nil, err
	{{ "}" }}
	return toDomainUser(row), nil
{{ "}" }}

func (r *Repo) GetByPhone(ctx context.Context, phone string) (*user.User, error) {{ "{" }}
	row, err := r.q.GetUserByPhone(ctx, &gen.GetUserByPhoneParams{{ "{" }}Phone: toPgText(&phone){{ "}" }})
	if errors.Is(err, pgx.ErrNoRows) {{ "{" }}
		return nil, user.ErrNotFound
	{{ "}" }}
	if err != nil {{ "{" }}
		return nil, err
	{{ "}" }}
	return toDomainUser(row), nil
{{ "}" }}
```
**Note for the implementer:** `gen.GetUserByEmailParams`/`GetUserByPhoneParams` 的确切字段名（`Email`/`Phone` vs 其他推断名）以 Task 2 Step 4 实际 `sqlc generate` 结果为准；此查询是位置参数（`$1`，非 `sqlc.arg`），sqlc 对单参数查询通常直接用列名做字段名，但需要跑一次 `go build` 确认。

- [ ] **Step 5: 补齐两处测试文件的 `fakeRepo`**

`internal_application_user_user_service_test_go.yaml` 的 `fakeRepo` 在 `GetByUsername` 方法之后追加（并给 struct 增加 `byEmail`/`byPhone` 两个 map，`newFakeRepo()` 初始化它们，`Create` 方法里在 email/phone 非空时写入）：
```go
func (r *fakeRepo) GetByEmail(ctx context.Context, email string) (*user.User, error) {{ "{" }}
	if u, ok := r.byEmail[email]; ok {{ "{" }}
		return u, nil
	{{ "}" }}
	return nil, user.ErrNotFound
{{ "}" }}
func (r *fakeRepo) GetByPhone(ctx context.Context, phone string) (*user.User, error) {{ "{" }}
	if u, ok := r.byPhone[phone]; ok {{ "{" }}
		return u, nil
	{{ "}" }}
	return nil, user.ErrNotFound
{{ "}" }}
```
`internal_application_useradmin_admin_service_test_go.yaml` 的 `fakeRepo`（该套件不测邮箱/短信查找路径，简单返回 `ErrNotFound` 即可满足接口）：
```go
func (r *fakeRepo) GetByEmail(ctx context.Context, email string) (*user.User, error) {{ "{" }} return nil, user.ErrNotFound {{ "}" }}
func (r *fakeRepo) GetByPhone(ctx context.Context, phone string) (*user.User, error) {{ "{" }} return nil, user.ErrNotFound {{ "}" }}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `go test ./internal/repository/user/... ./internal/application/... -v`
Expected: PASS（无 postgres 环境时 `TestUserRepoPostgresRoundTrip` 显示 `skipped:`，其余测试正常跑）

- [ ] **Step 7: Commit**

```bash
git add user-kitex/kitex-template/internal_domain_user_repository_go.yaml user-kitex/kitex-template/internal_repository_user_repo_go.yaml user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml user-kitex/kitex-template/internal_repository_user_repo_test_go.yaml
git commit -m "feat(user-kitex): add Repository.GetByEmail/GetByPhone"
```

---

## Task 4: `internal/infrastructure/passwordreset` 包

**Files:**
- Create: `user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml`
- Test: `user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_test_go.yaml`

**Interfaces:**
- Consumes：Task 2 的 `gen.Queries`（`CreatePasswordResetToken`/`GetValidPasswordResetToken`/`InvalidateUserPasswordResetTokens`/`MarkPasswordResetTokenUsed`）
- Produces：
  - `passwordreset.Token{{ "{" }}ID, UserID uuid.UUID; Channel, CredentialHash string; ExpiresAt time.Time; UsedAt *time.Time; CreatedAt time.Time{{ "}" }}`
  - `passwordreset.Repository` 接口：`Create(ctx, t Token) error`、`GetValid(ctx, credentialHash string) (Token, error)`（未命中返回 `ErrNotFound`）、`InvalidateForUser(ctx, userID uuid.UUID) error`、`MarkUsed(ctx, id uuid.UUID) error`
  - `NewSQLRepository(q *gen.Queries) *SQLRepository`、`NewMemoryRepository() *MemoryRepository`（供 Task 7 测试与 server.go 无 DB 场景使用）

- [ ] **Step 1: 编写内存实现测试**

`user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_test_go.yaml`：
```yaml
# ncgo exported template — internal/infrastructure/passwordreset/repository_test.go
path: internal/infrastructure/passwordreset/repository_test.go
update_behavior:
    type: cover
body: |-
    package passwordreset_test

    import (
    	"context"
    	"testing"
    	"time"

    	"github.com/google/uuid"

    	"{{.Module}}/internal/infrastructure/passwordreset"
    )

    func TestMemoryRepository_CreateAndGetValid(t *testing.T) {{ "{" }}
    	r := passwordreset.NewMemoryRepository()
    	ctx := context.Background()
    	userID := uuid.New()
    	tok := passwordreset.Token{{ "{" }}
    		ID:             uuid.New(),
    		UserID:         userID,
    		Channel:        "email",
    		CredentialHash: "hash-1",
    		ExpiresAt:      time.Now().Add(15 * time.Minute),
    	{{ "}" }}
    	if err := r.Create(ctx, tok); err != nil {{ "{" }}
    		t.Fatalf("Create: %v", err)
    	{{ "}" }}

    	got, err := r.GetValid(ctx, "hash-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("GetValid: %v", err)
    	{{ "}" }}
    	if got.UserID != userID {{ "{" }}
    		t.Fatalf("GetValid.UserID = %v, want %v", got.UserID, userID)
    	{{ "}" }}
    {{ "}" }}

    func TestMemoryRepository_GetValid_ExpiredRejected(t *testing.T) {{ "{" }}
    	r := passwordreset.NewMemoryRepository()
    	ctx := context.Background()
    	tok := passwordreset.Token{{ "{" }}
    		ID:             uuid.New(),
    		UserID:         uuid.New(),
    		Channel:        "sms",
    		CredentialHash: "hash-expired",
    		ExpiresAt:      time.Now().Add(-1 * time.Minute),
    	{{ "}" }}
    	_ = r.Create(ctx, tok)
    	if _, err := r.GetValid(ctx, "hash-expired"); err != passwordreset.ErrNotFound {{ "{" }}
    		t.Fatalf("expected ErrNotFound for expired token, got %v", err)
    	{{ "}" }}
    {{ "}" }}

    func TestMemoryRepository_MarkUsed_ThenGetValidFails(t *testing.T) {{ "{" }}
    	r := passwordreset.NewMemoryRepository()
    	ctx := context.Background()
    	id := uuid.New()
    	tok := passwordreset.Token{{ "{" }}
    		ID:             id,
    		UserID:         uuid.New(),
    		Channel:        "email",
    		CredentialHash: "hash-used",
    		ExpiresAt:      time.Now().Add(15 * time.Minute),
    	{{ "}" }}
    	_ = r.Create(ctx, tok)
    	if err := r.MarkUsed(ctx, id); err != nil {{ "{" }}
    		t.Fatalf("MarkUsed: %v", err)
    	{{ "}" }}
    	if _, err := r.GetValid(ctx, "hash-used"); err != passwordreset.ErrNotFound {{ "{" }}
    		t.Fatalf("expected ErrNotFound for used token, got %v", err)
    	{{ "}" }}
    {{ "}" }}

    func TestMemoryRepository_InvalidateForUser_InvalidatesAllUnused(t *testing.T) {{ "{" }}
    	r := passwordreset.NewMemoryRepository()
    	ctx := context.Background()
    	userID := uuid.New()
    	tok1 := passwordreset.Token{{ "{" }}ID: uuid.New(), UserID: userID, Channel: "email", CredentialHash: "hash-a", ExpiresAt: time.Now().Add(15 * time.Minute){{ "}" }}
    	tok2 := passwordreset.Token{{ "{" }}ID: uuid.New(), UserID: userID, Channel: "email", CredentialHash: "hash-b", ExpiresAt: time.Now().Add(15 * time.Minute){{ "}" }}
    	_ = r.Create(ctx, tok1)
    	_ = r.Create(ctx, tok2)

    	if err := r.InvalidateForUser(ctx, userID); err != nil {{ "{" }}
    		t.Fatalf("InvalidateForUser: %v", err)
    	{{ "}" }}
    	if _, err := r.GetValid(ctx, "hash-a"); err != passwordreset.ErrNotFound {{ "{" }}
    		t.Fatalf("expected hash-a invalidated, got %v", err)
    	{{ "}" }}
    	if _, err := r.GetValid(ctx, "hash-b"); err != passwordreset.ErrNotFound {{ "{" }}
    		t.Fatalf("expected hash-b invalidated, got %v", err)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `go test ./internal/infrastructure/passwordreset/... -v`
Expected: 编译失败（包不存在）

- [ ] **Step 3: 实现 repository.go**

`user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml`（`toPgText`/`toPgTimestamptz`/`fromPgTimestamptz` 复用与 `internal/infrastructure/audit` 相同的手写-helper 模式——本包同样不依赖 `internal/repository/user`，独立复制这几个 helper）：
```yaml
# ncgo exported template — internal/infrastructure/passwordreset/repository.go
path: internal/infrastructure/passwordreset/repository.go
update_behavior:
    type: cover
body: |-
    package passwordreset

    import (
    	"context"
    	"errors"
    	"sync"
    	"time"

    	"github.com/google/uuid"
    	"github.com/jackc/pgx/v5"
    	"github.com/jackc/pgx/v5/pgtype"

    	"{{.Module}}/internal/db/gen"
    )

    // Token is a single password-reset credential (email link token or SMS
    // code). CredentialHash is the sha256 hex of the raw credential — the
    // raw value is never persisted.
    type Token struct {{ "{" }}
    	ID             uuid.UUID
    	UserID         uuid.UUID
    	Channel        string
    	CredentialHash string
    	ExpiresAt      time.Time
    	UsedAt         *time.Time
    	CreatedAt      time.Time
    {{ "}" }}

    // ErrNotFound is returned when no valid (unused, unexpired) token
    // matches the given credential hash, or an operation targets a token
    // that does not exist.
    var ErrNotFound = errors.New("passwordreset: not found")

    // Repository persists and validates password-reset tokens.
    type Repository interface {{ "{" }}
    	Create(ctx context.Context, t Token) error
    	// GetValid returns the token matching credentialHash if, and only
    	// if, it is unused and unexpired. Any other case (no match, used,
    	// expired) returns ErrNotFound — callers must not distinguish these
    	// to avoid leaking which condition failed (see design doc's
    	// anti-enumeration section).
    	GetValid(ctx context.Context, credentialHash string) (Token, error)
    	// InvalidateForUser marks every unused token belonging to userID as
    	// used, so a new reset request supersedes any earlier one.
    	InvalidateForUser(ctx context.Context, userID uuid.UUID) error
    	MarkUsed(ctx context.Context, id uuid.UUID) error
    {{ "}" }}

    func toPgUUID(id uuid.UUID) pgtype.UUID {{ "{" }}
    	return pgtype.UUID{{ "{" }}Bytes: id, Valid: true{{ "}" }}
    {{ "}" }}

    func toPgText(s string) pgtype.Text {{ "{" }}
    	return pgtype.Text{{ "{" }}String: s, Valid: true{{ "}" }}
    {{ "}" }}

    func toPgTimestamptz(t time.Time) pgtype.Timestamptz {{ "{" }}
    	return pgtype.Timestamptz{{ "{" }}Time: t, Valid: true{{ "}" }}
    {{ "}" }}

    func fromPgTimestamptz(t pgtype.Timestamptz) time.Time {{ "{" }}
    	return t.Time
    {{ "}" }}

    // SQLRepository persists tokens via sqlc.
    type SQLRepository struct {{ "{" }}
    	q *gen.Queries
    {{ "}" }}

    // NewSQLRepository creates a passwordreset repository backed by the
    // password_reset_tokens table.
    func NewSQLRepository(q *gen.Queries) *SQLRepository {{ "{" }}
    	return &SQLRepository{{ "{" }}q: q{{ "}" }}
    {{ "}" }}

    func (r *SQLRepository) Create(ctx context.Context, t Token) error {{ "{" }}
    	return r.q.CreatePasswordResetToken(ctx, &gen.CreatePasswordResetTokenParams{{ "{" }}
    		ID:             toPgUUID(t.ID),
    		UserID:         toPgUUID(t.UserID),
    		Channel:        t.Channel,
    		CredentialHash: t.CredentialHash,
    		ExpiresAt:      toPgTimestamptz(t.ExpiresAt),
    	{{ "}" }})
    {{ "}" }}

    func (r *SQLRepository) GetValid(ctx context.Context, credentialHash string) (Token, error) {{ "{" }}
    	row, err := r.q.GetValidPasswordResetToken(ctx, &gen.GetValidPasswordResetTokenParams{{ "{" }}CredentialHash: credentialHash{{ "}" }})
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

    func (r *SQLRepository) InvalidateForUser(ctx context.Context, userID uuid.UUID) error {{ "{" }}
    	return r.q.InvalidateUserPasswordResetTokens(ctx, &gen.InvalidateUserPasswordResetTokensParams{{ "{" }}UserID: toPgUUID(userID){{ "}" }})
    {{ "}" }}

    func (r *SQLRepository) MarkUsed(ctx context.Context, id uuid.UUID) error {{ "{" }}
    	return r.q.MarkPasswordResetTokenUsed(ctx, &gen.MarkPasswordResetTokenUsedParams{{ "{" }}ID: toPgUUID(id){{ "}" }})
    {{ "}" }}

    // MemoryRepository is a test-only in-memory implementation, and also
    // backs server.go's no-database startup path (mirrors audit.MemoryWriter).
    type MemoryRepository struct {{ "{" }}
    	mu     sync.Mutex
    	tokens map[uuid.UUID]Token
    {{ "}" }}

    // NewMemoryRepository creates an in-memory passwordreset repository.
    func NewMemoryRepository() *MemoryRepository {{ "{" }}
    	return &MemoryRepository{{ "{" }}tokens: map[uuid.UUID]Token{{ "{" }}{{ "}" }}{{ "}" }}
    {{ "}" }}

    func (r *MemoryRepository) Create(ctx context.Context, t Token) error {{ "{" }}
    	r.mu.Lock()
    	defer r.mu.Unlock()
    	r.tokens[t.ID] = t
    	return nil
    {{ "}" }}

    func (r *MemoryRepository) GetValid(ctx context.Context, credentialHash string) (Token, error) {{ "{" }}
    	r.mu.Lock()
    	defer r.mu.Unlock()
    	now := time.Now()
    	for _, t := range r.tokens {{ "{" }}
    		if t.CredentialHash != credentialHash {{ "{" }}
    			continue
    		{{ "}" }}
    		if t.UsedAt != nil || now.After(t.ExpiresAt) {{ "{" }}
    			return Token{{ "{" }}{{ "}" }}, ErrNotFound
    		{{ "}" }}
    		return t, nil
    	{{ "}" }}
    	return Token{{ "{" }}{{ "}" }}, ErrNotFound
    {{ "}" }}

    func (r *MemoryRepository) InvalidateForUser(ctx context.Context, userID uuid.UUID) error {{ "{" }}
    	r.mu.Lock()
    	defer r.mu.Unlock()
    	now := time.Now()
    	for id, t := range r.tokens {{ "{" }}
    		if t.UserID == userID && t.UsedAt == nil {{ "{" }}
    			t.UsedAt = &now
    			r.tokens[id] = t
    		{{ "}" }}
    	{{ "}" }}
    	return nil
    {{ "}" }}

    func (r *MemoryRepository) MarkUsed(ctx context.Context, id uuid.UUID) error {{ "{" }}
    	r.mu.Lock()
    	defer r.mu.Unlock()
    	t, ok := r.tokens[id]
    	if !ok {{ "{" }}
    		return ErrNotFound
    	{{ "}" }}
    	now := time.Now()
    	t.UsedAt = &now
    	r.tokens[id] = t
    	return nil
    {{ "}" }}
```
**Note for the implementer:** `gen.GetValidPasswordResetTokenParams`/`CreatePasswordResetTokenParams` 等字段名以 Task 2 Step 4 实际生成结果为准（本 Step 假定 sqlc 用 `sqlc.arg('x')` 时生成驼峰字段名 `X`，与 `audit_log.sql` 的既有生成结果模式一致）。

- [ ] **Step 4: 运行测试确认通过**

Run: `go test ./internal/infrastructure/passwordreset/... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_go.yaml user-kitex/kitex-template/internal_infrastructure_passwordreset_repository_test_go.yaml
git commit -m "feat(user-kitex): add passwordreset.Repository (SQL + in-memory)"
```

---

## Task 5: `internal/infrastructure/notify` 包（邮件/短信发送接口 + stub）

**Files:**
- Create: `user-kitex/kitex-template/internal_infrastructure_notify_sender_go.yaml`
- Test: `user-kitex/kitex-template/internal_infrastructure_notify_sender_test_go.yaml`

**Interfaces:**
- Produces：`notify.EmailSender`（`SendPasswordResetLink(ctx, to, resetLink string) error`）、`notify.SMSSender`（`SendPasswordResetCode(ctx, to, code string) error`）；`notify.NewLogEmailSender(logger... )`/`NewLogSMSSender(...)` 及内存记录版 `*LogEmailSender`/`*LogSMSSender` 的 `Sent()` 访问器供测试断言

- [ ] **Step 1: 编写测试**

`user-kitex/kitex-template/internal_infrastructure_notify_sender_test_go.yaml`：
```yaml
# ncgo exported template — internal/infrastructure/notify/sender_test.go
path: internal/infrastructure/notify/sender_test.go
update_behavior:
    type: cover
body: |-
    package notify_test

    import (
    	"context"
    	"testing"

    	"{{.Module}}/internal/infrastructure/notify"
    )

    func TestLogEmailSender_RecordsSentLink(t *testing.T) {{ "{" }}
    	s := notify.NewLogEmailSender()
    	if err := s.SendPasswordResetLink(context.Background(), "alice@example.com", "https://example.com/reset?token=abc"); err != nil {{ "{" }}
    		t.Fatalf("SendPasswordResetLink: %v", err)
    	{{ "}" }}
    	sent := s.Sent()
    	if len(sent) != 1 || sent[0].To != "alice@example.com" || sent[0].Link != "https://example.com/reset?token=abc" {{ "{" }}
    		t.Fatalf("unexpected sent record: %+v", sent)
    	{{ "}" }}
    {{ "}" }}

    func TestLogSMSSender_RecordsSentCode(t *testing.T) {{ "{" }}
    	s := notify.NewLogSMSSender()
    	if err := s.SendPasswordResetCode(context.Background(), "13800000000", "123456"); err != nil {{ "{" }}
    		t.Fatalf("SendPasswordResetCode: %v", err)
    	{{ "}" }}
    	sent := s.Sent()
    	if len(sent) != 1 || sent[0].To != "13800000000" || sent[0].Code != "123456" {{ "{" }}
    		t.Fatalf("unexpected sent record: %+v", sent)
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `go test ./internal/infrastructure/notify/... -v`
Expected: 编译失败（包不存在）

- [ ] **Step 3: 实现 sender.go**

`user-kitex/kitex-template/internal_infrastructure_notify_sender_go.yaml`：
```yaml
# ncgo exported template — internal/infrastructure/notify/sender.go
path: internal/infrastructure/notify/sender.go
update_behavior:
    type: cover
body: |-
    package notify

    import (
    	"context"
    	"log"
    	"sync"
    )

    // EmailSender delivers a password-reset link to an email address.
    type EmailSender interface {{ "{" }}
    	SendPasswordResetLink(ctx context.Context, to, resetLink string) error
    {{ "}" }}

    // SMSSender delivers a password-reset verification code to a phone number.
    type SMSSender interface {{ "{" }}
    	SendPasswordResetCode(ctx context.Context, to, code string) error
    {{ "}" }}

    // SentEmail records one LogEmailSender delivery, for test assertions.
    type SentEmail struct {{ "{" }}
    	To   string
    	Link string
    {{ "}" }}

    // LogEmailSender is a stub EmailSender: it only logs and records what
    // would have been sent. Real SMTP/gateway integration is out of scope
    // for this template — swap this out via conf.Notify.Provider once a
    // real provider account is available.
    type LogEmailSender struct {{ "{" }}
    	mu   sync.Mutex
    	sent []SentEmail
    {{ "}" }}

    // NewLogEmailSender creates a stub EmailSender.
    func NewLogEmailSender() *LogEmailSender {{ "{" }}
    	return &LogEmailSender{{ "{" }}{{ "}" }}
    {{ "}" }}

    func (s *LogEmailSender) SendPasswordResetLink(ctx context.Context, to, resetLink string) error {{ "{" }}
    	log.Printf("notify: [stub email] password reset link for %s: %s", to, resetLink)
    	s.mu.Lock()
    	defer s.mu.Unlock()
    	s.sent = append(s.sent, SentEmail{{ "{" }}To: to, Link: resetLink{{ "}" }})
    	return nil
    {{ "}" }}

    // Sent returns a copy of the recorded deliveries.
    func (s *LogEmailSender) Sent() []SentEmail {{ "{" }}
    	s.mu.Lock()
    	defer s.mu.Unlock()
    	out := make([]SentEmail, len(s.sent))
    	copy(out, s.sent)
    	return out
    {{ "}" }}

    // SentSMS records one LogSMSSender delivery, for test assertions.
    type SentSMS struct {{ "{" }}
    	To   string
    	Code string
    {{ "}" }}

    // LogSMSSender is a stub SMSSender — see LogEmailSender's doc comment.
    type LogSMSSender struct {{ "{" }}
    	mu   sync.Mutex
    	sent []SentSMS
    {{ "}" }}

    // NewLogSMSSender creates a stub SMSSender.
    func NewLogSMSSender() *LogSMSSender {{ "{" }}
    	return &LogSMSSender{{ "{" }}{{ "}" }}
    {{ "}" }}

    func (s *LogSMSSender) SendPasswordResetCode(ctx context.Context, to, code string) error {{ "{" }}
    	log.Printf("notify: [stub sms] password reset code for %s: %s", to, code)
    	s.mu.Lock()
    	defer s.mu.Unlock()
    	s.sent = append(s.sent, SentSMS{{ "{" }}To: to, Code: code{{ "}" }})
    	return nil
    {{ "}" }}

    // Sent returns a copy of the recorded deliveries.
    func (s *LogSMSSender) Sent() []SentSMS {{ "{" }}
    	s.mu.Lock()
    	defer s.mu.Unlock()
    	out := make([]SentSMS, len(s.sent))
    	copy(out, s.sent)
    	return out
    {{ "}" }}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `go test ./internal/infrastructure/notify/... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_infrastructure_notify_sender_go.yaml user-kitex/kitex-template/internal_infrastructure_notify_sender_test_go.yaml
git commit -m "feat(user-kitex): add notify.EmailSender/SMSSender interfaces with log-only stub implementations"
```

---

## Task 6: `user.proto` 新增 RPC 定义

**Files:**
- Modify: `user-kitex/idl/user.proto`

**Interfaces:**
- Produces：`RequestPasswordResetReq/Resp`、`ConfirmPasswordResetReq/Resp` message；`UserService` 新增两个 rpc（供 Task 8 handler 使用）

- [ ] **Step 1: 在 `ListAuditLogsResp {}` 之后、`service UserService` 之前插入新 message**

```proto
message RequestPasswordResetReq {
  // identifier is an email address or phone number, per channel.
  string identifier = 1;
  string channel = 2; // "email" | "sms" — explicit, never inferred from identifier's format
}
message RequestPasswordResetResp {} // always empty on success; success is returned whether or not identifier matched an account

message ConfirmPasswordResetReq {
  string credential = 1;    // the email link's token, or the SMS code
  string new_password = 2;
}
message ConfirmPasswordResetResp {}
```

- [ ] **Step 2: 在 `service UserService {}` 块内 `ListAuditLogs` 一行之后新增两行 rpc 声明**

```proto
  rpc RequestPasswordReset(RequestPasswordResetReq) returns (RequestPasswordResetResp);
  rpc ConfirmPasswordReset(ConfirmPasswordResetReq) returns (ConfirmPasswordResetResp);
```

- [ ] **Step 3: 重新生成 kitex_gen（在渲染出的具体项目实例中）**

Run: `make update`
Expected: `kitex_gen/api/user/v1/` 下新增 `RequestPasswordResetReq`/`ConfirmPasswordResetReq` 等 Go 结构体，`kitex_gen/api/user/v1/userservice` 客户端接口新增两个方法签名。

- [ ] **Step 4: Commit**

```bash
git add user-kitex/idl/user.proto
git commit -m "feat(user-kitex): add RequestPasswordReset/ConfirmPasswordReset to user.proto"
```

---

## Task 7: `usersvc` 实现 `RequestPasswordReset` / `ConfirmPasswordReset`

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`

**Interfaces:**
- Consumes：Task 3 的 `user.Repository.GetByEmail`/`GetByPhone`；Task 4 的 `passwordreset.Repository`；Task 5 的 `notify.EmailSender`/`notify.SMSSender`；既有 `s.setPassword`（复用，`oldPassword=nil` 路径）
- Produces：`usersvc.Service.RequestPasswordReset(ctx, identifier, channel string) error`（恒定返回 `nil`，内部吞掉除参数校验外的一切错误，符合防枚举设计）、`usersvc.Service.ConfirmPasswordReset(ctx, credential, newPassword string) error`；`usersvc.New` 签名新增 `resetRepo passwordreset.Repository, emailSender notify.EmailSender, smsSender notify.SMSSender` 三个参数

- [ ] **Step 1: 编写测试**

在 `internal_application_user_user_service_test_go.yaml` 末尾追加（复用既有 `fakeRepo`/`fakeBlacklist`；新增 `newTestServiceWithReset` 辅助函数返回额外的 `passwordreset.MemoryRepository`/`*notify.LogEmailSender`/`*notify.LogSMSSender` 供断言）：
```go
func newTestServiceWithReset() (*Service, *passwordreset.MemoryRepository, *notify.LogEmailSender, *notify.LogSMSSender, *audit.MemoryWriter) {{ "{" }}
	rr := passwordreset.NewMemoryRepository()
	es := notify.NewLogEmailSender()
	ss := notify.NewLogSMSSender()
	aw := audit.NewMemoryWriter()
	svc := New(newFakeRepo(), auth.NewJWTManager("test-secret"), oauth.Registry{{ "{" }}{{ "}" }}, nil, time.Hour, aw, &fakeBlacklist{{ "{" }}{{ "}" }}, rr, es, ss)
	return svc, rr, es, ss, aw
{{ "}" }}

func TestRequestPasswordReset_UnknownIdentifier_StillSucceedsNoSend(t *testing.T) {{ "{" }}
	svc, _, es, ss, aw := newTestServiceWithReset()
	if err := svc.RequestPasswordReset(context.Background(), "nobody@example.com", "email"); err != nil {{ "{" }}
		t.Fatalf("expected nil error for unknown identifier, got %v", err)
	{{ "}" }}
	if len(es.Sent()) != 0 || len(ss.Sent()) != 0 {{ "{" }}
		t.Fatal("expected no send for unknown identifier")
	{{ "}" }}
	if len(aw.Entries()) != 0 {{ "{" }}
		t.Fatal("expected no audit entry for unknown identifier")
	{{ "}" }}
{{ "}" }}

func TestRequestPasswordReset_KnownEmail_SendsAndAudits(t *testing.T) {{ "{" }}
	svc, rr, es, _, aw := newTestServiceWithReset()
	ctx := context.Background()
	regOut, err := svc.Register(ctx, RegisterInput{{ "{" }}Username: "alice", Password: "correct horse battery staple"{{ "}" }})
	if err != nil {{ "{" }}
		t.Fatalf("register: %v", err)
	{{ "}" }}
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "alice@example.com"

	if err := svc.RequestPasswordReset(ctx, "alice@example.com", "email"); err != nil {{ "{" }}
		t.Fatalf("expected nil error, got %v", err)
	{{ "}" }}
	sent := es.Sent()
	if len(sent) != 1 || sent[0].To != "alice@example.com" {{ "{" }}
		t.Fatalf("expected 1 email sent to alice@example.com, got %+v", sent)
	{{ "}" }}
	entries := aw.Entries()
	if len(entries) != 1 || entries[0].Action != "user.password_reset_requested" {{ "{" }}
		t.Fatalf("expected 1 audit entry action=user.password_reset_requested, got %+v", entries)
	{{ "}" }}
	if _, err := rr.GetValid(ctx, hashCredential(extractTokenFromLink(t, sent[0].Link))); err != nil {{ "{" }}
		t.Fatalf("expected a valid stored token matching the sent link, got err: %v", err)
	{{ "}" }}
{{ "}" }}

func TestRequestPasswordReset_SecondRequest_InvalidatesFirstToken(t *testing.T) {{ "{" }}
	svc, rr, es, _, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "bob", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "bob@example.com"

	_ = svc.RequestPasswordReset(ctx, "bob@example.com", "email")
	firstLink := es.Sent()[0].Link
	firstHash := hashCredential(extractTokenFromLink(t, firstLink))

	_ = svc.RequestPasswordReset(ctx, "bob@example.com", "email")

	if _, err := rr.GetValid(ctx, firstHash); err != passwordreset.ErrNotFound {{ "{" }}
		t.Fatalf("expected first token invalidated by second request, got err=%v", err)
	{{ "}" }}
{{ "}" }}

func TestConfirmPasswordReset_ValidCredential_UpdatesPasswordAndAudits(t *testing.T) {{ "{" }}
	svc, _, es, _, aw := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "carol", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "carol@example.com"
	_ = svc.RequestPasswordReset(ctx, "carol@example.com", "email")
	token := extractTokenFromLink(t, es.Sent()[0].Link)

	if err := svc.ConfirmPasswordReset(ctx, token, "brand-new-password-1"); err != nil {{ "{" }}
		t.Fatalf("ConfirmPasswordReset: %v", err)
	{{ "}" }}
	updated, _ := svc.repo.GetByID(ctx, uid)
	if ok, _ := auth.VerifyPassword("brand-new-password-1", *updated.PasswordHash); !ok {{ "{" }}
		t.Fatal("password was not updated")
	{{ "}" }}
	found := false
	for _, e := range aw.Entries() {{ "{" }}
		if e.Action == "user.password_reset_confirmed" {{ "{" }}
			found = true
		{{ "}" }}
	{{ "}" }}
	if !found {{ "{" }}
		t.Fatal("expected a user.password_reset_confirmed audit entry")
	{{ "}" }}
{{ "}" }}

func TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, _, _ := newTestServiceWithReset()
	if err := svc.ConfirmPasswordReset(context.Background(), "no-such-token", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error for unknown credential")
	{{ "}" }}
{{ "}" }}

func TestConfirmPasswordReset_ReusedCredential_Rejected(t *testing.T) {{ "{" }}
	svc, _, es, _, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "dave", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "dave@example.com"
	_ = svc.RequestPasswordReset(ctx, "dave@example.com", "email")
	token := extractTokenFromLink(t, es.Sent()[0].Link)

	if err := svc.ConfirmPasswordReset(ctx, token, "brand-new-password-1"); err != nil {{ "{" }}
		t.Fatalf("first confirm: %v", err)
	{{ "}" }}
	if err := svc.ConfirmPasswordReset(ctx, token, "another-password-2"); err == nil {{ "{" }}
		t.Fatal("expected reused credential to be rejected")
	{{ "}" }}
{{ "}" }}

// extractTokenFromLink pulls the ?token= query value out of a reset link
// produced by RequestPasswordReset, for tests that need the raw credential
// to exercise ConfirmPasswordReset (which only ever receives the raw value
// from a real caller, never the hash).
func extractTokenFromLink(t *testing.T, link string) string {{ "{" }}
	t.Helper()
	u, err := url.Parse(link)
	if err != nil {{ "{" }}
		t.Fatalf("parse link %q: %v", link, err)
	{{ "}" }}
	tok := u.Query().Get("token")
	if tok == "" {{ "{" }}
		t.Fatalf("link %q has no token query param", link)
	{{ "}" }}
	return tok
{{ "}" }}
```
**Note for the implementer:** 上面测试直接访问了 `svc.repo`/`u.Email = ...`（依赖 `fakeRepo` 返回的是共享指针，赋值后对存储中的同一个 `*user.User` 生效——`fakeRepo.byID`/`Create` 目前存的就是传入指针本身，需要确认 `Register`→`user.NewLocal`→`repo.Create` 链路上没有做值拷贝；若 `fakeRepo.GetByID` 返回的不是同一底层指针，测试需要改为先 `GetByID` 拿到指针再改字段，或者改造 `fakeRepo` 补一个 `SetEmail`/直接改 map）。测试文件顶部 import 需要新增 `"net/url"`、`"{{.Module}}/internal/infrastructure/notify"`、`"{{.Module}}/internal/infrastructure/passwordreset"`。`hashCredential` 是 Step 3 里新增的 usecase 内部函数（小写未导出）——因为测试文件与 `user_service.go` 同包（`package usersvc`），测试可以直接调用它。

- [ ] **Step 2: 运行测试确认失败**

Run: `go test ./internal/application/user/... -run "TestRequestPasswordReset|TestConfirmPasswordReset" -v`
Expected: 编译失败（`RequestPasswordReset`/`ConfirmPasswordReset`/`hashCredential`/`New` 新签名均不存在）

- [ ] **Step 3: 实现**

修改 `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`：

1. import 新增：
```go
"crypto/rand"
"crypto/sha256"
"encoding/base64"
"encoding/hex"
"fmt"

"{{.Module}}/internal/infrastructure/notify"
"{{.Module}}/internal/infrastructure/passwordreset"
```
2. `Service` struct 新增三个字段：`resetRepo passwordreset.Repository`、`emailSender notify.EmailSender`、`smsSender notify.SMSSender`
3. `New` 签名与函数体追加三个参数：
```go
func New(repo user.Repository, jwt *auth.JWTManager, providers oauth.Registry, stateStore oauth.StateStore, tokenTTL time.Duration, auditWriter audit.Writer, blacklist Blacklist, resetRepo passwordreset.Repository, emailSender notify.EmailSender, smsSender notify.SMSSender) *Service {{ "{" }}
	return &Service{{ "{" }}repo: repo, jwt: jwt, providers: providers, stateStore: stateStore, tokenTTL: tokenTTL, audit: auditWriter, blacklist: blacklist, resetRepo: resetRepo, emailSender: emailSender, smsSender: smsSender{{ "}" }}
{{ "}" }}
```
4. 新增常量：
```go
const (
	emailResetTokenTTL = 15 * time.Minute
	smsResetCodeTTL    = 5 * time.Minute
)
```
5. 新增 helper 与两个方法（追加到文件末尾）：
```go
// hashCredential returns the sha256 hex digest stored in
// password_reset_tokens.credential_hash — the raw credential (link token
// or SMS code) is never persisted.
func hashCredential(raw string) string {{ "{" }}
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
{{ "}" }}

// generateEmailToken returns a 32-byte crypto/rand token, base64url-encoded
// for safe inclusion in a URL query parameter.
func generateEmailToken() (string, error) {{ "{" }}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {{ "{" }}
		return "", err
	{{ "}" }}
	return base64.RawURLEncoding.EncodeToString(b), nil
{{ "}" }}

// generateSMSCode returns a 6-digit numeric code using crypto/rand (not
// math/rand — this is a security credential, not a UI nonce).
func generateSMSCode() (string, error) {{ "{" }}
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {{ "{" }}
		return "", err
	{{ "}" }}
	n := uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
	return fmt.Sprintf("%06d", n%1000000), nil
{{ "}" }}

// RequestPasswordReset looks up identifier by channel ("email" or "sms")
// and, if it matches an account, invalidates any outstanding reset token
// for that user, issues a new one, and sends it. It ALWAYS returns nil —
// whether identifier matched no account, matched one, or the send failed
// — so the response carries no signal about account existence (see design
// doc's anti-enumeration section). Unexpected errors are logged, not
// returned.
func (s *Service) RequestPasswordReset(ctx context.Context, identifier, channel string) error {{ "{" }}
	var (
		u   *user.User
		err error
	{{ "}" }}
	switch channel {{ "{" }}
	case "email":
		u, err = s.repo.GetByEmail(ctx, identifier)
	case "sms":
		u, err = s.repo.GetByPhone(ctx, identifier)
	default:
		return errors.New("user: channel must be email or sms")
	{{ "}" }}
	if err != nil {{ "{" }}
		if !errors.Is(err, user.ErrNotFound) {{ "{" }}
			log.Printf("user: RequestPasswordReset lookup failed: %v", err)
		{{ "}" }}
		return nil
	{{ "}" }}

	if err := s.resetRepo.InvalidateForUser(ctx, u.ID); err != nil {{ "{" }}
		log.Printf("user: InvalidateForUser failed: %v", err)
		return nil
	{{ "}" }}

	id := uuid.New()
	var (
		raw string
		ttl time.Duration
	{{ "}" }}
	if channel == "email" {{ "{" }}
		raw, err = generateEmailToken()
		ttl = emailResetTokenTTL
	{{ "}" }} else {{ "{" }}
		raw, err = generateSMSCode()
		ttl = smsResetCodeTTL
	{{ "}" }}
	if err != nil {{ "{" }}
		log.Printf("user: generate reset credential failed: %v", err)
		return nil
	{{ "}" }}

	if err := s.resetRepo.Create(ctx, passwordreset.Token{{ "{" }}
		ID:             id,
		UserID:         u.ID,
		Channel:        channel,
		CredentialHash: hashCredential(raw),
		ExpiresAt:      time.Now().Add(ttl),
	{{ "}" }}); err != nil {{ "{" }}
		log.Printf("user: store reset token failed: %v", err)
		return nil
	{{ "}" }}

	if channel == "email" {{ "{" }}
		link := fmt.Sprintf("https://%s/reset-password?token=%s", "example.com", raw) // TODO: replace host with cfg.Notify.ResetLinkHost once real sending is wired up
		if err := s.emailSender.SendPasswordResetLink(ctx, identifier, link); err != nil {{ "{" }}
			log.Printf("user: send reset email failed: %v", err)
			return nil
		{{ "}" }}
	{{ "}" }} else {{ "{" }}
		if err := s.smsSender.SendPasswordResetCode(ctx, identifier, raw); err != nil {{ "{" }}
			log.Printf("user: send reset sms failed: %v", err)
			return nil
		{{ "}" }}
	{{ "}" }}

	_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: u.ID.String(), Action: "user.password_reset_requested", DetailJSON: fmt.Sprintf(`{{ "{" }}"channel":%q{{ "}" }}`, channel){{ "}" }})
	return nil
{{ "}" }}

// ConfirmPasswordReset validates credential against the stored token,
// then sets uid's password to newPassword via the shared setPassword
// helper (same path as admin-forced reset). All failure modes — no
// matching token, expired, already used — return the same generic error
// so a caller cannot distinguish them (see design doc's anti-enumeration
// section).
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, newPassword string) error {{ "{" }}
	tok, err := s.resetRepo.GetValid(ctx, hashCredential(credential))
	if err != nil {{ "{" }}
		return errors.New("user: reset credential is invalid or expired")
	{{ "}" }}
	if err := s.setPassword(ctx, tok.UserID.String(), nil, newPassword, "user.password_reset_confirmed", "", "", ""); err != nil {{ "{" }}
		return err
	{{ "}" }}
	_ = s.resetRepo.MarkUsed(ctx, tok.ID)
	return nil
{{ "}" }}
```
**Note for the implementer:** `link` 里硬编码的 `"example.com"` 域名是模板占位——真实项目渲染后应改为从配置读取（如 `cfg.Notify.ResetLinkHost`），本计划把这个配置项留给 `notify` 真实接入的后续 Issue（design doc 的 Open Follow-ups 已注明发送能力本身不在本计划范围），这里只保证接口调用形状正确、可编译、可测试。若 review 认为裸域名不可接受，可以在本 Task 内改为读取一个新增的 `cfg.Notify.ResetLinkBaseURL` 配置项（`user-kitex` 的 `conf.yaml` 新增 `Notify NotifyConfig` 节，`NotifyConfig{{ "{" }}ResetLinkBaseURL string{{ "}" }}`），但这会牵动 conf.yaml/conf_dev.yaml 与 server.go 的额外改动——若时间允许建议一并做，不允许则按占位符实现，不影响本计划其余任务。

- [ ] **Step 4: 运行测试确认通过**

Run: `go test ./internal/application/user/... -v`
Expected: PASS（含既有测试——注意 Step 3 改了 `New` 签名，检查该测试文件内所有 `usersvc.New(...)`/`New(...)` 调用点是否都需要同步加上三个新参数；本 Task 已经通过新增 `newTestServiceWithReset` 覆盖新路径，既有 `newTestServiceWithAudit`/`newTestService` 等旧 helper 也必须同步补上三个新参数，否则编译失败）

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_go.yaml user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "feat(user-kitex): add usersvc.RequestPasswordReset/ConfirmPasswordReset"
```

---

## Task 8: Handler 接入两个新 RPC + server.go 装配

**Files:**
- Modify: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`
- Modify: `user-kitex/kitex-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes：Task 6 生成的 `userv1.RequestPasswordResetReq/Resp`、`userv1.ConfirmPasswordResetReq/Resp`；Task 7 的 `usersvc.Service.RequestPasswordReset`/`ConfirmPasswordReset`；Task 4 的 `passwordreset.NewSQLRepository`/`NewMemoryRepository`；Task 5 的 `notify.NewLogEmailSender`/`NewLogSMSSender`
- Produces：`UserServiceHandlerImpl.RequestPasswordReset`/`ConfirmPasswordReset` 方法

- [ ] **Step 1: Handler 新增两个方法**

在 `internal_handler_userservice_handler_go.yaml` 的 `body` 末尾（`ListAuditLogs` 方法之后）追加：
```go
func (h *UserServiceHandlerImpl) RequestPasswordReset(ctx context.Context, req *userv1.RequestPasswordResetReq) (*userv1.RequestPasswordResetResp, error) {{ "{" }}
	_ = h.self.RequestPasswordReset(ctx, req.Identifier, req.Channel)
	return &userv1.RequestPasswordResetResp{{ "{" }}{{ "}" }}, nil
{{ "}" }}

func (h *UserServiceHandlerImpl) ConfirmPasswordReset(ctx context.Context, req *userv1.ConfirmPasswordResetReq) (*userv1.ConfirmPasswordResetResp, error) {{ "{" }}
	err := h.self.ConfirmPasswordReset(ctx, req.Credential, req.NewPassword)
	return &userv1.ConfirmPasswordResetResp{{ "{" }}{{ "}" }}, err
{{ "}" }}
```
（`RequestPasswordReset` 显式忽略 `usersvc.RequestPasswordReset` 的返回值而不是 `return ...Resp{{ "{" }}{{ "}" }}, err`——虽然该方法本身恒定返回 `nil`，这里显式丢弃而非透传，是为了让"这个 RPC 绝不通过错误码泄露账号存在性"这条约束在 handler 层也可见，即使 usecase 层未来被改坏也不会在这一层重新引入信息泄露）

- [ ] **Step 2: server.go 装配 passwordreset repo + notify senders**

修改 `user-kitex/kitex-template/internal_base_server_server_go.yaml`：
1. import 新增 `"{{.Module}}/internal/infrastructure/notify"`、`"{{.Module}}/internal/infrastructure/passwordreset"`
2. 在既有 `auditWriter`/`auditReader` 初始化代码块之后新增：
```go
var resetRepo passwordreset.Repository
if cfg.Database.Enabled {{ "{" }}
	resetRepo = passwordreset.NewSQLRepository(q)
{{ "}" }} else {{ "{" }}
	resetRepo = passwordreset.NewMemoryRepository()
{{ "}" }}
emailSender := notify.NewLogEmailSender()
smsSender := notify.NewLogSMSSender()
```
3. `usersvc.New(...)` 调用点追加三个参数：`resetRepo, emailSender, smsSender`

- [ ] **Step 3: 编译验证**

Run: `go build ./...`
Expected: 编译通过

- [ ] **Step 4: Commit**

```bash
git add user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml user-kitex/kitex-template/internal_base_server_server_go.yaml
git commit -m "feat(user-kitex): wire RequestPasswordReset/ConfirmPasswordReset RPCs into handler and server.go"
```

---

## Task 9: `user-bff-hertz` 限流 resolver 扩展两个新 phase

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- Modify: `user-bff-hertz/hertz-template/conf.yaml`

**Interfaces:**
- Produces：`ratelimit.Resolver.phaseConfig` 新增 `"password_reset_request"`/`"password_reset_confirm"` 两个 case；`conf.RateLimitConfig` 新增 `PasswordResetRequest`/`PasswordResetConfirm RateLimitPhaseConfig` 字段（供 Task 10 路由使用）

- [ ] **Step 1: `conf.yaml` 的 `RateLimitConfig` struct 新增字段**

修改 `user-bff-hertz/hertz-template/conf.yaml`，在既有 `PasswordChange RateLimitPhaseConfig \`yaml:"password_change"\`` 字段之后插入：
```go
PasswordResetRequest RateLimitPhaseConfig `yaml:"password_reset_request"`
PasswordResetConfirm RateLimitPhaseConfig `yaml:"password_reset_confirm"`
```

- [ ] **Step 2: `resolver.go` 的 `phaseConfig` 方法新增两个分支**

修改 `user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`：
```go
func (r *Resolver) phaseConfig(phase string) conf.RateLimitPhaseConfig {{ "{" }}
	switch strings.ToLower(strings.TrimSpace(phase)) {{ "{" }}
	case "post_auth":
		return r.cfg.PostAuth
	case "password_change":
		return r.cfg.PasswordChange
	case "password_reset_request":
		return r.cfg.PasswordResetRequest
	case "password_reset_confirm":
		return r.cfg.PasswordResetConfirm
	default:
		return r.cfg.PreAuth
	{{ "}" }}
{{ "}" }}
```

- [ ] **Step 3: 补一条默认配置（可选但建议）**

在 `conf.yaml` 的 `Default()` 函数里 `PasswordChange: RateLimitPhaseConfig{{ "{" }}...{{ "}" }}` 之后，仿照其结构追加 `PasswordResetRequest`/`PasswordResetConfirm` 的默认值（`Enabled: true`，`KeyBy: []string{{ "{" }}"ip"{{ "}" }}`，`Strategy: "fixed_window"`，`WindowSeconds: 3600s`，`MaxRequests` 按 design doc 的 5 次/小时、10 次/小时 设置——具体字段名以 `RateLimitRuleConfig` 既有字段为准，找到 `PasswordChange` 默认值块里除 `WindowSeconds` 外的其余字段名照抄）。

- [ ] **Step 4: 编译验证**

Run: `go build ./...`
Expected: 编译通过

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml user-bff-hertz/hertz-template/conf.yaml
git commit -m "feat(ratelimit): add password_reset_request/password_reset_confirm phases to user-bff-hertz"
```

---

## Task 10: `user-bff-hertz` 公开端点

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_handler_auth_go.yaml`
- Modify: `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`
- Test: `user-bff-hertz/hertz-template/internal_router_userbffservice_test_go.yaml`

**Interfaces:**
- Consumes：Task 8 的 `userCli.RequestPasswordReset`/`ConfirmPasswordReset`；Task 9 的 `cfg.RateLimit.PasswordResetRequest`/`PasswordResetConfirm`

- [ ] **Step 1: AuthHandler 新增两个方法**

在 `internal_handler_auth_go.yaml` 的 `ChangePassword` 方法之后追加：
```go
type requestPasswordResetReq struct {{ "{" }}
	Identifier string `json:"identifier"`
	Channel    string `json:"channel"`
{{ "}" }}

func (h *AuthHandler) RequestPasswordReset(ctx context.Context, c *app.RequestContext) {{ "{" }}
	var req requestPasswordResetReq
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	{{ "}" }}
	if _, err := h.userCli.RequestPasswordReset(ctx, &userv1.RequestPasswordResetReq{{ "{" }}Identifier: req.Identifier, Channel: req.Channel{{ "}" }}); err != nil {{ "{" }}
		response.Err(c, err)
		return
	{{ "}" }}
	// Always the same success body, regardless of whether identifier
	// matched an account — see usersvc.RequestPasswordReset's doc comment.
	response.OK(c, map[string]string{{ "{" }}"status": "reset_requested"{{ "}" }})
{{ "}" }}

type confirmPasswordResetReq struct {{ "{" }}
	Credential  string `json:"credential"`
	NewPassword string `json:"new_password"`
{{ "}" }}

func (h *AuthHandler) ConfirmPasswordReset(ctx context.Context, c *app.RequestContext) {{ "{" }}
	var req confirmPasswordResetReq
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	{{ "}" }}
	if _, err := h.userCli.ConfirmPasswordReset(ctx, &userv1.ConfirmPasswordResetReq{{ "{" }}Credential: req.Credential, NewPassword: req.NewPassword{{ "}" }}); err != nil {{ "{" }}
		response.Err(c, err)
		return
	{{ "}" }}
	response.OK(c, map[string]string{{ "{" }}"status": "password_reset"{{ "}" }})
{{ "}" }}
```

- [ ] **Step 2: 路由挂载（公开，不经 JWTAuth，附限流）**

修改 `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`，在 `auth.POST("/login", ...)` 之后、`authProtected := auth.Group("")` 之前插入（保持在受保护分组之外——忘记密码场景用户本来就没有 token）：
```go
auth.POST("/password-reset/request", middleware.RateLimit("password_reset_request", cfg.RateLimit, cfg.RateLimit.PasswordResetRequest, resolver), authHandler.RequestPasswordReset)
auth.POST("/password-reset/confirm", middleware.RateLimit("password_reset_confirm", cfg.RateLimit, cfg.RateLimit.PasswordResetConfirm, resolver), authHandler.ConfirmPasswordReset)
```

- [ ] **Step 3: 路由测试**

在 `internal_router_userbffservice_test_go.yaml` 里参照既有 `/auth/login`（`post_auth` phase）测试用例的写法（mock `userservice.Client` 返回成功/错误，`ut.PerformRequest` 发起请求断言状态码），追加：
```go
func TestPasswordResetRequest_AlwaysSucceeds_NoAuthRequired(t *testing.T) {{ "{" }}
	// 参照既有 login 测试的路由搭建方式：无 Authorization header 也应通过
	// （因为该路由在 authProtected 分组之外），mock RequestPasswordReset
	// 返回成功，断言 HTTP 200。
{{ "}" }}

func TestPasswordResetConfirm_InvalidCredential_ReturnsError(t *testing.T) {{ "{" }}
	// mock ConfirmPasswordReset 返回一个业务错误，断言响应体透传该错误
	// 而不是 HTTP 500——与既有 ChangePassword 错误路径测试一致的断言方式。
{{ "}" }}
```
**Note for the implementer:** 具体 mock 客户端搭建方式（`fakeRouterUserClient` 或类似结构体）以该测试文件已有的 `/auth/login`/`/auth/change-password` 测试用例代码为准，本计划不重复既有约定，避免编造与实际 mock 接口不匹配的代码。

- [ ] **Step 4: 编译验证 + 运行测试**

Run: `go build ./... && go test ./internal/router/... ./internal/handler/... -v`
Expected: 编译通过，测试 PASS

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_auth_go.yaml user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml user-bff-hertz/hertz-template/internal_router_userbffservice_test_go.yaml
git commit -m "feat(user-bff-hertz): add public POST /auth/password-reset/request and /confirm endpoints"
```

---

## Task 11: README 更新 + 全量编译回归

**Files:**
- Modify: `user-kitex/README.md`（若存在，追加新 RPC 说明；不存在则跳过此文件）
- Modify: `user-bff-hertz/README.md`（若存在，追加新端点说明；不存在则跳过此文件）

**Interfaces:**
- 无新增接口，纯文档 + 回归验证

- [ ] **Step 1: 检查并更新 README**

若 `user-kitex/README.md` 存在"RPC 列表"或类似章节，追加 `RequestPasswordReset`/`ConfirmPasswordReset` 两行说明（用途、防枚举行为提示）；若 `user-bff-hertz/README.md` 存在"端点列表"章节，追加 `POST /auth/password-reset/request`/`POST /auth/password-reset/confirm` 两行说明（标注"公开端点，无需 JWT，已限流"）。若两个 README 均不存在同类章节，跳过本 Step，不新建文档结构。

- [ ] **Step 2: 全量编译 + 测试回归（在两个服务各自渲染出的实例中）**

Run（`user-kitex`）：
```bash
go build ./... && go test -race -count=1 ./...
```
Run（`user-bff-hertz`）：
```bash
go build ./... && go test -race -count=1 ./...
```
Expected: 两处均编译通过、测试全部 PASS，无因跨 Task 修改遗漏（如某处 `New(...)` 调用点漏加新参数）导致的编译错误。

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: document forgot-password endpoints; final build verification for Issue #71"
```
（若 Step 1 未改动任何 README，本 Step 可能没有可提交内容——跳过 commit，不创建空提交）

---

## Self-Review Notes（写作后自查，供执行前参考）

- **Spec 覆盖**：设计文档的架构概览/数据模型/通知基础设施/凭证生成/限流/用例流程/API/Testing 八个章节，分别对应 Task 6+10 / Task 1-2 / Task 5 / Task 7 / Task 9 / Task 7 / Task 6+10 / 各 Task 内嵌测试，无遗漏。Open Follow-ups（真实发送接入、token 清理）明确不在本计划范围，已在 Global Constraints 重申。
- **已知需要在实现时对照真实生成结果调整的点**（非占位符，是模板生成结果依赖）：Task 2 Step 4、Task 3 Step 4、Task 4 Step 3 里标注的 `gen.*Params` 字段名；Task 7 里 `fakeRepo` 共享指针假设需要在实现时验证。
- **任务顺序具有依赖性，必须按 1→11 顺序执行**：Task 2 必须先于 Task 3/4（sqlc 生成类型）；Task 3/4/5 必须先于 Task 7（usecase 依赖三者）；Task 6 必须先于 Task 8（handler 使用生成类型）；Task 7 必须先于 Task 8；Task 9 必须先于 Task 10（`cfg.RateLimit.PasswordResetRequest/Confirm` 字段）。
- **Task 5 Step 1 的测试代码在自查中修正过一处 import 块转义错误**（多余的收尾符号已删除），当前版本可直接照抄。
