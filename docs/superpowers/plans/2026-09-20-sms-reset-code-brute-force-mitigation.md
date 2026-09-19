# SMS 重置验证码绑定账号标识 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Issue #75——`ConfirmPasswordReset` 的 SMS 渠道路径新增 `phone` 标识校验，收敛 6 位短信验证码的暴力枚举面（把"猜中任意账号的有效 token"收窄为"必须同时猜中验证码且指定正确账号"）。

**Architecture:** 不引入新基础设施、不做数据库迁移。在已有的 `ConfirmPasswordReset` 应用服务方法里新增一个 `phone` 参数；当被 `resetRepo.GetValid` 取出的 token 的 `Channel == "sms"` 时，用已有的 `s.repo.GetByID(ctx, tok.UserID)` 取出该 token 归属账号，比对其 `Phone` 字段与调用方传入的 `phone` 是否一致，不一致复用现有的通用"凭证无效或已过期"错误文案（防枚举，见设计文档）。这个签名变更沿 IDL → kitex handler → 应用服务 → BFF DTO/handler 四层依次传导。

**Tech Stack:** Go, Kitex (protobuf IDL), Hertz（BFF 层，无需改动数据库/sqlc）

**Spec:** `docs/superpowers/specs/2026-09-20-sms-reset-code-brute-force-mitigation-design.md`

## Global Constraints

- 仅 SMS 渠道生效；`channel == "email"` 时 `phone` 参数被完全忽略，行为与 Issue #71 合并时一致，不做任何改动
- 不引入数据库迁移；`password_reset_tokens` 表结构不变
- 校验失败（`phone` 缺失或与账号不符）复用现有通用错误文案 `"user: reset credential is invalid or expired"`（与"凭证不存在/已过期/已使用"完全同形，不给攻击者任何区分信号）——沿用该文件既有约定（无共享错误变量，每处内联 `errors.New(...)`），不新增共享 sentinel
- 不做 per-token 失败计数器（用户决策，见设计文档"被否决的方案"一节）
- `user-kitex/idl/user.proto` 与 `user-bff-hertz/idl/user.proto` 是两份独立维护、内容重复的 IDL 副本——`user-bff-hertz` 用 `ncgo add kitex-client` 生成**自己的** `kitex_gen`，不导入 `user-kitex` 的（见 `internal_base_server_server_go.yaml` L94-96 注释），两处 IDL 改动必须同步，缺一会导致两侧生成的 `ConfirmPasswordResetReq` 结构体字段不一致
- 修改 `.proto` 后必须在**渲染出的具体项目实例**里重新生成 kitex_gen：`user-kitex` 侧 `make update`；`user-bff-hertz` 侧 `ncgo add kitex-client`
- `user-kitex/kitex-template/*.yaml`（`internal_application_user_user_service_go.yaml`、`..._test_go.yaml`、`internal_handler_userservice_handler_go.yaml`）用 `body: |-`（`update_behavior.type: cover`）；`user-bff-hertz/hertz-template/*.yaml`（`internal_handler_auth_go.yaml`、`internal_router_userbffservice_test_go.yaml`）用 `body: |`（`update_behavior.type: skip` + `loop_service: true`）——编辑时保持各自原有 convention 不变，字面量大括号一律用 `{{ "{" }}`/`{{ "}" }}` 转义
- `user.ID` 是 `= uuid.UUID` 的类型别名，非独立包装类型
- 每个 Task 结束后本地跑 `go build ./... && go test ./... -v`（在渲染出的实例里）确认不破坏既有测试，再提交

---

## Task 1: `user.proto` IDL 新增 `phone` 字段（两份副本同步）

**Files:**
- Modify: `user-kitex/idl/user.proto`
- Modify: `user-bff-hertz/idl/user.proto`

**Interfaces:**
- Produces：`ConfirmPasswordResetReq.Phone`（proto field 3，string）——供 Task 3（kitex handler）、Task 4（BFF handler）取用生成后的 Go 结构体字段

- [ ] **Step 1: 编辑 `user-kitex/idl/user.proto`**

把现有（L238-241）：
```proto
message ConfirmPasswordResetReq {
  string credential = 1;    // the email link's token, or the SMS code
  string new_password = 2;
}
```
改为：
```proto
message ConfirmPasswordResetReq {
  string credential = 1;    // the email link's token, or the SMS code
  string new_password = 2;
  string phone = 3; // required when the matched token's channel is "sms"; ignored for "email" tokens. A missing/mismatched phone returns the same generic invalid-credential error as any other failure — see design doc's anti-enumeration section.
}
```

