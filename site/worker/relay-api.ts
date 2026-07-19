export interface RelayEnv {
  DB: D1Database;
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_TOPIC?: string;
}

type RelayContext = { waitUntil(promise: Promise<unknown>): void };
type ChannelRow = { id: string; mac_name: string; upload_token_hash: string; snapshot_json: string | null; snapshot_version: number; last_upload_at: string | null };
type DeviceRow = { id: string; channel_id: string; name: string; read_token_hash: string; apns_token: string | null; apns_environment: string | null; last_push_at: string | null; session_notifications_enabled: number };
type SessionEvent = { schemaVersion: 1; eventID: string; kind: "finished" | "error" | "permission_needed"; sessionTitle: string; workspaceName: string; occurredAt: string };
type RemoteToolRow = { id: string; channel_id: string; name: string; symbol_name: string; website_url: string | null; write_token_hash: string; snapshot_json: string | null; created_at: string; last_upload_at: string | null };

const encoder = new TextEncoder();
const pairingAlphabet = "0123456789";
const pairingLifetimeMs = 10 * 60_000;
const pushIntervalMs = 20 * 60_000;
const maximumBodyBytes = 256 * 1024;
let cachedProviderToken: { value: string; createdAt: number } | undefined;
let schemaReady: Promise<void> | undefined;

