# Contributing — Official Review Flow

Templates in this registry are curated by the official team. Every change goes
through a branch + PR review, mirroring the ncgo release discipline.

## Contribution Flow

```
Contributor                      Official Maintainer
───────────                      ─────────────────
1. Fork (or branch) this repo
2. Add/update a template package
3. Push branch & open PR ──────→ 4. Review (structure, variable substitution,
                                     update_behavior, idl consistency)
                                   5. Approve & merge
6. Users: ncgo template pull <name>
```

## Package Requirements (review checklist)

For each template package, reviewers verify:

- **`template.yaml`** — `name` matches the directory; `kind` is one of
  `hertz | kitex | micro`; `description` is accurate; `version` bumped on changes.
- **`<kind>-template/*.yaml`** — same format as built-in ncgo assets (`path`,
  `update_behavior`, optional `loop_service`, `body`); variables use
  `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}` and render cleanly.
- **`idl/*.proto`** (optional) — variabilized service names; renders to a
  syntactically valid proto under a new service name (validated with
  `ncgo protolint`).
- **Documentation** — `README.md` explains what the template provides and how
  to consume it.
- **Determinism** — no absolute paths, timestamps, or machine-specific values.

## Validation

```bash
# template.yaml + structure check
ncgo template list

# render a package to a scratch project and validate the generated IDL
ncgo new scratch --module github.com/acme/scratch --kind kitex \
  --no-generate --template-dir <package>
ncgo protolint --root scratch --file idl/<name>.proto
```

## Consumption Status

- `base-kitex` / `base-hertz`: fully consumable via `ncgo new --template`.
- `rule-center`: assets ready; full `--preset`-equivalent consumption depends on
  ncgo rule-center template support (follow-up).
- `micro`: workspace layout reference; consumption depends on ncgo
  `add rpc` / `add bff` template support (follow-up).
