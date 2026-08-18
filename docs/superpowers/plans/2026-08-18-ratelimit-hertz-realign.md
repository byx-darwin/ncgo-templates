# ratelimit-hertz 重新对齐 base-hertz 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 ratelimit-hertz 模板包全面对齐 base-hertz 的作者风格与 wiring 规范，保留全部限流能力，并新增「ncgo 加载模版后」的端到端测试。

**Architecture:** 逐组还原机器转义的 `{{ "{" }}`/`{{ "}" }}` 为字面量花括号（`body: |-` 块）、补描述性注释、恢复 `{{if}}` 条件；9 个与 base-hertz 重叠的基础文件以 base 内容为基座（base 的 `conf.go` 已内含 RateLimit/Redis/CORS/Idempotency 配置，叠加成本很低）；先落地端到端测试脚本作为 TDD 锚点（当前 35/44 文件含转义、server.go wiring 不完整，脚本必然失败），再逐组改写直到脚本通过。

**Tech Stack:** ncgo CLI（`ncgo new --template-dir`）、Go（`go build`/`go test`）、YAML 模板、bash（`e2e_test.sh`）。

**Spec:** `docs/superpowers/specs/2026-08-18-ratelimit-hertz-realign-design.md`

## Global Constraints

- 作用域仅限 `ratelimit-hertz/`（模板 YAML、README、新增 `test/`）；不改 base-hertz、不改 ncgo CLI。
- 文件名约定：**保留路径编码名**（如 `internal_pkg_middleware_cors_go.yaml`），不改文件名。
- 所有 `.yaml` 保持 `path:` 与 `update_behavior:` 键不变。
- 变量约定统一：`{{.Module}}`、`{{.ServiceName}}`、`{{ToLower .ServiceName}}`。
- 还原规则：`{{ "{" }}` → `{`；`{{ "}" }}` → `}`；置于 `body: |-` 块标量；真正的生成期分支用 `{{if .WithDatabase}}…{{end}}`。
- 头部注释统一为 `# Hertz custom template — <path>` + 一行用途说明。
- 端到端测试：hermetic(memory) 基线为**必跑门**；redis / postgres 变体按服务可用性 gated，不可用必须**显式打印 `skipped: <原因>`**（禁止静默跳过）。
- 9 个重叠文件（main/server/conf/data/errcode/middleware/response/conf.yaml/Makefile）：以 `base-hertz/hertz-template/<对应>.yaml` 的 `body` 为基座，仅叠加限流专属差异，改写后与 base 逐一 diff 复核。

---

## File Structure

新增：
- `ratelimit-hertz/test/e2e_test.sh` — 端到端测试（生成→静态断言→build→test；含 redis/postgres gated 变体）。
- `ratelimit-hertz/test/lib.sh`（可选）— 探测/日志辅助函数。

修改（分组）：
- **G1 重叠基础文件（9）**：`main_go.yaml`、`internal_base_server_server_go.yaml`、`internal_base_conf_conf_go.yaml`、`internal_base_data_data_go.yaml`、`internal_pkg_errcode_errcode_go.yaml`、`internal_pkg_middleware_middleware_go.yaml`、`internal_pkg_response_response_go.yaml`、`conf_dev_conf_yaml.yaml`、`Makefile.yaml`。
- **G2 中间件**：`cors`、`error`、`idempotency`、`memory_cache`、`observability`、`rate_limit`、`redis_client`、`signature`、`skip`、`token`（各自的 `_go.yaml`）。
- **G3 限流核心 + 基座数据**：`ratelimit/resolver`、`ratelimit/store`、`base/data/{redis,redis_shared,tx}`、`repository/rate_limit_rule`。
- **G4 装配层**：`handler/health/health`、`handler/pb/{{ToLower_ServiceName}}_service`、`router/register`、`router/pb/{{ToLower_ServiceName}}`、`router/pb/middleware`、`i18n/i18n`。
- **G5 测试模板（~15）**：全部 `*_test_go.yaml`。
- **G6 元数据**：`ratelimit-hertz/README.md`（`template.yaml` 保持原样）。

---

## Task 1: 端到端测试脚本（TDD 锚点，先失败）

**Files:**
- Create: `ratelimit-hertz/test/e2e_test.sh`

**Interfaces:**
- Consumes: `ncgo` CLI；`ratelimit-hertz/`（`--template-dir`）。
- Produces: 退出码 0=全部必跑通过；非 0=失败。可被后续任务重复调用作为验证门。

- [ ] **Step 1: 写脚本（此时预期失败）**

