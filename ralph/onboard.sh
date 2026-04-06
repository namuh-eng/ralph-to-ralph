#!/bin/bash
# Pre-loop onboarding: collect target info, research stack, generate config
# Run this BEFORE start.sh — it calls start.sh automatically on success
set -euo pipefail
cd "$(dirname "$0")/.."

# ── Cleanup on interrupt ──
cleanup() {
  echo ""
  echo ""
  echo "=== Onboarding interrupted ==="
  echo ""
  if [ -f "ralph-config.json" ]; then
    echo "Config was generated. Re-run ./ralph/onboard.sh to resume from the build step."
  elif [ -f ".onboard-answers.tmp" ]; then
    echo "Your answers were saved. Re-run ./ralph/onboard.sh to skip re-entering them."
  else
    echo "No state was saved. Re-run ./ralph/onboard.sh to start fresh."
  fi
  echo ""
  echo "To reset everything: ./ralph/onboard.sh --reset"
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
    "ralph/pre-setup.md"
    "CLAUDE.md"
    "ralph/inspect-prompt.md"
    "ralph/build-prompt.md"
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
  echo "Reset complete. Run ./ralph/onboard.sh to start fresh."
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

# ── Detect if user cloned the template directly (still has ralph-to-ralph as remote) ──
_REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if echo "$_REMOTE_URL" | grep -qiE "(jaeyunha|namuh-eng)/ralph-to-ralph"; then
  echo "It looks like you cloned ralph-to-ralph directly."
  echo "To start your own project, you should reinitialize git with a clean history."
  echo ""
  echo "  1) Reinitialize git now (recommended)"
  echo "  2) Keep the existing history and continue"
  echo ""
  read -rp "Choose [1]: " _GIT_INIT_CHOICE
  if [[ "${_GIT_INIT_CHOICE:-1}" == "1" ]]; then
    echo ""
    echo "Reinitializing git..."
    rm -rf .git
    git init -q
    git add .
    git -c user.email="user@localhost" -c user.name="User" commit -q -m "init: start project from ralph-to-ralph" 2>/dev/null \
      || git commit -q -m "init: start project from ralph-to-ralph" \
      || { echo "Warning: could not create initial commit (run 'git config --global user.email/user.name' first)."; }
    echo "Done. Your project now has a clean git history."
    echo "Set your own remote with: git remote add origin https://github.com/YOU/YOUR_REPO.git"
    echo ""
  fi
fi

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
" || { echo "Config is invalid. Run ./ralph/onboard.sh --reset to start fresh."; exit 1; }
      TARGET_URL=$(python3 -c "import json; print(json.load(open('ralph-config.json'))['targetUrl'])")
      BROWSER_AGENT=$(python3 -c "import json; print(json.load(open('ralph-config.json')).get('browserAgent', 'ever'))" 2>/dev/null || echo "ever")
      echo ""
      echo "=== Resuming with existing config ==="
      echo "Target: $TARGET_URL"
      echo ""
      if [ "${BROWSER_AGENT:-ever}" = "ever" ] && ! command -v ever &>/dev/null; then
        echo "Next step: install Ever CLI (needed for the Inspect phase)."
        echo "  Install: https://foreverbrowsing.com"
        echo "  Then start the loop: ./scripts/start.sh \"$TARGET_URL\""
      elif [ "${BROWSER_AGENT:-ever}" = "stagehand" ] && ! node -e "require('@browserbasehq/stagehand')" &>/dev/null; then
        echo "Next step: install Stagehand."
        echo "  Run: npm install @browserbasehq/stagehand"
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
      exec "$(dirname "$0")/onboard.sh"
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

# ── Verify cloud CLI is installed AND authenticated before the long research step ──
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
      else
        echo "Skipping. Re-run ./ralph/onboard.sh once Vercel CLI is installed."
        exit 1
      fi
    fi
    # Verify authentication (not just installation)
    if ! vercel whoami &>/dev/null; then
      echo ""
      echo "Vercel CLI is installed but not logged in. Launching vercel login..."
      echo ""
      vercel login
      if ! vercel whoami &>/dev/null; then
        echo "Still not logged in. Re-run ./ralph/onboard.sh once authenticated."
        exit 1
      fi
    fi
    echo "Vercel CLI: logged in as $(vercel whoami 2>/dev/null)"
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
      else
        echo "Skipping. Re-run ./ralph/onboard.sh once AWS CLI is installed."
        exit 1
      fi
    fi
    # Verify authentication (not just installation)
    if ! aws sts get-caller-identity &>/dev/null; then
      echo ""
      echo "AWS CLI is installed but not authenticated. Launching aws configure..."
      echo "  You'll need your Access Key ID, Secret Access Key, and region."
      echo ""
      aws configure
      if ! aws sts get-caller-identity &>/dev/null; then
        echo "Still not authenticated. Re-run ./ralph/onboard.sh once configured."
        exit 1
      fi
    fi
    echo "AWS CLI: authenticated ($(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null))"
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
          echo "gcloud still not found. Re-run ./ralph/onboard.sh once installed."
          exit 1
        fi
      else
        echo "Skipping. Re-run ./ralph/onboard.sh once Google Cloud SDK is installed."
        exit 1
      fi
    fi
    # Verify authentication (not just installation)
    if ! gcloud auth print-identity-token &>/dev/null; then
      echo ""
      echo "Google Cloud SDK is installed but not authenticated. Launching gcloud auth login..."
      echo ""
      gcloud auth login
      echo ""
      read -rp "Enter your GCP project ID: " _GCP_PROJECT
      if [ -n "$_GCP_PROJECT" ]; then
        gcloud config set project "$_GCP_PROJECT"
      fi
      if ! gcloud auth print-identity-token &>/dev/null; then
        echo "Still not authenticated. Re-run ./ralph/onboard.sh once configured."
        exit 1
      fi
    fi
    echo "GCP CLI: authenticated"
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
      else
        echo "Skipping. Re-run ./ralph/onboard.sh once Azure CLI is installed."
        exit 1
      fi
    fi
    # Verify authentication (not just installation)
    if ! az account show &>/dev/null; then
      echo ""
      echo "Azure CLI is installed but not logged in. Launching az login..."
      echo ""
      az login
      if ! az account show &>/dev/null; then
        echo "Still not logged in. Re-run ./ralph/onboard.sh once authenticated."
        exit 1
      fi
    fi
    echo "Azure CLI: authenticated ($(az account show --query 'name' --output tsv 2>/dev/null))"
    ;;
  custom)
    echo "Custom stack: will generate preflight using $GENERATOR."
    ;;
