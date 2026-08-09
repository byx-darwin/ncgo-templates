# ratelimit-hertz

Official Hertz HTTP service template with built-in rate limiting support.

## Features

- **Rate Limiting**: Built-in rate limiting middleware with multiple algorithms
  - Fixed window
  - Sliding window  
  - Token bucket
- **Storage Backends**: Support for both memory and Redis backends
- **Flexible Configuration**: Configurable rate limit rules per route/path
- **Health Checks**: Built-in `/healthz` and `/readyz` endpoints
- **Standard Layout**: Follows ncgo's standard layered architecture

## Usage

Create a new project using this template:

```bash
ncgo new my-service \
  --module github.com/yourorg/my-service \
  --kind hertz \
  --template ratelimit-hertz
```

## Rate Limiting Configuration

The template includes rate limiting configuration in `conf/dev/conf.yaml`:

```yaml
rate_limit:
  enabled: true
  backend: memory  # or "redis"
  pre_auth:
    enabled: true
    default_rule:
      enabled: true
      key_by: [ip]
      strategy: fixed_window
      window_seconds: 60s
      max_requests: 100
```

### Storage Backends

- **memory**: Single-instance deployment, counters reset on restart
- **redis**: Distributed deployment, shared counters across instances

### Algorithms

- **fixed_window**: Simple counter per time window
- **sliding_window**: More accurate, smooths traffic at window boundaries
- **token_bucket**: Allows bursts while maintaining average rate

## Project Structure

```
my-service/
├── cmd/
│   └── main.go              # Application entry point
├── internal/
│   ├── handler/             # HTTP handlers
│   ├── middleware/          # Rate limit middleware
│   ├── model/              # Data models
│   ├── repository/         # Data access layer
│   ├── service/            # Business logic
│   └── ratelimit/          # Rate limit implementation
├── conf/
│   └── dev/conf.yaml       # Configuration with rate limit settings
├── idl/
│   └── *.proto             # Protocol buffer definitions
└── template/
    └── hertz-template/     # Template files
```

## Health Check Endpoints

- `GET /healthz` - Liveness probe
- `GET /readyz` - Readiness probe

These endpoints are excluded from rate limiting by default.

## Example: Testing Rate Limits

```bash
# Send 10 rapid requests
for i in {1..10}; do
  curl -s "http://localhost:8080/ping?name=test$i"
  echo
done
```

Expected behavior:
- First 5 requests: 200 OK
- Remaining requests: 429 Too Many Requests

## License

Part of the ncgo template registry.
