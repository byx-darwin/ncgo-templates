#!/usr/bin/env bash
# rbac-kitex 端到端测试：ncgo 加载模版 → 生成 → 静态断言 → sqlc → build → test
#
# 门槛：
#   - hermetic 基线：必跑（domain/application/infrastructure 单测不需要 DB）。
#   - postgres 变体：gated on pg_isready + POSTGRES_DSN（真实 DB 才跑 go test）。
# 任何被跳过的变体都会显式打印 `skipped: <原因>`（禁止静默跳过）。
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
# residual-escape grep = 0). Each fragment is a unique substring of one escape.
ESC_OPEN='{{ "{'
ESC_CLOSE='{{ "}'

# 生成一个项目到临时目录，返回目录路径
gen() { # $1=svc-name
  local name="$1"; shift
  local dir; dir="$(mktemp -d)"
  ncgo new "$name" --module "$MOD" --kind kitex \
    --template-dir "$TPL_DIR" --dir "$dir/$name" --no-auto-steps "$@" >/dev/null
  echo "$dir/$name"
}

# 静态断言：生成的 .go 代码无残留转义 / 无未解析模板动作 / 无 rulecenter 泄漏。
# template/ 下的 yaml 源天然含 brace 转义，故只检查生成后的 .go 文件。
# Go 嵌套复合字面量（如 `1: {{ID: 1, ...}}`）合法包含 {{/}}，故只把 {{. / {{ 开头
# 的模板动作视为残留。
assert_no_residual() { # $1=project dir
  local d="$1"
  if grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留 brace 转义 in $d"; grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" --include='*.go' | head
  fi
  if grep -rnE '\{\{[. ]' "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留未解析模板动作 in $d"; grep -rnE '\{\{[. ]' "$d" --include='*.go' | head
  fi
  if [ -d "$d/internal/handler/rulecenter" ] || grep -rn "api/ratelimit" "$d/kitex_gen" >/dev/null 2>&1; then
    fail "rule-center 预设泄漏（非 rbac-kitex 内容）in $d"
  fi
}

# 在子 shell 里 cd 执行，但把成败带回父 shell
go_build() { # $1=dir  $2=label
  ( cd "$1" && go mod tidy >/dev/null 2>&1; go build ./... ) \
    && log "$2 build ok" || fail "$2 go build"
}
go_test() { # $1=dir  $2=label  $3..=env assignments
  local dir="$1" label="$2"; shift 2
  ( cd "$dir" && env "$@" go test ./... ) && log "$label test ok" || fail "$label go test"
}

# 工具门槛：缺少任一工具时显式跳过并 exit 0（plan Task 9 Step 1 — 禁止 "skipped" 后继续硬失败）
for tool in kitex protoc sqlc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    skip "$tool 未安装（rbac-kitex e2e 需要 $tool）"
    exit 0
  fi
done

# --- 基线：hermetic（必跑）---
log "== hermetic 基线 =="
BASE_DIR="$(gen rbace2e)"
assert_no_residual "$BASE_DIR"
( cd "$BASE_DIR" && make sqlc >/dev/null 2>&1 ) \
  && log "hermetic sqlc gen ok" || fail "hermetic make sqlc"
go_build "$BASE_DIR" "hermetic"
go_test  "$BASE_DIR" "hermetic"
rm -rf "$(dirname "$BASE_DIR")"

# --- postgres 变体（gated on pg_isready + POSTGRES_DSN）---
log "== postgres 变体 =="
if command -v pg_isready >/dev/null 2>&1 && [ -n "${POSTGRES_DSN:-}" ] && pg_isready >/dev/null 2>&1; then
  PG_DIR="$(gen rbace2epg)"
  assert_no_residual "$PG_DIR"
  ( cd "$PG_DIR" && make sqlc >/dev/null 2>&1 ) \
    && log "postgres sqlc gen ok" || fail "postgres make sqlc"
  go_build "$PG_DIR" "postgres"
  go_test  "$PG_DIR" "postgres" POSTGRES_DSN="$POSTGRES_DSN"
  rm -rf "$(dirname "$PG_DIR")"
else
  skip "postgres go test 部分（pg_isready / POSTGRES_DSN 不可用，仅验证 hermetic）"
fi

if [ "$FAILS" -ne 0 ]; then log "共 $FAILS 项失败"; exit 1; fi
log "全部必跑通过"
