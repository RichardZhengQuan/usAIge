import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { createRelayServer, maximumBodyBytes } from "../server/index.mjs";
import { SQLiteD1Database } from "../server/sqlite-d1.mjs";

const publicURL = "https://pmrichq.com/project/usaige";

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "usaige-relay-test-"));
  const databasePath = join(directory, "private", "relay.sqlite");
  const logs = [];
  let runtime;
  let localURL;
  async function start() {
    runtime = await createRelayServer({ databasePath, publicURL, port: 0, logger: message => logs.push(message) });
    const address = await runtime.listen();
    assert.equal(address.address, "127.0.0.1");
    localURL = `http://127.0.0.1:${address.port}`;
  }
  t.after(async () => {
    await runtime?.close();
    await rm(directory, { recursive: true, force: true });
  });
  await start();
  return {
    logs,
    databasePath,
    get runtime() { return runtime; },
    get localURL() { return localURL; },
    async restart() { await runtime.close(); await start(); },
    async send(path, { method = "GET", token, body, headers = {} } = {}) {
      return fetch(`${localURL}${path}`, {
        method,
        headers: {
          ...(token ? { authorization: `Bearer ${token}` } : {}),
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
          ...headers,
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
    },
  };
}

async function responseJSON(response, status) {
  assert.equal(response.status, status);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.match(response.headers.get("content-type"), /application\/json/);
  return response.json();
}

test("real HTTP relay persists pairing, snapshots, authorization, and revocation across a restart", async t => {
  const service = await fixture(t);
  const health = await responseJSON(await service.send("/project/usaige/api/v1/health"), 200);
  assert.deepEqual(health, { status: "ok", service: "usaige-relay" });
  assert.equal((await service.send("/api/v1/health")).status, 200);

  const channel = await responseJSON(await service.send("/project/usaige/api/v1/channels", {
    method: "POST", body: { macName: "Disposable Test Mac" },
  }), 201);
  assert.match(channel.pairingCode, /^\d{8}$/);
  assert.match(channel.uploadToken, /^usg_mac_/);
  const channelPath = `/api/v1/channels/${channel.channelID}`;
  assert.deepEqual(await responseJSON(await service.send(`${channelPath}/tools`, { token: channel.uploadToken }), 200), { tools: [] });
  assert.equal((await service.send(`${channelPath}/tools`)).status, 401);

  const phone = await responseJSON(await service.send("/api/v1/pairings/claim", {
    method: "POST",
    body: { code: `${channel.pairingCode.slice(0, 4)}-${channel.pairingCode.slice(4)}`, deviceName: "Disposable Test iPhone" },
  }), 201);
  assert.equal(phone.channelID, channel.channelID);
  assert.match(phone.readToken, /^usg_ios_/);
  assert.equal((await service.send("/api/v1/pairings/claim", {
    method: "POST", body: { code: channel.pairingCode },
  })).status, 400);

  const macSnapshot = {
    schemaVersion: 1, generatedAt: "2026-10-10T08:00:00Z",
    tools: [{ id: "chatgpt", name: "ChatGPT", symbolName: "sparkles", limits: [
      { id: "weekly", name: "Weekly", primary: { remainingPercent: 64, windowDurationMinutes: 10080 } },
    ] }],
  };
  const uploaded = await responseJSON(await service.send(`${channelPath}/snapshot`, {
    method: "PUT", token: channel.uploadToken, body: macSnapshot,
  }), 200);
  assert.equal(uploaded.changed, true);
  const phoneResponse = await service.send(`${channelPath}/snapshot`, { token: phone.readToken });
  const etag = phoneResponse.headers.get("etag");
  const phoneSnapshot = await responseJSON(phoneResponse, 200);
  assert.deepEqual(phoneSnapshot.snapshot, macSnapshot);
  assert.equal((await service.send(`${channelPath}/snapshot`, { token: channel.uploadToken })).status, 401);
  assert.equal((await service.send(`${channelPath}/snapshot`, {
    token: phone.readToken, headers: { "if-none-match": etag },
  })).status, 304);

  const pairing = await responseJSON(await service.send(`${channelPath}/tool-pairings`, {
    method: "POST", token: channel.uploadToken,
  }), 201);
  assert.match(pairing.pairingCode, /^\d{8}$/);
  const tool = await responseJSON(await service.send("/project/usaige/api/v1/tool-pairings/claim", {
    method: "POST",
    headers: { host: "untrusted.example", "x-forwarded-host": "untrusted.example", "x-forwarded-proto": "http" },
    body: { code: pairing.pairingCode, toolName: "Disposable Remote Claude", symbolName: "sparkles" },
  }), 201);
  assert.equal(tool.uploadURL, `${publicURL}${channelPath}/tools/${tool.toolID}/snapshot`);
  assert.match(tool.writeToken, /^usg_tool_/);
  assert.equal((await service.send("/api/v1/tool-pairings/claim", {
    method: "POST", body: { code: pairing.pairingCode },
  })).status, 400);

  const remoteSnapshot = {
    schemaVersion: 1, generatedAt: "2026-10-10T08:01:00Z",
    limits: [{ id: "weekly", name: "Weekly", primary: { remainingPercent: 75, windowDurationMinutes: 10080 } }],
  };
  const uploadPath = new URL(tool.uploadURL).pathname;
  assert.equal((await service.send(uploadPath, { method: "PUT", token: channel.uploadToken, body: remoteSnapshot })).status, 401);
  await responseJSON(await service.send(uploadPath, { method: "PUT", token: tool.writeToken, body: remoteSnapshot }), 200);
  let tools = await responseJSON(await service.send(`${channelPath}/tools`, { token: channel.uploadToken }), 200);
  assert.equal(tools.tools[0].id, tool.toolID);
  assert.deepEqual(tools.tools[0].snapshot, remoteSnapshot);

  assert.equal((await stat(service.databasePath)).mode & 0o777, 0o600);
  assert.equal((await stat(`${service.databasePath}-wal`)).mode & 0o777, 0o600);
  assert.equal((await stat(join(service.databasePath, ".."))).mode & 0o777, 0o700);
  assert.equal((await service.runtime.database.prepare("PRAGMA foreign_keys").first()).foreign_keys, 1);
  assert.equal((await service.runtime.database.prepare("PRAGMA journal_mode").first()).journal_mode, "wal");
  assert.equal((await service.runtime.database.prepare("PRAGMA busy_timeout").first()).timeout, 5000);
  const storedHash = await service.runtime.database.prepare("SELECT upload_token_hash FROM relay_channels WHERE id = ?").bind(channel.channelID).first();
  assert.notEqual(storedHash.upload_token_hash, channel.uploadToken);
  assert.match(storedHash.upload_token_hash, /^[0-9a-f]{64}$/);

  await service.restart();
  tools = await responseJSON(await service.send(`${channelPath}/tools`, { token: channel.uploadToken }), 200);
  assert.deepEqual(tools.tools[0].snapshot, remoteSnapshot);
  assert.deepEqual((await responseJSON(await service.send(`${channelPath}/snapshot`, { token: phone.readToken }), 200)).snapshot, macSnapshot);

  assert.equal((await service.send(`${channelPath}/tools/${tool.toolID}`, { method: "DELETE", token: tool.writeToken })).status, 401);
  assert.equal((await service.send(`${channelPath}/tools/${tool.toolID}`, { method: "DELETE", token: channel.uploadToken })).status, 204);
  assert.equal((await service.send(uploadPath, { method: "PUT", token: tool.writeToken, body: remoteSnapshot })).status, 401);
  assert.deepEqual(await responseJSON(await service.send(`${channelPath}/tools`, { token: channel.uploadToken }), 200), { tools: [] });
  assert.equal((await service.send(`${channelPath}/devices/${phone.deviceID}`, { method: "DELETE", token: phone.readToken })).status, 204);
  assert.equal((await service.send(`${channelPath}/snapshot`, { token: phone.readToken })).status, 401);
  assert.equal((await service.send(channelPath, { method: "DELETE", token: channel.uploadToken })).status, 204);
  assert.deepEqual(await responseJSON(await service.send(`${channelPath}/tools`, { token: channel.uploadToken }), 404), {
    error: "This connection is no longer available.", code: "channel_not_found",
  });
  assert.deepEqual(await responseJSON(await service.send("/api/v1/unknown"), 404), { error: "Not found." });
  assert.equal((await service.runtime.database.prepare("SELECT COUNT(*) AS count FROM relay_pairings").first()).count, 0);
  assert.equal((await service.runtime.database.prepare("SELECT COUNT(*) AS count FROM relay_tool_pairings").first()).count, 0);
  assert.deepEqual(service.logs, []);
});

test("HTTP body limits reject declared and chunked oversize bodies without logging content", async t => {
  const service = await fixture(t);
  const largeBody = "x".repeat(maximumBodyBytes + 1);
  let response = await fetch(`${service.localURL}/api/v1/channels`, { method: "POST", body: largeBody });
  assert.deepEqual(await responseJSON(response, 413), { error: "Request body is too large." });
  const chunked = await new Promise((resolve, reject) => {
    const req = request(`${service.localURL}/api/v1/channels`, { method: "POST" }, res => {
      const chunks = [];
      res.on("data", chunk => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    req.on("error", reject);
    req.write(Buffer.alloc(maximumBodyBytes, 120));
    req.end("x");
  });
  assert.equal(chunked.status, 413);
  assert.deepEqual(JSON.parse(chunked.body), { error: "Request body is too large." });
  response = await fetch(`${service.localURL}/api/v1/channels`, { method: "POST", body: "x".repeat(maximumBodyBytes) });
  assert.deepEqual(await responseJSON(response, 400), { error: "Request body must be valid JSON." });
  assert.equal((await service.send("/another/project/api/v1/health")).status, 404);
  assert.equal((await service.send("/project/usaige/api/v1/health", { method: "POST" })).status, 405);
  assert.equal((await service.runtime.database.prepare("SELECT COUNT(*) AS count FROM relay_channels").first()).count, 0);
  assert.deepEqual(service.logs, []);
});

test("health returns unavailable when storage cannot be queried", async t => {
  const service = await fixture(t);
  service.runtime.database.close();
  assert.deepEqual(await responseJSON(await service.send("/api/v1/health"), 503), { error: "Relay storage is unavailable." });
  assert.deepEqual(service.logs, ["relay_health_failed"]);
});

test("SQLite batch is atomic and foreign keys enforce channel ownership", async t => {
  const directory = await mkdtemp(join(tmpdir(), "usaige-relay-batch-"));
  const database = new SQLiteD1Database(join(directory, "relay.sqlite"));
  t.after(async () => { database.close(); await rm(directory, { recursive: true, force: true }); });
  await database.batch([
    database.prepare("CREATE TABLE parent (id TEXT PRIMARY KEY)"),
    database.prepare("CREATE TABLE child (id TEXT PRIMARY KEY, parent_id TEXT REFERENCES parent(id) ON DELETE CASCADE)"),
  ]);
  await assert.rejects(async () => database.batch([
    database.prepare("INSERT INTO parent (id) VALUES (?)").bind("disposable"),
    database.prepare("INSERT INTO parent (id) VALUES (?)").bind("disposable"),
  ]));
  assert.equal((await database.prepare("SELECT COUNT(*) AS count FROM parent").first()).count, 0);
  await assert.rejects(async () => database.prepare("INSERT INTO child (id, parent_id) VALUES (?, ?)").bind("child", "missing").run());
});

test("public origin configuration rejects credentials and non-HTTPS destinations", async () => {
  await assert.rejects(createRelayServer({ publicURL: "http://pmrichq.com/project/usaige" }));
  await assert.rejects(createRelayServer({ publicURL: "https://token@pmrichq.com/project/usaige" }));
  await assert.rejects(createRelayServer({ publicURL: "https://pmrichq.com/project/usaige?token=secret" }));
});

test("CLI drains on SIGTERM and a new process reopens the same database", { timeout: 10_000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), "usaige-relay-process-"));
  const children = [];
  t.after(async () => {
    for (const { child, exited } of children) {
      if (child.exitCode === null) child.kill("SIGTERM");
      await exited;
    }
    await rm(directory, { recursive: true, force: true });
  });
  async function start() {
    const child = spawn(process.execPath, ["--experimental-strip-types", fileURLToPath(new URL("../server/index.mjs", import.meta.url))], {
      env: {
        RELAY_DB_PATH: join(directory, "relay.sqlite"),
        RELAY_PUBLIC_URL: publicURL,
        RELAY_PORT: "0",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const exited = new Promise(resolve => child.once("exit", (code, signal) => resolve({ code, signal })));
    children.push({ child, exited });
    child.stderr.resume();
    const port = await new Promise((resolve, reject) => {
      const deadline = setTimeout(() => reject(new Error("Relay process did not start.")), 3000);
      let output = "";
      child.stdout.on("data", chunk => {
        output += chunk.toString();
        const match = output.match(/usAIge relay listening on 127\.0\.0\.1:(\d+)/);
        if (match) { clearTimeout(deadline); resolve(Number(match[1])); }
      });
      child.once("error", error => { clearTimeout(deadline); reject(error); });
      exited.then(() => { clearTimeout(deadline); reject(new Error("Relay process exited before startup.")); });
    });
    return { child, exited, localURL: `http://127.0.0.1:${port}` };
  }
  const first = await start();
  const channel = await responseJSON(await fetch(`${first.localURL}/api/v1/channels`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ macName: "Disposable Process Test" }),
  }), 201);
  first.child.kill("SIGTERM");
  assert.deepEqual(await first.exited, { code: 0, signal: null });
  const second = await start();
  await responseJSON(await fetch(`${second.localURL}/api/v1/health`), 200);
  assert.deepEqual(await responseJSON(await fetch(`${second.localURL}/api/v1/channels/${channel.channelID}/tools`, {
    headers: { authorization: `Bearer ${channel.uploadToken}` },
  }), 200), { tools: [] });
  second.child.kill("SIGTERM");
  assert.deepEqual(await second.exited, { code: 0, signal: null });
});
