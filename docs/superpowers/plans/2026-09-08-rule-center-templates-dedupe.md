# rule-center 模板去重 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 清理 `rule-center/kitex-template` 目录下 16 组重复声明同一输出 `path:` 的模板文件，并把该目录纳入 CI 重复路径检查（含补齐此前遗漏的 `on.pull_request.paths` 与 `build-check` matrix）。

**Architecture:** rule-center 与 rbac-kitex（#57）、admin-services-kitex（#58）不同——它自己就是 RuleService/规则引擎的实现方，而不是它的调用方。它的核心领域类型（`RuleRepo`、`RuleServiceImpl`、`gen.RateLimitRule` 等 sqlc 生成类型）是**固定命名、不随服务名参数化**的。经逐组内容核实：这个目录里"exported"（导出版）文件普遍是半吊子模板化——把变量名用 `{{ToLower .ServiceName}}` 声明，却在后续代码里硬编码引用字面量 `rule`（只有当 ServiceName 恰好渲染成 "Rule" 时才凑巧不出错，本质是脆弱的模板 bug），而"custom/preset"版本则一致地、有意地把整个领域完全硬编码为 `Rule*` 命名——这是正确设计，不是遗留代码。**因此本次的默认规则与前两个子任务相反：保留 custom/preset 版本，删除 exported 版本**，16 组无一例外。

**Tech Stack:** YAML 模板文件（ncgo 模板 DSL）、Go 1.22、Kitex、bash

**Spec:** `docs/superpowers/specs/2026-09-08-kitex-templates-duplicate-cleanup-design.md`

## Global Constraints

- **本目录判定规则与 #57/#58 相反**：保留 custom/preset 版本（文件名短、无 `internal_` 前缀），删除 exported 版本（`internal_*.yaml` 或 `main_go.yaml`）。原因：rule-center 是 RuleService 自身实现，其 `RuleRepo`/`RuleServiceImpl`/`gen.RateLimitRule` 等类型是固定命名的领域概念，不应该被参数化成 `{{.ServiceName}}Repo` 之类——导出版的半参数化是历史遗留 bug，不是需要保留的"新功能"
- 每组处理完立即用 `scripts/check-duplicate-template-paths.sh rule-center/kitex-template` 复核
- 最终必须能通过 `ncgo new scratch --module github.com/acme/scratch --kind kitex --db none --dir /tmp/scratch-rule-center --template-dir rule-center && cd /tmp/scratch-rule-center && go build ./... && go vet ./...`
- 目录：`rule-center/kitex-template/`；工作目录：仓库根目录
- CI 收口除了重复路径检查，还需补齐 `.github/workflows/template-build-check.yml` 里此前遗漏的 `on.pull_request.paths: rule-center/**` 和 `build-check` job 的 matrix 条目（`name: rule-center, kind: kitex, db: none`）——这是 #58 最终审查时发现的遗留缺口，一并修复

---

### Task 1: 批量删除 4 组纯格式冗余（data.go、interceptor.go、rpcerror.go、main.go）

**Files:**
- Delete: `rule-center/kitex-template/internal_base_data_data_go.yaml`
- Delete: `rule-center/kitex-template/internal_pkg_interceptor_interceptor_go.yaml`
- Delete: `rule-center/kitex-template/internal_pkg_rpcerror_rpcerror_go.yaml`
- Delete: `rule-center/kitex-template/main_go.yaml`
- Keep unchanged: `data.yaml`、`interceptor.yaml`、`rpcerror.yaml`、`main.yaml`

**Interfaces:**
- Consumes: 无
- Produces: 无新接口（纯删除，这 4 组内容与服务命名无关，是通用工具代码，只有转义/缩进/注释头差异）

- [ ] **Step 1: 逐组复核语义一致（RED 前置检查）**

对每一对运行归一化 diff（剥离缩进、注释头、`body: |` vs `body: |-`、`{` 与 `{{ "{" }}` 转义差异后比较），确认无字段/逻辑/签名级差异：
```
data.yaml                              vs internal_base_data_data_go.yaml
interceptor.yaml                       vs internal_pkg_interceptor_interceptor_go.yaml
rpcerror.yaml                          vs internal_pkg_rpcerror_rpcerror_go.yaml
main.yaml                              vs main_go.yaml
```
若某组发现除转义/缩进外的差异，STOP 并报告，不要删除该组。

