import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/project/usaige/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the current usAIge release", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>usAIge — AI usage and agent status, always in sight<\/title>/i);
  assert.match(
    html,
    /https:\/\/usaige-macos\.richardqz\.chatgpt\.site\/usAIge-0\.2\.4-alpha\.dmg/,
  );
  assert.match(
    html,
    /https:\/\/usaige-macos\.richardqz\.chatgpt\.site\/usAIge-0\.2\.4-alpha\.dmg\.sha256/,
  );
  assert.match(html, /Up to 100 active tasks/i);
  assert.match(html, /Pink error, green recent completion, yellow needs input, blue running/i);
  assert.match(html, /Click the ring to reopen the exact task/i);
  assert.match(html, /10–100%/i);
  assert.match(html, /50–250%/i);
  assert.match(html, /product-hud-status\.png/i);
  assert.match(html, /product-settings\.png/i);
  assert.doesNotMatch(html, /codex-preview|starter loading skeleton/i);
});

test("keeps menu hash navigation stable in Safari", async () => {
  const styles = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
  const sectionLink = await readFile(new URL("../app/section-link.tsx", import.meta.url), "utf8");

  assert.match(styles, /html\s*\{[^}]*scroll-behavior\s*:\s*auto\s*;/i);
  assert.doesNotMatch(styles, /scroll-behavior\s*:\s*smooth\s*;/i);
  assert.match(sectionLink, /event\.preventDefault\(\)/);
  assert.match(sectionLink, /history\.replaceState/);
  assert.match(sectionLink, /scrollIntoView\(\{\s*behavior:\s*"auto"/);
});

test("loads the domain-locked VibeLoft telemetry client", async () => {
  const source = await readFile(new URL("../app/layout.tsx", import.meta.url), "utf8");
  const response = await render();
  const html = await response.text();

  assert.match(source, /https:\/\/vibeloft\.ai\/telemetry\/v1\.js/i);
  assert.match(source, /0d5781ba-0024-4ef4-b25d-2853ee434456/i);
  assert.match(source, /vl_web\.[A-Za-z0-9_-]{43}/i);
  assert.doesNotMatch(source, /REPLACE_WITH_NEW_WEB_AUTH_KEY/i);
  assert.equal(
    (html.match(/<script[^>]*src="https:\/\/vibeloft\.ai\/telemetry\/v1\.js"[^>]*><\/script>/gi) ?? [])
      .length,
    1,
  );
  assert.match(
    html,
    /<head>[\s\S]*<script[^>]*defer=""[^>]*src="https:\/\/vibeloft\.ai\/telemetry\/v1\.js"[^>]*data-vl-product-id="0d5781ba-0024-4ef4-b25d-2853ee434456"[^>]*data-vl-auth-key="vl_web\.[A-Za-z0-9_-]{43}"[^>]*><\/script>[\s\S]*<\/head>/i,
  );
  assert.doesNotMatch(source, /api\.vibeloft\.ai|supabase/i);
});

test("publishes a checksum matching the current disk image", async () => {
  const dmg = await readFile(new URL("../public/usAIge-0.2.4-alpha.dmg", import.meta.url));
  const checksum = await readFile(
    new URL("../public/usAIge-0.2.4-alpha.dmg.sha256", import.meta.url),
    "utf8",
  );
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.equal(checksum.trim(), `${digest}  usAIge-0.2.4-alpha.dmg`);
});

test("publishes a valid automatic update manifest", async () => {
  const manifest = JSON.parse(
    await readFile(new URL("../public/update.json", import.meta.url), "utf8"),
  );
  const dmg = await readFile(new URL(`../public/usAIge-0.2.4-alpha.dmg`, import.meta.url));
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.deepEqual(
    {
      version: manifest.version,
      build: manifest.build,
      minimumSystemVersion: manifest.minimumSystemVersion,
      sha256: manifest.sha256,
    },
    {
      version: "0.2.4",
      build: 26,
      minimumSystemVersion: "11.0",
      sha256: digest,
    },
  );
  assert.equal(
    manifest.downloadURL,
    "https://usaige-macos.richardqz.chatgpt.site/usAIge-0.2.4-alpha.dmg",
  );
});

test("exports the same migration release for the legacy host", async () => {
  const legacyRoot = new URL("../out/project/usaige/", import.meta.url);
  const html = await readFile(new URL("index.html", legacyRoot), "utf8");
  const manifest = JSON.parse(await readFile(new URL("update.json", legacyRoot), "utf8"));
  const dmg = await readFile(new URL("usAIge-0.2.4-alpha.dmg", legacyRoot));
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.match(
    html,
    /https:\/\/pmrichq\.com\/project\/usaige\/usAIge-0\.2\.4-alpha\.dmg/,
  );
  assert.deepEqual(
    { version: manifest.version, build: manifest.build, sha256: manifest.sha256 },
    { version: "0.2.4", build: 26, sha256: digest },
  );
  assert.equal(
    manifest.downloadURL,
    "https://pmrichq.com/project/usaige/usAIge-0.2.4-alpha.dmg",
  );
});
