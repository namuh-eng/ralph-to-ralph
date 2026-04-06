# Onboarding Guide: Clone Any SaaS Product

## TL;DR

Ralph-to-Ralph can now clone **any** SaaS product, not just Resend. Run `./ralph/onboard.sh` and it will ask you what to clone, research the target's API/docs, configure your cloud provider (AWS, GCP, or Azure), and start the autonomous build loop — zero manual config editing required.

---

## What Changed

Previously, Ralph-to-Ralph was hardwired to clone Resend.com on AWS. The database connection checked for `amazonaws.com` in the URL, the preflight script created Resend-specific resources, and the package.json had AWS SDK dependencies baked in.

Now there's an **onboarding layer** that runs before the build loop:

| Before | After |
|--------|-------|
| Edit 7+ config files by hand | `./ralph/onboard.sh` configures everything |
| AWS only | AWS, GCP, or Azure |
| Resend-specific schema/preflight | Clean slate, configured per target |
| `./scripts/start.sh <url>` | `./ralph/onboard.sh` (calls start.sh automatically) |

### Files Added
- **`ralph/onboard.sh`** — Entry point. Runs the Claude onboarding session, validates the output, starts the loop.
- **`ralph/onboard-prompt.md`** — The Claude prompt that drives the onboarding flow (9 steps: collect info → research → configure → verify → hand off).
- **`.env.example`** — Documents every environment variable the project uses.
- **`tests/db-ssl.test.ts`** — Tests for the SSL configuration fix.
- **`tests/drizzle-config.test.ts`** — Tests for the Drizzle config fix.
- **`tests/onboard-validation.test.ts`** — Tests for the onboard.sh validation logic.

### Files Changed
- **`src/lib/db/index.ts`** — SSL check uses `DB_SSL` env var instead of hostname detection.
- **`drizzle.config.ts`** — Same SSL fix.
- **`ralph/inspect-ralph.sh`** — Now reads `ralph-config.json` so the inspect agent knows the chosen cloud.
- **`ralph/build-ralph.sh`** — Now reads `ralph-config.json`.
- **`ralph/qa-ralph.sh`** — Now reads `ralph-config.json`.
- **`README.md`** — Updated quick start, FAQ, and project structure.
- **`.gitignore`** — Excludes generated `ralph-config.json`.

---

## Prerequisites

You need these tools installed and authenticated before running onboarding:

| Tool | Why | How to Install |
|------|-----|---------------|
| **Claude Code CLI** | Powers onboarding research, inspect, and build | `npm install -g @anthropic-ai/claude-code` + Anthropic API key |
| **Codex CLI** | Powers QA phase | `npm install -g @openai/codex` + `OPENAI_API_KEY` env var |
| **Ever CLI** | Browser automation for inspect + QA | Install from [foreverbrowsing.com](https://foreverbrowsing.com) |
| **Cloud CLI** | Provisions infrastructure | AWS: `aws configure` / GCP: `gcloud auth login` / Azure: `az login` |
| **Node.js 20+** | Runtime | `brew install node` or [nodejs.org](https://nodejs.org/) |

> **Minimum for onboarding only:** Claude Code CLI + your cloud CLI. Ever CLI and Codex are needed later for the inspect/QA phases.

---

## How to Use It

### 1. Clone the repo

```bash
git clone https://github.com/jaeyunha/ralph-to-ralph.git
cd ralph-to-ralph
```

### 2. Install dependencies

```bash
npm install
npx playwright install chromium
```

### 3. Set up your environment

```bash
cp .env.example .env
```

Edit `.env` with your cloud credentials. At minimum you need:
- `DATABASE_URL` — or let the preflight script create one
- `DB_SSL=true` — if using a managed Postgres (RDS, Cloud SQL, Azure)
- Cloud credentials for your provider (AWS CLI configured, or `gcloud auth login`, or `az login`)

### 4. Run onboarding

```bash
./ralph/onboard.sh
```

The onboarding agent will:

1. **Ask what to clone** — give it any SaaS product URL (e.g., `https://mintlify.com`, `https://linear.app`, `https://resend.com`)
2. **Ask your stack preference** — AWS (default), GCP (experimental), or Azure (experimental)
3. **Research the target** — reads the product's docs, API reference, SDKs, and data model
4. **Recommend a stack** — maps the target's capabilities to your cloud provider's services
5. **Ask you to confirm** — shows what it found, lets you adjust
6. **Generate `ralph-config.json`** — single source of truth for the entire pipeline
7. **Check dependencies** — verifies CLI tools and credentials are present
8. **Rewrite config files** — updates schema, preflight script, package.json, prompts, and more
9. **Install packages and start the loop** — calls `start.sh` automatically

### 5. Watch it build

The autonomous loop takes over:
- **Inspect** — Claude + Ever CLI browse the target, generate a PRD
- **Build** — Claude implements each feature with TDD
- **QA** — Codex + Ever CLI test everything against the original

No human intervention needed.

---

## Cloud Provider Support

| Provider | Status | CLI Required | Auth Check |
|----------|--------|-------------|------------|
| AWS | Stable | `aws` | `aws sts get-caller-identity` |
| GCP | Experimental | `gcloud` | `gcloud auth print-identity-token` |
| Azure | Experimental | `az` | `az account show` |

GCP and Azure paths generate the correct preflight scripts and SDK dependencies, but have not been battle-tested at the same level as AWS. If you hit issues, please open an issue.

---

## How ralph-config.json Works

The onboarding agent generates `ralph-config.json` — a single file that drives everything:

```json
{
  "targetUrl": "https://mintlify.com",
  "targetName": "mintlify-clone",
  "cloudProvider": "aws",
  "framework": "nextjs",
  "database": "postgres",
  "services": {
    "storage": { "provider": "s3", "package": "@aws-sdk/client-s3" }
  },
  "sdk": { "enabled": true, "languages": ["node"] },
  "research": {
    "apiEndpoints": ["POST /api/v1/docs/search", "..."],
    "authPattern": "Bearer API key",
    "summary": "Mintlify is a docs platform..."
  }
}
```

Every phase of the loop reads this file. The inspect agent uses it to map features to the right cloud services. The build agent uses it to import the right SDKs. The QA agent uses it to validate cloud-specific code.

---

## Troubleshooting

**Onboarding says "ONBOARD_FAILED"**
→ Read the error output. It will list exactly which dependencies are missing and how to install them. Fix them and re-run `./ralph/onboard.sh`.

**Onboarding doesn't complete (no promise tag)**
→ The Claude session may have hit the 30-minute timeout or a context limit. Re-run `./ralph/onboard.sh` — it's idempotent.

**Tests fail after onboarding**
→ Run `make check && make test` to see what's wrong. The onboarding agent should leave the project in a passing state, but if it doesn't, the error output will guide you.

**Want to change cloud provider after onboarding?**
→ Delete `ralph-config.json` and re-run `./ralph/onboard.sh`. It will start fresh.