- [ ] **Step 2: 删除 4 个导出版文件**

Run:
```bash
git rm \
  rule-center/kitex-template/internal_base_data_data_go.yaml \
  rule-center/kitex-template/internal_pkg_interceptor_interceptor_go.yaml \
  rule-center/kitex-template/internal_pkg_rpcerror_rpcerror_go.yaml \
  rule-center/kitex-template/main_go.yaml
```

- [ ] **Step 3: 验证这 4 组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rule-center/kitex-template 2>&1 | grep -E "data.go|interceptor.go|rpcerror.go|^  path: main.go"`
Expected: 无输出

- [ ] **Step 4: Commit**

```bash
git add -A rule-center/kitex-template/internal_base_data_data_go.yaml \
  rule-center/kitex-template/internal_pkg_interceptor_interceptor_go.yaml \
  rule-center/kitex-template/internal_pkg_rpcerror_rpcerror_go.yaml \
  rule-center/kitex-template/main_go.yaml
git commit -m "chore(rule-center): drop 4 redundant exported template duplicates"
```

---

### Task 2: 修复 repo.go/usecase.go 的 update_behavior 元数据，删除其导出版重复

**Files:**
- Modify: `rule-center/kitex-template/ratelimit_repository.yaml`
- Modify: `rule-center/kitex-template/ratelimit_usecase.yaml`
- Delete: `rule-center/kitex-template/internal_repository_rulecenter_repo_go.yaml`
- Delete: `rule-center/kitex-template/internal_usecase_rulecenter_usecase_go.yaml`

**Interfaces:**
- Consumes: 无
- Produces: 无新接口。这两组的 `body:` 正文本身内容一致选择保留 preset 版（导出版把 `RuleRepo`/`UseCase` 错误模板化成 `{{.ServiceName}}Repo` 等，与 Task 3 里保留的 handler.go/server.go 引用的固定 `RuleRepo`/`usecase.UseCase` 类型不匹配，preset 版才是正确、一致的）。但 preset 版当前的 `update_behavior` 元数据不如导出版安全——preset 文件头部注释明确写着"Edit business logic here"（邀请用户手改），却声明 `type: cover`（重新生成时会覆盖用户改动）；导出版声明的是 `type: skip` + `loop_service: true`（不覆盖已存在文件），这才是正确行为，需要把这个元数据搬到保留的 preset 文件里。

- [ ] **Step 1: 确认当前重复与元数据差异（RED 前置检查）**

Run: `bash scripts/check-duplicate-template-paths.sh rule-center/kitex-template 2>&1 | grep -A2 "rulecenter/repo.go\|rulecenter/usecase.go"`

Run:
```bash
head -6 rule-center/kitex-template/ratelimit_repository.yaml
head -6 rule-center/kitex-template/internal_repository_rulecenter_repo_go.yaml
head -6 rule-center/kitex-template/ratelimit_usecase.yaml
head -6 rule-center/kitex-template/internal_usecase_rulecenter_usecase_go.yaml
```
Expected: `ratelimit_repository.yaml`/`ratelimit_usecase.yaml` 当前都是 `update_behavior:\n  type: cover`；对应的 `internal_*` 版都是 `update_behavior:\n    type: skip\nloop_service: true`。

- [ ] **Step 2: 编辑 `ratelimit_repository.yaml`**

把（文件开头第 1-5 行）：
```yaml
# Kitex rule-center preset — repository for RuleService
path: internal/repository/rulecenter/repo.go
update_behavior:
  type: cover
body: |-
```
替换为：
```yaml
# Kitex rule-center preset — repository for RuleService
path: internal/repository/rulecenter/repo.go
update_behavior:
  type: skip
loop_service: true
body: |-
```
（只改 `update_behavior.type` 从 `cover` 改成 `skip`，并新增 `loop_service: true`；`body:` 正文及以后内容原样不动）

- [ ] **Step 3: 编辑 `ratelimit_usecase.yaml`**

同样的元数据替换：把（文件开头第 1-5 行）：
```yaml
# Kitex rule-center preset — usecase for RuleService
path: internal/usecase/rulecenter/usecase.go
update_behavior:
  type: cover
