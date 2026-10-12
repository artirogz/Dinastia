// Drizzle pool on postgres.js for the web process. pg-boss in the worker keeps its own pool
// (sizes: docs/06-bot-and-funnels.md §6). No next/* imports: the worker uses this module too.
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";

function createDb() {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  const client = postgres(url, { max: Number(process.env.DB_POOL_MAX ?? 10) });
  return drizzle(client, { schema });
}

let instance: ReturnType<typeof createDb> | undefined;

// Lazy so that importing the module (next build, tests) does not require a database.
export function getDb() {
  instance ??= createDb();
  return instance;
}
