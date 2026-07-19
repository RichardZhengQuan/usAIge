import assert from "node:assert/strict";
import test from "node:test";
import { relayTestSupport } from "../worker/relay-api.ts";

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

test("hashes capabilities with SHA-256", async () => {
  assert.equal(
    await relayTestSupport.sha256("usg_mac_example"),
    "0e4fb712c07e2b3392b9a875b43744e70d0ef6b543e4378d6b23eeed264a581c",
  );
});
