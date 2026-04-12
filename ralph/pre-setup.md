# Pre-configured Setup — DO NOT recreate or reinstall

Everything listed here is already installed and configured. Do NOT reinstall, reconfigure, or overwrite these.

## Stack Profile

Check `stackProfile` in `ralph-config.json` before making framework and dependency decisions. The stack profile determines architecture — which services to initialize, how to structure source code, and which dependencies to install. Profiles are language-agnostic: the same profile applies regardless of whether `language` is `typescript`, `go`, `python`, etc.

| `stackProfile` | Architecture | Key additions |
|---------------|-------------|---------------|
| `dashboard-app` | Full-stack web app, server-rendered UI + API routes | Auth library (if multi-user) |
| `api-service` | Separate API server + frontend | Redis, job queue, SDK package |
| `platform` | Control plane + worker service | Redis Pub/Sub, CLI package |
| `content-app` | Web app with ISR/SSG, editor + reader separation | Image storage, CDN headers |
| `realtime-app` | WebSocket server + frontend | Redis Pub/Sub, WS client |

See `ralph/stack-profiles.md` for the full architecture details of each profile.

If `stackProfile` is missing from `ralph-config.json`, default to `dashboard-app`.

## Base Tooling (always present)
- **Makefile** — contract targets (`make check`, `make test`, `make dev`, etc.) with guard clause
- **hack/run_silent.sh** — output formatting helper sourced by Makefile targets
- **.gitignore** — universal ignores; language-specific entries appended by onboarding

## Stack Tooling (installed by onboarding)
Onboarding reads `ralph-config.json` and runs `setup-stack.sh`, which:
1. Copies config files from the matching template in `.claude/skills/ralph-to-ralph-onboard/templates/`
2. Appends real Makefile targets (typecheck, lint, test, dev, build, etc.)
3. Installs dependencies (`npm install`, `go mod download`, `pip install`, etc.)
4. Creates `.ralph-setup-done` marker file

Check `ralph-config.json` for `language` and `stackProfile` to know which template was used.
Read `BUILD_GUIDE.md` (copied from template) for stack-specific project structure and commands.

## Commands (use these, don't create new ones)
- `make check` — typecheck + lint/format
- `make test` — unit tests
- `make test-e2e` — E2E tests (needs dev server)
- `make all` — check + test
- `make fix` — auto-fix lint/format issues
- `make dev` — dev server on port **3015**
- `make build` — production build
- `make db-push` — push schema to database (if applicable)

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

## Project Structure (after onboarding)
```
src/               — source code (structure depends on template/BUILD_GUIDE.md)
tests/             — Unit tests
tests/e2e/         — E2E tests
packages/sdk/      — SDK package (created by build agent if target has SDK)
ralph/screenshots/inspect/ — Original product screenshots
ralph/screenshots/build/   — Build verification screenshots
ralph/screenshots/qa/      — QA evidence screenshots
scripts/           — Infrastructure and deploy scripts
```

## Port
Dev server runs on **3015**. Do not change this.
