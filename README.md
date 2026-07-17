# usAIge

usAIge has native clients for macOS, iPhone, iPad, and Apple Watch. The iOS 26
app connects to
user-owned remote HTTPS endpoints, displays current AI quota limits and reset
times, and shares successful snapshots with Home Screen widgets and a paired
Apple Watch.

## iOS app and widget

Open `usAIge-iOS.xcodeproj` in Xcode 26. The project contains:

- A native tab-based iPhone and iPad app with Usage and Tools sections.
- Add and Edit Connection flows that test the endpoint before saving it,
  including bearer-token rotation or removal.
- Keychain storage for optional bearer tokens.
- An App Group JSON cache containing quota values only, never tokens.
- Small, medium, and large widgets backed by the shared cache.
- Immediate foreground and pull-to-refresh updates plus best-effort iOS
  background refresh scheduling.
- Credential-free WatchConnectivity sync to the Watch app and watch-face
  complications.

The endpoint contract and a complete response example are documented in
[`docs/remote-usage-api.md`](docs/remote-usage-api.md). iOS controls the exact
time granted to background tasks and widget timelines, so the app shows saved
data and its update age instead of promising minute-exact background delivery.

Build the iOS app for Simulator with:

```bash
xcodebuild \
  -project usAIge-iOS.xcodeproj \
  -scheme usAIge-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  build
```

For device builds, select the same Apple development team for the app and
widget targets, then register `group.com.richardq.usaige` as an App Group for
both bundle identifiers. Simulator builds can be compiled without signing.

### iOS privacy

- Tool names, HTTPS endpoint paths, enabled state, and refresh intervals are
  stored in the app's sandboxed Application Support directory.
- Optional bearer tokens are stored separately in the iOS Keychain and can be
  rotated or removed from Edit Connection.
- The App Group cache shared with the widget contains normalized quota values,
  reset times, and refresh metadata, but never bearer tokens.
- The app sends requests only to endpoints the user adds. It does not read
  browser cookies, prompts, or account content.

## Apple Watch app and complications

The Apple Watch version shows every synced remote AI limit and provides
circular, rectangular, inline, and native quarter-curve corner complications.
Users configure endpoints and optional credentials in the existing iOS app;
only normalized quota snapshots are transferred to the Watch.

Open the combined project at `Apple/usAIgeApple.xcodeproj` to build the iOS app,
iOS widget, Watch app, and Watch widget together. Setup, supported watch-face
families, sync behavior, and device signing are documented in
[`Apple/README.md`](Apple/README.md).

## macOS app

usAIge is a native macOS floating AI usage rail. It shows real usage limits from the local Codex app-server and from remote AI tools you explicitly configure. When a limit has two windows, the inner ring shows its primary window and the outer ring shows its secondary window.

macOS can notify you whenever a primary or secondary usage window crosses a new 5% used boundary. Selecting the notification brings the live limits rail forward.

The panel stays above ordinary windows, starts at the bottom-right, and remembers its position per display. Hover over any row to reveal its usage name, remaining percentage, localized reset date, and plan details. Clicking a tool logo opens its installed app or web experience.

While idle, the panel surface is fully transparent and every visible control is shown at half its configured opacity. Hovering anywhere over the rail restores the surface and full configured opacity.

## macOS requirements

- macOS 11 or later on an Apple-silicon Mac.
- Swift 6.2 and Xcode 26 for source builds.
- For local Codex limits: the ChatGPT or Codex macOS app, or a `codex` executable on `PATH`, with an existing Codex-managed ChatGPT sign-in.
- For remote limits: an HTTPS JSON endpoint that implements the contract below. Plain HTTP is accepted only for loopback development endpoints.

usAIge uses the bundled Codex executable from the ChatGPT/Codex application when available. It does not implement a second account login.

## Build and run macOS

```bash
swift test
swift run usAIge
```

The development executable runs as a regular macOS app. Stop it from the launching terminal with Control-C.

## Package the application

```bash
scripts/package-app.sh
open 'dist/usAIge.app'
```

The script creates an ad-hoc signed application at `dist/usAIge.app`. Ad-hoc signing is suitable for local development but is not a substitute for Developer ID signing and notarization for public distribution.

The packaged application includes the custom usAIge icon in Finder, the Dock, Spotlight, and other macOS surfaces.

## Install the public alpha

