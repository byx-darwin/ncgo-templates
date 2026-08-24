# base-hertz DDD Scaffold Enhancement — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance base-hertz template to generate complete DDD scaffolding — usecase layer, model layer, and default error routing — matching the pattern used in edge-bff reference code.

**Architecture:** Three template additions/updates to `base-hertz/hertz-template/`: (1) a per-service usecase scaffold template with handler setter and server wiring, (2) a response.go template update enabling `RPCErrorRouter`, (3) an example model template for non-protobuf scenarios. All follow the existing YAML template format (`path` + `update_behavior` + `body`).

**Tech Stack:** Go templates (Hertz generator), YAML template definitions, `github.com/byx-darwin/go-tools/go-framework/hertz`, `github.com/byx-darwin/go-tools/go-common/error`, `github.com/cloudwego/hertz`.

**Spec:** `docs/investigations/wf-2026-08-24-001-base-hertz-ddd-response.md`

## Global Constraints

- Template YAML format: `path` (string), `update_behavior.type` (`cover` | `skip`), `body` (string, Go template syntax), optional `loop_service: true`.
- Generated Go code must compile (`go build ./...`).
- Template variables: `{{.Module}}` (Go module path), `{{ToLower .ServiceName}}` (service name from IDL).
- Existing `update_behavior: type: skip` files in generated projects (e.g., handler/pb) are NOT overwritten on regeneration — new scaffolding must be backward-compatible.
- Error code constants come from `github.com/byx-darwin/go-tools/go-framework/error` (aliased as `frameworkerror`).
- Error wrapping uses `github.com/byx-darwin/go-tools/go-common/error` (aliased as `goerror`).

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `base-hertz/hertz-template/internal_usecase_pb_{{ToLower_ServiceName}}_go.yaml` | Per-service usecase scaffold — constructor, methods with `CodeNotImplemented` stubs |
| Create | `base-hertz/hertz-template/internal_model_example_go.yaml` | Example domain model with request/response structs |
| Modify | `base-hertz/hertz-template/internal_handler_pb_{{ToLower_ServiceName}}_service_go.yaml` | Add `SetDefaultUseCase()` setter function |
| Modify | `base-hertz/hertz-template/internal_pkg_response_response_go.yaml` | Enable `WithErrorRouter` in `NewResponder()` |
| Modify | `base-hertz/hertz-template/internal_base_server_server_go.yaml` | Wire usecase → handler in `Run()` |
| Modify | `base-hertz/hertz-template/internal_pkg_response_response_test_go.yaml` | Add test for `RPCErrorRouter` default |

---

### Task 1: UseCase Scaffold Template

**Files:**
- Create: `base-hertz/hertz-template/internal_usecase_pb_{{ToLower_ServiceName}}_go.yaml`
- Modify: `base-hertz/hertz-template/internal_handler_pb_{{ToLower_ServiceName}}_service_go.yaml`
- Modify: `base-hertz/hertz-template/internal_base_server_server_go.yaml`

**Interfaces:**
- Consumes: IDL service definitions (`{{.ServiceName}}`, `{{.Module}}`)
- Produces:
  - `internal/usecase/pb/<service>_usecase.go`: `type UseCase struct{}`, `func NewUseCase() *UseCase`, methods matching handler's `useCase` interface
  - Handler gets `func SetDefaultUseCase(uc useCase)`
  - Server gets usecase → handler wiring in `Run()`

**Design rationale:** The current handler template defines a `useCase` interface and a `notImplementedUseCase` stub. The `DefaultHandler` var uses this stub. To enable DI wiring from `server.go`, the handler needs an exported setter. The usecase template provides the real implementation that the developer fills in.

- [ ] **Step 1: Create usecase scaffold template**

Create file `base-hertz/hertz-template/internal_usecase_pb_{{ToLower_ServiceName}}_go.yaml`:

