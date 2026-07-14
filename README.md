# usAIge

usAIge is a native macOS floating AI usage rail. Every active Codex bucket is shown with concentric real-data meters: the inner ring tracks its 5-hour window and the outer ring tracks its 7-day window.

The panel stays above ordinary windows, starts at the bottom-right, and remembers its position per display. Hover over any row to reveal its usage name, remaining percentage, localized reset date, and plan details. Clicking a tool logo opens its installed app or web experience.

While idle, the panel surface is fully transparent and every visible control is shown at half its configured opacity. Hovering anywhere over the rail restores the surface and full configured opacity.

## Requirements

- macOS 15 or later.
- Swift 6.2 and Xcode 26 for source builds.
- The ChatGPT or Codex macOS app, or a `codex` executable on `PATH`.
- An existing Codex-managed ChatGPT sign-in.

usAIge uses the bundled Codex executable from the ChatGPT/Codex application when available. It does not implement a second account login.

## Build and run

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

Download `usAIge-0.1.10-alpha.dmg` and its checksum from the website. Open the disk image, then drag `usAIge.app` onto the Applications shortcut.

This alpha is ad-hoc signed and is not notarized because the project does not yet have a Developer ID Application certificate. On first launch:

1. Open the Applications folder.
2. Control-click `usAIge` and choose **Open**.
3. Click **Open** in the confirmation dialog.

macOS remembers that choice for later launches. A future Developer ID-signed and notarized release will remove this one-time step.

To build and verify the installer locally:

```bash
scripts/package-dmg.sh
(cd dist && shasum -a 256 -c usAIge-0.1.10-alpha.dmg.sha256)
```

## Usage data

usAIge starts `codex app-server` locally and uses its documented JSON-RPC methods:

- `initialize`, followed by the `initialized` notification.
- `account/read` to detect the existing account.
- `account/rateLimits/read` for all available rate-limit buckets.
- `account/rateLimits/updated` for live changes.

The app prefers `rateLimitsByLimitId` and falls back to the legacy single `rateLimits` bucket. It reads both the primary and secondary windows for each bucket and never estimates a missing limit.

## Settings

Use the gear button on the panel to open native macOS Settings. Available preferences include:

- Active AI tool visibility.
- Quota visibility and vertical ordering.
- Panel opacity and scale.
- Optional automatic launch when you log in to your Mac.
- Automatic update checks, local new-version notifications, and one-click in-app updates.
- Full-screen app, full-screen video, game, presentation, and screen-sharing hide triggers.

Drag the panel by its background. Its safe position is stored separately for each display. If a display disappears, the panel is clamped onto an available screen the next time it is positioned.

The interface is provider-aware, but OpenAI/Codex remains the only usage provider today because the app reads its local app-server rather than scraping provider websites or copying credentials. Tools without a legitimate usage source are not shown with invented values.

## Updates

The packaged app checks the public usAIge website at launch and every six hours. When a newer build is published, macOS shows a local notification and Settings marks the update button with a red dot. Clicking the notification opens Settings; clicking **Update** downloads the DMG, verifies its SHA-256 checksum, validates the app bundle and code signature, replaces the installed copy, and relaunches usAIge. A manual **Check for Updates** action reports **You’re up to date!** after a successful check when no newer build exists.

## Privacy

- No browser cookies or web pages are read.
- No OpenAI credentials are copied or stored by usAIge.
- No screen pixels are captured or inspected.
- Preferences contain only visual settings, bucket identifiers, and display positions.
- Unsupported or malformed quota buckets are omitted rather than guessed.

## Visibility limitations

macOS does not provide a universal public signal revealing every screen-capture session started by another application. usAIge therefore uses public frontmost-application and window metadata, known presentation/media/conferencing application identifiers, and a general full-screen fallback. Screen sharing that occurs in a background or unrecognized application may not be detected. Each trigger can be disabled in Settings.

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

The automated suite covers quota normalization, JSON-RPC framing, account/rate-limit parsing, state recovery, countdowns, settings persistence, panel geometry, severity thresholds, and visibility-policy precedence.
