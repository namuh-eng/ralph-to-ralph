# Inspect Spec — Written by Humans

## Goal
Thoroughly inspect a target web product and produce a complete build spec (`build-spec.md`) and feature list (`prd.json`) that another AI agent can use to build a working clone from scratch.

## Assumptions
- The user is ALREADY LOGGED IN to the target product in the browser.
- An Ever CLI session is ALREADY running. Do NOT run `ever start`.
- You have full access to all authenticated pages and features.
- You should actively USE the product, not just read pages passively.
- A `.env` file exists in the project directory with API keys for the target product. Read it to get credentials for testing API features directly (e.g., sending test requests via curl).

## Out of Scope — DO NOT include these in the PRD
- Paywalls, billing, subscription management
- Any payment processing

## Authentication — MUST include in the PRD
Login, signup, OAuth, magic links, email verification, and password reset are **in scope** and must be inspected and added as P1 PRD entries. See Phase A.2 in inspect-prompt.md for the full auth inspection strategy.

## SDK / Language Scope
If the target product offers SDKs or code examples in multiple languages (Python, Ruby, Go, etc.), ONLY include TypeScript/Node.js in the PRD. Ignore all other language SDKs.

For the clone:
- Build the web dashboard UI only
- If the product has an API, clone it as a Node.js/TypeScript API
- If the product shows code snippets to users, only show TypeScript/Node.js examples
- Skip any language-specific SDK pages during inspection

## Inspection Strategy

### Phase A: Docs Extraction (FAST — bulk download, no UI testing)
Before touching the UI, extract ALL available documentation. Docs tell you what the product does. UI tells you how it looks. This phase should be FAST — no clicking around.

**Goal:** Download every docs page into `target-docs/` directory, organized to match the original docs structure.

**Steps — try in this order (fastest first):**

**Method 1: llms.txt (BEST — check first)**
```bash
curl -s <site-url>/llms.txt          # Index with all doc URLs
curl -s <site-url>/llms-full.txt     # Full docs in one file (if available)
curl -s <site-url>/docs/llms.txt     # Some sites put it under /docs/
```
If `llms-full.txt` exists → save it as `target-docs/full-docs.md` and you're done.
If only the index exists → parse the URLs and fetch each page.

**Method 2: Jina Reader (fast, no install, handles JS)**
For each docs URL, prepend `r.jina.ai/`:
```bash
curl -s "https://r.jina.ai/<docs-page-url>" > target-docs/<page-name>.md
```
This returns clean markdown. No browser needed. Can be parallelized with `&` in bash.

**Method 3: sitemap.xml**
```bash
curl -s <site-url>/sitemap.xml
```
Parse URLs, then use Method 2 (Jina Reader) to fetch each page.

**Method 4: Ever CLI (last resort — slowest)**
Only use if the docs are behind auth or Methods 1-3 fail:
```bash
ever navigate <docs-url> && ever extract
```

**Directory structure** — mirror the original docs hierarchy:
```
target-docs/
├── INDEX.md              # List of all pages with one-line descriptions
├── overview.md
├── api-reference/
│   ├── emails/
│   │   ├── send-email.md
│   │   ├── list-emails.md
│   │   └── ...
│   ├── domains/
│   └── ...
├── guides/
└── changelog.md
```

**Create `target-docs/INDEX.md`** listing all extracted pages with one-line descriptions.

**Commit the docs extraction.**

**This phase should take 1-2 iterations MAX.** Bulk download everything, then move on to UI testing. Do NOT read pages one at a time with Ever CLI — that wastes iterations.

### Phase A.1: Onboarding Flow Discovery (during docs phase)

The logged-in user has likely ALREADY COMPLETED the target product's onboarding, so the onboarding UI (setup wizards, first-run guides, empty states) won't be visible during inspection. You MUST discover the onboarding flow from docs.

**Why this matters:** Onboarding is a core product feature, not an auth flow. The clone needs its own onboarding experience so new users know what to do after signing up.

**Step 1: Search the scraped docs**
Look through `target-docs/` for onboarding-related content:
- Quickstart / getting-started guides
- Setup wizards or first-run flows
- "Welcome" or "getting started" pages
- Empty state descriptions (what users see before they have data)

