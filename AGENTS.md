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

## QA Sub-Phases

Every feature is tested across four sub-phases. Run them in order; skip only if genuinely not applicable.

### Sub-Phase A: FUNCTIONAL
Automated and manual verification that the feature works as specified.
- Run `make test` (unit tests) and `make test-e2e` (Playwright E2E)
- Authenticate via Ever CLI: `ever start --url http://localhost:3015`
- Navigate to the feature page, `ever snapshot`, follow PRD acceptance criteria
- Test edge cases: empty inputs, rapid clicks, unexpected data
- If auth is required: set up Playwright auth fixture (`tests/e2e/auth.setup.ts`) — never skip

### Sub-Phase B: API CONTRACT
Verify every API endpoint for this feature returns correct shapes, status codes, and error formats.
- Discover endpoints per your stack (see `BUILD_GUIDE.md`). For Next.js App Router: `find src/app/api -name "route.ts" | sort`.
- Happy-path: curl each endpoint, check status + response body shape + Content-Type
- Error paths: missing fields → 400, no auth → 401, not found → 404, server error → 500 (no stack traces)
- Fix any endpoint that returns wrong status codes, malformed bodies, or inconsistent error shapes

### Sub-Phase C: SECURITY
Targeted checks for the most impactful vulnerabilities.
- **Auth bypass**: curl every endpoint without a token — must return 401, never 200 with data
- **Input sanitization**: probe SQL injection and XSS payloads — no errors leaked, no raw HTML reflected
- **CORS**: OPTIONS request with `Origin: https://evil.com` — `Access-Control-Allow-Origin` must not echo it back
- **Data exposure**: responses must never leak passwords, stack traces, or env variable values
- Fix all critical/major security findings before moving on

### Sub-Phase D: ACCESSIBILITY
axe-core scan + manual spot-checks for WCAG 2.1 AA compliance. JS/TS stacks only — for other stacks, do manual spot-checks only.
- `@axe-core/playwright` is pre-installed by `qa-ralph.sh` for JS stacks (no need to install inside Codex)
- Run axe scan via Playwright on every page touched by the feature (tags: wcag2a, wcag2aa, wcag21a, wcag21aa)
- Manual checks via Ever CLI: keyboard navigation, form labels, aria associations, color contrast
- Fix critical violations; log serious/moderate as known issues in qa-report.json

## How To Test (Quick Reference)

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