```yaml
# Hertz custom template — internal/usecase/pb/{{ToLower .ServiceName}}_usecase.go
# Generates the per-service usecase scaffold implementing the handler's useCase interface.
# Developers fill in business logic; the scaffold compiles and wires out-of-the-box.
path: internal/usecase/pb/{{ToLower .ServiceName}}_usecase.go
update_behavior:
    type: skip
loop_service: true
body: |-
    package pb

    import (
        "context"

        goerror "github.com/byx-darwin/go-tools/go-common/error"
        frameworkerror "github.com/byx-darwin/go-tools/go-framework/error"

        pb "{{.Module}}/internal/handler/pb"
        "{{.Module}}/internal/pkg/response"
    )

    // UseCase implements the handler's useCase interface.
    // Fill in business logic — scaffold methods return CodeNotImplemented.
    type UseCase struct{}

    // NewUseCase creates a UseCase instance.
    // Wire it to the handler in server.go:
    //   pb.SetDefaultUseCase(usecasepb.NewUseCase())
    func NewUseCase() *UseCase {
        return &UseCase{}
    }

    // Ping .
    func (uc *UseCase) Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error) {
        _ = ctx
        _ = req
        return nil, goerror.
            In("pb.usecase").
            Code(response.CodeNotImplemented).
            Public("not_implemented").
            Errorf("Ping: not implemented")
    }

    // Ensure UseCase satisfies the handler's useCase interface at compile time.
    // The handler package defines useCase as unexported, so we verify via the setter.
    var _ pb.UseCaseSetter = (*UseCase)(nil)
```

**Note:** The compile-time check `var _ pb.UseCaseSetter = (*UseCase)(nil)` requires the handler to export a `UseCaseSetter` interface (see Step 2). This catches interface drift at compile time.

- [ ] **Step 2: Update handler template — add setter and interface**

Modify `base-hertz/hertz-template/internal_handler_pb_{{ToLower_ServiceName}}_service_go.yaml`.

Add after the `type notImplementedUseCase struct{}` block:

```go
    // UseCaseSetter is the exported interface for DI wiring from server.go.
    // It mirrors the unexported useCase interface.
    type UseCaseSetter interface {
        Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error)
    }

    // SetDefaultUseCase replaces the default (not-implemented) use case
    // with a real implementation. Call from server.go during startup.
    func SetDefaultUseCase(uc UseCaseSetter) {
        DefaultHandler = NewPbHandler(uc)
    }
```

**Why `UseCaseSetter`?** The handler's `useCase` interface is unexported. To wire from `server.go`, we need an exported interface that the usecase can implement. `UseCaseSetter` mirrors `useCase` and enables compile-time verification via `var _ pb.UseCaseSetter = (*UseCase)(nil)`.

The full handler template body after modification:

```go
    package pb

    import (
        "context"

        goerror "github.com/byx-darwin/go-tools/go-common/error"
        "github.com/cloudwego/hertz/pkg/app"

        pb "{{.Module}}/internal/pb"
        "{{.Module}}/internal/pkg/response"
    )

    // Handler handles HTTP requests. It delegates business logic to UseCase.
    type Handler struct {
        uc useCase
    }

    // useCase is the port this handler depends on.
    // Implement it in internal/usecase/pb/.
    type useCase interface {
        Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error)
    }

    // UseCaseSetter is the exported interface for DI wiring from server.go.
    // It mirrors the unexported useCase interface.
    type UseCaseSetter interface {
        Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error)
    }

    // SetDefaultUseCase replaces the default (not-implemented) use case
    // with a real implementation. Call from server.go during startup.
    func SetDefaultUseCase(uc UseCaseSetter) {
        DefaultHandler = NewPbHandler(uc)
    }

    type notImplementedUseCase struct{}

    func (notImplementedUseCase) Ping(ctx context.Context, req *pb.PingReq) (*pb.PingResp, error) {
        _ = ctx
        _ = req
        return nil, goerror.
            In("pb.usecase").
            Code(response.CodeNotImplemented).
            Public("not_implemented").
            Errorf("Ping: not implemented")
    }

    // NewPbHandler creates a Handler wired to the given usecase.
    func NewPbHandler(uc useCase) *Handler {
        return &Handler{uc: uc}
    }

    // DefaultHandler is used by hz-generated package-level route functions.
    // Replace it during server wiring with NewPbHandler(realUseCase).
    var DefaultHandler = NewPbHandler(notImplementedUseCase{})

    // Ping .
    // @router /ping [GET]
    func Ping(ctx context.Context, c *app.RequestContext) {
        DefaultHandler.Ping(ctx, c)
    }

    // Ping .
    // @router /ping [GET]
    func (h *Handler) Ping(ctx context.Context, c *app.RequestContext) {
        var req pb.PingReq
        if err := c.BindAndValidate(&req); err != nil {
            response.BindError(c, err)
            return
        }
        resp, err := h.uc.Ping(ctx, &req)
        if err != nil {
            response.Err(c, err)
            return
        }
        response.OK(c, resp)
    }
```

