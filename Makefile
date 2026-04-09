.PHONY: check test test-e2e test-integration typecheck lint format fix all dev down logs build clean db-studio
.PHONY: check-header test-header check-verbose test-verbose

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

# Docker Compose dev environment (starts postgres + redis + mailpit, then dev server)
dev:
	docker compose -f docker-compose.dev.yml up -d && npm run dev

down:
	docker compose -f docker-compose.dev.yml down

logs:
	docker compose -f docker-compose.dev.yml logs -f

# Integration tests (real DB, not mocks)
test-integration:
	@. ./hack/run_silent.sh && \
	run_silent_with_test_count "Integration Tests passed" "npx vitest run --config vitest.config.ts --reporter=verbose tests/integration" "vitest"

# Drizzle Studio
db-studio:
	npx drizzle-kit studio --config drizzle.config.ts

# Clean build artifacts
clean:
	rm -rf .next dist node_modules/.cache
