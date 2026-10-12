// Liveness for infra/deploy.sh, the compose healthcheck and scripts/visual-check.mjs:
// 200 when the database answers, 503 otherwise.
import { sql } from "drizzle-orm";
import { connection } from "next/server";
import { getDb } from "@/db/client";

export async function GET() {
  await connection();
  try {
    await getDb().execute(sql`select 1`);
    return Response.json({ ok: true });
  } catch {
    return Response.json({ ok: false }, { status: 503 });
  }
}
