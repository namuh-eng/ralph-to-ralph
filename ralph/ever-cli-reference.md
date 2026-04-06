---
name: ever-browser
description: "Ever CLI browser control reference — commands and workflows for programmatic browser automation. Use this skill whenever the user wants to control a browser programmatically, use `ever` CLI commands, automate web interactions (clicking, typing, navigating, extracting), run autonomous browser tasks, or debug browser session issues."
---

# Ever CLI — Browser Control

The `ever` CLI provides programmatic browser control through Chrome. Commands route: CLI → everd daemon → API server → extension CDPBridge → Chrome.

## Quick Start

```bash
ever start --url https://example.com   # Create browser session
ever snapshot                           # Capture DOM with [id] annotations
ever click 42                           # Click element with ID 42
ever snapshot                           # Re-capture to see changes
ever stop                               # End session
```

## Core Workflow: snapshot → act → snapshot

Every interaction follows this loop:

1. **`ever snapshot`** — capture annotated DOM with `[id]` markers on interactive elements (viewport + 500px buffer)
2. **Act** — perform action(s) using element IDs from the snapshot
3. **`ever snapshot`** — re-capture to see what changed (new elements marked with `*[id]` by default)

**IMPORTANT:** Always `snapshot` before interacting. Element IDs are only valid for the current snapshot. After page-changing actions (navigate, go-back, click on a link), you MUST snapshot again — old IDs are invalid.

## Reading Snapshots

Snapshot output uses a tree notation for interactive elements:

```
[id]<TAG attrs>text</TAG>          — interactive element (use id for actions)
*[id]<TAG>                         — NEW element since last snapshot
|SCROLL[id]<DIV>                   — scrollable container
|SHADOW(open)|[id]<INPUT>          — element inside shadow DOM
  [child_id]<TAG>                  — tab-indented = child of element above
```

- Only elements with `[id]` can be targeted by actions
- Tree indentation shows parent-child hierarchy
- `|SCROLL` marks elements you can scroll inside (use `ever scroll down --id <id>`)
- `|SHADOW` marks shadow DOM boundaries — elements inside still get IDs and are actionable

## Commands Reference

### Session Management
| Command | Description |
|---------|-------------|
| `ever start --url <url>` | Create session, navigate to URL |
| `ever stop` | Stop running task (preserves session) |
| `ever stop --session` | Force-end the session |
| `ever stop --all` | End all sessions |
| `ever sessions` | List active sessions |
| `ever use <n>` | Switch to session by index |
| `ever doctor` | Check everd, API server, extension connectivity |

### DOM & Navigation
| Command | Description |
|---------|-------------|
| `ever snapshot` | DOM capture with [id] annotations (viewport + 500px buffer). New elements since last snapshot marked with `*[id]`. |
| `ever snapshot --mode full` | Reset diff tracking — no `*` markers, clean slate |
| `ever navigate <url>` | Navigate to URL in current tab |
| `ever navigate <url> --new-tab` | Open URL in a new tab |
| `ever go-back` | Navigate back in browser history |
| `ever search <query>` | Search via Google (or `--engine bing\|duckduckgo\|brave`) |
| `ever tabs` | List tabs in session group |
| `ever switch-tab <tabId>` | Switch to a tab |
| `ever close-tab <tabId>` | Close a tab (cannot close the initial session tab) |

### Interaction
| Command | Description |
|---------|-------------|
| `ever click <id>` | Click element by snapshot index |
| `ever input <id> "text"` | Type text into an input element |
| `ever input <id> "text" --clear` | Clear field first (Select All + Delete), then type |
| `ever input <id> "text" --delay 50` | Type with delay between keystrokes (ms) |
| `ever send-keys "Enter"` | Send keyboard key (Enter, Tab, Escape, Space, Backspace, etc.) |
| `ever send-keys "Control+a"` | Send keyboard shortcut (modifier combos) |
| `ever send-keys "F2" --char-events` | Use char event sequence (needed for Google Sheets, contenteditable) |
| `ever scroll down` | Scroll down one page |
| `ever scroll up --amount 0.5` | Scroll up half a page |
| `ever scroll down --amount 10` | Jump to bottom |
| `ever scroll down --id 42` | Scroll inside a specific scrollable element |
| `ever wait <seconds>` | Wait for a duration (0-60s). For page loads, animations, timers. |
| `ever eval "expression"` | Execute JavaScript in page context (escape hatch for custom interactions) |

### Dropdown Handling

