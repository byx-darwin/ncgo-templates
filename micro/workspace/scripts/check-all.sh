#!/bin/bash
# Run ncgo check on all services in the workspace
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Running ncgo check on all services..."

FAILED=()
PASSED=()

for service_dir in "$WORKSPACE_ROOT/services"/*/; do
    if [ ! -d "$service_dir" ]; then
        continue
    fi

    service_name=$(basename "$service_dir")

    if [ ! -f "$service_dir/.ncgo/manifest.yaml" ]; then
        echo "  SKIP $service_name (no manifest)"
        continue
    fi

    echo "  CHECK $service_name..."
    if ncgo check --root "$service_dir" > /dev/null 2>&1; then
        PASSED+=("$service_name")
        echo "    ✓ PASS"
    else
        FAILED+=("$service_name")
        echo "    ✗ FAIL"
    fi
done

echo ""
echo "==> Summary"
echo "  Passed: ${#PASSED[@]}"
echo "  Failed: ${#FAILED[@]}"

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    echo "Failed services:"
    for name in "${FAILED[@]}"; do
        echo "  - $name"
    done
    exit 1
fi

echo ""
echo "All checks passed!"
