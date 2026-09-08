# Design: 同步 micro-admin/idl 的 Req/Resp 命名 (Issue #56)

## 背景

#52 修复 admin-bff-hertz 的 handler 模板与其 idl 之间的命名错配，将
`admin-bff-hertz/idl/{auth,rbac,rule_center}.proto` 中的 `XxxRequest`/`XxxResponse`
统一改为 `XxxReq`/`XxxResp`。`micro-admin/idl/{auth,rbac,rule_center}.proto`
与之高度相似但未同步这次改名。

## 核实结论

对比 `micro-admin/idl/*.proto` 与 `admin-bff-hertz/idl/*.proto`，两者**并非纯粹的命名分叉**：

- `auth.proto`：admin-bff-hertz 已删除 `ValidateToken` RPC 及其 message；micro-admin 仍保留
- `rbac.proto`：`EnforceRequest.sub` 字段在 admin-bff-hertz 侧被改名为 `EnforceReq.uid`；RPC 顺序也重排
- 三个文件：`go_package` 写法不同（admin-bff-hertz 用 `{{.Module}}/kitex_gen/...` 模板占位符，micro-admin 用固定路径 `api/...`）

已核实 micro-admin 下无任何 `.go` 文件、`template.yaml` 或 handler/client 模板引用这些
message 类型名（`workspace/scripts/smoke-test.sh` 中出现的 "Request"/"Response" 仅是日志文本，
非类型引用）。

## 决定

范围**收窄为纯机械式后缀重命名**，不合并两侧的内容性分叉：

- 对 `micro-admin/idl/{auth,rbac,rule_center}.proto` 应用 `XxxRequest` → `XxxReq`、
  `XxxResponse` → `XxxResp` 的标识符重命名，覆盖 message 定义名与 rpc 签名引用
- **不**移植 admin-bff-hertz 侧的内容性差异：不删除 `ValidateToken`、不把 `sub` 改为 `uid`、
  不改动 `go_package` 写法 —— 这些超出 Issue #56 的验收范围（"命名同步"），贸然移植会引入
  不必要的行为改动

## 验证方式

因无 Go 代码或模板引用这些类型，无需编译验证；仅需 diff 改动前后确认：
- 改动只涉及标识符重命名（message 名 + rpc 签名）
- 字段数量、字段名、RPC 数量与顺序均不变（除标识符本身）

## 涉及文件

- `micro-admin/idl/auth.proto`
- `micro-admin/idl/rbac.proto`
- `micro-admin/idl/rule_center.proto`

单一改动范围（3 个 proto 文件，纯文本重命名），无破坏性变更，无需拆分子任务。