export async function handleRelayRequest(request: Request, env: RelayEnv, ctx: RelayContext): Promise<Response | null> {
  const url = new URL(request.url);
  if (!url.pathname.startsWith("/api/v1/")) return null;
  if (!env.DB) return json({ error: "Relay storage is unavailable." }, 503);

  try {
    await ensureRelaySchema(env.DB);
    if (request.method === "POST" && url.pathname === "/api/v1/channels") {
      await enforceRateLimit(env.DB, `create:${clientAddress(request)}`, 10, 60 * 60_000);
      const payload = await readJSON(request) as { macName?: string };
      const macName = cleanName(payload.macName, "Mac");
      const channelID = crypto.randomUUID();
      const uploadToken = randomToken("usg_mac_");
      const now = new Date();
      await env.DB.prepare("INSERT INTO relay_channels (id, mac_name, upload_token_hash, created_at) VALUES (?, ?, ?, ?)")
        .bind(channelID, macName, await sha256(uploadToken), now.toISOString()).run();
      const pairing = await createPairing(env.DB, channelID, now);
      return json({ channelID, uploadToken, macName, ...pairing }, 201);
    }

    if (request.method === "POST" && url.pathname === "/api/v1/pairings/claim") {
      await enforceRateLimit(env.DB, `claim:${clientAddress(request)}`, 20, 15 * 60_000);
      const payload = await readJSON(request) as { code?: string; deviceName?: string };
      const normalizedCode = normalizeCode(payload.code);
      const pairing = await env.DB.prepare(
        "SELECT id, channel_id, expires_at, claimed_at, failed_attempts FROM relay_pairings WHERE code_hash = ?"
      ).bind(await sha256(normalizedCode)).first<{ id: string; channel_id: string; expires_at: string; claimed_at: string | null; failed_attempts: number }>();
      if (!pairing || pairing.claimed_at || Date.parse(pairing.expires_at) <= Date.now() || pairing.failed_attempts >= 5) {
        return json({ error: "That pairing code is invalid or expired." }, 400);
      }
      const deviceID = crypto.randomUUID();
      const readToken = randomToken("usg_ios_");
      const now = new Date().toISOString();
      const deviceName = cleanName(payload.deviceName, "iPhone");
      const claim = await env.DB.prepare("UPDATE relay_pairings SET claimed_at = ? WHERE id = ? AND claimed_at IS NULL")
        .bind(now, pairing.id).run();
      if ((claim.meta.changes ?? 0) !== 1) return json({ error: "That pairing code is invalid or expired." }, 400);
      await env.DB.prepare("INSERT INTO relay_devices (id, channel_id, name, read_token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?)")
        .bind(deviceID, pairing.channel_id, deviceName, await sha256(readToken), now, now).run();
      const channel = await channelByID(env.DB, pairing.channel_id);
      return json({ channelID: pairing.channel_id, deviceID, readToken, macName: channel?.mac_name ?? "Mac" }, 201);
    }

    if (request.method === "POST" && url.pathname === "/api/v1/tool-pairings/claim") {
      await enforceRateLimit(env.DB, `tool-claim:${clientAddress(request)}`, 20, 15 * 60_000);
      const payload = await readJSON(request) as { code?: string; toolName?: string; symbolName?: string; websiteURL?: string };
      const normalizedCode = normalizeCode(payload.code);
      const pairing = await env.DB.prepare(
        "SELECT id, channel_id, expires_at, claimed_at FROM relay_tool_pairings WHERE code_hash = ?"
      ).bind(await sha256(normalizedCode)).first<{ id: string; channel_id: string; expires_at: string; claimed_at: string | null }>();
      if (!pairing || pairing.claimed_at || Date.parse(pairing.expires_at) <= Date.now()) {
        return json({ error: "That pairing code is invalid or expired." }, 400);
      }
      const toolID = crypto.randomUUID();
      const writeToken = randomToken("usg_tool_");
      const now = new Date().toISOString();
      const toolName = cleanName(payload.toolName, "Remote AI Tool");
      const symbolName = cleanSymbolName(payload.symbolName);
      const websiteURL = cleanWebsiteURL(payload.websiteURL);
      const claim = await env.DB.prepare("UPDATE relay_tool_pairings SET claimed_at = ? WHERE id = ? AND claimed_at IS NULL")
        .bind(now, pairing.id).run();
      if ((claim.meta.changes ?? 0) !== 1) return json({ error: "That pairing code is invalid or expired." }, 400);
      await env.DB.prepare("INSERT INTO relay_remote_tools (id, channel_id, name, symbol_name, website_url, write_token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)")
        .bind(toolID, pairing.channel_id, toolName, symbolName, websiteURL, await sha256(writeToken), now).run();
      const uploadURL = `${url.origin}/api/v1/channels/${pairing.channel_id}/tools/${toolID}/snapshot`;
      return json({ channelID: pairing.channel_id, toolID, writeToken, uploadURL }, 201);
    }

    const channelMatch = url.pathname.match(/^\/api\/v1\/channels\/([^/]+)(?:\/(.*))?$/);
    if (!channelMatch) return json({ error: "Not found." }, 404);
    const channelID = channelMatch[1];
    const tail = channelMatch[2] ?? "";
    const channel = await channelByID(env.DB, channelID);
    if (!channel) return json({ error: "Not found." }, 404);

    if (request.method === "POST" && tail === "pairings") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      return json(await createPairing(env.DB, channelID, new Date()), 201);
    }

    if (request.method === "POST" && tail === "tool-pairings") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      return json(await createToolPairing(env.DB, channelID, new Date()), 201);
    }

    if (request.method === "PUT" && tail === "snapshot") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      const payload = await readJSON(request);
      validateSnapshot(payload);
      const canonical = JSON.stringify(payload);
      const snapshotHash = await sha256(canonical);
      const now = new Date().toISOString();
      const existingHash = await env.DB.prepare("SELECT snapshot_hash FROM relay_channels WHERE id = ?").bind(channelID).first<{ snapshot_hash: string | null }>();
      const changed = existingHash?.snapshot_hash !== snapshotHash;
      await env.DB.prepare(
        `UPDATE relay_channels SET snapshot_json = ?, snapshot_hash = ?, last_upload_at = ?,
         snapshot_version = snapshot_version + ? WHERE id = ?`
      ).bind(canonical, snapshotHash, now, changed ? 1 : 0, channelID).run();
      const updated = await channelByID(env.DB, channelID);
      if (changed && updated) ctx.waitUntil(pushChannel(env, updated));
      return json({ version: updated?.snapshot_version ?? channel.snapshot_version, serverReceivedAt: now, changed });
    }

    if (request.method === "POST" && tail === "session-events") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      await enforceRateLimit(env.DB, `events:${channelID}`, 240, 60 * 60_000);
      const event = await readJSON(request);
      validateSessionEvent(event);
      ctx.waitUntil(pushSessionEvent(env, channel, event));
      return json({ accepted: true }, 202);
    }

    if (request.method === "GET" && tail === "snapshot") {
      const device = await authorizePhone(request, env.DB, channelID);
      if (!device) return unauthorized();
      await env.DB.prepare("UPDATE relay_devices SET last_seen_at = ? WHERE id = ?").bind(new Date().toISOString(), device.id).run();
      if (!channel.snapshot_json) return json({ error: "The Mac has not uploaded limits yet." }, 404);
      const etag = `\"${channel.snapshot_version}\"`;
      if (request.headers.get("if-none-match") === etag) return new Response(null, { status: 304, headers: { etag } });
      return json({ schemaVersion: 1, version: channel.snapshot_version, serverReceivedAt: channel.last_upload_at, macName: channel.mac_name, snapshot: JSON.parse(channel.snapshot_json) }, 200, { etag });
    }

    if (request.method === "GET" && tail === "devices") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      const rows = await env.DB.prepare("SELECT id, name, created_at, last_seen_at FROM relay_devices WHERE channel_id = ? ORDER BY created_at")
        .bind(channelID).all();
      return json({ devices: rows.results });
    }

    if (request.method === "GET" && tail === "tools") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      const rows = await env.DB.prepare("SELECT id, name, symbol_name, website_url, snapshot_json, created_at, last_upload_at FROM relay_remote_tools WHERE channel_id = ? ORDER BY created_at")
        .bind(channelID).all<RemoteToolRow>();
      return json({ tools: rows.results.map(tool => ({
        id: tool.id,
        name: tool.name,
        symbolName: tool.symbol_name,
        websiteURL: tool.website_url,
        createdAt: tool.created_at,
        lastUploadAt: tool.last_upload_at,
        snapshot: tool.snapshot_json ? JSON.parse(tool.snapshot_json) : null,
      })) });
    }

    const toolSnapshotMatch = tail.match(/^tools\/([^/]+)\/snapshot$/);
    if (toolSnapshotMatch && request.method === "PUT") {
      const tool = await remoteToolByID(env.DB, channelID, toolSnapshotMatch[1]);
      if (!tool || !await authorizeRemoteTool(request, tool)) return unauthorized();
      const payload = await readJSON(request);
      validateRemoteToolSnapshot(payload);
      const now = new Date().toISOString();
      await env.DB.prepare("UPDATE relay_remote_tools SET snapshot_json = ?, last_upload_at = ? WHERE id = ? AND channel_id = ?")
        .bind(JSON.stringify(payload), now, tool.id, channelID).run();
      return json({ accepted: true, serverReceivedAt: now });
    }

    const remoteToolMatch = tail.match(/^tools\/([^/]+)$/);
    if (remoteToolMatch && request.method === "DELETE") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      await env.DB.prepare("DELETE FROM relay_remote_tools WHERE id = ? AND channel_id = ?")
        .bind(remoteToolMatch[1], channelID).run();
      return new Response(null, { status: 204 });
    }

    const deviceMatch = tail.match(/^devices\/([^/]+)$/);
    if (deviceMatch && request.method === "PUT") {
      const device = await authorizePhone(request, env.DB, channelID);
      if (!device || device.id !== deviceMatch[1]) return unauthorized();
      const payload = await readJSON(request) as { apnsToken?: string; environment?: string; sessionNotificationsEnabled?: boolean };
      if (!/^[a-fA-F0-9]{32,256}$/.test(payload.apnsToken ?? "") || !["sandbox", "production"].includes(payload.environment ?? "")) {
        return json({ error: "Invalid APNs registration." }, 400);
      }
      if (payload.sessionNotificationsEnabled != null && typeof payload.sessionNotificationsEnabled !== "boolean") {
        return json({ error: "Invalid notification preference." }, 400);
      }
      await env.DB.prepare("UPDATE relay_devices SET apns_token = ?, apns_environment = ?, session_notifications_enabled = ?, last_seen_at = ? WHERE id = ?")
        .bind(payload.apnsToken!.toLowerCase(), payload.environment, payload.sessionNotificationsEnabled === true ? 1 : 0, new Date().toISOString(), device.id).run();
      return json({ registered: true });
    }

    if (deviceMatch && request.method === "DELETE") {
      const macAuthorized = await authorizeMac(request, channel);
      const phone = macAuthorized ? null : await authorizePhone(request, env.DB, channelID);
      if (!macAuthorized && phone?.id !== deviceMatch[1]) return unauthorized();
      await env.DB.prepare("DELETE FROM relay_devices WHERE id = ? AND channel_id = ?").bind(deviceMatch[1], channelID).run();
      return new Response(null, { status: 204 });
    }

    if (request.method === "DELETE" && tail === "") {
      if (!await authorizeMac(request, channel)) return unauthorized();
      await env.DB.prepare("DELETE FROM relay_channels WHERE id = ?").bind(channelID).run();
      return new Response(null, { status: 204 });
    }
    return json({ error: "Not found." }, 404);
  } catch (error) {
    if (error instanceof RelayError) return json({ error: error.message }, error.status);
    return json({ error: "Relay request failed." }, 500);
  }
}

