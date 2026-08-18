#!/usr/bin/env bash
# ratelimit-hertz 真实功能测试（黑盒，连真实服务）
#
# 与 e2e_test.sh 的分工：
#   - e2e_test.sh      → 生成 → 无残留断言 → go build → go test（编译 + 单元测试）
#   - functional_test.sh（本脚本）→ 用 docker 起临时 PG + Redis，把生成的服务真正跑起来，
#     通过 HTTP 黑盒验证：
#       1) database.enabled=true 时服务能启动（启动路径 NewPostgres→pool.Ping，连不上会 log.Fatalf）
#          ⇒ 证明真正连上了 PostgreSQL；
#       2) rate_limit backend=redis 下，连打 /ping 触发 429 / code 10200（而非 10304 缓存不可用）
#          ⇒ 证明限流计数真正走了 Redis。
#
# 不给生成项目添加任何依赖；测试配置直接改写生成项目里 conf/dev/conf.yaml（项目即用即弃）。
#
# 门槛（缺任一 → 显式 skip，退出 0）：docker(daemon 运行) / go / ncgo / sqlc / curl / make / python3。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL_DIR="$REPO_ROOT/ratelimit-hertz"
HTTP_PORT="18080"
BASE="http://127.0.0.1:${HTTP_PORT}"
MAX_REQ=5          # pre_auth 默认规则的 max_requests；连打 > 该值应触发 429
BURST=10           # 连打次数
FAILS=0
PG_CID=""; RD_CID=""; SRV_PID=""; WORKDIR=""

log()  { printf '\033[1m[fn]\033[0m %s\n' "$*"; }
skip() { printf '\033[33m[fn] skipped: %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[fn] FAIL: %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  [ -n "$PG_CID" ]  && docker rm -f "$PG_CID" >/dev/null 2>&1 || true
  [ -n "$RD_CID" ]  && docker rm -f "$RD_CID" >/dev/null 2>&1 || true
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR" || true
}
trap cleanup EXIT

# ---------- 门槛 ----------
for t in go ncgo sqlc curl make python3 docker; do
  command -v "$t" >/dev/null 2>&1 || { skip "缺少工具：$t"; exit 0; }
done
docker info >/dev/null 2>&1 || { skip "docker daemon 未运行（先启动 docker 再跑本测试）"; exit 0; }

# ---------- 起临时 PG + Redis ----------
log "启动临时 PostgreSQL + Redis 容器"
PG_CID=$(docker run -d -P -e POSTGRES_PASSWORD=pass -e POSTGRES_USER=app -e POSTGRES_DB=appdb postgres:16-alpine) \
  || { fail "无法启动 postgres 容器"; exit 1; }
RD_CID=$(docker run -d -P redis:7-alpine) \
  || { fail "无法启动 redis 容器"; exit 1; }
PG_PORT=$(docker port "$PG_CID" 5432/tcp | head -1 | sed 's/.*://')
RD_PORT=$(docker port "$RD_CID" 6379/tcp | head -1 | sed 's/.*://')
[ -n "$PG_PORT" ] && [ -n "$RD_PORT" ] || { fail "取容器宿主端口失败"; exit 1; }
log "PG=127.0.0.1:${PG_PORT}  Redis=127.0.0.1:${RD_PORT}"

log "等待 PG / Redis 就绪"
for _ in $(seq 1 30); do docker exec "$PG_CID" pg_isready -U app >/dev/null 2>&1 && break; sleep 1; done
docker exec "$PG_CID" pg_isready -U app >/dev/null 2>&1 || { fail "PG 未就绪"; exit 1; }
for _ in $(seq 1 30); do docker exec "$RD_CID" redis-cli ping >/dev/null 2>&1 && break; sleep 1; done
docker exec "$RD_CID" redis-cli ping >/dev/null 2>&1 || { fail "Redis 未就绪"; exit 1; }

