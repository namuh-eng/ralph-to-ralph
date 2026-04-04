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
  if [ -f "ralph-config.json" ]; then
    echo "Config was generated. Re-run ./onboard.sh to resume from the build step."
  elif [ -f ".onboard-answers.tmp" ]; then
    echo "Your answers were saved. Re-run ./onboard.sh to skip re-entering them."
  else
    echo "No state was saved. Re-run ./onboard.sh to start fresh."
  fi
  echo ""
  echo "To reset everything: ./onboard.sh --reset"
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
  rm -f ralph-config.json .onboard-answers.tmp
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
if c['cloudProvider'] not in ('aws', 'gcp', 'azure', 'vercel', 'custom'):
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

# ── Detect saved Q&A answers from a previous interrupted run ──
_SKIP_QA=false
if [ -f ".onboard-answers.tmp" ] && [ ! -f "ralph-config.json" ]; then
  # shellcheck source=/dev/null
  source .onboard-answers.tmp
  echo "Found saved answers from a previous run:"
  echo "  Target:  $TARGET_URL"
  echo "  Clone:   $CLONE_NAME"
  echo "  Stack:   $CLOUD_PROVIDER${CUSTOM_STACK_DESC:+ (custom: $CUSTOM_STACK_DESC)}"
  echo ""
  read -rp "Resume with these? [Y/n]: " _RESUME_ANSWERS
  if [[ "${_RESUME_ANSWERS:-y}" =~ ^[Yy] ]]; then
    _SKIP_QA=true
    echo ""
  else
    rm -f .onboard-answers.tmp
    _SKIP_QA=false
  fi
fi

# ── Step 1: Collect user input interactively (bash handles Q&A) ──
# claude -p runs in pipe mode (no back-and-forth), so we collect answers
# here and pass them to Claude as context.
if [ "$_SKIP_QA" = false ]; then

read -rp "What product do you want to clone? (URL): " TARGET_URL
if [ -z "$TARGET_URL" ]; then
  echo "ERROR: Target URL is required."
  exit 1
fi
if ! [[ "$TARGET_URL" =~ ^https?:// ]]; then
  TARGET_URL="https://$TARGET_URL"
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
echo "Where should this clone run?"
echo ""
echo "  1) Vercel + Neon  (default — personal / solo dev)"
echo "     Deploy with 'vercel'. Serverless Postgres via Neon."
echo "     Free tier, zero ops. Best for building and experimenting."
echo ""
echo "  2) AWS — ECS Fargate + RDS  (team / production)"
echo "     Private VPC, ALB, RDS in private subnets."
echo "     Right architecture for shared use or real traffic."
echo ""
echo "  3) GCP  (experimental)"
echo "  4) Azure  (experimental)"
echo "  5) Custom — describe your own stack"
echo ""
read -rp "Choose stack [1]: " STACK_CHOICE
STACK_CHOICE="${STACK_CHOICE//[[:space:]]/}"  # strip whitespace
CUSTOM_STACK_DESC=""
GENERATOR="claude"
case "${STACK_CHOICE:-1}" in
  1|vercel) CLOUD_PROVIDER="vercel"; DEPLOYMENT_TIER="personal" ;;
  2|aws)    CLOUD_PROVIDER="aws";    DEPLOYMENT_TIER="team" ;;
  3|gcp)    CLOUD_PROVIDER="gcp";    DEPLOYMENT_TIER="team" ;;
  4|azure)  CLOUD_PROVIDER="azure";  DEPLOYMENT_TIER="team" ;;
  5|custom)
    CLOUD_PROVIDER="custom"
    DEPLOYMENT_TIER="custom"
    echo ""
    echo "Describe your stack. Be specific — include your deploy platform, database,"
    echo "and any cloud services the clone will need."
    echo "Examples:"
    echo "  'Railway + Neon — deploy to Railway, Postgres via Neon'"
    echo "  'Fly.io + Supabase — Fly.io for the app, Supabase for Postgres and storage'"
    echo "  'Docker Compose on a VPS — self-hosted, local Postgres, Nginx reverse proxy'"
    echo ""
    read -rp "Your stack: " CUSTOM_STACK_DESC
    if [ -z "$CUSTOM_STACK_DESC" ]; then
      echo "ERROR: Stack description is required for custom mode."
      exit 1
    fi
    echo ""
    echo "Generate the preflight script with:"
    echo "  1) Claude (default — better at reasoning about what your stack needs)"
    echo "  2) Codex  (strong at writing infrastructure scripts and bash)"
    echo ""
    read -rp "Choose generator [1]: " GEN_CHOICE
    case "${GEN_CHOICE:-1}" in
      2|codex)
        if command -v codex &>/dev/null; then
          GENERATOR="codex"
        else
          echo "Codex not found — falling back to Claude."
          echo "  Install Codex: npm install -g @openai/codex"
          GENERATOR="claude"
        fi
        ;;
      *) GENERATOR="claude" ;;
    esac
    ;;
  *)
    echo "Invalid choice. Using Vercel + Neon."
    CLOUD_PROVIDER="vercel"; DEPLOYMENT_TIER="personal"
    ;;
