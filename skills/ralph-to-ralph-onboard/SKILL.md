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
- **Likely tech stack** — check their engineering blog, job listings (`site:lever.co "resend"`, `site:greenhouse.io "resend"`), GitHub org if open source, StackShare profile
- **Third-party services** — what do they use for email, storage, search, payments, auth, analytics? Look for clues in their pricing page, docs, and job listings
- **Scale signals** — are they a tiny indie tool or a massive platform? This affects what's realistic to clone

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

**Out of scope (not worth attempting):**
- [list anything that's genuinely hard: ML models, real-time infra at scale, deeply integrated third-party moats]

**Complexity:** Simple / Medium / Complex — and a one-line reason why.

If the product is clearly not feasible (e.g. "clone OpenAI"), say so honestly and suggest a scoped-down version.

---

## Phase 4: Stack Walkthrough

Don't just list packages. Explain what each thing does for THIS specific product.

For each service or tool the clone will need, say:
- What it does in the context of this product (not a generic description)
- Whether the user needs to create an account / sign up for something
- How hard that setup is (easy = 2 clicks, medium = 15 minutes, hard = requires domain verification or billing)

**Format example:**

> **AWS SES** — this is how we'll send emails. Resend is literally an email API on top of SES, so we're building the same thing. You'll need an AWS account (free tier works for low volume) and to verify your sending domain. Takes about 15 minutes. I'll automate the provisioning — you just need the account.

> **Neon** — serverless Postgres for the database. Free tier, no setup needed beyond creating an account at neon.tech. Takes 2 minutes.

Cover: framework, database, email, storage, search, any AI/ML services, auth (if needed), cloud deployment target.

Keep it to what's actually needed — don't pad with hypotheticals.

---

## Phase 5: Gather Preferences + Confirm

Now ask the remaining questions conversationally (don't fire them all at once):

1. **Clone name** — suggest one based on the URL. "I'll call it `resend-clone` — good with that, or something else?"

2. **Deployment target** — explain the options in terms of the user's situation:
   - "Vercel + Neon is the easiest — free tier, no ops, ready in minutes. Best if this is for personal use or you're just exploring."
   - "AWS ECS Fargate + RDS if you want something production-ready for a team — more setup, but the right architecture for real traffic."
   - "GCP or Azure if you're already in that ecosystem."
   - "Custom if you have your own infra — describe it and I'll figure it out."

3. **Browser agent** — for the inspect and QA phases:
   - "Ever CLI is the recommended option — it's a visual AI browser agent that lets me actually look at the product as I build. Install it at foreverbrowsing.com."
   - "Playwright works too if you'd rather not install another tool — it's already set up."
   - "Or describe your own setup."

4. **Deploy after build?** — "Should I deploy to production when the build is done, or keep it local for now?"

Then show a clean summary and ask for go-ahead:

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

Now follow the steps in @references/onboard-prompt.md, starting from **Step 3** (Technical Architecture Scan).

You already have the answers to Steps 1 and 2 from the conversation above — use them directly, don't ask again.

As you work, narrate progress so the user isn't staring at a blank screen:
- "Researching Resend's architecture..." (already done — summarize what you found)
- "Writing ralph-config.json..."
- "Installing dependencies..." (run npm install in background)
- "Rewriting config files..."

When done, launch the build loop:

```bash
if command -v tmux &>/dev/null; then
  tmux new-session -d -s ralph-loop -c "$(pwd)" \
    "bash ./ralph-watchdog.sh '$TARGET_URL' 2>&1 | tee ralph-watchdog.log"
  echo "Build loop started in tmux session 'ralph-loop'."
  echo "Watch it: tmux attach -t ralph-loop"
  echo "Or tail:  tail -f ralph-watchdog.log"
else
  echo "Run this in a new terminal tab to start the build loop:"
  echo ""
  echo "  ./ralph-watchdog.sh '$TARGET_URL'"
  echo ""
  echo "(Logs will stream to your terminal. Ctrl+C stops it.)"
fi
```

If the browser agent requires Ever CLI and it's not installed, show that message first before attempting to launch:
- "Install Ever CLI at foreverbrowsing.com, then start the loop."

---

## Notes for edge cases

- **User gives a very broad product** (e.g. "clone Notion"): scope it down. "Notion is huge — I can build the core: pages, blocks, basic nesting, and a simple API. The full product would take months. Want me to scope to the essentials?"
- **User gives a non-SaaS product** (e.g. "clone a game"): explain this is designed for web SaaS products, suggest a pivot if appropriate.
- **Research fails** (product is too obscure or behind a login wall): work with what you can find, flag the gaps, and ask the user to fill them in.
- **User is clearly non-technical**: skip package names. Say "I'll set up the email service" not "I'll install @aws-sdk/client-sesv2". The technical details are in Phase 6, not Phase 4.