body: |-
```
替换为：
```yaml
# Kitex rule-center preset — usecase for RuleService
path: internal/usecase/rulecenter/usecase.go
update_behavior:
  type: skip
loop_service: true
body: |-
```

- [ ] **Step 4: 删除两个导出版文件**

Run:
```bash
git rm \
  rule-center/kitex-template/internal_repository_rulecenter_repo_go.yaml \
  rule-center/kitex-template/internal_usecase_rulecenter_usecase_go.yaml
```

- [ ] **Step 5: 验证这两组重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rule-center/kitex-template 2>&1 | grep "rulecenter/repo.go\|rulecenter/usecase.go"`
Expected: 无输出

- [ ] **Step 6: Commit**

```bash
git add rule-center/kitex-template/ratelimit_repository.yaml rule-center/kitex-template/ratelimit_usecase.yaml
git add -A rule-center/kitex-template/internal_repository_rulecenter_repo_go.yaml rule-center/kitex-template/internal_usecase_rulecenter_usecase_go.yaml
git commit -m "fix(rule-center): adopt skip+loop_service update_behavior for repo/usecase presets, drop duplicate exports"
```

---

### Task 3: 批量删除 10 组"固定命名域" exported 版（含 server.go 特殊判定）

**Files（DELETE，导出版，命名参数化不当，与保留文件的固定类型不匹配）：**
- `rule-center/kitex-template/internal_base_conf_conf_go.yaml`
- `rule-center/kitex-template/internal_base_middleware_ratelimit_test_go.yaml`
- `rule-center/kitex-template/internal_base_middleware_ratelimit_go.yaml`
- `rule-center/kitex-template/internal_base_server_server_go.yaml`
- `rule-center/kitex-template/internal_handler_rulecenter_handler_go.yaml`
- `rule-center/kitex-template/ratelimit_shared_rule_center_client.yaml`（**注意文件名易混淆**：这个是 exported 版且要删除，见下方"命名陷阱"说明）
- `rule-center/kitex-template/internal_pkg_ratelimit_resolver_test_go.yaml`
- `rule-center/kitex-template/internal_pkg_ratelimit_resolver_go.yaml`
- `rule-center/kitex-template/internal_pkg_ratelimit_store_test_go.yaml`
- `rule-center/kitex-template/internal_pkg_ratelimit_store_go.yaml`

**Files（KEEP，保持不变）：**
- `conf.yaml`、`ratelimit_middleware_test.yaml`、`ratelimit_middleware.yaml`、`ratelimit_server.yaml`、`ratelimit_handler.yaml`、`internal_pkg_middleware_rule_center_client_go.yaml`（**命名陷阱**：这个要保留，见下方说明）、`ratelimit_shared_resolver_test.yaml`、`ratelimit_shared_resolver.yaml`、`ratelimit_shared_store_test.yaml`、`ratelimit_shared_store.yaml`

**⚠️ 命名陷阱**：`internal/pkg/middleware/rule_center_client.go` 这一组的保留/删除文件名与其它组的"exported=internal_前缀"惯例相反——保留的是 `internal_pkg_middleware_rule_center_client_go.yaml`（虽然文件名带 `internal_` 前缀，但经内容核实它是正确版本），删除的是 `ratelimit_shared_rule_center_client.yaml`（虽然文件名不带 `internal_` 前缀，但经内容核实它含有与其它导出版同样的"变量名模板化但引用处硬编码字面量"缺陷）。**执行时务必以下面 Step 1 的内容核实结果为准，不要套用文件名模式。**

**Interfaces:**
- Consumes: 无
- Produces: 无新接口（保留文件已经是自洽、正确、相互匹配固定命名的版本）

**背景（server.go 判定依据，已核实）**：`ratelimit_server.yaml`（保留）注释头明确写着"Wires the preset's own rulecenter/ packages (handler/usecase/repository) instead of the default service-named per-layer packages"，其代码引用 `usecase.RuleRepo`、`handler.NewRuleServiceImpl`——与 Task 2 保留的 usecase.go（固定 `type RuleRepo interface`、`func New(repo RuleRepo) *UseCase`）和本任务保留的 handler.go（固定 `func NewRuleServiceImpl`）完全匹配。被删除的 `internal_base_server_server_go.yaml` 引用 `usecase.{{.ServiceName}}Repo`、`handler.New{{.ServiceName}}ServiceImpl`——这些类型在保留的 usecase.go/handler.go 里根本不存在，选中它会导致编译失败。

