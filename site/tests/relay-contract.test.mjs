import assert from "node:assert/strict";
import test from "node:test";
import { handleRelayRequest, relayTestSupport } from "../worker/relay-api.ts";

const validSnapshot = () => ({
  schemaVersion: 1,
  generatedAt: "2026-07-18T12:00:00Z",
  tools: [{
    id: "chatGPT",
    name: "ChatGPT",
    symbolName: "sparkles",
    sessionStatus: {
      phase: "thinking",
      updatedAt: "2026-07-18T12:00:02Z",
    },
    resetCredits: {
      availableCount: 1,
      expiresAt: "2026-08-13T00:00:00Z",
    },
    limits: [{
      id: "weekly",
      name: "Weekly",
      planType: "Plus",
      primary: { remainingPercent: 72, resetAt: "2026-07-20T12:00:00Z", windowDurationMinutes: 10_080 },
      secondary: null,
    }],
  }],
});

test("accepts only numeric one-use pairing code formats", () => {
  assert.equal(relayTestSupport.normalizeCode("01234567"), "01234567");
  assert.equal(relayTestSupport.normalizeCode("0123-4567"), "01234567");
  for (const invalid of ["0123!4567", "ABCD2345", "1234567", "123456789"]) {
    assert.throws(() => relayTestSupport.normalizeCode(invalid));
  }
});

test("generates 8-digit pairing codes", () => {
  for (let index = 0; index < 100; index += 1) {
    assert.match(relayTestSupport.randomCode(), /^\d{8}$/);
  }
});

test("accepts normalized visible-limit snapshots", () => {
  assert.doesNotThrow(() => relayTestSupport.validateSnapshot(validSnapshot()));

  const legacySnapshot = validSnapshot();
  legacySnapshot.sessionStatus = {
    phase: "thinking",
    updatedAt: "2026-07-18T11:59:59Z",
  };
  assert.doesNotThrow(() => relayTestSupport.validateSnapshot(legacySnapshot));
});

test("accepts only normalized reset-credit summaries", () => {
  const snapshot = validSnapshot();
  assert.doesNotThrow(() => relayTestSupport.validateSnapshot(snapshot));

  snapshot.tools[0].resetCredits.availableCount = -1;
  assert.throws(() => relayTestSupport.validateSnapshot(snapshot));

  snapshot.tools[0].resetCredits.availableCount = 1;
  snapshot.tools[0].resetCredits.creditId = "private-provider-id";
  assert.throws(() => relayTestSupport.validateSnapshot(snapshot));
});

test("accepts only privacy-minimal legacy aggregate session status", () => {
  for (const phase of ["idle", "thinking", "complete", "needsInput", "error"]) {
    const snapshot = validSnapshot();
    snapshot.sessionStatus = { phase, updatedAt: "2026-07-18T11:59:59Z" };
    assert.doesNotThrow(() => relayTestSupport.validateSnapshot(snapshot));
  }

  const privateStatus = validSnapshot();
  privateStatus.sessionStatus = { phase: "thinking", updatedAt: "2026-07-18T11:59:59Z" };
  privateStatus.sessionStatus.taskTitle = "Secret task";
  assert.throws(() => relayTestSupport.validateSnapshot(privateStatus));

  const invalidPhase = validSnapshot();
  invalidPhase.sessionStatus = { phase: "running", updatedAt: "2026-07-18T11:59:59Z" };
  assert.throws(() => relayTestSupport.validateSnapshot(invalidPhase));
});

test("accepts bounded session phases without task content", () => {
  const snapshot = validSnapshot();
  assert.doesNotThrow(() => relayTestSupport.validateSnapshot(snapshot));

  snapshot.tools[0].sessionStatus.taskTitle = "Private task";
  assert.throws(() => relayTestSupport.validateSnapshot(snapshot));

  delete snapshot.tools[0].sessionStatus.taskTitle;
  snapshot.tools[0].sessionStatus.phase = "unknown";
  assert.throws(() => relayTestSupport.validateSnapshot(snapshot));
});

