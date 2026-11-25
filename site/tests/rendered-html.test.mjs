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
    /https:\/\/pmrichq\.com\/project\/usaige\/usAIge-0\.2\.34-alpha\.dmg/,
  );
  assert.match(
    html,
    /https:\/\/pmrichq\.com\/project\/usaige\/usAIge-0\.2\.34-alpha\.dmg\.sha256/,
  );
  assert.match(html, /Up to 100 active tasks/i);
  assert.match(html, /Pink error, green recent completion, yellow needs input, blue running/i);
  assert.match(html, /Click the ring to reopen the exact task/i);
  assert.match(html, /10–100%/i);
  assert.match(html, /50–250%/i);
  assert.match(html, /New in v0\.2\.34/i);
  assert.match(html, /Circular provider badges sit inside the usage rings/i);
  assert.match(html, /reset times below/i);
  assert.doesNotMatch(html, /layered glass paperweights|Turn or zoom the view/i);
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

test("keeps the landing page independent and explicit about the alpha", async () => {
  const source = await readFile(new URL("../app/layout.tsx", import.meta.url), "utf8");
  const response = await render();
  const html = await response.text();

  assert.doesNotMatch(source, /vibeloft|data-vl-/i);
  assert.doesNotMatch(html, /vibeloft\.ai\/telemetry|data-vl-/i);
  assert.match(html, /Independent open-source software by Richard Q/i);
  assert.match(html, /Not affiliated with OpenAI, Anthropic, Cursor, or xAI/i);
  assert.match(html, /without an Apple Developer ID signature or Apple notarization/i);
  assert.match(html, /Review the source and checksum before deciding whether to install/i);
  assert.doesNotMatch(html, /Control-click to open once|Choose Open on first launch/i);
  for (const destination of [
    "https://pmrichq.com/",
    "https://github.com/RichardZhengQuan/usAIge",
    "https://github.com/RichardZhengQuan/usAIge/releases",
    "https://github.com/RichardZhengQuan/usAIge/issues",
  ]) {
    assert.ok(html.includes(`href="${destination}"`));
  }
  assert.match(html, /Claude’s normal authorization and permission checks/i);
  assert.match(html, /session notifications can include task titles and workspace names/i);
  assert.match(html, /Provider credentials and conversation bodies are not sent to the relay/i);
  assert.match(html, /Task state is read locally/i);
});

test("publishes a checksum matching the current disk image", async () => {
  const dmg = await readFile(new URL("../public/usAIge-0.2.34-alpha.dmg", import.meta.url));
  const checksum = await readFile(
    new URL("../public/usAIge-0.2.34-alpha.dmg.sha256", import.meta.url),
    "utf8",
  );
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.equal(checksum.trim(), `${digest}  usAIge-0.2.34-alpha.dmg`);
});

test("publishes a valid automatic update manifest", async () => {
  const manifest = JSON.parse(
    await readFile(new URL("../public/update.json", import.meta.url), "utf8"),
  );
  const dmg = await readFile(new URL(`../public/usAIge-0.2.34-alpha.dmg`, import.meta.url));
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.deepEqual(
    {
      version: manifest.version,
      build: manifest.build,
      minimumSystemVersion: manifest.minimumSystemVersion,
      sha256: manifest.sha256,
    },
    {
      version: "0.2.34",
      build: 59,
      minimumSystemVersion: "11.0",
      sha256: digest,
    },
  );
  assert.equal(
    manifest.downloadURL,
    "https://pmrichq.com/project/usaige/usAIge-0.2.34-alpha.dmg",
  );
  // The app pins the release key, so an unsigned manifest blocks every update.
  assert.match(manifest.signature ?? "", /^[A-Za-z0-9+/]{86}==$/);
});

test("exports the current release for the public website", async () => {
  const legacyRoot = new URL("../out/project/usaige/", import.meta.url);
  const html = await readFile(new URL("index.html", legacyRoot), "utf8");
  const manifest = JSON.parse(await readFile(new URL("update.json", legacyRoot), "utf8"));
  const dmg = await readFile(new URL("usAIge-0.2.34-alpha.dmg", legacyRoot));
  const digest = createHash("sha256").update(dmg).digest("hex");

  assert.match(
    html,
    /https:\/\/pmrichq\.com\/project\/usaige\/usAIge-0\.2\.34-alpha\.dmg/,
  );
  assert.deepEqual(
    { version: manifest.version, build: manifest.build, sha256: manifest.sha256 },
    { version: "0.2.34", build: 59, sha256: digest },
  );
  assert.equal(
    manifest.downloadURL,
    "https://pmrichq.com/project/usaige/usAIge-0.2.34-alpha.dmg",
  );
  // The signature covers version, build, and sha256, so the rewritten URL keeps it valid.
  const source = JSON.parse(await readFile(new URL("../public/update.json", import.meta.url), "utf8"));
  assert.equal(manifest.signature, source.signature);
});