async function ensureRelaySchema(db: D1Database) {
  if (!schemaReady) {
    schemaReady = (async () => {
      await db.batch([
        db.prepare("CREATE TABLE IF NOT EXISTS relay_channels (id TEXT PRIMARY KEY NOT NULL, mac_name TEXT NOT NULL, upload_token_hash TEXT NOT NULL UNIQUE, snapshot_json TEXT, snapshot_hash TEXT, snapshot_version INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, last_upload_at TEXT)"),
        db.prepare("CREATE TABLE IF NOT EXISTS relay_pairings (id TEXT PRIMARY KEY NOT NULL, channel_id TEXT NOT NULL REFERENCES relay_channels(id) ON DELETE CASCADE, code_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL, claimed_at TEXT, failed_attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)"),
        db.prepare("CREATE TABLE IF NOT EXISTS relay_devices (id TEXT PRIMARY KEY NOT NULL, channel_id TEXT NOT NULL REFERENCES relay_channels(id) ON DELETE CASCADE, name TEXT NOT NULL, read_token_hash TEXT NOT NULL UNIQUE, apns_token TEXT, apns_environment TEXT, last_push_at TEXT, session_notifications_enabled INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL)"),
        db.prepare("CREATE INDEX IF NOT EXISTS relay_devices_channel_idx ON relay_devices(channel_id)"),
        db.prepare("CREATE TABLE IF NOT EXISTS relay_tool_pairings (id TEXT PRIMARY KEY NOT NULL, channel_id TEXT NOT NULL REFERENCES relay_channels(id) ON DELETE CASCADE, code_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL, claimed_at TEXT, created_at TEXT NOT NULL)"),
        db.prepare("CREATE TABLE IF NOT EXISTS relay_remote_tools (id TEXT PRIMARY KEY NOT NULL, channel_id TEXT NOT NULL REFERENCES relay_channels(id) ON DELETE CASCADE, name TEXT NOT NULL, symbol_name TEXT NOT NULL, website_url TEXT, write_token_hash TEXT NOT NULL UNIQUE, snapshot_json TEXT, created_at TEXT NOT NULL, last_upload_at TEXT)"),
        db.prepare("CREATE INDEX IF NOT EXISTS relay_remote_tools_channel_idx ON relay_remote_tools(channel_id)"),
        db.prepare("CREATE TABLE IF NOT EXISTS relay_rate_limits (key TEXT PRIMARY KEY NOT NULL, count INTEGER NOT NULL, window_started_at TEXT NOT NULL)"),
      ]);
      const columns = await db.prepare("PRAGMA table_info(relay_devices)").all<{ name: string }>();
      if (!columns.results.some(column => column.name === "session_notifications_enabled")) {
        try {
          await db.prepare("ALTER TABLE relay_devices ADD COLUMN session_notifications_enabled INTEGER NOT NULL DEFAULT 0").run();
        } catch (error) {
          const refreshed = await db.prepare("PRAGMA table_info(relay_devices)").all<{ name: string }>();
          if (!refreshed.results.some(column => column.name === "session_notifications_enabled")) throw error;
        }
      }
    })().catch(error => { schemaReady = undefined; throw error; });
  }
  await schemaReady;
}

