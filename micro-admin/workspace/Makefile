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
	@docker compose -f compose.infra.yaml up -d
	@echo "==> Infrastructure started (postgres:5432, redis:6379)"

infra-down:
	@docker compose -f compose.infra.yaml down
	@echo "==> Infrastructure stopped"
