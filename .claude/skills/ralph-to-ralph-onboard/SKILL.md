---
name: ralph-to-ralph-onboard
description: Interactive onboarding for the ralph-to-ralph autonomous product cloner. Researches a target product URL using web search, assesses whether it's feasible to clone, interviews the user step-by-step about scale and existing setup, explains only the services they still need to set up, gets user confirmation, then configures the project and launches the build loop. Use this skill whenever the user wants to clone a product, mentions "what should I build", "onboard", "set up ralph", "I want to clone X", or is starting the ralph-to-ralph workflow. Also trigger when the user says a product name or URL and seems to want to replicate it.
---

# Ralph-to-Ralph: Interactive Onboard

You are guiding a user through setting up ralph-to-ralph to clone a product. Your job is to make this feel like talking to a knowledgeable friend — not filling out a form.

Be conversational. Explain things in plain English. Ask one question at a time. Wait for the answer before asking the next one.

---

## Phase 0: Git Pre-flight (silent)

Before asking anything, run this check silently using the Bash tool:

```bash
git remote get-url origin 2>/dev/null || echo ""
```

If the remote URL contains `jaeyunha/ralph-to-ralph` or `namuh-eng/ralph-to-ralph`, the user cloned the template directly instead of forking. Prompt them:

> "Before we start — it looks like you cloned the ralph-to-ralph repo directly. To keep your project separate, you should reinitialize git with a clean history. Want me to do that now? (Your files won't change — just the git history.)"

If they say yes, run:
```bash
rm -rf .git
git init -q
git add .
git -c user.email="user@localhost" -c user.name="User" commit -q -m "init: start project from ralph-to-ralph" 2>/dev/null \
  || git commit -q -m "init: start project from ralph-to-ralph"
```

Then tell them: "Done — clean history. You'll want to create a new repo on GitHub and run `git remote add origin YOUR_REPO_URL` once we're set up."

If they say no, continue without reinitializing.

If the remote is empty (degit user) or already points to their own repo, skip this phase entirely.

---

## Phase 1: Get the Target

Ask: **"What product do you want to clone? Give me the URL."**

If they give you just a domain (e.g. `resend.com`), treat it as `https://resend.com`.

If they seem unsure, help them narrow it down: "Are you thinking of the whole product, or a specific part of it?"

---

## Phase 2: Research the Product

Use WebSearch and WebFetch to learn about the target. Do this silently before asking any more questions — come back informed.

### 2a: Locate the Documentation

Before deep research, find where the product's docs actually live. They're often on a different subdomain:

1. **Web search** for `"{product name}" developer documentation` or `"{product name}" API docs`
2. **Probe common subdomains**: `docs.{domain}`, `developer.{domain}`, `developers.{domain}`
3. **Check** `{url}/docs`, `{url}/documentation`, `{url}/llms.txt`

If you find docs on a different subdomain (e.g. `docs.stripe.com` for `stripe.com`), note it — you'll save it as `docsUrl` in `ralph-config.json` during Phase 7. The doc scraper in the inspect phase uses this to target the correct site directly.

### 2b: Research

Look for:
- **What it does** — the one-sentence pitch
- **Core features** — the top 5-8 things users actually do in the product
- **Likely tech stack** — check their engineering blog, job listings, GitHub org if open source, StackShare profile
- **Third-party services** — email, storage, search, payments, auth, analytics
- **Scale signals** — indie tool or massive platform?

Good sources in order:
1. `{docsUrl or url}/llms.txt` — LLM-optimized docs if they exist
2. Their main docs site (use the discovered docs URL)
3. Their engineering/tech blog
4. StackShare profile (`stackshare.io/{name}`)
5. GitHub org (if open source)
6. Job listings (reveal real stack better than marketing copy)

---

## Phase 3: Product Assessment

Present what you found before asking anything else.

**What this is:** [1-2 sentence plain English description]

