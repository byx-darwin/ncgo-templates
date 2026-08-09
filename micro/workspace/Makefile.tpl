# ncgo micro workspace Makefile
# This Makefile provides convenience commands for the workspace.

.PHONY: help check build clean dev

# Default target
help:
	@echo "ncgo micro workspace commands:"
	@echo "  make check     - Run checks on all services"
	@echo "  make build     - Build all services"
	@echo "  make clean     - Clean build artifacts"
	@echo "  make dev       - Start all services in dev mode"
	@echo ""
	@echo "Service-specific commands:"
	@echo "  cd services/<name> && make <target>"

# Check all services
check:
	@echo "==> Checking all services..."
	@for dir in services/*/; do \
		if [ -f "$$dir/Makefile" ]; then \
			echo "  Checking $$dir..."; \
			(cd "$$dir" && make check) || exit 1; \
		fi; \
	done
	@echo "==> All checks passed"

# Build all services
build:
	@echo "==> Building all services..."
	@for dir in services/*/; do \
		if [ -f "$$dir/Makefile" ]; then \
			echo "  Building $$dir..."; \
			(cd "$$dir" && make build) || exit 1; \
		fi; \
	done
	@echo "==> All builds complete"

# Clean all services
clean:
	@echo "==> Cleaning all services..."
	@for dir in services/*/; do \
		if [ -f "$$dir/Makefile" ]; then \
			echo "  Cleaning $$dir..."; \
			(cd "$$dir" && make clean) || true; \
		fi; \
	done
	@echo "==> All clean"

# Start all services in dev mode
dev:
	@echo "==> Starting all services..."
	@docker compose up --build
