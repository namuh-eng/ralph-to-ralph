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