**Step 2: Use the docs search bar or AI assistant (if available)**
Many docs sites have a search bar or AI assistant (e.g., Mintlify's assistant, GitBook's search). If the docs don't have a dedicated onboarding page, use these to ask:
- "What is the onboarding process?"
- "What steps does a new user complete after signing up?"
- "What does the first-run experience look like?"

Use Ever CLI to interact with the search/assistant:
```bash
ever snapshot   # Find the search bar or assistant button
ever click <search-element>
ever type "onboarding process"
# Read the results / assistant response
ever snapshot
ever extract
```

Save the assistant's response to `target-docs/onboarding-flow.md`.

**Step 3: Document the onboarding flow**
Create `target-docs/onboarding-flow.md` (if not already created from Step 2) with:
- The step-by-step onboarding sequence
- What data/config the user provides at each step
- What the product looks like BEFORE the user has set anything up (empty states)
- Any skippable vs. required steps
- What "done" looks like (when does the user land on the main dashboard?)

**Step 4: Add onboarding PRD entries**
Add PRD entries for each onboarding step with category `"onboarding"`, priority P2-P3 (right after core infra/API). These should include:
- The onboarding wizard/flow UI
- Empty states for core features (what users see before they have data)
- Any first-run guided tours or tooltips

### Iteration 1: Site Map
1. `ever snapshot` the main dashboard to see all navigation links.
2. Map the COMPLETE site structure and save it to `sitemap.md`:
   - Every page in the navigation (sidebar, top nav, footer)
   - Sub-pages and tabs within each page
   - URLs for each page
   - Page type: list view, detail view, form, settings, etc.
3. Record the overall layout pattern (sidebar + content, top nav + pages, etc.).
4. Record the tech stack if detectable (check page source, network requests).
5. Take a screenshot of the main dashboard: `ever screenshot --output ralph/screenshots/home.jpg`

### Iterations 2-N: Feature-by-Feature Deep Dive (USE Ever CLI to test UI)
For each page/feature (one per iteration):
1. Navigate to the page.
2. `ever snapshot` to see all interactive elements.
3. `ever screenshot --output ralph/screenshots/<page-name>.jpg`
4. **Actively test the feature with Ever CLI:**
   - Click buttons, open modals, expand dropdowns
   - Fill forms with test data, observe validation and responses
   - Try CRUD operations (create, read, update, delete)
   - Test search/filter/sort if present
   - Check empty states, loading states, error states
   - Test pagination/infinite scroll
   - Note animations, transitions, toasts/notifications
   - Use API keys from `.env` to test API features via `curl`
5. Screenshot key states: `ralph/screenshots/<page-name>-<state>.jpg`
6. Cross-reference what you see in the UI with what the docs say — the docs describe the feature, the UI shows how it's presented.

### When to use what:
| Task | Tool |
|------|------|
| Reading docs/help pages | `ever extract` or `curl` (just read text) |
| Mapping site structure | `ever snapshot` (read nav links) |
| Testing UI interactions | `ever snapshot` → `ever click` → `ever snapshot` |
| Testing API features | `curl` with API key from `.env` |
| Capturing visual reference | `ever screenshot` |

### Every Iteration: Update build-spec.md Incrementally
After each inspection iteration, update `build-spec.md` with what you know so far. This file grows as you discover more:
- Add newly discovered pages to the site map
- Add newly observed colors, fonts, components to the design system
- Add newly discovered data fields to the data models
- Update the feature list with new entries
- Mark sections as "partial" or "complete" so future iterations know what's left

This ensures that if the inspect loop stops unexpectedly, there's still a usable (partial) spec.

### Final Iteration: Clean Up build-spec.md & Reorder PRD
Once all features are inspected, do a final cleanup pass on `build-spec.md`:
- Remove all "partial" markers
- Consolidate duplicate observations
- Ensure the design system is complete and consistent
- Write a clear product overview now that you've seen everything
- Finalize the tech stack recommendation

**Step 1: Identify the CORE features of this product.**
Before reordering, first answer: "What is this product's reason to exist? What are the 3-5 features that make it valuable?"

