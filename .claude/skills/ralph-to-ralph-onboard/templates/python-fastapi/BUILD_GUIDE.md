# python-fastapi template

## Stack
- Language: Python
- Framework: FastAPI
- Test runner: pytest
- E2E: pytest smoke or provider-specific browser tests when added later

## Commands
- Install deps: `pip install -e ".[dev]"`
- Dev server: `make dev`
- Checks: `make check`
- Tests: `make test`
- Build: `make build`

## Layout
- App entrypoint: `app/main.py`
- Tests: `tests/`
- Docs: FastAPI OpenAPI at `/docs`

## Notes
- Prefer `make` targets over raw CLI commands.
- If browser/E2E tooling is added later, document it here and expose it via `make test-e2e`.
