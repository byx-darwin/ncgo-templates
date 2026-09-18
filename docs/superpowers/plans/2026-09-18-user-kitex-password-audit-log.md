# user-kitex 密码修改/重置 + 审计日志子系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `user-kitex` 新增密码修改（自助）/重置（管理员）能力，以及一套从零搭建的审计日志子系统（存储+写入点+查询 RPC），并在 `admin-bff-hertz` 挂载查询端点。

**Architecture:** 复用 `rbac-kitex` 已验证的 `audit.Writer` 写入模式扩展出查询侧（`Reader`/`ListFilter`）；密码修改/重置各自独立 RPC 共享 `usersvc` 内部 helper；四类既有 usecase 方法（登录/绑定解绑/管理员操作）末尾追加 best-effort 审计写入；BFF 层复用 `middleware.RateLimit`，为此需扩展 `resolver.go` 的 `phaseConfig` 支持新 phase。

**Tech Stack:** Go, Kitex (protobuf IDL), sqlc + pgx/v5 + Postgres, Hertz, Argon2id (`internal/infrastructure/auth`)

**Spec:** `docs/superpowers/specs/2026-09-18-user-kitex-password-audit-log-design.md`

## Global Constraints

- 审计写入一律 best-effort（错误不阻断主流程，`_ = writer.Write(...)` 或显式忽略并记录日志），与 rbac-kitex 既有写点一致
- 审计日志表本次不实现自动保留/清理策略（YAGNI）
- `ChangePassword`/`ResetPassword` 是两个独立 RPC，共享一个私有 helper，不合并成带标志位的单一 RPC
- 两者都必须调用 `Blacklist.Revoke(ctx, uid)` 强制旧 token 下线（复用 `ForceLogout` 既有机制，仍是尽力而为，不修复 JWT 中间件不读黑名单的既有缺口）
- 审计日志查询端点仅管理员可用（`admin-bff-hertz`），不新增终端用户自助查看端点
- `Authz(rbacCli)` 中间件必须严格 per-route（紧跟 `RequirePermission` 之后）挂载，禁止 group 级别 `Use()`
- 修改 `user.proto` 后必须运行 `make update`（`user-kitex/Makefile`）重新生成 `kitex_gen`；修改 schema/query `.sql` 后运行 `make sqlc`

---

## Task 1: 审计日志表 + sqlc 查询定义（user-kitex）

**Files:**
- Create: `user-kitex/kitex-template/internal_db_schema_000002_audit_log_sql.yaml`
- Create: `user-kitex/kitex-template/internal_db_query_audit_log_sql.yaml`

**Interfaces:**
- Produces：新表 `audit_log`；sqlc 生成的 `gen.InsertAuditLogParams`/`gen.AuditLog`/`gen.ListAuditLogParams`/`gen.CountAuditLogParams`（供 Task 2 使用）

- [ ] **Step 1: 新建 schema 模板文件**

`user-kitex/kitex-template/internal_db_schema_000002_audit_log_sql.yaml`：
```yaml
# ncgo exported template — internal/db/schema/000002_audit_log.sql
path: internal/db/schema/000002_audit_log.sql
update_behavior:
    type: cover
body: |-
    CREATE TABLE audit_log (
        id BIGSERIAL PRIMARY KEY,
        actor_uid TEXT,
        action TEXT NOT NULL,
        target TEXT NOT NULL DEFAULT '',
        ip_address TEXT NOT NULL DEFAULT '',
        user_agent TEXT NOT NULL DEFAULT '',
        detail_json TEXT NOT NULL DEFAULT '{}',
        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX idx_audit_log_actor_created ON audit_log(actor_uid, created_at);
    CREATE INDEX idx_audit_log_action_created ON audit_log(action, created_at);
```

- [ ] **Step 2: 新建 sqlc 查询模板文件**

`user-kitex/kitex-template/internal_db_query_audit_log_sql.yaml`：
```yaml
# ncgo exported template — internal/db/query/audit_log.sql
path: internal/db/query/audit_log.sql
update_behavior:
    type: cover
body: |-
    -- name: InsertAuditLog :one
    INSERT INTO audit_log (actor_uid, action, target, ip_address, user_agent, detail_json)
    VALUES ($1, $2, $3, $4, $5, $6) RETURNING id;
    -- name: ListAuditLog :many
    SELECT * FROM audit_log
    WHERE actor_uid = $1
      AND ($2::text IS NULL OR action = $2)
      AND ($3::timestamptz IS NULL OR created_at >= $3)
      AND ($4::timestamptz IS NULL OR created_at <= $4)
    ORDER BY created_at DESC
    LIMIT $5 OFFSET $6;
    -- name: CountAuditLog :one
    SELECT count(*) FROM audit_log
    WHERE actor_uid = $1
      AND ($2::text IS NULL OR action = $2)
      AND ($3::timestamptz IS NULL OR created_at >= $3)
      AND ($4::timestamptz IS NULL OR created_at <= $4);
```

- [ ] **Step 3: 手工渲染验证 SQL 语法**

在一个临时的本地 `user-kitex` 实例（或已有开发实例）里手动把两段 `body` 内容分别落到 `internal/db/schema/000002_audit_log.sql` / `internal/db/query/audit_log.sql`，运行：
```bash
make sqlc
```
Expected: 无报错，`internal/db/gen/` 生成/更新出 `InsertAuditLog`、`ListAuditLog`、`CountAuditLog`、`AuditLog`（行结构体）对应的 Go 代码，字段名符合 sqlc 命名规则（`ActorUid *string`、`IpAddress string` 等，`emit_result_struct_pointers: true` 意味着返回值是 `*gen.AuditLog`）。

- [ ] **Step 4: Commit**

```bash
git add user-kitex/kitex-template/internal_db_schema_000002_audit_log_sql.yaml user-kitex/kitex-template/internal_db_query_audit_log_sql.yaml
git commit -m "feat(user-kitex): add audit_log table schema and sqlc queries"
```

---

## Task 2: 审计基础设施包 — Writer 复用 + 新增 Reader（user-kitex）

**Files:**
- Create: `user-kitex/kitex-template/internal_infrastructure_audit_writer_go.yaml`
- Create: `user-kitex/kitex-template/internal_infrastructure_audit_reader_go.yaml`
- Test: `user-kitex/kitex-template/internal_infrastructure_audit_reader_test_go.yaml`

**Interfaces:**
- Consumes：Task 1 的 `gen.Queries`（`InsertAuditLog`/`ListAuditLog`/`CountAuditLog`）
- Produces：
  - `audit.Entry{ActorUID, Action, Target, IPAddress, UserAgent, DetailJSON string; CreatedAt time.Time}`
  - `audit.Writer` 接口：`Write(ctx context.Context, e Entry) error`（**注意**：与 rbac-kitex 的位置参数签名不同，这里改为整包 `Entry` 传入，因为新增了 `IPAddress`/`UserAgent` 字段，位置参数会超过 4 个变得难读）
  - `audit.ListFilter{ActorUID string; Action *string; StartTime, EndTime *time.Time; Limit, Offset int}`
  - `audit.Reader` 接口：`List(ctx context.Context, f ListFilter) ([]Entry, int64, error)`
  - `NewSQLWriter(q *gen.Queries) *SQLWriter`、`NewSQLReader(q *gen.Queries) *SQLReader`、`NewMemoryWriter() *MemoryWriter`、`NewMemoryReader(w *MemoryWriter) *MemoryReader`（内存实现共享同一份底层切片，供测试同时验证写入与查询）

- [ ] **Step 1: 编写 Reader 测试（内存实现）**

