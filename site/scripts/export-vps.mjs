import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const basePath = "/project/usaige";
const outputRoot = resolve("out");
const siteRoot = resolve(`out${basePath}`);

const workerUrl = new URL(`../dist/server/index.js?export=${Date.now()}`, import.meta.url);
const { default: worker } = await import(workerUrl.href);
const response = await worker.fetch(
  new Request(`http://localhost${basePath}/`, {
    headers: { accept: "text/html" },
  }),
  { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
  { waitUntil() {}, passThroughOnException() {} },
);

if (!response.ok) {
  throw new Error(`Could not render ${basePath}/: HTTP ${response.status}`);
}

const html = (await response.text()).replaceAll(
  "/assets/_vinext_fonts/",
  `${basePath}/assets/_vinext_fonts/`,
);

await rm(outputRoot, { recursive: true, force: true });
await mkdir(siteRoot, { recursive: true });
await cp(resolve("dist/client"), siteRoot, { recursive: true });
await writeFile(resolve(siteRoot, "index.html"), html);

console.log(`Exported ${basePath}/ to ${siteRoot}`);