- [ ] **Step 1: 逐组复核内容判定（RED 前置检查，务必真实读取内容而非只看文件名）**

对下表每一行，读取两份文件全文，确认"保留"列的版本是固定命名（如 `RuleRepo`、`RuleServiceImpl`）且与已保留的 usecase.go/handler.go 一致，"删除"列的版本存在 `{{ToLower .ServiceName}}`/`{{.ServiceName}}` 半参数化后又硬编码引用字面量（如变量声明为 `{{ToLower .ServiceName}} := ...` 但后续代码写死引用 `rule.Xxx`）的模式：

| KEEP（保留） | DELETE（删除） |
|---|---|
| `conf.yaml` | `internal_base_conf_conf_go.yaml` |
| `ratelimit_middleware_test.yaml` | `internal_base_middleware_ratelimit_test_go.yaml` |
| `ratelimit_middleware.yaml` | `internal_base_middleware_ratelimit_go.yaml` |
| `ratelimit_server.yaml` | `internal_base_server_server_go.yaml` |
| `ratelimit_handler.yaml` | `internal_handler_rulecenter_handler_go.yaml` |
| `internal_pkg_middleware_rule_center_client_go.yaml` | `ratelimit_shared_rule_center_client.yaml` |
| `ratelimit_shared_resolver_test.yaml` | `internal_pkg_ratelimit_resolver_test_go.yaml` |
| `ratelimit_shared_resolver.yaml` | `internal_pkg_ratelimit_resolver_go.yaml` |
| `ratelimit_shared_store_test.yaml` | `internal_pkg_ratelimit_store_test_go.yaml` |
| `ratelimit_shared_store.yaml` | `internal_pkg_ratelimit_store_go.yaml` |

若某一组的实际内容与上表描述的模式不符（例如"删除"列那份反而是正确、可编译的固定命名版本），STOP 并报告该组具体内容，不要按表格盲删——这是判断性任务,表格是根据已有分析写的，不是无脑规则。

- [ ] **Step 2: 删除全部 10 个导出版文件**

Run:
```bash
git rm \
  rule-center/kitex-template/internal_base_conf_conf_go.yaml \
  rule-center/kitex-template/internal_base_middleware_ratelimit_test_go.yaml \
  rule-center/kitex-template/internal_base_middleware_ratelimit_go.yaml \
  rule-center/kitex-template/internal_base_server_server_go.yaml \
  rule-center/kitex-template/internal_handler_rulecenter_handler_go.yaml \
  rule-center/kitex-template/ratelimit_shared_rule_center_client.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_resolver_test_go.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_resolver_go.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_store_test_go.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_store_go.yaml
```

- [ ] **Step 3: 验证全部重复已消失（GREEN）**

Run: `bash scripts/check-duplicate-template-paths.sh rule-center/kitex-template; echo "exit=$?"`
Expected: 无重复输出，`exit=0`（Task 1+2+3 累计清零全部 16 组）

- [ ] **Step 4: Commit**

```bash
git add -A rule-center/kitex-template/internal_base_conf_conf_go.yaml \
  rule-center/kitex-template/internal_base_middleware_ratelimit_test_go.yaml \
  rule-center/kitex-template/internal_base_middleware_ratelimit_go.yaml \
  rule-center/kitex-template/internal_base_server_server_go.yaml \
  rule-center/kitex-template/internal_handler_rulecenter_handler_go.yaml \
  rule-center/kitex-template/ratelimit_shared_rule_center_client.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_resolver_test_go.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_resolver_go.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_store_test_go.yaml \
  rule-center/kitex-template/internal_pkg_ratelimit_store_go.yaml
git commit -m "fix(rule-center): drop 10 exported template duplicates with broken half-templated Rule* naming"
```

---

### Task 4: 渲染 + 编译验证，接入 CI 重复路径检查 + 补齐 CI 触发路径/matrix

**Files:**
- Modify: `.github/workflows/template-build-check.yml`

