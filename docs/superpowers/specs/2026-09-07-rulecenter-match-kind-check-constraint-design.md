# rule-center: match_kind CHECK 约束与业务取值域对齐

## 背景

`rule-center` 模板（同时存在于 `admin-services-kitex/kitex-template/` 与独立的
`rule-center/kitex-template/` 两个目录，两者结构一致）中，数据库层对
`match_kind` 字段的 CHECK 约束仍是初始化时的 `('exact', 'pattern')`，而
proto（`admin.proto` 259/321 行）与 usecase 层
（`internal_usecase_rulecenter_usecase_go.yaml` / `ratelimit_usecase.yaml`）
早已实现并支持 `exact` / `prefix` / `glob` / `regex` 四种匹配方式。写入
`prefix`/`glob`/`regex` 规则时会直接触发 CHECK 约束违反，运行时插入失败。

对应 Issue: #41

## 范围（bounded）

修改点集中在两个模板目录下、结构完全相同的 4 处 CHECK 约束定义，并为
`rulecenter` repository 新增一条 gated 集成测试，验证四种取值均可写入。
不改动 proto/usecase 匹配逻辑本身（已正确），不涉及
`internal_base_middleware_ratelimit_go.yaml` 中 Kitex server 级硬限流的 TODO
（issue 中明确该项是关联但独立的问题，届时在提交说明中注明避免误解，不在本次
修复范围内）。

## 修改内容

### 1. 修正 CHECK 约束

以下 4 处均将 `CHECK (match_kind IN ('exact', 'pattern'))` 改为
`CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex'))`：

- `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml:103`
- `admin-services-kitex/kitex-template/migration_init.yaml:105`
- `rule-center/kitex-template/ratelimit_schema.yaml:14`
- `rule-center/kitex-template/migration_init.yaml:13`

### 2. 补充集成测试

复用仓库既有的 gated postgres 集成测试模式（参考
`admin-services-kitex/kitex-template/internal_repository_user_repo_test_go.yaml`：
用 `pg_isready` + `POSTGRES_DSN` 环境变量做 gate，条件不满足时 `t.Skip`，避免
在无 DB 环境的 CI/本地开发中失败）。

在两个模板目录下各新增 `internal_repository_rulecenter_repo_test_go.yaml`
（渲染路径 `internal/repository/rulecenter/repo_test.go`），对
`exact`/`prefix`/`glob`/`regex` 四种 `match_kind` 各插入一条规则，断言写入
成功、不触发 CHECK 约束错误。

## 测试策略

TDD 顺序：先按上述模式添加集成测试（此时若约束未修，且本地具备 pg 环境，
`prefix`/`glob`/`regex` 三种取值的插入会因 CHECK 违反而失败；无 pg 环境则
`t.Skip`），再修正 4 处 CHECK 约束使测试转绿。

## 不做的事

- 不修改 proto 定义（字符串字段本身无需变更）
- 不修改 usecase/resolver 的匹配逻辑（已正确实现四种匹配）
- 不处理 Kitex server 级硬限流 TODO（`internal_base_middleware_ratelimit_go.yaml`，
  已确认为独立问题，business-rule 限流逻辑不受影响）
