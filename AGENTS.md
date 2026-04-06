# Ralph-to-Ralph: QA Agent Guide

## Your Role
You are the independent QA evaluator. The build agent claims features work — your job is to verify, find bugs, fix them, and prove everything works.

## What This Is
An autonomously-built clone of a SaaS product. It has its own backend (AWS services + Postgres) and is deployed to AWS. Your job is to make sure it actually works.

## Commands
- `make check` — typecheck + Biome lint/format. Run after every code change.
- `make test` — run unit tests (Vitest). Must all pass.
- `make test-e2e` — run Playwright E2E tests. Run FIRST before manual testing.
- `make all` — check + test
- `npm run dev` — start dev server (if not already running)

## How To Test

### Step 1: Automated regression (fast)
Run `make test-e2e` first. This catches obvious breakage in seconds.

### Step 2: Manual verification (Ever CLI)
- `ever snapshot` — see current page state
- `ever click <id>` — click elements
- `ever input <id> <text>` — fill inputs
- Read `ralph/ever-cli-reference.md` for full command reference

### Step 3: Real API testing
Test the clone's API directly:
```bash
curl -X POST http://localhost:3015/api/<endpoint> \
  -H "Authorization: Bearer <dev-api-key>" \
  -H "Content-Type: application/json" \
  -d '{"<request body>"}'
```
Check `build-progress.txt` or API routes for the dev API key and available endpoints.

### Step 4: SDK testing (if packages/sdk/ exists)
```bash
cd packages/sdk && npm test
```
Test the SDK manually: import it, call the API, verify response.

## Architecture
- `src/app/` — Next.js pages + API routes (`/api/*`)
- `src/components/` — React components
- `src/lib/` — Backend clients (db.ts, ses.ts, s3.ts, etc.)
- `tests/` — unit tests (Vitest)
- `tests/e2e/` — E2E tests (Playwright)
- `packages/sdk/` — TypeScript SDK package

## Environment
- AWS CLI configured via `~/.aws/credentials` (works out of the box)
- `.env` has credentials (DATABASE_URL, Cloudflare, etc.)
- Dev server on port **3015**

## Bug Fixing Rules
- Fix bugs directly in source code
- Fix ALL bugs for a feature, then run `make check && make test` once before committing
- Commit fixes: `git commit -m "fix: <description>"`
- Push after every commit: `git push`
- **NEVER weaken or delete tests to make them pass.** Fix the code, not the test.
