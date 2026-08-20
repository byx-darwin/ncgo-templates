# admin-bff-hertz

Official **Admin BFF (Backend for Frontend)** Hertz HTTP template — JWT authentication, RBAC authorization, API signature, and idempotency support.

## Overview

`admin-bff-hertz` is designed for building admin backends with fine-grained permission control. It connects to `admin-services-kitex` (authority service) for authentication and authorization:

- ✅ **JWT Authentication** - Bearer token validation
- ✅ **RBAC Authorization** - Permission-based access control via Casbin
- ✅ **API Signature** - HMAC signature verification (optional)
- ✅ **Idempotency** - Prevent duplicate requests (optional)
- ✅ **Fine-grained Error Codes** - Aligned with go-framework v0.2.1

**Architecture:**
```
Client → admin-bff-hertz (BFF) → admin-services-kitex (Authority)
         - JWT validation        - AuthService (login/token)
         - RBAC check            - RBACService (users/roles/permissions)
         - Signature             - RuleService (rate limit rules)
```

## Quick Start

```bash
# Create admin BFF
ncgo new admin-api --module github.com/acme/admin-api --kind hertz --db postgres --template admin-bff-hertz

# Add authority service (required)
ncgo add rpc authority --template admin-services-kitex
```

## Configuration

### JWT Configuration

Must match the authority service's JWT secret:

```yaml
jwt:
  secret: "dev-secret-change-me"  # Must match authority service
  access_token_ttl_seconds: 3600
  refresh_token_ttl_seconds: 86400
```

### gRPC Connection

Connect to authority service:

```yaml
grpc:
  authority:
    service_name: "authority"
    host_ports:
      - "127.0.0.1:8888"
    rpc_timeout_seconds: 5
```

### RBAC Authorization

Authorization is handled via Casbin policies:

```yaml
auth:
  public_paths:
    - /healthz
    - /readyz
```

### API Signature (Optional)

For open API scenarios:

```yaml
auth:
  signature:
    enabled: true
    static_secret: "your-app-secret"
    header_app_key: "X-App-Key"
    header_timestamp: "X-Timestamp"
    header_nonce: "X-Nonce"
    header_signature: "X-Signature"
```

## API Routes

### Public Routes

- `POST /api/v1/auth/login` - Login (returns JWT)
- `POST /api/v1/auth/refresh` - Refresh token
- `GET /healthz` - Liveness probe
- `GET /readyz` - Readiness probe

### Protected Routes (JWT + RBAC Required)

#### Auth

```
POST /api/v1/auth/logout
```

#### Current User

```
GET /api/v1/me/menus      # Get current user's menu tree
GET /api/v1/me/perms      # Get current user's permissions
```

#### User Management

```
GET    /api/v1/users      # permission: user:list
GET    /api/v1/users/:id  # permission: user:read
POST   /api/v1/users      # permission: user:create
PUT    /api/v1/users/:id  # permission: user:update
DELETE /api/v1/users/:id  # permission: user:delete
```

#### Role Management

```
GET    /api/v1/roles      # permission: role:list
POST   /api/v1/roles      # permission: role:create
PUT    /api/v1/roles/:id  # permission: role:update
DELETE /api/v1/roles/:id  # permission: role:delete
```

#### Permission Management

```
GET    /api/v1/permissions      # permission: permission:list
GET    /api/v1/permissions/:id  # permission: permission:read
POST   /api/v1/permissions      # permission: permission:create
PUT    /api/v1/permissions/:id  # permission: permission:update
DELETE /api/v1/permissions/:id  # permission: permission:delete
```

#### Menu Management

```
GET /api/v1/menus  # permission: menu:list
```

#### Rate Limit Rules Management

```
GET    /api/v1/rate-limit-rules      # permission: rate_limit:list
POST   /api/v1/rate-limit-rules      # permission: rate_limit:create
PUT    /api/v1/rate-limit-rules/:id  # permission: rate_limit:update
DELETE /api/v1/rate-limit-rules/:id  # permission: rate_limit:delete
```

## Middleware Stack

### Request Flow

```
1. Signature Verification (if enabled)
2. Idempotency Check (if enabled)
3. JWT Authentication
4. RBAC Authorization (Casbin)
5. Permission Check (per-route)
6. Handler Execution → gRPC call to authority
```

### Error Codes

