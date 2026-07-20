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
