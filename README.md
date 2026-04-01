<div align="center">

# Ralph-to-Ralph

**Give it a URL. Get back a deployed, full-stack clone.**

An autonomous pipeline that inspects any SaaS product, builds a working clone with real cloud infrastructure, tests everything, and deploys it — no human in the loop.

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![TypeScript](https://img.shields.io/badge/TypeScript-strict-blue?logo=typescript&logoColor=white)](https://www.typescriptlang.org/)
[![Next.js](https://img.shields.io/badge/Next.js-16-black?logo=next.js&logoColor=white)](https://nextjs.org/)
[![Built at Ralphthon Seoul](https://img.shields.io/badge/Built_at-Ralphthon_Seoul_2026-orange)](https://ralphthon.com)

![Architecture](docs/architecture-diagram.png)

<br>

<!-- Replace the src below with the GitHub CDN URL after dragging docs/demo.mp4 into a PR comment -->
<video src="docs/demo.mp4" width="100%" autoplay loop muted playsinline>
  Your browser doesn't support video — <a href="docs/demo.mp4">watch the demo here</a>.
</video>

</div>

---

## Proof It Works

We pointed Ralph-to-Ralph at [resend.com](https://resend.com) during Ralphthon Seoul 2026 and walked away:

| Metric | Result |
|--------|--------|
| Features built | **52** |
| Lines of code | **24,000+** |
| Unit tests passing | **388** |
| Dashboard pages | **10** |
| API endpoints | **16+** |
| Total time | **~4 hours** (fully autonomous) |
| Human intervention | **Zero** |

The clone sends real emails via AWS SES, verifies real domains, auto-configures DNS via Cloudflare, and deployed itself to AWS App Runner. It placed **2nd** at the hackathon.

---

## Table of Contents

- [Why](#why)
- [How It Works](#how-it-works)
- [Quick Start](#quick-start)
- [What Gets Built](#what-gets-built)
- [Pipeline Deep Dive](#pipeline-deep-dive)
- [Customization](#customization)
- [Project Structure](#project-structure)
- [FAQ](#faq)
- [Contributing](#contributing)
- [Team](#team)
- [License](#license)

---

## Why

Most AI coding demos produce toy apps — a single page with hardcoded data and no tests. We wanted to know: **can AI agents autonomously clone a real product, end-to-end, with real infrastructure?**

Ralph-to-Ralph is the answer. It doesn't scaffold a template or generate boilerplate. It browses the target product like a human would, writes a detailed PRD, implements every feature with TDD, stands up real cloud services, runs independent QA, and deploys. The entire pipeline runs unattended.

## How It Works

Ralph-to-Ralph is a three-phase autonomous pipeline managed by a watchdog orchestrator:

1. **Inspect** (Claude + [Ever CLI](https://foreverbrowsing.com)) — Browses the target product, extracts documentation, captures screenshots, and generates a detailed PRD with 50+ features
2. **Build** (Claude) — Implements each feature one-by-one with TDD, real cloud infrastructure (AWS SES, RDS Postgres, S3), and commits after every feature
3. **QA** (Codex + [Ever CLI](https://foreverbrowsing.com)) — An independent evaluator that tests every feature against the original product, finds bugs, fixes them, and verifies the results

The **watchdog orchestrator** ties it all together with auto-restart on failure, git commit + push after every iteration, and a build-QA-fix loop that runs up to 5 cycles until everything passes.

## Quick Start

### Prerequisites

| Tool | Purpose |
|------|---------|
| [Node.js 20+](https://nodejs.org/) | Runtime |
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | Powers Inspect + Build phases |
| [Codex CLI](https://github.com/openai/codex) | Powers QA phase |
| [Ever CLI](https://foreverbrowsing.com) | Browser automation for inspection and E2E testing |
| [AWS CLI](https://aws.amazon.com/cli/) | Cloud infrastructure (configured via `aws configure`) |
| Docker | Deployment |

### Run It

```bash
# Clone
git clone https://github.com/jaeyunha/ralph-to-ralph.git
cd ralph-to-ralph

# Install
npm install
npx playwright install chromium

# Configure
cp .env.example .env
# Edit .env with your AWS, Cloudflare, and other credentials

# Provision AWS infrastructure (RDS, SES, S3, ECR)
bash scripts/preflight.sh

# Go
./scripts/start.sh https://your-target-product.com
```

That's it. The system will inspect the target, build every feature with tests, QA everything independently, and deploy to AWS App Runner.

## What Gets Built

The loop produces a **fully functional, deployed product** — not a mockup.

| Capability | Implementation | When |
|------------|---------------|------|
| Full-stack web app | Next.js 16 + TypeScript | Always |
| REST API | Bearer token auth | Always |
| Database | RDS Postgres via Drizzle ORM | Always |
| Unit + E2E tests | Vitest + Playwright | Always |
| Deployment | Docker + AWS App Runner | Always |
| Email delivery | AWS SES | If the target sends emails |
| DNS management | Cloudflare API | If the target manages domains |
| File storage | AWS S3 | If the target handles uploads |
| TypeScript SDK | With React email support | If the target has an SDK |

## Pipeline Deep Dive

```
./scripts/start.sh https://target-product.com
         │
    Watchdog Orchestrator (auto-restart, git push, cron backup)
         │
         ▼
    ┌─────────────────────────────────────────────┐
    │  Phase 1: INSPECT                           │
    │  Claude + Ever CLI                          │
    │  → Browse target, capture screenshots       │
    │  → Extract docs and API structure           │
    │  → Generate prd.json (50+ features)         │
    │  → Write build-spec.md                      │
    └──────────────────────┬──────────────────────┘
                           │
                           ▼
    ┌─────────────────────────────────────────────┐
    │  Phase 2: BUILD                             │
    │  Claude (one feature per iteration)         │
    │  → TDD: write tests first, then implement   │
    │  → make check && make test                  │
    │  → git commit + push after each feature     │
    └──────────────────────┬──────────────────────┘
                           │
                           ▼
    ┌─────────────────────────────────────────────┐
    │  Phase 3: QA                                │
    │  Codex + Ever CLI                           │
    │  → Run Playwright regression suite          │
    │  → Ever CLI verification against original   │
    │  → Fix bugs and re-test                     │
    │  → Compare output with target product       │
    └──────────────────────┬──────────────────────┘
                           │
                           ▼
                  All features pass?
                   /            \
                 Yes             No
                  │               │
                  ▼               ▼
    ┌──────────────────┐  ┌──────────────────┐
    │  DEPLOY          │  │  FIX + REBUILD   │
    │  Docker → ECR    │  │  (up to 5 loops) │
    │  → App Runner    │  │  then re-QA      │
    │  → Live URL      │  └───────┬──────────┘
    └──────────────────┘          │
                                  └──→ back to Phase 2
```

### AI Agents

| Agent | Role | Phase |
|-------|------|-------|
| Claude | Inspect the target product and build the clone | 1, 2 |
| [Codex](https://github.com/openai/codex) | Independent QA evaluation | 3 |
| [Ever CLI](https://foreverbrowsing.com) | Browser automation for inspection and E2E testing | 1, 3 |

## Customization

### Changing the target

```bash
./scripts/start.sh https://any-saas-product.com
```

### Cloud credentials

Edit `.env` to configure:
- **AWS** — SES, RDS, S3, App Runner (required)
- **Cloudflare** — Auto-configuring DNS records (optional)

### Modifying agent behavior

The system is controlled by prompt files you can edit:

| File | Controls |
|------|----------|
| `inspect-prompt.md` | How the inspect agent analyzes the target |
| `build-prompt.md` | How the build agent implements features |
| `qa-prompt.md` | How the QA agent tests features |
| `pre-setup.md` | Pre-configured setup context (read by all agents) |

## Project Structure

```
ralph-to-ralph/
├── scripts/
│   ├── start.sh                # Entry point — starts the loop
│   ├── preflight.sh            # Provisions AWS infrastructure
│   └── generate-demo-keys.sh   # Generate API keys for demos
├── ralph-watchdog.sh           # Orchestrator (inspect → build → QA loop)
├── inspect-ralph.sh            # Phase 1 runner
├── build-ralph.sh              # Phase 2 runner
├── qa-ralph.sh                 # Phase 3 runner
├── inspect-prompt.md           # Inspect agent instructions
├── inspect-spec.md             # Inspection strategy
├── build-prompt.md             # Build agent instructions
├── qa-prompt.md                # QA agent instructions
├── pre-setup.md                # Pre-configured setup (read by agents)
├── ever-cli-reference.md       # Ever CLI command reference
├── CLAUDE.md                   # Instructions for Claude agents
├── AGENTS.md                   # Instructions for Codex QA agent
├── prd.json                    # Product requirements (generated)
├── src/                        # Next.js app (built by build agent)
├── tests/                      # Unit tests (Vitest)
├── tests/e2e/                  # E2E tests (Playwright)
├── packages/sdk/               # TypeScript SDK (if applicable)
└── Dockerfile                  # For deployment
```

## FAQ

<details>
<summary><strong>How much does a run cost in API credits?</strong></summary>

A full run (inspect + build + QA) against a complex product like Resend costs roughly $30–60 in combined Claude and Codex API usage, depending on feature count and how many QA fix cycles are needed.
</details>

<details>
<summary><strong>Does it work on non-SaaS products?</strong></summary>

It's optimized for SaaS products with dashboards, APIs, and documentation. Static sites or native apps won't produce great results. The inspect phase needs browsable UI and ideally public docs to generate a meaningful PRD.
</details>

<details>
<summary><strong>What if a phase fails?</strong></summary>

The watchdog orchestrator automatically restarts failed phases (up to 5 times for inspect, 10 for build). It also commits progress after every iteration, so you never lose work. If it exhausts retries, it stops and you can inspect the logs.
</details>

<details>
<summary><strong>Can I skip phases?</strong></summary>

Yes. If you already have a `prd.json`, you can run the build and QA phases directly by calling `./build-ralph.sh` and `./qa-ralph.sh` individually. Each phase is a standalone script.
</details>

<details>
<summary><strong>Can I use this without AWS?</strong></summary>

AWS is required for the full pipeline (RDS for database, SES for email, S3 for storage, App Runner for deployment). You could modify the prompts and `preflight.sh` to target a different cloud provider, but that's not supported out of the box.
</details>

## Contributing

We welcome contributions! Whether it's bug fixes, new features, documentation improvements, or ideas for new target products to test against — all contributions are appreciated.

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run `make check && make test` to verify
5. Commit with a clear message
6. Open a pull request

If you're unsure about a change, open an issue first to discuss it.

## Team

Ralph-to-Ralph was built by:

- **Jaeyun Ha** — [github.com/jaeyunha](https://github.com/jaeyunha)
- **Ashley Ha** — [github.com/ashley-ha](https://github.com/ashley-ha)

Built at [Ralphthon Seoul 2026](https://ralphthon.com).

---

<div align="center">

If you find this project interesting, consider giving it a star. It helps others discover it.

</div>

## License

[Apache License 2.0](LICENSE) — use it, modify it, ship it. Includes an explicit patent grant.
