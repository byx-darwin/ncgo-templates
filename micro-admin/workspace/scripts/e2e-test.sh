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