Native `<select>` elements cannot be clicked directly. Use these instead:

| Command | Description |
|---------|-------------|
| `ever get-dropdown-options <id>` | List all options with text, value, selected state, disabled status |
| `ever select-dropdown <id> "Option Text"` | Select option by text (case-insensitive match by label, text, or value) |

### Content & Screenshots
| Command | Description |
|---------|-------------|
| `ever extract` | Page content as readable markdown (no [id] annotations) |
| `ever screenshot` | Save viewport screenshot (JPEG q75) to temp file |
| `ever screenshot --output path.jpg` | Save to specific path |

**When to use `extract` vs `snapshot`:**
- Use `snapshot` when you need to **find and interact** with elements (returns [id] annotations)
- Use `extract` when you need to **read content** as clean text (returns markdown, no IDs)
- Prefer reading data from `snapshot` output directly when visible — `extract` is heavier

### File Upload
| Command | Description |
|---------|-------------|
| `ever upload-file <id> <file1> [file2...]` | Upload local files to a file input element |

### Agent Tasks
| Command | Description |
|---------|-------------|
| `ever run "task description"` | Run autonomous agent task with SSE streaming |
| `ever run "task" --provider gemini --model gemini-2.5-flash` | Specify LLM provider/model |
| `ever status` | Check running tasks |
| `ever logs --follow` | Stream agent logs |

### Domain-Specific Commands

**Google Sheets** (`ever sheets`):
| Command | Description |
|---------|-------------|
| `ever sheets select-cell A1` | Navigate to cell using Name Box |
| `ever sheets select-cell "Sheet2!A1:C10"` | Select range with sheet prefix |
| `ever sheets select-cell B2 --no-edit` | Navigate without entering edit mode |

**Agent File System** (`ever fs`):
| Command | Description |
|---------|-------------|
| `ever fs write <file> <content>` | Write content to file |
| `ever fs write <file> <content> --append` | Append to existing file |
| `ever fs read <file>` | Read file (paginated at ~8000 chars) |
| `ever fs read <file> --page 2` | Read specific page of large file |
| `ever fs replace <file> <old> <new>` | Find and replace string in file |

### Auth & Config
| Command | Description |
|---------|-------------|
| `ever login` | Store API key (get from dashboard → API Keys) |
| `ever logout` | Remove stored API key |
| `ever debug-bundle` | Collect diagnostics for debugging |
| `ever mcp` | Start MCP stdio server for coding agents |

## Action Efficiency Guide

### Action categories

- **Page-changing (must be last):** `navigate`, `go-back`, `switch-tab`, `search` — these load a new page. Element IDs from the previous snapshot become invalid. Always snapshot after.
- **Potentially page-changing:** `click` on links/buttons that navigate — may change the page. If it does, snapshot again.
- **Safe to chain:** `input`, `scroll`, `wait`, `eval`, `select-dropdown`, `upload-file` — do not change the page. Can be combined freely.

### Efficient combinations

```bash
# Fill form and submit in sequence (input is safe, click-submit may navigate)
ever input 12 "John" && ever input 15 "john@example.com" && ever click 20

# Scroll multiple times to load lazy content
ever snapshot && ever scroll down && ever scroll down && ever snapshot

# Wait for dynamic content after triggering it
ever click 5 && ever wait 2 && ever snapshot --mode incremental
```

### Common mistakes to avoid

- **Don't use `extract` for data visible in snapshot** — if the text is in the snapshot DOM tree, read it directly
- **Don't `click` a `<select>` element** — use `get-dropdown-options` + `select-dropdown` instead
- **Don't forget to snapshot after navigation** — old element IDs are stale
- **Don't repeat failing actions** — if clicking element X doesn't work, try a different approach (scroll to reveal it, use `eval`, try a different element)

## Data Extraction with `eval` (Preferred for Scraping)

When the task is **reading/scraping data** (not clicking or interacting), use `ever eval` with custom JavaScript instead of `snapshot`. It's 10x faster and returns structured data directly.

### Decision: `snapshot` vs `eval` vs `extract`

| Task | Tool | Why |
|------|------|-----|
| Click buttons, fill forms | `snapshot` | Need element `[id]` annotations |
| Scrape feed/list data | `eval` | Structured JSON output, no parsing needed |
| Read full page as markdown | `extract` | Clean text, no IDs or JS needed |

### The Batch-Scroll-Collect Pattern

For scraping data across a scrollable feed (social media, search results, infinite scroll):