# ---------- 生成项目 ----------
WORKDIR=$(mktemp -d)
PROJ="$WORKDIR/fnsvc"
# 注意：不加 --infra redis —— ratelimit 模板已自带 internal/base/data/redis.go，
# 再 --infra redis 会因文件已存在而报错。redis 支持随模板生成，conf 里已有 redis 段。
log "ncgo 生成项目（--db postgres；redis 由模板自带）"
ncgo new fnsvc --module example.com/fnsvc --kind hertz --db postgres \
  --template-dir "$TPL_DIR" --dir "$PROJ" >/dev/null || { fail "ncgo 生成失败"; exit 1; }

log "make sqlc + go mod tidy + go build"
( cd "$PROJ" && make sqlc >/dev/null 2>&1 && go mod tidy >/dev/null 2>&1 && go build -o fnsvc-bin . ) \
  || { fail "生成项目构建失败"; exit 1; }

# 应用 sqlc schema（纯 DDL）——即使 config-sourced 限流用不到，也让表存在，顺带证明 DB 可写
for f in "$PROJ"/internal/db/schema/*.sql; do
  [ -f "$f" ] && docker exec -i "$PG_CID" psql -U app -d appdb >/dev/null 2>&1 < "$f" || true
done

# ---------- 改写测试配置 ----------
# 用 python 标准库做定向文本替换（不依赖 PyYAML —— 系统 python3 常无 yaml 模块）。
# 依赖生成配置里各目标值的唯一性：port "8080"/dsn ""/redis 6379 地址/backend memory
# /max_requests 100(仅 pre_auth) 均全局唯一；database、rate_limit 的 enabled 用分节锚定。
log "写入测试配置（PG/Redis 指向容器；开启 redis 后端限流；/healthz、/readyz 加入 skip）"
CONF="$PROJ/conf/dev/conf.yaml"
PG_PORT="$PG_PORT" RD_PORT="$RD_PORT" HTTP_PORT="$HTTP_PORT" MAX_REQ="$MAX_REQ" CONF="$CONF" python3 - <<'PY' || { echo "conf patch python 失败"; exit 3; }
import os, re, sys
p, pg, rd = os.environ["CONF"], os.environ["PG_PORT"], os.environ["RD_PORT"]
http, mx = os.environ["HTTP_PORT"], os.environ["MAX_REQ"]
t = open(p).read()
def once(old, new):
    global t
    if old not in t:
        sys.exit(f"配置里未找到锚点: {old!r}")
    t = t.replace(old, new, 1)
once('port: "8080"',    f'port: "{http}"')
once('dsn: ""',         f'dsn: "postgres://app:pass@127.0.0.1:{pg}/appdb?sslmode=disable"')
once('- 127.0.0.1:6379', f'- 127.0.0.1:{rd}')
once('backend: memory', 'backend: redis\n  skip_paths:\n    - /healthz\n    - /readyz')
once('max_requests: 100', f'max_requests: {mx}')  # 仅 pre_auth 默认规则为 100
# database / rate_limit 的 enabled: false 分节锚定（非贪婪，各取其后第一个）
t = re.sub(r'(database:.*?)enabled: false', r'\1enabled: true', t, count=1, flags=re.S)
t = re.sub(r'(rate_limit:.*?)enabled: false', r'\1enabled: true', t, count=1, flags=re.S)
open(p, "w").write(t)
print("conf patched")
PY
# 校验关键值确实写入（防止静默失配）
grep -q "port: \"$HTTP_PORT\"" "$CONF" && grep -q "backend: redis" "$CONF" \
  && grep -q "127.0.0.1:$RD_PORT" "$CONF" && grep -q "max_requests: $MAX_REQ" "$CONF" \
  || { fail "配置改写校验失败（关键值未写入 $CONF）"; exit 1; }

# ---------- 启动服务 ----------
log "启动服务"
# 用 exec 让子 shell 被二进制替换，$! 才是真正的服务进程（cleanup kill 才有效）
( cd "$PROJ" && exec ./fnsvc-bin >"$WORKDIR/server.log" 2>&1 ) &
SRV_PID=$!

# 断言 1：从日志解析真实监听地址。框架可能绑定 LAN IP 而非 127.0.0.1；且监听发生在
# NewPostgres→pool.Ping 成功之后，故能拿到监听地址本身即证明 PG 连接成功。
ADDR=""
for _ in $(seq 1 40); do
  ADDR=$(grep -oE 'address=[0-9.]+:[0-9]+' "$WORKDIR/server.log" 2>/dev/null | head -1 | sed 's/address=//')
  [ -n "$ADDR" ] && break
  kill -0 "$SRV_PID" 2>/dev/null || break   # 进程已退出（多半是 PG 连接失败 → log.Fatalf）
  sleep 1
done
if [ -z "$ADDR" ]; then
  fail "断言1 失败：服务未监听（很可能 database.enabled=true 下 PG 连接失败）。server.log 末尾："
  tail -25 "$WORKDIR/server.log" || true
  exit 1
fi
BASE="http://$ADDR"
log "服务监听于 ${ADDR}（监听发生在 pool.Ping 之后 ⇒ PostgreSQL 连接成功）"
if curl -sf "$BASE/healthz" >/dev/null 2>&1; then
  log "断言1 通过：/healthz OK ⇒ 服务健康、PG 已连接"
else
  fail "断言1 失败：/healthz 不可达 @ ${BASE}"
  tail -25 "$WORKDIR/server.log" || true
  exit 1
fi

# 附加：直接查 PG 证明可读写
docker exec "$PG_CID" psql -U app -d appdb -c '\dt' >/dev/null 2>&1 \
  && log "附加：PG 可查询（schema 已应用）" || log "附加：PG \\dt 无表（config-sourced 限流不依赖，可忽略）"

# 断言 2：redis 后端限流 —— 连打 /ping 应先 200 后 429，且 429 体含 code 10200
log "连打 /ping ${BURST} 次（max_requests=${MAX_REQ}）"
codes=""
for _ in $(seq 1 "$BURST"); do
  codes="$codes $(curl -s -o /dev/null -w '%{http_code}' "$BASE/ping")"
done
log "/ping 状态序列:${codes}"
n200=$(printf '%s' "$codes" | tr ' ' '\n' | grep -c '^200$' || true)
n429=$(printf '%s' "$codes" | tr ' ' '\n' | grep -c '^429$' || true)
body=$(curl -s "$BASE/ping" || true)
if [ "$n200" -ge 1 ] && [ "$n429" -ge 1 ]; then
  log "断言2 通过：出现 ${n200} 个 200 与 ${n429} 个 429 ⇒ Redis 后端限流生效"
  if printf '%s' "$body" | grep -q '10200'; then
    log "断言2+ 通过：429 响应体含 code 10200（真限流，非 10304 缓存不可用）"
  else
    fail "429 响应体未含 code 10200（疑似非限流拒绝）；body=${body}"
  fi
else
  fail "断言2 失败：期望同时出现 200 与 429，实际序列:${codes}；末次 body=${body}"
fi

# 断言 3：确凿区分 Redis vs 内存 —— 限流计数必须真的写进了 Redis。
# 内存后端不会在 Redis 留下任何 key；只有 backend=redis 真正生效才会有计数 key。
RKEYS=$(docker exec "$RD_CID" redis-cli dbsize 2>/dev/null | tr -dc '0-9')
if [ -n "$RKEYS" ] && [ "$RKEYS" -ge 1 ]; then
  log "断言3 通过：Redis dbsize=${RKEYS} ⇒ 限流计数确实存储于 Redis（非内存回退）。样例 key："
  docker exec "$RD_CID" redis-cli --scan 2>/dev/null | head -5 | sed 's/^/    /'
else
  fail "断言3 失败：Redis 无任何 key（dbsize=${RKEYS:-0}）⇒ 限流疑似回退到内存后端"
fi

# ---------- 结果 ----------
if [ "$FAILS" -ne 0 ]; then log "共 ${FAILS} 项失败"; exit 1; fi
log "功能测试全部通过（PG 连接 + Redis 限流均已真实验证）"
