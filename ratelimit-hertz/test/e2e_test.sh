#!/usr/bin/env bash
# ratelimit-hertz 端到端测试：ncgo 加载模版 → 生成 → 静态断言 → build → test
#
# 门槛：
#   - hermetic (memory backend) 基线：必跑。
#   - redis 变体：gated on redis-cli（可 ping）。
#   - postgres 变体：gated on sqlc（build 需 sqlc 生成 internal/db/gen，
#     不需要真跑 postgres）；go test 部分再额外 gated on pg_isready。
# 任何被跳过的变体都会显式打印 `skipped: <原因>`（禁止静默跳过）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="$REPO_ROOT/ratelimit-hertz"
MOD="example.com/rl-e2e"
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
gen() { # $1=svc-name  $2..=extra ncgo flags
  local name="$1"; shift
  local dir; dir="$(mktemp -d)"
  ncgo new "$name" --module "$MOD" --kind hertz \
    --template-dir "$TPL_DIR" --dir "$dir/$name" "$@" >/dev/null
  echo "$dir/$name"
}

# 静态断言：无残留转义 / 无未解析模板动作（在父 shell 累加 FAILS）
assert_no_residual() { # $1=project dir
  local d="$1"
  if grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" >/dev/null 2>&1; then
    fail "残留 brace 转义 in $d"; grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" | head
  fi
  if grep -rn '{{[^}]*}}' "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留未解析模板动作 in $d"; grep -rn '{{[^}]*}}' "$d" --include='*.go' | head
  fi
}

# 在子 shell 里 cd 执行，但把成败带回父 shell（关键：fail 必须在父 shell 调用，
# 否则 FAILS 在子 shell 里自增、退出后丢失 → 失败被吞掉）。
go_build() { # $1=dir  $2=label
  ( cd "$1" && go mod tidy >/dev/null 2>&1; go build ./... ) \
    && log "$2 build ok" || fail "$2 go build"
}
go_test() { # $1=dir  $2=label
  ( cd "$1" && go test ./... ) && log "$2 test ok" || fail "$2 go test"
}

# --- 基线：hermetic memory backend（必跑）---
log "== hermetic 基线 =="
BASE_DIR="$(gen rlbase)"
assert_no_residual "$BASE_DIR"
go_build "$BASE_DIR" "hermetic"
go_test  "$BASE_DIR" "hermetic"
rm -rf "$(dirname "$BASE_DIR")"

# --- redis 变体（gated on redis-cli）---
log "== redis 变体 =="
if command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1; then
  RD_DIR="$(gen rlredis --infra redis)"
  assert_no_residual "$RD_DIR"
  go_build "$RD_DIR" "redis"
  ( cd "$RD_DIR" && ncgo test rate-limit >/dev/null 2>&1 ) \
    && log "rate-limit ok" || fail "ncgo test rate-limit"
  rm -rf "$(dirname "$RD_DIR")"
else
  skip "本地 Redis 不可用（redis-cli ping 失败）"
fi

# --- postgres 变体（gated on sqlc）---
# build 只需 sqlc 生成 internal/db/gen，不需要真跑 postgres；
# go test 需要连接真实 DB，故额外 gated on pg_isready。
log "== postgres 变体 =="
if command -v sqlc >/dev/null 2>&1; then
  PG_DIR="$(gen rlpg --db postgres)"
  assert_no_residual "$PG_DIR"
  ( cd "$PG_DIR" && make sqlc >/dev/null 2>&1 ) \
    && log "postgres sqlc gen ok" || fail "postgres make sqlc"
  go_build "$PG_DIR" "postgres"
  if command -v pg_isready >/dev/null 2>&1 && pg_isready >/dev/null 2>&1; then
    go_test "$PG_DIR" "postgres"
  else
    skip "postgres go test 部分（pg_isready 不可用，仅验证 build）"
  fi
  rm -rf "$(dirname "$PG_DIR")"
else
  skip "sqlc 未安装（postgres build 需 sqlc 生成 internal/db/gen；install: go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest）"
fi

if [ "$FAILS" -ne 0 ]; then log "共 $FAILS 项失败"; exit 1; fi
log "全部必跑通过"
