# Ralph-to-Ralph: Autonomous Product Cloner

## What This Is
A three-phase autonomous system that clones any SaaS product from just a URL.
Phase 1: Inspect (Claude + Ever CLI) → Phase 2: Build (Claude) → Phase 3: QA (Codex + Ever CLI)

## Tech Stack
- **Framework**: Determined during onboarding — installed by Claude based on target product (default: Next.js 16 App Router)
- **Language**: TypeScript strict mode, no `any` types
- **Styling**: Installed during onboarding (default: Tailwind CSS)
- **UI Components**: Installed during onboarding (default: Radix UI)
- **Database**: Installed during onboarding (default: Drizzle ORM + Postgres)
- **Unit Tests**: Vitest (pre-installed)
- **E2E Tests**: Playwright (pre-installed)
- **Linting**: Biome (pre-installed)

## Commands
- `make check` — typecheck + lint/format (Biome)
- `make test` — run unit tests (Vitest)
- `make test-e2e` — run E2E tests (Playwright, requires dev server)
- `make all` — check + test
- `npm run dev` — start dev server on port 3015
- `npm run build` — production build
- `npm run db:push` — push Drizzle schema to Postgres

## Quality Standards
- TypeScript strict mode, no `any` types
- Every feature must have at least one unit test AND one Playwright E2E test
- Run `make check && make test` before every commit
- Small, focused commits — one feature per commit

## Architecture
- `src/app/` — Next.js App Router pages and API routes
- `src/components/` — React components
- `src/lib/` — utilities, helpers, API clients
- `src/lib/db/` — Drizzle ORM schema and client
- `src/types/` — TypeScript types
- `tests/` — unit tests (Vitest)
- `tests/e2e/` — E2E tests (Playwright)
- `packages/sdk/` — TypeScript SDK package (if target product has an SDK)
- `scripts/` — infrastructure and deployment scripts

## Pre-configured (DO NOT reinstall or recreate)
- **Playwright** — `playwright.config.ts`, `tests/e2e/`, `npm run test:e2e`
- **Biome** — `biome.json`, fast lint + format
- **Makefile** — `make check`, `make test`, `make test-e2e`, `make all`

## Environment
- **AWS CLI** — configure via `aws configure`. `aws` commands and `@aws-sdk/*` packages work out of the box.
- **`.env`** — copy from `.env.example` and fill in your values

## Authentication

Check `authMode` in `ralph-config.json` before building any auth. If `authMode` is missing, default to `"api-key"`.

**`authMode: "api-key"`** (personal/solo use):
- Protect all API routes and the dashboard with a single `DASHBOARD_KEY` env var
- Check `Authorization: Bearer ${DASHBOARD_KEY}` in a Next.js middleware (`src/middleware.ts`)
- No login/signup UI, no sessions, no user table needed
- Do NOT install Better Auth

**`authMode: "better-auth"`** (multi-user):
- Use **Better Auth** — `npm install better-auth`
- Match the target product's auth methods: email/password, OAuth providers (Google, GitHub, etc.), magic links
- Protect routes via Next.js middleware (`src/middleware.ts`)
- Store sessions in Postgres via Better Auth's built-in Drizzle adapter
- Auth is **P1 priority** — build it before core features
- **Google OAuth setup**: redirect URI must be registered in Google Cloud Console:
  - Dev: `http://localhost:3015/api/auth/callback/google`
  - Prod: `https://your-domain.com/api/auth/callback/google`
  - OAuth consent screen must be "External" + Published, or test accounts must be added
  - For Ever CLI QA: the browser's logged-in Google account must be an authorized test user

## Out of Scope — DO NOT build
- Paywalls, billing, subscription management
- Payment processing