Download `usAIge-0.2.1-alpha.dmg` and its checksum from the website. Open the disk image, then drag `usAIge.app` onto the Applications shortcut.

This alpha is ad-hoc signed and is not notarized because the project does not yet have a Developer ID Application certificate. On first launch:

1. Open the Applications folder.
2. Control-click `usAIge` and choose **Open**.
3. Click **Open** in the confirmation dialog.

macOS remembers that choice for later launches. A future Developer ID-signed and notarized release will remove this one-time step.

To build and verify the installer locally:

```bash
scripts/package-dmg.sh
(cd dist && shasum -a 256 -c usAIge-0.2.1-alpha.dmg.sha256)
```

## Usage data

### Local Codex

usAIge starts `codex app-server` locally and uses its documented JSON-RPC methods:

- `initialize`, followed by the `initialized` notification.
- `account/read` to detect the existing account.
- `account/rateLimits/read` for all available rate-limit buckets.
- `account/rateLimits/updated` for live changes.

The app prefers `rateLimitsByLimitId` and falls back to the legacy single `rateLimits` bucket. It reads both the primary and secondary windows for each bucket and never estimates a missing limit.

### Remote AI tools (0.1.11)

Connect a remote source from **Settings**:

1. In **Connected AI tools**, click **Connect a Tool**.
2. Paste the `usaige://connect?...` link supplied by a compatible service or your team administrator.
3. Click **Connect**. The link fills in the service name, Usage URL, website, and optional access token for you.

If you do not have a connection link, use **Get help → Copy Setup Prompt** in the connection sheet. Paste that request into Codex or Claude Code. It will check the provider's documented options, prepare a compatible adapter and link when possible, or explain clearly when the account cannot expose usage. The prompt is self-contained and explicitly forbids browser scraping, copied session credentials, secrets in chat, and undocumented private APIs.

A public HTTPS Usage URL can also be pasted directly. Use the panel refresh button for an immediate request; enabled remote tools otherwise refresh every 60 seconds.

### Where does the connection link come from?

