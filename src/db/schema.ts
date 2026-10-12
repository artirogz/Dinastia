// Database schema (docs/02-data-model.md). M0 has only `users`; the remaining tables arrive in M2.
import { sql } from "drizzle-orm";
import { bigint, check, pgTable, serial, text, timestamp } from "drizzle-orm/pg-core";

const tstz = (name: string) => timestamp(name, { withTimezone: true });

export const users = pgTable(
  "users",
  {
    id: serial("id").primaryKey(),
    tgId: bigint("tg_id", { mode: "number" }).notNull().unique(),
    firstName: text("first_name"),
    lastName: text("last_name"),
    username: text("username"),
    photoUrl: text("photo_url"),
    languageCode: text("language_code"),
    role: text("role", { enum: ["user", "admin"] }).notNull().default("user"),
    consentAt: tstz("consent_at"),
    // which policy text the user accepted
    consentVersion: text("consent_version"),
    // separate consent for promotional messages (docs/06 §2)
    marketingConsentAt: tstz("marketing_consent_at"),
    // /stop; broadcasts skip the user while set
    marketingOptOutAt: tstz("marketing_opt_out_at"),
    // set on Telegram 403, cleared on next /start
    botBlockedAt: tstz("bot_blocked_at"),
    createdAt: tstz("created_at").notNull().defaultNow(),
    lastSeenAt: tstz("last_seen_at").notNull().defaultNow(),
    // /forget: name, username, photo wiped
    anonymizedAt: tstz("anonymized_at"),
    // account closed, row kept for orders integrity
    deletedAt: tstz("deleted_at"),
  },
  (t) => [check("users_role_check", sql`${t.role} in ('user', 'admin')`)],
);