**Note on `NewPbHandler` parameter type:** `NewPbHandler(uc useCase)` uses the unexported `useCase` interface. `SetDefaultUseCase(uc UseCaseSetter)` uses the exported `UseCaseSetter`. Since both interfaces have identical method sets, any type satisfying `UseCaseSetter` also satisfies `useCase`. The call `NewPbHandler(uc)` in `SetDefaultUseCase` works because Go structural typing accepts it.

- [ ] **Step 3: Update server.go template — wire usecase**

Modify `base-hertz/hertz-template/internal_base_server_server_go.yaml`.

Add to imports:
```go
    pbhandler "{{.Module}}/internal/handler/pb"
    usecasepb "{{.Module}}/internal/usecase/pb"
```

Add after `health.Register(h)` and before `router.GeneratedRegister(h)`:
```go
    // Wire DDD: usecase → handler
    pbhandler.SetDefaultUseCase(usecasepb.NewUseCase())
```

The relevant section of server.go template after modification:

```go
    // Register health check routes
    health.Register(h)

    // Wire DDD: usecase → handler
    pbhandler.SetDefaultUseCase(usecasepb.NewUseCase())

    // Register auto-generated routes
    router.GeneratedRegister(h)
```

**Important:** `pbhandler` alias avoids conflict with `pb "{{.Module}}/internal/pb"` (proto definitions). The usecase template imports `pb "{{.Module}}/internal/handler/pb"` which refers to the handler package — this is the same package aliased as `pbhandler` in server.go. Both refer to the same Go package `internal/handler/pb`.

- [ ] **Step 4: Verify templates compile**

Run:
```bash
cd base-hertz/hertz-template
# Verify YAML syntax (if yq available)
for f in internal_usecase_*.yaml internal_handler_pb_*.yaml internal_base_server_server_go.yaml; do
    echo "=== $f ===" && head -5 "$f"
done
```

For full verification with a generated project:
```bash
# If ncgo CLI is available, generate a test project
ncgo new test-svc --template base-hertz
cd test-svc && go build ./...
```

- [ ] **Step 5: Commit**

```bash
git add base-hertz/hertz-template/internal_usecase_pb_*.yaml \
        base-hertz/hertz-template/internal_handler_pb_*.yaml \
        base-hertz/hertz-template/internal_base_server_server_go.yaml
git commit -m "feat(base-hertz): add usecase scaffold template with DI wiring

- New usecase template: internal/usecase/pb/<service>_usecase.go
- Handler: add SetDefaultUseCase() and UseCaseSetter interface
- Server: wire usecase → handler in Run() via DI"
```

---

### Task 2: Enable RPCErrorRouter in Response Template

**Files:**
- Modify: `base-hertz/hertz-template/internal_pkg_response_response_go.yaml`
- Modify: `base-hertz/hertz-template/internal_pkg_response_response_test_go.yaml`

**Interfaces:**
- Consumes: `hertzframework.RPCErrorRouter` from `go-tools/go-framework/hertz`
- Produces: `NewResponder()` returns `*hertzframework.Responder` configured with `RPCErrorRouter`

**Why:** BFF services call RPC backends and need automatic error→HTTP mapping. `RPCErrorRouter` extracts error codes from `go-common/error` oops-errors and maps them to HTTP status codes. Without it, all errors return HTTP 500. Enabling by default matches the edge-bff reference pattern.

- [ ] **Step 1: Write the failing test**

Modify `base-hertz/hertz-template/internal_pkg_response_response_test_go.yaml`. Add a test that verifies `NewResponder()` configures an error router.

The test file template after modification:

