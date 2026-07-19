# usAIge

usAIge has native clients for macOS, iPhone, iPad, and Apple Watch. The Mac is
the trusted limit collector: it reads local Codex and paired remote tools,
then relays only normalized percentages and reset times to paired iPhones.

## iOS app and widget

Open `usAIge-iOS.xcodeproj` in Xcode 26. The project contains:

- A native tab-based iPhone and iPad app with Usage and Connection sections.
- Account-free pairing with an 8-character, one-use code shown by the Mac.
- A device-scoped relay token stored in the iOS Keychain.
- An App Group JSON cache containing quota values only, never tokens.
- Small, medium, and large widgets backed by the shared cache.
- Immediate foreground and pull-to-refresh updates plus APNs-assisted,
  best-effort background refresh scheduling.
- Credential-free WatchConnectivity sync to the Watch app and watch-face
  complications.

Open **Settings → iPhone & Apple Watch Sync** on the Mac, create a code, and enter it in the
iPhone Connection tab. One Mac can issue separate revocable codes for multiple
iPhones. iOS controls the exact time granted to background tasks and widget
timelines, so the app shows saved data and its update age instead of promising
minute-exact background delivery.

Build the iOS app for Simulator with:

```bash
xcodebuild \
  -project usAIge-iOS.xcodeproj \
  -scheme usAIge-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  build
```

For device builds, select the same Apple development team for the app and
widget targets, register `group.com.richardq.usaige` as an App Group, and enable
Push Notifications plus the Remote notifications background mode.

### iOS privacy

- The channel and device identifiers are stored in the app sandbox. The
  device-scoped read token is stored separately in the iOS Keychain.
- The App Group cache shared with the widget contains normalized quota values,
  reset times, and refresh metadata, but never bearer tokens.
- The relay retains only the latest normalized snapshot until the Mac owner
  disconnects the channel. It receives no provider credentials, browser
  cookies, prompts, account content, or Codex task state.

## Apple Watch app and complications

The Apple Watch version shows every synced remote AI limit and provides
circular, rectangular, inline, and native quarter-curve corner complications.
Users configure sources on the Mac; only normalized quota snapshots are
relayed to iPhone and transferred to the Watch.

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
- For remote limits: a compatible adapter that can claim a one-time usAIge pairing code and upload normalized limits.

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

### Remote AI tools

Connect a remote source from **Settings**:

1. Open **Manage AI Tools → Add AI Tool**.
2. Click **Create Connection** to generate an 8-character, one-use code.
3. Copy the connection instructions into Codex, Claude Code, or another compatible adapter. The tool claims the code and stores its revocable upload credential locally.
4. When the first normalized limit snapshot arrives, usAIge shows the paired tool automatically. Revoke it from the same screen at any time.

This is the same pairing model used by iPhone Sync: short-lived codes, separately revocable devices/tools, and no account password inside usAIge. The old connection-link, endpoint editor, and pasted bearer-token flow have been removed.

The adapter must use an official provider API or documented local command. Consumer plans that do not expose machine-readable current remaining limits cannot be connected safely; usAIge does not scrape provider websites or reuse browser sessions.

#### Upload contract

After claiming the code, the relay returns an `uploadURL` and `writeToken`. Upload with `Authorization: Bearer <writeToken>` and this body:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-19T12:00:00Z",
  "limits": [
    {
      "id": "requests",
      "name": "Requests",
      "planType": "Pro",
      "primary": {
        "remainingPercent": 58,
        "windowDurationMinutes": 300,
        "resetAt": "2030-01-01T00:00:00Z"
      },
      "secondary": {
        "remainingPercent": 67,
        "windowDurationMinutes": 10080,
        "resetAt": "2030-01-07T00:00:00Z"
      }
    }
  ]
}
```

Contract details:

- `id` and `name` are required stable strings. `planType` is optional.
- `primary` is required for a displayed limit. `secondary` is optional; include it when the provider has another quota window.
- Each window must provide `remainingPercent` as a JSON number in `0...100`.
- `windowDurationMinutes` is an optional integer. Common values include `300` for five hours and `10080` for seven days.
- `resetAt` is an optional ISO-8601 timestamp.
- Unknown fields and provider credentials are rejected. A malformed upload cannot replace the last accepted snapshot.

#### Remote limits and safety

- Pairing codes expire after 10 minutes and can be claimed only once.
- Each paired tool receives its own write-only credential and can be revoked independently.
- The relay receives only normalized display metadata and quota windows. Provider credentials remain with the adapter.
- The Mac polls paired snapshots on the normal remote refresh cadence and relays the combined visible view to paired iPhones.

## Settings

Use the gear button on the panel to open native macOS Settings. Available preferences include:

- Active AI tool visibility.
- Quota visibility and vertical ordering.
- Connecting remote AI tools with one-time pairing codes and per-tool revocation.
- Panel opacity and scale.
- Optional automatic launch when you log in to your Mac.
- Automatic update checks, local new-version notifications, and one-click in-app updates.
- Local usage-limit notifications at each new 5% used boundary.
- Always-visible behavior while usAIge is running, including after sleep and wake.

Drag the panel by its background. Its safe position is stored separately for each display. If a display disappears, the panel is clamped onto an available screen the next time it is positioned.

The built-in OpenAI/Codex source reads its local app-server. Additional tools appear only after a paired adapter uploads valid normalized usage data; usAIge does not scrape provider websites or invent missing values.

## Updates

The packaged app checks the public usAIge website at launch and every six hours. When a newer build is published, macOS shows a local notification and Settings marks the update button with a red dot. Clicking the notification opens Settings; clicking **Update** downloads the DMG, verifies its SHA-256 checksum, validates the app bundle and code signature, replaces the installed copy, and relaunches usAIge. A manual **Check for Updates** action reports **You’re up to date!** after a successful check when no newer build exists.

## Usage-limit notifications

After the first successful usage read, usAIge asks for macOS notification permission. The first value for each limit establishes a quiet baseline; it does not generate catch-up alerts. Later live updates notify at newly crossed 5% used boundaries for primary and secondary windows independently. If one update skips several boundaries, usAIge sends one notification for the newest boundary instead of a burst.

When a quota resets, the new window starts its own notification cycle. Selecting a usage notification or its **View Limits** action reveals the floating limits rail. Denying notification permission does not affect live values in the rail.

## macOS privacy

- No browser cookies or web pages are read.
- No OpenAI credentials are copied or stored by usAIge.
- The Mac relay credential is stored in macOS Keychain. Each remote tool keeps its own write credential outside usAIge.
- No screen pixels are captured or inspected.
- Preferences contain visual settings, bucket identifiers, and display positions; they do not contain remote-tool bearer tokens.
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

The automated suite covers quota normalization, JSON-RPC framing, account/rate-limit parsing, one-time remote pairing payloads, state recovery, countdowns, notification thresholds and routing, settings persistence, panel geometry, and severity thresholds.

## TODO

- Add the usAIge website link to Settings.
- Tune the main HUD glass-board opacity while the HUD is hovered.
