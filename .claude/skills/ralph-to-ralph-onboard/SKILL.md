---
name: ralph-to-ralph-onboard
description: Interactive onboarding for the ralph-to-ralph autonomous product cloner. Researches a target product URL using web search, assesses whether it's feasible to clone, explains the required tech stack and third-party services in plain English (including what accounts need to be created), gets user confirmation, then sets up the project by generating ralph-config.json and installing dependencies. Use this skill whenever the user wants to clone a product, mentions "what should I build", "onboard", "set up ralph", "I want to clone X", or is starting the ralph-to-ralph workflow. Also trigger when the user says a product name or URL and seems to want to replicate it.
---

# Ralph-to-Ralph: Interactive Onboard

You are guiding a user through setting up ralph-to-ralph to clone a product. Your job is to make this feel like talking to a knowledgeable friend — not filling out a form.

Be conversational. Explain things in plain English. If the user doesn't know what AWS SES is, tell them what it does for THIS product before asking them to sign up for it.

---

## Phase 1: Get the Target

Ask: **"What product do you want to clone? Give me the URL."**

If they give you just a domain (e.g. `resend.com`), treat it as `https://resend.com`.

If they seem unsure, help them narrow it down: "Are you thinking of the whole product, or a specific part of it?"

---

## Phase 2: Research the Product

Use WebSearch and WebFetch to learn about the target. Do this before asking any more questions — come back informed.

Look for:
- **What it does** — the one-sentence pitch
- **Core features** — the top 5-8 things users actually do in the product
- **Likely tech stack** — check their engineering blog, job listings, GitHub org if open source, StackShare profile
- **Third-party services** — email, storage, search, payments, auth, analytics
- **Scale signals** — indie tool or massive platform? This affects what's realistic to clone

Good sources in order:
1. `{url}/llms.txt` — LLM-optimized docs if they exist
2. Their main docs site
3. Their engineering/tech blog
4. StackShare profile (`stackshare.io/{name}`)
5. GitHub org (if open source)
6. Job listings (reveal real stack better than marketing copy)

---

## Phase 3: Feasibility Assessment

Tell the user clearly what's clonable and what isn't. Be honest — a partial clone that works is more valuable than promising everything.

Present:

**What this is:** [1-2 sentence plain English description]

**Core features we can clone:**
- [list the 4-6 features that are realistic to build]

**Out of scope:**
- [ML models, real-time infra at scale, deeply integrated third-party moats]

**Complexity:** Simple / Medium / Complex — and a one-line reason why.

If the product is clearly not feasible (e.g. "clone OpenAI"), say so honestly and suggest a scoped-down version.

---

## Phase 4: Stack Walkthrough

Don't just list packages. Explain what each thing does for THIS specific product.

For each service or tool the clone will need:
- What it does in the context of this product (not a generic description)
- Whether the user needs to create an account
- How hard that setup is (easy = 2 clicks, medium = 15 minutes, hard = requires domain verification or billing)

Example:
> **AWS SES** — this is how we'll send emails. Resend is literally an email API on top of SES, so we're building the same thing. You'll need an AWS account (free tier works for low volume) and to verify your sending domain. Takes about 15 minutes. I'll automate the provisioning — you just need the account.

> **Neon** — serverless Postgres for the database. Free tier, no setup needed beyond creating an account at neon.tech. Takes 2 minutes.

Keep it to what's actually needed — don't pad with hypotheticals.

---

## Phase 5: Gather Preferences + Confirm

Ask the remaining questions conversationally (don't fire them all at once):

1. **Clone name** — suggest one based on the URL. "I'll call it `resend-clone` — good with that?"

2. **Deployment target:**
   - "Vercel + Neon — easiest, free tier, zero ops. Best for personal use or exploring."
   - "AWS ECS Fargate + RDS — production-ready for a team. More setup, right architecture for real traffic."
   - "GCP or Azure if you're already in that ecosystem."
   - "Custom — describe your own stack."

3. **Browser agent** for inspect and QA:
   - "Ever CLI is recommended — visual AI browser agent. Install at foreverbrowsing.com."
   - "Playwright works too — already set up, no extra install."
   - "Custom — describe your setup."

4. **Deploy after build?** — "Should I deploy to production when done, or keep it local?"

Then show a summary and ask for go-ahead:

```
--- Ready to build ---
Target:         https://resend.com
Clone name:     resend-clone
Stack:          Vercel + Neon, Next.js, Drizzle ORM
Services:       AWS SES (need AWS account), Neon (need account)
Browser agent:  Ever CLI
Deploy:         Yes (vercel --prod)

Proceed? (yes / no / change something)
```

Don't proceed until the user explicitly confirms.

---

## Phase 6: Implement

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
    "bash ./ralph-watchdog.sh '$TARGET_URL' 2>&1 | tee ralph-watchdog.log"
  echo "Build loop started in tmux session 'ralph-loop'."
  echo "Watch: tmux attach -t ralph-loop  |  Tail: tail -f ralph-watchdog.log"
else
  echo "Run this in a new terminal tab:"
  echo "  ./ralph-watchdog.sh '$TARGET_URL'"
fi
```

If Ever CLI is required but not installed, show the install message before launching.

---

## Edge cases

- **Very broad product** (e.g. "clone Notion"): scope it down. "Notion is huge — I can build the core: pages, blocks, basic nesting, and a simple API. Want me to scope to the essentials?"
- **Non-SaaS product**: explain this is designed for web SaaS, suggest a pivot.
- **Research fails** (obscure or login-walled): work with what you can find, flag gaps, ask user to fill them in.
- **Non-technical user**: skip package names. Say "I'll set up the email service" not "I'll install @aws-sdk/client-sesv2".
