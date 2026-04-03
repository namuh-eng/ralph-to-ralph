import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import * as schema from "./schema";

const connectionString = process.env.DATABASE_URL;
const needsSsl = process.env.DB_SSL === "true";

const pool = new Pool({
  connectionString,
  // rejectUnauthorized: false encrypts the connection but skips cert verification.
  // Managed Postgres providers (RDS, Cloud SQL, Azure) use self-signed or private
  // CAs that most clients don't trust by default. For stricter validation, set
  // ssl.ca to the provider's CA bundle path.
  ssl: needsSsl ? { rejectUnauthorized: false } : undefined,
});

export const db = drizzle(pool, { schema });