esac

# ── Verify cloud CLI is installed before the long research step ──
case "$CLOUD_PROVIDER" in
  vercel)
    if ! command -v vercel &>/dev/null; then
      echo ""
      echo "Vercel CLI is not installed."
      echo "  Run: npm install -g vercel"
      echo "  Then: vercel login"
      echo ""
      read -rp "Install now? [Y/n]: " _INSTALL_CHOICE
      if [[ "${_INSTALL_CHOICE:-y}" =~ ^[Yy] ]]; then
        npm install -g vercel
        echo ""
        echo "Now run: vercel login"
        read -rp "Press Enter once you've logged in..."
      else
        echo "Skipping. Re-run ./onboard.sh once Vercel CLI is installed."
        exit 1
      fi
    fi
    ;;
  aws)
    if ! command -v aws &>/dev/null; then
      echo ""
      echo "AWS CLI is not installed."
      echo "  Run: brew install awscli"
      echo "  Then: aws configure"
      echo ""
      read -rp "Install now? [Y/n]: " _INSTALL_CHOICE
      if [[ "${_INSTALL_CHOICE:-y}" =~ ^[Yy] ]]; then
        brew install awscli
        echo ""
        echo "Now run: aws configure"
        read -rp "Press Enter once you've configured AWS credentials..."
      else
        echo "Skipping. Re-run ./onboard.sh once AWS CLI is installed."
        exit 1
      fi
    fi
    ;;
  gcp)
    if ! command -v gcloud &>/dev/null; then
      echo ""
      echo "Google Cloud SDK is not installed."
      echo "  Install: https://cloud.google.com/sdk/docs/install"
      echo "  Then: gcloud auth login && gcloud config set project YOUR_PROJECT"
      echo ""
      read -rp "Open install page and continue once done? [Y/n]: " _INSTALL_CHOICE
      if [[ "${_INSTALL_CHOICE:-y}" =~ ^[Yy] ]]; then
        open "https://cloud.google.com/sdk/docs/install" 2>/dev/null || true
        read -rp "Press Enter once gcloud is installed and authenticated..."
        if ! command -v gcloud &>/dev/null; then
          echo "gcloud still not found. Re-run ./onboard.sh once installed."
          exit 1
        fi
      else
        echo "Skipping. Re-run ./onboard.sh once Google Cloud SDK is installed."
        exit 1
      fi
    fi
    ;;
  azure)
    if ! command -v az &>/dev/null; then
      echo ""
      echo "Azure CLI is not installed."
      echo "  Run: brew install azure-cli"
      echo "  Then: az login"
      echo ""
      read -rp "Install now? [Y/n]: " _INSTALL_CHOICE
      if [[ "${_INSTALL_CHOICE:-y}" =~ ^[Yy] ]]; then
        brew install azure-cli
        echo ""
        echo "Now run: az login"
        read -rp "Press Enter once you've logged in..."
      else
        echo "Skipping. Re-run ./onboard.sh once Azure CLI is installed."
        exit 1
      fi
    fi
    ;;
  custom)
    echo "Custom stack: will generate preflight using $GENERATOR."
    ;;
