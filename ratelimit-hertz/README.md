# ratelimit-hertz

Official **Hertz HTTP** service template with built-in rate limiting execution — JWT authentication, API signature, idempotency, and rate limiting middleware.

## Overview

`ratelimit-hertz` is designed for services that need **rate limit execution** (enforcement). It includes all the security features of `base-hertz` plus powerful rate limiting capabilities:

- ✅ **JWT Authentication** - Bearer token validation
- ✅ **API Signature** - HMAC signature verification (optional)
- ✅ **Idempotency** - Prevent duplicate requests (optional)
- ✅ **Rate Limiting** - Two-phase rate limiting (pre-auth + post-auth)
- ✅ **Multiple Backends** - Memory (single instance) or Redis (distributed)
- ✅ **Flexible Strategies** - Fixed window, sliding window, token bucket
- ✅ **Fine-grained Error Codes** - Aligned with go-framework v0.2.1

**Note:** This template is for rate limit **execution** only. For rate limit rule **management**, use `admin-services-kitex` (rule-center service) or `admin-bff-hertz`.

## Rate Limiting Architecture

```
Request → Signature Check → Rate Limit (pre_auth) → JWT Auth → Rate Limit (post_auth) → Handler
```

### Two-Phase Rate Limiting

1. **Pre-auth Phase** - Before authentication (default: IP-based)
   - Protects authentication endpoints
   - Prevents brute force attacks
   - Uses IP address as key

2. **Post-auth Phase** - After authentication (default: user-based)
   - Per-user rate limiting
   - More granular control
   - Uses user ID or app key as key

## Quick Start

```bash
# With database support
ncgo new my-api --module github.com/acme/my-api --kind hertz --db postgres --template ratelimit-hertz

# Without database
ncgo new my-api --module github.com/acme/my-api --kind hertz --template ratelimit-hertz
```

## Configuration

### Basic Rate Limiting

```yaml
rate_limit:
  enabled: true
  backend: memory  # or "redis" for distributed
  
  # Pre-auth phase (before JWT)
  pre_auth:
    enabled: true
    default_rule:
      enabled: true
      key_by: [ip]
      strategy: fixed_window
      window_seconds: "60s"
      max_requests: 100
  
  # Post-auth phase (after JWT)
  post_auth:
    enabled: true
    default_rule:
      enabled: true
      key_by: [user_uuid]
      strategy: fixed_window
      window_seconds: "60s"
      max_requests: 50
```

### Redis Backend (Distributed)

```yaml
rate_limit:
  enabled: true
  backend: redis
  redis:
    addrs:
      - "127.0.0.1:6379"
    password: ""
    db: 0
```

### Rule Sources

Rate limit rules can come from different sources:

```yaml
rate_limit:
  source:
    type: config  # or "grpc", "database", "rule_center"
    cache_ttl_seconds: "60s"
    fallback_on_error: true
```

- **config** - Rules from YAML configuration
- **grpc** - Fetch rules from gRPC service (rule-center)
- **database** - Rules from database
- **rule_center** - Rules from rule-center service

### Custom Rules

```yaml
rate_limit:
  post_auth:
    rules:
      - path: "/api/v1/upload"
        method: "POST"
        rule:
          key_by: [user_uuid]
          strategy: fixed_window
          window_seconds: "3600s"
          max_requests: 10
      
      - path_prefix: "/api/v1/admin"
        rule:
          key_by: [user_uuid]
          strategy: sliding_window
          window_seconds: "60s"
          max_requests: 30
```

## Middleware Stack

### Request Flow

```
1. Signature Verification (if enabled)
2. Rate Limit - Pre-auth Phase
3. JWT Authentication
4. Rate Limit - Post-auth Phase
5. Idempotency Check (if enabled)
6. Handler Execution
```

### Error Codes

| Code | HTTP | Message | Phase |
|------|------|---------|-------|
| 10007 | 401 | signature_missing | Signature |
| 10019 | 403 | signature_invalid | Signature |
| 10020 | 401 | token_missing | JWT |
| 10021 | 401 | token_invalid | JWT |
| 10200 | 429 | rate_limited | Rate Limit |
| 10203 | 400 | idempotency_key_missing | Idempotency |

## API Routes

### Public Routes

- `GET /healthz` - Liveness probe
- `GET /readyz` - Readiness probe

### Protected Routes (Rate Limited)

Example CRUD endpoints with rate limiting:

```
GET    /api/v1/resources      # Rate limited (post-auth)
POST   /api/v1/resources      # Rate limited (pre-auth + post-auth)
PUT    /api/v1/resources/:id  # Rate limited (post-auth)
DELETE /api/v1/resources/:id  # Rate limited (post-auth)
```

## Rate Limiting Strategies

### Fixed Window

```yaml
strategy: fixed_window
window_seconds: "60s"
max_requests: 100
```

Simple counter that resets every window.

### Sliding Window

```yaml
strategy: sliding_window
window_seconds: "60s"
max_requests: 100
```

Smooth rate limiting using weighted previous window.

### Token Bucket

```yaml
strategy: token_bucket
requests_per_second: 10
burst: 20
```

Allows bursts up to `burst` size, refills at `requests_per_second`.

## Key Extraction

Rate limit keys can be extracted from different sources:

```yaml
key_by: [ip]              # Client IP address
key_by: [user_uuid]       # Authenticated user ID
key_by: [ak]              # App key from header
key_by: [ak, user_uuid]   # Composite key
```

## Project Structure

```
my-api/
├── internal/
│   ├── base/
│   │   ├── conf/                  # Configuration
│   │   ├── data/                  # Database clients
│   │   └── server/                # HTTP server + rate limit setup
│   ├── handler/
│   │   ├── health/                # Health checks
│   │   ├── resource.go            # Resource handler
│   │   └── pb/                    # Proto handlers
│   ├── pkg/
│   │   ├── middleware/            # JWT, signature, idempotency, rate_limit
│   │   ├── ratelimit/             # Rate limit resolver & store
│   │   └── response/              # Error codes
│   └── router/
│       └── service.go             # Route registration
└── conf/
    └── dev/conf.yaml              # Configuration with rate_limit
```

## Integration with Rule Center

To fetch rate limit rules from a centralized rule-center service:

```yaml
rate_limit:
  source:
    type: rule_center
    cache_ttl_seconds: "60s"
    fallback_on_error: true
  
  # gRPC configuration for rule-center
  grpc:
    target: "localhost:8889"
    timeout_milliseconds: "200ms"
    service_name: "rulecenter"
```

## Development

```bash
# Run in development mode
make dev

# Build binary
make build

# Run tests
make test
```

## Related Templates

- **base-hertz** - HTTP service without rate limiting
- **admin-bff-hertz** - Admin BFF with RBAC authorization
- **admin-services-kitex** - Merged RBAC + Rule Center RPC service (rule management)

## License

Part of the ncgo template registry.
