# micro-admin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a micro workspace composition template that wires rbac-kitex + admin-bff-hertz + rule-center into a runnable admin workspace.

**Architecture:** Reference-based composition — micro-admin provides workspace shell (compose, pre-commit, Makefile) and references existing service templates. Consumption orchestrates `ncgo add rpc/bff --template` to assemble the workspace.

**Tech Stack:** ncgo CLI, Docker Compose, Make, Shell scripts, Protocol Buffers

**Spec:** docs/superpowers/specs/2026-08-20-micro-admin-design.md

## Global Constraints

- Template kind: `micro`
- Composition model: Reference-based (not standalone copies)
- Infrastructure: Shared postgres + redis (single compose instance)
- E2E testing: Hybrid mode (hermetic + gated integration with docker)
- Documentation: All seams (OTel, SSO, data-scope, k8s) documented but not implemented

---

## File Structure

```
micro-admin/
├── template.yaml                    # Task 1
├── workspace/                       # Tasks 2-3
│   ├── ncgo.workspace              
│   ├── compose.yaml                
│   ├── .pre-commit-config.yaml     
│   ├── Makefile                    
│   └── scripts/
│       ├── e2e-test.sh            
│       └── smoke-test.sh          
├── idl/                            # Task 4
│   ├── auth.proto
│   ├── rbac.proto
│   └── rule_center.proto
└── README.md                       # Task 5

ncgo-templates/README.md            # Task 6 (modify)
```

---

### Task 1: Create Template Metadata

**Files:**
- Create: `micro-admin/template.yaml`

**Interfaces:**
- Consumes: Nothing
- Produces: Template metadata file

- [ ] **Step 1: Create template.yaml**

```yaml
name: micro-admin
kind: micro
description: "Official micro-admin workspace composition template (rbac-kitex + admin-bff-hertz + rule-center)"
version: "1"
```

- [ ] **Step 2: Verify file created**

Run: `cat micro-admin/template.yaml`
Expected: File displays with correct YAML content

- [ ] **Step 3: Commit**

```bash
git add micro-admin/template.yaml
git commit -m "feat(micro-admin): add template metadata"
```

---

### Task 2: Create Workspace Shell — Infrastructure

**Files:**
- Create: `micro-admin/workspace/compose.yaml`
- Create: `micro-admin/workspace/ncgo.workspace`

**Interfaces:**
- Consumes: Nothing
- Produces: Infrastructure configuration files

- [ ] **Step 1: Create compose.yaml**

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

- [ ] **Step 2: Create ncgo.workspace**

```yaml
mode: micro
name: micro-admin
description: "Micro workspace for admin (运营中台)"
version: "1"
```

- [ ] **Step 3: Verify files created**

Run: `ls -la micro-admin/workspace/`
Expected: compose.yaml and ncgo.workspace present

- [ ] **Step 4: Commit**

```bash
git add micro-admin/workspace/compose.yaml micro-admin/workspace/ncgo.workspace
git commit -m "feat(micro-admin): add workspace infrastructure (compose + ncgo.workspace)"
```

---

### Task 3: Create Workspace Shell — Build & Hooks

**Files:**
- Create: `micro-admin/workspace/Makefile`
- Create: `micro-admin/workspace/.pre-commit-config.yaml`

**Interfaces:**
- Consumes: Nothing
- Produces: Build automation and git hooks configuration

- [ ] **Step 1: Create Makefile**

