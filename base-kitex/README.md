# base-kitex

Official base **Kitex RPC** service template — standard layered layout with
health check, matching what `ncgo new --kind kitex` generates with built-in assets.

## Use

```bash
ncgo template pull base-kitex
ncgo new my-rpc --module github.com/acme/my-rpc --kind kitex --template base-kitex
```

## Contents

`kitex-template/*.yaml` mirrors the built-in ncgo kitex template set:
`main`, `conf`, `data`, `handler`, `usecase`, `repository`, `server`,
`interceptor` (+ tests), `client`, `rpcerror`, `migration`, `makefile`.

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.

## Layered Architecture

The template generates a standard layered structure:

| Layer | Path | Description |
|-------|------|-------------|
| Handler | `internal/handler/` | gRPC service implementations |
| UseCase | `internal/usecase/` | Business logic orchestration |
| Repository | `internal/repository/` | Data access interfaces |
| Response | `internal/pkg/response/` | Error codes and helpers |

## Build

```bash
# Generate Kitex code from proto
make update

# Generate sqlc code (if database enabled)
make sqlc

# Run in development mode
make dev

# Build binary
make build

# Run tests
make test
```