```bash
#!/usr/bin/env bash
# ratelimit-hertz 端到端测试：ncgo 加载模版 → 生成 → 静态断言 → build → test
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="$REPO_ROOT/ratelimit-hertz"
MOD="example.com/rl-e2e"
FAILS=0

log()  { printf '\033[1m[e2e]\033[0m %s\n' "$*"; }
skip() { printf '\033[33m[e2e] skipped: %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[e2e] FAIL: %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }

# 生成一个项目到临时目录，返回目录路径
gen() { # $1=svc-name  $2..=extra ncgo flags
  local name="$1"; shift
  local dir; dir="$(mktemp -d)"
  ncgo new "$name" --module "$MOD" --kind hertz \
    --template-dir "$TPL_DIR" --dir "$dir/$name" "$@" >/dev/null
  echo "$dir/$name"
}

# 静态断言：无残留转义 / 无未解析模板动作
assert_no_residual() { # $1=project dir
  local d="$1"
  if grep -rn '{{ "{" }}\|{{ "}" }}' "$d" >/dev/null 2>&1; then
    fail "残留 brace 转义 in $d"; grep -rn '{{ "{" }}\|{{ "}" }}' "$d" | head
  fi
  if grep -rn '{{[^}]*}}' "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留未解析模板动作 in $d"; grep -rn '{{[^}]*}}' "$d" --include='*.go' | head
  fi
}

run_go() { # $1=dir  $2=label
  ( cd "$1" && go mod tidy >/dev/null 2>&1 || true
    if go build ./... ; then log "$2 build ok"; else fail "$2 go build"; fi
    if go test ./... ; then log "$2 test ok"; else fail "$2 go test"; fi )
}

# --- 基线：hermetic memory backend（必跑）---
log "== hermetic 基线 =="
BASE_DIR="$(gen rlbase)"
assert_no_residual "$BASE_DIR"
run_go "$BASE_DIR" "hermetic"
rm -rf "$(dirname "$BASE_DIR")"

# --- redis 变体（gated）---
log "== redis 变体 =="
if command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1; then
  RD_DIR="$(gen rlredis --infra redis)"
  assert_no_residual "$RD_DIR"
  run_go "$RD_DIR" "redis"
  ( cd "$RD_DIR" && ncgo test rate-limit >/dev/null 2>&1 && log "rate-limit ok" || fail "ncgo test rate-limit" )
  rm -rf "$(dirname "$RD_DIR")"
else
  skip "本地 Redis 不可用（redis-cli ping 失败）"
fi

# --- postgres 变体（gated）---
log "== postgres 变体 =="
if command -v pg_isready >/dev/null 2>&1 && pg_isready >/dev/null 2>&1; then
  PG_DIR="$(gen rlpg --db postgres)"
  assert_no_residual "$PG_DIR"
  run_go "$PG_DIR" "postgres"
  rm -rf "$(dirname "$PG_DIR")"
else
  skip "本地 Postgres 不可用（pg_isready 失败）"
fi

if [ "$FAILS" -ne 0 ]; then log "共 $FAILS 项失败"; exit 1; fi
log "全部必跑通过"
```

- [ ] **Step 2: 赋可执行 + 运行验证其失败**

Run: `chmod +x ratelimit-hertz/test/e2e_test.sh && ./ratelimit-hertz/test/e2e_test.sh`
Expected: FAIL —— hermetic 基线因残留转义 / server.go wiring 不完整（health/router 未注册）导致 `assert_no_residual` 或 `go build` 失败。

- [ ] **Step 3: 记录失败输出**（作为后续任务的验收基线，不提交修复）

- [ ] **Step 4: Commit**

```bash
git add ratelimit-hertz/test/e2e_test.sh
git commit -m "test(ratelimit-hertz): add ncgo template e2e harness (RED)"
```

---

## Task 2: G1 — 重叠基础文件对齐（base 基座 + 限流叠加）

**Files:**
- Modify: `ratelimit-hertz/hertz-template/main_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_base_server_server_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_base_conf_conf_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_base_data_data_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_errcode_errcode_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_middleware_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_response_response_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/conf_dev_conf_yaml.yaml`
- Modify: `ratelimit-hertz/hertz-template/Makefile.yaml`
- Reference: `base-hertz/hertz-template/{main_go,server_go,conf_go,data_go,errcode_go,middleware_go,response_go,conf_dev_yaml,makefile_yaml}.yaml`

