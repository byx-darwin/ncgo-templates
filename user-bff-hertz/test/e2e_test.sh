#!/usr/bin/env bash
# user-bff-hertz 端到端测试：ncgo 加载模版 → 生成 → 补齐 kitex_gen（两个
# RPC client：user-kitex 的 UserService + rule-center 的 RuleService）→
# 静态断言 → build → test
#
# 门槛：
#   - hermetic 基线：必跑（handler/middleware 单测不需要真实 user-kitex / rule-center / redis）。
#   - 工具缺失（ncgo / hz / kitex / protoc）时显式跳过，禁止静默跳过或硬失败。
#
# 已知 flake（与本模版代码无关，out of scope）：internal/pkg/i18n 的
# TestTranslateBuiltInLanguages 偶发失败——在任何 hz 生成的 vanilla scaffold
# 上都会复现，与 user-bff-hertz 自身逻辑无关，不做特殊处理。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="$REPO_ROOT/user-bff-hertz"
MOD="example.com/userbff-e2e"
FAILS=0

log()  { printf '\033[1m[e2e]\033[0m %s\n' "$*"; }
skip() { printf '\033[33m[e2e] skipped: %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[e2e] FAIL: %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }

# Brace-escape patterns, written as truncated fragments so this script itself
# does not contain the literal machine-escape sequence (keeps repo-wide
# residual-escape grep = 0). Each fragment is a unique substring of one escape.
ESC_OPEN='{{ "{'
ESC_CLOSE='{{ "}'

# 工具门槛：缺少任一工具时显式跳过并 exit 0（禁止 "skipped" 后继续硬失败）
for tool in ncgo hz kitex protoc; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    skip "$tool 未安装（user-bff-hertz e2e 需要 $tool）"
    exit 0
  fi
done

# 生成一个项目到临时目录，返回目录路径
gen() { # $1=svc-name
  local name="$1"; shift
  local dir; dir="$(mktemp -d)"
  ncgo new "$name" --module "$MOD" --kind hertz \
    --template-dir "$TPL_DIR" --dir "$dir/$name" "$@" >/dev/null
  echo "$dir/$name"
}

# 补齐 kitex_gen/：user-bff-hertz 模版只带 idl/*.proto，不预置生成好的 RPC
# client 代码。真实使用者渲染完模版后必须跑两次 `ncgo add kitex-client`
# （一次对 user-kitex 的 UserService，一次对 rule-center 的 RuleService）
# 才能 build 通过——这一步在此复现，否则 e2e 会在 go build 处假性失败。
#
# 注意：server.go 从渲染起就同时 import 了 userservice 和 ruleservice 两个
# 包，所以第一条 `ncgo add kitex-client user` 命令内部触发的 `go mod tidy`
# 必然会因为 ruleservice 包还不存在而以非零退出码结束——这是预期中的顺序性
# 失败，不代表 user client 本身生成失败（kitex_gen/api/user/v1 与
# pkg/client/user 仍会正确写出）。真正决定成败的是第二条命令之后统一执行
# 的 `go mod tidy`，因此这里不对第一条命令的退出码做失败判定，只检查产物
# 是否落地；第二条命令（此时两个包都已就绪）才按退出码判定成败。
add_kitex_clients() { # $1=project dir
  local d="$1"
  ( cd "$d" && ncgo add kitex-client user --service UserService --idl idl/user.proto --module "$MOD" >/dev/null 2>&1 )
  if [ -d "$d/kitex_gen/api/user/v1" ] && [ -f "$d/pkg/client/user/client.go" ]; then
    log "kitex-client user codegen ok"
  else
    fail "ncgo add kitex-client user did not produce kitex_gen/api/user/v1 + pkg/client/user"
  fi
  ( cd "$d" && ncgo add kitex-client rulecenter --service RuleService --idl idl/rule_center.proto --module "$MOD" >/dev/null 2>&1 ) \
    && log "kitex-client rulecenter ok" || fail "ncgo add kitex-client rulecenter"
}

# 静态断言：生成的 .go 代码无残留转义 / 无未解析模板动作。
assert_no_residual() { # $1=project dir
  local d="$1"
  if grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留 brace 转义 in $d"; grep -rn -e "$ESC_OPEN" -e "$ESC_CLOSE" "$d" --include='*.go' | head
  fi
  if grep -rnE '\{\{[. ]' "$d" --include='*.go' >/dev/null 2>&1; then
    fail "残留未解析模板动作 in $d"; grep -rnE '\{\{[. ]' "$d" --include='*.go' | head
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

# --- 基线：hermetic（必跑）---
log "== hermetic 基线 =="
BASE_DIR="$(gen userbffbase)"
add_kitex_clients "$BASE_DIR"
assert_no_residual "$BASE_DIR"
go_build "$BASE_DIR" "hermetic"
go_test  "$BASE_DIR" "hermetic"
rm -rf "$(dirname "$BASE_DIR")"

if [ "$FAILS" -ne 0 ]; then log "共 $FAILS 项失败"; exit 1; fi
log "全部必跑通过"