For example, if cloning an email API platform:
- Core: sending emails via API, viewing email logs, managing API keys
- Secondary: domains, webhooks, team settings
- Nice-to-have: analytics charts, contact lists

Or if cloning a CRM:
- Core: contacts list, deal pipeline, activity feed
- Secondary: reports, integrations, settings
- Nice-to-have: email templates, automation rules

The core features MUST be built first and get the most build iterations. If the loop runs out of time, the core features are done and the product is still useful.

**Step 2: Reorder prd.json by implementation order.**
Sort all entries so the build loop implements core features first:

1. Project scaffolding (package.json, config, framework setup)
2. Core layout shell (app container, routing, navigation skeleton)
3. Design system foundations (colors, typography, spacing, shared components)
4. Data models and state management for CORE features
5. **CORE FEATURES** — the 3-5 features that define what this product does
   (implement these end-to-end: UI + API + data + tests)
6. Primary pages and navigation for core features
7. Secondary features (search, filters, sorting)
8. Supporting features (settings, configurations)
9. Interactions (modals, dropdowns, tooltips, toasts)
10. Edge cases (empty states, loading states, error handling)
11. Polish (animations, transitions, responsive)

Add a `"priority"` field (1 = first to build) to each entry reflecting this order.
Also add a `"core"` field: `true` for the essential features, `false` for everything else.

**Step 2: Create `build-spec.md` containing:**
1. **Product Overview**: What the product does, who it's for
2. **Tech Stack Recommendation**: Based on what we observed, recommend the best stack for cloning
3. **Site Map**: All pages and their relationships
4. **Design System**: Colors, fonts, spacing, component patterns observed
5. **Data Models**: Entities and fields discovered from forms, tables, API responses
6. **Feature List**: Summary of all features referencing prd.json entry IDs
7. **Build Order**: The same priority order used to sort prd.json, with rationale

## Output Files

### prd.json
Array of feature entries, each with:
```json
{
  "id": "feature-001",
  "category": "ui|nav|auth|data|crud|search|settings|layout|interaction|sdk|developer-experience|onboarding",
  "description": "Clear description of the feature",
  "page": "Which page this belongs to",
  "ui_details": "Components, layout, colors, spacing",
  "behavior": "What happens when user interacts — observed by testing",
  "data_model": "Fields and types from forms/tables",
  "priority": 1,
  "core": true,
  "passes": false,
  "dependent_on": ["infra-001", "design-001"]
}
```

**DO NOT include test specs in prd.json.** The build agent writes its own tests based on `behavior` and `ui_details`. After building, the build agent logs what it tested and what needs deeper QA in `qa-hints.json` — the QA agent reads those hints.

**`dependent_on`** — list IDs of features this one depends on or shares components with (3-5 max). Examples:
- A detail page depends on its list page and shared data table
- An API route depends on the database schema and auth middleware
- A filter component depends on the page it's used on

### PRD Item Sizing — CRITICAL
Each PRD item must be small and focused. If a feature has too many steps, SPLIT it into multiple PRD items.

Rules:
- MAX 4-5 verification steps per PRD item
- MAX 2-3 unit tests per PRD item
- MAX 2 e2e tests per PRD item
- MAX 2 edge case tests per PRD item

If a feature is too big (e.g., "entire settings page"), break it into:
- "Settings page layout and navigation"
- "Settings: update display name"
- "Settings: change notification preferences"

Small PRD items = small commits = tight feedback loops = working product.

### build-spec.md
A comprehensive spec document that gives the build loop everything it needs to clone the product. This is the PRIMARY input for the build phase.

### ralph/screenshots/
Visual reference for every page and key interaction state.

### inspect-progress.txt
Running log of what was inspected each iteration — helps avoid re-inspecting.

## Rules
- ONE page/feature per iteration.
- Be thorough — capture colors, layouts, component types, exact text content.
- ACTIVELY USE the product — click, type, submit, navigate. Don't just look.
- Record BEHAVIOR you observe, not just UI structure.
- Always navigate back to unexplored sections each iteration.
- Commit after every iteration.