- [ ] **Step 2: 对 `user-bff-hertz/idl/user.proto` 做完全相同的编辑**

同一位置（L143-146）应用同样的字段新增，两份文件改动后内容须逐字一致（这是本仓库两份 IDL 副本一贯保持同步的方式，`user-bff-hertz` 靠这份自己的副本生成本地 `kitex_gen`）。

- [ ] **Step 3: 渲染实例中重新生成 kitex_gen**

在渲染出的 `user-kitex` 项目实例里：
```bash
make update
```
Expected: `kitex_gen/api/user/v1` 下 `ConfirmPasswordResetReq` 结构体新增 `Phone string` 字段。

在渲染出的 `user-bff-hertz` 项目实例里：
```bash
ncgo add kitex-client
```
Expected: 该项目自己的 `kitex_gen/api/user/v1` 下 `ConfirmPasswordResetReq` 同样新增 `Phone string` 字段。

- [ ] **Step 4: Commit**

```bash
git add user-kitex/idl/user.proto user-bff-hertz/idl/user.proto
git commit -m "feat(user-kitex,user-bff-hertz): add phone field to ConfirmPasswordResetReq IDL"
```

---

## Task 2: `usersvc.Service.ConfirmPasswordReset` 新增 SMS 渠道 `phone` 校验

**Files:**
- Modify: `user-kitex/kitex-template/internal_application_user_user_service_go.yaml`
- Test: `user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml`

**Interfaces:**
- Consumes：`user.Repository.GetByID(ctx, id ID) (*User, error)`（已存在，`internal_domain_user_repository_go.yaml` L16）；`passwordreset.Token.Channel`/`.UserID`（已存在）
- Produces：`func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, phone, newPassword string) error`——新签名，供 Task 3（kitex handler）调用

- [ ] **Step 1: 写失败测试（新增 3 个 SMS 用例 + 更新既有 3 个 email 用例的调用签名）**

在 `internal_application_user_user_service_test_go.yaml` 里，把既有的三处调用（L447、L467、L482 和 L485）：
```go
if err := svc.ConfirmPasswordReset(ctx, token, "brand-new-password-1"); err != nil {
```
```go
if err := svc.ConfirmPasswordReset(context.Background(), "no-such-token", "brand-new-password-1"); err == nil {
```
```go
if err := svc.ConfirmPasswordReset(ctx, token, "brand-new-password-1"); err != nil {
```
```go
if err := svc.ConfirmPasswordReset(ctx, token, "another-password-2"); err == nil {
```
全部在 `newPassword` 前插入一个空字符串 `phone` 参数（email 渠道下 `phone` 被忽略，传空字符串即可）：
```go
if err := svc.ConfirmPasswordReset(ctx, token, "", "brand-new-password-1"); err != nil {
```
```go
if err := svc.ConfirmPasswordReset(context.Background(), "no-such-token", "", "brand-new-password-1"); err == nil {
```
```go
if err := svc.ConfirmPasswordReset(ctx, token, "", "brand-new-password-1"); err != nil {
```
```go
if err := svc.ConfirmPasswordReset(ctx, token, "", "another-password-2"); err == nil {
```

然后在文件末尾（`TestConfirmPasswordReset_ReusedCredential_Rejected` 之后）追加 3 个新测试，复用 `newTestServiceWithReset()` 五元组 fixture 与 `notify.LogSMSSender.Sent()[i].Code` 取出明文验证码（`SendPasswordResetCode(ctx, to, code)` 把明文 `code` 存进 `SentSMS.Code`，`internal_infrastructure_notify_sender_go.yaml` L62-83 已确认）：

