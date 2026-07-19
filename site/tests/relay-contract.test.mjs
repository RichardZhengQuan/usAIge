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
