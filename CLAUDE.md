# Ralph-to-Ralph: Autonomous Product Cloner

## What This Is
A three-phase autonomous system that clones any SaaS product from just a URL.
Phase 1: Inspect (Claude + Ever CLI) → Phase 2: Build (Claude) → Phase 3: QA (Codex + Ever CLI)

## Tech Stack
- **Language & Framework**: Configured during onboarding (see `language` and `stackProfile` in `ralph-config.json`)
- **Styling & UI**: Installed during onboarding based on stackProfile
- **Database**: Installed during onboarding (default: Postgres)
- **Testing**: Installed during onboarding (template provides unit test + E2E config)
- **Linting**: Installed during onboarding (template provides linter config)

## Commands
All commands go through `make`. The Makefile is a contract — onboarding wires up real recipes based on your stack.
- `make check` — typecheck + lint/format
- `make test` — run unit tests
- `make test-e2e` — run E2E tests (requires dev server)
- `make all` — check + test
- `make dev` — start dev server on port 3015
- `make build` — production build
- `make db-push` — push schema to database

## Quality Standards
- Strict type checking enabled (language-specific: TypeScript strict, Go vet, etc.)
- Every feature must have at least one unit test AND one E2E test
- Run `make check && make test` before every commit
- Small, focused commits — one feature per commit

## Architecture
- `src/` (or language equivalent) — populated by onboarding based on stackProfile
- Source layout depends on the template — read `BUILD_GUIDE.md` (copied from template during setup) for stack-specific structure
- `tests/` — unit tests
- `tests/e2e/` — E2E tests
- `packages/sdk/` — SDK package (if target product has an SDK)
- `scripts/` — infrastructure and deployment scripts

## Pre-configured (DO NOT reinstall or recreate)
- **Makefile** — `make check`, `make test`, `make test-e2e`, `make all` (contract targets)
- **hack/run_silent.sh** — output formatting helper used by Makefile

## Stack Setup
- Onboarding writes `ralph-config.json` and runs `setup-stack.sh`
- The setup script copies template files, appends Makefile targets, installs dependencies
- Check `.ralph-setup-done` to see which template was used
- Read `BUILD_GUIDE.md` in the repo root for stack-specific build instructions

## Environment
- **Cloud CLI** — configure via onboarding (AWS, Vercel, GCP, Azure)
- **`.env`** — copy from `.env.example` and fill in your values

## Authentication

Check `authMode` in `ralph-config.json` before building any auth. If `authMode` is missing, default to `"api-key"`.

**`authMode: "api-key"`** (personal/solo use):
- Protect all API routes and the dashboard with a single `DASHBOARD_KEY` env var
- Check `Authorization: Bearer ${DASHBOARD_KEY}` in middleware
- No login/signup UI, no sessions, no user table needed

**`authMode: "better-auth"`** (multi-user):
- Use **Better Auth** (TypeScript) or equivalent auth library for other languages
- Match the target product's auth methods: email/password, OAuth providers, magic links
- Protect routes via middleware
- Auth is **P1 priority** — build it before core features

## Out of Scope — DO NOT build
- Paywalls, billing, subscription management
- Payment processing