```go
func TestConfirmPasswordReset_SMSChannel_CorrectPhone_Succeeds(t *testing.T) {
	svc, _, _, ss, aw := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{Username: "erin", Password: "correct horse battery staple"})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550001111"
	_ = svc.RequestPasswordReset(ctx, "+15550001111", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "+15550001111", "brand-new-password-1"); err != nil {
		t.Fatalf("ConfirmPasswordReset: %v", err)
	}
	updated, _ := svc.repo.GetByID(ctx, uid)
	if ok, _ := auth.VerifyPassword("brand-new-password-1", *updated.PasswordHash); !ok {
		t.Fatal("password was not updated")
	}
	found := false
	for _, e := range aw.Entries() {
		if e.Action == "user.password_reset_confirmed" {
			found = true
		}
	}
	if !found {
		t.Fatal("expected a user.password_reset_confirmed audit entry")
	}
}

func TestConfirmPasswordReset_SMSChannel_MissingPhone_ReturnsGenericError(t *testing.T) {
	svc, _, _, ss, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{Username: "frank", Password: "correct horse battery staple"})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550002222"
	_ = svc.RequestPasswordReset(ctx, "+15550002222", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "", "brand-new-password-1"); err == nil {
		t.Fatal("expected an error when phone is missing for an sms-channel token")
	}
}

func TestConfirmPasswordReset_SMSChannel_WrongPhone_ReturnsGenericError(t *testing.T) {
	svc, _, _, ss, _ := newTestServiceWithReset()
	ctx := context.Background()
	regOut, _ := svc.Register(ctx, RegisterInput{Username: "grace", Password: "correct horse battery staple"})
	uid, _ := parseUID(regOut.Uid)
	u, _ := svc.repo.GetByID(ctx, uid)
	u.Phone = "+15550003333"
	_ = svc.RequestPasswordReset(ctx, "+15550003333", "sms")
	code := ss.Sent()[0].Code

	if err := svc.ConfirmPasswordReset(ctx, code, "+15550009999", "brand-new-password-1"); err == nil {
		t.Fatal("expected an error when phone does not match the token's owning account")
	}
}
```

- [ ] **Step 2: 运行测试确认失败（编译失败，签名不匹配）**

Run（渲染出的实例里）: `go build ./... 2>&1 | head -30`
Expected: 编译失败，报 `ConfirmPasswordReset` 参数数量不匹配（`too many arguments in call to svc.ConfirmPasswordReset`），因为生产代码签名尚未修改。

- [ ] **Step 3: 修改生产代码——新签名 + SMS 分支校验**

