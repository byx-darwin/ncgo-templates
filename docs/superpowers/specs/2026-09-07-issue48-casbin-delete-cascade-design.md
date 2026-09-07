# Issue #48: permission 级联删除与 role 删除缺失 Casbin 策略清理

**Status:** Approved (bounded task, chat-approved design)
**Issue:** https://github.com/byx-darwin/ncgo-templates/issues/48
**Related:** #39 (Casbin 策略清理错误被静默忽略)

## Context

#39 修复过程中的 Phase 4 全分支复审发现两处与 #39 同源但不在其修复范围内的缺失：这两处根本没有调用 Casbin 清理，而非"调用了但错误被吞掉"。

## Design Decision (Open Question Resolved)

**`role.Service.Delete` 是否级联清理该角色的 `g`（用户-角色绑定）策略：是。**

删除角色时同时清理该角色的 `p` 策略（权限授予）与 `g` 绑定（用户持有该角色的记录）。理由：若仅清理 `p` 策略而保留 `g` 绑定，日后重建同 Code 的角色时，历史持有该角色的用户会自动获得新角色的权限——这正是 Issue 中点名的"复活"风险。级联清理 `g` 绑定与常见 RBAC 系统的级联删除语义一致，安全性优先于"保留历史绑定记录"的边缘场景。

## Fix Approach

涉及文件（`rbac-kitex` 与 `admin-services-kitex` 两处镜像文件，内容完全一致，需同步改）：
- `kitex-template/internal_application_permission_permission_service_go.yaml`（+ 对应 `_test_go.yaml`）
- `kitex-template/internal_application_role_role_service_go.yaml`（+ 对应 `_test_go.yaml`）

### 1. `permission.Service.Delete` — 级联清理子权限 Casbin 策略

- `cascadeDelete` 目前只做 DB 递归删除，不碰 Casbin。改为在删除每个节点（含子节点，不仅顶层）时同步调用 `s.enforcer.RemoveFilteredPolicy(1, code)`。
- 顶层 `Delete` 方法中原有的 `RemoveFilteredPolicy(1, p.Code)` 调用并入 `cascadeDelete` 统一路径，避免重复/遗漏。
- 错误处理沿用 #39 established 模式：`RemoveFilteredPolicy` 失败只 `klog.CtxErrorf` 记录，不中断删除流程。
- 更新方法注释使其与实际行为一致（说明清理范围覆盖该权限及其所有子孙节点）。

### 2. `role.Service.Delete` — 补充 Casbin 清理（p 策略 + g 绑定级联）

```go
func (s *Service) Delete(ctx context.Context, id string) error {
    rid, err := strconv.ParseInt(id, 10, 64)
    if err != nil { ... }
    r, err := s.roles.GetByID(ctx, rid)   // 需要先取 Code，再删 DB
    if err != nil { return err }
    if err := s.roles.Delete(ctx, rid); err != nil { return err }
    if _, err := s.enforcer.RemoveFilteredPolicy(0, r.Code); err != nil {
        klog.CtxErrorf(ctx, "role.delete: remove casbin policies for role %s failed: %v", r.Code, err)
    }
    if _, err := s.enforcer.RemoveFilteredGroupingPolicy(1, r.Code); err != nil {
        klog.CtxErrorf(ctx, "role.delete: remove casbin role bindings for role %s failed: %v", r.Code, err)
    }
    _ = s.audit.Write(ctx, "", "role.delete", id, "{}")
    return nil
}
```

- `Enforcer` interface（role service 内的窄端口）新增 `RemoveFilteredGroupingPolicy(fieldIndex int, fieldValues ...string) (bool, error)`；真实 casbin `*Enforcer`（`internal/infrastructure/casbin/enforcer.go` 中 type alias）原生支持，无需改底层适配器。
- `RemoveFilteredPolicy(0, r.Code)` 清理 `p` 策略（field 0 = sub = role code，与 `GrantPermissions` 中已有用法一致）。
- `RemoveFilteredGroupingPolicy(1, r.Code)` 清理 `g` 绑定（field 1 = role，model.conf 中 `g = _, _` 为 `user, role` 两元组）。
- 错误处理同样只记日志不中断（对齐 #39 模式）。

### 3. 测试

- `permission_service_test.go`：多层子权限删除时，验证每一层的 Casbin policy 都被清理（mock enforcer 记录调用参数）。
- `role_service_test.go`：`TestService_Delete` 验证 `RemoveFilteredPolicy(0, code)` 与 `RemoveFilteredGroupingPolicy(1, code)` 均被调用；补一个"两个清理调用均失败但 Delete 仍返回 nil 且记录日志"的用例（沿用现有 `errEnforcer` 模式）。

## Complexity / Batching

- files_changed ≈ 4（按逻辑改动计，2 service + 2 test，跨两仓库同步）→ score 4
- crosses_module_boundary: 否 / changes_public_api: 否（新增接口方法不改现有签名）/ requires_migration: 否
- **score ≈ 4 → simple → 主 agent 直接批量实现 + 单次 review**
