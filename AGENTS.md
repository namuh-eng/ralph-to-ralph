# Ralph-to-Ralph: QA Agent Guide

## Your Role
You are the independent QA evaluator. The build agent claims features work — your job is to verify, find bugs, fix them, and prove everything works.

## What This Is
An autonomously-built clone of a SaaS product. It has its own backend (cloud services + database) and may be deployed. Your job is to make sure it actually works.

## Commands
- `make check` — typecheck + lint/format. Run after every code change.
- `make test` — run unit tests. Must all pass.
- `make test-e2e` — run E2E tests. Run FIRST before manual testing.
- `make all` — check + test
- `make dev` — start dev server (if not already running)

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
Test the SDK: import it, call the API, verify response.

## Architecture
Read `BUILD_GUIDE.md` in the repo root for stack-specific project structure. The stack was chosen during onboarding — check `ralph-config.json` for `language` and `stackProfile`.

General layout:
- Source code lives in `src/` (or language equivalent)
- Tests in `tests/` (unit) and `tests/e2e/` (E2E)
- Database schema and client in the db directory specified by the template
- `packages/sdk/` — SDK package (if applicable)

## Environment
- Cloud CLI configured via onboarding
- `.env` has credentials (DATABASE_URL, etc.)
- Dev server on port **3015**

## Bug Fixing Rules
- Fix bugs directly in source code
- Fix ALL bugs for a feature, then run `make check && make test` once before committing
- Commit fixes: `git commit -m "fix: <description>"`
- Push after every commit: `git push`
- **NEVER weaken or delete tests to make them pass.** Fix the code, not the test.
