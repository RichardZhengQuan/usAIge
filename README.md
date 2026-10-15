# usAIge

usAIge has native clients for macOS, iPhone, iPad, and Apple Watch. The Mac is
the trusted limit collector: it reads the local Codex app-server, Claude
desktop usage data, Cursor and Grok Build sign-ins already on the Mac, and paired remote
tools, then relays only normalized percentages and reset times to paired
iPhones.

## Roadmap

Product development follows three stages: establish the macOS MVP, extend the
experience to iPhone and Apple Watch, and then expand support for additional AI
tools. See [`docs/roadmap.md`](docs/roadmap.md) for the scope and boundaries of
each stage.

## Built with Codex and GPT-5.6

Codex powered by GPT-5.6 was the primary engineering collaborator used to turn
usAIge from a product idea into a working multi-platform system. The human
owner set the product direction, privacy boundaries, and final UX decisions;
Codex and GPT-5.6 helped execute and verify the implementation across the
Swift, SwiftUI, AppKit, WidgetKit, WatchConnectivity, and relay-server codebases.

In practice, Codex and GPT-5.6 were used to:

- Explore the repository, translate product requirements into implementation
  plans, and make coordinated changes across macOS, iOS, iPadOS, watchOS,
  widgets, and the web relay.
- Build the local Codex app-server JSON-RPC integration, including account and
  rate-limit reads, live `account/rateLimits/updated` events, multi-window quota
  normalization, reconnect behavior, and privacy-safe error handling.
- Design and implement the account-free Mac-to-iPhone pairing flow, revocable
  device credentials, normalized snapshot relay, session-status notifications,
  widgets, WatchConnectivity sync, and Apple Watch complications.
- Iterate on native Apple UX from feedback: the floating macOS usage rail,
  Settings flows, quota severity states, connection guidance, iPhone activity
  views, widgets, and Watch layouts.
- Generate and expand automated tests, diagnose build and concurrency failures,
  review diffs for regressions, package releases, and verify behavior with
  command-line builds and simulator/device-oriented checks.

This was not a one-shot code generation exercise. Development used an iterative
agentic loop: inspect the existing architecture, implement a focused change,
run the relevant tests and builds, review the result, fix failures, and repeat.
The commit and pull-request history preserves that progression.

## iOS app and widget

Open `usAIge-iOS.xcodeproj` in Xcode 26. The project contains:

- A native tab-based iPhone and iPad app with Usage, Activities, Connection,
  and Settings sections.
- Account-free pairing with an 8-digit, one-use code shown by the Mac.
- A device-scoped relay token stored in the iOS Keychain.
- An App Group JSON cache containing quota values only, never tokens.
- Small, medium, and large widgets backed by the shared cache.
- Immediate foreground and pull-to-refresh updates plus APNs-assisted,
  best-effort background refresh scheduling.
- Finished-session, error, and permission-request alerts are enabled by default
  and controlled through iPhone notification permissions. A locally cached
  Activities inbox remains available, and selecting an alert focuses the
  matching event.
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
  cookies, prompts, or account content.
- For session notification delivery, the relay retains at most the latest
  100 status events per Mac, and none older than seven days: event type, session title, workspace name, and
  timestamp. Disconnecting the Mac deletes that history with the channel.

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

usAIge is a native macOS floating AI usage rail. It shows real usage limits from the local Codex app-server, from local Claude desktop usage data and the Cursor and Grok Build sign-ins already on this Mac, and from remote AI tools you explicitly configure. When a limit has two windows, the inner ring shows its primary window and the outer ring shows its secondary window.

macOS can notify you whenever a primary or secondary usage window crosses a new 5% used boundary. Selecting the notification brings the live limits rail forward.

The panel stays above ordinary windows, starts at the bottom-right, and remembers its position per display. Hover over any row to reveal its usage name, remaining percentage, localized reset date, and plan details. Clicking a tool logo opens its installed app or web experience.

While idle, the panel surface is fully transparent and every visible control is shown at half its configured opacity. Hovering anywhere over the rail restores the surface and full configured opacity.