test("distinguishes session transitions from quota-only changes", () => {
  const first = validSnapshot();
  const quotaOnly = validSnapshot();
  quotaOnly.tools[0].limits[0].primary.remainingPercent = 60;
  assert.equal(
    relayTestSupport.sessionStatusSignature(first),
    relayTestSupport.sessionStatusSignature(quotaOnly),
  );

  const completed = validSnapshot();
  completed.tools[0].sessionStatus.phase = "complete";
  assert.notEqual(
    relayTestSupport.sessionStatusSignature(first),
    relayTestSupport.sessionStatusSignature(completed),
  );
});

test("rejects credentials, malformed windows, and oversized schemas", () => {
  const credential = validSnapshot();
  credential.providerToken = "must-not-pass";
  assert.throws(() => relayTestSupport.validateSnapshot(credential));

  const invalidPercent = validSnapshot();
  invalidPercent.tools[0].limits[0].primary.remainingPercent = 101;
  assert.throws(() => relayTestSupport.validateSnapshot(invalidPercent));

  const tooManyTools = validSnapshot();
  tooManyTools.tools = Array.from({ length: 101 }, () => validSnapshot().tools[0]);
  assert.throws(() => relayTestSupport.validateSnapshot(tooManyTools));
});

test("accepts paired remote tool uploads without provider credentials", () => {
  const upload = {
    schemaVersion: 1,
    generatedAt: "2026-07-19T12:00:00Z",
    limits: validSnapshot().tools[0].limits,
  };
  assert.doesNotThrow(() => relayTestSupport.validateRemoteToolSnapshot(upload));

  upload.providerToken = "must-not-pass";
  assert.throws(() => relayTestSupport.validateRemoteToolSnapshot(upload));
});

test("accepts only bounded session attention events", () => {
  const event = {
    schemaVersion: 1,
    eventID: "session-1:finished:123",
    kind: "finished",
    sessionTitle: "Ship notification relay",
    workspaceName: "GPTUsage",
    occurredAt: "2026-07-19T12:00:00Z",
  };
  assert.doesNotThrow(() => relayTestSupport.validateSessionEvent(event));
  assert.equal(relayTestSupport.sessionEventCopy(event).title, "Session Finished");
  assert.equal(relayTestSupport.sessionEventCopy(event).body, "Ship notification relay · GPTUsage");

  assert.throws(() => relayTestSupport.validateSessionEvent({ ...event, kind: "thinking" }));
  assert.throws(() => relayTestSupport.validateSessionEvent({ ...event, prompt: "private" }));
});

test("accepts complete bounded app feedback without an account", () => {
  const feedback = {
    schemaVersion: 1,
    content: "The reset time would be easier to read with a date.",
    platform: "macOS",
    systemVersion: "macOS 26.0 (25A123)",
    architecture: "arm64",
    locale: "en_SG",
    language: "en-SG",
    appVersion: "0.2.1",
    appBuild: "23",
    appBundleIdentifier: "com.richardzhengquan.usaige",
    submittedAt: "2026-07-20T08:00:00Z",
  };
  assert.doesNotThrow(() => relayTestSupport.validateFeedback(feedback));
  assert.throws(() => relayTestSupport.validateFeedback({ ...feedback, content: "   " }));
  assert.throws(() => relayTestSupport.validateFeedback({ ...feedback, accountToken: "not allowed" }));
  assert.throws(() => relayTestSupport.validateFeedback({ ...feedback, content: "x".repeat(4_001) }));
});