esac

# ── Verify .env has required keys ──
echo ""
echo "--- Checking .env ---"
_ENV_WARNINGS=()

# Create .env from example if it doesn't exist
if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    # Strip placeholder DATABASE_URL so the preflight script can write the real one.
    # The grep -q guard in preflight templates skips writing if any DATABASE_URL exists,
    # so copying the placeholder would block the real URL from ever being set.
    grep -v '^DATABASE_URL=postgresql://user:password@' .env.example > .env
    echo "Created .env from .env.example — fill in your values."
  else
    touch .env
    echo "Created empty .env — you'll need to add keys."
  fi
fi

# Check ANTHROPIC_API_KEY (deferrable — only needed if clone has AI features)
if ! grep -q '^ANTHROPIC_API_KEY=.\+' .env 2>/dev/null || grep -q '^ANTHROPIC_API_KEY=sk-ant-your-key-here' .env 2>/dev/null; then
  _ENV_WARNINGS+=("ANTHROPIC_API_KEY not set in .env (needed if clone has AI features)")
  echo "  Warning: ANTHROPIC_API_KEY not found or still using placeholder in .env"
  echo "    Get a key at https://console.anthropic.com"
  echo "    Add to .env: ANTHROPIC_API_KEY=sk-ant-api03-..."
fi

