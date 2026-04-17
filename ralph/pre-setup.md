# Pre-configured Setup — DO NOT recreate or reinstall

Everything listed here is already installed and configured. Do NOT reinstall, reconfigure, or overwrite these.

## Tooling
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

## Doc Scraper (Phase 1 only — auto-installed)
The inspect loop calls `scripts/scrape-docs.py` once before iteration 1 to populate `target-docs/` with the target product's documentation. The first time you run `./ralph/inspect-ralph.sh`, it will:
1. Create `.venv-scrape/` (Python venv, gitignored, **NOT** part of the generated clone)
2. `pip install -r scripts/scrape-docs-requirements.txt` (Scrapling + trafilatura + defusedxml)
3. Pre-fetch Playwright Chromium and Camoufox so JS-rendered / Cloudflare-protected doc sites work (warnings only if the download fails — static-HTML doc sites still scrape via plain HTTP)
4. Run the scraper and write `target-docs/` + `target-docs/coverage.json`
5. Touch `.venv-scrape/.install-complete` as a sentinel — a partial install (network drop, ^C) is detected and the venv is recreated on the next run

The skip guard requires both `coverage.json` AND `target-docs/INDEX.md` to be present before reusing the cached scrape. Delete either to force a re-scrape, or pass `--force` to `scrape-docs.py`.

If the scraper fails the inspect loop hard-stops with an exit-code-aware error message (gate failure, no docs discovered, dependency error). The venv only exists in the cloning workspace; the generated clone never depends on Python.

**Requirement:** `python3` (3.10+) on PATH. Default on macOS/Linux.

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