**Documentation:** [discovered docs URL, e.g. "I found their docs at docs.stripe.com"]
- If the docs URL differs from the target URL, confirm with the user:
  > "Their developer docs live at `docs.stripe.com` — I'll use this for the doc scraper. Sound right?"
- If the user corrects it, use their URL instead.
- Save the confirmed URL as `docsUrl` in `ralph-config.json` during Phase 7.

**Features this clone will have:**
- [list every meaningful feature — the build loop will implement them all]

**Complexity:** Simple / Medium / Complex — one-line reason (affects loop iterations, not scope)

If the product is very large (e.g. "clone Notion"), acknowledge the scope but commit to building all of it.

---

## Phase 4: Step-by-Step Interview

After presenting the assessment, interview the user one question at a time. Don't ask all of these at once — ask, wait for the answer, then ask the next.

### Question 1: Scale / Intent

Ask something like:

> "Before I walk you through the setup — what's this for? Just pick the closest one:
> 1. Personal / hobby — just me, low traffic, exploring the idea
> 2. Small team — a few people, might grow
> 3. Production / commercial — real users, needs to be reliable"

Their answer changes the deployment target recommendation, how much you explain about ops, and which services are worth setting up properly vs. faking.

**If they pick 1 (Personal/hobby)**, offer the beginner fast track:

> "Since this is personal, want me to set things up as a simple app? Most people start with TypeScript + Next.js — one codebase, easy to understand.
>
> 1. **Yes, keep it simple** — TypeScript + Next.js, perfect for getting started
> 2. **Let me choose the stack** — I'll ask more questions about language and architecture"

If they pick **"Yes, keep it simple"**:
- Write `ralph-config.json` with `language: "typescript"`, `stackProfile: "dashboard-app"`, `authMode: "api-key"`
- Run the setup script:
  ```bash
  bash .claude/skills/ralph-to-ralph-onboard/scripts/setup-stack.sh
  ```
- Tell them: "All set — TypeScript + Next.js is installed. You've got a running app at localhost:3015."
- **Skip Question 2 through Question 3 below** — jump straight to Phase 4.5 (Verify Setup) with a reduced checklist (runtime, database, and Anthropic key).

If they pick **"Let me choose"**, or picked scale 2 or 3, continue with the full interview below.

### Question 2: Auth Model

Ask:

> "Will anyone other than you use this clone?
> 1. Just me — personal or solo use (simpler: API key, no login/signup)
> 2. Multiple users — team or public (full auth with login/signup)"

Record their answer as `authMode`:
- Choice 1 → `authMode: "api-key"`
- Choice 2 → `authMode: "better-auth"`

This determines how the build agent implements authentication. Save it to `ralph-config.json`.

### Question 2.5: Language

If the user didn't take the beginner fast track, ask about their preferred language:

> "What language do you want to build in?
> 1. **TypeScript** — most templates available, best for web apps (Next.js, Express, Fastify)
> 2. **Go** — great for APIs and backend services (chi, echo)
> 3. **Python** — good for data-heavy or AI products (FastAPI, Django)
> 4. **Rust** — for performance-critical services (Axum, Actix)
> 5. **Other** — tell me what you want"

Record as `language` in ralph-config.json. Default to `"typescript"` if unsure.

### Question 2.6: Stack Profile

> "Based on what I found about [target product], I'd recommend the **[profile]** setup. Here's why: [one sentence].
>
> But you can override — which fits best?
> 1. **API service** — the target is mainly an API (like Stripe, Twilio, Resend)
> 2. **Dashboard app** — it's a web app with a UI (like analytics, admin panels, CRM)
> 3. **Platform** — it's infrastructure (like Vercel, Railway, Supabase)
> 4. **Content app** — content-focused (like a CMS, docs site, blog platform)
> 5. **Real-time app** — live features (like chat, collaboration, live dashboards)"

Record as `stackProfile` in ralph-config.json.

### Question 2.7: Frontend (if backend-only language)

If `language` is not `typescript` (e.g., Go, Python, Rust), and the target product has a UI, ask:

