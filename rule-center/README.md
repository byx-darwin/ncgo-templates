# rule-center

Official rate-limit **rule-center** service template (Kitex gRPC) — a standalone
service other Hertz services query for rate-limit rules, mirroring the ncgo
`rule-center` preset assets.

## Use

```bash
ncgo template pull rule-center
ncgo new rule-center --module github.com/acme/rule-center --kind kitex \
  --template rule-center
```

> **Consumption status:** the package ships the complete rule-center template
> and IDL asset set. Full `--preset rule-center`-equivalent behavior (preset
> proto wiring + schema/query extras) lands with ncgo rule-center template
> support — tracked as a follow-up. Until then, prefer
> `ncgo new rule-center --kind kitex --preset rule-center` for the built-in path.

## Contents

- `kitex-template/*.yaml` — rate-limit handler/middleware/usecase/repository,
  shared resolver + store (+ tests), rule-center client, server, conf, data,
  sqlc queries, migration, makefile.
- `idl/rule-center.proto` — `ratelimit.v1.RuleService` (GetRule / CreateRule /
  UpdateRule / DeleteRule / ListRules).

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.
