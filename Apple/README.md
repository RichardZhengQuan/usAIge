# usAIge for Apple Watch

This project adds a native watchOS app and WidgetKit complications to usAIge's iPhone app. The Mac remains the trusted source. Apple Watch normally receives credential-free quota snapshots from the iPhone, and a cellular or Wi-Fi Watch can fetch the same normalized snapshots directly from the usAIge relay when the iPhone is unavailable.

## What is included

- `usAIge-iOS`: the iPhone and iPad app for pairing with a Mac using a one-use code. Its device-scoped relay token stays in the iPhone Keychain.
- `usAIgeWatch`: inspect limits grouped by connected Mac and AI tool, see primary and secondary windows, and refresh through the iPhone or directly through the usAIge relay.
- `usAIgeWatchWidget`: watch-face complications for circular, rectangular, inline, and corner families.
- `WatchUsageSnapshot`: a small, versioned, credential-free transfer contract shared by the iOS app, Watch app, and Watch widget.

The macOS app, iPhone, Watch app, and complication use the same quota severity language: blue above 60% remaining, green from 41–60%, orange from 21–40%, red from 11–20%, and deep red at 10% or below. Critical Watch rings use the same warning glow and pulse as macOS; with Reduce Motion enabled, the warning remains visible without animation. At 0%, the ring becomes a complete warning ring rather than disappearing. Compact duration tags such as `5H` and `7D` keep them readable on small screens.

The complication displays the most constrained quota window, so the limit most likely to need attention is visible at a glance.

## Requirements

- Xcode 26 or later.
- iOS 26 or later.
- watchOS 10 or later.
- An Apple Developer team and the existing `group.com.richardq.usaige` App Group enabled for installation on physical devices.

The generated Xcode project is committed at `Apple/usAIgeApple.xcodeproj`. Its reproducible XcodeGen source is `Apple/project.yml`.

## Build

From the repository root:

```bash
swift test

xcodebuild \
  -project Apple/usAIgeApple.xcodeproj \
  -target usAIge-iOS \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Apple/usAIgeApple.xcodeproj \
  -target usAIgeWatch \
  -sdk watchsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Before a device build, select the same Apple Developer team for the iOS app, iOS widget, Watch app, and Watch widget. Register the bundle identifiers from `project.yml` and enable the App Group on all four targets.

Running a paired simulator scheme also requires matching iOS and watchOS simulator runtimes installed in Xcode.

An unsigned Watch build verifies compilation only. Because App Group entitlements are not available when `CODE_SIGNING_ALLOWED=NO`, the Watch app and complication cannot share their snapshot in that configuration. Use a signed scheme or device build when validating live complication data.

## Pair with a Mac

1. On the Mac, open **usAIge Settings → iPhone & Apple Watch Sync** and create a connection.
2. Open the iPhone Connection tab and enter the 8-digit code.
3. The iPhone fetches the latest sanitized Mac snapshot and forwards it to Apple Watch.
4. While the Watch is reachable, the iPhone also provisions a separate Watch-scoped read credential for each connected Mac. The Watch keeps those credentials in its private Keychain for direct cellular or Wi-Fi refreshes.

The iPhone token and provider credentials never enter the Watch. Only separate `usg_watch_` read credentials are provisioned to the Watch, and those never enter the App Group snapshot file. The widget extension has no credential access and performs no authenticated network request.

## Add usAIge to a watch face

1. Install and open the watch app once so it can receive its first snapshot.
2. Touch and hold the current watch face, choose **Edit**, then move to **Complications**.
3. Select a complication slot and choose **usAIge — AI limits**.

You can also configure the complication from the Watch app on the paired iPhone.

## Remote quota API

The endpoint must use HTTPS, respond to `GET`, return a successful HTTP status and JSON content type, and implement schema version 1. When a token is configured, usAIge sends it as `Authorization: Bearer <token>`.

Minimal response:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-14T14:00:00Z",
  "limits": [
    {
      "id": "five-hour",
      "name": "5 hour",
      "usedPercent": 42,
      "windowDurationSeconds": 18000,
      "resetAt": "2026-07-14T18:00:00Z"
    }
  ]
}
```

Nested primary and secondary windows are supported:

```json
{
  "schemaVersion": 1,
  "generatedAt": 1784047200,
  "tool": {
    "name": "Claude Team"
  },
  "limits": [
    {
      "id": "messages",
      "name": "Messages",
      "planType": "team",
      "primary": {
        "remainingPercent": 58,
        "windowDurationMinutes": 300,
        "resetsAt": 1784065200
      },
      "secondary": {
        "usedPercent": 71,
        "windowDurationSeconds": 604800,
        "resetAt": "2026-07-19T00:00:00Z"
      }
    }
  ]
}
```

Contract rules:

- Dates may be ISO 8601 strings or Unix timestamps in seconds.
- A window may provide `usedPercent` or `remainingPercent`. If both are present, they must add up to 100 after clamping.
- Flat primary-window fields and a nested `primary` object cannot be mixed in the same limit.
- Limit IDs must be unique and use letters, numbers, period, underscore, or hyphen.
- At most 64 limits are accepted. Unsupported schemas, oversized responses, duplicate IDs, malformed dates, and insecure endpoints are rejected.
- Responses larger than 256 KiB are rejected.
- Endpoint credentials in the URL itself are rejected; use the optional bearer token field.

Vendor web pages are not scraped. A vendor adapter or private relay should translate a provider-specific API into this small normalized contract.

## Refresh behavior

Opening the watch app requests a live refresh from the iPhone when it is reachable. Otherwise, a Watch with previously provisioned credentials uses its own cellular or Wi-Fi connection to fetch each Mac's latest normalized snapshot from the usAIge relay. Successful refreshes replace the Watch cache and ask WidgetKit to reload the complication.

WidgetKit complications are not continuously running processes. Timeline reloads are best-effort and scheduled by watchOS. The complication refreshes after sync, around a known reset time, and on a periodic timeline; it marks snapshots older than 30 minutes as potentially stale. Guaranteed second-by-second remote quota updates would require a provider-backed push service and are outside this local-first version.

## Regenerate the Xcode project

If XcodeGen is installed:

```bash
xcodegen generate --spec Apple/project.yml --project Apple
```

Always commit `project.yml`, generated plist/entitlement files, and the updated `.xcodeproj` together.
