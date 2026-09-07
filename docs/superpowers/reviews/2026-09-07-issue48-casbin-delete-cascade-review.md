# Issue #48 — Casbin Delete-Cascade Cleanup — Final Whole-Change Review

**Delivery type:** Local merge (no PR). Merge commit `6bec911afc578c0bb4901d1af5779acf9003682` on `main`, merging `feat/48-casbin-delete-cascade` (base `main` @ `118d207`).
**Reviewed diff:** `git diff 118d207...6bec911afc578c0bb4901d1af5779acf9003682 -- rbac-kitex admin-services-kitex docs/superpowers`
**Reviewer:** Phase 4 final-review agent (gf-workflow contract wf-2026-09-07-002)
**Verdict:** No blocking issues. One informational finding (pre-existing, out of scope for #48) worth tracking as a follow-up issue.

---

## 1. Scope of change

Files touched (identical edits mirrored across two template packages):

- `rbac-kitex/kitex-template/internal_application_permission_permission_service_go.yaml` (+test)
- `rbac-kitex/kitex-template/internal_application_role_role_service_go.yaml` (+test)
- `admin-services-kitex/kitex-template/internal_application_permission_permission_service_go.yaml` (+test)
- `admin-services-kitex/kitex-template/internal_application_role_role_service_go.yaml` (+test)
- `docs/superpowers/plans/2026-09-07-issue48-casbin-delete-cascade.md` (new)
- `docs/superpowers/specs/2026-09-07-issue48-casbin-delete-cascade-design.md` (new)

All Go source lives inside YAML `body: |` block scalars; `{{ "{" }}` / `{{ "}" }}` are expected ncgo template brace escapes, not defects — confirmed consistent with pre-existing convention throughout both files.

---

## 2. Correctness review

### 2.1 `permission.Service.Delete` / `cascadeDelete`

- `cascadeDelete` now takes `*permission.Permission` (already fetched) instead of an ID, eliminating the duplicate `GetByID` call the Phase 3 pass flagged as a nit. Verified: the child objects returned by `PermRepo.ListChildren` already carry `.Code`, so no extra fetch is needed for children either — the earlier review's fix is real, not just claimed.
- Traversal order verified independently: for each node, `cascadeDelete` first recurses into **all** children (deleting each child's subtree in full, DB delete + Casbin cleanup), and only after the child loop completes does it delete the current node from the DB and then clean its Casbin policy. This is genuine DFS **post-order**: every descendant is fully removed (DB + Casbin) before its ancestor is removed. Correct for FK-cascade safety and for policy-cleanup completeness — no node's cleanup can be skipped by an early return higher up the stack, since each level's own cleanup happens within its own stack frame after its children's cleanup succeeds.
- `RemoveFilteredPolicy(1, p.Code)` — field index 1 is `obj` in `p = sub, obj, act` (model.conf: `internal_infrastructure_casbin_model_conf.yaml`). `GrantPermissions` in `role_service.go` calls `AddPolicy(r.Code, p.Code, p.Method)`, i.e. `obj = p.Code`. Field index 1 = obj = permission code is consistent and correct.
- The top-level `Delete` no longer has its own `RemoveFilteredPolicy` call — cleanup for the top node now flows through the same `cascadeDelete` path as its children (single code path, no duplication, no missed case). Confirmed by reading the full post-diff method body.
- Error handling: Casbin cleanup failure is logged via `klog.CtxErrorf` and does not propagate — matches the #39-established pattern and is exercised by the pre-existing `TestDeleteCasbinCleanupErrorDoesNotFailRequest` (untouched by this diff, still passes with the new call site).

### 2.2 `role.Service.Delete`

- `GetByID` is now called before `roles.Delete`, to capture `r.Code` for the two Casbin calls issued afterward. Verified this doesn't change behavior on a not-found id in an observable way: previously `roles.Delete` would itself surface a not-found/DB error; now `GetByID`'s `fakeRoleRepo`/real repo returns `role.NotFoundError` first. Either way `Delete` still returns a non-nil error and never reaches Casbin cleanup — no regression.
- `RemoveFilteredPolicy(0, r.Code)` — field index 0 = `sub` in `p = sub, obj, act`. Consistent with `GrantPermissions`'s existing `RemoveFilteredPolicy(0, r.Code)` call (same file, pre-existing, untouched by this diff). Correct.
- `RemoveFilteredGroupingPolicy(1, r.Code)` — model.conf defines `g = _, _` (i.e. `user, role`), so field index 1 = role. Correct. This is the new "g-binding cascade cleanup" and is independently consistent with `user.Service.Delete`'s existing `DeleteRolesForUser(id)` call (field index 0 = user, in `user_service.go`, untouched by this diff) — the two deletion paths clean the same `g` relation from complementary ends (by-role vs by-user), which is the right shape for a bidirectional many-to-many binding.
- Both new Casbin calls are logged-not-failed, matching the established pattern; both are independently exercised by `TestDeleteCasbinCleanupErrorsDoNotFailRequest`, which sets `removeErr` on `errEnforcer` (now implementing both `RemoveFilteredPolicy` and the new `RemoveFilteredGroupingPolicy`) and asserts `Delete` still returns nil.

### 2.3 Byte-identical mirror check (rbac-kitex vs admin-services-kitex)

Ran `diff` on all four touched non-doc files after the merge:

```
diff rbac-kitex/.../internal_application_permission_permission_service_go.yaml admin-services-kitex/.../internal_application_permission_permission_service_go.yaml       → no output
diff rbac-kitex/.../internal_application_permission_permission_service_test_go.yaml admin-services-kitex/.../internal_application_permission_permission_service_test_go.yaml → no output
diff rbac-kitex/.../internal_application_role_role_service_go.yaml admin-services-kitex/.../internal_application_role_role_service_go.yaml           → no output
diff rbac-kitex/.../internal_application_role_role_service_test_go.yaml admin-services-kitex/.../internal_application_role_role_service_test_go.yaml → no output
```

All four pairs are still byte-identical post-merge. The mirroring discipline was maintained.

---

## 3. Residual-gap sweep (the point of this final pass)

Grepped both template packages for every Casbin mutation call site (`RemoveFiltered*`, `AddPolicy`, `AddGroupingPolicy`, `AddRoleForUser`, `DeleteRolesForUser`, `GetRolesForUser`) to check for any other delete/rename path that should touch Casbin but doesn't:

| Call site | File | Touches Casbin? |
|---|---|---|
| `permission.Service.Delete` (+ cascade) | permission_service.go | Yes (this fix) |
| `role.Service.Delete` | role_service.go | Yes (this fix) |
| `role.Service.GrantPermissions` | role_service.go | Yes (pre-existing, #39) |
| `user.Service.Delete` | user_service.go | Yes (pre-existing, `DeleteRolesForUser`) |
| `user.Service.AssignRoles` | user_service.go | Yes (pre-existing, `DeleteRolesForUser` + `AddRoleForUser`) |
| **`permission.Service.Update`** | permission_service.go | **No** |
| `role.Service.Update` | role_service.go | N/A — doesn't mutate `Code` (only `Name`/`Status`/`Remark`), so no policy identity change occurs |

**Finding (informational, pre-existing, out of scope for #48):** `permission.Service.Update` accepts an optional `in.Code` and, if set, overwrites `p.Code` (`internal_application_permission_permission_service_go.yaml`, `Update` method, `if in.Code != nil { p.Code = *in.Code }`) without any Casbin call. This method was not touched by this diff (confirmed via the diff hunks — `Update` doesn't appear in either changed range) and pre-dates #39/#48. Effect of renaming a permission's code today:
- The **old** code's `p` policies (e.g. `p, admin, old:code, DELETE`) remain in Casbin and become orphaned/stale — no live `Permission` row references that code anymore, but the grant is never cleaned up. This is a stale-policy accumulation risk in the same family as the #39/#48 bugs, though not a live over-privilege risk by itself (nothing currently maps a user to that dangling code unless it's later reused).
- The **new** code has zero grants until someone re-runs `GrantPermissions` — a functional (not security) gap, fails closed rather than open.
- Not a security escalation and not blocking for #48 (different method, different trigger, arguably a separate bug). Recommend filing a follow-up issue tracking `permission.Service.Update`'s code-rename path for the same `RemoveFilteredPolicy`/re-grant treatment, for symmetry with Delete. Role rename is not exposed (no equivalent gap), so this is permission-only.

No other gaps found. Every delete-shaped mutation of a `Permission`, `Role`, or user-role binding that exists in these two service files now has matching Casbin cleanup on both the `p`-policy and `g`-binding sides, cross-checked from both ends (role-initiated and user-initiated `g` cleanup both exist and don't overlap/duplicate).

---

## 4. Security-reviewer lens: residual over-privilege after delete

- After `permission.Service.Delete` (including cascaded children): all `p` policies referencing the deleted code(s) are removed synchronously in the same call, best-effort logged on failure. No user retains access via a *deleted* permission code through this path. Residual risk is identical in shape to #39's already-accepted residual risk: if `RemoveFilteredPolicy` itself fails (enforcer/store error), the stale policy remains and only a log line records it — this is the deliberate, previously-approved trade-off (fail open on cleanup, not on the request), not a new decision made in this change.
- After `role.Service.Delete`: both the role's own `p` grants and every user's `g` binding to that role are removed synchronously. This closes the exact "role revival" scenario named in the design doc — if the same role Code is recreated later, previously-bound users no longer automatically inherit it, since the `g` rows were deleted, not just the `p` rows. Verified this is actually exercised by `TestDeleteRemovesCasbinPolicyAndRoleBindings`, which checks both `Enforce(...)` post-delete and `GetRolesForUser(alice)` returns `[]` — i.e. the test asserts the binding is gone, not just that enforcement currently fails.
- No new attack surface introduced: no new external inputs, no new interface exposed beyond the single `RemoveFilteredGroupingPolicy` method added to the already-narrow `role.Service`'s internal `Enforcer` port, which is satisfied by the real `*casbin.Enforcer` alias with no adapter changes.

---

## 5. Test quality

- New/changed tests: `TestDeleteCascadeRemovesCasbinPolicyForChildren` (permission), `TestDeleteRemovesCasbinPolicyAndRoleBindings` and `TestDeleteCasbinCleanupErrorsDoNotFailRequest` (role), plus the `errEnforcer.RemoveFilteredGroupingPolicy` stub extension.
- Coverage is good for the two fixed gaps specifically:
  - Permission: exercises a real parent/child creation, grants a policy on the child, deletes the parent, and asserts the child's policy is gone via `Enforce`, not just via a mock-call assertion — this is an integration-style assertion against the real embedded enforcer/store, stronger than mocking.
  - Role: exercises both `p` and `g` cleanup together in one test using the real enforcer, with explicit pre-conditions asserted before the delete (`Enforce(...) = true`, `GetRolesForUser(alice) = [admin]`) so the test would fail loudly if the fixture itself were wrong, not just if the fix regressed.
  - Failure-path test reuses the existing `errEnforcer` pattern consistently with #39's established test style.
- Minor coverage gap (non-blocking): no test exercises a **3-level-deep** permission tree (grandchild) for the cascade fix — the new test only covers one parent + one direct child. The recursive logic is simple enough (and independently verified above by reading it) that this is a nice-to-have, not a correctness risk; the existing `TestDeleteCascadesChildren` (pre-existing, DB-only cascade) already covers multi-level DB deletion, just not multi-level Casbin cleanup specifically.
- No test covers the case of a role with **multiple** bound users to confirm `RemoveFilteredGroupingPolicy(1, r.Code)` clears all of them, not just one — again a nice-to-have; `RemoveFilteredGroupingPolicy` semantics (any-row-matching-field-1 removal) make multi-user correctness a library-level guarantee rather than something this code could get wrong, so this is very low priority.

---

## 6. Documentation

- `docs/superpowers/plans/2026-09-07-issue48-casbin-delete-cascade.md` and `docs/superpowers/specs/2026-09-07-issue48-casbin-delete-cascade-design.md` accurately describe the shipped change; spot-checked several code blocks in the plan against the actual diff and they match verbatim (including the intentionally-approved g-binding cascade decision, recorded with rationale in the spec's Design Decision section).

---

## 7. Summary

No blocking issues. Field indices, cascade ordering, error-handling pattern, and cross-template mirroring are all correct and verified independently rather than taken on trust from the Phase 3 pass. One informational, pre-existing (not introduced by #48), out-of-scope finding: `permission.Service.Update`'s code-rename path doesn't clean/migrate Casbin `p` policies for the old code — recommend a follow-up issue, not a blocker for closing #48.