class RelayError extends Error {
  readonly status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
}
async function readJSON(request: Request): Promise<unknown> {
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > maximumBodyBytes) throw new RelayError("Request body is too large.", 413);
  const text = await request.text();
  if (encoder.encode(text).byteLength > maximumBodyBytes) throw new RelayError("Request body is too large.", 413);
  try { return JSON.parse(text || "{}"); } catch { throw new RelayError("Request body must be valid JSON.", 400); }
}
function validateSnapshot(value: unknown): asserts value is Record<string, unknown> {
  const root = value as { schemaVersion?: unknown; generatedAt?: unknown; tools?: unknown };
  if (!root || !hasOnlyKeys(root, ["schemaVersion", "generatedAt", "tools"]) || root.schemaVersion !== 1 || !isDateString(root.generatedAt) || !Array.isArray(root.tools) || root.tools.length > 100) {
    throw new RelayError("Invalid snapshot schema.", 400);
  }
  for (const tool of root.tools as Array<{ id?: unknown; name?: unknown; symbolName?: unknown; limits?: unknown }>) {
    if (!hasOnlyKeys(tool, ["id", "name", "symbolName", "limits"]) || !isBoundedString(tool.id, 128) || !isBoundedString(tool.name, 128) || !isBoundedString(tool.symbolName, 128) || !Array.isArray(tool.limits) || tool.limits.length > 100) {
      throw new RelayError("Invalid tool snapshot.", 400);
    }
    for (const limit of tool.limits as Array<{ id?: unknown; name?: unknown; planType?: unknown; primary?: unknown; secondary?: unknown }>) {
      if (!hasOnlyKeys(limit, ["id", "name", "planType", "primary", "secondary"]) || !isBoundedString(limit.id, 256) || !isBoundedString(limit.name, 128) || (limit.planType != null && !isBoundedString(limit.planType, 128)) || !isWindow(limit.primary) || (limit.secondary != null && !isWindow(limit.secondary))) {
        throw new RelayError("Invalid limit snapshot.", 400);
      }
    }
  }
}
function validateRemoteToolSnapshot(value: unknown): asserts value is Record<string, unknown> {
  const root = value as { schemaVersion?: unknown; generatedAt?: unknown; limits?: unknown };
  if (!root || !hasOnlyKeys(root, ["schemaVersion", "generatedAt", "limits"]) || root.schemaVersion !== 1 || !isDateString(root.generatedAt) || !Array.isArray(root.limits) || root.limits.length > 100) {
    throw new RelayError("Invalid remote tool snapshot schema.", 400);
  }
  for (const limit of root.limits as Array<{ id?: unknown; name?: unknown; planType?: unknown; primary?: unknown; secondary?: unknown }>) {
    if (!hasOnlyKeys(limit, ["id", "name", "planType", "primary", "secondary"]) || !isBoundedString(limit.id, 256) || !isBoundedString(limit.name, 128) || (limit.planType != null && !isBoundedString(limit.planType, 128)) || !isWindow(limit.primary) || (limit.secondary != null && !isWindow(limit.secondary))) {
      throw new RelayError("Invalid remote tool limit.", 400);
    }
  }
}
function validateSessionEvent(value: unknown): asserts value is SessionEvent {
  const event = value as Partial<SessionEvent> | null;
  if (!event || !hasOnlyKeys(event, ["schemaVersion", "eventID", "kind", "sessionTitle", "workspaceName", "occurredAt"])
    || event.schemaVersion !== 1
    || !isBoundedString(event.eventID, 256)
    || !["finished", "error", "permission_needed"].includes(event.kind ?? "")
    || !isBoundedString(event.sessionTitle, 160)
    || !isBoundedString(event.workspaceName, 160)
    || !isDateString(event.occurredAt)) {
    throw new RelayError("Invalid session event.", 400);
  }
}
function isBoundedString(value: unknown, maximum: number): value is string { return typeof value === "string" && value.length > 0 && value.length <= maximum; }
function isDateString(value: unknown): value is string { return typeof value === "string" && value.length <= 64 && Number.isFinite(Date.parse(value)); }
function hasOnlyKeys(value: object, allowed: string[]) { return Object.keys(value).every(key => allowed.includes(key)); }
function isWindow(value: unknown) {
  const window = value as { remainingPercent?: unknown; resetAt?: unknown; windowDurationMinutes?: unknown } | null;
  return !!window
    && hasOnlyKeys(window, ["remainingPercent", "resetAt", "windowDurationMinutes"])
    && typeof window.remainingPercent === "number" && Number.isFinite(window.remainingPercent) && window.remainingPercent >= 0 && window.remainingPercent <= 100
    && (window.resetAt == null || isDateString(window.resetAt))
    && (window.windowDurationMinutes == null || (Number.isInteger(window.windowDurationMinutes) && Number(window.windowDurationMinutes) >= 0 && Number(window.windowDurationMinutes) <= 525_600));
}
async function channelByID(db: D1Database, id: string) { return db.prepare("SELECT * FROM relay_channels WHERE id = ?").bind(id).first<ChannelRow>(); }
async function remoteToolByID(db: D1Database, channelID: string, id: string) { return db.prepare("SELECT * FROM relay_remote_tools WHERE id = ? AND channel_id = ?").bind(id, channelID).first<RemoteToolRow>(); }
async function authorizeMac(request: Request, channel: ChannelRow) { const token = bearer(request); return !!token && timingSafeEqual(await sha256(token), channel.upload_token_hash); }
async function authorizeRemoteTool(request: Request, tool: RemoteToolRow) { const token = bearer(request); return !!token && timingSafeEqual(await sha256(token), tool.write_token_hash); }
async function authorizePhone(request: Request, db: D1Database, channelID: string) {
  const token = bearer(request); if (!token) return null;
  return db.prepare("SELECT * FROM relay_devices WHERE channel_id = ? AND read_token_hash = ?").bind(channelID, await sha256(token)).first<DeviceRow>();
}
function bearer(request: Request) { const value = request.headers.get("authorization") ?? ""; return value.startsWith("Bearer ") ? value.slice(7) : null; }
function unauthorized() { return json({ error: "Unauthorized." }, 401); }
function json(value: unknown, status = 200, headers: HeadersInit = {}) { return Response.json(value, { status, headers: { "cache-control": "no-store", ...headers } }); }
function cleanName(value: unknown, fallback: string) { const name = typeof value === "string" ? value.trim().slice(0, 80) : ""; return name || fallback; }
function cleanSymbolName(value: unknown) { const symbol = typeof value === "string" ? value.trim() : ""; return /^[a-z0-9.-]{1,64}$/i.test(symbol) ? symbol : "cpu"; }
function cleanWebsiteURL(value: unknown) {
  if (typeof value !== "string" || value.length > 2048) return null;
  try { const url = new URL(value); return ["http:", "https:"].includes(url.protocol) ? url.toString() : null; } catch { return null; }
}
function normalizeCode(value: unknown) {
  const raw = typeof value === "string" ? value.trim().toUpperCase() : "";
  const pattern = `[${pairingAlphabet}]{8}`;
  if (!new RegExp(`^(?:${pattern}|[${pairingAlphabet}]{4}[- ][${pairingAlphabet}]{4})$`).test(raw)) {
    throw new RelayError("That pairing code is invalid or expired.", 400);
  }
  return raw.replace(/[- ]/g, "");
}
function randomToken(prefix: string) { const bytes = crypto.getRandomValues(new Uint8Array(32)); return prefix + base64url(bytes); }
function randomCode() { const bytes = crypto.getRandomValues(new Uint8Array(8)); return Array.from(bytes, byte => pairingAlphabet[byte % pairingAlphabet.length]).join(""); }
async function createPairing(db: D1Database, channelID: string, now: Date) {
  const code = randomCode(); const expiresAt = new Date(now.getTime() + pairingLifetimeMs).toISOString();
  await db.prepare("INSERT INTO relay_pairings (id, channel_id, code_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(crypto.randomUUID(), channelID, await sha256(code), expiresAt, now.toISOString()).run();
  return { pairingCode: code, expiresAt };
}
async function createToolPairing(db: D1Database, channelID: string, now: Date) {
  const code = randomCode(); const expiresAt = new Date(now.getTime() + pairingLifetimeMs).toISOString();
  await db.prepare("INSERT INTO relay_tool_pairings (id, channel_id, code_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(crypto.randomUUID(), channelID, await sha256(code), expiresAt, now.toISOString()).run();
  return { pairingCode: code, expiresAt };
}
async function sha256(value: string) { return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value)))).map(v => v.toString(16).padStart(2, "0")).join(""); }
function timingSafeEqual(a: string, b: string) { if (a.length !== b.length) return false; let result = 0; for (let i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i); return result === 0; }
function base64url(bytes: Uint8Array) { let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte); return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_"); }
function clientAddress(request: Request) { return request.headers.get("cf-connecting-ip") ?? "unknown"; }
async function enforceRateLimit(db: D1Database, key: string, maximum: number, windowMs: number) {
  const hashed = await sha256(key); const now = new Date(); const row = await db.prepare("SELECT count, window_started_at FROM relay_rate_limits WHERE key = ?").bind(hashed).first<{ count: number; window_started_at: string }>();
  if (!row || Date.now() - Date.parse(row.window_started_at) >= windowMs) { await db.prepare("INSERT INTO relay_rate_limits (key, count, window_started_at) VALUES (?, 1, ?) ON CONFLICT(key) DO UPDATE SET count = 1, window_started_at = excluded.window_started_at").bind(hashed, now.toISOString()).run(); return; }
  if (row.count >= maximum) throw new RelayError("Too many requests. Try again later.", 429);
  await db.prepare("UPDATE relay_rate_limits SET count = count + 1 WHERE key = ?").bind(hashed).run();
}

