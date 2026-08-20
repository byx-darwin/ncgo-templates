# micro-admin Design Spec

**Date:** 2026-08-20
**Issue:** [#13](https://github.com/byx-darwin/ncgo-templates/issues/13)
**Status:** Draft

## Overview

`micro-admin` 是 micro-admin（运营中台）项目的 **micro workspace 组合包**——将三个已完成的模板（rbac-kitex + admin-bff-hertz + rule-center）组装成一个可运行的 workspace。

**Bar:** Reference scaffold（正确的结构 + 可运行的 happy path + 文档化的 production seams）

## Scope

### micro-admin 职责

| 类别 | 内容 |
|------|------|
| **Workspace shell** | `compose.yaml`（共享 postgres + redis）、`ncgo.workspace`、`Makefile`、`.pre-commit-config.yaml` |
| **E2E 测试** | 混合模式：Phase 1 hermetic（构建 + 单元测试）+ Phase 2 integration（docker-compose + smoke test） |
| **IDL 引用** | 从三个模板引用 proto 文件（auth.proto、rbac.proto、rule_center.proto） |
| **文档** | README（使用文档 + prerequisites + seams） |

### 不在 Scope

- **服务模板本身**：rbac-kitex、admin-bff-hertz、rule-center 已完成
- **服务间 wiring 代码**：由 admin-bff-hertz 的 pkg/client 处理
- **生产部署**：k8s 部署是文档化的 seam，不在 v1 scope

## Architecture

### 模板结构

```
micro-admin/
├── template.yaml                    # metadata: name=micro-admin, kind=micro
├── workspace/                       # workspace shell
│   ├── ncgo.workspace              # micro workspace 元数据
│   ├── compose.yaml                # 共享 postgres + redis
│   ├── .pre-commit-config.yaml     # 本地 hooks
│   ├── Makefile                    # workspace 级别命令
│   └── scripts/
│       ├── e2e-test.sh            # 混合模式 E2E 测试脚本
│       └── smoke-test.sh          # Happy-path smoke test
├── idl/                            # 引用的 IDL（从三个模板复制）
│   ├── auth.proto
│   ├── rbac.proto
│   └── rule_center.proto
└── README.md                       # 使用文档 + prerequisites + seams
```

### 模板消费流程

```bash
# Phase 1: 创建 workspace shell
ncgo new --mode micro my-admin --module github.com/acme/my-admin --template micro-admin

# Phase 2: 添加服务（引用现有模板）
cd my-admin
ncgo add rpc rbac --template rbac-kitex
ncgo add bff admin --template admin-bff-hertz
ncgo add rpc rule --template rule-center

# Phase 3: 启动基础设施
docker compose up -d postgres redis

# Phase 4: 启动服务
make dev  # 或分别启动每个服务
```

### Workspace Shell 内容

**compose.yaml：**
```yaml
version: "3.8"

services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: micro_admin
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

volumes:
  postgres_data:
```

**ncgo.workspace：**
```yaml
mode: micro
name: micro-admin
description: "Micro workspace for admin (运营中台)"
version: "1"
```

**Makefile：**
```makefile
.PHONY: help check build clean dev test

help:
	@echo "micro-admin workspace commands:"
	@echo "  make check     - Run checks on all services"
	@echo "  make build     - Build all services"
	@echo "  make clean     - Clean build artifacts"
	@echo "  make dev       - Start all services in dev mode"
	@echo "  make test      - Run E2E tests (hermetic + integration)"
	@echo ""
	@echo "Infrastructure:"
	@echo "  make infra-up    - Start postgres + redis"
	@echo "  make infra-down  - Stop infrastructure"

check:
	@echo "==> Checking all services..."
	@for dir in services/*/; do \
		if [ -f "$$dir/Makefile" ]; then \
			echo "  Checking $$dir..."; \
			(cd "$$dir" && make check) || exit 1; \
		fi; \
	done
	@echo "==> All checks passed"

build:
	@echo "==> Building all services..."
	@for dir in services/*/; do \
		if [ -f "$$dir/Makefile" ]; then \
			echo "  Building $$dir..."; \
			(cd "$$dir" && make build) || exit 1; \
		fi; \
	done
	@echo "==> All builds complete"

clean:
	@echo "==> Cleaning all services..."
	@for dir in services/*/; do \
		if [ -f "$$dir/Makefile" ]; then \
			echo "  Cleaning $$dir..."; \
			(cd "$$dir" && make clean) || true; \
		fi; \
	done
	@echo "==> All clean"

dev:
	@echo "==> Starting all services..."
	@docker compose up --build

test:
	@./scripts/e2e-test.sh

infra-up:
	@docker compose up -d postgres redis
	@echo "==> Infrastructure started (postgres:5432, redis:6379)"

infra-down:
	@docker compose down
	@echo "==> Infrastructure stopped"
```

**.pre-commit-config.yaml：**
```yaml
repos:
  - repo: local
    hooks:
      - id: go-fmt
        name: go fmt
        entry: go fmt ./...
        language: system
        types: [go]
      - id: go-vet
        name: go vet
        entry: go vet ./...
        language: system
        types: [go]
```

### E2E 测试脚本（混合模式）

**scripts/e2e-test.sh：**
```bash
#!/bin/bash
set -e

echo "==> Phase 1: Hermetic tests (always run)"

# Build all services
echo "  Building all services..."
go build ./... || { echo "FAIL: build"; exit 1; }

# Run unit tests
echo "  Running unit tests..."
go test ./... || { echo "FAIL: unit tests"; exit 1; }

echo "==> Phase 1: PASSED"
echo ""

# Phase 2: Integration tests (require docker)
if command -v docker &>/dev/null; then
    echo "==> Phase 2: Integration tests (docker available)"
    
    # Start infrastructure
    echo "  Starting postgres + redis..."
    docker compose up -d postgres redis
    sleep 5  # 等待数据库就绪
    
    # Start services in background
    echo "  Starting services..."
    cd services/rbac-rpc && go run . &
    RBAC_PID=$!
    cd ../..
    
    cd services/admin-bff && go run . &
    BFF_PID=$!
    cd ../..
    
    cd services/rule-rpc && go run . &
    RULE_PID=$!
    cd ../..
    
    # Wait for services to start
    sleep 10
    
    # Run smoke test
    echo "  Running smoke test..."
    ./scripts/smoke-test.sh || { 
        echo "FAIL: smoke test"; 
        kill $RBAC_PID $BFF_PID $RULE_PID 2>/dev/null || true
        docker compose down
        exit 1 
    }
    
    # Cleanup
    echo "  Cleaning up..."
    kill $RBAC_PID $BFF_PID $RULE_PID 2>/dev/null || true
    docker compose down
    
    echo "==> Phase 2: PASSED"
else
    echo "==> Phase 2: SKIPPED (docker not available)"
    echo "skipped: integration tests require docker"
fi

echo ""
echo "==> All E2E tests passed"
```

**scripts/smoke-test.sh：**
```bash
#!/bin/bash
set -e

BFF_URL="http://localhost:8888"

echo "==> Smoke test: Happy path"

# 1. Login
echo "  [1/4] Login..."
LOGIN_RESP=$(curl -s -X POST $BFF_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}')

TOKEN=$(echo $LOGIN_RESP | jq -r '.access_token')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "FAIL: login failed"
    echo "Response: $LOGIN_RESP"
    exit 1
fi
echo "  ✓ Login successful"

# 2. Get current user menus
echo "  [2/4] Get current user menus..."
MENUS=$(curl -s -H "Authorization: Bearer $TOKEN" $BFF_URL/api/v1/me/menus)
if [ -z "$MENUS" ] || [ "$MENUS" = "null" ]; then
    echo "FAIL: get menus failed"
    exit 1
fi
echo "  ✓ Menus retrieved"

# 3. RBAC management (create user)
echo "  [3/4] Create user..."
CREATE_USER=$(curl -s -X POST $BFF_URL/api/v1/users \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"test123","email":"test@example.com"}')
if [ -z "$CREATE_USER" ] || echo "$CREATE_USER" | grep -q "error"; then
    echo "FAIL: create user failed"
    echo "Response: $CREATE_USER"
    exit 1
fi
echo "  ✓ User created"

# 4. Rate-limit rule management
echo "  [4/4] Create rate-limit rule..."
CREATE_RULE=$(curl -s -X POST $BFF_URL/api/v1/rate-limit-rules \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"api-limit","limit":100,"window":"1m"}')
if [ -z "$CREATE_RULE" ] || echo "$CREATE_RULE" | grep -q "error"; then
    echo "FAIL: create rate-limit rule failed"
    echo "Response: $CREATE_RULE"
    exit 1
fi
echo "  ✓ Rate-limit rule created"

echo ""
echo "==> Smoke test: PASSED"
```

### Graceful Degradation（文档化）

README 中记录：

| 场景 | 行为 |
|------|------|
| **rule-center 不可用** | admin-bff 仍可服务，限流规则管理接口返回错误，但不影响其他功能 |
| **postgres 不可用** | 所有服务启动失败（强依赖） |
| **redis 不可用** | rbac-kitex 和 rule-center 降级（缓存失效，但仍可工作） |

## Seams (Documented TODO, Not Built in v1)

| Seam | 描述 | 代码标记 |
|------|------|----------|
| **OTel Observability** | 基础 wiring，启用时需配置 jaeger | `// TODO(otel)` |
| **SSO/OIDC** | 当前 JWT，预留 SSO/OIDC 扩展点 | `// TODO(sso)` |
| **Org-tree/Data-scope** | 组织架构树 + 数据权限 | `// TODO(org-tree)` |
| **Production deployment** | k8s 部署配置 | `// TODO(k8s)` |

## Build Method

1. 创建 `micro-admin/` 目录结构
2. 编写 workspace shell（compose.yaml、ncgo.workspace、Makefile、.pre-commit-config.yaml）
3. 编写 E2E 测试脚本（e2e-test.sh + smoke-test.sh）
4. 从三个模板复制 IDL 文件
5. 编写 README（使用文档 + prerequisites + seams）
6. 验证 `ncgo new --mode micro --template micro-admin` 可构建
7. 运行 E2E 测试（hermetic + integration）

## Acceptance Criteria

- [ ] `micro-admin/` package: workspace shell + IDL + README
- [ ] `ncgo new --mode micro --template micro-admin` generates a buildable workspace
- [ ] Happy-path smoke: login → JWT → /me/menus + button perms → user/role/permission/menu management → rate-limit rule
- [ ] Graceful degradation: rule-center / postgres down → bff still serves (documented behavior)
- [ ] README documents usage, prerequisites (ncgo, hz, kitex, sqlc, postgres, redis), and seams (OTel, SSO, data-scope, k8s)
- [ ] e2e test script (hermetic + gated postgres/redis variants, explicit `skipped:` lines)
- [ ] Registry row in `ncgo-templates/README.md`

## Related

- rbac-kitex #10/#11 (authority)
- admin-bff-hertz #12 (admin BFF)
- rule-center (rate-limit)
- micro workspace reference