`user-kitex/kitex-template/internal_infrastructure_audit_reader_test_go.yaml`：
```yaml
# ncgo exported template — internal/infrastructure/audit/reader_test.go
path: internal/infrastructure/audit/reader_test.go
update_behavior:
    type: cover
body: |-
    package audit_test

    import (
    	"context"
    	"testing"
    	"time"

    	"{{.Module}}/internal/infrastructure/audit"
    )

    func TestMemoryReader_List_FiltersByActorAndAction(t *testing.T) {{ "{" }}
    	w := audit.NewMemoryWriter()
    	r := audit.NewMemoryReader(w)
    	ctx := context.Background()

    	_ = w.Write(ctx, audit.Entry{{ "{" }}ActorUID: "u1", Action: "auth.login.success", CreatedAt: time.Now(){{ "}" }})
    	_ = w.Write(ctx, audit.Entry{{ "{" }}ActorUID: "u1", Action: "user.password_change", CreatedAt: time.Now(){{ "}" }})
    	_ = w.Write(ctx, audit.Entry{{ "{" }}ActorUID: "u2", Action: "auth.login.success", CreatedAt: time.Now(){{ "}" }})

    	entries, total, err := r.List(ctx, audit.ListFilter{{ "{" }}ActorUID: "u1", Limit: 10{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("List returned error: %v", err)
    	{{ "}" }}
    	if total != 2 {{ "{" }}
    		t.Fatalf("expected total=2, got %d", total)
    	{{ "}" }}
    	if len(entries) != 2 {{ "{" }}
    		t.Fatalf("expected 2 entries, got %d", len(entries))
    	{{ "}" }}

    	action := "user.password_change"
    	entries, total, err = r.List(ctx, audit.ListFilter{{ "{" }}ActorUID: "u1", Action: &action, Limit: 10{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("List with action filter returned error: %v", err)
    	{{ "}" }}
    	if total != 1 || len(entries) != 1 {{ "{" }}
    		t.Fatalf("expected 1 filtered entry, got total=%d len=%d", total, len(entries))
    	{{ "}" }}
    	if entries[0].Action != action {{ "{" }}
    		t.Fatalf("expected action %q, got %q", action, entries[0].Action)
    	{{ "}" }}
    {{ "}" }}

    func TestMemoryReader_List_Pagination(t *testing.T) {{ "{" }}
    	w := audit.NewMemoryWriter()
    	r := audit.NewMemoryReader(w)
    	ctx := context.Background()
    	for i := 0; i < 5; i++ {{ "{" }}
    		_ = w.Write(ctx, audit.Entry{{ "{" }}ActorUID: "u1", Action: "auth.login.success", CreatedAt: time.Now(){{ "}" }})
    	{{ "}" }}

    	entries, total, err := r.List(ctx, audit.ListFilter{{ "{" }}ActorUID: "u1", Limit: 2, Offset: 1{{ "}" }})
    	if err != nil {{ "{" }}
    		t.Fatalf("List returned error: %v", err)
    	{{ "}" }}
    	if total != 5 {{ "{" }}
    		t.Fatalf("expected total=5, got %d", total)
    	{{ "}" }}
    	if len(entries) != 2 {{ "{" }}
    		t.Fatalf("expected 2 entries (page size), got %d", len(entries))
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `go test ./internal/infrastructure/audit/... -run TestMemoryReader -v`（在渲染出的具体项目实例中）
Expected: 编译失败（`audit.Entry`/`audit.NewMemoryReader`/`audit.ListFilter` 尚不存在）

- [ ] **Step 3: 重写 writer.go（加入新字段的 Entry + 保留 MemoryWriter 供内存读写共用）**

`user-kitex/kitex-template/internal_infrastructure_audit_writer_go.yaml`：
```yaml
# ncgo exported template — internal/infrastructure/audit/writer.go
path: internal/infrastructure/audit/writer.go
update_behavior:
    type: cover
body: |-
    package audit

    import (
    	"context"
    	"sync"
    	"time"

    	"{{.Module}}/internal/db/gen"
    )

    // Entry is a single audit log line.
    type Entry struct {{ "{" }}
    	ActorUID   string
    	Action     string
    	Target     string
    	IPAddress  string
    	UserAgent  string
    	DetailJSON string
    	CreatedAt  time.Time
    {{ "}" }}

    // Writer records user-kitex mutations for audit.
    type Writer interface {{ "{" }}
    	Write(ctx context.Context, e Entry) error
    {{ "}" }}

    // SQLWriter persists audit entries via sqlc.
    type SQLWriter struct {{ "{" }}
    	q *gen.Queries
    {{ "}" }}

    // NewSQLWriter creates an audit writer backed by the audit_log table.
    func NewSQLWriter(q *gen.Queries) *SQLWriter {{ "{" }}
    	return &SQLWriter{{ "{" }}q: q{{ "}" }}
    {{ "}" }}

    func (w *SQLWriter) Write(ctx context.Context, e Entry) error {{ "{" }}
    	var actor *string
    	if e.ActorUID != "" {{ "{" }}
    		v := e.ActorUID
    		actor = &v
    	{{ "}" }}
    	detail := e.DetailJSON
    	if detail == "" {{ "{" }}
    		detail = "{{ "{" }}{{ "}" }}"
    	{{ "}" }}
    	_, err := w.q.InsertAuditLog(ctx, &gen.InsertAuditLogParams{{ "{" }}
    		ActorUid:   actor,
    		Action:     e.Action,
    		Target:     e.Target,
    		IpAddress:  e.IPAddress,
    		UserAgent:  e.UserAgent,
    		DetailJson: detail,
    	{{ "}" }})
    	return err
    {{ "}" }}

    // MemoryWriter is a test-only in-memory audit writer, shared with
    // MemoryReader (see reader.go) so tests can write then query in one
    // hermetic slice without a database.
    type MemoryWriter struct {{ "{" }}
    	mu      sync.Mutex
    	entries []Entry
    {{ "}" }}

    // NewMemoryWriter creates an in-memory audit writer.
    func NewMemoryWriter() *MemoryWriter {{ "{" }}
    	return &MemoryWriter{{ "{" }}{{ "}" }}
    {{ "}" }}

    func (w *MemoryWriter) Write(ctx context.Context, e Entry) error {{ "{" }}
    	w.mu.Lock()
    	defer w.mu.Unlock()
    	if e.CreatedAt.IsZero() {{ "{" }}
    		e.CreatedAt = time.Now()
    	{{ "}" }}
    	w.entries = append(w.entries, e)
    	return nil
    {{ "}" }}

    // Entries returns a copy of the recorded audit entries.
    func (w *MemoryWriter) Entries() []Entry {{ "{" }}
    	w.mu.Lock()
    	defer w.mu.Unlock()
    	out := make([]Entry, len(w.entries))
    	copy(out, w.entries)
    	return out
    {{ "}" }}
```

- [ ] **Step 4: 新建 reader.go**

`user-kitex/kitex-template/internal_infrastructure_audit_reader_go.yaml`：
```yaml
# ncgo exported template — internal/infrastructure/audit/reader.go
path: internal/infrastructure/audit/reader.go
update_behavior:
    type: cover
