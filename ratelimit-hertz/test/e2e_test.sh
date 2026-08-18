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