**Step 1 — Initialize** a global accumulator (avoids duplicates across scrolls):
```bash
ever eval "window._data = {}; window._cfg = { timeWindowMs: 5 * 60 * 60 * 1000 }; 'init ok'"
```

**Step 2 — Collect + Scroll** in a bash loop. Wrap in IIFE to avoid `const` redeclaration errors:
```bash
for i in $(seq 1 20); do
  ever scroll down 2>/dev/null
  sleep 1
  ever eval "(() => {
    // ... collect visible items into window._data ...
    return JSON.stringify({ collected: Object.keys(window._data).length });
  })()" 2>&1
done
```

**Step 3 — Dump** all collected data:
```bash
ever eval "JSON.stringify(Object.values(window._data), null, 2)"
```

### Key rules for `eval` scripts

- **Always wrap in IIFE** `(() => { ... })()` — CDP eval shares scope across calls, `const`/`let` at top level will throw `SyntaxError: already declared` on subsequent runs
- **Use `window._varName`** for state that persists across eval calls (global accumulator, config)
- **CDP eval has a ~30s timeout** — don't put the scroll loop inside eval. Keep each eval call fast (<5s), do scrolling via `ever scroll` between calls
- **Return `JSON.stringify()`** — eval returns the expression's value as a string

### Saved Recipes

Reusable eval scripts for common sites are saved in `recipes/`. Before writing a new scraper from scratch, check if a recipe exists:

| Recipe | Site | Task |
|--------|------|------|
| `x-feed-scraper.js` | x.com | Collect timeline posts with metadata (who, content, engagement, links) |

**To use a recipe**: Read the recipe file for the INIT, COLLECT, and DUMP scripts. Adapt parameters (time window, selectors) as needed. The recipe documents which CSS selectors it relies on and when they were last verified.

**To save a new recipe**: After successfully scraping a site with eval, save the working script to `recipes/<site>-<task>.js` with the same format — header comments documenting site, selectors, and the INIT/COLLECT/DUMP pattern.

## Common Patterns

### Fill and submit a form
```bash
ever snapshot
ever input 12 "John Doe"
ever input 15 "john@example.com"
ever click 20                      # Submit button
ever snapshot                      # Verify result
```

### Navigate and extract content
```bash
ever start --url https://example.com
ever snapshot
ever extract                       # Get full page as readable markdown
ever stop
```

### Handle dynamic/delayed content
```bash
ever click 5                       # Trigger AJAX load
ever wait 2                        # Wait for content to load
ever snapshot --mode incremental   # See new elements
```

### Scroll to find elements
```bash
ever snapshot
ever scroll down                   # Scroll one page
ever snapshot                      # Check for new elements
# Repeat until target found
```

### Interact with shadow DOM elements
```bash
ever snapshot                      # Shadow DOM elements get [id] annotations too
ever input 347 "text"              # Use the [id] directly — works across shadow boundaries
```

### Work with dropdown menus
```bash
ever snapshot                      # Find the <select> element [id]
ever get-dropdown-options 42       # List all options
ever select-dropdown 42 "United States"  # Select by text
```

### Scrape data from a list across pages
```bash
# Preferred: use eval with batch-scroll-collect pattern (see "Data Extraction with eval" above)
# Fallback: snapshot-based approach for simple cases
ever snapshot                      # Read all visible items from snapshot
ever scroll down && ever snapshot  # Load more
# Continue until done
```

### Run an autonomous task
```bash
ever start --url https://example.com
ever run "Find the pricing page and extract all plan details"
# Streams progress via SSE, prints stage updates
ever stop
```

## Error Recovery

| Error | Fix |
|-------|-----|
| "No active session" | Run `ever start` first |
| "No active snapshot" | Run `ever snapshot` before actions |
| "Extension not connected" | Open Chrome with Ever extension, run `ever doctor` |
| "Session expired" | Run `ever start` again (API server may have restarted) |
| "Tab does not belong to this session's group" | Use `ever tabs` to find valid tab IDs |
| "Failed to acquire lock" | Another task is running — `ever stop` it first |
| "everd daemon crashed on startup" | Check error message — usually port conflict. `lsof -ti :4198 \| xargs kill` |
| "Too many CLI requests" | Rate limited (120 req/min). Slow down command frequency. |
| "Cannot click on \<select\>" | Use `ever get-dropdown-options` + `ever select-dropdown` instead |
| "Stale element reference" | DOM changed since snapshot. Run `ever snapshot` again. |