body: |-
    package audit

    import (
    	"context"
    	"sort"
    	"time"

    	"{{.Module}}/internal/db/gen"
    )

    // ListFilter selects audit entries for one actor, optionally narrowed by
    // action and/or a created_at range. ActorUID is required — this
    // subsystem does not support an unscoped "list everything" query.
    type ListFilter struct {{ "{" }}
    	ActorUID  string
    	Action    *string
    	StartTime *time.Time
    	EndTime   *time.Time
    	Limit     int
    	Offset    int
    {{ "}" }}

    // Reader queries previously written audit entries.
    type Reader interface {{ "{" }}
    	List(ctx context.Context, f ListFilter) ([]Entry, int64, error)
    {{ "}" }}

    // SQLReader queries audit entries via sqlc.
    type SQLReader struct {{ "{" }}
    	q *gen.Queries
    {{ "}" }}

    // NewSQLReader creates an audit reader backed by the audit_log table.
    func NewSQLReader(q *gen.Queries) *SQLReader {{ "{" }}
    	return &SQLReader{{ "{" }}q: q{{ "}" }}
    {{ "}" }}

    func (r *SQLReader) List(ctx context.Context, f ListFilter) ([]Entry, int64, error) {{ "{" }}
    	limit := f.Limit
    	if limit <= 0 {{ "{" }}
    		limit = 20
    	{{ "}" }}
    	if limit > 100 {{ "{" }}
    		limit = 100
    	{{ "}" }}
    	rows, err := r.q.ListAuditLog(ctx, &gen.ListAuditLogParams{{ "{" }}
    		ActorUid:  &f.ActorUID,
    		Action:    f.Action,
    		CreatedAt: f.StartTime,
    		CreatedAt_2: f.EndTime,
    		Limit:     int32(limit),
    		Offset:    int32(f.Offset),
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	total, err := r.q.CountAuditLog(ctx, &gen.CountAuditLogParams{{ "{" }}
    		ActorUid:  &f.ActorUID,
    		Action:    f.Action,
    		CreatedAt: f.StartTime,
    		CreatedAt_2: f.EndTime,
    	{{ "}" }})
    	if err != nil {{ "{" }}
    		return nil, 0, err
    	{{ "}" }}
    	out := make([]Entry, 0, len(rows))
    	for _, row := range rows {{ "{" }}
    		actor := ""
    		if row.ActorUid != nil {{ "{" }}
    			actor = *row.ActorUid
    		{{ "}" }}
    		out = append(out, Entry{{ "{" }}
    			ActorUID:   actor,
    			Action:     row.Action,
    			Target:     row.Target,
    			IPAddress:  row.IpAddress,
    			UserAgent:  row.UserAgent,
    			DetailJSON: row.DetailJson,
    			CreatedAt:  row.CreatedAt.Time,
    		{{ "}" }})
    	{{ "}" }}
    	return out, total, nil
    {{ "}" }}

    // MemoryReader queries entries recorded by a MemoryWriter. It is a thin,
    // read-only view (no separate storage) — construct it with the same
    // *MemoryWriter instance the code under test writes through.
    type MemoryReader struct {{ "{" }}
    	w *MemoryWriter
    {{ "}" }}

    // NewMemoryReader creates an in-memory audit reader backed by w.
    func NewMemoryReader(w *MemoryWriter) *MemoryReader {{ "{" }}
    	return &MemoryReader{{ "{" }}w: w{{ "}" }}
    {{ "}" }}

    func (r *MemoryReader) List(ctx context.Context, f ListFilter) ([]Entry, int64, error) {{ "{" }}
    	all := r.w.Entries()
    	matched := make([]Entry, 0, len(all))
    	for _, e := range all {{ "{" }}
    		if e.ActorUID != f.ActorUID {{ "{" }}
    			continue
    		{{ "}" }}
    		if f.Action != nil && e.Action != *f.Action {{ "{" }}
    			continue
    		{{ "}" }}
    		if f.StartTime != nil && e.CreatedAt.Before(*f.StartTime) {{ "{" }}
    			continue
    		{{ "}" }}
    		if f.EndTime != nil && e.CreatedAt.After(*f.EndTime) {{ "{" }}
    			continue
    		{{ "}" }}
    		matched = append(matched, e)
    	{{ "}" }}
    	sort.Slice(matched, func(i, j int) bool {{ "{" }} return matched[i].CreatedAt.After(matched[j].CreatedAt) {{ "}" }})
    	total := int64(len(matched))
    	limit := f.Limit
    	if limit <= 0 {{ "{" }}
    		limit = 20
    	{{ "}" }}
    	start := f.Offset
    	if start > len(matched) {{ "{" }}
    		start = len(matched)
    	{{ "}" }}
    	end := start + limit
    	if end > len(matched) {{ "{" }}
    		end = len(matched)
    	{{ "}" }}
    	return matched[start:end], total, nil
    {{ "}" }}
```

**Note for the implementer:** `gen.ListAuditLogParams`/`gen.CountAuditLogParams` 的确切字段名由 `sqlc generate` 决定——本 Task 1 里两个同名 `created_at` 占位参数（`$3`、`$4`）sqlc 通常会生成 `CreatedAt`/`CreatedAt_2`（重复列名加后缀）。生成后先跑一次 `go build` 确认实际字段名，若 sqlc 生成的名字不同（例如 `StartTime`/`EndTime`，取决于 sqlc 版本对参数推断的命名策略），以实际生成结果为准调整本文件的字段名，这不是本计划可以脱离生成结果预判死的细节。

- [ ] **Step 5: 运行测试确认通过**

Run: `go test ./internal/infrastructure/audit/... -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_infrastructure_audit_writer_go.yaml user-kitex/kitex-template/internal_infrastructure_audit_reader_go.yaml user-kitex/kitex-template/internal_infrastructure_audit_reader_test_go.yaml
git commit -m "feat(user-kitex): add audit Reader alongside existing Writer, extend Entry with ip/user_agent"
```

---

## Task 3: user.proto 新增 RPC 定义（ChangePassword / ResetPassword / ListAuditLogs）

**Files:**
- Modify: `user-kitex/idl/user.proto`

**Interfaces:**
- Produces：`ChangePasswordReq/Resp`、`ResetPasswordReq/Resp`、`ListAuditLogsReq/Resp`、`AuditLogItem` message；`UserService` 新增三个 rpc（供 Task 4/5/6 的 handler 实现）

- [ ] **Step 1: 在 `user-kitex/idl/user.proto` 的 `AdminUnbindProviderResp {}` 之后、`service UserService` 之前插入新 message**

```proto
message ChangePasswordReq {
  // uid MUST be extracted from the caller's verified JWT by the invoking
  // BFF — same trust boundary as UnbindProviderReq.uid.
  string uid = 1;
  string old_password = 2;
  string new_password = 3;
}
message ChangePasswordResp {}

message ResetPasswordReq {
  // uid is the target end-user, specified by an admin operator via
  // admin-bff-hertz. Trust boundary matches AdminUnbindProviderReq: the
  // calling BFF's RBAC check ("terminal_user:password-reset" permission)
  // gates this call, user-kitex does not re-verify caller identity.
  string uid = 1;
  string new_password = 2;
}
message ResetPasswordResp {}

message ListAuditLogsReq {
  string actor_uid = 1;
  string action = 2;      // optional filter, empty = no filter
  string start_time = 3;  // optional, RFC3339
  string end_time = 4;    // optional, RFC3339
  int32 limit = 5;
  int32 offset = 6;
}
message AuditLogItem {
  string actor_uid = 1;
  string action = 2;
  string target = 3;
  string ip_address = 4;
  string user_agent = 5;
  string detail_json = 6;
  string created_at = 7;  // RFC3339
}
message ListAuditLogsResp {
  repeated AuditLogItem entries = 1;
  int64 total = 2;
}
```

- [ ] **Step 2: 在 `service UserService {}` 块内新增三行 rpc 声明**

```proto
  rpc ChangePassword(ChangePasswordReq) returns (ChangePasswordResp);
  rpc ResetPassword(ResetPasswordReq) returns (ResetPasswordResp);
  rpc ListAuditLogs(ListAuditLogsReq) returns (ListAuditLogsResp);
```
放在 `AdminUnbindProvider` 那一行之后。

- [ ] **Step 3: 重新生成 kitex_gen（在渲染出的具体项目实例中）**

Run: `make update`
Expected: `kitex_gen/api/user/v1/` 下新增 `ChangePasswordReq`/`ResetPasswordReq`/`ListAuditLogsReq` 等 Go 结构体，`kitex_gen/api/user/v1/userservice` 客户端接口新增三个方法签名。

- [ ] **Step 4: Commit**

```bash
git add user-kitex/idl/user.proto
git commit -m "feat(user-kitex): add ChangePassword/ResetPassword/ListAuditLogs to user.proto"
```

---

## Task 4: usersvc 新增 ChangePassword + 写点接入（Login/OAuthCallback/BindProvider/UnbindProvider）

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Test: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`（若不存在则新建）

**Interfaces:**
- Consumes：`audit.Writer`（Task 2）、`useradmin.Blacklist` 接口（跨包复用，见下方 Step 3 说明）、`auth.VerifyPassword`/`auth.HashPassword`（已存在）
- Produces：`usersvc.Service.ChangePassword(ctx context.Context, uid, oldPassword, newPassword string) error`；`usersvc.New` 签名新增 `audit audit.Writer` 与 `blacklist Blacklist` 两个参数（供 Task 7 wiring 使用）

- [ ] **Step 1: 编写 ChangePassword 测试（使用 MemoryWriter 断言写点）**

`user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`（若已存在同名文件，在其基础上追加以下测试函数；若不存在则新建，`package usersvc_test`，按现有测试文件惯例 import 真实包）：
```yaml
# ncgo exported template — internal/application/user/user_service_test.go
path: internal/application/user/user_service_test.go
update_behavior:
    type: cover
body: |-
    package usersvc_test

    import (
    	"context"
    	"testing"
    	"time"

    	usersvc "{{.Module}}/internal/application/user"
    	"{{.Module}}/internal/domain/user"
    	"{{.Module}}/internal/infrastructure/audit"
    	"{{.Module}}/internal/infrastructure/auth"
    )

    type fakeBlacklist struct {{ "{" }}
    	revoked []string
    {{ "}" }}

    func (b *fakeBlacklist) Revoke(ctx context.Context, uid string) error {{ "{" }}
    	b.revoked = append(b.revoked, uid)
    	return nil
    {{ "}" }}

    func TestChangePassword_WrongOldPassword_Rejected(t *testing.T) {{ "{" }}
    	repo := newFakeUserRepo(t) // helper assumed to exist per existing test suite conventions; if absent, construct a minimal in-memory user.Repository stub here implementing Create/GetByID/UpdatePassword at minimum
    	hash, _ := auth.HashPassword("correct-horse")
    	u, _ := user.NewLocal("alice", hash)
    	_ = repo.Create(context.Background(), u)

    	aw := audit.NewMemoryWriter()
    	bl := &fakeBlacklist{{ "{" }}{{ "}" }}
    	svc := usersvc.New(repo, nil, nil, nil, time.Hour, aw, bl)

    	err := svc.ChangePassword(context.Background(), u.ID.String(), "wrong-password", "new-password-1")
    	if err == nil {{ "{" }}
    		t.Fatal("expected error for wrong old password, got nil")
    	{{ "}" }}
    	if len(aw.Entries()) != 0 {{ "{" }}
    		t.Fatalf("expected no audit entry on failed change, got %d", len(aw.Entries()))
    	{{ "}" }}
    {{ "}" }}

    func TestChangePassword_Success_UpdatesHashRevokesAndAudits(t *testing.T) {{ "{" }}
    	repo := newFakeUserRepo(t)
    	hash, _ := auth.HashPassword("correct-horse")
    	u, _ := user.NewLocal("alice", hash)
    	_ = repo.Create(context.Background(), u)

    	aw := audit.NewMemoryWriter()
    	bl := &fakeBlacklist{{ "{" }}{{ "}" }}
    	svc := usersvc.New(repo, nil, nil, nil, time.Hour, aw, bl)

    	err := svc.ChangePassword(context.Background(), u.ID.String(), "correct-horse", "new-password-1")
    	if err != nil {{ "{" }}
    		t.Fatalf("expected success, got error: %v", err)
    	{{ "}" }}

    	updated, err := repo.GetByID(context.Background(), u.ID)
    	if err != nil {{ "{" }}
    		t.Fatalf("GetByID failed: %v", err)
    	{{ "}" }}
    	if ok, _ := auth.VerifyPassword("new-password-1", *updated.PasswordHash); !ok {{ "{" }}
    		t.Fatal("password hash was not updated to the new password")
    	{{ "}" }}

    	if len(bl.revoked) != 1 || bl.revoked[0] != u.ID.String() {{ "{" }}
    		t.Fatalf("expected blacklist.Revoke called once with uid %q, got %v", u.ID.String(), bl.revoked)
    	{{ "}" }}

    	entries := aw.Entries()
    	if len(entries) != 1 || entries[0].Action != "user.password_change" {{ "{" }}
    		t.Fatalf("expected 1 audit entry with action user.password_change, got %+v", entries)
    	{{ "}" }}
    {{ "}" }}
```

**Note for the implementer:** `newFakeUserRepo` 是占位辅助函数名——检查 `internal/application/user/` 目录下是否已有既有测试文件定义的内存 `user.Repository` 测试替身（`usersvc` 测试通常需要一个）；如果已存在同类 helper，复用它并调整函数名；如果不存在，在本文件内新增一个实现 `user.Repository` 全部方法的最小内存结构体（`Create`/`GetByID`/`UpdatePassword` 是本测试实际用到的三个，其余方法可返回 `errors.New("not implemented")`）。

- [ ] **Step 2: 运行测试确认失败**

Run: `go test ./internal/application/user/... -run TestChangePassword -v`
Expected: 编译失败（`ChangePassword` 方法、`usersvc.New` 新签名均不存在）

- [ ] **Step 3: 实现 ChangePassword + 改造 New() + 补齐 4 个既有写点**

重写 `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`（在原有内容基础上做以下修改，其余方法体不变）：

1. import 新增 `"{{.Module}}/internal/infrastructure/audit"`
2. `Service` struct 新增两个字段：`audit audit.Writer` 和 `blacklist Blacklist`
3. 新增一个本包私有接口 `Blacklist`（与 `useradminsvc.Blacklist` 结构相同但独立定义，避免 `usersvc` 反向依赖 `useradminsvc`）：
   ```go
   // Blacklist revokes a JWT before its natural expiry. Mirrors
   // useradminsvc.Blacklist's shape exactly — server.go wires the same
   // concrete redisBlacklist/noopBlacklist instance into both services.
   type Blacklist interface {{ "{" }}
   	Revoke(ctx context.Context, uid string) error
   {{ "}" }}
   ```
4. `New` 签名与函数体：
   ```go
   func New(repo user.Repository, jwt *auth.JWTManager, providers oauth.Registry, stateStore oauth.StateStore, tokenTTL time.Duration, auditWriter audit.Writer, blacklist Blacklist) *Service {{ "{" }}
   	return &Service{{ "{" }}repo: repo, jwt: jwt, providers: providers, stateStore: stateStore, tokenTTL: tokenTTL, audit: auditWriter, blacklist: blacklist{{ "}" }}
   {{ "}" }}
   ```
5. 在 `Login` 的每个 return 分支追加审计写点（成功与失败都记）：
   - 失败路径（`GetByUsername` 返回 `ErrNotFound`）：在 `return LoginOutput{{ "{" }}{{ "}" }}, errors.New("user: invalid credentials")` 之前插入 `_ = s.audit.Write(ctx, audit.Entry{{ "{" }}Action: "auth.login.failure", DetailJSON: `+"`"+`{{ "{" }}"reason":"user_not_found"{{ "}" }}`+"`"+`{{ "}" }})`
   - `u.IsBanned()` 分支：插入 `_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: u.ID.String(), Action: "auth.login.failure", DetailJSON: `+"`"+`{{ "{" }}"reason":"banned"{{ "}" }}`+"`"+`{{ "}" }})`
   - `u.PasswordHash == nil` 分支：`Action: "auth.login.failure"`，`DetailJSON: {{ "{" }}"reason":"no_local_password"{{ "}" }}`
   - `VerifyPassword` 失败分支：`Action: "auth.login.failure"`，`DetailJSON: {{ "{" }}"reason":"bad_password"{{ "}" }}`
   - 成功路径：在 `return s.issueToken(u)` 之前无法直接拿到结果，改为在 `issueToken` 成功返回前插入 `_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: u.ID.String(), Action: "auth.login.success"{{ "}" }})`（即在 `issueToken` 方法内、`return LoginOutput{{ "{" }}...{{ "}" }}, nil` 之前）。`issueToken` 签名需要新增 `ctx context.Context` 参数（当前签名 `func (s *Service) issueToken(u *user.User) (LoginOutput, error)` 没有 ctx），两处调用点（`Login`、`OAuthCallback`）同步传入 ctx。
6. 在 `OAuthCallback` 的失败分支（`ErrTokenExpired`/state 校验失败/provider 不存在/交换 code 失败/获取用户信息失败/`u.IsBanned()`）统一追加 `Action: "auth.login.failure"`，`DetailJSON` 按分支区分（如 `{{ "{" }}"reason":"oauth_state_invalid","provider":"...")`），成功路径复用改造后的 `issueToken(ctx, u)`（自动记 `auth.login.success`）。
7. `BindProvider` 成功返回（`return s.repo.CreateIdentity(ctx, identity)` 之前，仅在 err 为 nil 时）追加 `_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: uid, Action: "identity.bind", Target: in.Provider{{ "}" }})` — 注意需要先判断 `CreateIdentity` 是否成功再决定是否写审计，因此把 `return s.repo.CreateIdentity(...)` 拆成：
   ```go
   if err := s.repo.CreateIdentity(ctx, identity); err != nil {{ "{" }}
   	return err
   {{ "}" }}
   _ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: uid, Action: "identity.bind", Target: in.Provider{{ "}" }})
   return nil
   ```
8. `UnbindProvider` 成功路径同理，把末尾 `return s.repo.DeleteIdentity(ctx, id, providerName)` 拆成先判断错误、成功后写 `Action: "identity.unbind"`、`Target: providerName`、`ActorUID: uid` 再 `return nil`。
9. 新增 `ChangePassword` 方法（追加到文件末尾）：
   ```go
   // ChangePassword lets an already-authenticated end-user change their own
   // password after verifying the current one.
   func (s *Service) ChangePassword(ctx context.Context, uid, oldPassword, newPassword string) error {{ "{" }}
   	return s.setPassword(ctx, uid, &oldPassword, newPassword, "user.password_change")
   {{ "}" }}

   // setPassword is the shared implementation behind ChangePassword (self-
   // service, oldPassword required) and useradminsvc.ResetPassword (admin-
   // forced, oldPassword nil — see server.go wiring, which passes this same
   // Service to construct useradminsvc.Service's password-reset path).
   func (s *Service) setPassword(ctx context.Context, uid string, oldPassword *string, newPassword, auditAction string) error {{ "{" }}
   	if len(newPassword) < minPasswordLength {{ "{" }}
   		return errors.New("user: password must be at least 8 characters")
   	{{ "}" }}
   	id, err := parseUID(uid)
   	if err != nil {{ "{" }}
   		return err
   	{{ "}" }}
   	u, err := s.repo.GetByID(ctx, id)
   	if err != nil {{ "{" }}
   		return err
   	{{ "}" }}
   	if oldPassword != nil {{ "{" }}
   		if u.PasswordHash == nil {{ "{" }}
   			return errors.New("user: account has no local password set")
   		{{ "}" }}
   		ok, err := auth.VerifyPassword(*oldPassword, *u.PasswordHash)
   		if err != nil || !ok {{ "{" }}
   			return errors.New("user: old password is incorrect")
   		{{ "}" }}
   	{{ "}" }}
   	newHash, err := auth.HashPassword(newPassword)
   	if err != nil {{ "{" }}
   		return err
   	{{ "}" }}
   	if err := s.repo.UpdatePassword(ctx, id, newHash); err != nil {{ "{" }}
   		return err
   	{{ "}" }}
   	_ = s.blacklist.Revoke(ctx, uid)
   	_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: uid, Action: auditAction{{ "}" }})
   	return nil
   {{ "}" }}

   // SetPasswordForAdmin is called by useradminsvc.ResetPassword to reuse
   // setPassword's shared logic without exporting setPassword itself
   // (keeps the no-old-password path explicit at the call site rather than
   // letting any caller pass a nil oldPassword to the unexported helper).
   func (s *Service) SetPasswordForAdmin(ctx context.Context, uid, newPassword string) error {{ "{" }}
   	return s.setPassword(ctx, uid, nil, newPassword, "user.password_reset")
   {{ "}" }}
   ```

- [ ] **Step 4: 运行测试确认通过**

Run: `go test ./internal/application/user/... -v`
Expected: PASS（含既有 Register/Login/OAuth 测试——注意 Step 3 改了 `issueToken`/`New` 签名，既有测试文件里所有 `usersvc.New(...)` 调用点都要同步加上两个新参数，既有测试用 `audit.NewMemoryWriter()` 和一个 no-op blacklist stub 填充）

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_go.yaml user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "feat(user-kitex): add usersvc.ChangePassword, audit write points for login/bind/unbind"
```

---

## Task 5: useradminsvc 新增 ResetPassword + 写点接入（BanUser/UnbanUser/ForceLogout）

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml`
- Test: `user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`（若不存在则新建）

**Interfaces:**
- Consumes：Task 4 产出的 `*usersvc.Service.SetPasswordForAdmin`（`useradminsvc.Service` 新增一个 `passwordSetter` 依赖）、`audit.Writer`
- Produces：`useradminsvc.Service.ResetPassword(ctx, uid, newPassword string) error`；`useradminsvc.New` 签名新增 `auditWriter audit.Writer` 与 `passwordSetter PasswordSetter` 两个参数

- [ ] **Step 1: 编写 ResetPassword + 写点测试**

`user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml`：
```yaml
# ncgo exported template — internal/application/useradmin/admin_service_test.go
path: internal/application/useradmin/admin_service_test.go
update_behavior:
    type: cover
body: |-
    package useradminsvc_test

    import (
    	"context"
    	"testing"

    	useradminsvc "{{.Module}}/internal/application/useradmin"
    	"{{.Module}}/internal/infrastructure/audit"
    )

    type fakePasswordSetter struct {{ "{" }}
    	calls []string // uid+":"+newPassword
    {{ "}" }}

    func (f *fakePasswordSetter) SetPasswordForAdmin(ctx context.Context, uid, newPassword string) error {{ "{" }}
    	f.calls = append(f.calls, uid+":"+newPassword)
    	return nil
    {{ "}" }}

    func TestResetPassword_DelegatesToSharedSetter(t *testing.T) {{ "{" }}
    	repo := newFakeUserRepo(t)
    	ps := &fakePasswordSetter{{ "{" }}{{ "}" }}
    	aw := audit.NewMemoryWriter()
    	svc := useradminsvc.New(repo, &noopBlacklist{{ "{" }}{{ "}" }}, aw, ps)

    	if err := svc.ResetPassword(context.Background(), "u1", "new-password-1"); err != nil {{ "{" }}
    		t.Fatalf("expected success, got error: %v", err)
    	{{ "}" }}
    	if len(ps.calls) != 1 || ps.calls[0] != "u1:new-password-1" {{ "{" }}
    		t.Fatalf("expected SetPasswordForAdmin called once with u1:new-password-1, got %v", ps.calls)
    	{{ "}" }}
    {{ "}" }}

    func TestBanUser_WritesAuditEntry(t *testing.T) {{ "{" }}
    	repo := newFakeUserRepo(t)
    	aw := audit.NewMemoryWriter()
    	svc := useradminsvc.New(repo, &noopBlacklist{{ "{" }}{{ "}" }}, aw, &fakePasswordSetter{{ "{" }}{{ "}" }})

    	u := seedFakeUser(t, repo, "alice") // helper assumed present in existing test suite; create one if absent, mirroring newFakeUserRepo's conventions

    	if err := svc.BanUser(context.Background(), u.ID.String()); err != nil {{ "{" }}
    		t.Fatalf("BanUser failed: %v", err)
    	{{ "}" }}
    	entries := aw.Entries()
    	if len(entries) != 1 || entries[0].Action != "user.ban" || entries[0].ActorUID != u.ID.String() {{ "{" }}
    		t.Fatalf("expected 1 audit entry action=user.ban actor=%s, got %+v", u.ID.String(), entries)
    	{{ "}" }}
    {{ "}" }}
```

**Note for the implementer:** `noopBlacklist`/`newFakeUserRepo`/`seedFakeUser` 是假定复用既有测试文件里的测试替身（`admin_service.go` 本身在生产代码里已有 `noopBlacklist`，测试文件需要一个可导出或包内可见的等价物）；若既有测试套件中命名不同，以实际命名为准调整，但保持"内存 repo、no-op blacklist"的构造方式不变。

- [ ] **Step 2: 运行测试确认失败**

Run: `go test ./internal/application/useradmin/... -v`
Expected: 编译失败（`ResetPassword`、`useradminsvc.New` 新签名不存在）

- [ ] **Step 3: 实现 ResetPassword + 改造 New() + 补齐 3 个既有写点**

重写 `user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml`：

1. import 新增 `"{{.Module}}/internal/infrastructure/audit"`
2. 新增接口：
   ```go
   // PasswordSetter is implemented by usersvc.Service (see its
   // SetPasswordForAdmin method) so ResetPassword can reuse the same
   // old-password-optional logic without useradminsvc importing usersvc's
   // full surface or duplicating hashing/blacklist-revoke logic.
   type PasswordSetter interface {{ "{" }}
   	SetPasswordForAdmin(ctx context.Context, uid, newPassword string) error
   {{ "}" }}
   ```
3. `Service` struct 新增字段：`audit audit.Writer`、`passwordSetter PasswordSetter`
4. `New` 签名：
   ```go
   func New(repo user.Repository, blacklist Blacklist, auditWriter audit.Writer, passwordSetter PasswordSetter) *Service {{ "{" }}
   	return &Service{{ "{" }}repo: repo, blacklist: blacklist, audit: auditWriter, passwordSetter: passwordSetter{{ "}" }}
   {{ "}" }}
   ```
5. `BanUser` 成功路径追加审计（把原来的 `return s.repo.UpdateStatus(...)` 拆成先判断错误，成功后 `_ = s.audit.Write(ctx, audit.Entry{{ "{" }}ActorUID: uid, Action: "user.ban"{{ "}" }})` 再 `return nil`）
6. `UnbanUser` 同理，`Action: "user.unban"`
7. `ForceLogout` 同理（`s.blacklist.Revoke` 成功后写 `Action: "user.force_logout"`）
8. 新增 `ResetPassword`：
   ```go
   func (s *Service) ResetPassword(ctx context.Context, uid, newPassword string) error {{ "{" }}
   	return s.passwordSetter.SetPasswordForAdmin(ctx, uid, newPassword)
   {{ "}" }}
   ```
   （不在这里重复写审计——`usersvc.setPassword` 已经在 `SetPasswordForAdmin` 路径里写了 `user.password_reset`，避免双写）

- [ ] **Step 4: 运行测试确认通过**

Run: `go test ./internal/application/useradmin/... -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_application_useradmin_admin_service_go.yaml user-kitex/kitex-template/internal_application_useradmin_admin_service_test_go.yaml
git commit -m "feat(user-kitex): add useradminsvc.ResetPassword, audit write points for ban/unban/force_logout"
```

---

## Task 6: AdminUnbindProvider 写点 + Handler 层接入三个新 RPC

**Files:**
- Modify: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`

**Interfaces:**
- Consumes：Task 4 的 `usersvc.Service.ChangePassword`；Task 5 的 `useradminsvc.Service.ResetPassword`；Task 3 生成的 `userv1.ChangePasswordReq/Resp`、`userv1.ResetPasswordReq/Resp`（`ListAuditLogs` 留到 Task 7 一并处理，因为它依赖 `audit.Reader` 而非现有两个 service）
- Produces：`UserServiceHandlerImpl.ChangePassword`/`ResetPassword` 方法

**关于 `AdminUnbindProvider` 写点：** 复查 Task 4 Step 3 第 8 点——`AdminUnbindProvider` 在 handler 层直接调用 `h.self.UnbindProvider(ctx, req.Uid, req.Provider)`（复用同一个已经写了 `identity.unbind` 审计的方法），因此 `identity.admin_unbind` 不需要单独的 action 名——管理员代操作与自助解绑共享同一条 `identity.unbind` 审计记录，`ActorUID` 字段记录的是被操作的终端用户 uid 而非发起操作的管理员（现有 handler 也不知道发起管理员是谁——admin-bff-hertz 未透传操作者身份，这是既有设计边界，非本计划引入）。**此项无需代码改动**，仅在设计文档层面已说明，此处不再新建 action。

- [ ] **Step 1: 在 handler 文件末尾追加两个新方法**

在 `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml` 的 `body` 末尾（`AdminUnbindProvider` 方法之后）追加：
```go
func (h *UserServiceHandlerImpl) ChangePassword(ctx context.Context, req *userv1.ChangePasswordReq) (*userv1.ChangePasswordResp, error) {{ "{" }}
	err := h.self.ChangePassword(ctx, req.Uid, req.OldPassword, req.NewPassword)
	return &userv1.ChangePasswordResp{{ "{" }}{{ "}" }}, err
{{ "}" }}

func (h *UserServiceHandlerImpl) ResetPassword(ctx context.Context, req *userv1.ResetPasswordReq) (*userv1.ResetPasswordResp, error) {{ "{" }}
	err := h.admin.ResetPassword(ctx, req.Uid, req.NewPassword)
	return &userv1.ResetPasswordResp{{ "{" }}{{ "}" }}, err
{{ "}" }}
```

- [ ] **Step 2: 编译验证（在渲染出的具体项目实例中）**

Run: `go build ./...`
Expected: 编译通过（`UserServiceHandlerImpl` 满足生成的 `userv1.UserService` 接口——注意此时接口还多出 `ListAuditLogs` 一个方法未实现，`go build` 会在 Task 7 完成前对 handler 赋值给接口的那一行报错；如果 `server.go` 尚未做该赋值处的类型检查触发点，这一步可能仍然通过，Task 7 完成后再整体跑一次 `go build ./...` 兜底确认）

- [ ] **Step 3: Commit**

```bash
git add user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml
git commit -m "feat(user-kitex): wire ChangePassword/ResetPassword RPCs into handler"
```

---

## Task 7: ListAuditLogs RPC（handler + wiring）+ server.go 全量装配

**Files:**
- Modify: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`
- Modify: `user-kitex/kitex-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes：Task 2 的 `audit.Reader`/`audit.NewSQLReader`/`audit.NewMemoryReader`；Task 3 的 `userv1.ListAuditLogsReq/Resp`
- Produces：`UserServiceHandlerImpl` 新增 `auditReader audit.Reader` 字段，`NewUserServiceHandlerImpl` 签名新增该参数；`ListAuditLogs` 方法

- [ ] **Step 1: Handler 新增字段与方法**

修改 `internal_handler_userservice_handler_go.yaml`：
1. import 新增 `"time"` 和 `"{{.Module}}/internal/infrastructure/audit"`
2. `UserServiceHandlerImpl` struct 新增字段 `auditReader audit.Reader`
3. `NewUserServiceHandlerImpl` 签名改为 `func NewUserServiceHandlerImpl(self *usersvc.Service, admin *useradminsvc.Service, auditReader audit.Reader) *UserServiceHandlerImpl`，函数体同步加上 `auditReader: auditReader`
4. 追加方法：
   ```go
   func (h *UserServiceHandlerImpl) ListAuditLogs(ctx context.Context, req *userv1.ListAuditLogsReq) (*userv1.ListAuditLogsResp, error) {{ "{" }}
   	f := audit.ListFilter{{ "{" }}ActorUID: req.ActorUid, Limit: int(req.Limit), Offset: int(req.Offset){{ "}" }}
   	if req.Action != "" {{ "{" }}
   		f.Action = &req.Action
   	{{ "}" }}
   	if req.StartTime != "" {{ "{" }}
   		t, err := time.Parse(time.RFC3339, req.StartTime)
   		if err != nil {{ "{" }}
   			return nil, err
   		{{ "}" }}
   		f.StartTime = &t
   	{{ "}" }}
   	if req.EndTime != "" {{ "{" }}
   		t, err := time.Parse(time.RFC3339, req.EndTime)
   		if err != nil {{ "{" }}
   			return nil, err
   		{{ "}" }}
   		f.EndTime = &t
   	{{ "}" }}
   	entries, total, err := h.auditReader.List(ctx, f)
   	if err != nil {{ "{" }}
   		return nil, err
   	{{ "}" }}
   	items := make([]*userv1.AuditLogItem, 0, len(entries))
   	for _, e := range entries {{ "{" }}
   		items = append(items, &userv1.AuditLogItem{{ "{" }}
   			ActorUid:   e.ActorUID,
   			Action:     e.Action,
   			Target:     e.Target,
   			IpAddress:  e.IPAddress,
   			UserAgent:  e.UserAgent,
   			DetailJson: e.DetailJSON,
   			CreatedAt:  e.CreatedAt.Format(time.RFC3339),
   		{{ "}" }})
   	{{ "}" }}
   	return &userv1.ListAuditLogsResp{{ "{" }}Entries: items, Total: total{{ "}" }}, nil
   {{ "}" }}
   ```

- [ ] **Step 2: server.go 装配审计 Writer/Reader + Blacklist 跨服务共享 + 更新构造调用**

打开 `user-kitex/kitex-template/internal_base_server_server_go.yaml`，找到现有的 `useradminsvc.New(...)`/`usersvc.New(...)`/`handler.NewUserServiceHandlerImpl(...)` 调用点（具体行号需在渲染实例里 grep 确认，模板中按逻辑位置定位：数据库/Redis 初始化之后，两个 svc 构造之前）：

1. 在 blacklist（`noopBlacklist`/`redisBlacklist`，已存在，供 `useradminsvc.New` 使用）初始化代码之后，新增审计读写器初始化：
   ```go
   var auditWriter audit.Writer
   var auditReader audit.Reader
   if cfg.Database.Enabled {{ "{" }}
   	auditWriter = audit.NewSQLWriter(q)
   	auditReader = audit.NewSQLReader(q)
   {{ "}" }} else {{ "{" }}
   	mw := audit.NewMemoryWriter()
   	auditWriter = mw
   	auditReader = audit.NewMemoryReader(mw)
   {{ "}" }}
   ```
   （`q` 是既有 `*gen.Queries` 变量，需在渲染实例里确认实际变量名，与 `userRepo`/`useradminsvc`/`usersvc` 构造使用的是同一个 `gen.Queries` 实例）
2. `usersvc.New(...)` 调用点追加两个新参数：`auditWriter, blacklist`（`blacklist` 复用已有的、原本只传给 `useradminsvc.New` 的那个变量——两个 service 现在共享同一个 blacklist 实例，这是 Task 4 Step 3 注释里承诺的行为）
3. `useradminsvc.New(...)` 调用点追加两个新参数：`auditWriter, userSvc`（`userSvc` 是刚构造出的 `*usersvc.Service` 变量，实现了 `PasswordSetter` 接口——注意构造顺序必须先建 `usersvc.Service` 再建 `useradminsvc.Service`，若现有代码顺序相反需要调整）
4. `handler.NewUserServiceHandlerImpl(...)` 调用点追加 `auditReader` 参数

- [ ] **Step 3: 编译验证**

Run: `go build ./...`
Expected: 编译通过，无未使用变量/未满足接口错误

- [ ] **Step 4: Commit**

```bash
git add user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml user-kitex/kitex-template/internal_base_server_server_go.yaml
git commit -m "feat(user-kitex): wire ListAuditLogs RPC and audit reader/writer + shared blacklist into server.go"
```

---

## Task 8: rate limit resolver 扩展新 phase（password_change）

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml`
- Modify: `user-bff-hertz/hertz-template/conf_go.yaml`（新增 `PasswordChange` 字段，具体行号在渲染实例中定位 `RateLimitConfig` struct）
- Modify: `admin-bff-hertz/hertz-template/conf_go.yaml`（同上）

**Interfaces:**
- Produces：`ratelimit.Resolver.phaseConfig` 支持 `"password_change"` 之外，`conf.RateLimitConfig.PasswordChange RateLimitPhaseConfig` 字段（供 Task 9/10 路由使用）

- [ ] **Step 1: 两个服务的 `conf_go.yaml` 里 `RateLimitConfig` struct 新增字段**

```go
PasswordChange RateLimitPhaseConfig `yaml:"password_change"`
```
紧跟在既有 `PostAuth RateLimitPhaseConfig \`yaml:"login"\`` 字段之后。

- [ ] **Step 2: 两个服务的 `resolver.go` 里 `phaseConfig` 方法新增分支**

```go
func (r *Resolver) phaseConfig(phase string) conf.RateLimitPhaseConfig {{ "{" }}
	switch strings.ToLower(strings.TrimSpace(phase)) {{ "{" }}
	case "post_auth":
		return r.cfg.PostAuth
	case "password_change":
		return r.cfg.PasswordChange
	default:
		return r.cfg.PreAuth
	{{ "}" }}
{{ "}" }}
```
（替换原来的 if/else 两分支版本）

- [ ] **Step 3: 编译验证（在两个服务的渲染实例中各跑一次）**

Run: `go build ./...`
Expected: 编译通过

- [ ] **Step 4: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml user-bff-hertz/hertz-template/conf_go.yaml admin-bff-hertz/hertz-template/internal_pkg_ratelimit_resolver_go.yaml admin-bff-hertz/hertz-template/conf_go.yaml
git commit -m "feat(ratelimit): add password_change phase to resolver and config in user-bff-hertz/admin-bff-hertz"
```

---

## Task 9: user-bff-hertz 自助改密码端点

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_handler_auth_handler_go.yaml`（假定既有 `AuthHandler`——即 Register/Login 所在文件；若实际文件名不同，以 grep `func.*AuthHandler.*Login` 定位为准）
- Modify: `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`

**Interfaces:**
- Consumes：Task 6 产出的 `userCli.ChangePassword`；`middleware.GetClaims(c)` 获取 uid（已存在）

- [ ] **Step 1: AuthHandler 新增 ChangePassword 方法**

在既有 `AuthHandler`（`userCli userservice.Client` 字段）文件中追加：
```go
type ChangePasswordRequest struct {{ "{" }}
	OldPassword string `json:"old_password" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=8"`
{{ "}" }}

func (h *AuthHandler) ChangePassword(ctx context.Context, c *app.RequestContext) {{ "{" }}
	claims, ok := middleware.GetClaims(c)
	if !ok {{ "{" }}
		response.ErrorCode(c, response.CodeTokenInvalid)
		return
	{{ "}" }}
	var req ChangePasswordRequest
	if err := c.BindJSON(&req); err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	{{ "}" }}
	if _, err := h.userCli.ChangePassword(ctx, &userv1.ChangePasswordReq{{ "{" }}
		Uid:         claims.Uid,
		OldPassword: req.OldPassword,
		NewPassword: req.NewPassword,
	{{ "}" }}); err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeInternalError)
		return
	{{ "}" }}
	response.OK(c, map[string]string{{ "{" }}"status": "password_changed"{{ "}" }})
{{ "}" }}
```
**Note for the implementer:** `middleware`/`response`/`userv1` 的具体 import 路径与既有 handler 文件顶部一致；`c.BindJSON`/`response.ErrorCode`/`response.OK` 的确切签名以既有 `AuthHandler.Register`/`Login` 方法的实际写法为准做适配（本计划基于 admin-bff-hertz `TerminalUserHandler` 与 user-bff-hertz `JWTAuth` 中间件已确认的 `response` 包 API 推断，实现时对照同文件内 `Register`/`Login` 的 JSON 绑定写法保持一致，若该文件用的是别的绑定方式如 `c.Bind(&req)` 而非 `BindJSON`，以既有写法为准）。

- [ ] **Step 2: 路由挂载（受保护 + 限流）**

修改 `user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml`，在 `auth.POST("/login", ...)` 之后、`oauth := auth.Group("/oauth")` 之前插入：
```go
authProtected := auth.Group("")
authProtected.Use(middleware.JWTAuth(cfg.Auth.Token))
authProtected.POST("/change-password", middleware.RateLimit("password_change", cfg.RateLimit, cfg.RateLimit.PasswordChange, resolver), authHandler.ChangePassword)
```

- [ ] **Step 3: 编译验证**

Run: `go build ./...`
Expected: 编译通过

- [ ] **Step 4: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_auth_handler_go.yaml user-bff-hertz/hertz-template/internal_router_userbffservice_go.yaml
git commit -m "feat(user-bff-hertz): add self-service POST /auth/change-password endpoint"
```