# Check DASHBOARD_KEY (deferrable — simple auth for admin dashboard)
if ! grep -q '^DASHBOARD_KEY=.\+' .env 2>/dev/null || grep -q '^DASHBOARD_KEY=your-dashboard-key' .env 2>/dev/null; then
  _ENV_WARNINGS+=("DASHBOARD_KEY not set or still using placeholder in .env")
  echo "  Warning: DASHBOARD_KEY not configured in .env"
  echo "    Set a strong random value: DASHBOARD_KEY=\$(openssl rand -hex 32)"
fi

if [ ${#_ENV_WARNINGS[@]} -eq 0 ]; then
  echo "  All .env keys present"
else
  echo ""
  echo "  ${#_ENV_WARNINGS[@]} warning(s) above — these are deferrable, continuing."
  echo "  You can fix them later before starting the build loop."
fi

echo ""
read -rp "Deploy to production after build? [Y/n]: " DEPLOY_CHOICE
if [[ "${DEPLOY_CHOICE:-y}" =~ ^[Nn] ]]; then
  SKIP_DEPLOY="true"
else
  SKIP_DEPLOY="false"
fi

echo ""
echo "Which browser agent for inspecting and QA-testing the product?"
echo ""
echo "  1) Ever CLI    (recommended — visual AI browser agent)"
echo "     Best for inspecting the target product visually."
echo "     Install: https://foreverbrowsing.com"
echo ""
echo "  2) Playwright  (already installed — scripted automation)"
echo "     Uses npx playwright to browse and screenshot pages."
echo ""
echo "  3) Stagehand   (AI-powered via Browserbase)"
echo "     Install: npm install @browserbasehq/stagehand"
echo ""
echo "  4) Custom — describe your own"
echo ""
read -rp "Choose browser agent [1]: " BROWSER_CHOICE
BROWSER_CHOICE="${BROWSER_CHOICE//[[:space:]]/}"
BROWSER_AGENT_DESC=""
case "${BROWSER_CHOICE:-1}" in
  1|ever)       BROWSER_AGENT="ever" ;;
  2|playwright) BROWSER_AGENT="playwright" ;;
  3|stagehand)  BROWSER_AGENT="stagehand" ;;
  4|custom)
    BROWSER_AGENT="custom"
    echo ""
    read -rp "Describe your browser agent: " BROWSER_AGENT_DESC
    if [ -z "$BROWSER_AGENT_DESC" ]; then
      echo "ERROR: Description is required for custom browser agent."
      exit 1
    fi
    ;;
  *)
    echo "Invalid choice. Using Ever CLI."
    BROWSER_AGENT="ever"
    ;;
esac

fi  # end _SKIP_QA=false block

# ── Re-verify cloud CLI auth if resuming (sessions can expire between runs) ──
if [ "$_SKIP_QA" = true ] && [ "$CLOUD_PROVIDER" != "custom" ]; then
  _auth_ok=false
  case "$CLOUD_PROVIDER" in
    vercel) vercel whoami &>/dev/null && _auth_ok=true ;;
    aws)    aws sts get-caller-identity &>/dev/null && _auth_ok=true ;;
    gcp)    gcloud auth print-identity-token &>/dev/null && _auth_ok=true ;;
    azure)  az account show &>/dev/null && _auth_ok=true ;;
  esac
  if [ "$_auth_ok" = false ]; then
    echo ""
    echo "ERROR: $CLOUD_PROVIDER CLI session has expired."
    echo "Re-run ./ralph/onboard.sh to re-authenticate."
    echo "(Your answers are saved in .onboard-answers.tmp — stack selection will be remembered.)"
    exit 1
  fi
fi

# Save answers so a Ctrl+C re-run can skip re-entering them
# Use printf %q to safely escape arbitrary user input (quotes, $(...), backticks)
{
  printf 'TARGET_URL=%q\n'       "$TARGET_URL"
  printf 'CLONE_NAME=%q\n'       "$CLONE_NAME"
  printf 'CLOUD_PROVIDER=%q\n'   "$CLOUD_PROVIDER"
  printf 'DEPLOYMENT_TIER=%q\n'  "$DEPLOYMENT_TIER"
  printf 'CUSTOM_STACK_DESC=%q\n' "$CUSTOM_STACK_DESC"
  printf 'GENERATOR=%q\n'        "$GENERATOR"
  printf 'SKIP_DEPLOY=%q\n'      "$SKIP_DEPLOY"
  printf 'BROWSER_AGENT=%q\n'    "$BROWSER_AGENT"
  printf 'BROWSER_AGENT_DESC=%q\n' "$BROWSER_AGENT_DESC"
} > .onboard-answers.tmp

