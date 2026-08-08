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

| Package | Kind | Description | Consumable |
|---|---|---|---|
| `base-kitex` | kitex | Standard Kitex RPC service (layered layout + health check) | ✅ `ncgo new --kind kitex --template base-kitex` |
| `base-hertz` | hertz | Standard Hertz HTTP service (layered layout + health check) | ✅ `ncgo new --kind hertz --template base-hertz` |
| `rule-center` | kitex | Rate-limit rule-center service (Kitex gRPC + rate-limit store/resolver/middleware) | ⚠️ asset-ready; full preset consumption lands with ncgo rule-center template support |
| `micro` | micro | Micro workspace reference (multi-service layout + shared compose/pre-commit) | ⚠️ reference; workspace template consumption lands with ncgo add rpc/bff template support |

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