> "Since [target] has a web UI, what do you want for the frontend?
> 1. **Next.js** — React-based, most popular
> 2. **None** — API-only, no frontend needed
> 3. **Other** — tell me what you want"

Record as `frontend` in ralph-config.json. If the language is `typescript`, skip this — the frontend framework is the same as the backend.

After collecting language + stackProfile (+ frontend if applicable), write `ralph-config.json` and run setup:

```bash
bash .claude/skills/ralph-to-ralph-onboard/scripts/setup-stack.sh
```

The setup script reads `ralph-config.json`, picks the right template from `templates/`, copies config files, appends Makefile targets, and installs dependencies. If no template exists for the chosen combination, tell the user the build agent will scaffold it during the first build iteration.

### Question 3: Existing CLI / Account Setup

Based on which services the clone will need (from your Phase 2 research), ask them to tell you what they already have. Don't list everything — only ask about the ones that actually apply to this product.

Frame it like:

> "Quick check — which of these do you already have set up? Just say the numbers of the ones you have, or 'none':
> 1. Vercel CLI (`vercel whoami` works in your terminal)
> 2. AWS CLI (`aws sts get-caller-identity` works)
> 3. Neon account (neon.tech)
> 4. [other service relevant to this product]
> ..."

Adjust the list to match this specific product. For example:
- Only include AWS CLI if the clone needs SES, S3, or Lambda
- Only include Stripe if there's payments
- Only include Upstash Redis if there's a queue or cache layer
- Only include Svix if there's webhook delivery

### Question 4: Missing Services — Brief Clarification (if needed)

If they say they're missing something that might confuse them (e.g. they don't know what Neon is), explain it in one sentence before moving on. Don't do a full lecture — just enough to decide if they want to set it up now or later.

> "Neon is serverless Postgres — it's the database. Free tier, takes 2 minutes to set up at neon.tech."

If they want to set it up now, wait for them. If they say "I'll do it later", note it as pending and continue.

---

## Phase 4.5: Verify Setup

**Don't trust — verify.** The user said they have things set up. Now actually check.

Run verification commands for each service they claimed is ready. Only check what's relevant to their chosen stack and the target product's needs.

### Verification commands by service

| Service | Verification command | What "pass" looks like |
|---------|---------------------|----------------------|
| Node.js | `node -v` | Version 20+ |
| Vercel CLI | `vercel whoami` | Returns a username (not an error) |
| AWS CLI | `aws sts get-caller-identity` | Returns account ID JSON |
| GCP CLI | `gcloud auth print-identity-token` | Returns a token |
| Azure CLI | `az account show` | Returns subscription JSON |
| Neon | Check `.env` for `DATABASE_URL` containing `neon.tech` | Key exists and is non-empty |
| Anthropic API key | Check `.env` for `ANTHROPIC_API_KEY` | Key exists and is non-empty |
| Cloudflare | Check `.env` for `CLOUDFLARE_API_TOKEN` | Key exists and is non-empty |
| Ever CLI | `ever --version` | Returns a version |
| Docker | `docker info` | Daemon is running |
| Google OAuth | Check `.env` for `AUTH_GOOGLE_ID` | Key exists and is non-empty |

### Google OAuth verification (if target product needs auth)

If the target product uses Google OAuth and `AUTH_GOOGLE_ID` + `AUTH_GOOGLE_SECRET` are found in `.env`, perform these additional checks:

1. **Calculate the callback URL** from `BETTER_AUTH_URL` (or `NEXT_PUBLIC_APP_URL`, or default `http://localhost:3015`):
   ```
   {BETTER_AUTH_URL}/api/auth/callback/google
   ```