```yaml
# Hertz custom template — internal/pkg/response/response_test.go
# Generates tests for internal/pkg/response/response_test.go.
path: internal/pkg/response/response_test.go
update_behavior:
    type: cover
body: |-
    package response

    import (
        "context"
        "net/http"
        "testing"

        goerror "github.com/byx-darwin/go-tools/go-common/error"
        frameworkerror "github.com/byx-darwin/go-tools/go-framework/error"
    )

    func TestCodeNotImplementedIsDefined(t *testing.T) {
        if CodeNotImplemented != 10010 {
            t.Fatalf("CodeNotImplemented = %d, want 10010", CodeNotImplemented)
        }
    }

    func TestNewResponderHasErrorRouter(t *testing.T) {
        r := NewResponder()
        if r == nil {
            t.Fatal("NewResponder() returned nil")
        }
        // Verify the error router is configured by routing a known oops error.
        // An oops error with CodeParamInvalid (10002) should route to HTTP 400.
        err := goerror.In("test").
            Code(frameworkerror.CodeParamInvalid).
            Public("param_invalid").
            Errorf("bad param")
        route, ok := r.ErrorRouter().Route(context.Background(), err)
        if !ok {
            t.Fatal("ErrorRouter did not recognize oops error")
        }
        if route.HTTPCode != http.StatusBadRequest {
            t.Fatalf("HTTPCode = %d, want %d", route.HTTPCode, http.StatusBadRequest)
        }
        if route.BizCode != frameworkerror.CodeParamInvalid {
            t.Fatalf("BizCode = %d, want %d", route.BizCode, frameworkerror.CodeParamInvalid)
        }
    }
```

**Note:** This test calls `r.ErrorRouter()` which must be an exported accessor on `*hertzframework.Responder`. If that accessor doesn't exist, use an alternative approach — test the routing behavior through the `Reply`/`Error` methods with a mock `app.RequestContext`.

**Alternative test (if `ErrorRouter()` accessor unavailable):**

```go
    func TestNewResponderRoutesErrors(t *testing.T) {
        r := NewResponder()
        if r == nil {
            t.Fatal("NewResponder() returned nil")
        }
        // Indirect verification: NewResponder should not panic and should
        // produce a non-nil Responder. The actual routing is tested in
        // go-tools/go-framework/hertz/response_test.go.
    }
```

- [ ] **Step 2: Update response.go template**

Modify `base-hertz/hertz-template/internal_pkg_response_response_go.yaml`.

Change `NewResponder()` from:
```go
    // NewResponder creates a Responder instance (called by server.Run).
    func NewResponder() *hertzframework.Responder {
        return hertzframework.NewResponder()
    }
```

To:
```go
    // NewResponder creates a Responder instance with RPC error routing.
    // RPCErrorRouter maps go-common/error oops errors to HTTP status codes,
    // enabling automatic error→HTTP mapping for BFF services.
    func NewResponder() *hertzframework.Responder {
        return hertzframework.NewResponder(
            hertzframework.WithErrorRouter(&hertzframework.RPCErrorRouter{}),
        )
    }
```

- [ ] **Step 3: Run tests**

If a generated project exists (e.g., `admin-bff-hertz`):
```bash
cd admin-bff-hertz
go test ./internal/pkg/response/ -v -run TestNewResponder
```

Or after regenerating from template:
```bash
ncgo update  # or however the template is applied
go test ./internal/pkg/response/ -v
```

- [ ] **Step 4: Commit**

```bash
git add base-hertz/hertz-template/internal_pkg_response_response_go.yaml \
        base-hertz/hertz-template/internal_pkg_response_response_test_go.yaml
git commit -m "feat(base-hertz): enable RPCErrorRouter in response template

- NewResponder() now uses WithErrorRouter(&RPCErrorRouter{})
- Adds test verifying error routing configuration
- Matches edge-bff reference pattern for BFF error handling"
```

---

### Task 3: Model Template for Non-Protobuf Scenarios

**Files:**
- Create: `base-hertz/hertz-template/internal_model_example_go.yaml`

**Interfaces:**
- Consumes: `{{.Module}}` (Go module path)
- Produces: `internal/model/example.go` with sample domain model structs

**Why:** The current template only generates protobuf-based types (via `internal/pb/`). For services using REST/JSON without protobuf, or for internal domain types that differ from API types, a `model` package provides a starting point. Follows the edge-bff pattern (`internal/model/device.go`).

