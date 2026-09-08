# micro-admin idl Req/Resp Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename all `XxxRequest`/`XxxResponse` message identifiers in `micro-admin/idl/{auth,rbac,rule_center}.proto` to `XxxReq`/`XxxResp`, matching the naming convention already applied to `admin-bff-hertz/idl` in #52.

**Architecture:** Pure mechanical text substitution (`Request`→`Req`, `Response`→`Resp`) across three `.proto` files. No Go code, template, or handler in this repo references these message type names, so no other files need changes and no build/codegen verification is required.

**Tech Stack:** Protocol Buffers (`.proto` files only, no toolchain invocation needed).

**Spec:** `docs/superpowers/specs/2026-09-08-micro-admin-idl-req-resp-rename-design.md`

## Global Constraints

- Scope is strictly the `Request`/`Response` → `Req`/`Resp` suffix rename. Do NOT port over the content-level divergences already found between micro-admin and admin-bff-hertz idl (do not remove `ValidateToken` RPC/messages, do not rename `EnforceRequest.sub` to `uid`, do not change `go_package` format).
- Verified: no substring collisions exist — no identifier has `Request`/`Response` followed by another letter (e.g. no `RequestId`), so a global `Request`→`Req` / `Response`→`Resp` replacement is safe per file.
- Verified: no `.go` file, `template.yaml`, or handler/client template anywhere under `micro-admin/` references any of these message type names — this is a pure idl-file change with no downstream code to update or compile-check.

---

### Task 1: Rename Req/Resp suffixes in micro-admin idl files

**Files:**
- Modify: `micro-admin/idl/auth.proto`
- Modify: `micro-admin/idl/rbac.proto`
- Modify: `micro-admin/idl/rule_center.proto`

**Interfaces:**
- Consumes: nothing (no upstream task)
- Produces: nothing consumed by a later task — this is the only task in the plan

- [ ] **Step 1: Capture pre-change identifier list (for the post-change diff check in Step 3)**

Run:
```bash
for f in micro-admin/idl/auth.proto micro-admin/idl/rbac.proto micro-admin/idl/rule_center.proto; do
  grep -oE '[A-Za-z]+Request|[A-Za-z]+Response' "$f" | sort -u
done > /tmp/before-idl-idents.txt
wc -l /tmp/before-idl-idents.txt
```
Expected: prints a count of 56 (this repo currently has 56 unique `XxxRequest`/`XxxResponse` identifiers combined across the three files).

- [ ] **Step 2: Apply the rename**

Run:
```bash
sed -i '' 's/Request/Req/g; s/Response/Resp/g' micro-admin/idl/auth.proto micro-admin/idl/rbac.proto micro-admin/idl/rule_center.proto
```
(macOS `sed -i ''` syntax — this repo is developed on macOS/Darwin.)

- [ ] **Step 3: Verify the rename is complete and scope-limited**

Run:
```bash
# No old suffixes should remain
grep -n 'Request\|Response' micro-admin/idl/auth.proto micro-admin/idl/rbac.proto micro-admin/idl/rule_center.proto
```
Expected: no output (empty — all occurrences renamed).

Run:
```bash
# Diff should show ONLY identifier renames, not structural changes
git diff --stat micro-admin/idl/auth.proto micro-admin/idl/rbac.proto micro-admin/idl/rule_center.proto
git diff micro-admin/idl/auth.proto micro-admin/idl/rbac.proto micro-admin/idl/rule_center.proto | grep -E '^\+|^-' | grep -v 'Req\b\|Resp\b\|+++\|---' 
```
Expected: the second command prints no lines whose changed content is unrelated to a `Req`/`Resp` identifier (i.e., every `+`/`-` line in the diff touches an identifier ending in `Req` or `Resp` — field names, rpc counts, `go_package`, and message bodies must be byte-identical otherwise).

- [ ] **Step 4: Confirm no other files reference the old names (regression guard)**

Run:
```bash
grep -rn "ValidateTokenRequest\|ValidateTokenResponse\|LoginRequest\|LoginResponse\|EnforceRequest\|EnforceResponse\|ListRulesRequest\|ListRulesResponse" micro-admin/ --include="*.go" --include="*.yaml" 2>/dev/null
```
Expected: no output (already verified during brainstorming that nothing references these types; this step re-confirms after the edit that nothing was missed).

- [ ] **Step 5: Commit**

```bash
git add micro-admin/idl/auth.proto micro-admin/idl/rbac.proto micro-admin/idl/rule_center.proto
git commit -m "refactor(micro-admin): rename idl Request/Response suffixes to Req/Resp

Sync micro-admin/idl/{auth,rbac,rule_center}.proto naming with the
Req/Resp convention already applied to admin-bff-hertz/idl in #52.
Pure mechanical rename; no Go code or templates reference these
message types.

Closes #56"
```
