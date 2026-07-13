# usAIge Design

## Summary

usAIge is a native macOS companion for the unified OpenAI/Codex account. It displays the usage buckets exposed by the local Codex app-server in a small, configurable panel that floats above ordinary application windows. The panel is fully detailed, avoids the crowded menu bar, and hides automatically during configured full-screen and privacy-sensitive activities.

## Goals

- Keep current OpenAI/Codex quota status visible without switching applications.
- Show both percentage remaining and time until reset for every available quota bucket.
- Use the documented local Codex app-server as the only account and usage source.
- Remain unobtrusive: never steal keyboard focus and consume negligible resources between updates.
- Let users choose which quota rows appear, their order, the panel position, size, opacity, and automatic-hide behavior.

## Non-goals

- Scraping ChatGPT or Codex web interfaces.
- Estimating limits that OpenAI does not expose.
- Reading, copying, or storing OpenAI credentials directly.
- Providing a menu-bar item.
- Displaying API billing or third-party AI-provider usage in the first version.

## Product Experience

The app opens a narrow vertical floating panel at the bottom-right of the primary display. The user can drag it to another location or display. The app remembers a separate position for each connected display and restores the appropriate position after relaunch.

Each visible quota row contains:

- A colored circular progress ring.
- The service-provided quota name, with a safe fallback derived from its bucket identifier.
- The percentage remaining.
- A live countdown to the next reset.

The HUD remains fully detailed rather than collapsing on hover. Users can reorder or hide rows and adjust panel size and opacity. Settings are accessible from a small settings control on the HUD and from the standard application Settings command, without adding a menu-bar extra.

The default ring colors are neutral/accent above 20% remaining, amber at or below 20%, and red at or below 10%. Color is never the only indicator; the numeric percentage remains visible.

## Window and Visibility Behavior

The HUD uses a borderless, non-activating AppKit panel hosting SwiftUI content. It floats above ordinary application windows, joins the user's normal Spaces, does not appear in the Dock as a normal document window, and never becomes key merely because the user is working in another app. Explicit interaction with HUD controls is still supported.

Automatic hiding is enabled by default. The visibility controller evaluates configurable triggers for:

- Full-screen applications.
- Full-screen video playback.
- Games.
- Presentation mode.
- Active screen sharing or screen recording.

Each trigger can be disabled independently. The app restores the HUD when no enabled trigger remains active. Detection should use public macOS state and accessibility/window metadata where available; it must not continuously capture or inspect screen pixels. When a trigger cannot be identified reliably, the general full-screen rule is the fallback. A user-accessible temporary hide command remains available.

## Architectulre

### FloatingHUD

A SwiftUI view hosted by a borderless, non-activating `NSPanel`. It renders quota rows, connection states, settings access, and drag affordances. It depends only on observable view state, not directly on the Codex process.

### UsageProvider

Owns the local Codex app-server subprocess and its JSON-RPC connection. It initializes the server, calls `account/read`, calls `account/rateLimits/read`, and consumes `account/rateLimits/updated` notifications. It exposes normalized events and never exposes raw authentication material to the UI.

The existing Codex-managed ChatGPT account is the sole source of authentication. If no usable account is present, the app directs the user to sign in through Codex rather than implementing a second ChatGPT account flow.

### UsageStore

Normalizes every returned bucket into a `QuotaSnapshot` containing a stable bucket ID, display name, used percentage, remaining percentage, reset timestamp, window duration, plan type when supplied, and update timestamp. Remaining percentage is clamped to 0–100 and calculated as `100 - usedPercent`.

The store publishes snapshots to the UI, updates countdown text from the reset timestamp, and requests a fresh read after a reset boundary, reconnection, system wake, significant clock change, or app-server restart. Live server notifications are preferred over frequent polling.

### VisibilityController

Combines macOS workspace, display, full-screen, presentation, media, game, and capture state into one visible/hidden decision. Each detector is isolated behind a small interface so unavailable or unreliable signals do not break the rest of the policy.

### SettingsStore

Persists visible bucket IDs, their order, panel scale, opacity, per-display positions, warning thresholds, and enabled automatic-hide triggers. Preferences use local macOS application storage and contain no credentials.

## Data Flow

