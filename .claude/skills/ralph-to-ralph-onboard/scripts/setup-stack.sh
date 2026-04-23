#!/usr/bin/env bash
# setup-stack.sh — Scaffolds the project based on ralph-config.json stackProfile + language.
# Run by the onboarding agent after the user makes their stack choices.
# Idempotent: safe to run multiple times.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
TEMPLATES_DIR="$(dirname "$0")/../templates"
cd "$REPO_ROOT"

# --- Read config ---
if [ ! -f ralph-config.json ]; then
  echo "ERROR: ralph-config.json not found. Run onboarding first."
  exit 1
fi

LANGUAGE=$(node -e "console.log(JSON.parse(require('fs').readFileSync('ralph-config.json','utf8')).language || 'typescript')")
STACK_PROFILE=$(node -e "console.log(JSON.parse(require('fs').readFileSync('ralph-config.json','utf8')).stackProfile || 'dashboard-app')")

# Resolve template directory
# Template naming: {language}-{framework} or {language}-{stackProfile}
# e.g., typescript-nextjs, go-chi, python-fastapi
resolve_template() {
  local lang="$1"
  local profile="$2"

  # Direct match: language-specific profile template
  case "${lang}-${profile}" in
    typescript-dashboard-app) echo "typescript-nextjs" ;;
    typescript-api-service)   echo "typescript-nextjs" ;;
    typescript-content-app)   echo "typescript-nextjs" ;;
    typescript-realtime-app)  echo "typescript-nextjs" ;;
    typescript-platform)      echo "typescript-nextjs" ;;
    python-api-service)       echo "python-fastapi" ;;
    go-api-service)           echo "go-chi" ;;
    *) echo "${lang}-${profile}" ;;
  esac
}

TEMPLATE_NAME=$(resolve_template "$LANGUAGE" "$STACK_PROFILE")
TEMPLATE_DIR="${TEMPLATES_DIR}/${TEMPLATE_NAME}"

if [ ! -d "$TEMPLATE_DIR" ]; then
  echo "ERROR: No template found at ${TEMPLATE_DIR}"
  echo "Available templates:"
  ls -1 "$TEMPLATES_DIR" 2>/dev/null || echo "  (none)"
  exit 1
fi

echo "==> Setting up stack: ${LANGUAGE} / ${STACK_PROFILE} (template: ${TEMPLATE_NAME})"

# --- 1. Copy template root files to repo root ---
echo "  Copying template root files..."
while IFS= read -r template_file; do
  rel_path="${template_file#${TEMPLATE_DIR}/}"

  case "$rel_path" in
    src/*|.gitignore-append|makefile-targets.mk)
      continue
      ;;
  esac

  mkdir -p "${REPO_ROOT}/$(dirname "$rel_path")"
  cp "$template_file" "${REPO_ROOT}/${rel_path}"
  echo "    → ${rel_path}"
done < <(find "$TEMPLATE_DIR" -type f | sort)

# --- 2. Copy source scaffolding (src/, preserving existing files) ---
if [ -d "${TEMPLATE_DIR}/src" ]; then
  echo "  Copying source scaffolding..."
  # Use cp -rn to not overwrite existing files (macOS), or cp --no-clobber (Linux)
  if cp -rn "${TEMPLATE_DIR}/src/" "${REPO_ROOT}/src/" 2>/dev/null; then
    true
  else
    # Fallback: use rsync to skip existing
    rsync -a --ignore-existing "${TEMPLATE_DIR}/src/" "${REPO_ROOT}/src/"
  fi
fi

# --- 3. Append .gitignore entries ---
if [ -f "${TEMPLATE_DIR}/.gitignore-append" ]; then
  echo "  Updating .gitignore..."
  # Only append lines not already present
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    grep -qxF "$line" .gitignore 2>/dev/null || echo "$line" >> .gitignore
  done < "${TEMPLATE_DIR}/.gitignore-append"
fi

# --- 4. Append Makefile targets ---
if [ -f "${TEMPLATE_DIR}/makefile-targets.mk" ]; then
  # Check if real targets (not just the sentinel comment) have been appended
  if ! grep -q "^typecheck:" Makefile 2>/dev/null; then
    echo "  Appending Makefile targets..."
    cat "${TEMPLATE_DIR}/makefile-targets.mk" >> Makefile
  else
    echo "  Makefile targets already appended, skipping."
  fi
fi

# --- 5. Install dependencies ---
# Do NOT silence stderr — a failed install here leaves the project unbootable
# and we need the user to see the real error.
echo "  Installing dependencies..."
case "$LANGUAGE" in
  typescript|javascript)
    npm install
    # Install Playwright browsers if playwright config exists
    if [ -f playwright.config.ts ]; then
      npx playwright install chromium || true
    fi
    ;;
  go)
    if [ -f go.mod ]; then
      go mod download
    fi
    ;;
  python)
    if [ -f pyproject.toml ] || [ -f requirements.txt ]; then
      if command -v python3 >/dev/null 2>&1; then
        if python3 -m pip --version >/dev/null 2>&1; then
          if [ -f pyproject.toml ]; then
            python3 -m pip install ".[dev]"
          else
            python3 -m pip install -r requirements.txt
          fi
        else
          echo "ERROR: python3 is installed but pip is unavailable."
          exit 1
        fi
      elif command -v pip3 >/dev/null 2>&1; then
        if [ -f pyproject.toml ]; then
          pip3 install ".[dev]"
        else
          pip3 install -r requirements.txt
        fi
      elif command -v pip >/dev/null 2>&1; then
        if [ -f pyproject.toml ]; then
          pip install ".[dev]"
        else
          pip install -r requirements.txt
        fi
      else
        echo "ERROR: Python dependencies requested but no pip installer was found."
        exit 1
      fi
    fi
    ;;
  rust)
    if [ -f Cargo.toml ]; then
      cargo fetch || true
    fi
    ;;
esac

# --- 6. Create marker file ---
echo "${TEMPLATE_NAME}" > .ralph-setup-done
echo ""
echo "==> Stack setup complete! (${TEMPLATE_NAME})"
echo "    Run: make dev"
