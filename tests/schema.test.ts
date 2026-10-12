import { getTableConfig } from "drizzle-orm/pg-core";
import { describe, expect, it } from "vitest";
import { users } from "@/db/schema";

describe("db schema", () => {
  it("defines users with a unique tg_id", () => {
    const cfg = getTableConfig(users);
    expect(cfg.name).toBe("users");
    const tgId = cfg.columns.find((c) => c.name === "tg_id");
    expect(tgId?.notNull).toBe(true);
    expect(tgId?.isUnique).toBe(true);
  });
});