## macOS requirements

- macOS 11 or later on an Apple-silicon Mac.
- Swift 6.2 and Xcode 26 for source builds.
- For local Codex limits: the ChatGPT or Codex macOS app, or a `codex` executable on `PATH`, with an existing Codex-managed ChatGPT sign-in.
- For Claude limits: the Claude desktop app with its existing sign-in, installed before or after usAIge. No setup, extension, or Claude Code session is required: once Claude has recorded a usage reading, usAIge keeps it current by asking Claude to reload its own Usage page. The optional usage extension can also refresh from an idle Claude Code session. usAIge never offers sign-in or reads Claude's passwords, keys, tokens, or cookies.
- For Cursor limits: the Cursor app installed and signed in on this Mac.
- For Grok Build limits: the Grok Build CLI signed in with `grok login`.
- For remote limits: a compatible adapter that can claim a one-time usAIge pairing code and upload normalized limits.

Each tool's ring also breathes while that tool has an agent session running, turns green when a session finishes, amber when one is waiting on you (for Claude Code, a question or a plan awaiting approval; permission prompts leave no record on disk), and pink on an error; clicking the ring opens the tool and settles the light. The signals are read locally: Codex through its app-server, Claude Code from the record types at the end of its session transcripts in `~/.claude` (never the text), Cursor from the conversation status fields in its own state database, and Grok Build from its unified log. Paired iPhones and the Watch show the same per-tool session status.

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

Download `usAIge-0.2.22-alpha.dmg` and its checksum from the website. Open the disk image, then drag `usAIge.app` onto the Applications shortcut.

Version 0.2.22 detects Claude usage automatically in either installation order and keeps refreshing when Claude pauses its own polling. Open Claude and complete its normal account setup; usAIge needs no extra sign-in, Keychain access, Detect, or manual configuration. Automatic recovery can bring Claude’s Usage page to the front.

This alpha is ad-hoc signed and is not notarized because the project does not yet have a Developer ID Application certificate. On first launch:

1. Open the Applications folder.
2. Control-click `usAIge` and choose **Open**.
3. Click **Open** in the confirmation dialog.

macOS remembers that choice for later launches. A future Developer ID-signed and notarized release will remove this one-time step.

To build and verify the installer locally:

```bash
scripts/package-dmg.sh
(cd dist && shasum -a 256 -c usAIge-0.2.22-alpha.dmg.sha256)
```

For headless packaging, reuse the layout from a trusted previous installer:

```bash
scripts/package-dmg.sh --headless --template /absolute/path/to/trusted-previous.dmg
```

The packager preserves executable permissions and checks the app inside the compressed DMG. Before publication, copy that app into a temporary Applications folder and verify that it launches; matching checksums and a valid code signature alone do not establish that it can launch.

## Usage data

### Local Codex

usAIge starts `codex app-server` locally and uses its documented JSON-RPC methods:

- `initialize`, followed by the `initialized` notification.
- `account/read` to detect the existing account.
- `account/rateLimits/read` for all available rate-limit buckets.
- `account/rateLimits/updated` for live changes.

The app prefers `rateLimitsByLimitId` and falls back to the legacy single `rateLimits` bucket. It reads both the primary and secondary windows for each bucket and never estimates a missing limit.

### Local Claude, Cursor, and Grok Build

Claude usage comes from the local usage extension report, desktop history,
or validated HTTP-cache responses. usAIge reads those files automatically;
it never reads a Claude password key, Keychain item, OAuth token, or cookie
store, and makes no authenticated Claude usage request.

The included [Claude usage extension](Integrations/ClaudeUsageBridge/README.md)
runs inside a Claude Code subscription session. Claude supplies an opaque
authorization handle and performs its own first-party usage requests. The
extension refreshes at session start and every five minutes while idle,
independently of Desktop's tray polling. Only filtered usage figures, reset
timestamps, organization identity, and collector status are written to
`~/Library/Application Support/usAIge/claude-usage/`. Failed requests retain
their previous observation time, and account switches invalidate old reports.
The host session's engine must remain running; its timer stops if Claude
ends or evicts that engine. usAIge expires old reports rather than treating
them as fresh after the collector stops.

