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
log "ncgo 生成项目（--db postgres --infra redis）"
ncgo new fnsvc --module example.com/fnsvc --kind hertz --db postgres --infra redis \
  --template-dir "$TPL_DIR" --dir "$PROJ" >/dev/null || { fail "ncgo 生成失败"; exit 1; }

log "make sqlc + go mod tidy + go build"
( cd "$PROJ" && make sqlc >/dev/null 2>&1 && go mod tidy >/dev/null 2>&1 && go build -o fnsvc-bin . ) \
  || { fail "生成项目构建失败"; exit 1; }

# 应用 sqlc schema（纯 DDL）——即使 config-sourced 限流用不到，也让表存在，顺带证明 DB 可写
for f in "$PROJ"/internal/db/schema/*.sql; do
  [ -f "$f" ] && docker exec -i "$PG_CID" psql -U app -d appdb >/dev/null 2>&1 < "$f" || true
done

# ---------- 改写测试配置 ----------
# 直接修改生成项目的 conf/dev/conf.yaml（渲染后是纯 YAML，PyYAML 可安全往返）。
log "写入测试配置（PG/Redis 指向容器；开启 redis 后端限流；/healthz、/readyz 加入 skip）"
CONF="$PROJ/conf/dev/conf.yaml"
PG_PORT="$PG_PORT" RD_PORT="$RD_PORT" HTTP_PORT="$HTTP_PORT" MAX_REQ="$MAX_REQ" CONF="$CONF" python3 - <<'PY'
import os, yaml
p = os.environ["CONF"]
d = yaml.safe_load(open(p))
d.setdefault("server", {}).setdefault("http", {})["port"] = os.environ["HTTP_PORT"]
db = d.setdefault("database", {})
db["enabled"] = True
db["dsn"] = f'postgres://app:pass@127.0.0.1:{os.environ["PG_PORT"]}/appdb?sslmode=disable'
d.setdefault("redis", {})["addrs"] = [f'127.0.0.1:{os.environ["RD_PORT"]}']
rl = d.setdefault("rate_limit", {})
rl["enabled"] = True
rl["backend"] = "redis"
# /healthz、/readyz 探活不占限流预算（key_by=[ip] 时它们与 /ping 共享计数）
rl["skip_paths"] = ["/healthz", "/readyz"]
pre = rl.setdefault("pre_auth", {})
pre["enabled"] = True
rule = pre.setdefault("default_rule", {})
rule["enabled"] = True
rule["key_by"] = ["ip"]
rule["strategy"] = "fixed_window"
rule["window_seconds"] = "60s"
rule["max_requests"] = int(os.environ["MAX_REQ"])
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
print("conf patched")
PY

# ---------- 启动服务 ----------
log "启动服务"
# 用 exec 让子 shell 被二进制替换，$! 才是真正的服务进程（cleanup kill 才有效）
( cd "$PROJ" && exec ./fnsvc-bin >"$WORKDIR/server.log" 2>&1 ) &
SRV_PID=$!

# 断言 1：服务能起来 + /healthz 200 ⇒ 真连上了 PG（database.enabled=true 下 pool.Ping 成功）
up=0
for _ in $(seq 1 30); do
  curl -sf "$BASE/healthz" >/dev/null 2>&1 && { up=1; break; }
  kill -0 "$SRV_PID" 2>/dev/null || break   # 进程已退出（多半是 PG 连接失败）
  sleep 1
done
if [ "$up" = 1 ]; then
  log "断言1 通过：服务启动 + /healthz OK ⇒ PostgreSQL 连接成功"
else
  fail "断言1 失败：服务未起（很可能 PG 连接失败）。server.log 末尾："
  tail -20 "$WORKDIR/server.log" || true
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

# ---------- 结果 ----------
if [ "$FAILS" -ne 0 ]; then log "共 ${FAILS} 项失败"; exit 1; fi
log "功能测试全部通过（PG 连接 + Redis 限流均已真实验证）"
