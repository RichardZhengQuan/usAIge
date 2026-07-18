import { index, integer, sqliteTable, text } from "drizzle-orm/sqlite-core";

export const relayChannels = sqliteTable("relay_channels", {
  id: text("id").primaryKey(),
  macName: text("mac_name").notNull(),
  uploadTokenHash: text("upload_token_hash").notNull().unique(),
  snapshotJSON: text("snapshot_json"),
  snapshotHash: text("snapshot_hash"),
  snapshotVersion: integer("snapshot_version").notNull().default(0),
  createdAt: text("created_at").notNull(),
  lastUploadAt: text("last_upload_at"),
});

export const relayPairings = sqliteTable("relay_pairings", {
  id: text("id").primaryKey(),
  channelID: text("channel_id").notNull().references(() => relayChannels.id, { onDelete: "cascade" }),
  codeHash: text("code_hash").notNull().unique(),
  expiresAt: text("expires_at").notNull(),
  claimedAt: text("claimed_at"),
  failedAttempts: integer("failed_attempts").notNull().default(0),
  createdAt: text("created_at").notNull(),
});

export const relayDevices = sqliteTable("relay_devices", {
  id: text("id").primaryKey(),
  channelID: text("channel_id").notNull().references(() => relayChannels.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  readTokenHash: text("read_token_hash").notNull().unique(),
  apnsToken: text("apns_token"),
  apnsEnvironment: text("apns_environment"),
  lastPushAt: text("last_push_at"),
  createdAt: text("created_at").notNull(),
  lastSeenAt: text("last_seen_at").notNull(),
}, (table) => ({ channelIndex: index("relay_devices_channel_idx").on(table.channelID) }));

export const relayRateLimits = sqliteTable("relay_rate_limits", {
  key: text("key").primaryKey(),
  count: integer("count").notNull(),
  windowStartedAt: text("window_started_at").notNull(),
});
