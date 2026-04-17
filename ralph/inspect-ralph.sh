#!/bin/bash
# Phase 1: Inspect a target product using Ever CLI and generate a PRD
# Each iteration = exactly 1 page/feature (enforced by prompt)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_URL="${1:?Usage: $0 <target-url> [iterations]}"
ITERATIONS="${2:-999}"

# Resolve Python: prefer `uv run python3` if uv is available, fall back to bare python3
if command -v uv &>/dev/null; then
  PY="uv run python3"
else
  PY="python3"
fi

[ -f ralph-config.json ] || { echo "ERROR: ralph-config.json not found. Run ./ralph/onboard.sh first."; exit 1; }
BROWSER_AGENT=$($PY -c "import json; print(json.load(open('ralph-config.json')).get('browserAgent', 'ever'))" 2>/dev/null || echo "ever")
# docsUrl is set during onboarding when the actual docs live on a different
# subdomain (e.g. docs.stripe.com vs stripe.com). If present, the scraper
# targets it directly instead of probing subdomains at runtime.
DOCS_URL=$($PY -c "import json; print(json.load(open('ralph-config.json')).get('docsUrl', ''))" 2>/dev/null || echo "")

echo "=== RALPH-TO-RALPH: Phase 1 (Inspect) ==="
echo "Target: $TARGET_URL"
echo "Iterations: $ITERATIONS"
echo ""

# Initialize files
touch inspect-progress.txt
if [ ! -f "prd.json" ]; then
  echo '[]' > prd.json
fi
mkdir -p ralph/screenshots target-docs

# Phase 1.0: Deterministic doc scrape (runs once before iteration 1)
# Populates target-docs/ so the inspect prompts can read docs from disk
# instead of trying to scrape the web themselves. Hard-fails on the coverage
# gate so the loop never starts with a half-empty target-docs/.
#
# Skip-guard: trust the cache only if BOTH coverage.json reports passed AND
# INDEX.md is on disk. Otherwise we'd silently start with an empty corpus
# when a user nuked target-docs/*.md but left coverage.json behind.
_coverage_passed=0
if [ -f target-docs/coverage.json ] && [ -f target-docs/INDEX.md ]; then
  if $PY -c "import json,sys; sys.exit(0 if json.load(open('target-docs/coverage.json')).get('passed') else 1)" 2>/dev/null; then
    _coverage_passed=1
  fi
fi