1. The application starts the local Codex app-server and initializes JSON-RPC.
2. `UsageProvider` calls `account/read` to confirm the existing managed account.
3. If authenticated, it calls `account/rateLimits/read`.
4. `UsageStore` converts all entries in `rateLimitsByLimitId`; if the multi-bucket view is absent, it uses the backward-compatible single `rateLimits` bucket.
5. The HUD renders the configured subset in the user's saved order, appending newly discovered buckets after configured buckets.
6. `account/rateLimits/updated` notifications update matching rows immediately.
7. Reset boundaries, wake, clock changes, and reconnection trigger a full refresh.

## States and Error Handling

- **Connecting:** Render neutral placeholder rings with a subtle, non-distracting pulse.
- **Codex unavailable:** Explain that the Codex command/app-server could not be reached and provide Retry and Open Codex actions.
- **Signed out:** Display a single action directing the user to sign in through Codex.
- **Offline or disconnected:** Retain the last successful snapshot, dim it, show its age, and reconnect with bounded exponential backoff.
- **Malformed or partial response:** Ignore invalid buckets, preserve valid ones, and log a privacy-safe diagnostic.
- **Unsupported quota:** Omit it; never invent a value or reset time.
- **Reset boundary:** Refresh rather than assuming the new remaining percentage is 100%.
- **Display removed:** Clamp or move the panel onto the primary display and retain the disconnected display's saved position for its return.
- **No buckets returned:** Show an explanatory empty state rather than an empty panel.

## Privacy and Security

- usAIge communicates only with the local Codex app-server for account usage.
- It does not read browser cookies, scrape web pages, inspect screen pixels, or persist OpenAI tokens.
- Logs exclude email addresses, account identifiers, raw server payloads containing account data, and credentials.
- The screen-sharing auto-hide policy defaults to privacy-preserving behavior.

## Performance

- Use server notifications for usage changes.
- Update countdown labels at the lowest cadence needed by their displayed precision: once per minute when more than one hour remains and once per second during the final minute.
- Suspend unnecessary timers while the HUD is hidden or the display is asleep.
- Avoid continuous screen capture and high-frequency window polling.

## Verification

### Automated tests

- Parse single-bucket and multi-bucket app-server responses.
- Clamp remaining percentages and handle missing optional values.
- Reconcile added, removed, renamed, and reordered quota buckets.
- Calculate countdowns across resets, sleep/wake, time-zone changes, and significant clock changes.
- Exercise connection loss, malformed responses, reconnection backoff, and stale-data presentation.
- Validate settings migration and per-display position restoration.
- Test visibility-policy precedence and independent trigger overrides.

### macOS integration tests

- Confirm the panel does not steal focus while typing in another app.
- Confirm panel level and Space behavior across normal windows and multiple displays.
- Confirm positions remain on-screen after display rearrangement or removal.
- Confirm settings changes update the HUD immediately.

### Manual acceptance checks

- Compare every displayed bucket, percentage, and reset time with the Codex app.
- Verify hiding and restoration with Safari or another browser playing full-screen video, QuickTime, Keynote presentation mode, macOS screen sharing or recording, and representative full-screen games.
- Verify relaunch, offline recovery, Codex restart, sign-out, system sleep/wake, and monitor connection changes.
- Confirm idle CPU use remains negligible and no continuous screen inspection occurs.

## Version-One Acceptance Criteria

- All rate-limit buckets exposed by the Codex app-server can be displayed.
- Every row shows a label, percentage remaining, and reset countdown when the source provides the necessary values.
- Users can show, hide, and reorder rows; move the HUD; and change its size and opacity.
- The panel defaults to the bottom-right and remembers a safe per-display position.
- The panel remains above ordinary windows without disrupting keyboard focus.
- Configured full-screen and privacy triggers hide the panel and restore it afterward.
- Stale or unavailable data is clearly distinguished from current data.
- No browser scraping, quota estimation, or direct credential storage is used.

## Alpha Distribution

The public alpha is distributed as a compressed macOS disk image named `usAIge-0.1.5-alpha.dmg`. Opening the image presents `usAIge.app` and an `Applications` shortcut so users can install it with the standard drag-to-Applications interaction.

The release pipeline must build the release executable from source, assemble the `.app`, create the disk image, mount it read-only, verify the bundled executable and Applications shortcut, validate the property list and ad-hoc signature, and generate a SHA-256 checksum. The disk image and checksum are published together on a prerelease GitHub Release.

This alpha remains ad-hoc signed because the available keychain contains no Developer ID Application identity. The release notes and README must explain that users need to Control-click the installed app, choose Open, and confirm the first launch. Warning-free public installation is deferred until a Developer ID certificate and Apple notarization credentials are available.