esac

echo ""
read -rp "Deploy to production after build? [Y/n]: " DEPLOY_CHOICE
if [[ "${DEPLOY_CHOICE:-y}" =~ ^[Nn] ]]; then
  SKIP_DEPLOY="true"
else
  SKIP_DEPLOY="false"
fi

fi  # end _SKIP_QA=false block

# Save answers so a Ctrl+C re-run can skip re-entering them
cat > .onboard-answers.tmp <<ANSWERS_EOF
TARGET_URL="$TARGET_URL"
CLONE_NAME="$CLONE_NAME"
CLOUD_PROVIDER="$CLOUD_PROVIDER"
DEPLOYMENT_TIER="$DEPLOYMENT_TIER"
CUSTOM_STACK_DESC="$CUSTOM_STACK_DESC"
GENERATOR="$GENERATOR"
SKIP_DEPLOY="$SKIP_DEPLOY"
ANSWERS_EOF

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
- Deployment tier: $DEPLOYMENT_TIER (personal = Vercel + Neon; team = ECS Fargate + RDS private VPC / GCP / Azure; custom = user-defined)
- Custom stack description: ${CUSTOM_STACK_DESC:-(none)}
- Preflight generator: $GENERATOR (claude = you write the preflight; codex = Claude writes ralph-config.json only, Codex generates preflight separately)
- Framework: nextjs (default)
- Database: postgres (default)
- Skip deployment: $SKIP_DEPLOY (if true, do NOT set up container registry, Docker, or deployment infrastructure. Only provision database and services needed for local development.)

SKIP Steps 1 and 2 (already answered above). Start directly from Step 3 (Technical Architecture Scan).
Research the target product, generate ralph-config.json, check dependencies, rewrite config files, and install packages.
If cloudProvider is 'custom' and generator is 'claude': also generate scripts/preflight.sh from the custom stack description.
If cloudProvider is 'custom' and generator is 'codex': generate ralph-config.json and all config files, but SKIP writing scripts/preflight.sh — Codex will generate it separately.
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
if c['cloudProvider'] not in ('aws', 'gcp', 'azure', 'vercel', 'custom'):
    print(f'ERROR: invalid cloudProvider: {c[\"cloudProvider\"]}', file=sys.stderr)
    sys.exit(1)
" || exit 1

  # ── Codex preflight generation (custom stack, generator=codex) ──
  if [ "$CLOUD_PROVIDER" = "custom" ] && [ "$GENERATOR" = "codex" ]; then
    echo ""
    echo "--- Generating preflight script with Codex... ---"
    _REPO_ROOT=$(git rev-parse --show-toplevel)
    codex exec "Generate a bash preflight script (scripts/preflight.sh) for the following stack:

Stack description: $CUSTOM_STACK_DESC
Clone name: $(python3 -c "import json; print(json.load(open('ralph-config.json'))['targetName'])" 2>/dev/null || echo '__APP_NAME__')
ralph-config.json: $(cat ralph-config.json 2>/dev/null || echo '{}')

Requirements:
- Write scripts/preflight.sh that provisions all infrastructure described above
- Script must be idempotent (safe to re-run)
- Use grep -q guards before appending DATABASE_URL and DB_SSL to .env
- Output clear progress messages for each step
- Exit with code 1 and a clear error message if any step fails
- End with: echo '=== Pre-flight Complete ==='" \
      -C "$_REPO_ROOT" -s write --approval-policy never 2>/dev/null || {
      echo "WARNING: Codex preflight generation failed. You may need to write scripts/preflight.sh manually."
    }
    if [ -f "scripts/preflight.sh" ]; then
      chmod +x scripts/preflight.sh
      echo "scripts/preflight.sh generated by Codex ✓"
    fi
  fi

  rm -f .onboard-answers.tmp

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