---

## Task 10: admin-bff-hertz 管理员重置密码端点 + 审计日志查询端点

**Files:**
- Modify: `admin-bff-hertz/hertz-template/internal_handler_terminal_user_go.yaml`
- Modify: `admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml`

**Interfaces:**
- Consumes：Task 6 的 `userCli.ResetPassword`；Task 7 的 `userCli.ListAuditLogs`

- [ ] **Step 1: TerminalUserHandler 新增两个方法**

在 `internal_handler_terminal_user_go.yaml` 的 `body` 末尾（`UnbindIdentity` 之后）追加：
```go
type ResetPasswordRequest struct {{ "{" }}
	NewPassword string `json:"new_password" binding:"required,min=8"`
{{ "}" }}

func (h *TerminalUserHandler) ResetPassword(ctx context.Context, c *app.RequestContext) {{ "{" }}
	uid := c.Param("uid")
	if uid == "" {{ "{" }}
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	{{ "}" }}
	var req ResetPasswordRequest
	if err := c.BindJSON(&req); err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	{{ "}" }}
	if _, err := h.userCli.ResetPassword(ctx, &userv1.ResetPasswordReq{{ "{" }}Uid: uid, NewPassword: req.NewPassword{{ "}" }}); err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeInternalError)
		return
	{{ "}" }}
	response.OK(c, map[string]string{{ "{" }}"status": "password_reset"{{ "}" }})
{{ "}" }}

func (h *TerminalUserHandler) ListAuditLogs(ctx context.Context, c *app.RequestContext) {{ "{" }}
	uid := c.Param("uid")
	if uid == "" {{ "{" }}
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	{{ "}" }}
	limit := int32(20)
	offset := int32(0)
	if v := string(c.Query("limit")); v != "" {{ "{" }}
		if n, err := strconv.Atoi(v); err == nil {{ "{" }}
			limit = int32(n)
		{{ "}" }}
	{{ "}" }}
	if v := string(c.Query("offset")); v != "" {{ "{" }}
		if n, err := strconv.Atoi(v); err == nil {{ "{" }}
			offset = int32(n)
		{{ "}" }}
	{{ "}" }}
	req := &userv1.ListAuditLogsReq{{ "{" }}
		ActorUid: uid,
		Action:   string(c.Query("action")),
		StartTime: string(c.Query("start_time")),
		EndTime:   string(c.Query("end_time")),
		Limit:    limit,
		Offset:   offset,
	{{ "}" }}
	resp, err := h.userCli.ListAuditLogs(ctx, req)
	if err != nil {{ "{" }}
		response.ErrorCode(c, response.CodeInternalError)
		return
	{{ "}" }}
	response.OK(c, resp)
{{ "}" }}
```

