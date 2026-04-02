#!/bin/bash
# Pre-loop onboarding: collect target info, research stack, generate config
# Run this BEFORE start.sh — it calls start.sh automatically on success
set -euo pipefail
cd "$(dirname "$0")"

echo "=== RALPH-TO-RALPH: Onboarding ==="
echo "This will prepare the project for cloning a specific product."
echo ""

# Run Claude onboarding session
result=$(timeout 1800 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@onboard-prompt.md @pre-setup.md @CLAUDE.md

Run the complete onboarding flow. Ask the user what to clone, research the target,
configure the stack, check dependencies, and prepare all config files.
Output <promise>ONBOARD_COMPLETE</promise> when done.
Output <promise>ONBOARD_FAILED</promise> if any check fails.")

echo "$result"

# Validate outputs
if [[ "$result" == *"<promise>ONBOARD_COMPLETE</promise>"* ]]; then
  # Verify ralph-config.json exists and has required fields
  if [ ! -f "ralph-config.json" ]; then
    echo "ERROR: ralph-config.json not found after onboarding"
    exit 1
  fi

  # Lightweight schema validation — catch prompt drift early
  python3 -c "
import json, sys
c = json.load(open('ralph-config.json'))
required = ['targetUrl', 'targetName', 'cloudProvider', 'framework', 'database']
missing = [k for k in required if k not in c]
if missing:
    print(f'ERROR: ralph-config.json missing required fields: {missing}', file=sys.stderr)
    sys.exit(1)
if c['cloudProvider'] not in ('aws', 'gcp', 'azure'):
    print(f'ERROR: invalid cloudProvider: {c[\"cloudProvider\"]}', file=sys.stderr)
    sys.exit(1)
" || exit 1

  TARGET_URL=$(python3 -c "import json; print(json.load(open('ralph-config.json'))['targetUrl'])")
  echo ""
  echo "=== Onboarding complete ==="
  echo "Target: $TARGET_URL"
  echo "Config: ralph-config.json"
  echo ""
  echo "Starting the build loop..."
  ./scripts/start.sh "$TARGET_URL"
elif [[ "$result" == *"<promise>ONBOARD_FAILED</promise>"* ]]; then
  echo ""
  echo "=== Onboarding failed ==="
  echo "Fix the issues above and re-run: ./onboard.sh"
  exit 1
else
  echo ""
  echo "=== Onboarding did not complete ==="
  echo "Re-run: ./onboard.sh"
  exit 1
fi