**Interfaces:**
- Consumes: Task 1-3 清理后的 `rule-center/kitex-template`（必须先完成全部前置任务）
- Produces: 无（终态验证 + CI 收口）

- [ ] **Step 1: 本地渲染 + 编译验证**

Run:
```bash
command -v ncgo || go install github.com/byx-darwin/ncgo@latest
ncgo new scratch \
  --module github.com/acme/scratch \
  --kind kitex \
  --db none \
  --dir /tmp/scratch-rule-center \
  --template-dir rule-center
cd /tmp/scratch-rule-center
go build ./...
go vet ./...
cd -
```
Expected: `go build ./...` 与 `go vet ./...` 均 exit 0。**注意**：`--template-dir` 指向包目录 `rule-center`（不是 `rule-center/kitex-template`），与 `build-check` job 现有其它 matrix 条目用法一致。若失败，报错会指向具体缺失/不匹配的类型——回到 Task 1-3 对应组核实，不要在这一步瞎猜着改模板内容。

- [ ] **Step 2: 把 `rule-center/kitex-template` 加入 CI 重复检查列表**

编辑 `.github/workflows/template-build-check.yml`，把（当前内容）：

```yaml
      # rule-center still has unresolved duplicate path: declarations
      # (tracked as Issue #43 follow-up); add it here once cleaned up.
      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template admin-services-kitex/kitex-template
```

替换为：

```yaml
      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template admin-services-kitex/kitex-template rule-center/kitex-template
```

（Issue #43 汇总的 4 个模板目录此时全部清理完成，注释里"still have unresolved"的说明整段可以删掉了）

- [ ] **Step 3: 补齐 `on.pull_request.paths`**

把（文件开头 `on:` 块）：

```yaml
on:
  pull_request:
    paths:
      - 'rbac-kitex/**'
      - 'admin-services-kitex/**'
      - 'admin-bff-hertz/**'
```

替换为：

```yaml
on:
  pull_request:
    paths:
      - 'rbac-kitex/**'
      - 'admin-services-kitex/**'
      - 'admin-bff-hertz/**'
      - 'rule-center/**'
```

（这是 #58 最终审查发现的遗留缺口：`rule-center/**` 此前从未被加入触发路径，导致该目录的模板改动完全不会触发这个 workflow）

- [ ] **Step 4: 补齐 `build-check` matrix**

把（`build-check` job 的 `matrix.include` 列表）：

```yaml
      matrix:
        include:
          - name: rbac-kitex
            kind: kitex
            db: none
          - name: admin-services-kitex
            kind: kitex
            db: none
          - name: admin-bff-hertz
            kind: hertz
            db: postgres
```

替换为：

```yaml
      matrix:
        include:
          - name: rbac-kitex
            kind: kitex
            db: none
          - name: admin-services-kitex
            kind: kitex
            db: none
          - name: admin-bff-hertz
            kind: hertz
            db: postgres
          - name: rule-center
            kind: kitex
            db: none
```

- [ ] **Step 5: 验证 CI 配置改动本身语法正确**

Run: `bash scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template rbac-kitex/kitex-template admin-services-kitex/kitex-template rule-center/kitex-template; echo "exit=$?"`
Expected: 无重复输出，`exit=0`

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/template-build-check.yml
git commit -m "ci(templates): add rule-center/kitex-template to duplicate-path check, paths trigger, and build-check matrix"
```

---

## Self-Review Checklist（执行前已完成）

- **Spec 覆盖**：16 组重复全部落实到 Task 1（4 组纯冗余）+ Task 2（2 组需修元数据）+ Task 3（10 组含 server.go 特殊判定）；CI 收口对应 Task 4，且额外修复了 #58 审查发现的 paths/matrix 遗漏。
- **占位符扫描**：无 TBD/TODO。
- **判定规则的方向性对调已显式声明**：Global Constraints 第一条明确写明本目录与 #57/#58 相反（保留 custom/preset，删除 exported），避免执行者套用前两个子任务的默认直觉出错。
- **命名陷阱已标注**：Task 3 的 rule_center_client 组保留/删除文件名不遵循"exported=internal_前缀"的一般模式，已在 Task 3 描述与表格里显式标注，要求执行者以内容核实为准。
