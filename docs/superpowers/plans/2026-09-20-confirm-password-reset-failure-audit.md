# ConfirmPasswordReset 失败路径审计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `user-kitex` 的 `ConfirmPasswordReset`（忘记密码/短信重置确认）在凭证校验失败时写入一条通用审计条目，且不泄露具体失败原因，不改变调用方可观察的响应或时序。

**Architecture:** 复用 `setPassword` 已有的 `s.audit.Write(ctx, audit.Entry{...})` fire-and-forget 模式，在 `ConfirmPasswordReset` 的 4 个既有失败分支各自 `return` 前插入同一个 Action 字符串的审计写入；`ActorUID`/`Target` 依据"此时是否已知道 `tok.UserID`"分两类填法（已与用户在设计阶段确认为方案 A）。不新增类型、不新增接口、不改变函数签名。

**Tech Stack:** Go 1.x, `internal/infrastructure/audit`（`audit.Writer`/`audit.Entry`，已存在）

**Spec:** `docs/superpowers/specs/2026-09-20-confirm-password-reset-failure-audit-design.md`

## Global Constraints

- 所有失败分支必须使用**完全相同**的 Action 字符串字面量 `"user.password_reset_confirm.failure"`，不得因分支不同而变化，也不得附带能区分具体原因的 `DetailJSON`（反枚举要求，来自 Issue #76 验收标准）。
- 审计写入必须是 fire-and-forget：`_ = s.audit.Write(ctx, audit.Entry{...})`，与 `setPassword` 现有写法一致；不得阻塞、不得改变函数的返回值或返回时机。
- `ActorUID`/`Target`：token 查找本身失败（凭证未知/过期/已用）时，身份未知 → 留空（零值 `""`）；SMS 渠道下已经拿到 `tok.UserID` 的 3 个分支 → 填 `tok.UserID.String()`（`Target` 同 `ActorUID`，与 `setPassword` 自服务路径"只填 ActorUID、Target 留空"的既有约定一致——这里额外把 `Target` 也设为同一 UID 是因为这条审计记录的对象就是这个账户本身，便于按 `Target` 检索；见设计文档）。
- 不改变 `ConfirmPasswordReset` 的函数签名、返回的错误消息文案、`MarkUsed`/`setPassword` 调用；不新增 IP/UA 参数（设计文档已注明为 out-of-scope）。
- SMS 分支中 `s.repo.GetByID(ctx, tok.UserID)` 失败这条子分支，当前测试基建（`fakeRepo`）没有提供删除已注册用户的方法，无法在不新增测试基础设施的前提下触发；本计划在该分支写入相同的审计调用（与其余 SMS 分支代码形状一致），但不为它单独造测试用例——这是刻意的范围裁剪，不是遗留 TODO。

---

## Task 1: 凭证查找失败分支（未知/过期/已用凭证）写入审计

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`（`ConfirmPasswordReset` 函数，模板行 558-565）
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`（`TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError` 行 465-470、`TestConfirmPasswordReset_ReusedCredential_Rejected` 行 472-488）

**Interfaces:**
- Consumes：既有 `audit.Writer`（`s.audit` 字段，`Service` 上已存在）、`audit.Entry{ActorUID, Action, Target, IPAddress, UserAgent, DetailJSON string; CreatedAt time.Time}`（已存在，无需改动）
- Produces：无新增导出符号——本任务只在既有函数体内插入一行审计写入

- [ ] **Step 1: 编写失败测试（RED）— 更新 `TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError`**

在 `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml` 中，把（当前第 465-470 行，模板转义 `{{ "{" }}`/`{{ "}" }}` 对应 Go 源码的 `{`/`}`）：

```yaml
func TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, _, _ := newTestServiceWithReset()
	if err := svc.ConfirmPasswordReset(context.Background(), "no-such-token", "", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error for unknown credential")
	{{ "}" }}
{{ "}" }}
```

替换为：

```yaml
func TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, _, aw := newTestServiceWithReset()
	if err := svc.ConfirmPasswordReset(context.Background(), "no-such-token", "", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error for unknown credential")
	{{ "}" }}
	if len(aw.Entries()) != 1 {{ "{" }}
		t.Fatalf("expected exactly 1 audit entry, got %d", len(aw.Entries()))
	{{ "}" }}
	entry := aw.Entries()[0]
	if entry.Action != "user.password_reset_confirm.failure" {{ "{" }}
		t.Fatalf("expected action %q, got %q", "user.password_reset_confirm.failure", entry.Action)
	{{ "}" }}
	if entry.ActorUID != "" || entry.Target != "" {{ "{" }}
		t.Fatalf("expected no actor/target for an unknown credential (identity is not known), got ActorUID=%q Target=%q", entry.ActorUID, entry.Target)
	{{ "}" }}
	if entry.DetailJSON != "" {{ "{" }}
		t.Fatalf("expected no detail that could leak the failure reason, got %q", entry.DetailJSON)
	{{ "}" }}
{{ "}" }}
```

