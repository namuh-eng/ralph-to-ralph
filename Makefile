# Ralph-to-Ralph Makefile — Universal Contract
#
# These targets define the interface between the ralph pipeline and your stack.
# Onboarding appends real recipes below the guard line based on your stackProfile.
# Every stack template must implement: dev, build, test, test-e2e, check, clean.

.PHONY: check test test-e2e typecheck lint format fix all dev build clean validate
.PHONY: check-header test-header check-verbose test-verbose
.PHONY: db-generate db-migrate db-push

# --- Guard: ensure onboarding has run ---
SETUP_DONE := $(wildcard .ralph-setup-done)

ifndef SETUP_DONE
$(error Stack not set up. Run onboarding first: /ralph-to-ralph-onboard)
endif

# Full validation: check + test
all: check test

# Static analysis: typecheck + lint/format
check: check-header typecheck lint

# TypeScript type checking
 typecheck:
	@. ./hack/run_silent.sh && \
	run_silent "TypeCheck passed" "npx tsc --noEmit"

# Lint and format check (Biome)
lint:
	@. ./hack/run_silent.sh && \
	run_silent "Lint & Format passed" "npx biome check ."

# Auto-fix lint and format issues
fix:
	npx biome check --write .

format:
	npx biome format --write .

# Unit tests (Vitest) — only shows failures, summary on success
test: test-header
	@. ./hack/run_silent.sh && \
	run_silent_with_test_count "Unit Tests passed" "npx vitest run" "vitest"

# E2E tests (Playwright — requires dev server running)
test-e2e:
	@. ./hack/run_silent.sh && \
	run_silent_with_test_count "E2E Tests passed" "npx playwright test" "playwright"

# Headers
check-header:
	@sh -n ./hack/run_silent.sh || (echo "Shell script syntax error" && exit 1)
	@. ./hack/run_silent.sh && print_main_header "Running Checks"

test-header:
	@sh -n ./hack/run_silent.sh || (echo "Shell script syntax error" && exit 1)
	@. ./hack/run_silent.sh && print_main_header "Running Tests"

# Verbose versions (show full output)
check-verbose:
	@VERBOSE=1 $(MAKE) check

test-verbose:
	@VERBOSE=1 $(MAKE) test

# Dev server
dev:
	npm run dev

# Production build
build:
	npm run build

# Database migrations
db-generate:
	npx drizzle-kit generate --config drizzle.config.ts

db-migrate:
	npx drizzle-kit migrate --config drizzle.config.ts

db-push:
	npx drizzle-kit push --config drizzle.config.ts

# Clean build artifacts
clean:
	rm -rf .next dist node_modules/.cache

# Validate state files against JSON schemas
validate:
	node scripts/validate-schemas.mjs
