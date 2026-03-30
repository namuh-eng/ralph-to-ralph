#!/bin/bash
# Phase 3: QA evaluation using Codex as independent evaluator
# Runs Playwright regression first (fast), then Ever CLI for visual/interaction QA
set -euo pipefail
cd "$(dirname "$0")"

TARGET_URL="${1:-}"
ITERATIONS="${2:-999}"

if [ ! -f "prd.json" ]; then
  echo "Error: prd.json not found. Run build-ralph.sh first."
  exit 1
fi

echo "=== RALPH-TO-RALPH: Phase 3 (QA with Codex) ==="
echo "Target: ${TARGET_URL:-none}"
echo "Iterations: $ITERATIONS"
echo ""

# Initialize
if [ ! -f "qa-report.json" ]; then
  echo '[]' > qa-report.json
fi

# Start dev server in background
npm run dev &
DEV_PID=$!
echo "Dev server started (PID: $DEV_PID)"
trap 'kill $DEV_PID 2>/dev/null; ever stop 2>/dev/null' EXIT
sleep 5  # Wait for server to be ready

# Run Playwright regression suite first (fast, catches obvious bugs)
if [ -f "playwright.config.ts" ] || [ -d "tests/e2e" ]; then
  echo "--- Running Playwright regression suite ---"
  npx playwright test --reporter=list 2>&1 || echo "Some Playwright tests failed — QA agent will investigate."
  echo ""
fi

# Start Ever CLI session for QA
ever start --url http://localhost:3015
echo "Ever CLI session started for QA."
echo ""

# Build target URL context for the prompt
TARGET_CONTEXT=""
if [ -n "$TARGET_URL" ]; then
  TARGET_CONTEXT="
TARGET_URL: $TARGET_URL
When confused about how a feature should work, use 'ever start --url $TARGET_URL' to check the original product."
fi

for ((i=1; i<=$ITERATIONS; i++)); do
  echo "--- QA iteration $i/$ITERATIONS ---"

  # Use Codex as an independent evaluator (different model = different perspective)
  result=$(timeout 1200 codex exec --dangerously-bypass-approvals-and-sandbox \
"$(cat qa-prompt.md)

Read these files before starting:
@pre-setup.md
@build-spec.md
@prd.json
@qa-report.json
@ever-cli-reference.md

ITERATION: $i of $ITERATIONS
${TARGET_CONTEXT}

Test exactly ONE feature, then commit, push, and stop.
Output <promise>NEXT</promise> when done with this feature.
If ALL features have been QA tested and all bugs fixed, output <promise>QA_COMPLETE</promise>.")

  echo "$result"

  if [[ "$result" == *"<promise>QA_COMPLETE</promise>"* ]]; then
    echo ""
    echo "--- Running final Playwright regression suite ---"
    npx playwright test --reporter=list 2>&1 || echo "Some Playwright tests failed in final regression."
    echo ""
    echo "=== QA complete after $i iterations! ==="
    exit 0
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "QA for feature done. Moving to next..."
    continue
  fi

  echo "WARNING: No promise found. Agent may have crashed. Restarting..."
  sleep 3
done

# Run full E2E regression at the end
echo "--- Running final Playwright regression suite ---"
npx playwright test --reporter=list 2>&1 || echo "Some Playwright tests failed in final regression."
echo ""

echo ""
echo "=== QA finished after $ITERATIONS iterations ==="
echo "Check qa-report.json for results."