Also update `TestConfirmPasswordReset_ReusedCredential_Rejected`（当前第 472-488 行）from:

```yaml
func TestConfirmPasswordReset_ReusedCredential_Rejected(t *testing.T) {{ "{" }}
	svc, _, es, _, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "dave", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "dave@example.com"
	_ = svc.RequestPasswordReset(ctx, "dave@example.com", "email")
	token := extractTokenFromLink(t, es.Sent()[0].Link)

	if err := svc.ConfirmPasswordReset(ctx, token, "", "brand-new-password-1"); err != nil {{ "{" }}
		t.Fatalf("first confirm: %v", err)
	{{ "}" }}
	if err := svc.ConfirmPasswordReset(ctx, token, "", "another-password-2"); err == nil {{ "{" }}
		t.Fatal("expected reused credential to be rejected")
	{{ "}" }}
{{ "}" }}
```

to:

```yaml
func TestConfirmPasswordReset_ReusedCredential_Rejected(t *testing.T) {{ "{" }}
	svc, _, es, _, aw := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "dave", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Email = "dave@example.com"
	_ = svc.RequestPasswordReset(ctx, "dave@example.com", "email")
	token := extractTokenFromLink(t, es.Sent()[0].Link)

	if err := svc.ConfirmPasswordReset(ctx, token, "", "brand-new-password-1"); err != nil {{ "{" }}
		t.Fatalf("first confirm: %v", err)
	{{ "}" }}
	if err := svc.ConfirmPasswordReset(ctx, token, "", "another-password-2"); err == nil {{ "{" }}
		t.Fatal("expected reused credential to be rejected")
	{{ "}" }}
	found := false
	for _, e := range aw.Entries() {{ "{" }}
		if e.Action == "user.password_reset_confirm.failure" {{ "{" }}
			found = true
			if e.ActorUID != "" || e.Target != "" {{ "{" }}
				t.Fatalf("expected no actor/target for a reused/unknown credential, got ActorUID=%q Target=%q", e.ActorUID, e.Target)
			{{ "}" }}
		{{ "}" }}
	{{ "}" }}
	if !found {{ "{" }}
		t.Fatal("expected a user.password_reset_confirm.failure audit entry on reuse")
	{{ "}" }}
{{ "}" }}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/application/user/... -run "TestConfirmPasswordReset_UnknownCredential_ReturnsGenericError|TestConfirmPasswordReset_ReusedCredential_Rejected" -v`
Expected: FAIL — `len(aw.Entries())` 为 0（`entry := aw.Entries()[0]` 会 panic/index out of range，或第一个断言先 fail），`found` 为 `false`

- [ ] **Step 3: 实现 — 在凭证查找失败分支写入审计**

在 `user-kitex/kitex-template/internal_application_user_user_service_go.yaml` 中，把（当前第 558-565 行）：

```yaml
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, phone, newPassword string) error {{ "{" }}
	tok, err := s.resetRepo.GetValid(ctx, hashCredential(credential))
	if err != nil {{ "{" }}
		if !errors.Is(err, passwordreset.ErrNotFound) {{ "{" }}
			log.Printf("user: ConfirmPasswordReset lookup failed: %v", err)
		{{ "}" }}
		return errors.New("user: reset credential is invalid or expired")
	{{ "}" }}
```

替换为：

