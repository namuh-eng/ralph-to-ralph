# go-chi template

## Stack
- Language: Go
- Framework: chi
- Test runner: go test
- E2E: add stack-specific smoke coverage later via documented make targets

## Commands
- Dev server: `make dev`
- Checks: `make check`
- Tests: `make test`
- Build: `make build`

## Layout
- Entrypoint: `cmd/server/main.go`
- Router: `internal/http/router.go`
- Tests: standard Go `*_test.go`

## Notes
- Prefer `make` targets over raw CLI commands.
- Expose future browser/E2E coverage through `make test-e2e` when available.