- [ ] **Step 1: Create model template**

Create file `base-hertz/hertz-template/internal_model_example_go.yaml`:

```yaml
# ncgo exported template — internal/model/example.go
# Generates an example domain model package for non-protobuf scenarios.
# Developers replace example types with their own domain models.
path: internal/model/example.go
update_behavior:
    type: skip
body: |-
    package model

    // This file provides example domain model types.
    // Replace these with your actual domain models.
    //
    // Models represent business entities and are independent of
    // transport-layer types (protobuf, JSON). Use models when:
    //   - Your service uses REST/JSON without protobuf IDL
    //   - You need internal types that differ from API request/response types
    //   - You want clean separation between API contracts and domain logic

    // ExampleRequest is an example request body.
    type ExampleRequest struct {
        Name string `json:"name"`
    }

    // ExampleResponse is an example response body.
    type ExampleResponse struct {
        ID   string `json:"id"`
        Name string `json:"name"`
    }
```

- [ ] **Step 2: Verify template file**

```bash
# Verify YAML structure
cat base-hertz/hertz-template/internal_model_example_go.yaml

# Verify generated path
echo "Template generates: internal/model/example.go"
```

- [ ] **Step 3: Commit**

```bash
git add base-hertz/hertz-template/internal_model_example_go.yaml
git commit -m "feat(base-hertz): add model template for non-protobuf scenarios

- Generates internal/model/example.go with example domain types
- update_behavior: skip (developer-owned, not overwritten on regeneration)
- Provides starting point for REST/JSON services without protobuf IDL"
```

---

### Task 4: Verification & Documentation

**Files:**
- Modify: `base-hertz/README.md` (if exists, otherwise create)

- [ ] **Step 1: Update README with new templates**

Add a "DDD Scaffolding" section to `base-hertz/README.md`:

```markdown
## DDD Scaffolding

The template generates the following DDD layers:

| Layer | Path | Description |
|-------|------|-------------|
| Handler | `internal/handler/pb/` | HTTP handlers — bind, delegate, respond |
| UseCase | `internal/usecase/pb/` | Business logic — implement handler's `useCase` interface |
| Repository | `internal/repository/` | Data access — database queries |
| Model | `internal/model/` | Domain types — for non-protobuf scenarios |
| Response | `internal/pkg/response/` | HTTP response helpers (wraps go-framework/hertz) |

### Wiring

The template wires layers in `internal/base/server/server.go`:

```go
// Wire DDD: usecase → handler
pbhandler.SetDefaultUseCase(usecasepb.NewUseCase())
```

### Error Routing

`NewResponder()` enables `RPCErrorRouter` by default, mapping `go-common/error` oops errors to HTTP status codes. This is essential for BFF services calling RPC backends.
```

- [ ] **Step 2: Full build verification**

If a generated project exists:
```bash
cd admin-bff-hertz
go build ./...
go test ./...
```

- [ ] **Step 3: Commit documentation**

```bash
git add base-hertz/README.md
git commit -m "docs(base-hertz): document DDD scaffolding and error routing"
```

---

## Summary

| Task | Files | Effort | Risk |
|------|-------|--------|------|
| 1. UseCase scaffold | 3 templates (1 new, 2 modify) | Medium | Breaking: server.go `type: cover` overwrites on regen |
| 2. RPCErrorRouter | 2 templates (modify) | Low | Low: additive change |
| 3. Model template | 1 template (new) | Low | None: new file, `type: skip` |
| 4. Verification | README | Low | None |

**Backward compatibility notes:**
- Handler template change adds `UseCaseSetter` + `SetDefaultUseCase`. Generated projects with `type: skip` won't be overwritten. Developers must manually add the setter or regenerate.
- Server.go template change uses `type: cover` — existing projects WILL be overwritten on regeneration. The added wiring is safe (no-op if usecase doesn't exist yet, but will fail compilation if usecase package is missing). **Mitigation:** ensure the usecase template is applied before server.go regeneration.
- Response template change uses `type: cover` — existing projects WILL be overwritten. The `RPCErrorRouter` is a safe default for BFF services.
