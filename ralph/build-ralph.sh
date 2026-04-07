#!/bin/bash
# Phase 2: Build a clone from the generated PRD and build spec
# Each iteration = exactly 1 feature (enforced by prompt + NEXT/COMPLETE promises)
set -euo pipefail
cd "$(dirname "$0")/.."

ITERATIONS="${1:-999}"

[ -f ralph-config.json ] || { echo "ERROR: ralph-config.json not found. Run ./ralph/onboard.sh first."; exit 1; }

if [ ! -f "prd.json" ]; then
  echo "Error: prd.json not found. Run inspect-ralph.sh first."
  exit 1
fi

if [ ! -f "build-spec.md" ]; then
  echo "Error: build-spec.md not found. Run inspect-ralph.sh first."
  exit 1
fi

echo "=== RALPH-TO-RALPH: Phase 2 (Build) ==="
echo "Iterations: $ITERATIONS"
echo ""

# Initialize
touch build-progress.txt

count_passes() {
  python3 -c "import json; d=json.load(open('prd.json')); print(sum(1 for x in d if x.get('build_pass', False)))" 2>/dev/null || echo "0"
}
total_tasks() {
  python3 -c "import json; print(len(json.load(open('prd.json'))))" 2>/dev/null || echo "0"
}

for ((i=1; i<=$ITERATIONS; i++)); do
  PASSES=$(count_passes)
  TOTAL=$(total_tasks)
  echo "--- Build iteration $i/$ITERATIONS ($PASSES/$TOTAL passed) ---"

  # Check if all done before invoking
  if [ "$PASSES" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "All $TOTAL features already build_pass!"
    exit 0
  fi

  result=$(timeout 1200 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@ralph/build-prompt.md @ralph/pre-setup.md @build-spec.md @prd.json @build-progress.txt @CLAUDE.md @ralph-config.json

ITERATION: $i of $ITERATIONS
PROGRESS: $PASSES/$TOTAL features build_pass

Build exactly ONE feature (the first build_pass:false entry), then commit, push, and stop.
Output <promise>NEXT</promise> when done with this feature.
Output <promise>COMPLETE</promise> only if ALL features pass.")

  echo "$result"

  if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
    echo ""
    echo "=== Build complete after $i iterations! All $(total_tasks) features pass. ==="
    exit 0
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "Feature done. Moving to next iteration..."
    continue
  fi

  # If neither promise found, agent may have hit context limit or errored
  echo "WARNING: No promise found. Agent may have crashed or hit context limit. Restarting..."
  sleep 3
done

echo ""
echo "=== Build finished after $ITERATIONS iterations ==="
echo "Passes: $(count_passes)/$(total_tasks). Check prd.json for remaining."
