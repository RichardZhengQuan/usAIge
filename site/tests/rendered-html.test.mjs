import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the current usAIge release", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>usAIge — Your AI usage, always in sight<\/title>/i);
  assert.match(html, /usAIge-0\.1\.11-alpha\.dmg/);
  assert.match(html, /usAIge-0\.1\.11-alpha\.dmg\.sha256/);
  assert.match(html, /remote tools/i);
  assert.match(html, /Open usAIge at login/);
  assert.doesNotMatch(html, /codex-preview|starter loading skeleton/i);
});

test("publishes a checksum matching the current disk image", async () => {
  const dmg = await readFile(new URL("../public/usAIge-0.1.11-alpha.dmg", import.meta.url));
  const checksum = await readFile(
    new URL("../public/usAIge-0.1.11-alpha.dmg.sha256", import.meta.url),
    "utf8",
  );
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.equal(checksum.trim(), `${digest}  usAIge-0.1.11-alpha.dmg`);
});

test("publishes a valid automatic update manifest", async () => {
  const manifest = JSON.parse(
    await readFile(new URL("../public/update.json", import.meta.url), "utf8"),
  );
  const dmg = await readFile(new URL(`../public/usAIge-0.1.11-alpha.dmg`, import.meta.url));
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.deepEqual(
    {
      version: manifest.version,
      build: manifest.build,
      minimumSystemVersion: manifest.minimumSystemVersion,
      sha256: manifest.sha256,
    },
    {
      version: "0.1.11",
      build: 13,
      minimumSystemVersion: "15.0",
      sha256: digest,
    },
  );
  assert.equal(
    manifest.downloadURL,
    "https://usaige-macos.richardqz.chatgpt.site/usAIge-0.1.11-alpha.dmg",
  );
});
