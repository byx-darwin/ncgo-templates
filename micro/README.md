# micro

Official **micro workspace** reference — the multi-service layout for ncgo
micro mode: `services/rpc` + `services/bff`, shared `compose.yaml`,
`.pre-commit-config.yaml`, and workspace metadata (`ncgo.workspace`).

## Reference Layout

```
workspace/
├── ncgo.workspace               # micro workspace metadata
├── README.md
├── compose.yaml                 # service orchestration
├── .pre-commit-config.yaml      # local hooks
├── scripts/                     # run-go-module-checks.sh
└── services/
    ├── <name>-rpc/              # Kitex RPC service (own .ncgo/manifest.yaml)
    └── <name>-bff/              # Hertz BFF service (own .ncgo/manifest.yaml)
```

Services under `services/` are scaffolded with `ncgo add rpc <name>` /
`ncgo add bff <name>` (each delegates to the mono service generator, so they
inherit the `base-kitex` / `base-hertz` template conventions).

> **Consumption status:** this package is a workspace-layout reference.
> `ncgo new --mode micro --template <package>` and `ncgo add rpc/bff
> --template-dir` land with ncgo micro workspace template support (follow-up).
> Today: `ncgo new --mode micro <name> --module <mod>` for the built-in path.
