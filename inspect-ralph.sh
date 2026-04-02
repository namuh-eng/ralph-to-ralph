#!/bin/bash
# Phase 1: Inspect a target product using Ever CLI and generate a PRD
# Each iteration = exactly 1 page/feature (enforced by prompt)
set -euo pipefail
cd "$(dirname "$0")"

TARGET_URL="${1:?Usage: $0 <target-url> [iterations]}"
ITERATIONS="${2:-999}"

echo "=== RALPH-TO-RALPH: Phase 1 (Inspect) ==="
echo "Target: $TARGET_URL"
echo "Iterations: $ITERATIONS"
echo ""

# Initialize files
touch inspect-progress.txt
if [ ! -f "prd.json" ]; then
  echo '[]' > prd.json
fi
mkdir -p screenshots

# Start Ever CLI session
ever start --url "$TARGET_URL"
trap 'ever stop 2>/dev/null' EXIT

echo "Ever CLI session started."
echo ""

for ((i=1; i<=$ITERATIONS; i++)); do
  echo "--- Inspection iteration $i/$ITERATIONS ---"

  result=$(timeout 1200 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@inspect-prompt.md @inspect-spec.md @ever-cli-reference.md @prd.json @inspect-progress.txt @pre-setup.md @ralph-config.json

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
