#!/bin/bash
# Pre-loop onboarding: collect target info, research stack, generate config
# Run this BEFORE start.sh — it calls start.sh automatically on success
set -euo pipefail
cd "$(dirname "$0")"

# ── Cleanup on interrupt ──
cleanup() {
  echo ""
  echo ""
  echo "=== Onboarding interrupted ==="
  echo ""
  echo "The project may be in a partially configured state."
  echo "You have two options:"
  echo ""
  echo "  1. Re-run:  ./onboard.sh"
  echo "     (Will detect partial state and offer to reset)"
  echo ""
  echo "  2. Reset:   ./onboard.sh --reset"
  echo "     (Restores all config files to their pre-onboarding state)"
  echo ""
  exit 130
}
trap cleanup SIGINT SIGTERM

# ── Handle --reset flag ──
if [[ "${1:-}" == "--reset" ]]; then
  echo "=== Resetting onboarding state ==="
  # Reset config files that onboarding may have modified
  ONBOARD_FILES=(
    "src/lib/db/schema.ts"
    "scripts/preflight.sh"
    "package.json"
    "pre-setup.md"
    "CLAUDE.md"
    "inspect-prompt.md"
    "build-prompt.md"
  )
  dirty=0
  for f in "${ONBOARD_FILES[@]}"; do
    if git diff --quiet "$f" 2>/dev/null; then
      :
    else
      echo "  Restoring: $f"
      git checkout -- "$f" 2>/dev/null || true
      dirty=1
    fi
  done
  rm -f ralph-config.json
  if [ "$dirty" -eq 1 ]; then
    echo "  Running npm install to restore dependencies..."
    npm install --silent 2>/dev/null || true
  fi
  echo ""
  echo "Reset complete. Run ./onboard.sh to start fresh."
  exit 0
fi

# ── Preflight: check required tools ──
missing_tools=()
if ! command -v claude &>/dev/null; then
  missing_tools+=("claude (Claude Code CLI — install from https://docs.anthropic.com/en/docs/claude-code)")
fi
if ! command -v python3 &>/dev/null; then
  missing_tools+=("python3 (required for config validation)")
fi
if ! command -v node &>/dev/null; then
  missing_tools+=("node (Node.js 20+ — https://nodejs.org)")
fi
if [ ${#missing_tools[@]} -gt 0 ]; then
  echo "ERROR: Missing required tools:"
  for t in "${missing_tools[@]}"; do
    echo "  - $t"
  done
  exit 1
fi

# macOS does not ship GNU timeout — provide a portable fallback
if ! command -v timeout &>/dev/null; then
  timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
fi

echo "=== RALPH-TO-RALPH: Onboarding ==="
echo "This will prepare the project for cloning a specific product."
echo ""

# ── Detect partial state from a previous interrupted run ──
if [ -f "ralph-config.json" ]; then
  PREV_TARGET=$(python3 -c "import json; print(json.load(open('ralph-config.json')).get('targetUrl', 'unknown'))" 2>/dev/null || echo "unknown")
  echo "Found existing ralph-config.json (target: $PREV_TARGET)"
  echo ""
  echo "Options:"
  echo "  1) Continue with existing config (skip to build loop)"
  echo "  2) Start fresh (reset and re-onboard)"
  echo "  3) Abort"
  read -rp "Choose [1]: " RESUME_CHOICE
  case "${RESUME_CHOICE:-1}" in
    1)
      echo ""
      echo "Validating existing config..."
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
print('Config is valid.')
" || { echo "Config is invalid. Run ./onboard.sh --reset to start fresh."; exit 1; }
      TARGET_URL=$(python3 -c "import json; print(json.load(open('ralph-config.json'))['targetUrl'])")
      echo ""
      echo "=== Resuming with existing config ==="
      echo "Target: $TARGET_URL"
      echo ""
      if ! command -v ever &>/dev/null; then
        echo "Next step: install Ever CLI (needed for the Inspect phase)."
        echo "  Install: https://foreverbrowsing.com"
        echo "  Then start the loop: ./scripts/start.sh \"$TARGET_URL\""
      else
        echo "Starting the build loop..."
        ./scripts/start.sh "$TARGET_URL"
      fi
      exit 0
      ;;
    2)
      echo "Resetting..."
      "$0" --reset
      exec "$0"
      ;;
    3)
      echo "Aborted."
      exit 0
      ;;
  esac
fi

# ── Step 1: Collect user input interactively (bash handles Q&A) ──
# claude -p runs in pipe mode (no back-and-forth), so we collect answers
# here and pass them to Claude as context.

read -rp "What product do you want to clone? (URL): " TARGET_URL
if [ -z "$TARGET_URL" ]; then
  echo "ERROR: Target URL is required."
  exit 1
