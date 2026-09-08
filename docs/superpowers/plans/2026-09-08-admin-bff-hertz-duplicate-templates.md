# admin-bff-hertz Duplicate Template Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the 6 duplicate `path:` template-file groups in `admin-bff-hertz/hertz-template`, port forward the two genuine feature deltas (JWT/gRPC config, refined auth error codes) into the maintained templates, and add a CI guard so the duplication can't silently reappear.

**Architecture:** Each of the 6 groups is a pair of `.yaml` template files declaring the same output `path:`. For 2 groups (`conf.go`, `response.go`) the stale "ncgo exported" file carries real content the maintained file lacks — those fields/cases are hand-ported into the maintained file, then the exported file is deleted. For the other 4 groups the exported file adds nothing (or is a functional regression) — it is deleted outright. A new shell script (`scripts/check-duplicate-template-paths.sh`) scans a given template directory for duplicate `path:` declarations and is wired into CI, scoped to `admin-bff-hertz/hertz-template` only (the other 3 template directories still have unresolved duplicates and are out of scope — tracked as follow-up Issues off #43).

**Tech Stack:** YAML template files (ncgo template format), Bash, GitHub Actions, Go (generated code target, validated via `ncgo new scratch` + `go build`/`go vet`).

**Spec:** `docs/superpowers/specs/2026-09-08-admin-bff-hertz-duplicate-templates-design.md`

## Global Constraints

- Scope is `admin-bff-hertz/hertz-template` only — do not touch admin-services-kitex, rbac-kitex, or rule-center in this plan.
- Never reintroduce hardcoded values (e.g. a literal service name) into a maintained template — all such values must stay as Go template actions (`{{...}}`).
- The new CI duplicate-path check must only be pointed at `admin-bff-hertz/hertz-template` for now (per design doc §"新增 CI 检查").
- Every deleted file must be a `git rm`, not a manual filesystem delete, so the removal shows up in the diff.

---

### Task 1: Merge conf.go JWT/gRPC config forward, delete the stale exported file

**Files:**
- Modify: `admin-bff-hertz/hertz-template/conf_go.yaml`
- Delete: `admin-bff-hertz/hertz-template/internal_base_conf_conf_go.yaml`
- Test: manual render via `ncgo new scratch` (Task 6 covers the full end-to-end render+build; this task's own check is a template syntax sanity check described in Step 2 below)

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: `conf_go.yaml`'s rendered `Config` struct now has `JWT JWTConfig` and `GRPC GRPCConfig` fields, plus the `JWTConfig`, `GRPCConfig`, `ClientConfig`, `RetryConfig` type definitions — Task 6's end-to-end build depends on these compiling

- [ ] **Step 1: Add the two new fields to the `Config` struct**

In `admin-bff-hertz/hertz-template/conf_go.yaml`, find:

```
      Auth AuthConfig `yaml:"auth"`
      Logging LoggingConfig `yaml:"logging"`
```

Replace with:

```
      Auth AuthConfig `yaml:"auth"`
      JWT JWTConfig `yaml:"jwt"`
      GRPC GRPCConfig `yaml:"grpc"`
      Logging LoggingConfig `yaml:"logging"`
```

- [ ] **Step 2: Add the new type definitions**

In the same file, find:

```
  func RegisterConfigCenterLoader(provider string, loader ConfigCenterLoader) {
```

Replace with:

```
  // JWT and gRPC client configuration for admin-bff
  type JWTConfig struct {
      Secret                 string `yaml:"secret"`
      AccessTokenTTLSeconds  int    `yaml:"access_token_ttl_seconds"`
      RefreshTokenTTLSeconds int    `yaml:"refresh_token_ttl_seconds"`
  }

  type GRPCConfig struct {
      Authority ClientConfig `yaml:"authority"`
  }

  type ClientConfig struct {
      ServiceName                string      `yaml:"service_name"`
      HostPorts                  []string    `yaml:"host_ports"`
      RPCTimeoutSeconds          int         `yaml:"rpc_timeout_seconds"`
      ConnectTimeoutMilliseconds int         `yaml:"connect_timeout_milliseconds"`
      EnableMetaInfo             bool        `yaml:"enable_metainfo"`
      Retry                      RetryConfig `yaml:"retry"`
  }

  type RetryConfig struct {
      Enabled bool `yaml:"enabled"`
  }

  func RegisterConfigCenterLoader(provider string, loader ConfigCenterLoader) {
```

- [ ] **Step 3: Verify the YAML still parses and the body is still valid Go**

Run:
```bash
cd admin-bff-hertz/hertz-template
python3 -c "import yaml; d = yaml.safe_load(open('conf_go.yaml')); open('/tmp/conf_check.go','w').write(d['body'])"
gofmt -l /tmp/conf_check.go
```
Expected: `gofmt -l` prints nothing (file is syntactically valid and already formatted). If it prints the path, re-check indentation from Step 1/2 against `gofmt`'s complaint and fix.

- [ ] **Step 4: Delete the stale exported file**

```bash
git rm admin-bff-hertz/hertz-template/internal_base_conf_conf_go.yaml
```

- [ ] **Step 5: Commit**

```bash
git add admin-bff-hertz/hertz-template/conf_go.yaml
git commit -m "fix(admin-bff-hertz): merge JWT/gRPC config into conf.go template, drop stale export"
```

---

### Task 2: Merge response.go auth error-code refinements forward, delete the stale exported file

**Files:**
- Modify: `admin-bff-hertz/hertz-template/response_go.yaml`
- Delete: `admin-bff-hertz/hertz-template/internal_pkg_response_response_go.yaml`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: `response_go.yaml`'s rendered package now maps `CodeSignatureMissing/Expired/Invalid`, `CodeAppKeyInvalid`, `CodeTokenMissing/Invalid/Expired`, `CodeClaimsInvalid`, `CodeSessionInvalid` to their specific `frameworkerror` codes (previously all aliased to `frameworkerror.CodeAuthFailed`), with matching `StatusFromCode`/`MsgFromCode` branches — Task 6's build depends on `frameworkerror.CodeSignatureMissing` etc. existing (confirmed present in `go-tools/go-framework/error@v0.2.x`)

- [ ] **Step 1: Replace the generic auth error-code aliases with specific ones**

In `admin-bff-hertz/hertz-template/response_go.yaml`, find:

```
      CodeUnauthorized          = frameworkerror.CodeAuthFailed
      CodeSignatureMissing      = frameworkerror.CodeAuthFailed
      CodeSignatureExpired      = frameworkerror.CodeAuthFailed
      CodeSignatureInvalid      = frameworkerror.CodeAuthFailed
      CodeTokenMissing          = frameworkerror.CodeAuthFailed
      CodeTokenInvalid          = frameworkerror.CodeAuthFailed
      CodeTokenExpired          = frameworkerror.CodeAuthFailed
      CodeClaimsInvalid         = frameworkerror.CodeAuthFailed
      CodeAppKeyInvalid         = frameworkerror.CodeAuthFailed
      CodeSessionInvalid        = frameworkerror.CodeAuthFailed
```

Replace with:

```
      CodeUnauthorized          = frameworkerror.CodeAuthFailed

      // Signature errors
      CodeSignatureMissing      = frameworkerror.CodeSignatureMissing
      CodeSignatureExpired      = frameworkerror.CodeSignatureExpired
      CodeSignatureInvalid      = frameworkerror.CodeSignatureInvalid
      CodeAppKeyInvalid         = frameworkerror.CodeAppKeyInvalid

      // Token / JWT errors
      CodeTokenMissing          = frameworkerror.CodeTokenMissing
      CodeTokenInvalid          = frameworkerror.CodeTokenInvalid
      CodeTokenExpired          = frameworkerror.CodeTokenExpired
      CodeClaimsInvalid         = frameworkerror.CodeTokenInvalid
      CodeSessionInvalid        = frameworkerror.CodeTokenInvalid
```

- [ ] **Step 2: Add HTTP status mapping for the new codes**

In the same file, find:

```
      case CodeIdempotencyKeyMissing:
          return consts.StatusBadRequest
      case frameworkerror.CodeAuthFailed:
          return consts.StatusForbidden
```

Replace with:

```
      case CodeIdempotencyKeyMissing:
          return consts.StatusBadRequest

      // Signature errors → HTTP status from framework
      case CodeSignatureMissing, CodeSignatureExpired:
          return consts.StatusUnauthorized
      case CodeSignatureInvalid, CodeAppKeyInvalid:
          return consts.StatusForbidden

      // Token / JWT errors → 401
      case CodeTokenMissing, CodeTokenInvalid, CodeTokenExpired,
          CodeClaimsInvalid, CodeSessionInvalid:
          return consts.StatusUnauthorized

      case frameworkerror.CodeAuthFailed:
          return consts.StatusForbidden
```

- [ ] **Step 3: Add message mapping for the new codes**

In the same file, find:

```
      case CodeAuthFailed:
          return "auth_failed"
      case CodeConfigInvalid:
          return "config_invalid"
```

Replace with:

```
      case CodeAuthFailed:
          return "auth_failed"
      case CodeSignatureMissing:
          return "signature_missing"
      case CodeSignatureExpired:
          return "signature_expired"
      case CodeSignatureInvalid:
          return "signature_invalid"
      case CodeAppKeyInvalid:
          return "app_key_invalid"
      case CodeTokenMissing:
          return "token_missing"
      case CodeTokenInvalid:
          return "token_invalid"
      case CodeTokenExpired:
          return "token_expired"
      case CodeConfigInvalid:
          return "config_invalid"
```

- [ ] **Step 4: Verify the YAML still parses and the body is still valid Go**

```bash
cd admin-bff-hertz/hertz-template
python3 -c "import yaml; d = yaml.safe_load(open('response_go.yaml')); open('/tmp/response_check.go','w').write(d['body'])"
gofmt -l /tmp/response_check.go
```
Expected: no output.

- [ ] **Step 5: Delete the stale exported file**

```bash
git rm admin-bff-hertz/hertz-template/internal_pkg_response_response_go.yaml
```

- [ ] **Step 6: Commit**

```bash
git add admin-bff-hertz/hertz-template/response_go.yaml
git commit -m "fix(admin-bff-hertz): merge refined auth error codes into response.go template, drop stale export"
```

---

### Task 3: Delete the remaining 4 redundant exported files

**Files:**
- Delete: `admin-bff-hertz/hertz-template/internal_base_data_data_go.yaml`
- Delete: `admin-bff-hertz/hertz-template/internal_pkg_errcode_errcode_go.yaml`
- Delete: `admin-bff-hertz/hertz-template/internal_pkg_middleware_middleware_go.yaml`
- Delete: `admin-bff-hertz/hertz-template/Makefile.yaml`

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: nothing consumed by later tasks — these 4 groups have no unique content (verified in the design doc's per-group diff), so deleting them is a pure removal

- [ ] **Step 1: Confirm no unique content would be lost (re-verify before deleting)**

```bash
cd admin-bff-hertz/hertz-template
python3 << 'EOF'
import yaml, subprocess
pairs = [
    ("data_go.yaml", "internal_base_data_data_go.yaml"),
    ("errcode_go.yaml", "internal_pkg_errcode_errcode_go.yaml"),
    ("middleware_go.yaml", "internal_pkg_middleware_middleware_go.yaml"),
    ("makefile_yaml.yaml", "Makefile.yaml"),
]
for keep, drop in pairs:
    dk = yaml.safe_load(open(keep))
    dd = yaml.safe_load(open(drop))
    print(f"--- {keep} (keep) vs {drop} (drop) ---")
    open('/tmp/keep.txt','w').write(dk.get('body',''))
    open('/tmp/drop.txt','w').write(dd.get('body',''))
    subprocess.run(["diff","-u","/tmp/keep.txt","/tmp/drop.txt"])
EOF
```
Expected: only the escaped-brace / already-known cosmetic diffs from the design doc (no new unexplained content in the "drop" files). If any pair now shows a real content difference beyond what's documented, STOP and re-run Task 1/2-style merge for that pair instead of deleting.

- [ ] **Step 2: Delete the 4 files**

```bash
git rm admin-bff-hertz/hertz-template/internal_base_data_data_go.yaml \
       admin-bff-hertz/hertz-template/internal_pkg_errcode_errcode_go.yaml \
       admin-bff-hertz/hertz-template/internal_pkg_middleware_middleware_go.yaml \
       admin-bff-hertz/hertz-template/Makefile.yaml
```

- [ ] **Step 3: Verify no duplicate `path:` declarations remain in the directory**

```bash
grep -h "^path:" admin-bff-hertz/hertz-template/*.yaml | sort | uniq -d
```
Expected: no output (empty — no duplicates left).

- [ ] **Step 4: Commit**

```bash
git commit -m "fix(admin-bff-hertz): remove remaining redundant ncgo-exported template files"
```

---

### Task 4: Add the duplicate-path-check script with fixture tests

**Files:**
- Create: `scripts/check-duplicate-template-paths.sh`
- Create: `scripts/testdata/dup-check-fixture/has-duplicate/a.yaml`
- Create: `scripts/testdata/dup-check-fixture/has-duplicate/b.yaml`
- Create: `scripts/testdata/dup-check-fixture/clean/a.yaml`
- Create: `scripts/testdata/dup-check-fixture/clean/b.yaml`
- Test: `scripts/check-duplicate-template-paths.sh` invoked directly against the two fixtures (this is a shell script, not a Go test — the "test" is a manual invocation with a known expected exit code, run in Step 2/4 below)

**Interfaces:**
- Consumes: nothing from other tasks
- Produces: `scripts/check-duplicate-template-paths.sh <dir> [<dir> ...]` — exits 0 if no directory has duplicate `path:` declarations across its `.yaml` files, exits 1 (with details on stderr) otherwise. Task 5 wires this into CI.

- [ ] **Step 1: Write the fixture files (the "failing test" — a directory that must be rejected)**

`scripts/testdata/dup-check-fixture/has-duplicate/a.yaml`:
```yaml
path: foo.go
body: "package foo"
```

`scripts/testdata/dup-check-fixture/has-duplicate/b.yaml`:
```yaml
path: foo.go
body: "package foo // duplicate"
```

`scripts/testdata/dup-check-fixture/clean/a.yaml`:
```yaml
path: foo.go
body: "package foo"
```

`scripts/testdata/dup-check-fixture/clean/b.yaml`:
```yaml
path: bar.go
body: "package foo"
```

- [ ] **Step 2: Run the check against the fixtures to confirm the script doesn't exist yet**

```bash
bash scripts/check-duplicate-template-paths.sh scripts/testdata/dup-check-fixture/has-duplicate
```
Expected: FAIL with "No such file or directory" (script not written yet).

- [ ] **Step 3: Write the script**

`scripts/check-duplicate-template-paths.sh`:
```bash
#!/usr/bin/env bash
# Fails if any two .yaml files directly under a given directory declare the
# same `path:` value. Usage:
#   scripts/check-duplicate-template-paths.sh <template-dir> [<template-dir> ...]
set -euo pipefail

status=0

for dir in "$@"; do
  if [ ! -d "$dir" ]; then
    echo "error: directory not found: $dir" >&2
    exit 1
  fi

  pairs=$(grep -H "^path:" "$dir"/*.yaml 2>/dev/null | sed -E 's/^([^:]+):path:[[:space:]]*/\1\t/' || true)
  if [ -z "$pairs" ]; then
    continue
  fi

  dupes=$(printf '%s\n' "$pairs" | awk -F'\t' '{print $2}' | sort | uniq -d)
  if [ -n "$dupes" ]; then
    echo "duplicate path: declarations found in $dir:" >&2
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      echo "  path: $p" >&2
      printf '%s\n' "$pairs" | awk -F'\t' -v p="$p" '$2==p {print "    - " $1}' >&2
    done <<< "$dupes"
    status=1
  fi
done

exit $status
```

```bash
chmod +x scripts/check-duplicate-template-paths.sh
```

- [ ] **Step 4: Run the check against both fixtures to confirm it now passes/fails as expected**

```bash
bash scripts/check-duplicate-template-paths.sh scripts/testdata/dup-check-fixture/has-duplicate; echo "exit=$?"
bash scripts/check-duplicate-template-paths.sh scripts/testdata/dup-check-fixture/clean; echo "exit=$?"
```
Expected: first invocation prints `duplicate path: declarations found in scripts/testdata/dup-check-fixture/has-duplicate:` with both `a.yaml` and `b.yaml` listed under `path: foo.go`, and `exit=1`. Second invocation prints nothing and `exit=0`.

- [ ] **Step 5: Run the check against the now-cleaned admin-bff-hertz directory**

```bash
bash scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template; echo "exit=$?"
```
Expected: no output, `exit=0` (Tasks 1-3 already removed all duplicates there).

- [ ] **Step 6: Commit**

```bash
git add scripts/check-duplicate-template-paths.sh scripts/testdata/dup-check-fixture
git commit -m "feat(ci): add duplicate template path checker script with fixture tests"
```

---

### Task 5: Wire the duplicate-path check into CI and add admin-bff-hertz to the build matrix

**Files:**
- Modify: `.github/workflows/template-build-check.yml`

**Interfaces:**
- Consumes: `scripts/check-duplicate-template-paths.sh` from Task 4
- Produces: nothing consumed by later tasks (CI-only change)

- [ ] **Step 1: Read the current file to confirm it still matches what Task 5 assumes**

```bash
cat .github/workflows/template-build-check.yml
```
Confirm it still has the `paths:` trigger list `rbac-kitex/**` / `admin-services-kitex/**` and the `build-check` job with `matrix.template: [rbac-kitex, admin-services-kitex]`. If it has drifted, adapt the edits below to the current structure instead of applying them blindly.

- [ ] **Step 2: Rewrite the workflow file**

Replace the full contents of `.github/workflows/template-build-check.yml` with:

```yaml
name: Template Build Check

on:
  pull_request:
    paths:
      - 'rbac-kitex/**'
      - 'admin-services-kitex/**'
      - 'admin-bff-hertz/**'

jobs:
  duplicate-path-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check for duplicate path declarations
        run: scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template

  build-check:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - name: rbac-kitex
            kind: kitex
            dir: rbac-kitex/kitex-template
          - name: admin-services-kitex
            kind: kitex
            dir: admin-services-kitex/kitex-template
          - name: admin-bff-hertz
            kind: hertz
            dir: admin-bff-hertz/hertz-template
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Install ncgo
        run: go install github.com/byx-darwin/ncgo@latest

      - name: Render ${{ matrix.name }}
        run: |
          ncgo new scratch \
            --module github.com/acme/scratch \
            --kind ${{ matrix.kind }} \
            --dir /tmp/scratch-${{ matrix.name }} \
            --template-dir ${{ matrix.dir }}

      - name: Build
        working-directory: /tmp/scratch-${{ matrix.name }}
        run: go build ./...

      - name: Vet
        working-directory: /tmp/scratch-${{ matrix.name }}
        run: go vet ./...
```

- [ ] **Step 3: Validate the YAML is well-formed**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/template-build-check.yml'))" && echo "valid YAML"
```
Expected: `valid YAML` printed, no exception.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/template-build-check.yml
git commit -m "ci(templates): check admin-bff-hertz for duplicate paths, add it to the build matrix"
```

---

### Task 6: End-to-end validation

**Files:**
- None (validation only)

**Interfaces:**
- Consumes: the merged/cleaned templates from Tasks 1-3, the script from Task 4
- Produces: confirmation that Issue #52's acceptance criteria are all met

- [ ] **Step 1: Render admin-bff-hertz into a scratch project**

```bash
rm -rf /tmp/scratch-admin-bff-hertz
ncgo new scratch \
  --module github.com/acme/scratch \
  --kind hertz \
  --dir /tmp/scratch-admin-bff-hertz \
  --template-dir admin-bff-hertz/hertz-template
```
Expected: command exits 0, `/tmp/scratch-admin-bff-hertz` is populated.

- [ ] **Step 2: Build and vet the rendered project**

```bash
cd /tmp/scratch-admin-bff-hertz
go build ./...
go vet ./...
```
Expected: both exit 0 with no output.

- [ ] **Step 3: Spot-check the merged content made it into the rendered output**

```bash
grep -n "JWTConfig\|GRPCConfig" /tmp/scratch-admin-bff-hertz/internal/base/conf/conf.go
grep -n "CodeSignatureMissing\|CodeTokenMissing" /tmp/scratch-admin-bff-hertz/internal/pkg/response/response.go
grep -n 'Name: "adminbffservice"' /tmp/scratch-admin-bff-hertz/internal/base/conf/conf.go
```
Expected: first two greps print matching lines (merged content present). Third grep prints nothing (the old hardcoded value is gone — `Registry.Name` still uses the templated `{{ToLower .ServiceName}}` path, rendered here as the scratch project's own lowercased service name, not the stale literal).

- [ ] **Step 4: Confirm no duplicate `path:` declarations remain**

```bash
bash scripts/check-duplicate-template-paths.sh admin-bff-hertz/hertz-template; echo "exit=$?"
```
Expected: no output, `exit=0`.

- [ ] **Step 5: Clean up the scratch directory**

```bash
rm -rf /tmp/scratch-admin-bff-hertz /tmp/conf_check.go /tmp/response_check.go
```

No commit for this task — it's pure verification. If anything in Steps 1-4 fails, go back to the relevant earlier task and fix it there (with its own commit), then re-run this task.