**Interfaces:**
- Consumes: base-hertz 对应文件的 `body`（作为基座）。
- Produces: ratelimit-hertz 的 9 个 `path:` 目标与 base 一致、body 为字面量花括号 + `{{if}}` 条件；`server.go` 暴露 `Run()` 且注册 health/router/限流中间件。

- [ ] **Step 1: 逐文件采用 base body 为基座**

对每个文件：读 `base-hertz/hertz-template/<对应>.yaml` 的 `body`，作为 ratelimit 版本的新 body（保持 ratelimit 的 `path:` 值不变——两边 path 相同，见 spec §3.1）。base 的 `conf.go` 已含 `RateLimit/Redis/CORS/Idempotency/Auth` 配置段，无需额外叠加。

- [ ] **Step 2: 叠加限流专属差异**

- `internal_base_server_server_go.yaml`：在 base 的中间件链（responder → AccessLog → OTel）之后，`health.Register(h)` 之前，注入限流中间件装配（引用 `internal/pkg/middleware` 的 rate-limit 装配入口，见 G2）；保留 base 的 `{{if .WithDatabase}}` DDD 块与 `router.GeneratedRegister(h)`。
- `conf_dev_conf_yaml.yaml`：以 base 的 `conf/dev/conf.yaml` 为基座，确保含 README 记载的 `rate_limit:` 段（`enabled/backend/pre_auth/default_rule`）。
- `internal_base_data_data_go.yaml`：base 基座；若 ratelimit 需要 redis 客户端装配，保留 redis 相关（redis 客户端文件在 G3）。

- [ ] **Step 3: 头部注释 + 无残留转义**

每个文件头部改为 `# Hertz custom template — <path>` + 一行用途；确认 body 内无 `{{ "{" }}`/`{{ "}" }}`。

- [ ] **Step 4: 逐文件 diff 复核**

Run:
```bash
for f in main_go:main_go internal_base_server_server_go:server_go internal_base_conf_conf_go:conf_go \
         internal_base_data_data_go:data_go internal_pkg_errcode_errcode_go:errcode_go \
         internal_pkg_middleware_middleware_go:middleware_go internal_pkg_response_response_go:response_go \
         conf_dev_conf_yaml:conf_dev_yaml Makefile:makefile_yaml; do
  rl="${f%%:*}"; bs="${f##*:}"
  echo "### $rl vs $bs"; diff <(sed -n '/^body:/,$p' ratelimit-hertz/hertz-template/$rl.yaml) \
       <(sed -n '/^body:/,$p' base-hertz/hertz-template/$bs.yaml) || true
done
```
Expected: 差异仅为已记录的限流叠加（server 中间件注入、conf rate_limit 段等），无遗漏转义。

- [ ] **Step 5: Commit**

```bash
git add ratelimit-hertz/hertz-template/{main_go,internal_base_server_server_go,internal_base_conf_conf_go,internal_base_data_data_go,internal_pkg_errcode_errcode_go,internal_pkg_middleware_middleware_go,internal_pkg_response_response_go,conf_dev_conf_yaml,Makefile}.yaml
git commit -m "refactor(ratelimit-hertz): align 9 overlapping base files to base-hertz substrate"
```

---

## Task 3: G2 — 中间件文件还原风格

**Files:**
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_middleware_{cors,error,idempotency,memory_cache,observability,rate_limit,redis_client,signature,skip,token}_go.yaml`

**Interfaces:**
- Consumes: 无（原地转换）。
- Produces: 各中间件 body 为字面量花括号、可编译；`middleware.go`（G1）装配入口引用的符号名保持不变。

- [ ] **Step 1: 逐文件还原转义**

对每个文件：`{{ "{" }}`→`{`、`{{ "}" }}`→`}`，body 改 `body: |-` 块标量；头部注释统一。**不改逻辑、不改导出符号名**（`middleware.go` 依赖它们）。

- [ ] **Step 2: 无残留转义断言**

Run: `grep -rn '{{ "{" }}\|{{ "}" }}' ratelimit-hertz/hertz-template/internal_pkg_middleware_*_go.yaml`
Expected: 无输出（排除 `*_test_go.yaml`，那是 G5）。

- [ ] **Step 3: 渲染抽查（gofmt）**

Run（对 rate_limit 与 cors 抽查渲染后语法）:
```bash
# 抽取 body、替换变量为样例、gofmt 校验
python3 - <<'PY'
import yaml,subprocess,sys
for fn in ["rate_limit","cors","skip"]:
    d=yaml.safe_load(open(f"ratelimit-hertz/hertz-template/internal_pkg_middleware_{fn}_go.yaml"))
    body=d["body"]
    for k,v in {"{{.Module}}":"example.com/x","{{.ServiceName}}":"Demo","{{ToLower .ServiceName}}":"demo"}.items():
        body=body.replace(k,v)
    # 去掉 {{if}}/{{end}} 行做粗略渲染
    body="\n".join(l for l in body.splitlines() if "{{" not in l)
    p=subprocess.run(["gofmt"],input=body,capture_output=True,text=True)
    print(fn, "OK" if p.returncode==0 else "GOFMT-ERR:\n"+p.stderr)