test("stores account-free feedback through the public endpoint", async () => {
  let storedFeedback;
  const db = {
    prepare(sql) {
      const statement = {
        bindings: [],
        bind(...bindings) { this.bindings = bindings; return this; },
        async first() { return null; },
        async all() {
          if (sql.startsWith("PRAGMA table_info(relay_devices)")) {
            return { results: [{ name: "session_notifications_enabled" }] };
          }
          return { results: [] };
        },
        async run() {
          if (sql.includes("INSERT INTO app_feedback")) storedFeedback = this.bindings;
          return { meta: { changes: 1 } };
        },
      };
      return statement;
    },
    async batch(statements) {
      return statements.map(() => ({ success: true }));
    },
  };
  const request = new Request("https://feedback.example/api/v1/feedback", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.5" },
    body: JSON.stringify({
      schemaVersion: 1,
      content: "  A direct server feedback message.  ",
      platform: "macOS",
      systemVersion: "macOS 26.0",
      architecture: "arm64",
      locale: "en_SG",
      language: "en-SG",
      appVersion: "0.2.1",
      appBuild: "23",
      appBundleIdentifier: "com.richardzhengquan.usaige",
      submittedAt: "2026-07-20T08:00:00Z",
    }),
  });

  const response = await handleRelayRequest(request, { DB: db }, { waitUntil() {} });
  assert.equal(response.status, 201);
  const receipt = await response.json();
  assert.match(receipt.id, /^[0-9a-f-]{36}$/);
  assert.equal(storedFeedback[1], "A direct server feedback message.");
  assert.equal(storedFeedback[2], "macOS");
  assert.equal(storedFeedback[7], "0.2.1");
  assert.equal(storedFeedback[8], "23");
});

test("hashes capabilities with SHA-256", async () => {
  assert.equal(
    await relayTestSupport.sha256("usg_mac_example"),
    "0e4fb712c07e2b3392b9a875b43744e70d0ef6b543e4378d6b23eeed264a581c",
  );
});

test("accepts only canonical Watch device UUIDs", () => {
  assert.equal(relayTestSupport.isUUID("11111111-1111-4111-8111-111111111111"), true);
  for (const invalid of ["watch", "11111111-1111-1111-1111-111111111111", "../../device"]) {
    assert.equal(relayTestSupport.isUUID(invalid), false);
  }
});

/// A scripted D1 stand-in: `handlers` map a SQL prefix to the row `first()` returns
/// or a function of the bindings; everything else is a successful no-op.
function scriptedDB(handlers = {}) {
  const calls = [];
  const resolve = (sql, bindings) => {
    for (const [prefix, handler] of Object.entries(handlers)) {
      if (sql.trim().startsWith(prefix)) return typeof handler === "function" ? handler(bindings) : handler;
    }
    return null;
  };
  return {
    calls,
    prepare(sql) {
      return {
        bindings: [],
        bind(...bindings) { this.bindings = bindings; return this; },
        async first() { calls.push(sql); return resolve(sql, this.bindings); },
        async all() {
          if (sql.startsWith("PRAGMA table_info(relay_devices)")) return { results: [{ name: "session_notifications_enabled" }] };
          return { results: [] };
        },
        async run() {
          calls.push(sql);
          const result = resolve(sql, this.bindings);
          return result ?? { meta: { changes: 1 } };
        },
      };
    },
    async batch(statements) { return statements.map(() => ({ success: true })); },
  };
}
const noopContext = { waitUntil() {} };
const openChannel = { id: "channel-1", mac_name: "Mac", upload_token_hash: await relayTestSupport.sha256("usg_mac_secret"), snapshot_json: null, snapshot_version: 0, last_upload_at: null };

test("rate limiting is one atomic upsert and rejects once the window is full", async () => {
  const db = scriptedDB({ "INSERT INTO relay_rate_limits": { count: 21 } });
  await assert.rejects(
    () => relayTestSupport.enforceRateLimit(db, "claim:203.0.113.5", 20, 15 * 60_000),
    error => error.status === 429
  );
  assert.equal(db.calls.filter(sql => sql.includes("relay_rate_limits")).length, 1);
  assert.match(db.calls[0], /RETURNING count/);
  assert.doesNotMatch(db.calls[0], /^SELECT/);

  const allowed = scriptedDB({ "INSERT INTO relay_rate_limits": { count: 20 } });
  await assert.doesNotReject(() => relayTestSupport.enforceRateLimit(allowed, "claim:203.0.113.5", 20, 15 * 60_000));
});