fi
if ! [[ "$TARGET_URL" =~ ^https?:// ]]; then
  echo "ERROR: Target URL must start with http:// or https://"
  exit 1
fi
if [[ "$TARGET_URL" == *"<promise>"* ]] || [[ "$TARGET_URL" == *"</promise>"* ]]; then
  echo "ERROR: Invalid characters in URL."
  exit 1
fi

# Suggest a clone name from the URL
# Strips protocol, www, path, port, then extracts the brand name (second-to-last domain segment)
# e.g. app.posthog.com → posthog, docs.stripe.com/api → stripe, resend.com → resend
SUGGESTED_NAME=$(echo "$TARGET_URL" | sed -E 's|https?://||;s|www\.||;s|/.*||;s|:[0-9]+||' | awk -F. '{if(NF>=2) print $(NF-1); else print $1}')
read -rp "What should we call the clone? [$SUGGESTED_NAME-clone]: " CLONE_NAME
CLONE_NAME="${CLONE_NAME:-${SUGGESTED_NAME}-clone}"
if [[ "$CLONE_NAME" == *"<promise>"* ]] || [[ "$CLONE_NAME" == *"</promise>"* ]]; then
  echo "ERROR: Invalid characters in clone name."
  exit 1
fi
if ! [[ "$CLONE_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "ERROR: Clone name must only contain letters, numbers, dots, hyphens, and underscores."
  exit 1
fi

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

# ── Deployment tier (AWS only) ──
DEPLOYMENT_TIER="personal"
if [ "$CLOUD_PROVIDER" = "aws" ]; then
  echo ""
  echo "How will this clone be used?"
  echo ""
  echo "  1) Personal / solo dev  — App Runner + Neon (serverless Postgres)"
  echo "     Simple setup, ~\$0-5/mo at low traffic, scales to zero."
  echo "     No VPC, no cluster. Good for building and experimenting."
  echo ""
  echo "  2) Team / production    — ECS Fargate + RDS (private VPC)"
  echo "     Full infrastructure: private subnets, ALB, security groups."
  echo "     Right architecture for shared use or real traffic."
  echo ""
  read -rp "Choose deployment tier [1]: " TIER_CHOICE
  case "${TIER_CHOICE:-1}" in
    1|personal) DEPLOYMENT_TIER="personal" ;;
    2|team)     DEPLOYMENT_TIER="team" ;;
    *)          echo "Invalid choice. Using personal."; DEPLOYMENT_TIER="personal" ;;
  esac
fi

# ── Verify cloud CLI is installed before the long research step ──
case "$CLOUD_PROVIDER" in
  aws)
    if ! command -v aws &>/dev/null; then
      echo ""
      echo "ERROR: AWS CLI is not installed."
      echo "  Install: brew install awscli"
      echo "  Then:    aws configure"
      exit 1
    fi
    ;;
  gcp)
    if ! command -v gcloud &>/dev/null; then
      echo ""
      echo "ERROR: Google Cloud SDK is not installed."
      echo "  Install: https://cloud.google.com/sdk/docs/install"
      echo "  Then:    gcloud auth login && gcloud config set project YOUR_PROJECT"
      exit 1
    fi
    ;;
  azure)
    if ! command -v az &>/dev/null; then
      echo ""
      echo "ERROR: Azure CLI is not installed."
      echo "  Install: brew install azure-cli"
      echo "  Then:    az login"
      exit 1
    fi
    ;;
esac

echo ""
read -rp "Deploy to production after build? [Y/n]: " DEPLOY_CHOICE
if [[ "${DEPLOY_CHOICE:-y}" =~ ^[Nn] ]]; then
  SKIP_DEPLOY="true"
else
  SKIP_DEPLOY="false"
fi

echo ""
echo "--- Summary ---"
echo "Target:    $TARGET_URL"
echo "Clone:     $CLONE_NAME"
echo "Cloud:     $CLOUD_PROVIDER"
echo "Framework: Next.js 16 (default)"
echo "Database:  Postgres (default)"
echo "Deploy:    $([ "$SKIP_DEPLOY" = "true" ] && echo "No (build locally only)" || echo "Yes (Docker → cloud)")"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
if [[ "${CONFIRM:-y}" =~ ^[Nn] ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "--- Researching target and configuring project... ---"
echo "(This takes 1-5 minutes. Press Ctrl+C to cancel safely.)"
echo ""

# ── Step 2: Claude handles research + config generation (no Q&A needed) ──
claude_exit=0
result=$(timeout 1800 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@onboard-prompt.md @pre-setup.md @CLAUDE.md

The user has already provided their answers:
- Target URL: $TARGET_URL
- Clone name: $CLONE_NAME
- Cloud provider: $CLOUD_PROVIDER
- Deployment tier: $DEPLOYMENT_TIER (personal = App Runner + Neon; team = ECS Fargate + RDS private VPC)
- Framework: nextjs (default)
- Database: postgres (default)
- Skip deployment: $SKIP_DEPLOY (if true, do NOT set up container registry, Docker, or deployment infrastructure. Only provision database and services needed for local development.)

SKIP Steps 1 and 2 (already answered above). Start directly from Step 3 (Technical Architecture Scan).
Research the target product, generate ralph-config.json, check dependencies, rewrite config files, and install packages.
Output <promise>ONBOARD_COMPLETE</promise> when done.
Output <promise>ONBOARD_FAILED</promise> if any check fails.") || claude_exit=$?

echo "$result"

if [ "$claude_exit" -eq 124 ]; then
  echo ""
  echo "ERROR: Claude timed out after 30 minutes."
  exit 1
elif [ "$claude_exit" -ne 0 ]; then
  echo ""
  echo "ERROR: Claude exited with code $claude_exit"
  exit 1
fi

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

  # Check if Ever CLI is available before auto-starting the build loop
  if ! command -v ever &>/dev/null; then
    echo "Next step: install Ever CLI (needed for the Inspect phase)."
    echo "  Install: https://foreverbrowsing.com"
    echo "  Then start the loop: ./scripts/start.sh \"$TARGET_URL\""
  else
    echo "Starting the build loop..."
    ./scripts/start.sh "$TARGET_URL"
  fi
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
