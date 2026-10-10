import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { pathToFileURL } from "node:url";
import { SQLiteD1Database } from "./sqlite-d1.mjs";

export const maximumBodyBytes = 256 * 1024;
const apiPath = "/api/v1/";
const apnsKeys = ["APNS_TEAM_ID", "APNS_KEY_ID", "APNS_PRIVATE_KEY", "APNS_TOPIC"];

function publicConfiguration(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new Error("The public URL must be an HTTPS URL without credentials, query, or fragment.");
  }
  const basePath = url.pathname.replace(/\/+$/, "");
  if (!/^\/[a-zA-Z0-9/_-]*$/.test(basePath || "/")) {
    throw new Error("The public URL has an unsupported base path.");
  }
  return { origin: url.origin, basePath, publicURL: `${url.origin}${basePath}` };
}

function jsonError(message, status) {
  return Response.json({ error: message }, { status, headers: { "cache-control": "no-store" } });
}

function readBody(request) {
  if (Number(request.headers["content-length"] ?? 0) > maximumBodyBytes) {
    request.resume();
    return Promise.reject(new BodyTooLargeError());
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    let settled = false;
    request.on("data", chunk => {
      if (settled) return;
      bytes += chunk.length;
      if (bytes > maximumBodyBytes) {
        settled = true;
        chunks.length = 0;
        reject(new BodyTooLargeError());
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    const fail = () => {
      if (settled) return;
      settled = true;
      reject(new Error("Request body interrupted."));
    };
    request.on("aborted", fail);
    request.on("error", fail);
  });
}

class BodyTooLargeError extends Error {}

async function writeResponse(response, outgoing) {
  outgoing.statusCode = response.status;
  for (const [name, value] of response.headers) outgoing.setHeader(name, value);
  // This service never serves cacheable responses, including its health route.
  outgoing.setHeader("cache-control", "no-store");
  outgoing.end(Buffer.from(await response.arrayBuffer()));
}

async function rewritePublicURLs(response, configuration) {
  if (!response.headers.get("content-type")?.includes("application/json")) return response;
  const payload = await response.json();
  if (typeof payload.uploadURL === "string") {
    const uploadURL = new URL(payload.uploadURL);
    if (uploadURL.origin === configuration.origin && uploadURL.pathname.startsWith(apiPath)) {
      payload.uploadURL = `${configuration.publicURL}${uploadURL.pathname}${uploadURL.search}`;
    }
  }
  return Response.json(payload, { status: response.status, headers: response.headers });
}

export async function createRelayServer({
  databasePath,
  publicURL = "https://pmrichq.com/project/usaige",
  port = 8788,
  environment = {},
  logger = message => console.error(message),
  shutdownTimeoutMs = 10_000,
} = {}) {
  const configuration = publicConfiguration(publicURL);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) throw new Error("Invalid relay port.");
  const database = new SQLiteD1Database(databasePath);
  const env = { DB: database };
  for (const key of apnsKeys) if (environment[key]) env[key] = environment[key];
  // Each server instance needs its own Worker's schema and APNs cache. This also
  // permits isolated database fixtures and clean restarts within one process.
  const workerURL = new URL(`../worker/relay-api.ts?runtime=${randomUUID()}`, import.meta.url);
  let handleRelayRequest;
  try {
    ({ handleRelayRequest } = await import(workerURL.href));
    const initialized = await handleRelayRequest(new Request(`${configuration.origin}${apiPath}`), env, { waitUntil() {} });
    if (initialized?.status !== 404) throw new Error("Relay schema initialization failed.");
  } catch (error) {
    database.close();
    throw error;
  }

  const pendingBackgroundTasks = new Set();
  const context = {
    waitUntil(promise) {
      const pending = Promise.resolve(promise).catch(() => logger("relay_background_failed"));
      pendingBackgroundTasks.add(pending);
      pending.finally(() => pendingBackgroundTasks.delete(pending));
    },
  };

  const server = createServer(async (incoming, outgoing) => {
    try {
      if (!incoming.url?.startsWith("/") || incoming.url.startsWith("//")) {
        return await writeResponse(jsonError("Not found.", 404), outgoing);
      }
      const url = new URL(incoming.url, configuration.origin);
      let pathname = url.pathname;
      if (configuration.basePath && pathname.startsWith(`${configuration.basePath}${apiPath}`)) {
        pathname = pathname.slice(configuration.basePath.length);
      }
      if (!pathname.startsWith(apiPath)) {
        incoming.resume();
        return await writeResponse(jsonError("Not found.", 404), outgoing);
      }
      const body = await readBody(incoming);
      if (pathname === `${apiPath}health`) {
        if (incoming.method !== "GET") {
          return await writeResponse(jsonError("Method not allowed.", 405), outgoing);
        }
        try {
          await database.prepare("SELECT id FROM relay_channels LIMIT 1").first();
          return await writeResponse(Response.json({ status: "ok", service: "usaige-relay" }), outgoing);
        } catch {
          logger("relay_health_failed");
          return await writeResponse(jsonError("Relay storage is unavailable.", 503), outgoing);
        }
      }

      const headers = new Headers();
      for (const [name, value] of Object.entries(incoming.headers)) {
        if (value !== undefined) headers.set(name, Array.isArray(value) ? value.join(", ") : value);
      }
      // Nginx owns X-Real-IP; the loopback listener is not exposed publicly.
      // Request Host and forwarded URL headers never choose response origins.
      headers.set("cf-connecting-ip", incoming.headers["x-real-ip"] || incoming.socket.remoteAddress || "unknown");
      const requestURL = `${configuration.origin}${pathname}${url.search}`;
      const request = new Request(requestURL, {
        method: incoming.method,
        headers,
        ...(incoming.method === "GET" || incoming.method === "HEAD" ? {} : { body }),
      });
      const response = await handleRelayRequest(request, env, context) ?? jsonError("Not found.", 404);
      if (response.status >= 500) logger("relay_service_failed");
      await writeResponse(await rewritePublicURLs(response, configuration), outgoing);
    } catch (error) {
      if (outgoing.destroyed || outgoing.headersSent) return;
      outgoing.setHeader("connection", "close");
      if (error instanceof BodyTooLargeError) {
        await writeResponse(jsonError("Request body is too large.", 413), outgoing);
      } else {
        logger("relay_request_failed");
        await writeResponse(jsonError("Relay request failed.", 500), outgoing);
      }
    }
  });
  server.requestTimeout = 20_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  let closePromise;

  return {
    server,
    database,
    publicURL: configuration.publicURL,
    listen() {
      return new Promise((resolve, reject) => {
        const onError = error => reject(error);
        server.once("error", onError);
        server.listen(port, "127.0.0.1", () => {
          server.removeListener("error", onError);
          resolve(server.address());
        });
      });
    },
    close() {
      closePromise ??= (async () => {
        let deadline;
        const timedOut = new Promise(resolve => {
          deadline = setTimeout(() => {
            server.closeAllConnections();
            resolve();
          }, shutdownTimeoutMs);
          deadline.unref();
        });
        const drained = new Promise(resolve => server.close(resolve))
          .then(() => Promise.allSettled([...pendingBackgroundTasks]));
        await Promise.race([drained, timedOut]);
        clearTimeout(deadline);
        database.close();
      })();
      return closePromise;
    },
  };
}

async function main() {
  const runtime = await createRelayServer({
    databasePath: process.env.RELAY_DB_PATH,
    publicURL: process.env.RELAY_PUBLIC_URL || "https://pmrichq.com/project/usaige",
    port: Number(process.env.RELAY_PORT || 8788),
    environment: process.env,
  });
  try {
    const address = await runtime.listen();
    console.log(`usAIge relay listening on 127.0.0.1:${address.port}`);
  } catch (error) {
    await runtime.close();
    throw error;
  }
  const stop = () => {
    runtime.close().then(
      () => process.exit(0),
      () => { console.error("relay_shutdown_failed"); process.exit(1); },
    );
  };
  process.once("SIGTERM", stop);
  process.once("SIGINT", stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => { console.error("relay_startup_failed"); process.exitCode = 1; });
}