test("pairing codes stay uniform and eight digits long", () => {
  const seen = new Set();
  for (let index = 0; index < 400; index += 1) {
    const code = relayTestSupport.randomCode();
    assert.match(code, /^\d{8}$/);
    for (const digit of code) seen.add(digit);
  }
  assert.equal(seen.size, 10);
});

test("an invalid bearer token is rejected on an authenticated endpoint", async () => {
  const db = scriptedDB({ "SELECT * FROM relay_channels": openChannel, "INSERT INTO relay_rate_limits": { count: 1 } });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels/channel-1/snapshot", {
    method: "PUT",
    headers: { authorization: "Bearer usg_mac_wrong", "content-type": "application/json" },
    body: JSON.stringify(validSnapshot()),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 401);
  assert.ok(!db.calls.some(sql => sql.startsWith("UPDATE relay_channels")));
});

test("snapshot uploads are rate limited per channel", async () => {
  const db = scriptedDB({ "SELECT * FROM relay_channels": openChannel, "INSERT INTO relay_rate_limits": { count: 601 } });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels/channel-1/snapshot", {
    method: "PUT",
    headers: { authorization: "Bearer usg_mac_secret", "content-type": "application/json" },
    body: JSON.stringify(validSnapshot()),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 429);
});

test("a pairing code can only be claimed once", async () => {
  const pairing = { id: "pairing-1", channel_id: "channel-1", expires_at: new Date(Date.now() + 60_000).toISOString(), claimed_at: null };
  const db = scriptedDB({
    "INSERT INTO relay_rate_limits": { count: 1 },
    "SELECT id, channel_id, expires_at, claimed_at FROM relay_pairings": pairing,
    // The conditional UPDATE finds the row already claimed by a concurrent request.
    "UPDATE relay_pairings SET claimed_at": { meta: { changes: 0 } },
  });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/pairings/claim", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.5" },
    body: JSON.stringify({ code: "01234567", deviceName: "iPhone" }),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 400);
  assert.ok(!db.calls.some(sql => sql.startsWith("INSERT INTO relay_devices")));
});

const phoneDevice = async () => ({ id: "phone-1", channel_id: "channel-1", name: "iPhone", read_token_hash: await relayTestSupport.sha256("usg_ios_secret"), apns_token: null, apns_environment: null, last_push_at: null, session_notifications_enabled: 1 });

test("a channel cannot register more than ten devices", async () => {
  const db = scriptedDB({
    "SELECT * FROM relay_channels": openChannel,
    "SELECT * FROM relay_devices WHERE channel_id = ? AND read_token_hash": await phoneDevice(),
    "SELECT channel_id FROM relay_devices WHERE id": null,
    // The bounded insert finds the channel full and inserts nothing.
    "INSERT INTO relay_devices": { meta: { changes: 0 } },
  });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels/channel-1/watch-devices/2a5f3c4e-1b2d-4c3e-8f9a-0b1c2d3e4f5a", {
    method: "POST",
    headers: { authorization: "Bearer usg_ios_secret", "content-type": "application/json" },
    body: JSON.stringify({ deviceName: "Apple Watch" }),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 409);
  const insert = db.calls.find(sql => sql.startsWith("INSERT INTO relay_devices"));
  // The limit check and the insert are one statement, so no count-then-insert gap.
  assert.match(insert, /SELECT COUNT\(\*\) FROM relay_devices/);
  assert.ok(!db.calls.some(sql => sql.startsWith("SELECT COUNT(*)")));
});

