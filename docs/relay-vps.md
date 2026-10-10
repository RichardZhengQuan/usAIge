# usAIge relay on the pmrichq.com VPS

The website's static export does not include the relay. The VPS runtime in
`site/server/index.mjs` serves the existing `site/worker/relay-api.ts` API with
SQLite and listens only on `127.0.0.1`. Nginx publishes it below
`https://pmrichq.com/project/usaige/api/v1/`.

## Runtime and files

Use Node.js **22.13.0 or newer**, including its `node:sqlite` module and TypeScript
stripping. This runtime needs no npm dependencies or website build. Deploy
`site/server/` and `site/worker/relay-api.ts` together, preserving their relative
paths. The supported SQLite API is documented in the
[Node 22.13 documentation](https://nodejs.org/download/release/v22.13.0/docs/api/sqlite.html).

Set these environment variables for the service:

| Variable | Value |
| --- | --- |
| `RELAY_PUBLIC_URL` | `https://pmrichq.com/project/usaige` |
| `RELAY_DB_PATH` | Absolute persistent path, such as `/var/lib/usaige-relay/relay.sqlite` |
| `RELAY_PORT` | `8788`, or another unused loopback port |

The deployment script pins and verifies the official Node **v22.23.3** Linux
x64 archive. It installs that binary only under
`/opt/usaige-relay/runtime/node-v22.23.3-linux-x64/`, without replacing the
server's global Node installation. The release archive contains `server/` and
`worker/relay-api.ts`; each release lives in
`/opt/usaige-relay/releases/<UTC timestamp>/`, and
`/opt/usaige-relay/current` points to the active release.

The service runs this command from `/opt/usaige-relay/current`:

```sh
/opt/usaige-relay/runtime/node-v22.23.3-linux-x64/bin/node --experimental-strip-types server/index.mjs
```

Run as a dedicated unprivileged service user. Give that user a private state
directory with mode `0700`; keep it outside release directories. The runtime
creates an owner-only database file, enables foreign keys and WAL, and sets a
five-second SQLite busy timeout. It refuses database-file symlinks. D1 schema
batches execute in a SQLite transaction; the existing worker initializes its
schema before accepting HTTP requests.

Configuration is stored in the root-owned, mode `0600`
`/etc/usaige-relay/relay.env` and read by systemd. The script creates the default
file only when it is absent, preserving existing configuration on subsequent
deployments. The optional `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, and
`APNS_TOPIC` variables are passed to the shared worker only when configured.
Keep any real `.p8` key in service secret storage. Pairing and quota polling
work without APNs.

The VPS adapter currently preserves the worker's plain `fetch` push transport;
Node 22 uses HTTP/1.1 by default for that transport. Apple requires
[HTTP/2 for APNs](https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns).
Before enabling push on the VPS, add an HTTP/2 transport and test real Apple
credentials with the installed iPhone app. Supplying environment variables
alone does not establish background push support.

## Reverse proxy

The script adds `/etc/nginx/snippets/usaige-relay.conf` inside the existing HTTPS
server block in `/etc/nginx/sites-available/pmrichq`. The proxy preserves the
public base path; the adapter also accepts stripped `/api/v1/` requests.

```nginx
location ^~ /project/usaige/api/v1/ {
    client_max_body_size 256k;
    proxy_pass http://127.0.0.1:8788;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header CF-Connecting-IP $remote_addr;
    proxy_set_header Connection "";
    proxy_connect_timeout 5s;
    proxy_read_timeout 30s;
    proxy_send_timeout 30s;
    proxy_intercept_errors off;
    access_log off;
}
```

The configured public URL chooses generated upload URLs. Request `Host` and
forwarded host/protocol headers cannot change that destination. `X-Real-IP` is
trusted only because Nginx overwrites it and the listener is loopback-only.
Request bodies above 256 KiB are rejected before reaching the worker, including
chunked uploads. Service logs use fixed event names and omit headers, tokens,
request bodies, and SQL values. Reverse-proxy access logs are disabled for these
credential-bearing routes.

## Service lifecycle

The script installs `/etc/systemd/system/usaige-relay.service` for the dedicated
`usaige-relay` user:

```ini
[Unit]
Description=usAIge usage relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=usaige-relay
Group=usaige-relay
WorkingDirectory=/opt/usaige-relay/current
Environment=NODE_ENV=production
EnvironmentFile=/etc/usaige-relay/relay.env
ExecStart=/opt/usaige-relay/runtime/node-v22.23.3-linux-x64/bin/node --experimental-strip-types server/index.mjs
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/usaige-relay
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
```

SIGTERM/SIGINT stop new requests, drain active HTTP and background work, and
close SQLite. A ten-second deadline closes remaining sockets before shutdown.
Keep the SQLite database and its WAL/SHM companions when deploying releases.
Use a SQLite-consistent backup or stop the service before copying its files.

## Deployment

From the GPTUsage repository, use the existing SSH identity authorized for the
pmrichq.com server:

```sh
SSH_IDENTITY=/absolute/path/to/existing-key bash scripts/deploy-relay-vps.sh
```

`RELAY_SSH_TARGET` defaults to `root@pmrichq.com`. `RELAY_NODE_ARCHIVE` can select
an already downloaded archive; the pinned checksum is still required. SSH uses
batch mode and existing host-key verification.

The script archives only the relay source, verifies the isolated Node runtime,
creates a persistent private state directory, tests Nginx configuration, and
activates the service release. Existing website files and other project routes
are outside the archive. Before declaring remote activation successful, it
checks loopback health, service state, and the local HTTPS proxy using the real
pmrichq.com hostname. Failed activation restores the previous release and
backed-up Nginx/unit configuration; first-install failure disables the new
service and removes the failed current-release link. A subsequent public health
request separately checks access through the external network.

## Verification

Run the real SQLite and HTTP fixture tests from `site/`:

```sh
node --experimental-strip-types --test tests/relay-server.test.mjs
```

They verify numeric phone pairing, Mac snapshot retrieval, one-time remote-tool
pairing, public upload URLs, tool upload/fetch, authorization, revocation,
restart persistence, foreign-key cascades, atomic batches, private file modes,
body-size limits, and storage-aware health responses. All accounts and tokens
in these tests are disposable fixtures.

After deploying, read-only health requests should return HTTP 200 JSON with
`{"status":"ok","service":"usaige-relay"}`:

```sh
curl --fail http://127.0.0.1:8788/api/v1/health
curl --fail https://pmrichq.com/project/usaige/api/v1/health
```

A healthy unauthenticated endpoint proves runtime and database availability. It
does not establish that an installed Mac/iPhone client paired successfully or
that Apple push delivery works.

`python3 scripts/verify-relay-vps.py` performs a public HTTPS smoke test using
one disposable Mac channel, phone, and remote tool, then revokes and removes
all test connections. It verifies pairing, public upload URLs, quota exchange,
authorization, revocation, and the typed missing-channel recovery response.
See [the deployment evidence](relay-fix-2026-10-10/verification.md) for the
activated release and verified client artifact.
