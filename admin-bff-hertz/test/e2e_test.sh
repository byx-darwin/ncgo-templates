#!/bin/bash
set -e

echo "=== E2E Test: admin-bff-hertz ==="

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "Generating project from template..."
ncgo new test-bff --module github.com/test/bff --kind hertz --template-dir /Users/xs/Documents/workspce/github.com/byx-darwin/ncgo-templates/.worktree/feat-12-admin-bff-hertz/admin-bff-hertz

cd test-bff

echo "Building..."
go build ./...

echo "Running tests..."
go test ./...

cd /
rm -rf "$TMPDIR"

echo "=== E2E Test PASSED ==="