Claude usage refreshes automatically, whichever app was installed first. Every
30 seconds, while Claude is open and visible in the usAIge rail, one check
chooses at most one route:

1. For an established collector with automatic reopening enabled, usAIge
   checks Claude's local lifecycle log for that exact session. An idle timeout
   or memory eviction reopens its existing session through Claude's normal
   continuation link. Recovery honors the collector's retry deadline, does not
   reopen after a later explicit stop, and attempts each pause once, with at
   least 15 minutes between attempts, including across usAIge restarts.
2. Otherwise, when Claude has recorded a reading for its signed-in
   organization and no reading is newer than 6.5 minutes, usAIge opens
   Claude's public `claude://claude.ai/settings/usage` link. Claude reloads its
   own Usage page with its own session, and usAIge reads the validated cache
   response on its next tick. The page waits for a collector's rate-limit or
   in-progress retry deadline. A Code session without a subscription, or one
   whose requests keep failing, does not hold it back. Without a newer
   reading, the page is retried at most every 15 minutes.

Either route can bring Claude to the front. After either one opens, both wait
at least 90 seconds, including across usAIge restarts, so the reopened
session and the Usage page never compete. If a reopened collector writes a
new status during that time, the page also waits for its retry deadline.
usAIge never launches Claude, signs in, or opens anything while Claude is
hidden in the rail. Before Claude records its first reading, usAIge waits for
one. An incomplete status file defers both routes until its retry deadline can
be read safely.

Cursor and Grok Build reuse the sign-ins their own clients already store on
this Mac. usAIge holds those credentials in memory only for usage requests;
it never writes, logs, relays, refreshes, or rotates them.

| Tool | Sign-in read | Usage source | Buckets |
| --- | --- | --- | --- |
| Claude app (local) | None | Usage-extension report, `~/Library/Application Support/Claude/plan-usage-history.json`, and validated native usage-cache responses | **All models** (5-hour inner ring, 7-day outer ring), with exact reported reset times and any reported model-scoped limits |
| Cursor | `cursorAuth/accessToken` in Cursor's own state store | `api2.cursor.sh` `DashboardService/GetCurrentPeriodUsage`, the request the editor makes for Plan & Usage | **Cursor models** and **Other models** for the current billing cycle, or the blended included-usage percentage when the split is not reported |
| Grok Build | `~/.grok/auth.json` (or `$GROK_HOME/auth.json`) | `grok.com` credits configuration and task usage, the requests Grok Build makes for its own usage view | Included credits for the current cycle, plus task limits when the account reports them |

Cursor's plan label comes from its live `auth/full_stripe_profile` account
endpoint on each usage refresh, because the editor's locally cached membership
can remain unchanged after cancellation. If that lookup is unavailable, usAIge
omits the plan label while still showing the current usage.

Claude local files are checked every five seconds, including while other
providers are waiting on a network retry. Cursor and Grok Build poll their
account endpoints every two minutes,
with automatic back-off after any failure and a longer pause after an HTTP
429. A manual refresh may run sooner but never faster than a per-tool floor. A
source that is waiting on something, such as a slow network request, never
holds up the others; the rail keeps showing the
last known values and picks up the answer on the next cycle.
The endpoints are the ones each vendor's own client uses; they are not
publicly documented contracts, so a provider change can pause a tool until
usAIge is updated. When that happens the rail keeps the last accepted values
and marks them stale rather than inventing numbers.

usAIge checks Desktop's local HTTP cache for a validated usage response
for the most recently recorded organization. The response must be under
30 minutes old. Its server percentages and reset timestamps can advance an
older history observation for that same organization; stale history numbers
are never substituted for a current response. Future, conflicting,
unsupported, expired, or incomplete responses are ignored. Without an accepted
cache response, recent desktop history supplies percentages without reset times.