if [ "$_coverage_passed" -eq 0 ]; then
  echo "=== Scraping target docs ==="
  # Sentinel marks a fully-installed venv. Without this, a partial install
  # (network drop, disk full, ^C) leaves .venv-scrape/ on disk and the next
  # run silently reuses the broken venv.
  if [ ! -f .venv-scrape/.install-complete ]; then
    if [ -d .venv-scrape ]; then
      echo "Removing stale .venv-scrape (no install-complete sentinel)..."
      rm -rf .venv-scrape
    fi
    echo "First-time setup: creating .venv-scrape and installing scrape-docs deps..."
    if ! command -v python3 >/dev/null 2>&1; then
      echo "ERROR: python3 is required for the doc scraper. Install Python 3.10+ and re-run." >&2
      exit 1
    fi
    python3 -m venv .venv-scrape
    .venv-scrape/bin/pip install --quiet --upgrade pip
    .venv-scrape/bin/pip install --quiet -r scripts/scrape-docs-requirements.txt
    # Pre-fetch browser binaries so StealthyFetcher / PlayWrightFetcher don't
    # silently degrade to plain HTTP on Cloudflare-protected or SPA-rendered
    # doc sites. Both installers are best-effort: if the download fails we
    # still continue (Fetcher.get covers static HTML), but the warning makes
    # the degradation visible instead of silent.
    echo "Installing browser binaries for stealthy/playwright fetchers..."
    if ! .venv-scrape/bin/python -m playwright install chromium >/dev/null 2>&1; then
      echo "WARNING: playwright chromium install failed. SPA-rendered doc sites may be skipped." >&2
    fi
    if ! .venv-scrape/bin/python -m camoufox fetch >/dev/null 2>&1; then
      echo "WARNING: camoufox browser fetch failed. Cloudflare-protected doc sites may be skipped." >&2
    fi
    touch .venv-scrape/.install-complete
  fi
  set +e
  _SCRAPE_ARGS=("$TARGET_URL")
  [ -n "$DOCS_URL" ] && _SCRAPE_ARGS+=(--docs-url "$DOCS_URL")
  .venv-scrape/bin/python scripts/scrape-docs.py "${_SCRAPE_ARGS[@]}"
  _scrape_exit=$?
  set -e
  if [ "$_scrape_exit" -ne 0 ]; then
    echo "" >&2
    case "$_scrape_exit" in
      1)
        echo "ERROR: coverage gate not satisfied. Inspect cannot proceed." >&2
        echo "  - see target-docs/coverage.json for the failure reason" >&2
        echo "  - try a more specific target URL (e.g. https://example.com/docs)" >&2
        ;;
      2)
        echo "ERROR: no documentation discovered for this target." >&2
        echo "  - the discovery ladder (llms.txt -> mint.json -> sitemap -> crawl) found nothing" >&2
        echo "  - try a more specific target URL (e.g. https://example.com/docs)" >&2
        ;;
      3)
        echo "ERROR: scraper dependency / environment failure." >&2
        echo "  - delete .venv-scrape/ and re-run to reinstall" >&2
        echo "  - confirm Python 3.10+ is available" >&2
        ;;
      *)
        echo "ERROR: doc scraper exited with code $_scrape_exit." >&2
        ;;
    esac
    echo "  - debug re-run:  .venv-scrape/bin/python scripts/scrape-docs.py \"$TARGET_URL\" --force" >&2
    exit 1
  fi
  echo "=== Doc scrape complete ==="
  echo ""
else
  echo "target-docs/ already populated (coverage.json passed, INDEX.md present). Skipping scrape."
  echo "Delete target-docs/coverage.json or pass --force to re-scrape."
  echo ""
fi

# Start browser agent session
if [ "$BROWSER_AGENT" = "ever" ]; then
  ever start --url "$TARGET_URL"
  trap 'ever stop 2>/dev/null' EXIT
  echo "Ever CLI session started."
elif [ "$BROWSER_AGENT" = "stagehand" ]; then
  echo "Using Stagehand for browser automation."
else
  echo "Using Playwright for browser automation."
fi
echo ""

for ((i=1; i<=$ITERATIONS; i++)); do
  echo "--- Inspection iteration $i/$ITERATIONS ---"

  _BROWSER_REF=""
  [ "$BROWSER_AGENT" = "ever" ] && _BROWSER_REF="@ralph/ever-cli-reference.md"
  result=$(timeout 1200 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@ralph/inspect-prompt.md @ralph/inspect-spec.md $_BROWSER_REF @prd.json @inspect-progress.txt @ralph/pre-setup.md @ralph-config.json

TARGET URL: $TARGET_URL
ITERATION: $i of $ITERATIONS

Inspect exactly ONE page/feature, then commit, push, and stop.
Output <promise>NEXT</promise> when done with this page.
Output <promise>INSPECT_COMPLETE</promise> only if ALL pages are inspected AND build-spec.md is finalized.")

  echo "$result"

  if [[ "$result" == *"<promise>INSPECT_COMPLETE</promise>"* ]]; then
    echo ""
    echo "=== Inspection complete after $i iterations ==="
    echo "PRD: prd.json"
    echo "Build spec: build-spec.md"
    touch .inspect-complete
    exit 0
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "Page done. Moving to next iteration..."
    continue
  fi

  # No promise = crash or context limit
  echo "WARNING: No promise found. Agent may have crashed. Restarting..."
  sleep 3
done

echo ""
echo "=== Inspection finished after $ITERATIONS iterations ==="
echo "PRD: prd.json (may be incomplete)"
