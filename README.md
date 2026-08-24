# Official ncgo Template Registry

Official template registry for [ncgo](https://github.com/byx-darwin/ncgo) — the AI-friendly scaffold CLI for Go microservices.

Browse and consume these templates with the ncgo registry client:

```bash
ncgo template list
ncgo template pull base-kitex
ncgo new my-svc --module github.com/acme/my-svc --kind kitex --template base-kitex
```

The registry URL defaults to this repository; override with `--registry <url>` or `NCGO_REGISTRY`.

## Templates

### HTTP Services (Hertz)

| Package | Description | Consumable |
|---|---|---|
| `base-hertz` | Standard Hertz HTTP service (DDD layered layout + JWT + signature + idempotency) | ✅ `ncgo new --kind hertz --template base-hertz` |
| `ratelimit-hertz` | Hertz HTTP service with rate limiting execution (two-phase: pre-auth + post-auth) | ✅ `ncgo new --kind hertz --template ratelimit-hertz` |
| `admin-bff-hertz` | Admin BFF with RBAC authorization (JWT + Casbin + gRPC to authority) | ✅ `ncgo new --kind hertz --template admin-bff-hertz` |

### RPC Services (Kitex)

| Package | Description | Consumable |
|---|---|---|
| `base-kitex` | Standard Kitex RPC service (layered layout + health check) | ✅ `ncgo new --kind kitex --template base-kitex` |
| `rbac-kitex` | RBAC + auth authority service (DDD, Casbin sqlc adapter, JWT login, audit) | ✅ `ncgo new --kind kitex --template rbac-kitex` |
| `admin-services-kitex` | Merged admin authority (RBAC + Rule Center in one service) | ✅ `ncgo new --kind kitex --template admin-services-kitex` |
| `rule-center` | Rate-limit rule-center service (standalone) | ⚠️ asset-ready; use `admin-services-kitex` for merged version |

### Workspaces (Micro)

| Package | Description | Consumable |
|---|---|---|
| `micro` | Micro workspace reference (multi-service layout + shared compose/pre-commit) | ⚠️ reference; use `ncgo add rpc/bff` to add services |
| `micro-admin` | Admin workspace composition (admin-services-kitex + admin-bff-hertz) | ⚠️ composition package; see README for setup guide |

### DDD Pattern

All service templates follow DDD layered architecture:

```
internal/
├── handler/          # HTTP/gRPC handlers — bind, delegate, respond
├── usecase/          # Business logic — implement handler interfaces
├── repository/       # Data access — database queries
├── model/            # Domain types — for non-protobuf scenarios
└── pkg/response/     # Response helpers with RPCErrorRouter
```

**Key features:**
- `NewResponder()` enables `RPCErrorRouter` by default (maps `go-common/error` to HTTP status)
- JWT `Claims` includes `Roles []string` field for permission-based access control
- Unified `auth.token` configuration (replaces legacy `jwt` config)

## Package Layout

Each template package is a directory with:

```
<package>/
├── template.yaml            # metadata: name / kind / description / version
├── <kind>-template/*.yaml   # code templates (same format as built-in ncgo assets)
├── idl/*.proto              # optional variabilized IDL
└── README.md
```

Exported packages produced by `ncgo export templates` map directly onto this layout (add `template.yaml` + `README.md` to contribute).

## Contributing

Templates are managed through official review — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the branch / PR flow.
