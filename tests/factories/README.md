# Test Factories

Factories create realistic test data with sensible defaults, reducing boilerplate in tests.

## Pattern

Each factory is a function that accepts partial overrides and returns a complete object.
Integration tests use factories with the real database; unit tests use them as plain objects.

## Example Template

```typescript
// tests/factories/user.factory.ts
import { db } from "@/lib/db";
import { users } from "@/lib/db/schema";

let counter = 0;

function uniqueEmail() {
  return `user-${++counter}-${Date.now()}@example.com`;
}

export function buildUser(overrides: Partial<typeof users.$inferInsert> = {}) {
  return {
    id: crypto.randomUUID(),
    email: uniqueEmail(),
    name: "Test User",
    createdAt: new Date(),
    ...overrides,
  };
}

/** Insert a user into the real DB and return the row. */
export async function createUser(overrides: Partial<typeof users.$inferInsert> = {}) {
  const [row] = await db.insert(users).values(buildUser(overrides)).returning();
  return row;
}
```

## Usage in Unit Tests

```typescript
import { buildUser } from "../factories/user.factory";

test("formats display name", () => {
  const user = buildUser({ name: "Jane Doe" });
  expect(formatDisplayName(user)).toBe("Jane Doe");
});
```

## Usage in Integration Tests

```typescript
// tests/integration/users.test.ts
import { createUser } from "../factories/user.factory";

test("GET /api/users/:id returns the user", async () => {
  const user = await createUser({ name: "Integration User" });
  const res = await fetch(`http://localhost:3015/api/users/${user.id}`);
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(body.name).toBe("Integration User");
});
```

## Rules

- `build*` functions return plain objects — no DB calls, safe for unit tests.
- `create*` functions insert into the real DB — use only in integration tests.
- Always clean up after integration tests (use `afterEach` with `db.delete(...)` or run tests in transactions that roll back).
- Use counters or timestamps to ensure unique values across parallel test runs.