```makefile
.PHONY: help check build clean dev test infra-up infra-down

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

- [ ] **Step 2: Create .pre-commit-config.yaml**

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

- [ ] **Step 3: Verify files created**

Run: `ls -la micro-admin/workspace/`
Expected: Makefile and .pre-commit-config.yaml present

- [ ] **Step 4: Commit**

```bash
git add micro-admin/workspace/Makefile micro-admin/workspace/.pre-commit-config.yaml
git commit -m "feat(micro-admin): add workspace build automation and git hooks"
```

---

### Task 4: Create E2E Test Scripts

**Files:**
- Create: `micro-admin/workspace/scripts/e2e-test.sh`
- Create: `micro-admin/workspace/scripts/smoke-test.sh`

**Interfaces:**
- Consumes: Workspace with services
- Produces: E2E test automation

- [ ] **Step 1: Create scripts directory**

```bash
mkdir -p micro-admin/workspace/scripts
```

- [ ] **Step 2: Create e2e-test.sh**

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
    sleep 5  # Wait for database ready
    
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

- [ ] **Step 3: Create smoke-test.sh**

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

- [ ] **Step 4: Make scripts executable**

```bash
chmod +x micro-admin/workspace/scripts/e2e-test.sh
chmod +x micro-admin/workspace/scripts/smoke-test.sh
```

- [ ] **Step 5: Verify scripts created and executable**

Run: `ls -la micro-admin/workspace/scripts/`
Expected: e2e-test.sh and smoke-test.sh present with execute permissions

- [ ] **Step 6: Commit**

```bash
git add micro-admin/workspace/scripts/
git commit -m "feat(micro-admin): add E2E test scripts (hermetic + integration)"
```

---

### Task 5: Copy IDL References

**Files:**
- Create: `micro-admin/idl/auth.proto`
- Create: `micro-admin/idl/rbac.proto`
- Create: `micro-admin/idl/rule_center.proto`

**Interfaces:**
- Consumes: IDL files from rbac-kitex, admin-bff-hertz, rule-center
- Produces: Copied proto files for reference

- [ ] **Step 1: Create idl directory**

```bash
mkdir -p micro-admin/idl
```

- [ ] **Step 2: Copy auth.proto from rbac-kitex**

```bash
cp rbac-kitex/idl/auth.proto micro-admin/idl/auth.proto
```

- [ ] **Step 3: Copy rbac.proto from rbac-kitex**

```bash
cp rbac-kitex/idl/rbac.proto micro-admin/idl/rbac.proto
```

- [ ] **Step 4: Copy rule_center.proto from rule-center**

```bash
cp rule-center/idl/rule_center.proto micro-admin/idl/rule_center.proto
```

- [ ] **Step 5: Verify IDL files copied**

Run: `ls -la micro-admin/idl/`
Expected: auth.proto, rbac.proto, rule_center.proto present

- [ ] **Step 6: Commit**

```bash
git add micro-admin/idl/
git commit -m "feat(micro-admin): copy IDL references from service templates"
```

---

### Task 6: Create README Documentation

**Files:**
- Create: `micro-admin/README.md`

**Interfaces:**
- Consumes: All previous tasks
- Produces: User-facing documentation

- [ ] **Step 1: Create README.md**

```markdown
# micro-admin

Official **micro-admin workspace** composition template — wires `rbac-kitex` (authority) + `admin-bff-hertz` (admin BFF) + `rule-center` (rate-limit) into a runnable micro workspace for the micro-admin (运营中台) program.

## Overview

This template provides a **workspace shell** that orchestrates three service templates into a cohesive admin workspace:

- **rbac-kitex** — RBAC + auth authority service (users, roles, permissions, menus, Casbin enforcement, JWT login)
- **admin-bff-hertz** — Admin BFF (thin HTTP API gateway with JWT auth + RBAC authorization)
- **rule-center** — Rate-limit rule-center service (dynamic rate-limit rules)

## Prerequisites

- `ncgo` CLI (latest version)
- `hz` (Hertz code generator)
- `kitex` (Kitex code generator)
- `sqlc` (SQL compiler)
- `docker` + `docker compose` (for infrastructure)
- `postgres` 15+ (or use docker-compose)
- `redis` 7+ (or use docker-compose)

## Quick Start

### 1. Create Workspace

```bash
ncgo new --mode micro my-admin --module github.com/acme/my-admin --template micro-admin
cd my-admin
```

### 2. Add Services

```bash
# Add RBAC service
ncgo add rpc rbac --template rbac-kitex

# Add Admin BFF
ncgo add bff admin --template admin-bff-hertz

# Add Rule Center service
ncgo add rpc rule --template rule-center
```

### 3. Start Infrastructure

```bash
# Start postgres + redis
make infra-up

# Or manually:
docker compose up -d postgres redis
```

### 4. Initialize Databases

```bash
# Run migrations for rbac-rpc
cd services/rbac-rpc
make migrate

# Run migrations for rule-rpc
cd ../rule-rpc
make migrate

cd ../..
```

### 5. Start Services

```bash
# Start all services
make dev

# Or start individually:
cd services/rbac-rpc && go run . &
cd services/admin-bff && go run . &
cd services/rule-rpc && go run . &
```

### 6. Test

```bash
# Login
curl -X POST http://localhost:8888/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}'

# Get current user menus
curl -H "Authorization: Bearer <token>" http://localhost:8888/api/v1/me/menus
```

## E2E Testing

The workspace includes hybrid E2E tests:

```bash
# Run all tests (hermetic + integration if docker available)
make test

# Or run manually:
./scripts/e2e-test.sh
```

**Test Phases:**
- **Phase 1 (Hermetic):** Always runs — build + unit tests
- **Phase 2 (Integration):** Requires docker — starts services + runs smoke test