| Code | HTTP | Message | Description |
|------|------|---------|-------------|
| 10002 | 401 | auth_failed | Generic auth failure |
| 10007 | 401 | signature_missing | Missing signature headers |
| 10019 | 403 | signature_invalid | Invalid signature |
| 10020 | 401 | token_missing | Missing JWT token |
| 10021 | 401 | token_invalid | Invalid JWT token |
| 10108 | 403 | permission_denied | Insufficient permissions |
| 10203 | 400 | idempotency_key_missing | Missing Idempotency-Key |

## Permission System

### Permission Types

- **catalog** - Top-level menu category
- **menu** - Menu item
- **button** - UI button/action
- **api** - API endpoint permission

### Permission Codes

Standard naming convention: `resource:action`

Examples:
- `user:list` - List users
- `user:create` - Create user
- `role:update` - Update role
- `permission:delete` - Delete permission

### Casbin Policy Model

```
[request_definition]
r = sub, obj, act

[policy_definition]
p = sub, obj, act

[role_definition]
g = user, role

[policy_effect]
e = some(where (p.eft == allow))

[matchers]
m = g(r.sub, p.sub) && r.obj == p.obj && r.act == p.act
```

## Project Structure

```
admin-api/
├── internal/
│   ├── base/
│   │   ├── conf/                  # Configuration
│   │   ├── data/                  # Database clients
│   │   └── server/                # HTTP server setup
│   ├── handler/
│   │   ├── auth.go                # Login/logout handlers
│   │   ├── user.go                # User management
│   │   ├── role.go                # Role management
│   │   ├── permission.go          # Permission management
│   │   ├── menu.go                # Menu management
│   │   ├── rate_limit.go          # Rate limit rules
│   │   ├── current_user.go        # Current user info
│   │   └── pb/                    # Proto handlers
│   ├── pkg/
│   │   ├── middleware/
│   │   │   ├── jwt.go             # JWT validation
│   │   │   ├── authz.go           # RBAC authorization
│   │   │   ├── signature.go       # API signature
│   │   │   └── idempotency.go     # Idempotency
│   │   └── response/              # Error codes
│   └── router/
│       └── adminbffservice.go     # Route registration
├── conf/
│   └── dev/conf.yaml              # Configuration
└── idl/
    └── *.proto                    # Proto definitions
```

## Login Flow

```bash
# 1. Login
curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"Admin@123"}'

# Response:
{
  "code": 200,
  "msg": "ok",
  "data": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "refresh_token": "9d4ab5f7bfb8...",
    "expires_in": 3600
  }
}

# 2. Use token
curl -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIs..." \
  http://localhost:8080/api/v1/users
```

## API Signature Example

```bash
# Generate signature
METHOD="POST"
PATH="/api/v1/users"
TIMESTAMP=$(date +%s)
NONCE=$(openssl rand -hex 8)
BODY='{"username":"testuser"}'
SECRET="your-app-secret"

CANONICAL="${METHOD}\n${PATH}\n\n${TIMESTAMP}\n${NONCE}\n${BODY}"
SIGNATURE=$(echo -ne "$CANONICAL" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')

# Make request
curl -X POST http://localhost:8080/api/v1/users \
  -H "X-App-Key: my-app" \
  -H "X-Timestamp: $TIMESTAMP" \
  -H "X-Nonce: $NONCE" \
  -H "X-Signature: $SIGNATURE" \
  -H "Content-Type: application/json" \
  -d "$BODY"
```

## Idempotency Example

```bash
# First request
curl -X POST http://localhost:8080/api/v1/users \
  -H "Authorization: Bearer <token>" \
  -H "Idempotency-Key: unique-key-123" \
  -H "Content-Type: application/json" \
  -d '{"username":"user1"}'

# Second request with same key (returns cached response)
curl -X POST http://localhost:8080/api/v1/users \
  -H "Authorization: Bearer <token>" \
  -H "Idempotency-Key: unique-key-123" \
  -H "Content-Type: application/json" \
  -d '{"username":"different-user"}'  # Ignored, returns first response
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

- **base-hertz** - Basic HTTP service (no RBAC)
- **ratelimit-hertz** - HTTP service with rate limiting execution
- **admin-services-kitex** - Authority service (RBAC + Rule Center)

## License

Part of the ncgo template registry.