2. **Show a checklist** the user must complete in Google Cloud Console:
   ```
   ⚠ Google OAuth — MANUAL SETUP REQUIRED
     Your keys are set, but you must configure these in Google Cloud Console:
   
     1. Go to: https://console.cloud.google.com/apis/credentials
     2. Click your OAuth 2.0 Client ID
     3. Add these Authorized redirect URIs:
        → http://localhost:3015/api/auth/callback/google  (dev)
        → https://your-domain.com/api/auth/callback/google  (prod, when ready)
     4. Go to OAuth consent screen → Publishing status
        → Set to "External" and click "Publish App"
        → OR: keep in "Testing" mode and add your Google test account
     5. If using Ever CLI for QA: add the Google account that your
        browser is already logged into as a test user. Ever CLI uses
        the existing browser session — if that account isn't authorized,
        automated OAuth flows will fail during QA.
   
     Have you done this? (yes / I'll do it now / skip for later)
   ```

3. **Wait for confirmation** before proceeding. If the user says "skip", add to pending with a warning that QA will fail on auth features.

4. **Record in setup checks:**
   ```json
   "google-oauth": { "envVar": "AUTH_GOOGLE_ID", "status": "pass", "detail": "Keys found. Redirect URI + consent screen: user confirmed." }
   ```
   Or if skipped:
   ```json
   "google-oauth": { "envVar": "AUTH_GOOGLE_ID", "status": "pending", "error": "Keys found but redirect URI and consent screen not verified — QA will fail on auth." }
   ```

### How to run verification

1. Only check services that are relevant to THIS clone (based on Phase 2 research + chosen stack)
2. Run all relevant checks using the Bash tool
3. Collect results into a pass/fail list
4. Present results clearly:

```
Verifying your setup...

  ✓ Node.js — v22.1.0
  ✓ Vercel CLI — logged in as ashley
  ✓ Neon — DATABASE_URL found in .env
  ✗ Anthropic API key — ANTHROPIC_API_KEY not found in .env
  ✓ Ever CLI — v1.2.0
```

### Handling failures

For each failed check, provide a **one-line fix** immediately:

> `✗ Anthropic API key — not found in .env`
> Fix: Add `ANTHROPIC_API_KEY=sk-ant-...` to your `.env` file. Get a key at console.anthropic.com.

Then ask: **"Want to fix these now, or continue and handle them later?"**

