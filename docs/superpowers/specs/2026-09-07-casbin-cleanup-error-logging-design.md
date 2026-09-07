# Casbin 策略清理错误静默忽略修复 — 设计（Bounded）

- Issue: #39
- 分类: Bounded（对已有代码流程的定向修复，非架构性改动）
- 日期: 2026-09-07

## 问题

`rbac-kitex` 与 `admin-services-kitex` 两个模板包中，多处 Casbin 策略清理操作的返回错误被静默忽略（`_, _ = s.enforcer.XXX(...)`），导致 DB 记录已变更但 Casbin policy 清理失败时无任何可观测信号，可能造成越权残留或权限叠加。

涉及位置（每个模板包各 3 处，共 6 处 / 12 个模板文件含对应测试）：

| 文件 | 方法 | 行为约 |
|---|---|---|
| `internal_application_role_role_service_go.yaml` | `GrantPermissions` | `RemoveFilteredPolicy(0, r.Code)` ~174 |
| `internal_application_permission_permission_service_go.yaml` | 权限删除场景 | `RemoveFilteredPolicy(1, p.Code)` ~165 |
| `internal_application_user_user_service_go.yaml` | 用户删除场景 | `DeleteRolesForUser(id)` ~134 |
| `internal_application_user_user_service_go.yaml` | `AssignRoles`（先删旧角色） | `DeleteRolesForUser(uid)` ~201 |

以上四类各在 `rbac-kitex/` 与 `admin-services-kitex/` 下各出现一次。

## 修复方案

**仅记录错误日志**（Issue 建议的方案①），不引入事务/补偿机制：

- 原因：Casbin policy store 与业务 DB 是两套独立存储，模板生成的代码不具备跨存储事务能力；补偿对账是更大的架构改动，超出本次 bounded 修复范围。
- 项目已确立 `github.com/cloudwego/kitex/pkg/klog` 作为日志组件（参考 `admin-services-kitex/kitex-template/internal_base_middleware_ratelimit_go.yaml` 中 `klog.CtxWarnf` 用法），本次统一使用 `klog.CtxErrorf(ctx, "...: %v", err)`。
- 不改变方法的返回值语义：Casbin 清理失败不会让业务方法本身返回 error（与当前行为一致），仅补充日志可观测性，把"完全吞掉"改为"记录后继续"。

### 修改示例（role_service）

```go
// Before
_, _ = s.enforcer.RemoveFilteredPolicy(0, r.Code)

// After
if _, err := s.enforcer.RemoveFilteredPolicy(0, r.Code); err != nil {
    klog.CtxErrorf(ctx, "role.grant_permissions: remove existing casbin policies for role %s failed: %v", r.Code, err)
}
```

各文件需新增 `"github.com/cloudwego/kitex/pkg/klog"` import。

## 测试

`Enforcer` 是各 service 包本地定义的接口（非直接依赖 casbin 具体实现），可在对应 `_test_go.yaml` 中新增一个返回 error 的 fake `Enforcer` 实现，为上述 4 处各补一条错误路径测试：

- 断言：Casbin 清理失败时，业务方法本身仍返回预期结果（不因此报错），验证"记录日志但不中断主流程"的行为不回归。

## 影响范围

- 12 个模板文件：6 个实现 `*_go.yaml` + 6 个测试 `*_test_go.yaml`，`rbac-kitex/kitex-template/` 与 `admin-services-kitex/kitex-template/` 各占一半（若两包内容一致视为同源修改）。
- 无破坏性变更：不改变任何公开接口/返回值语义。

## 用户批准

已在对话中以简短设计形式呈现并获得批准（2026-09-07）。
