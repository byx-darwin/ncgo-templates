#!/usr/bin/env bash
# rbac-kitex 端到端测试：ncgo 加载模版 → 生成 → 静态断言 → sqlc → build → test
#
# 门槛：
#   - 必跑：ncgo/kitex/protoc/sqlc 工具存在；否则显式 `skipped:` + exit 0。
#   - hermetic：domain/application 单测无需 DB 必跑。
#   - postgres：go test 的 repo 集成测试 gated on pg_isready + POSTGRES_DSN；
#     缺失时显式打印 `skipped:`（禁止静默跳过）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="$REPO_ROOT/rbac-kitex"
MOD="example.com/rbac-e2e"
FAILS=0

log()  { printf '\033[1m[e2e]\033[0m %s\n' "$*"; }
skip() { printf '\033[33m[e2e] skipped: %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[e2e] FAIL: %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }

# Brace-escape patterns, written as truncated fragments so this script itself
# does not contain the literal machine-escape sequence (keeps repo-wide
# residual-escape grep = 0).
ESC_OPEN='{{ "{'
ESC_CLOSE='{{ "}'

gen() { # $1=svc-name
  local name="$1"
  local dir; dir="$(mktemp -d)"
  ncgo new "$name" --module "$MOD" --kind kitex --db postgres \
    --template-dir "$TPL_DIR" --dir "$dir/$name" --no-auto-steps >/dev/null
  echo "$dir/$name"
}

# 静态断言：生成的源码中无残留转义 / 无未解析模板动作（在父 shell 累加 FAILS）。
# template/ 目录里的 yaml 允许包含转义序列（{{ "{" }} 等），只在渲染后的 .go 里检查。
assert_no_residual() { # $1=project dir
  local d="$1"
  local go_files; go_files="$(find "$d" -name '*.go' -not -path '*/template/*' -not -path '*/kitex_gen/*' -not -path '*/internal/db/gen/*')"
  if [ -n "$go_files" ]; then
    if grep -n -e "$ESC_OPEN" -e "$ESC_CLOSE" $go_files >/dev/null 2>&1; then
      fail "残留 brace 转义 in $d"; grep -n -e "$ESC_OPEN" -e "$ESC_CLOSE" $go_files | head
    fi
    # 只匹配未渲染的模板动作（. 变量 / ToLower / exportName），
    # 不匹配合法的 Go 复合字面量（如 {{ID: 1}}）。
    if grep -nE '\{\{[.]|\{\{ToLower|\{\{exportName' $go_files >/dev/null 2>&1; then
      fail "残留未解析模板动作 in $d"; grep -nE '\{\{[.]|\{\{ToLower|\{\{exportName' $go_files | head
    fi
  fi
}

# 在子 shell 里 cd 执行，但把成败带回父 shell（fail 必须在父 shell 调用）。
go_build() { # $1=dir  $2=label
  ( cd "$1" && go mod tidy >/dev/null 2>&1; go build ./... ) \
    && log "$2 build ok" || fail "$2 go build"
}
go_test() { # $1=dir  $2=label
  ( cd "$1" && go test ./... ) && log "$2 test ok" || fail "$2 go test"
}

# --- 工具门槛（必跑路径）---
log "== 工具门槛 =="
for tool in ncgo kitex protoc sqlc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    skip "$tool 未安装（install: 见 ncgo README）"
    exit 0
  fi
done

# --- 生成 + 静态断言 + sqlc + build + hermetic test（必跑）---
log "== hermetic 基线 =="
DIR="$(gen rbac-e2e)"
assert_no_residual "$DIR"
if [ "$FAILS" -ne 0 ]; then rm -rf "$(dirname "$DIR")"; exit 1; fi

( cd "$DIR" && make sqlc >/dev/null 2>&1 ) \
  && log "sqlc gen ok" || fail "make sqlc"
go_build "$DIR" "hermetic"
go_test  "$DIR" "hermetic"

# --- postgres-gated repo 集成测试 ---
if command -v pg_isready >/dev/null 2>&1 && [ -n "${POSTGRES_DSN:-}" ]; then
  go_test "$DIR" "postgres"
else
  skip "postgres go test 部分（需 pg_isready + POSTGRES_DSN）"
fi

rm -rf "$(dirname "$DIR")"

if [ "$FAILS" -ne 0 ]; then log "共 $FAILS 项失败"; exit 1; fi
log "全部必跑通过"
