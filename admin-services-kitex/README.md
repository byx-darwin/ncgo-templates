# admin-services-kitex

Official **Admin Authority** Kitex RPC service template — merged RBAC (users/roles/permissions) and Rule Center (rate limit rules) into a single service.

## Overview

`admin-services-kitex` combines two bounded contexts into one service:

- ✅ **Authentication Service** - Login, token validation, refresh
- ✅ **RBAC Service** - Users, roles, permissions, menus (Casbin-based)
- ✅ **Rule Center Service** - Rate limit rule management

**Architecture:**
```
admin-bff-hertz (BFF)
    ↓ gRPC
admin-services-kitex (Authority)
    ├── AuthService      - JWT token management
    ├── RBACService      - Users/Roles/Permissions
    └── RuleService      - Rate limit rules
    ↓
PostgreSQL + Redis
```

## Why Merged?

Originally, these were separate services (`rbac-kitex` + `rule-center`). Merging provides:

- ✅ **Simpler deployment** - One service instead of two
- ✅ **Shared database** - Same PostgreSQL instance
- ✅ **Shared Redis** - Same Redis instance
- ✅ **Reduced latency** - No inter-service RPC calls
- ✅ **Easier development** - Single codebase

## Quick Start

```bash
# Create authority service
ncgo new authority --module github.com/acme/authority --kind kitex --db postgres --template admin-services-kitex

# Create admin BFF (connects to authority)
ncgo new admin-api --module github.com/acme/admin-api --kind hertz --template admin-bff-hertz
```

## gRPC Services

### 1. AuthService

Authentication and token management:

```protobuf
service AuthService {
    rpc Login(LoginReq) returns (LoginResp);
    rpc Refresh(RefreshReq) returns (LoginResp);
    rpc Logout(LogoutReq) returns (LogoutResp);
    rpc ValidateToken(ValidateTokenReq) returns (ValidateTokenResp);
}
```

**Login:**
```bash
# Via BFF
curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"Admin@123"}'
```

### 2. RBACService

User, role, and permission management:

```protobuf
service RBACService {
    // User management
    rpc CreateUser(CreateUserReq) returns (UserResp);
    rpc GetUser(GetUserReq) returns (UserResp);
    rpc ListUsers(ListUsersReq) returns (ListUsersResp);
    rpc UpdateUser(UpdateUserReq) returns (UserResp);
    rpc DeleteUser(DeleteUserReq) returns (Empty);
    
    // Role management
    rpc CreateRole(CreateRoleReq) returns (RoleResp);
    rpc ListRoles(ListRolesReq) returns (ListRolesResp);
    rpc UpdateRole(UpdateRoleReq) returns (RoleResp);
    rpc DeleteRole(DeleteRoleReq) returns (Empty);
    
    // Permission management
    rpc CreatePermission(CreatePermissionReq) returns (PermissionResp);
    rpc ListPermissions(ListPermissionsReq) returns (ListPermissionsResp);
    
    // Authorization
    rpc Enforce(EnforceReq) returns (EnforceResp);
    rpc GetUserMenuTree(GetUserMenuTreeReq) returns (GetUserMenuTreeResp);
    rpc GetUserPermCodes(GetUserPermCodesReq) returns (GetUserPermCodesResp);
}
```

### 3. RuleService

Rate limit rule management:

```protobuf
service RuleService {
    rpc CreateRule(CreateRuleReq) returns (RuleResp);
    rpc GetRule(GetRuleReq) returns (RuleResp);
    rpc ListRules(ListRulesReq) returns (ListRulesResp);
    rpc UpdateRule(UpdateRuleReq) returns (RuleResp);
    rpc DeleteRule(DeleteRuleReq) returns (Empty);
}
```

**Rule structure:**
```json
{
    "name": "api-limit",
    "path_pattern": "/api/v1/*",
    "method": "POST",
    "limit": 100,
    "window_seconds": 60,
    "strategy": "fixed_window",
    "enabled": true
}
```

## Database Schema

### Users & Auth

```sql
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,  -- Argon2id hash
    email TEXT,
    status INT DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE roles (
    id BIGSERIAL PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    status INT DEFAULT 1
);

CREATE TABLE user_roles (
    user_id BIGINT REFERENCES users(id),
    role_id BIGINT REFERENCES roles(id),
    PRIMARY KEY (user_id, role_id)
);
```

### Permissions

```sql
CREATE TABLE permissions (
    id BIGSERIAL PRIMARY KEY,
    code TEXT NOT NULL,
    type TEXT NOT NULL,  -- catalog, menu, button, api
    name TEXT NOT NULL,
    parent_id BIGINT REFERENCES permissions(id),
    path TEXT,
    method TEXT,
    status INT DEFAULT 1,
    UNIQUE(code, type)
);

CREATE TABLE role_permissions (
    role_id BIGINT REFERENCES roles(id),
    permission_id BIGINT REFERENCES permissions(id),
    PRIMARY KEY (role_id, permission_id)
);
```

