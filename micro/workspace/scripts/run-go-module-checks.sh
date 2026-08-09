#!/bin/bash
# Run Go module checks (vet, test, build) on all Go services
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Running Go module checks on all services..."

FAILED=()
PASSED=()

for service_dir in "$WORKSPACE_ROOT/services"/*/; do
    if [ ! -d "$service_dir" ]; then
        continue
    fi

    service_name=$(basename "$service_dir")

    if [ ! -f "$service_dir/go.mod" ]; then
        echo "  SKIP $service_name (no go.mod)"
        continue
    fi

    echo "  CHECK $service_name..."

    # Run go vet
    if ! (cd "$service_dir" && go vet ./... > /dev/null 2>&1); then
        echo "    ✗ go vet failed"
        FAILED+=("$service_name:vet")
        continue
    fi

    # Run go build
    if ! (cd "$service_dir" && go build ./... > /dev/null 2>&1); then
        echo "    ✗ go build failed"
        FAILED+=("$service_name:build")
        continue
    fi

    # Run go test (if there are test files)
    if find "$service_dir" -name "*_test.go" -print -quit | grep -q .; then
        if ! (cd "$service_dir" && go test ./... -count=1 > /dev/null 2>&1); then
            echo "    ✗ go test failed"
            FAILED+=("$service_name:test")
            continue
        fi
    fi

    PASSED+=("$service_name")
    echo "    ✓ PASS"
done

echo ""
echo "==> Summary"
echo "  Passed: ${#PASSED[@]}"
echo "  Failed: ${#FAILED[@]}"

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "Failed checks:"
    for name in "${FAILED[@]}"; do
        echo "  - $name"
    done
    exit 1
fi

echo ""
echo "All Go module checks passed!"