It does not come from an ordinary AI-app login. A compatible service or a team-owned adapter must issue it. Consumer Claude, Gemini, and Cursor accounts do not currently expose their subscription limits through a simple endpoint that usAIge can call. [OpenAI](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage) and [Anthropic](https://platform.claude.com/docs/en/api/admin/usage_report/retrieve_messages) usage APIs are organization/admin APIs for API consumption, [Cursor's usage API](https://docs.cursor.com/en/account/teams/admin-api) is for team administrators, and [Gemini](https://ai.google.dev/gemini-api/docs/rate-limits) directs users to AI Studio to view active limits. usAIge does not scrape browser sessions to work around those restrictions.

For a team adapter, URL-encode the values into this format and deliver the result through a secure channel:

```text
usaige://connect?name=Team%20Claude&endpoint=https%3A%2F%2Flimits.example.com%2Fusage&website=https%3A%2F%2Fclaude.ai&token=secret
```

The optional token is moved into macOS Keychain when the link is accepted; the connection link itself is not saved in preferences. Anyone holding a token-bearing link can access whatever that token permits, so treat it like a password.

Developers operating a compatible endpoint can instead expand **Advanced setup** and enter the details manually.

The configured endpoint must use HTTPS. For local development only, HTTP is accepted when the host is `localhost`, `127.0.0.1`, or `::1`. usAIge sends a `GET` request with `Accept: application/json`. If a token is configured, the request also includes `Authorization: Bearer <token>`.

The endpoint must return a JSON object with a `limits` array. This is the canonical response contract:

```json
{
  "limits": [
    {
      "id": "requests",
      "name": "Requests",
      "planType": "Pro",
      "primary": {
        "usedPercent": 42,
        "windowDurationMinutes": 300,
        "resetsAt": 1893456000
      },
      "secondary": {
        "remainingPercent": 67,
        "windowDurationMinutes": 10080,
        "resetsAt": 1893974400
      }
    }
  ]
}
```

Contract details:

- `id` is a required, non-empty string that remains stable for the limit. `name` and `planType` are optional strings.
- `primary` is required for a displayed limit. `secondary` is optional; include it when the provider has another quota window.
- Each window must provide either `usedPercent` or `remainingPercent` as a JSON number. If both are present, `usedPercent` takes precedence. Values are normalized to the `0...100` range.
- `windowDurationMinutes` is an optional integer. Common values include `300` for five hours and `10080` for seven days.
- `resetsAt` is an optional JSON number containing an absolute Unix timestamp in seconds, not milliseconds or a relative countdown. For example, `1893456000` is `2030-01-01T00:00:00Z`.
- Unknown fields are ignored. A limit without a usable primary percentage is omitted rather than estimated.

#### Remote limits and safety

- A response must have a successful `2xx` HTTP status, valid JSON, no more than 100 limits, and a body no larger than 1 MB. The body is streamed and cancelled as soon as it crosses that limit.
- Each request has a 15-second timeout. A failure in one configured remote tool does not prevent other available sources from reporting their limits.
- Remote tools are read-only: usAIge makes `GET` requests and never sends account usage back to the provider.
- Configure only endpoints you trust. The endpoint operator can observe the request, bearer token, IP address, and standard HTTP metadata.

## Settings

Use the gear button on the panel to open native macOS Settings. Available preferences include:

- Active AI tool visibility.
- Quota visibility and vertical ordering.
- Connecting remote AI tools with a one-step connection link, plus advanced manual setup.
- Panel opacity and scale.
- Optional automatic launch when you log in to your Mac.
- Automatic update checks, local new-version notifications, and one-click in-app updates.
- Local usage-limit notifications at each new 5% used boundary.
- Always-visible behavior while usAIge is running, including after sleep and wake.

Drag the panel by its background. Its safe position is stored separately for each display. If a display disappears, the panel is clamped onto an available screen the next time it is positioned.

The built-in OpenAI/Codex source reads its local app-server. Additional tools appear only when you configure a remote endpoint that returns valid usage data; usAIge does not scrape provider websites or invent missing values.

## Updates

The packaged app checks the public usAIge website at launch and every six hours. When a newer build is published, macOS shows a local notification and Settings marks the update button with a red dot. Clicking the notification opens Settings; clicking **Update** downloads the DMG, verifies its SHA-256 checksum, validates the app bundle and code signature, replaces the installed copy, and relaunches usAIge. A manual **Check for Updates** action reports **You’re up to date!** after a successful check when no newer build exists.

## Usage-limit notifications

After the first successful usage read, usAIge asks for macOS notification permission. The first value for each limit establishes a quiet baseline; it does not generate catch-up alerts. Later live updates notify at newly crossed 5% used boundaries for primary and secondary windows independently. If one update skips several boundaries, usAIge sends one notification for the newest boundary instead of a burst.

When a quota resets, the new window starts its own notification cycle. Selecting a usage notification or its **View Limits** action reveals the floating limits rail. Denying notification permission does not affect live values in the rail.

## macOS privacy

- No browser cookies or web pages are read.
- No OpenAI credentials are copied or stored by usAIge.
- An optional remote bearer token is stored in the macOS Keychain, never in usAIge preferences, and is sent only in requests to that tool's configured endpoint.
- No screen pixels are captured or inspected.
- Preferences contain visual settings, bucket identifiers, display positions, and remote tool metadata such as names and URLs; they do not contain bearer tokens.
- Unsupported or malformed quota buckets are omitted rather than guessed.

## Visibility

The floating panel remains visible while usAIge is running, including across Spaces, full-screen apps, and sleep/wake. Use **Quit usAIge** in Settings to remove it.

## Troubleshooting

### “Open Codex to connect”

Start the ChatGPT or Codex app, confirm that it is signed in, then press the refresh button. The app searches these locations before checking `PATH`:

- `/Applications/ChatGPT.app/Contents/Resources/codex`
- `/Applications/Codex.app/Contents/Resources/codex`
- `/opt/homebrew/bin/codex`
- `/usr/local/bin/codex`

### Stale values

When the local app-server or network disconnects, usAIge dims the last successful values and retries with bounded backoff. Press refresh after connectivity returns for an immediate attempt.

### No usage limits available

The signed-in account did not return any supported rate-limit buckets. usAIge does not manufacture a percentage or reset time when the service omits it.

## Verification

```bash
swift package clean
swift test
scripts/package-app.sh
scripts/package-dmg.sh
codesign --verify --deep --strict 'dist/usAIge.app'
```

The automated suite covers quota normalization, JSON-RPC framing, account/rate-limit parsing, remote connection links, state recovery, countdowns, notification thresholds and routing, settings persistence, panel geometry, and severity thresholds.

## TODO

- Add the usAIge website link to Settings.
- Tune the main HUD glass-board opacity while the HUD is hovered.