test("claiming a pairing code fails once the channel is full and hands the code back", async () => {
  const pairing = { id: "pairing-1", channel_id: "channel-1", expires_at: new Date(Date.now() + 60_000).toISOString(), claimed_at: null };
  const db = scriptedDB({
    "INSERT INTO relay_rate_limits": { count: 1 },
    "SELECT id, channel_id, expires_at, claimed_at FROM relay_pairings": pairing,
    "INSERT INTO relay_devices": { meta: { changes: 0 } },
  });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/pairings/claim", {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": "203.0.113.5" },
    body: JSON.stringify({ code: "01234567", deviceName: "iPhone" }),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 409);
  assert.ok(db.calls.some(sql => sql.startsWith("UPDATE relay_pairings SET claimed_at = NULL")));
});

test("pairing code creation is rate limited per channel", async () => {
  const db = scriptedDB({ "SELECT * FROM relay_channels": openChannel, "INSERT INTO relay_rate_limits": { count: 31 } });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels/channel-1/pairings", {
    method: "POST",
    headers: { authorization: "Bearer usg_mac_secret" },
  }), { DB: db }, noopContext);
  assert.equal(response.status, 429);
  assert.ok(!db.calls.some(sql => sql.startsWith("INSERT INTO relay_pairings")));
});

test("refreshing an APNs token keeps the saved notification preference", async () => {
  let update;
  const db = scriptedDB({
    "SELECT * FROM relay_channels": openChannel,
    "SELECT * FROM relay_devices WHERE channel_id = ? AND read_token_hash": await phoneDevice(),
    "UPDATE relay_devices SET apns_token": bindings => { update = bindings; return { meta: { changes: 1 } }; },
  });
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels/channel-1/devices/phone-1", {
    method: "PUT",
    headers: { authorization: "Bearer usg_ios_secret", "content-type": "application/json" },
    body: JSON.stringify({ apnsToken: "ab".repeat(32), environment: "production" }),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 200);
  assert.match(db.calls.find(sql => sql.startsWith("UPDATE relay_devices SET apns_token")), /COALESCE\(\?, session_notifications_enabled\)/);
  assert.equal(update[2], null);
});

test("session events dated in the future are stamped with arrival time", async () => {
  let stored;
  const db = scriptedDB({
    "SELECT * FROM relay_channels": openChannel,
    "INSERT INTO relay_rate_limits": { count: 1 },
    "SELECT id FROM relay_devices WHERE channel_id = ? AND session_notifications_enabled": { id: "phone-1" },
    "INSERT OR IGNORE INTO relay_session_events": bindings => { stored = bindings; return { meta: { changes: 1 } }; },
  });
  const before = Date.now();
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels/channel-1/session-events", {
    method: "POST",
    headers: { authorization: "Bearer usg_mac_secret", "content-type": "application/json" },
    body: JSON.stringify({ schemaVersion: 1, eventID: "event-1", kind: "finished", sessionTitle: "Task", workspaceName: "Repo", occurredAt: "2099-01-01T00:00:00Z" }),
  }), { DB: db }, noopContext);
  assert.equal(response.status, 202);
  const occurredAt = Date.parse(stored[6]);
  assert.ok(occurredAt >= before - 1000 && occurredAt <= Date.now() + 1000);

  const recent = new Date(Date.now() + 60_000).toISOString();
  assert.equal(relayTestSupport.clampedOccurredAt(recent), recent);
});

test("bounded strings count characters and cap bytes", () => {
  assert.equal(relayTestSupport.isBoundedString("😀".repeat(64), 64), true);
  assert.equal(relayTestSupport.isBoundedString("😀".repeat(65), 64), false);
  assert.equal(relayTestSupport.isBoundedString("a".repeat(64), 64), true);
  assert.equal(relayTestSupport.isBoundedString("", 64), false);
});

test("browser preflights get no cross-origin grant", async () => {
  const response = await handleRelayRequest(new Request("https://relay.example/api/v1/channels", { method: "OPTIONS" }), { DB: scriptedDB() }, noopContext);
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), null);
});