## Workspace Layout

```
my-admin/
├── ncgo.workspace          # micro workspace metadata
├── compose.yaml            # postgres + redis
├── Makefile                # workspace commands
├── .pre-commit-config.yaml # git hooks
├── scripts/
│   ├── e2e-test.sh        # E2E test runner
│   └── smoke-test.sh      # Happy-path smoke test
└── services/
    ├── rbac-rpc/           # Kitex RBAC service
    ├── admin-bff/          # Hertz Admin BFF
    └── rule-rpc/           # Kitex Rule Center service
```

## Graceful Degradation

| Scenario | Behavior |
|----------|----------|
| **rule-center unavailable** | admin-bff still serves; rate-limit rule management returns errors, other functions unaffected |
| **postgres unavailable** | All services fail to start (hard dependency) |
| **redis unavailable** | rbac-rpc and rule-rpc degrade (cache misses, but still functional) |

## Seams (Documented TODO, Not Built in v1)

| Seam | Description | Code Marker |
|------|-------------|-------------|
| **OTel Observability** | Basic wiring, requires jaeger config | `// TODO(otel)` |
| **SSO/OIDC** | Current JWT, extensible to SSO/OIDC | `// TODO(sso)` |
| **Org-tree/Data-scope** | Organization tree + data permissions | `// TODO(org-tree)` |
| **Production deployment** | k8s deployment configs | `// TODO(k8s)` |

## Related

- [rbac-kitex](../rbac-kitex/) — Authority service template
- [admin-bff-hertz](../admin-bff-hertz/) — Admin BFF template
- [rule-center](../rule-center/) — Rate-limit service template
- [Issue #13](https://github.com/byx-darwin/ncgo-templates/issues/13) — micro-admin composition
```

- [ ] **Step 2: Verify README created**

Run: `cat micro-admin/README.md | head -20`
Expected: README displays with correct content

- [ ] **Step 3: Commit**

```bash
git add micro-admin/README.md
git commit -m "docs(micro-admin): add README with usage, prerequisites, and seams"
```

---

### Task 7: Update Template Registry

**Files:**
- Modify: `README.md` (root)

**Interfaces:**
- Consumes: micro-admin template package
- Produces: Registry entry in main README

- [ ] **Step 1: Add micro-admin row to registry table**

Open `README.md` and find the Templates table. Add this row after the `micro` row:

```markdown
| `micro-admin` | micro | Micro-admin workspace composition (rbac-kitex + admin-bff-hertz + rule-center) | ⚠️ composition package; consumption lands with ncgo micro workspace template support |
```

- [ ] **Step 2: Verify registry updated**

Run: `grep -A 1 "micro-admin" README.md`
Expected: micro-admin row present in table

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add micro-admin to template registry"
```

---

### Task 8: Validation & E2E Test

**Files:**
- None (validation only)

**Interfaces:**
- Consumes: All previous tasks
- Produces: Validation that template works end-to-end

- [ ] **Step 1: Verify directory structure**

Run: `tree micro-admin/ -L 3`
Expected: Complete directory structure matches spec

- [ ] **Step 2: Verify template.yaml valid**

Run: `cat micro-admin/template.yaml`
Expected: Valid YAML with name, kind, description, version

- [ ] **Step 3: Verify all files present**

Run: `find micro-admin/ -type f | sort`
Expected: All files from spec present

- [ ] **Step 4: Test template consumption (if ncgo available)**

```bash
# This step requires ncgo CLI
# If available, test:
# ncgo new --mode micro test-admin --module github.com/test/admin --template micro-admin
# cd test-admin
# go build ./...
```

- [ ] **Step 5: Run hermetic E2E tests**

```bash
cd micro-admin/workspace
./scripts/e2e-test.sh
```

Expected: Phase 1 (hermetic) passes. Phase 2 skips if docker unavailable.

- [ ] **Step 6: Final commit (if any fixes needed)**

```bash
git add .
git commit -m "test(micro-admin): validate template structure and E2E tests"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** All requirements from spec covered (workspace shell, compose, E2E tests, IDL, README, registry)
- [x] **Placeholder scan:** No TBD/TODO placeholders (only documented seams)
- [x] **Type consistency:** File paths and names consistent across tasks
- [x] **Task granularity:** Each task produces independently testable deliverable
- [x] **Step clarity:** Each step is 2-5 minutes with explicit commands

---

## Plan Complete

**Plan saved to:** `docs/superpowers/plans/2026-08-20-micro-admin.md`

**Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