echo ""
echo "--- Summary ---"
echo "Target:    $TARGET_URL"
echo "Clone:     $CLONE_NAME"
echo "Cloud:     $CLOUD_PROVIDER"
echo "Framework: Next.js 16 (default)"
echo "Database:  Postgres (default)"
if [ "$SKIP_DEPLOY" = "true" ]; then
  _DEPLOY_LABEL="No (build locally only)"
elif [ "$CLOUD_PROVIDER" = "vercel" ]; then
  _DEPLOY_LABEL="Yes (vercel --prod)"
else
  _DEPLOY_LABEL="Yes (Docker → cloud)"
fi
echo "Deploy:    $_DEPLOY_LABEL"
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

# ── Verify Claude Code can make API calls before the long research step ──
if ! claude -p "echo ok" --max-turns 1 &>/dev/null; then
  echo "ERROR: Claude Code is not authenticated or cannot reach the API."
  echo "  Run: claude login"
  echo "  Or set ANTHROPIC_API_KEY in your environment."
  exit 1
fi

# ── Step 2: Claude handles research + config generation (no Q&A needed) ──
claude_exit=0
result=$(timeout 1800 claude -p --dangerously-skip-permissions --model claude-opus-4-6 \
"@ralph/onboard-prompt.md @ralph/pre-setup.md @CLAUDE.md

The user has already provided their answers:
- Target URL: $TARGET_URL
- Clone name: $CLONE_NAME
- Cloud provider: $CLOUD_PROVIDER
- Deployment tier: $DEPLOYMENT_TIER (personal = Vercel + Neon; team = ECS Fargate + RDS private VPC / GCP / Azure; custom = user-defined)
- Custom stack description: ${CUSTOM_STACK_DESC:-(none)}
- Preflight generator: $GENERATOR (claude = you write the preflight; codex = Claude writes ralph-config.json only, Codex generates preflight separately)
- Framework: nextjs (default)
- Database: postgres (default)
- Skip deployment: $SKIP_DEPLOY (if true, do NOT set up deployment infrastructure — only provision database and services needed for local development. If false and cloudProvider is 'vercel', deploy via 'vercel --prod' — no Docker needed. If false and cloudProvider is 'aws'/'gcp'/'azure', build a Docker image and push to the cloud container registry.)
- Browser agent: $BROWSER_AGENT (ever = Ever CLI for visual inspection; playwright = npx playwright scripted; stagehand = @browserbasehq/stagehand AI agent; custom = $BROWSER_AGENT_DESC). Set this as 'browserAgent' in ralph-config.json.

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
if [[ "$result" == *"<promise>ONBOARD_FAILED</promise>"* ]]; then
  echo ""
  echo "=== Onboarding failed ==="
  echo "Fix the issues above and re-run: ./onboard.sh"
  exit 1
elif [[ "$result" == *"<promise>ONBOARD_COMPLETE</promise>"* ]]; then
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

  # ── Write setup verification results to ralph-config.json ──
  python3 -c "
import json, subprocess, os

config = json.load(open('ralph-config.json'))
provider = config.get('cloudProvider', '')
browser = config.get('browserAgent', 'ever')
setup = {'verified': [], 'pending': [], 'checks': {}}

# Node.js check
try:
    ver = subprocess.check_output(['node', '-v'], stderr=subprocess.DEVNULL).decode().strip()
    major = int(ver.lstrip('v').split('.')[0])
    if major >= 20:
        setup['verified'].append('node')
        setup['checks']['node'] = {'command': 'node -v', 'status': 'pass', 'detail': ver}
    else:
        setup['pending'].append('node')
        setup['checks']['node'] = {'command': 'node -v', 'status': 'fail', 'error': f'version {ver} < 20'}
except Exception:
    setup['pending'].append('node')
    setup['checks']['node'] = {'command': 'node -v', 'status': 'fail', 'error': 'not found'}

# Cloud CLI auth check
cli_checks = {
    'vercel': ('vercel-cli', ['vercel', 'whoami']),
    'aws': ('aws-cli', ['aws', 'sts', 'get-caller-identity']),
    'gcp': ('gcp-cli', ['gcloud', 'auth', 'print-identity-token']),
    'azure': ('azure-cli', ['az', 'account', 'show']),
}
if provider in cli_checks:
    name, cmd = cli_checks[provider]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
        setup['verified'].append(name)
        detail = out.split('\n')[0][:80] if out else 'authenticated'
        setup['checks'][name] = {'command': ' '.join(cmd), 'status': 'pass', 'detail': detail}
    except Exception:
        setup['pending'].append(name)
        setup['checks'][name] = {'command': ' '.join(cmd), 'status': 'fail', 'error': 'not authenticated'}

# .env key checks
env_vars = {}
if os.path.exists('.env'):
    with open('.env') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                env_vars[k] = v

for key, label, critical in [
    ('ANTHROPIC_API_KEY', 'anthropic-api-key', False),
    ('DATABASE_URL', 'database-url', True),
    ('DASHBOARD_KEY', 'dashboard-key', False),
]:
    placeholder_values = {'your-dashboard-key', 'sk-ant-your-key-here', 'postgresql://user:password@host:5432/dbname', ''}
    val = env_vars.get(key, '')
    if val and val not in placeholder_values:
        setup['verified'].append(label)
        setup['checks'][label] = {'envVar': key, 'status': 'pass'}
    else:
        setup['pending'].append(label)
        status = 'fail' if critical else 'skip'
        error = 'not set in .env' if not val else 'still using placeholder value'
        setup['checks'][label] = {'envVar': key, 'status': status, 'error': error}

# Browser agent check
if browser == 'ever':
    try:
        subprocess.check_output(['ever', '--version'], stderr=subprocess.DEVNULL)
        setup['verified'].append('ever-cli')
        setup['checks']['ever-cli'] = {'command': 'ever --version', 'status': 'pass'}
    except Exception:
        setup['pending'].append('ever-cli')
        setup['checks']['ever-cli'] = {'command': 'ever --version', 'status': 'skip', 'error': 'not installed (can use Playwright instead)'}

config['setup'] = setup
with open('ralph-config.json', 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')

# Print summary
print('')
print('--- Setup Verification ---')
for name in setup['verified']:
    check = setup['checks'][name]
    detail = check.get('detail', '')
    print(f'  ✓ {name}' + (f' — {detail}' if detail else ''))
for name in setup['pending']:
    check = setup['checks'][name]
    error = check.get('error', 'unknown')
    print(f'  ✗ {name} — {error}')
if not setup['pending']:
    print('  All checks passed!')
print('')
"

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

  # Check if required browser agent is available before auto-starting the build loop
  if [ "${BROWSER_AGENT:-ever}" = "ever" ] && ! command -v ever &>/dev/null; then
    echo "Next step: install Ever CLI (needed for the Inspect phase)."
    echo "  Install: https://foreverbrowsing.com"
    echo "  Then start the loop: ./scripts/start.sh \"$TARGET_URL\""
  elif [ "${BROWSER_AGENT:-ever}" = "stagehand" ] && ! node -e "require('@browserbasehq/stagehand')" &>/dev/null; then
    echo "Next step: install Stagehand."
    echo "  Run: npm install @browserbasehq/stagehand"
    echo "  Then start the loop: ./scripts/start.sh \"$TARGET_URL\""
  else
    echo "Starting the build loop..."
    ./scripts/start.sh "$TARGET_URL"
  fi
else
  echo ""
  echo "=== Onboarding did not complete ==="
  echo "Re-run: ./onboard.sh"
  exit 1
fi
