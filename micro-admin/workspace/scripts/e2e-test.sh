#!/bin/bash
set -e

echo "==> Phase 1: Hermetic tests (always run)"

# Check if services directory exists and has services
SERVICES_DIR="services"
if [ ! -d "$SERVICES_DIR" ] || [ -z "$(ls -A "$SERVICES_DIR" 2>/dev/null | grep -v '\.gitkeep')" ]; then
    echo "  No services found in workspace."
    echo "  Add services with: ncgo add rpc <name> / ncgo add bff <name>"
    echo "==> Phase 1: SKIPPED (no services to test)"
else
    # Build all services
    echo "  Building all services..."
    FAILED=0
    for service_dir in "$SERVICES_DIR"/*/; do
        if [ ! -d "$service_dir" ]; then
            continue
        fi
        service_name=$(basename "$service_dir")
        if [ ! -f "$service_dir/go.mod" ]; then
            echo "    SKIP $service_name (no go.mod)"
            continue
        fi
        echo "    Building $service_name..."
        if ! (cd "$service_dir" && go build ./... 2>&1); then
            echo "    FAIL: build $service_name"
            FAILED=1
        fi
    done

    if [ $FAILED -eq 1 ]; then
        echo "FAIL: build"
        exit 1
    fi

    # Run unit tests
    echo "  Running unit tests..."
    for service_dir in "$SERVICES_DIR"/*/; do
        if [ ! -d "$service_dir" ]; then
            continue
        fi
        service_name=$(basename "$service_dir")
        if [ ! -f "$service_dir/go.mod" ]; then
            continue
        fi
        # Only run tests if there are test files
        if find "$service_dir" -name "*_test.go" -print -quit | grep -q .; then
            echo "    Testing $service_name..."
            if ! (cd "$service_dir" && go test ./... -count=1 2>&1); then
                echo "    FAIL: test $service_name"
                FAILED=1
            fi
        fi
    done

    if [ $FAILED -eq 1 ]; then
        echo "FAIL: unit tests"
        exit 1
    fi

    echo "==> Phase 1: PASSED"
fi
echo ""

# Phase 2: Integration tests (require docker)
if [ ! -d "$SERVICES_DIR" ] || [ -z "$(ls -A "$SERVICES_DIR" 2>/dev/null | grep -v '\.gitkeep')" ]; then
    echo "==> Phase 2: SKIPPED (no services to test)"
elif command -v docker &>/dev/null; then
    echo "==> Phase 2: Integration tests (docker available)"

    # Start infrastructure
    echo "  Starting postgres + redis..."
    docker compose up -d postgres redis
    sleep 5  # Wait for database ready

    # Start services in background (if they exist)
    echo "  Starting services..."
    PIDS=""

    if [ -d "services/rbac-rpc" ] && [ -f "services/rbac-rpc/go.mod" ]; then
        cd services/rbac-rpc && go run . &
        PIDS="$PIDS $!"
        cd ../..
    fi

    if [ -d "services/admin-bff" ] && [ -f "services/admin-bff/go.mod" ]; then
        cd services/admin-bff && go run . &
        PIDS="$PIDS $!"
        cd ../..
    fi

    if [ -d "services/rule-rpc" ] && [ -f "services/rule-rpc/go.mod" ]; then
        cd services/rule-rpc && go run . &
        PIDS="$PIDS $!"
        cd ../..
    fi

    if [ -z "$PIDS" ]; then
        echo "  No services with go.mod found, skipping integration tests"
        echo "==> Phase 2: SKIPPED (no services to test)"
    else
        # Wait for services to start
        sleep 10

        # Run smoke test
        echo "  Running smoke test..."
        if ./scripts/smoke-test.sh; then
            echo "==> Phase 2: PASSED"
        else
            echo "FAIL: smoke test"
            kill $PIDS 2>/dev/null || true
            docker compose down
            exit 1
        fi

        # Cleanup
        echo "  Cleaning up..."
        kill $PIDS 2>/dev/null || true
        docker compose down
    fi
else
    echo "==> Phase 2: SKIPPED (docker not available)"
    echo "skipped: integration tests require docker"
fi

echo ""
echo "==> All E2E tests passed"