- [ ] **Step 2: 路由挂载**

修改 `internal_router_adminbffservice_go.yaml`，在 `terminalUsers.DELETE("/:uid/identities/:provider", ...)` 之后追加：
```go
	terminalUsers.POST("/:uid/reset-password", middleware.RequirePermission("terminal_user:password-reset"), middleware.Authz(rbacCli), terminalUserHandler.ResetPassword)
	terminalUsers.GET("/:uid/audit-logs", middleware.RequirePermission("terminal_user:audit-log:read"), middleware.Authz(rbacCli), terminalUserHandler.ListAuditLogs)
```
注意限流：设计文档要求管理员重置端点也限流。`admin-bff-hertz` 现有路由均未套用 `middleware.RateLimit`（该中间件目前只在 `user-bff-hertz` 的 `/auth` 路由上使用），若要在此处加限流，需要先确认 `admin-bff-hertz` 是否已经在 `Register{{.ServiceName}}BffServiceRoutes` 里持有 `*ratelimit.Resolver` 实例（当前函数签名 `func Register...Routes(h *server.Hertz, rbacAuthCli authservice.Client, rbacCli rbacservice.Client, rulecenterCli ruleservice.Client, userCli userservice.Client)` 未见 resolver 参数）——若没有，本 Task 范围内追加 `resolver *ratelimit.Resolver` 参数并同步修改 `server.go` 调用点，然后在 `reset-password` 路由上追加 `middleware.RateLimit("password_change", cfg.RateLimit, cfg.RateLimit.PasswordChange, resolver)`（紧跟在 `middleware.RequirePermission` 之后、`middleware.Authz` 之前均可，两者顺序目前只对 `Authz`/`RequirePermission` 的相对顺序有强约束，`RateLimit` 放前后皆可，建议放最前防止未授权流量也消耗限流配额）。

