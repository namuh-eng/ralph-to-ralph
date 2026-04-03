#!/bin/bash
# Pre-loop onboarding: collect target info, research stack, generate config
# Run this BEFORE start.sh — it calls start.sh automatically on success
set -euo pipefail
cd "$(dirname "$0")"

echo "=== RALPH-TO-RALPH: Onboarding ==="
echo "This will prepare the project for cloning a specific product."
echo ""

# ── Step 1: Collect user input interactively (bash handles Q&A) ──
# claude -p runs in pipe mode (no back-and-forth), so we collect answers
# here and pass them to Claude as context.

read -rp "What product do you want to clone? (URL): " TARGET_URL
if [ -z "$TARGET_URL" ]; then
  echo "ERROR: Target URL is required."
  exit 1
fi

# Suggest a clone name from the URL
SUGGESTED_NAME=$(echo "$TARGET_URL" | sed 's|https\?://||;s|www\.||;s|\.com.*||;s|\.io.*||;s|\.dev.*||;s|\.app.*||')
read -rp "What should we call the clone? [$SUGGESTED_NAME-clone]: " CLONE_NAME
CLONE_NAME="${CLONE_NAME:-${SUGGESTED_NAME}-clone}"

echo ""
echo "Cloud provider options:"
echo "  1) AWS  (stable — recommended)"
echo "  2) GCP  (experimental)"
echo "  3) Azure (experimental)"
read -rp "Choose cloud provider [1]: " CLOUD_CHOICE
case "${CLOUD_CHOICE:-1}" in
  1|aws)   CLOUD_PROVIDER="aws" ;;
  2|gcp)   CLOUD_PROVIDER="gcp" ;;
  3|azure) CLOUD_PROVIDER="azure" ;;
  *)       echo "Invalid choice. Using AWS."; CLOUD_PROVIDER="aws" ;;
esac

echo ""
echo "--- Summary ---"
echo "Target:    $TARGET_URL"
echo "Clone:     $CLONE_NAME"
echo "Cloud:     $CLOUD_PROVIDER"
echo "Framework: Next.js 16 (default)"
echo "Database:  Postgres (default)"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
if [[ "${CONFIRM:-y}" =~ ^[Nn] ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "--- Researching target and configuring project... ---"
echo ""

# ── Step 2: Claude handles research + config generation (no Q&A needed) ──
result=$(timeout 1800 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@onboard-prompt.md @pre-setup.md @CLAUDE.md

The user has already provided their answers:
- Target URL: $TARGET_URL
- Clone name: $CLONE_NAME
- Cloud provider: $CLOUD_PROVIDER
- Framework: nextjs (default)
- Database: postgres (default)

SKIP Steps 1 and 2 (already answered above). Start directly from Step 3 (Technical Architecture Scan).
Research the target product, generate ralph-config.json, check dependencies, rewrite config files, and install packages.
Output <promise>ONBOARD_COMPLETE</promise> when done.
Output <promise>ONBOARD_FAILED</promise> if any check fails.")

echo "$result"

# ── Step 3: Validate outputs ──
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