### Casbin Policy

```sql
CREATE TABLE casbin_rule (
    id BIGSERIAL PRIMARY KEY,
    ptype TEXT,  -- 'p' (policy) or 'g' (group)
    v0 TEXT,     -- subject (user/role)
    v1 TEXT,     -- object (resource)
    v2 TEXT      -- action
);
```

### Rate Limit Rules

```sql
CREATE TABLE rate_limit_rules (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    path_pattern TEXT,
    method TEXT,
    limit INT NOT NULL,
    window_seconds INT NOT NULL,
    strategy TEXT DEFAULT 'fixed_window',
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

## Configuration

### Database

```yaml
database:
  enabled: true
  dsn: "postgres://postgres:postgres@localhost:5432/authority?sslmode=disable"
  max_conns: 20
  min_conns: 2
```

### Redis

```yaml
redis:
  addrs:
    - "127.0.0.1:6379"
  db: 0
```

### JWT

```yaml
auth:
  jwt_secret: "dev-secret-change-me"
  access_ttl_seconds: 3600
  refresh_ttl_seconds: 86400
  token_store: "memory"  # or "redis"
```

## Password Hashing

Uses Argon2id (recommended by OWASP):

```go
import "golang.org/x/crypto/argon2"

// Hash password
hash := argon2.IDKey([]byte(password), salt, 3, 64*1024, 4, 32)

// Format: $argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>
```

## Seed Data

Initial admin user:

```sql
-- Password: Admin@123 (Argon2id hash)
INSERT INTO users (username, password_hash, email, status)
VALUES (
    'admin',
    '$argon2id$v=19$m=65536,t=3,p=4$...',
    'admin@example.com',
    1
);

-- Super admin role
INSERT INTO roles (code, name) VALUES ('super_admin', 'Super Administrator');

-- Assign role
INSERT INTO user_roles (user_id, role_id) VALUES (1, 1);

-- Casbin policy: admin → super_admin
INSERT INTO casbin_rule (ptype, v0, v1, v2)
VALUES ('g', '1', 'super_admin', '');
```

## Permission Codes

Standard naming: `resource:action`

| Permission | Description |
|------------|-------------|
| `user:list` | List users |
| `user:read` | Read user |
| `user:create` | Create user |
| `user:update` | Update user |
| `user:delete` | Delete user |
| `role:list` | List roles |
| `role:create` | Create role |
| `role:update` | Update role |
| `role:delete` | Delete role |
| `permission:list` | List permissions |
| `permission:read` | Read permission |
| `permission:create` | Create permission |
| `permission:update` | Update permission |
| `permission:delete` | Delete permission |
| `menu:list` | List menus |
| `rate_limit:list` | List rate limit rules |
| `rate_limit:create` | Create rate limit rule |
| `rate_limit:update` | Update rate limit rule |
| `rate_limit:delete` | Delete rate limit rule |

## Project Structure

```
authority/
├── cmd/
│   └── main.go                    # Entry point
├── internal/
│   ├── application/
│   │   ├── auth/                  # Auth use cases
│   │   ├── user/                  # User use cases
│   │   ├── role/                  # Role use cases
│   │   ├── permission/            # Permission use cases
│   │   ├── menu/                  # Menu use cases
│   │   └── rbac/                  # RBAC enforcement
│   ├── domain/
│   │   ├── user/                  # User entity
│   │   ├── role/                  # Role entity
│   │   └── permission/            # Permission entity
│   ├── handler/
│   │   ├── authservice/           # Auth gRPC handler
│   │   ├── rbacservice/           # RBAC gRPC handler
│   │   └── rulecenter/            # Rule gRPC handler
│   ├── infrastructure/
│   │   ├── auth/                  # JWT, password hashing
│   │   ├── casbin/                # Casbin enforcer
│   │   └── token/                 # Token store (memory/redis)
│   ├── repository/                # Data access
│   └── usecase/                   # Business logic
├── kitex_gen/                     # Generated gRPC code
├── idl/
│   └── admin.proto                # Proto definitions
└── conf/
    └── dev/conf.yaml              # Configuration
```

## Development

```bash
# Generate Kitex code from proto
make generate

# Run in development mode
make dev

# Build binary
make build

# Run tests
make test

# Run migrations
make migrate-up DATABASE_URL="postgres://..."
```

## Integration with BFF

The admin BFF connects to this service via gRPC:

```yaml
# admin-bff-hertz conf.yaml
grpc:
  authority:
    service_name: "authority"
    host_ports:
      - "127.0.0.1:8888"
```

## Related Templates

- **admin-bff-hertz** - Admin BFF with RBAC authorization (connects to this service)
- **ratelimit-hertz** - HTTP service with rate limiting execution (fetches rules from this service)
- **base-hertz** - Basic HTTP service (no RBAC)

## License

Part of the ncgo template registry.