- [ ] **Step 3: 编译验证**

Run: `go build ./...`
Expected: 编译通过

- [ ] **Step 4: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_terminal_user_go.yaml admin-bff-hertz/hertz-template/internal_router_adminbffservice_go.yaml
git commit -m "feat(admin-bff-hertz): add reset-password and audit-logs endpoints under /terminal-users/:uid"
```

---

## Task 11: admin-bff-hertz handler 测试 + README 更新

**Files:**
- Modify: `admin-bff-hertz/hertz-template/internal_handler_terminal_user_test_go.yaml`
- Modify: `admin-bff-hertz/README.md`

**Interfaces:**
- 无新增接口，覆盖 Task 10 新增的两个 handler

- [ ] **Step 1: 追加 handler 测试**

在既有 `internal_handler_terminal_user_test_go.yaml` 测试文件中，参照文件内 `TestTerminalUserHandler_Ban`（或同类既有测试）的 mock `userservice.Client` 写法，追加：
```go
func TestTerminalUserHandler_ResetPassword_Success(t *testing.T) {{ "{" }}
	// 参照既有 Ban 测试的 mock 客户端搭建方式，mock ResetPassword 返回成功，
	// 断言 HTTP 200 且响应体包含 status: password_reset
{{ "}" }}

func TestTerminalUserHandler_ResetPassword_MissingUID_BadRequest(t *testing.T) {{ "{" }}
	// 不带 :uid 路径参数发起请求，断言返回 CodeRequestParamInvalid
{{ "}" }}

