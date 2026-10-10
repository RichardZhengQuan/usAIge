# Relay endpoint and connection recovery verification

Initial endpoint deployment verified on 2026-10-10 in the GPTUsage project.
The initial source snapshot was 0.2.13; the fixes were subsequently integrated
onto remote main 0.2.16 for release 0.2.17. The initial evidence below remains
a historical record; final release validation follows at the end.

The retired Sites URL returned an HTML 404. The static pmrichq.com website
did not have an API. A dedicated Node/SQLite relay now runs as the unprivileged
`usaige-relay` systemd service on loopback, behind the existing HTTPS server at
`https://pmrichq.com/project/usaige/api/v1/`.

Activated release: `20261010T131945Z`. The service is active and enabled.
The SQLite database is outside the release directory, with file mode `0600`
and directory mode `0700`. The initial deployment used these SHA-256 hashes before current-main integration:

| Source | SHA-256 |
| --- | --- |
| `site/server/index.mjs` | `d031caaa9ee2cd34ac45a3202f25d2b9fcbf558ad1d09fa87882ac4cb237a585` |
| `site/server/sqlite-d1.mjs` | `6a4f5ff136e0d3bfa3d8007df42f8d6671496c49b3b6183d958eb2675dda9027` |
| `site/worker/relay-api.ts` | `9f5299061584b0c14d76a1c43d04dcf79b96d0e78df671245b91858e18b185a3` |

Verification passed:

- Public HTTPS health returned HTTP 200 JSON with `status: ok`.
- `python3 scripts/verify-relay-vps.py` exercised real public HTTPS with one
  disposable Mac connection, iPhone, and remote tool. Pairing, one-time tool
  claim, correctly prefixed public upload URL, Mac/iPhone snapshots, remote
  quota upload/fetch, unauthorized requests, revocation, and channel deletion
  passed. Tokens stayed in process memory and were never printed.
- After cleanup, the server database had zero channels, devices, tools, phone
  pairing records, or tool pairing records.
- The existing static usAIge website still returned HTTP 200.
- Twenty backend contract/runtime checks passed, including real SQLite,
  restart persistence, SIGTERM shutdown, atomic batches, body limits, and
  health failure when storage is unavailable.
- All 229 Swift tests passed from a refreshed source-only temporary package.
  The disposable private-pasteboard test passed outside the sandbox; opt-in
  live-account and render suites retained their default disabled settings.
- Native light/dark previews at 520 x 580 points passed. Actual Retry clicks
  showed loading, then a successful empty state. Actual Reconnect clicks
  rechecked a coded missing channel, created a fresh channel, and displayed
  a new pairing code. See `ui-verification.md` and the saved screenshots.
- The arm64 release build passed. The rebuilt Mac app is packaged in
  [`usAIge-relay-fix.zip`](../../dist/relay-fix-2026-10-10/usAIge-relay-fix.zip).
  A clean extraction passed strict code-signature verification and plist
  validation. Its binary contains the new API, claim, and feedback URLs.
  Version/build remain `0.2.13` / `35`; this is an ad-hoc signed local build.
  The installed app was not replaced or launched. Build logs and ZIP hashes
  are in the adjacent artifact verification report.

All Mac relay, setup-prompt, feedback, and shared iPhone relay URLs now use
the new endpoint. The UI distinguishes successful empty results, loading,
temporary errors with Retry, saved data, and verified missing connections
with Reconnect. A missing channel requires HTTP 404, JSON MIME type, and the
exact `channel_not_found` code. HTML errors, authentication failures, and
temporary server errors preserve existing credentials.

The old Sites database was inaccessible, so its connections were not migrated.
Existing users must reconnect their Mac and pair their phones/tools again
after updating clients. Preview checks used disposable fixtures; installed
apps and real AI provider accounts were not modified or tested.

APNs credentials are not configured. Background push delivery is outside this
verification; the required HTTP/2 transport limitation is recorded in
`../relay-vps.md`. Foreground pairing and quota polling were verified live.

## Release 0.2.17 validation

The release branch starts from current remote main
`8b74aa43bf685cf290c33a897bb0f4954878c5e3` and preserves its Claude app support,
per-tool session states, signed-update verification, adaptive Settings sizing,
path encoding, and error sanitization. App and bundled notes are version
`0.2.17`, build `39`. Watch relay URLs also use the new endpoint.

- All 297 Swift tests passed, including the disposable pasteboard test.
- All 44 website/relay tests passed, including 38 relay contract/runtime checks.
- Website lint passed with only the five existing image-element warnings.
- The release app and mounted DMG passed strict code-signature verification
  and plist validation.
- The signed update manifest matches the pinned Ed25519 public key, the DMG
  SHA-256, version/build, and bundled release notes.
- The public download URL and primary update feed use pmrichq.com.
- Native Retry and Reconnect clicks passed against the integrated current-main
  source, with content-driven window sizing in light/dark appearances.

Artifact: `site/public/usAIge-0.2.17-alpha.dmg`. SHA-256:
`521d62e1e1a9e76df5658fdbd9084a02abd18291f7d6dc87cfb27dbb5b0a15ca`.
The release activation and remote merge proof are recorded separately after
publication. No installed app or real provider account was changed by these
fixture and packaging checks.