async function pushChannel(env: RelayEnv, channel: ChannelRow) {
  if (!env.APNS_TEAM_ID || !env.APNS_KEY_ID || !env.APNS_PRIVATE_KEY || !env.APNS_TOPIC) return;
  const devices = await env.DB.prepare("SELECT * FROM relay_devices WHERE channel_id = ? AND apns_token IS NOT NULL").bind(channel.id).all<DeviceRow>();
  for (const device of devices.results) {
    const now = new Date();
    const cutoff = new Date(now.getTime() - pushIntervalMs).toISOString();
    const claimed = await env.DB.prepare("UPDATE relay_devices SET last_push_at = ? WHERE id = ? AND (last_push_at IS NULL OR last_push_at <= ?)")
      .bind(now.toISOString(), device.id, cutoff).run();
    if ((claimed.meta.changes ?? 0) !== 1) continue;
    const host = device.apns_environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    const response = await fetch(`${host}/3/device/${device.apns_token}`, { method: "POST", headers: { authorization: `bearer ${await providerToken(env)}`, "apns-topic": env.APNS_TOPIC, "apns-push-type": "background", "apns-priority": "5", "content-type": "application/json" }, body: JSON.stringify({ aps: { "content-available": 1 }, relayVersion: channel.snapshot_version }) });
    if (!response.ok) {
      const reason = (await response.json().catch(() => ({})) as { reason?: string }).reason;
      if (["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(reason ?? "")) {
        await env.DB.prepare("UPDATE relay_devices SET apns_token = NULL, apns_environment = NULL WHERE id = ?").bind(device.id).run();
      }
    }
  }
}
async function pushSessionEvent(env: RelayEnv, channel: ChannelRow, event: SessionEvent) {
  if (!env.APNS_TEAM_ID || !env.APNS_KEY_ID || !env.APNS_PRIVATE_KEY || !env.APNS_TOPIC) return;
  const devices = await env.DB.prepare(
    "SELECT * FROM relay_devices WHERE channel_id = ? AND apns_token IS NOT NULL AND session_notifications_enabled = 1"
  ).bind(channel.id).all<DeviceRow>();
  const copy = sessionEventCopy(event);
  for (const device of devices.results) {
    const host = device.apns_environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    const response = await fetch(`${host}/3/device/${device.apns_token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await providerToken(env)}`,
        "apns-topic": env.APNS_TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: { title: `${channel.mac_name}: ${copy.title}`, body: copy.body },
          sound: "default",
          category: "USAGE_HUD_SESSION_EVENT",
          "thread-id": channel.id,
        },
        sessionEvent: { id: event.eventID, kind: event.kind, occurredAt: event.occurredAt },
      }),
    });
    if (!response.ok) {
      const reason = (await response.json().catch(() => ({})) as { reason?: string }).reason;
      if (["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(reason ?? "")) {
        await env.DB.prepare("UPDATE relay_devices SET apns_token = NULL, apns_environment = NULL WHERE id = ?").bind(device.id).run();
      }
    }
  }
}
function sessionEventCopy(event: SessionEvent) {
  const title = event.kind === "finished" ? "Session Finished"
    : event.kind === "error" ? "Session Error" : "Permission Needed";
  const body = event.workspaceName === event.sessionTitle
    ? event.sessionTitle : `${event.sessionTitle} · ${event.workspaceName}`;
  return { title, body };
}
async function providerToken(env: RelayEnv) {
  const now = Date.now(); if (cachedProviderToken && now - cachedProviderToken.createdAt < 50 * 60_000) return cachedProviderToken.value;
  const header = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64url(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })));
  const pem = env.APNS_PRIVATE_KEY!.replace(/\\n/g, "\n");
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(`${header}.${claims}`)));
  const value = `${header}.${claims}.${base64url(signature)}`; cachedProviderToken = { value, createdAt: now }; return value;
}

export const relayTestSupport = { normalizeCode, randomCode, validateSnapshot, validateRemoteToolSnapshot, validateSessionEvent, sessionEventCopy, sha256 };