func TestTerminalUserHandler_ListAuditLogs_Success(t *testing.T) {{ "{" }}
	// mock ListAuditLogs 返回 2 条记录，断言 HTTP 200 且响应体透传 entries/total
{{ "}" }}
```
**Note for the implementer:** 具体 mock 框架（手写 stub / gomock / testify mock）与断言库以该测试文件既有代码为准，本计划不重复既有约定；三个测试函数的具体断言代码需要在实现阶段对照既有 `Ban`/`Unban` 测试的实际代码逐字段补全，这里只给出测试意图与覆盖范围，避免在未读到该测试文件全文前编造不匹配既有 mock 接口的代码。

- [ ] **Step 2: 运行测试确认通过**

Run: `go test ./internal/handler/... -run TestTerminalUserHandler -v`
Expected: PASS

- [ ] **Step 3: 更新 README**

在 `admin-bff-hertz/README.md` 的 "Seams" 章节（既有 `terminal_user`/`grpc.terminal_user` 相关条目附近）追加一条，说明新增的两个端点及其权限码：`terminal_user:password-reset`、`terminal_user:audit-log:read`，并注明审计日志查询仅返回指定 `:uid` 的记录（无跨用户查询能力）。

- [ ] **Step 4: Commit**

```bash
git add admin-bff-hertz/hertz-template/internal_handler_terminal_user_test_go.yaml admin-bff-hertz/README.md
git commit -m "test(admin-bff-hertz): cover reset-password and audit-logs handlers, document new permission codes"
```

---

## Self-Review Notes（写作后自查，供执行前参考）

- **Spec 覆盖**：设计文档 6 个章节（表结构/基础设施/写点/密码修改重置/查询接口/测试）分别对应 Task 1-2 / Task 4-6 / Task 3+6+9+10 / Task 7 / Task 11，无遗漏。
- **已知需要在实现时对照真实生成结果调整的点**（非占位符，是模板生成结果依赖）：Task 2 Step 4 的 `gen.ListAuditLogParams`/`CountAuditLogParams` 字段名；Task 4/5/11 里标注为"assumed existing helper"的测试辅助函数名，需要执行者先读一遍目标文件真实内容再对齐命名。
- **任务顺序具有依赖性，必须按 1→11 顺序执行**：Task 3（proto）必须先于 Task 6/7（handler 使用生成类型）；Task 4 必须先于 Task 5（`PasswordSetter` 接口）；Task 8 必须先于 Task 9/10（`cfg.RateLimit.PasswordChange` 字段）。