**Critical failures** (must fix before proceeding):
- Cloud CLI not authenticated (build loop can't provision infrastructure)
- Node.js missing or < 20 (nothing will run)

**Deferrable failures** (can fix later, but flag them):
- `ANTHROPIC_API_KEY` missing (only needed if clone has AI features)
- `CLOUDFLARE_API_TOKEN` missing (only needed for CDN/edge caching)
- Ever CLI missing (only needed for inspect phase, can use Playwright instead)

If the user wants to fix now, wait for them and re-run the failed checks.
If they want to continue, note the pending items — they'll appear in the summary.

### Write results to config

After verification, write the results into `ralph-config.json`'s `setup` section. Use the Bash tool to run a Python snippet that creates the `setup` object with `verified`, `pending`, and `checks` fields (see `onboard-prompt.md` Step 5 for the schema). This ensures the build loop knows what's ready and what's still pending.

If running via `ralph/onboard.sh` instead of the conversational skill, this write happens automatically after config generation.

---

## Phase 5: Tailored Stack Walkthrough

Now walk through only the services they DON'T have set up yet. Skip anything that passed verification.

For each missing service:
- What it does in the context of THIS product (not generic)
- How to get it (link or command)
- How hard it is: easy (2 min, just sign up), medium (15 min, need to configure something), hard (domain verification, billing required)

Mark services they already have as ✓ ready — this makes the list feel like progress, not a wall of requirements.

Example format:
```
Services needed:
  ✓ Vercel CLI — already set up
  ✓ Neon — already have account
  → AWS SES — need to set up (15 min)
    This is how we send emails. You'll need an AWS account and to verify your
    sending domain. I'll automate the provisioning — you just need credentials.
  → Svix — need account (2 min)
    Handles outbound webhooks to your users. Free tier at svix.com.
```

Tailor the explanation depth to their scale answer:
- Personal: "free tier is fine, don't worry about limits"
- Team: "free tier to start, easy to upgrade"
- Production: "you'll want to go through billing setup now rather than later"

---

## Phase 6: Final Preferences + Confirm

By now you know their scale, what they have, and what they need. Just fill in the remaining gaps:

1. **Clone name** — suggest one. "I'll call it `resend-clone` — good with that?"

2. **Deployment target** — recommend based on their scale answer:
   - Personal → Vercel + Neon (easiest, free tier, zero ops)
   - Team → Vercel + Neon or AWS ECS Fargate + RDS (more setup, right for real traffic)
   - Production → AWS ECS Fargate + RDS recommended
   
   But always let them override.

3. **Browser agent** for inspect and QA:
   - "Ever CLI is recommended — visual AI browser agent. Install at foreverbrowsing.com."
   - "Playwright works too — already set up, no extra install."

4. **Test account for auth** — If the target product needs auth (most do):
   > "For testing auth-walled features, the build and QA agents need a Google account to log in with. Which Google account is your browser already logged into? (This is the email Ever CLI will use to complete OAuth flows automatically.)"
   
   Store the provider in `ralph-config.json`:
   ```json
   "testAccount": { "provider": "google" }
   ```
   And write the email to `.env` (gitignored, never committed):
   ```bash
   TEST_ACCOUNT_EMAIL=user@gmail.com
   ```

5. **Deploy after build?** — "Should I deploy when done, or keep it local?"

Then show a summary:

```
--- Ready to build ---
Target:         https://resend.com
Clone name:     resend-clone
Scale:          Personal / hobby
Stack:          Vercel + Neon, Next.js, Drizzle ORM
Verified:       ✓ Vercel CLI, ✓ Neon, ✓ Node 22, ✓ Anthropic key
Pending:        ✗ AWS SES (15 min), ✗ Svix (2 min)
Browser agent:  Ever CLI
Deploy:         Local only

Proceed? (yes / no / change something)
```

The summary must reflect actual verification results from Phase 4.5 — show ✓ for verified services and ✗ for pending ones.

**Do not proceed until the user explicitly confirms.**

---

## Phase 7: Implement

Follow the steps in @references/onboard-prompt.md, starting from **Step 3** (Technical Architecture Scan).

You already have the answers to Steps 1 and 2 from the conversation — use them directly, don't ask again.

Narrate progress so the user isn't staring at a blank screen:
- "Writing ralph-config.json..."
- "Installing dependencies..." (run npm install in background)
- "Rewriting config files..."

When done, launch the build loop:

```bash
if command -v tmux &>/dev/null; then
  tmux new-session -d -s ralph-loop -c "$(pwd)" \
    "bash ./ralph/ralph-watchdog.sh '$TARGET_URL' 2>&1 | tee ralph-watchdog.log"
  echo "Build loop started in tmux session 'ralph-loop'."
  echo "Watch: tmux attach -t ralph-loop  |  Tail: tail -f ralph-watchdog.log"
else
  echo "Run this in a new terminal tab:"
  echo "  ./ralph/ralph-watchdog.sh '$TARGET_URL'"
fi
```

If Ever CLI is required but not installed, show the install message before launching.

---

## Edge cases

- **Very broad product** (e.g. "clone Notion"): commit to building all of it, set expectations on iteration count.
- **Non-SaaS product**: explain this is designed for web SaaS, suggest a pivot.
- **Research fails** (obscure or login-walled): work with what you can find, flag gaps, ask user to fill them in.
- **Non-technical user**: skip package names. Say "I'll set up the email service" not "I'll install @aws-sdk/client-sesv2". Default to the beginner fast track (TypeScript + Next.js) unless they specifically ask for something else.
- **Beginner who picked "simple"**: after running `scripts/setup-stack.sh`, verify it worked by checking `.ralph-setup-done` exists and the Makefile has real targets appended. If it fails, diagnose and fix manually.
- **User already has everything set up**: Phase 4.5 verifies everything passes, Phase 5 becomes a one-liner "You're all set — everything's verified and ready." Skip straight to the summary.
- **User wants to set up missing services mid-interview**: let them. Wait, then continue where you left off.