**AI Tools** says **Connected · Claude app cache on this Mac** when that
validated cache supplies limits. History-only readings have no reset times:
their recording time is not a quota reset time. usAIge never estimates a
reset from usage drops or fixed window lengths. When no accepted source
reports a reset, the countdown shows **—** and the status says **Reset times
unavailable**. Keep Claude open so it can refresh its own usage data.
No sign-in or **Detect** action is required. usAIge picks up new local readings
on its next automatic tick and retries when no current data is available.
With the extension loaded, **AI Tools** says **Connected · Refreshing
automatically through Claude**. Its timer continues when Desktop pauses its
normal usage poller. Without an active extension session, usAIge asks Claude
to reload its Usage page when the native reading goes stale, as described
above. usAIge itself never sends a usage request. Missing or expired data
remains unavailable.

If Claude Code uses an API key helper, the desktop app still supplies the
Claude plan readings; usAIge does not access that helper or its credentials.

Grok Build's sign-in is a six-hour token that only its CLI renews. When it has
expired, usAIge runs `grok models` without a terminal so the CLI refreshes its
own auth file, at most once every ten minutes, and never touches the refresh
token itself.

Claude reports several weekly buckets. The rail shows **All models** by
default and keeps the others available under **AI Tools**, mirroring
how the Codex buckets are handled. A weekly limit scoped to one model (Claude
lists it as, for example, **Fable**) is often the one that actually gates a
heavy session, so turn that bucket on if you want the rail to warn about it.

### Remote AI tools

Connect a remote source from **Settings**:

1. Open **AI Tools → Connect AI Tool**.
2. Click **Create Connection** to generate an 8-digit, one-use code.
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

- Active AI tool visibility, and the rail order of tools by dragging them, or with **Move Up** and **Move Down** in a row's Control-click menu, in **AI Tools**.
- Quota visibility and vertical ordering within a tool.
- Connecting remote AI tools with one-time pairing codes and per-tool revocation.
- Panel opacity and scale.
- Optional automatic launch when you log in to your Mac.
- Automatic update checks, local new-version notifications, and one-click in-app updates.
- A native, account-free feedback form that records the message and basic app/system context on the usAIge server.
- Local usage-limit notifications at each new 5% used boundary.
- Always-visible behavior while usAIge is running, including after sleep and wake.

Drag the panel by its background. Its safe position is stored separately for each display. If a display disappears, the panel is clamped onto an available screen the next time it is positioned.

The built-in Codex, Cursor, and Grok Build sources reuse existing sign-ins, while Claude reads only local usage data; **AI Tools** shows each one's connection state. Other tools appear only after a paired adapter uploads valid normalized usage data; usAIge does not scrape provider websites or invent missing values.

## Updates

The packaged app checks the public usAIge website at launch and every six hours. When a newer build is published, macOS shows a local notification and Settings marks the update button with a red dot. Clicking the notification opens Settings; clicking **Update** downloads the DMG, verifies its SHA-256 checksum, validates the app bundle and code signature, replaces the installed copy, and relaunches usAIge. If the replacement fails, the previous copy is put back and relaunched. When the installed app carries a Developer ID team, the replacement must be signed by the same team. The manifest carries an Ed25519 signature from the release key: `scripts/generate-update-signing-key.swift` created the key once on the release Mac (keep `~/.config/usaige/update-signing-key` backed up; losing it breaks in-app updates), `scripts/package-dmg.sh` signs `update.json` with it on every release, and the public key pinned in `UpdateSigning.pinnedPublicKeyBase64` makes the app refuse unsigned or tampered manifests, so a compromised download host cannot push a different build. A manual **Check for Updates** action reports **You’re up to date!** after a successful check when no newer build exists.

## Magnet

Drop the rail within about 32 points of the left or right edge of a display and it snaps flush to that edge and stays docked there, per display, across relaunches. A docked rail slides off screen a moment after your pointer leaves it, leaving a two-point sliver, and slides back when the pointer pushes against that edge, the way the Dock does. Drag it away from the edge to undock it. **Magnet** in Settings turns the behaviour off, which releases a docked rail where it sits.

## Usage-limit notifications