PY
```
Expected: 各文件 `OK`（`{{if}}` 分支剔除后仍语法完整）。

- [ ] **Step 4: Commit**

```bash
git add ratelimit-hertz/hertz-template/internal_pkg_middleware_*_go.yaml
git commit -m "refactor(ratelimit-hertz): restyle middleware templates to literal-brace bodies"
```

---

## Task 4: G3 — 限流核心 + 基座数据文件还原风格

**Files:**
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_ratelimit_{resolver,store}_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_base_data_{redis,redis_shared,tx}_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_repository_rate_limit_rule_go.yaml`

**Interfaces:**
- Consumes: 无。
- Produces: resolver/store 的公开类型与方法名保持不变（G2 rate_limit 中间件依赖）。

- [ ] **Step 1: 逐文件还原转义 + 头部注释**（规则同 Task 3 Step 1）

- [ ] **Step 2: 无残留转义断言**

Run: `grep -rn '{{ "{" }}\|{{ "}" }}' ratelimit-hertz/hertz-template/internal_pkg_ratelimit_*_go.yaml ratelimit-hertz/hertz-template/internal_base_data_*_go.yaml ratelimit-hertz/hertz-template/internal_repository_rate_limit_rule_go.yaml | grep -v _test_go`
Expected: 无输出。

- [ ] **Step 3: Commit**

```bash
git add ratelimit-hertz/hertz-template/internal_pkg_ratelimit_{resolver,store}_go.yaml \
        ratelimit-hertz/hertz-template/internal_base_data_{redis,redis_shared,tx}_go.yaml \
        ratelimit-hertz/hertz-template/internal_repository_rate_limit_rule_go.yaml
git commit -m "refactor(ratelimit-hertz): restyle ratelimit core & data templates"
```

---

## Task 5: G4 — 装配层还原风格 + 补齐注册

**Files:**
- Modify: `ratelimit-hertz/hertz-template/internal_handler_health_health_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_handler_pb_{{ToLower_ServiceName}}_service_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_router_register_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_router_pb_{{ToLower_ServiceName}}_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_router_pb_middleware_go.yaml`
- Modify: `ratelimit-hertz/hertz-template/internal_pkg_i18n_i18n_go.yaml`

**Interfaces:**
- Consumes: `health.Register(h)`、`router.GeneratedRegister(h)`（G1 server.go 调用的入口）。
- Produces: `health.Register` 与 `router.GeneratedRegister` 签名与 base 约定一致，供 server.go 调用编译通过。

- [ ] **Step 1: 逐文件还原转义 + 头部注释**

- [ ] **Step 2: 补齐注册入口**

确认 `internal/router/register.go` 暴露 `GeneratedRegister(h)`，`internal/handler/health/health.go` 暴露 `Register(h)`，与 G1 server.go 的调用点一致（base-hertz server 调用 `health.Register(h)` 与 `router.GeneratedRegister(h)`）。

- [ ] **Step 3: 无残留转义断言**

Run: `grep -rn '{{ "{" }}\|{{ "}" }}' ratelimit-hertz/hertz-template/internal_handler_*_go.yaml ratelimit-hertz/hertz-template/internal_router_*_go.yaml ratelimit-hertz/hertz-template/internal_pkg_i18n_i18n_go.yaml | grep -v _test_go`
Expected: 无输出。

- [ ] **Step 4: Commit**

```bash
git add ratelimit-hertz/hertz-template/internal_handler_*_go.yaml \
        ratelimit-hertz/hertz-template/internal_router_*_go.yaml \
        ratelimit-hertz/hertz-template/internal_pkg_i18n_i18n_go.yaml
git commit -m "refactor(ratelimit-hertz): restyle handler/router/i18n templates & wire registration"
```

---

## Task 6: G5 — 测试模板还原风格

**Files:**
- Modify: 全部 `ratelimit-hertz/hertz-template/*_test_go.yaml`（i18n_test、redis_client_test、response_test、tx_test、ratelimit store/resolver_test、observability_test、rate_limit_test、idempotency_test、cors_test、signature_test、skip_test 等 ~15 个）

