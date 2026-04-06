// ABOUTME: Unit tests for DB_SSL env var behavior in src/lib/db/index.ts
// Verifies SSL is enabled when DB_SSL=true, disabled when unset/false

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Mock pg module to capture Pool constructor args
vi.mock("pg", () => {
  const MockPool = vi.fn();
  return { Pool: MockPool };
});

// Mock drizzle-orm to avoid real DB connection
vi.mock("drizzle-orm/node-postgres", () => ({
  drizzle: vi.fn(() => ({})),
}));

// Mock schema to avoid importing real tables
vi.mock("@/lib/db/schema", () => ({}));

describe("db/index.ts SSL configuration", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.unstubAllEnvs();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("enables SSL when DB_SSL=true", async () => {
    vi.stubEnv("DB_SSL", "true");
    vi.stubEnv("DATABASE_URL", "postgresql://localhost:5432/test");

    const { Pool } = await import("pg");
    await import("@/lib/db/index");

    expect(Pool).toHaveBeenCalledWith(
      expect.objectContaining({
        ssl: { rejectUnauthorized: false },
      }),
    );
  });

  it("disables SSL when DB_SSL is unset", async () => {
    vi.stubEnv("DATABASE_URL", "postgresql://localhost:5432/test");
    // biome-ignore lint/performance/noDelete: process.env needs delete — assignment coerces to string "undefined"
    delete process.env.DB_SSL;

    const { Pool } = await import("pg");
    await import("@/lib/db/index");

    expect(Pool).toHaveBeenCalledWith(
      expect.objectContaining({
        ssl: undefined,
      }),
    );
  });

  it("disables SSL when DB_SSL=false", async () => {
    vi.stubEnv("DB_SSL", "false");
    vi.stubEnv("DATABASE_URL", "postgresql://localhost:5432/test");

    const { Pool } = await import("pg");
    await import("@/lib/db/index");

    expect(Pool).toHaveBeenCalledWith(
      expect.objectContaining({
        ssl: undefined,
      }),
    );
  });

  it("disables SSL even with amazonaws.com in URL when DB_SSL is unset", async () => {
    vi.stubEnv(
      "DATABASE_URL",
      "postgresql://user:pass@mydb.amazonaws.com:5432/db",
    );
    // biome-ignore lint/performance/noDelete: process.env needs delete — assignment coerces to string "undefined"
    delete process.env.DB_SSL;

    const { Pool } = await import("pg");
    await import("@/lib/db/index");

    expect(Pool).toHaveBeenCalledWith(
      expect.objectContaining({
        ssl: undefined,
      }),
    );
  });
});