```yaml
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, phone, newPassword string) error {{ "{" }}
	tok, err := s.resetRepo.GetValid(ctx, hashCredential(credential))
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/application/user/... -run "TestConfirmPasswordReset" -v`
Expected: PASS（含本任务修改的两个测试，以及其余尚未改动的 `TestConfirmPasswordReset_*` 测试——SMS 相关测试此时仍为旧断言，不受影响，仍应 PASS）

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_go.yaml user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "fix(user-kitex): audit ConfirmPasswordReset unknown/expired/reused credential failures"
```

---

## Task 2: SMS 渠道失败分支（缺手机号/用户查找失败/手机号不匹配）写入审计

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`（`ConfirmPasswordReset` 函数，模板行 566-580，紧接 Task 1 之后）
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`（`TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError` 行 518-531、`TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError` 行 533-546）

**Interfaces:**
- Consumes：Task 1 中确认可用的 `s.audit.Write(ctx, audit.Entry{...})` 调用形状；`tok.UserID`（`passwordreset.MemoryRepository`/`GetValid` 返回的 token 结构体既有字段，`user.ID` 类型，`.String()` 方法已存在）
- Produces：无新增导出符号

- [ ] **Step 1: 编写失败测试（RED）— 更新两个 SMS 失败测试**

在 `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml` 中，把（当前第 518-531 行）：

```yaml
func TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, ss, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "frank", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550002222"
	_ = svc.RequestPasswordReset(ctx, "+15550002222", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error when phone is missing for an sms-channel token")
	{{ "}" }}
{{ "}" }}
```

替换为：

```yaml
func TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, ss, aw := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "frank", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550002222"
	_ = svc.RequestPasswordReset(ctx, "+15550002222", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error when phone is missing for an sms-channel token")
	{{ "}" }}
	if len(aw.Entries()) != 1 {{ "{" }}
		t.Fatalf("expected exactly 1 audit entry, got %d", len(aw.Entries()))
	{{ "}" }}
	entry := aw.Entries()[0]
	if entry.Action != "user.password_reset_confirm.failure" {{ "{" }}
		t.Fatalf("expected action %q, got %q", "user.password_reset_confirm.failure", entry.Action)
	{{ "}" }}
	if entry.ActorUID != regOut.Uid {{ "{" }}
		t.Fatalf("expected ActorUID %q (token's owning user is known), got %q", regOut.Uid, entry.ActorUID)
	{{ "}" }}
	if entry.DetailJSON != "" {{ "{" }}
		t.Fatalf("expected no detail that could leak the failure reason, got %q", entry.DetailJSON)
	{{ "}" }}
{{ "}" }}
```

Also update `TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError`（当前第 533-546 行）from:

```yaml
func TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, ss, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "grace", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550003333"
	_ = svc.RequestPasswordReset(ctx, "+15550003333", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "+15550009999", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error when phone does not match the token's owning account")
	{{ "}" }}
{{ "}" }}
```

to:

```yaml
func TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError(t *testing.T) {{ "{" }}
	svc, _, _, ss, aw := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{{ "{" }}Username: "grace", Password: "correct horse battery staple"{{ "}" }})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550003333"
	_ = svc.RequestPasswordReset(ctx, "+15550003333", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "+15550009999", "brand-new-password-1"); err == nil {{ "{" }}
		t.Fatal("expected an error when phone does not match the token's owning account")
	{{ "}" }}
	if len(aw.Entries()) != 1 {{ "{" }}
		t.Fatalf("expected exactly 1 audit entry, got %d", len(aw.Entries()))
	{{ "}" }}
	entry := aw.Entries()[0]
	if entry.Action != "user.password_reset_confirm.failure" {{ "{" }}
		t.Fatalf("expected action %q, got %q", "user.password_reset_confirm.failure", entry.Action)
	{{ "}" }}
	if entry.ActorUID != regOut.Uid {{ "{" }}
		t.Fatalf("expected ActorUID %q (token's owning user is known), got %q", regOut.Uid, entry.ActorUID)
	{{ "}" }}
	if entry.DetailJSON != "" {{ "{" }}
		t.Fatalf("expected no detail that could leak the failure reason, got %q", entry.DetailJSON)
	{{ "}" }}
{{ "}" }}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/application/user/... -run "TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError|TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError" -v`
Expected: FAIL — `len(aw.Entries())` 为 0

- [ ] **Step 3: 实现 — 在 SMS 渠道 3 个失败分支写入审计**

在 `user-kitex/kitex-template/internal_application_user_user_service_go.yaml` 中，把（当前第 566-580 行，紧接 Task 1 修改后的代码之后）：

```yaml
	if tok.Channel == "sms" {{ "{" }}
		if phone == "" {{ "{" }}
			return errors.New("user: reset credential is invalid or expired")
		{{ "}" }}
		u, err := s.repo.GetByID(ctx, tok.UserID)
		if err != nil {{ "{" }}
			if !errors.Is(err, user.ErrNotFound) {{ "{" }}
				log.Printf("user: ConfirmPasswordReset phone lookup failed: %v", err)
			{{ "}" }}
			return errors.New("user: reset credential is invalid or expired")
		{{ "}" }}
		if u.Phone != phone {{ "{" }}
			return errors.New("user: reset credential is invalid or expired")
		{{ "}" }}
	{{ "}" }}
```

替换为：

```yaml
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/application/user/... -run "TestConfirmPasswordReset" -v`
Expected: PASS — 全部 `TestConfirmPasswordReset_*` 测试通过，包括本任务和 Task 1 新增的审计断言，以及未改动的成功路径测试（`ValidCredential`/`SMSChannel_CorrectPhone`/`EmailChannel_PhoneIgnored`）

- [ ] **Step 5: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_go.yaml user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "fix(user-kitex): audit ConfirmPasswordReset SMS phone-check failures"
```

---

## Task 3: 全量回归

**Files:** 无新增/修改（纯验证任务）

**Interfaces:** 无

- [ ] **Step 1: 跑整个 user 包测试确认无回归**

Run: `go build ./... && go test ./internal/application/user/... -v`
Expected: 编译通过，全部测试 PASS（包括 `TestChangePassword_WrongOldPassword_Rejected` 等既有 `user.password_change.failure` 测试，确认未被本次改动波及）

- [ ] **Step 2: 跑一次全仓库测试兜底**

Run: `go build ./... && go test -race -count=1 ./...`
Expected: 编译通过，测试全部 PASS，无因本次改动引入的其他包编译错误

- [ ] **Step 3: 无需 commit（本任务纯验证，无文件改动）**