After the first successful usage read, usAIge asks for macOS notification permission. The first value for each limit establishes a quiet baseline; it does not generate catch-up alerts. Later live updates notify at newly crossed 5% used boundaries for primary and secondary windows independently. If one update skips several boundaries, usAIge sends one notification for the newest boundary instead of a burst.

When a quota resets, the new window starts its own notification cycle. Selecting a usage notification or its **View Limits** action reveals the floating limits rail. Denying notification permission does not affect live values in the rail.

## macOS privacy

- No browser cookies, cookie stores, or web pages are read. For Claude, usAIge reads filtered extension reports, `plan-usage-history.json`, and validated local usage-cache responses, never its sign-in, OAuth tokens, or Keychain item. When automatic reopening is configured, it also checks a bounded tail of Claude's local log for the collector's exact lifecycle markers without retaining log lines. Claude itself performs the extension's first-party usage requests with a host-owned opaque handle. When a reading is stale, usAIge only opens Claude's public Usage-page link; Claude loads the page with its own session, and usAIge reads no page content.
- No provider credentials are copied or stored by usAIge. The Cursor and Grok Build sign-ins already on this Mac are read into memory only to request each provider's current limits, and are never written to disk, logged, refreshed, or relayed.
- The Mac relay credential is stored in an owner-only local application-support file. Each remote tool keeps its own write credential outside usAIge.
- No screen pixels are captured or inspected.
- Preferences contain visual settings, bucket identifiers, and display positions; they do not contain remote-tool bearer tokens.
- Feedback is sent only when you press **Send Feedback** and contains the message plus the disclosed app/system context. The server keeps it for 180 days.
- Unsupported or malformed quota buckets are omitted rather than guessed.

## Visibility

The floating panel remains visible while usAIge is running, including across Spaces, full-screen apps, and sleep/wake. Use **Quit usAIge** in Settings to remove it.

## Troubleshooting

### “Open Codex to connect”

Start the ChatGPT or Codex app, confirm that it is signed in, then press the refresh button. The app searches these locations, in `/Applications` and then `~/Applications`, before checking `PATH`:

- `ChatGPT.app/Contents/Resources/codex-cli` (the entry point its `codex-package.json` names, normally `bin/codex`)
- `ChatGPT.app/Contents/Resources/codex` (older app builds)
- the same two paths inside `Codex.app`
- `/opt/homebrew/bin/codex`
- `/usr/local/bin/codex`

### Claude, Cursor, or Grok Build is missing from the rail

Open **Settings → AI Tools**. The **Local AI Tools** list shows
each tool's state. Claude usage is checked automatically without a sign-in or
**Detect** action. Cursor may need its own sign-in refreshed; Grok Build uses
`grok login`. A provider failure keeps the last accepted values while usAIge
retries.

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

The automated suite covers quota normalization, JSON-RPC framing, account/rate-limit parsing, Claude Code, Cursor, and Grok Build decoding and throttling, one-time remote pairing payloads, state recovery, countdowns, notification thresholds and routing, settings persistence, panel geometry, and severity thresholds.

Opt-in smoke tests exercise local usage sources on this Mac and print only normalized limits:

```bash
USAIGE_LIVE_LOCAL_TOOLS=1 swift test --filter LiveLocalTools
```

Add `USAIGE_LIVE_CLAUDE=1` to include Claude's local usage files. A separate
cache smoke test verifies real reset timestamps with credential and network
dependencies explicitly blocked:

```bash
USAIGE_LIVE_CLAUDE_CACHE=1 swift test --filter ClaudeLocalCacheLive
```

## TODO

- Add the usAIge website link to Settings.
- Tune the main HUD glass-board opacity while the HUD is hovered.

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/RichardZhengQuan/usAIge).
[`CONTRIBUTING.md`](CONTRIBUTING.md) covers how to build, test, and send a
change, and [`SECURITY.md`](SECURITY.md) explains how to report a
vulnerability privately.

## License

usAIge is open source under the [MIT License](LICENSE). Codex, ChatGPT,
Claude, Cursor, and Grok are trademarks of their respective owners; their names
and marks in this repository identify the tools usAIge reads and are not
covered by that license.
