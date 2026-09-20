#!/usr/bin/env bash
# base-hertz 端到端测试：ncgo 加载模版 → 生成 → 静态断言 → build → vet → test
#
# 门槛：
#   - hermetic 基线（默认 memory backend）：必跑，是本脚本唯一的必跑用例。
#
# 范围说明（对照 ratelimit-hertz/test/e2e_test.sh 裁剪）：
#   - 无 postgres 变体：base-hertz 模版下没有任何 db/sqlc 相关文件
#     （`ls base-hertz/hertz-template | grep -i 'db_\|sqlc'` 为空），模版本身
#     不产出需要连接 postgres 的代码路径。
#   - 无 redis 变体：base-hertz 的 `rate_limit.backend`（以及 idempotency/
#     signature 的 backend）在 `conf_dev_conf_yaml.yaml` 中默认写死为
#     "memory"，且不像 ratelimit-hertz 那样有 `--infra redis` 联动切换
#     默认 backend 的模板逻辑 —— 生成后仍是 memory backend，加一个「假装测了
#     redis」的变体不会验证任何东西，比不加更危险。若未来 base-hertz 增加了
#     真正可切换 redis backend 的生成入口，再补这个变体。
#
# 本脚本要捕获的具体 bug 类别（Issue #80）：模版文件里残留硬编码的占位
# module path（例如 github.com/acme/scratch）而不是 {{.Module}}，导致新鲜
# 生成的项目 `go mod tidy` 失败。`assert_no_residual` 里的未解析模板动作检查
# 顺带覆盖了 {{...}} 残留，但 acme/scratch 这类"看起来合法的 Go import 但
# 指向不存在模块"的问题不会被那个检查捕获，因此下面额外做一次
# `go mod tidy` + `go build`/`go vet`/`go test` 的全链路验证。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="$REPO_ROOT/base-hertz"
MOD="example.com/bh-e2e"
FAILS=0

log()  { printf '\033[1m[e2e]\033[0m %s\n' "$*"; }
skip() { printf '\033[33m[e2e] skipped: %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[e2e] FAIL: %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }

# Brace-escape patterns, written as truncated fragments so this script itself
# does not contain the literal machine-escape sequence (keeps repo-wide
# residual-escape grep = 0). Each fragment is a unique substring of one escape.
ESC_OPEN='{{ "{'
ESC_CLOSE='{{ "}'

# 工具门槛：缺少 ncgo 时显式跳过并 exit 0（禁止 skipped 后继续硬失败）
if ! command -v ncgo >/dev/null 2>&1; then
  skip "ncgo 未安装（base-hertz e2e 需要 ncgo）"
  exit 0
fi

# 生成一个项目到临时目录，返回目录路径
gen() { # $1=svc-name  $2..=extra ncgo flags
  local name="$1"; shift
  local dir; dir="$(mktemp -d)"
  ncgo new "$name" --module "$MOD" --kind hertz \
    --template-dir "$TPL_DIR" --dir "$dir/$name" "$@" >/dev/null
  echo "$dir/$name"
}

# 静态断言：无残留转义 / 无未解析模板动作 / 无遗留占位 module path
# （在父 shell 累加 FAILS）
assert_no_residual() { # $1=project dir
  local d="$1"
  if grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留 brace 转义 in $d"; grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" --include='*.go' | head
  fi
  if grep -rn '{{[^}]*}}' "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留未解析模板动作 in $d"; grep -rn '{{[^}]*}}' "$d" --include='*.go' | head
  fi
  if grep -rln "acme/scratch" "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留占位 module path (acme/scratch) in $d"; grep -rn "acme/scratch" "$d" --include='*.go' | head
  fi
}

# 在子 shell 里 cd 执行，但把成败带回父 shell（关键：fail 必须在父 shell 调用，
# 否则 FAILS 在子 shell 里自增、退出后丢失 → 失败被吞掉）。
go_build() { # $1=dir  $2=label
  ( cd "$1" && go mod tidy >/dev/null 2>&1 && go build ./... ) \
    && log "$2 build ok" || fail "$2 go build"
}
go_vet() { # $1=dir  $2=label
  ( cd "$1" && go vet ./... ) && log "$2 vet ok" || fail "$2 go vet"
}
go_test() { # $1=dir  $2=label
  ( cd "$1" && go test ./... ) && log "$2 test ok" || fail "$2 go test"
}

# --- 基线：hermetic memory backend（必跑，唯一变体）---
log "== hermetic 基线 =="
BASE_DIR="$(gen bhbase)"
assert_no_residual "$BASE_DIR"
go_build "$BASE_DIR" "hermetic"
go_vet   "$BASE_DIR" "hermetic"
go_test  "$BASE_DIR" "hermetic"
rm -rf "$(dirname "$BASE_DIR")"

if [ "$FAILS" -ne 0 ]; then log "共 $FAILS 项失败"; exit 1; fi
log "全部必跑通过"