把 `internal_application_user_user_service_go.yaml` 里的（L556-574）：
```go
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, newPassword string) error {
	tok, err := s.resetRepo.GetValid(ctx, hashCredential(credential))
	if err != nil {
		if !errors.Is(err, passwordreset.ErrNotFound) {
			log.Printf("user: ConfirmPasswordReset lookup failed: %v", err)
		}
		return errors.New("user: reset credential is invalid or expired")
	}
	if err := s.setPassword(ctx, tok.UserID.String(), nil, newPassword, "user.password_reset_confirmed", "", "", ""); err != nil {
		return err
	}
	if err := s.resetRepo.MarkUsed(ctx, tok.ID); err != nil {
		// Best-effort: the password was already changed above, so this
		// failure is non-fatal, but log it so a stuck "still valid" token
		// row doesn't go unnoticed.
		log.Printf("user: ConfirmPasswordReset MarkUsed failed: %v", err)
	}
	return nil
}
```
改为（在 doc comment 里补一句说明 SMS 分支的意图）：
```go
// ConfirmPasswordReset validates credential against the stored token,
// then sets uid's password to newPassword via the shared setPassword
// helper (same path as admin-forced reset). All failure modes — no
// matching token, expired, already used, or (SMS channel only) a
// missing/mismatched phone — return the same generic error so a caller
// cannot distinguish them (see design doc's anti-enumeration section).
// phone is required and checked only when the matched token's Channel
// is "sms"; it is ignored entirely for "email" tokens (Issue #75).
func (s *Service) ConfirmPasswordReset(ctx context.Context, credential, phone, newPassword string) error {
	tok, err := s.resetRepo.GetValid(ctx, hashCredential(credential))
	if err != nil {
		if !errors.Is(err, passwordreset.ErrNotFound) {
			log.Printf("user: ConfirmPasswordReset lookup failed: %v", err)
		}
		return errors.New("user: reset credential is invalid or expired")
	}
	if tok.Channel == "sms" {
		if phone == "" {
			return errors.New("user: reset credential is invalid or expired")
		}
		u, err := s.repo.GetByID(ctx, tok.UserID)
		if err != nil || u.Phone != phone {
			return errors.New("user: reset credential is invalid or expired")
		}
	}
	if err := s.setPassword(ctx, tok.UserID.String(), nil, newPassword, "user.password_reset_confirmed", "", "", ""); err != nil {
		return err
	}
	if err := s.resetRepo.MarkUsed(ctx, tok.ID); err != nil {
		// Best-effort: the password was already changed above, so this
		// failure is non-fatal, but log it so a stuck "still valid" token
		// row doesn't go unnoticed.
		log.Printf("user: ConfirmPasswordReset MarkUsed failed: %v", err)
	}
	return nil
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `go build ./... && go test ./internal/application/user/... -run "TestConfirmPasswordReset" -v`
Expected: 全部 `TestConfirmPasswordReset_*`（既有 3 个 + 新增 3 个）PASS。

- [ ] **Step 5: 全量回归该包**

Run: `go test ./internal/application/user/... -v`
Expected: 该包内所有测试（含 `RequestPasswordReset` 系列）PASS，无回归。

- [ ] **Step 6: Commit**

```bash
git add user-kitex/kitex-template/internal_application_user_user_service_go.yaml user-kitex/kitex-template/internal_application_user_user_service_test_go.yaml
git commit -m "fix(user-kitex): require phone binding for SMS-channel password reset confirm"
```

---

## Task 3: Kitex handler 透传 `phone`

**Files:**
- Modify: `user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml`

**Interfaces:**
- Consumes：Task 1 的 `userv1.ConfirmPasswordResetReq.Phone`；Task 2 的 `(s *Service) ConfirmPasswordReset(ctx, credential, phone, newPassword string) error`

- [ ] **Step 1: 修改 handler 包装函数**

把（L191-194）：
```go
func (h *UserServiceHandlerImpl) ConfirmPasswordReset(ctx context.Context, req *userv1.ConfirmPasswordResetReq) (*userv1.ConfirmPasswordResetResp, error) {
	err := h.self.ConfirmPasswordReset(ctx, req.Credential, req.NewPassword)
	return &userv1.ConfirmPasswordResetResp{}, err
}
```
改为：
```go
func (h *UserServiceHandlerImpl) ConfirmPasswordReset(ctx context.Context, req *userv1.ConfirmPasswordResetReq) (*userv1.ConfirmPasswordResetResp, error) {
	err := h.self.ConfirmPasswordReset(ctx, req.Credential, req.Phone, req.NewPassword)
	return &userv1.ConfirmPasswordResetResp{}, err
}
```

- [ ] **Step 2: 编译验证**

Run: `go build ./...`
Expected: 编译通过（`req.Phone` 字段已由 Task 1 的 `make update` 生成）。

- [ ] **Step 3: Commit**

```bash
git add user-kitex/kitex-template/internal_handler_userservice_handler_go.yaml
git commit -m "feat(user-kitex): pass phone through to ConfirmPasswordReset handler"
```

---

## Task 4: `user-bff-hertz` DTO + handler + 测试

**Files:**
- Modify: `user-bff-hertz/hertz-template/internal_handler_auth_go.yaml`
- Test: `user-bff-hertz/hertz-template/internal_router_userbffservice_test_go.yaml`

**Interfaces:**
- Consumes：Task 1 的 `userv1.ConfirmPasswordResetReq.Phone`

- [ ] **Step 1: 写失败测试——断言 `phone` 透传到 RPC 请求**

在 `internal_router_userbffservice_test_go.yaml` 的 `TestPasswordResetConfirm_InvalidCredential_ReturnsError` 之后追加：
```go
func TestPasswordResetConfirm_PhoneFieldPassedThrough(t *testing.T) {
	var captured *userv1.ConfirmPasswordResetReq
	cli := &fakeRouterUserClient{
		confirmPasswordResetFn: func(ctx context.Context, req *userv1.ConfirmPasswordResetReq) (*userv1.ConfirmPasswordResetResp, error) {
			captured = req
			return &userv1.ConfirmPasswordResetResp{}, nil
		},
	}
	engine := newRouterTestEngine(t, cli)
	w := ut.PerformRequest(engine, "POST", "/auth/password-reset/confirm", &ut.Body{Body: strings.NewReader(`{"credential":"123456","new_password":"hunter22","phone":"+15550001111"}`), Len: -1})
	resp := w.Result()
	if resp.StatusCode() != consts.StatusOK {
		t.Fatalf("expected 200, got %d: %s", resp.StatusCode(), resp.Body())
	}
	if captured == nil || captured.Phone != "+15550001111" {
		t.Fatalf("expected phone to be passed through to the RPC request, got %+v", captured)
	}
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `go build ./... 2>&1 | head -30`
Expected: 编译失败——`confirmPasswordResetReq`（BFF DTO）尚无 `Phone` 字段，`userv1.ConfirmPasswordResetReq` 字面量赋值里没有 `Phone`，且测试引用的 `captured.Phone` 编译不通过（`userv1.ConfirmPasswordResetReq` 此时已由 Task 1 生成 `Phone` 字段，所以这一步实际卡在 BFF handler 未透传，测试断言会失败而非编译失败——若两者都已生成，Run 改为 `go test ./internal/router/... -run TestPasswordResetConfirm_PhoneFieldPassedThrough -v`，Expected: FAIL，`captured.Phone` 为空字符串）。

- [ ] **Step 3: 修改 DTO + handler**

把 `internal_handler_auth_go.yaml` 的（L116-132）：
```go
type confirmPasswordResetReq struct {
	Credential  string `json:"credential"`
	NewPassword string `json:"new_password"`
}

func (h *AuthHandler) ConfirmPasswordReset(ctx context.Context, c *app.RequestContext) {
	var req confirmPasswordResetReq
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}
	if _, err := h.userCli.ConfirmPasswordReset(ctx, &userv1.ConfirmPasswordResetReq{Credential: req.Credential, NewPassword: req.NewPassword}); err != nil {
		response.Err(c, err)
		return
	}
	response.OK(c, map[string]string{"status": "password_reset"})
}
```
改为：
```go
type confirmPasswordResetReq struct {
	Credential  string `json:"credential"`
	NewPassword string `json:"new_password"`
	Phone       string `json:"phone"`
}

func (h *AuthHandler) ConfirmPasswordReset(ctx context.Context, c *app.RequestContext) {
	var req confirmPasswordResetReq
	if err := json.Unmarshal(c.Request.Body(), &req); err != nil {
		response.ErrorCode(c, response.CodeRequestParamInvalid)
		return
	}
	if _, err := h.userCli.ConfirmPasswordReset(ctx, &userv1.ConfirmPasswordResetReq{Credential: req.Credential, NewPassword: req.NewPassword, Phone: req.Phone}); err != nil {
		response.Err(c, err)
		return
	}
	response.OK(c, map[string]string{"status": "password_reset"})
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `go build ./... && go test ./internal/router/... ./internal/handler/... -v`
Expected: 全部 PASS，含新增的 `TestPasswordResetConfirm_PhoneFieldPassedThrough` 与既有的 `TestPasswordResetConfirm_InvalidCredential_ReturnsError`/`TestPasswordResetRequest_AlwaysSucceeds_NoAuthRequired`。

- [ ] **Step 5: Commit**

```bash
git add user-bff-hertz/hertz-template/internal_handler_auth_go.yaml user-bff-hertz/hertz-template/internal_router_userbffservice_test_go.yaml
git commit -m "feat(user-bff-hertz): pass phone through to ConfirmPasswordReset request"
```

---

## Task 5: 全量回归 + 文档收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-09-20-sms-reset-code-brute-force-mitigation-design.md`（若实现阶段发现与设计有出入，在此更新；预期无出入，仅确认）

- [ ] **Step 1: 两个服务各自渲染出的实例中全量编译 + 测试**

`user-kitex`：
```bash
go build ./... && go test -race -count=1 ./...
```
`user-bff-hertz`：
```bash
go build ./... && go test -race -count=1 ./...
```
Expected: 两个实例均编译通过，全部测试 PASS，无 race 告警。

- [ ] **Step 2: 核对设计文档与最终实现一致**

对照 `docs/superpowers/specs/2026-09-20-sms-reset-code-brute-force-mitigation-design.md`"接口变更"一节描述的字段名、校验位置、错误复用方式，确认与 Task 1-4 实际改动一致；若有偏差（例如字段名不同），在设计文档里更新为最终实现（不重写决策论证部分，只更正描述性细节）。

- [ ] **Step 3: 最终提交**

```bash
git add docs/superpowers/specs/2026-09-20-sms-reset-code-brute-force-mitigation-design.md
git commit -m "docs: reconcile SMS reset design doc with final implementation" --allow-empty
```
（若 Step 2 未发现任何偏差，此 commit 允许为空提交，仅作为"已核对"的记录；也可以跳过此 commit，直接在 Phase 4 走查中说明已核对——执行时二选一，不强制空提交。）

---

## Self-Review Notes（写作后自查，供执行前参考）

1. **Spec coverage**：设计文档四条 Goals 分别对应 Task 2（SMS 校验逻辑）、Task 2 Step1（email 路径不变，既有测试改造为传空 phone 验证）、无 schema 改动（Global Constraints 已声明）、Task 1/3/4（IDL/handler/BFF 改动+测试）——全部覆盖，无遗漏。
2. **Placeholder scan**：全文无 TBD/TODO；Task 4 Step 2 的"Run"根据两种可能状态给出了两条具体命令及各自 Expected，不是含糊占位。
3. **Type consistency**：`ConfirmPasswordReset(ctx, credential, phone, newPassword string) error` 签名在 Task 2 定义后，Task 3（`h.self.ConfirmPasswordReset(ctx, req.Credential, req.Phone, req.NewPassword)`）与测试文件的所有调用点均使用相同的参数顺序 `(credential, phone, newPassword)`，未发现不一致。
4. **Scope check**：单一 Issue、单一改动主线（SMS 渠道 phone 绑定），5 个 Task 均围绕同一签名变更的传导链，无需进一步拆分为独立计划。
