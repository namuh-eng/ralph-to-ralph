#!/bin/bash
# Phase 1: Inspect a target product using Ever CLI and generate a PRD
# Each iteration = exactly 1 page/feature (enforced by prompt)
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_URL="${1:?Usage: $0 <target-url> [iterations]}"
ITERATIONS="${2:-999}"

[ -f ralph-config.json ] || { echo "ERROR: ralph-config.json not found. Run ./ralph/onboard.sh first."; exit 1; }
BROWSER_AGENT=$(python3 -c "import json; print(json.load(open('ralph-config.json')).get('browserAgent', 'ever'))" 2>/dev/null || echo "ever")

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
_coverage_passed=0
if [ -f target-docs/coverage.json ]; then
  if python3 -c "import json,sys; sys.exit(0 if json.load(open('target-docs/coverage.json')).get('passed') else 1)" 2>/dev/null; then
    _coverage_passed=1
  fi
fi

if [ "$_coverage_passed" -eq 0 ]; then
  echo "=== Scraping target docs ==="
  if [ ! -d .venv-scrape ]; then
    echo "First-time setup: creating .venv-scrape and installing scrape-docs deps..."
    if ! command -v python3 >/dev/null 2>&1; then
      echo "ERROR: python3 is required for the doc scraper. Install Python 3.10+ and re-run." >&2
      exit 1
    fi
    python3 -m venv .venv-scrape
    .venv-scrape/bin/pip install --quiet --upgrade pip
    .venv-scrape/bin/pip install --quiet -r scripts/scrape-docs-requirements.txt
  fi
  if ! .venv-scrape/bin/python scripts/scrape-docs.py "$TARGET_URL"; then
    echo "" >&2
    echo "ERROR: doc scraper failed coverage gate. Inspect cannot proceed." >&2
    echo "  - check target-docs/coverage.json for the failure reason" >&2
    echo "  - try a more specific target URL (e.g. https://example.com/docs)" >&2
    echo "  - or re-run after debugging:" >&2
    echo "      .venv-scrape/bin/python scripts/scrape-docs.py \"$TARGET_URL\" --force" >&2
    exit 1
  fi
  echo "=== Doc scrape complete ==="
  echo ""
else
  echo "target-docs/ already populated (coverage.json passed). Skipping scrape."
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
