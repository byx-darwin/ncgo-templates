# base-kitex

Official base **Kitex RPC** service template — standard layered layout with
health check, matching what `ncgo new --kind kitex` generates with built-in assets.

## Use

```bash
ncgo template pull base-kitex
ncgo new my-rpc --module github.com/acme/my-rpc --kind kitex --template base-kitex
```

## Contents

`kitex-template/*.yaml` mirrors the built-in ncgo kitex template set:
`main`, `conf`, `data`, `handler`, `usecase`, `repository`, `server`,
`interceptor` (+ tests), `client`, `rpcerror`, `migration`, `makefile`.

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.
