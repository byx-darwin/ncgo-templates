# base-hertz

Official base **Hertz HTTP** service template — standard layered layout with
health check, matching what `ncgo new --kind hertz` generates with built-in assets.

## Use

```bash
ncgo template pull base-hertz

# With database support (recommended)
ncgo new my-api --module github.com/acme/my-api --kind hertz --db postgres --template base-hertz

# Without database support (limited functionality)
ncgo new my-api --module github.com/acme/my-api --kind hertz --template base-hertz
```

**Note:** This template includes database-related templates (repository, usecase, sqlc).
For full functionality, use with `--db postgres`. Without `--db`, some generated files
may reference database code that requires manual setup.

## Adding Infrastructure Components

After creating your project, you can add infrastructure components using `ncgo add infra`:

### Redis

```bash
ncgo add infra redis --root .
```

This adds:
- `internal/base/data/redis.go` - Redis client initialization
- `internal/base/data/redis_shared.go` - Shared Redis client helper

Configuration in `conf/dev/conf.yaml`:
```yaml
redis:
  enabled: true
  addrs:
    - "localhost:6379"
  password: ""
  db: 0
```

### Kafka

```bash
ncgo add infra kafka --root .
```

Adds Kafka producer and consumer helpers under `internal/base/data/`.

### Elasticsearch

```bash
ncgo add infra elasticsearch --root .
```

Adds Elasticsearch client initialization.

### ClickHouse

```bash
ncgo add infra clickhouse --root .
```

Adds ClickHouse client for analytics workloads.

### Structured Logging

```bash
ncgo add infra logging --root .
```

Adds structured logging with:
- `internal/base/logging/logging.go` - Core logging setup
- `internal/base/logging/hertz.go` - Hertz-specific access logging

Wire it up in `internal/base/server/server.go`:
```go
import "my-api/internal/base/logging"

// In Run() function:
h.Use(logging.HertzRecovery())
h.Use(logging.HertzRequestID())
h.Use(logging.HertzAccessLog())
```

### Canary Release

```bash
ncgo add infra canary --root .
```

Adds canary release helpers for traffic splitting and A/B testing.

### Observability

```bash
ncgo add infra observability --root .
```

Adds OpenTelemetry tracing and metrics setup.

## Contents

`hertz-template/*.yaml` mirrors the built-in ncgo hertz template set:
`main`, `conf`, `data`, `server`, `middleware`, `repository`, `usecase`,
`errcode`, `response`, `makefile`, `sqlc`.

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.

## Features

### Health Check Endpoints

Built-in health check and readiness probe endpoints for Kubernetes and load balancers:

- **`GET /healthz`** - Liveness probe
  ```json
  {
    "code": 200,
    "msg": "ok",
    "data": {
      "status": "ok",
      "time": "2026-08-09T09:01:37Z"
    }
  }
  ```

- **`GET /readyz`** - Readiness probe
  ```json
  {
    "code": 200,
    "msg": "ok",
    "data": {
      "status": "ready",
      "time": "2026-08-09T09:01:37Z"
    }
  }
  ```

Implementation: `internal/handler/health/health.go`

These endpoints are automatically registered in `internal/base/server/server.go` via:
```go
health.Register(h)
```

### Other Features

- **Standard Layout**: Follows ncgo's layered architecture
- **Database Support**: Repository and usecase patterns with sqlc
- **Rate Limiting**: Configurable rate limiting middleware
- **Middleware Stack**: CORS, error handling, authentication, etc.

## Project Structure

```
my-api/
├── cmd/
│   └── main.go              # Application entry point
├── internal/
│   ├── base/
│   │   ├── conf/            # Configuration loading
│   │   ├── data/            # Database and infrastructure clients
│   │   └── server/          # HTTP server setup
│   ├── handler/
│   │   ├── health/          # Health check handlers
│   │   └── pb/              # Protocol buffer handlers
│   ├── middleware/          # HTTP middleware
│   ├── pkg/                 # Shared packages
│   ├── repository/          # Data access layer
│   └── usecase/             # Business logic layer
├── conf/
│   └── dev/conf.yaml        # Development configuration
├── idl/
│   └── *.proto              # Protocol buffer definitions
└── template/
    └── hertz-template/      # Template files
```

## Configuration

Edit `conf/dev/conf.yaml` to configure:
- Server port and address
- Database connection
- Redis connection
- Rate limiting rules
- Logging levels

## Development

```bash
# Run in development mode
make dev

# Build binary
make build

# Run tests
make test
```

## License

Part of the ncgo template registry.