**Interfaces:**
- Consumes: 各被测文件的公开符号（已在 G2-G5 保持不变）。
- Produces: 渲染后的 `*_test.go` 可被 `go test` 编译运行。

- [ ] **Step 1: 逐文件还原转义 + 头部注释**（规则同前；不改断言逻辑）

- [ ] **Step 2: 全仓无残留转义断言（含测试）**

Run: `grep -rln '{{ "{" }}\|{{ "}" }}' ratelimit-hertz/hertz-template/ | wc -l`
Expected: `0`。

- [ ] **Step 3: Commit**

```bash
git add ratelimit-hertz/hertz-template/*_test_go.yaml
git commit -m "refactor(ratelimit-hertz): restyle test templates to literal-brace bodies"
```

---

## Task 7: G6 — README 重构 + 元数据对齐

**Files:**
- Modify: `ratelimit-hertz/README.md`
- Reference: `base-hertz/README.md`

**Interfaces:**
- Consumes: base-hertz README 章节结构。
- Produces: ratelimit README 采用 base 章节骨架，保留限流内容。

- [ ] **Step 1: 按 base 章节骨架重写**

章节顺序：标题/简介 → Use → Contents → Variables → Features（保留限流算法/backend）→ Project Structure → Configuration（保留 rate_limit 示例）→ Development → License。变量说明列出 `{{.Module}}`/`{{.ServiceName}}`/`{{ToLower .ServiceName}}`。

- [ ] **Step 2: 校验 template.yaml 保持不变**

Run: `git diff --exit-code ratelimit-hertz/template.yaml && echo "template.yaml unchanged"`
Expected: 无 diff。

- [ ] **Step 3: Commit**

```bash
git add ratelimit-hertz/README.md
git commit -m "docs(ratelimit-hertz): restructure README to base-hertz layout"
```

---

## Task 8: 端到端测试转绿 + 交付验证

**Files:**
- Reference: `ratelimit-hertz/test/e2e_test.sh`（Task 1 创建）

**Interfaces:**
- Consumes: 全部 G1-G6 产物。
- Produces: e2e 基线通过；变体按可用性通过或显式 skip。

- [ ] **Step 1: 运行端到端测试（应转绿）**

Run: `./ratelimit-hertz/test/e2e_test.sh`
Expected: PASS —— hermetic 基线「全部必跑通过」；redis/postgres 变体通过或打印 `skipped: <原因>`。

- [ ] **Step 2: 全仓静态门复核**

Run:
```bash
echo "residual escapes:"; grep -rln '{{ "{" }}\|{{ "}" }}' ratelimit-hertz/ | wc -l
```
Expected: residual escapes = `0`。

> **注意：不要用 PyYAML/`yaml.safe_load` 判定模板 YAML 合法性** —— 这些文件内含 Go-template 语法（`{{ToLower .ServiceName}}`、`{{if}}`），PyYAML 会对 base-hertz 与 ratelimit-hertz **同样报错**（假阳性）。模板「合法」的权威判据是 **ncgo 能成功加载并渲染**，即 Task 8 Step 1 的 `e2e_test.sh` 成功生成项目本身。若需单独校验 YAML 结构，用 ncgo 自身的加载器而非 PyYAML。

- [ ] **Step 3: 若失败 → systematic-debugging**

任何 build/test 失败：定位到具体文件的转义/wiring 错误，回到对应 G 任务修复，重跑 Task 8 Step 1。

- [ ] **Step 4: Commit（如有修复）**

```bash
git add -A
git commit -m "fix(ratelimit-hertz): resolve e2e findings, template renders & tests green"
```

---

## Self-Review

**Spec coverage：**
- §4 风格转换 → Task 2-6 Step 1（还原转义/注释/`|-`/`{{if}}`）。
- §3.1 重叠 9 文件 base 基座 → Task 2。
- §3.2 限流专属改风格 → Task 3-6。
- §5 元数据/README → Task 7。
- §6 端到端测试（基线+redis+postgres gated）→ Task 1 + Task 8。
- §7 验证策略（无残留/YAML 合法/diff base/build+test）→ Task 2 Step 4、Task 8 Step 2。
- 无遗漏。

**Placeholder scan：** 无 TBD/TODO；e2e 脚本为完整可执行内容；每个断言给出具体命令与预期。

**Type consistency：** `health.Register(h)`、`router.GeneratedRegister(h)` 在 G1（调用）与 G4（定义）一致；G2 中间件导出符号在 G1 `middleware.go` 装配处引用，Task 3/5 明确「不改导出符号名」。
