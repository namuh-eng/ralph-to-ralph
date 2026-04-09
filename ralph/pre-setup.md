# Pre-configured Setup — DO NOT recreate or reinstall

Everything listed here is already installed and configured. Do NOT reinstall, reconfigure, or overwrite these.

## Stack Profile

Check `stackProfile` in `ralph-config.json` before making framework and dependency decisions. The stack profile determines architecture — which services to initialize, how to structure `src/`, and which dependencies to install.

| `stackProfile` | Architecture | Key additions |
|---------------|-------------|---------------|
| `dashboard-app` | Next.js full-stack, API routes in `src/app/api/` | Better Auth (if multi-user) |
| `api-service` | Separate API server + Next.js frontend | Redis, BullMQ, SDK package |
| `platform` | Control plane (Next.js) + worker service | Redis Pub/Sub, CLI package |
| `content-app` | Next.js with ISR/SSG, editor + reader routes | Image storage, CDN headers |
| `realtime-app` | WebSocket server + Next.js frontend | Redis Pub/Sub, WS client |

See `ralph/stack-profiles.md` for the full architecture details of each profile.

If `stackProfile` is missing from `ralph-config.json`, default to `dashboard-app`.

## Tooling (Pre-configured — DO NOT reinstall)
- **Next.js 16** — `next.config.js` (standalone output for Docker, Turbopack)
- **TypeScript** — `tsconfig.json` (strict mode, `@/` path aliases)
- **Tailwind CSS** — `tailwind.config.ts` + `postcss.config.js` (dark mode, src paths)
- **Biome** — `biome.json` (lint + format, replaces ESLint/Prettier)
- **Vitest** — `vitest.config.ts` (jsdom, path aliases, `tests/*.test.ts`)
- **Playwright** — `playwright.config.ts` + Chromium installed (`tests/e2e/*.spec.ts`)
- **Drizzle ORM** — `drizzle.config.ts` + `src/lib/db/index.ts` + `src/lib/db/schema.ts`
- **Docker** — `Dockerfile` (multi-stage, standalone) + `.dockerignore`

## Commands (use these, don't create new ones)
- `make check` — typecheck + Biome lint/format
- `make test` — unit tests (Vitest)
- `make test-e2e` — E2E tests (Playwright, needs dev server)
- `make all` — check + test
- `make fix` — auto-fix lint/format issues
- `make db-push` — push Drizzle schema to Postgres
- `npm run dev` — dev server on port **3015**
- `npm run build` — production build

## AWS Infrastructure (provision with scripts/preflight.sh)
Run `bash scripts/preflight.sh` before starting the loop. It creates:
- **RDS Postgres** — database instance, connection string added to `.env`
- **S3** — storage bucket with CORS
- **ECR** — Docker image repository
- **SES** — email identity verification

## Cloudflare DNS (optional)
If you want auto-configure for domain verification, add to `.env`:
- `CLOUDFLARE_API_TOKEN` — API token with Edit zone DNS permission
- `CLOUDFLARE_ZONE_ID` — your domain's zone ID

## Project Structure (already scaffolded)
```
src/app/           — Next.js App Router (layout.tsx, page.tsx, globals.css)
src/app/api/       — API routes (created by build agent)
src/components/    — React components (created by build agent)
src/lib/           — Utilities and clients
src/lib/db/        — Drizzle ORM (index.ts + schema.ts ready)
src/types/         — TypeScript types
tests/             — Unit tests (Vitest)
tests/e2e/         — E2E tests (Playwright)
packages/sdk/      — SDK package (created by build agent if target has SDK)
ralph/screenshots/inspect/ — Original product screenshots
ralph/screenshots/build/   — Build verification screenshots
ralph/screenshots/qa/      — QA evidence screenshots
scripts/           — Infrastructure and deploy scripts
```

## Port
Dev server runs on **3015**. Do not change this.
