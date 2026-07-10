# usAIge

usAIge is a native macOS floating panel for the usage limits exposed by the local Codex app-server. It shows every available quota as a circular meter with percentage remaining and time until reset.

The panel stays above ordinary windows, starts at the bottom-right, remembers its position per display, and avoids both the Dock and menu bar. Users can choose visible quotas, reorder them, and adjust panel size, opacity, and automatic-hide triggers.

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

The development executable runs as an accessory application. Stop it from the launching terminal with Control-C.

## Package the application

```bash
scripts/package-app.sh
open 'dist/usAIge.app'
```

The script creates an ad-hoc signed application at `dist/usAIge.app`. Ad-hoc signing is suitable for local development but is not a substitute for Developer ID signing and notarization for public distribution.

## Usage data

usAIge starts `codex app-server` locally and uses its documented JSON-RPC methods:

- `initialize`, followed by the `initialized` notification.
- `account/read` to detect the existing account.
- `account/rateLimits/read` for all available rate-limit buckets.
- `account/rateLimits/updated` for live changes.

The app prefers `rateLimitsByLimitId` and falls back to the legacy single `rateLimits` bucket. It never estimates a missing limit.

## Settings

Use the gear button on the panel to open native macOS Settings. Available preferences include:

- Quota visibility and vertical ordering.
- Panel opacity and scale.
- Full-screen app, full-screen video, game, presentation, and screen-sharing hide triggers.

Drag the panel by its background. Its safe position is stored separately for each display. If a display disappears, the panel is clamped onto an available screen the next time it is positioned.

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
codesign --verify --deep --strict 'dist/usAIge.app'
```

The automated suite covers quota normalization, JSON-RPC framing, account/rate-limit parsing, state recovery, countdowns, settings persistence, panel geometry, severity thresholds, and visibility-policy precedence.
