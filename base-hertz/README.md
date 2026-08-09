# base-hertz

Official base **Hertz HTTP** service template — standard layered layout with
health check, matching what `ncgo new --kind hertz` generates with built-in assets.

## Use

```bash
ncgo template pull base-hertz

# With database support (recommended)
ncgo new my-api --module github.com/acme/my-api --kind hertz --db postgres --template base-hertz

# Without database support (limited functionality)
ncgo new my-api --module github.com/acme/my-api --kind hertz --template base-hertz
```

**Note:** This template includes database-related templates (repository, usecase, sqlc).
For full functionality, use with `--db postgres`. Without `--db`, some generated files
may reference database code that requires manual setup.

## Contents

`hertz-template/*.yaml` mirrors the built-in ncgo hertz template set:
`main`, `conf`, `data`, `server`, `middleware`, `repository`, `usecase`,
`errcode`, `response`, `makefile`, `sqlc`.

Variables: `{{.Module}}`, `{{.ServiceName}}`, `{{ToLower .ServiceName}}`.

## Features

- **Health Check**: Built-in `/healthz` and `/readyz` endpoints
- **Standard Layout**: Follows ncgo's layered architecture
- **Database Support**: Repository and usecase patterns with sqlc
- **Rate Limiting**: Configurable rate limiting middleware
- **Middleware Stack**: CORS, error handling, authentication, etc.
