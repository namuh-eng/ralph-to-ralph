# Ralph-to-Ralph Makefile — Universal Contract
#
# These targets define the interface between the ralph pipeline and your stack.
# Onboarding appends real recipes below the guard line based on your stackProfile.
# Every stack template must implement: dev, build, test, test-e2e, check, clean.

.PHONY: check test test-e2e typecheck lint format fix all dev build clean
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

# --- ONBOARDING TARGETS (appended by setup-stack.sh) ---
# --- typescript-nextjs targets (appended by onboarding) ---

typecheck:
	@. ./hack/run_silent.sh && \
	run_silent "TypeCheck passed" "npx tsc --noEmit"

lint:
	@. ./hack/run_silent.sh && \
	run_silent "Lint & Format passed" "npx biome check ."

fix:
	npx biome check --write .

format:
	npx biome format --write .

test: test-header
	@. ./hack/run_silent.sh && \
	run_silent_with_test_count "Unit Tests passed" "npx vitest run" "vitest"

test-e2e:
	@. ./hack/run_silent.sh && \
	run_silent_with_test_count "E2E Tests passed" "npx playwright test" "playwright"

dev:
	npm run dev

build:
	npm run build

db-generate:
	npx drizzle-kit generate --config drizzle.config.ts

db-migrate:
	npx drizzle-kit migrate --config drizzle.config.ts

db-push:
	npx drizzle-kit push --config drizzle.config.ts

clean:
	rm -rf .next dist node_modules/.cache
