# rule-center match_kind CHECK Constraint Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the `rate_limit_rules.match_kind` CHECK constraint in both the `admin-services-kitex` and `rule-center` templates with the value domain (`exact`/`prefix`/`glob`/`regex`) already implemented by the usecase layer, so generated projects can actually insert non-`exact` rules, and add a regression test that pins this down.

**Architecture:** Pure template-content fix — no code-generation logic changes. Four CHECK-constraint occurrences (two per template: the applied goose migration and the sqlc schema snapshot) get their value list widened. A new gated Postgres integration test file is added to each template's `internal/repository/rulecenter/` output, following the exact skip-gating pattern already used by `internal_repository_user_repo_test_go.yaml`.

**Tech Stack:** Go, pgx/v5, goose migrations, sqlc, ncgo template rendering (Go `text/template`), Docker (local verification only, not part of the deliverable).

**Spec:** `docs/superpowers/specs/2026-09-07-rulecenter-match-kind-check-constraint-design.md`

## Global Constraints

- Only the 4 identified CHECK-constraint occurrences and the 2 new test files change. No proto/usecase/resolver logic changes.
- Test files must follow the existing gated-integration-test pattern (`pg_isready` + `POSTGRES_DSN` env var, `t.Skipf` when absent) so they never fail CI/dev environments without Postgres.
- Every template edit must still render and `go build`/`go vet` cleanly via `ncgo new ... --template-dir <template>` (this is what `.github/workflows/template-build-check.yml` checks for `admin-services-kitex`; `rule-center` isn't in that CI matrix but must be verified locally the same way).
- Do not touch `internal_base_middleware_ratelimit_go.yaml` or any Kitex hard-limit TODO — out of scope per the design doc.

---

### Task 1: Reproduce the bug against a real Postgres (verification only, no file changes)

**Files:** none (throwaway Docker container + raw SQL)

- [ ] **Step 1: Start a throwaway Postgres container**

```bash
docker run -d --name rulecenter-checkfix-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16-alpine
until docker exec rulecenter-checkfix-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
```

- [ ] **Step 2: Apply the current (unfixed) `rate_limit_rules` DDL, copied verbatim from `admin-services-kitex/kitex-template/migration_init.yaml`**

```bash
docker exec -i rulecenter-checkfix-pg psql -U postgres -c "
CREATE TABLE rate_limit_rules (
    id BIGSERIAL PRIMARY KEY,
    service TEXT NOT NULL,
    phase TEXT NOT NULL,
    method TEXT NOT NULL,
    match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'pattern')),
    path TEXT NOT NULL DEFAULT '*',
    path_pattern TEXT NOT NULL DEFAULT '*',
    app_key TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT true,
    key_by TEXT[] NOT NULL DEFAULT ARRAY['ip']::TEXT[],
    strategy TEXT NOT NULL DEFAULT 'fixed_window' CHECK (strategy IN ('fixed_window', 'sliding_window', 'token_bucket')),
    window_seconds INTEGER NOT NULL DEFAULT 60,
    max_requests INTEGER NOT NULL DEFAULT 100,
    requests_per_second DOUBLE PRECISION NOT NULL DEFAULT 0,
    burst INTEGER NOT NULL DEFAULT 0,
    client_ttl_seconds INTEGER NOT NULL DEFAULT 300,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"
```

- [ ] **Step 3: Confirm `prefix`/`glob`/`regex` are rejected (RED), `exact` is accepted**

```bash
for mk in exact prefix glob regex; do
  echo "-- match_kind=$mk --"
  docker exec -i rulecenter-checkfix-pg psql -U postgres -c \
    "INSERT INTO rate_limit_rules (service, phase, method, match_kind) VALUES ('svc','pre_auth','GET','$mk');"
done
```

Expected: `exact` → `INSERT 0 1`; `prefix`/`glob`/`regex` → `ERROR: new row for relation "rate_limit_rules" violates check constraint "rate_limit_rules_match_kind_check"`.

- [ ] **Step 4: Tear down (will re-provision fresh in Task 3)**

```bash
docker rm -f rulecenter-checkfix-pg
```

---

### Task 2: Fix the 4 CHECK-constraint occurrences

**Files:**
- Modify: `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml:103`
- Modify: `admin-services-kitex/kitex-template/migration_init.yaml:105`
- Modify: `rule-center/kitex-template/ratelimit_schema.yaml:14`
- Modify: `rule-center/kitex-template/migration_init.yaml:13`

- [ ] **Step 1: Edit `admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml`**

At line 103, change:
```sql
        match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'pattern')),
```
to:
```sql
        match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex')),
```

- [ ] **Step 2: Edit `admin-services-kitex/kitex-template/migration_init.yaml`**

At line 105, apply the identical change (same surrounding indentation, 8 spaces):
```sql
        match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex')),
```

- [ ] **Step 3: Edit `rule-center/kitex-template/ratelimit_schema.yaml`**

At line 14 (6-space indentation), change:
```sql
      match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'pattern')),
```
to:
```sql
      match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex')),
```

- [ ] **Step 4: Edit `rule-center/kitex-template/migration_init.yaml`**

At line 13 (6-space indentation), apply the identical change:
```sql
      match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex')),
```

- [ ] **Step 5: Grep-verify no stale occurrence remains**

```bash
grep -rn "match_kind IN ('exact', 'pattern')" admin-services-kitex/ rule-center/
```

Expected: no output.

---

### Task 3: Re-verify the fix against a real Postgres (GREEN)

**Files:** none (throwaway Docker container + raw SQL)

- [ ] **Step 1: Fresh Postgres container**

```bash
docker run -d --name rulecenter-checkfix-pg2 -e POSTGRES_PASSWORD=postgres -p 55433:5432 postgres:16-alpine
until docker exec rulecenter-checkfix-pg2 pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
```

- [ ] **Step 2: Apply the fixed DDL (constraint widened to 4 values), reusing the same table body as Task 1 Step 2 but with the corrected CHECK clause from Task 2**

```bash
docker exec -i rulecenter-checkfix-pg2 psql -U postgres -c "
CREATE TABLE rate_limit_rules (
    id BIGSERIAL PRIMARY KEY,
    service TEXT NOT NULL,
    phase TEXT NOT NULL,
    method TEXT NOT NULL,
    match_kind TEXT NOT NULL CHECK (match_kind IN ('exact', 'prefix', 'glob', 'regex')),
    path TEXT NOT NULL DEFAULT '*',
    path_pattern TEXT NOT NULL DEFAULT '*',
    app_key TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT true,
    key_by TEXT[] NOT NULL DEFAULT ARRAY['ip']::TEXT[],
    strategy TEXT NOT NULL DEFAULT 'fixed_window' CHECK (strategy IN ('fixed_window', 'sliding_window', 'token_bucket')),
    window_seconds INTEGER NOT NULL DEFAULT 60,
    max_requests INTEGER NOT NULL DEFAULT 100,
    requests_per_second DOUBLE PRECISION NOT NULL DEFAULT 0,
    burst INTEGER NOT NULL DEFAULT 0,
    client_ttl_seconds INTEGER NOT NULL DEFAULT 300,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"
```

- [ ] **Step 3: Confirm all four values now insert successfully**

```bash
for mk in exact prefix glob regex; do
  echo "-- match_kind=$mk --"
  docker exec -i rulecenter-checkfix-pg2 psql -U postgres -c \
    "INSERT INTO rate_limit_rules (service, phase, method, match_kind) VALUES ('svc','pre_auth','GET','$mk');"
done
```

Expected: all four → `INSERT 0 1`.

- [ ] **Step 4: Tear down**

```bash
docker rm -f rulecenter-checkfix-pg2
```

---

### Task 4: Add the gated integration test to `admin-services-kitex`

**Files:**
- Create: `admin-services-kitex/kitex-template/internal_repository_rulecenter_repo_test_go.yaml`

**Interfaces:**
- Consumes: nothing from other tasks — talks to Postgres directly via `pgxpool.Pool`, mirroring `internal_repository_user_repo_test_go.yaml`'s gating pattern. Does not depend on `gen.CreateRateLimitRuleParams` (avoids coupling to sqlc-generated struct shape; the bug is a schema-level constraint, so a direct SQL insert against the four required NOT-NULL-no-default columns — `service, phase, method, match_kind` — is the precise regression check).
- Produces: `TestRateLimitRuleMatchKindCheckConstraint` — a new gated test in package `rulecenterrepo`, table path `internal/repository/rulecenter/repo_test.go`.

- [ ] **Step 1: Create the test template file**

```yaml
# ncgo exported template — internal/repository/rulecenter/repo_test.go
path: internal/repository/rulecenter/repo_test.go
update_behavior:
    type: skip
loop_service: true
body: |
    package rulecenterrepo

    import (
    	"context"
    	"os"
    	"os/exec"
    	"testing"
    	"time"

    	"github.com/jackc/pgx/v5/pgxpool"
    )

    // TestRateLimitRuleMatchKindCheckConstraint exercises the rate_limit_rules
    // match_kind CHECK constraint against a real postgres, inserting one rule
    // per match_kind value the usecase layer actually supports (exact/prefix/
    // glob/regex). It is gated on `pg_isready` plus a reachable POSTGRES_DSN so
    // the happy-path seed/test/e2e runs stay hermetic. When the gate is absent
    // the test prints an explicit `skipped:` line instead of silently passing.
    func TestRateLimitRuleMatchKindCheckConstraint(t *testing.T) {{ "{" }}
    	if _, err := exec.LookPath("pg_isready"); err != nil {{ "{" }}
    		t.Skipf("skipped: pg_isready not installed (install postgres client to run)")
    	{{ "}" }}
    	dsn := os.Getenv("POSTGRES_DSN")
    	if dsn == "" {{ "{" }}
    		t.Skipf("skipped: POSTGRES_DSN not set")
    	{{ "}" }}
    	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    	defer cancel()
    	pool, err := pgxpool.New(ctx, dsn)
    	if err != nil {{ "{" }}
    		t.Fatalf("connect postgres: %v", err)
    	{{ "}" }}
    	defer pool.Close()
    	if err := pool.Ping(ctx); err != nil {{ "{" }}
    		t.Fatalf("ping postgres: %v", err)
    	{{ "}" }}

    	for _, matchKind := range []string{{ "{" }}"exact", "prefix", "glob", "regex"{{ "}" }} {{ "{" }}
    		matchKind := matchKind
    		t.Run(matchKind, func(t *testing.T) {{ "{" }}
    			var id int64
    			err := pool.QueryRow(ctx,
    				`INSERT INTO rate_limit_rules (service, phase, method, match_kind)
    				 VALUES ($1, $2, $3, $4) RETURNING id`,
    				"integration-test-svc", "pre_auth", "GET", matchKind,
    			).Scan(&id)
    			if err != nil {{ "{" }}
    				t.Fatalf("insert rule with match_kind=%q: %v", matchKind, err)
    			{{ "}" }}
    			if id == 0 {{ "{" }}
    				t.Fatalf("inserted rule with match_kind=%q has id 0", matchKind)
    			{{ "}" }}
    			if _, err := pool.Exec(ctx, `DELETE FROM rate_limit_rules WHERE id = $1`, id); err != nil {{ "{" }}
    				t.Fatalf("cleanup rule id=%d: %v", id, err)
    			{{ "}" }}
    		{{ "}" }})
    	{{ "}" }}
    {{ "}" }}
```

- [ ] **Step 2: Render `admin-services-kitex` and build/vet it, confirming the new test file compiles**

```bash
rm -rf /tmp/scratch-admin-services-kitex
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/scratch-admin-services-kitex --template-dir admin-services-kitex
cd /tmp/scratch-admin-services-kitex && go build ./... && go vet ./...
```

Expected: both commands exit 0. `internal/repository/rulecenter/repo_test.go` exists in the rendered output and contains `TestRateLimitRuleMatchKindCheckConstraint`.

- [ ] **Step 3: Run the rendered test against the Task 3 Postgres pattern (real end-to-end confirmation)**

```bash
docker run -d --name rulecenter-e2e-pg -e POSTGRES_PASSWORD=postgres -p 55434:5432 postgres:16-alpine
until docker exec rulecenter-e2e-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
docker exec -i rulecenter-e2e-pg psql -U postgres -c "$(grep -A30 'CREATE TABLE rate_limit_rules' admin-services-kitex/kitex-template/migration_init.yaml | sed -n '1,/^);/p' | sed 's/^    //')"
cd /tmp/scratch-admin-services-kitex
POSTGRES_DSN="postgres://postgres:postgres@localhost:55434/postgres?sslmode=disable" \
  PATH="$PATH:$(dirname "$(command -v docker)")" \
  go test ./internal/repository/rulecenter/... -run TestRateLimitRuleMatchKindCheckConstraint -v
docker rm -f rulecenter-e2e-pg
```

Note: if `pg_isready` is not installed on the machine running this step, the test will print `skipped: pg_isready not installed` and pass trivially — that's the intended hermetic behavior, not a failure. The Task 1/3 raw-SQL checks are what give unconditional proof the constraint itself is fixed; this step additionally proves the new Go test compiles and, when the gate is satisfiable, exercises the fix end-to-end.

- [ ] **Step 4: Commit**

```bash
git add admin-services-kitex/kitex-template/internal_db_schema_000001_admin_sql.yaml \
        admin-services-kitex/kitex-template/migration_init.yaml \
        admin-services-kitex/kitex-template/internal_repository_rulecenter_repo_test_go.yaml
git commit -m "fix(admin-services-kitex): widen match_kind CHECK to exact/prefix/glob/regex"
```

---

### Task 5: Add the gated integration test to `rule-center`

**Files:**
- Create: `rule-center/kitex-template/internal_repository_rulecenter_repo_test_go.yaml`

**Interfaces:**
- Consumes: nothing from other tasks (same rationale as Task 4).
- Produces: identical `TestRateLimitRuleMatchKindCheckConstraint` in package `rulecenterrepo`, path `internal/repository/rulecenter/repo_test.go`, for the `rule-center` template.

- [ ] **Step 1: Create the test template file with the same body as Task 4 Step 1**

```yaml
# Kitex custom template — internal/repository/rulecenter/repo_test.go
path: internal/repository/rulecenter/repo_test.go
update_behavior:
  type: skip
body: |-
  package rulecenterrepo

  import (
  	"context"
  	"os"
  	"os/exec"
  	"testing"
  	"time"

  	"github.com/jackc/pgx/v5/pgxpool"
  )

  // TestRateLimitRuleMatchKindCheckConstraint exercises the rate_limit_rules
  // match_kind CHECK constraint against a real postgres, inserting one rule
  // per match_kind value the usecase layer actually supports (exact/prefix/
  // glob/regex). It is gated on `pg_isready` plus a reachable POSTGRES_DSN so
  // the happy-path seed/test/e2e runs stay hermetic. When the gate is absent
  // the test prints an explicit `skipped:` line instead of silently passing.
  func TestRateLimitRuleMatchKindCheckConstraint(t *testing.T) {
  	if _, err := exec.LookPath("pg_isready"); err != nil {
  		t.Skipf("skipped: pg_isready not installed (install postgres client to run)")
  	}
  	dsn := os.Getenv("POSTGRES_DSN")
  	if dsn == "" {
  		t.Skipf("skipped: POSTGRES_DSN not set")
  	}
  	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
  	defer cancel()
  	pool, err := pgxpool.New(ctx, dsn)
  	if err != nil {
  		t.Fatalf("connect postgres: %v", err)
  	}
  	defer pool.Close()
  	if err := pool.Ping(ctx); err != nil {
  		t.Fatalf("ping postgres: %v", err)
  	}

  	for _, matchKind := range []string{"exact", "prefix", "glob", "regex"} {
  		matchKind := matchKind
  		t.Run(matchKind, func(t *testing.T) {
  			var id int64
  			err := pool.QueryRow(ctx,
  				`INSERT INTO rate_limit_rules (service, phase, method, match_kind)
  				 VALUES ($1, $2, $3, $4) RETURNING id`,
  				"integration-test-svc", "pre_auth", "GET", matchKind,
  			).Scan(&id)
  			if err != nil {
  				t.Fatalf("insert rule with match_kind=%q: %v", matchKind, err)
  			}
  			if id == 0 {
  				t.Fatalf("inserted rule with match_kind=%q has id 0", matchKind)
  			}
  			if _, err := pool.Exec(ctx, `DELETE FROM rate_limit_rules WHERE id = $1`, id); err != nil {
  				t.Fatalf("cleanup rule id=%d: %v", id, err)
  			}
  		})
  	}
  }
```

Note: `rule-center/kitex-template/*.yaml` files use raw Go source directly (no `{{ "{" }}` brace-escaping) — confirmed by the existing sibling file `rule-center/kitex-template/ratelimit_shared_resolver_test.yaml`, which is not template-escaped. Use plain braces here to match that convention.

- [ ] **Step 2: Render `rule-center` and build/vet it**

```bash
rm -rf /tmp/scratch-rule-center
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --dir /tmp/scratch-rule-center --template-dir rule-center
cd /tmp/scratch-rule-center && go build ./... && go vet ./...
```

Expected: both commands exit 0.

- [ ] **Step 3: Commit**

```bash
git add rule-center/kitex-template/ratelimit_schema.yaml \
        rule-center/kitex-template/migration_init.yaml \
        rule-center/kitex-template/internal_repository_rulecenter_repo_test_go.yaml
git commit -m "fix(rule-center): widen match_kind CHECK to exact/prefix/glob/regex"
```

---

### Task 6: Final sweep

- [ ] **Step 1: Confirm no other file in the repo still carries the stale constraint**

```bash
grep -rn "match_kind IN ('exact', 'pattern')" . --include="*.yaml" --include="*.sql" \
  | grep -v '/.worktree/' | grep -v '/.claude/worktrees/'
```

Expected: no output.

- [ ] **Step 2: Run repo-wide quality gate (per gf-workflow Phase 2 requirement)**

Handled by the orchestrator's `gf-quality` step after this plan is approved — not a task step here.
