# usAIge for Apple Watch

This project adds a native watchOS app and WidgetKit complications to usAIge's iPhone app. The Mac remains the trusted source and the iPhone receives normalized relay snapshots; Apple Watch receives only credential-free quota snapshots from the iPhone.

## What is included

- `usAIge-iOS`: the iPhone and iPad app for pairing with a Mac using a one-use code. Its device-scoped relay token stays in the iPhone Keychain.
- `usAIgeWatch`: inspect every synced tool and quota, see primary and secondary windows, and request an immediate refresh from a reachable iPhone.
- `usAIgeWatchWidget`: watch-face complications for circular, rectangular, inline, and corner families.
- `WatchUsageSnapshot`: a small, versioned, credential-free transfer contract shared by the iOS app, Watch app, and Watch widget.

The iPhone, Watch app, and complication share the macOS app's concentric quota language: cyan for a normal primary window, purple for a normal secondary window, orange at 20% remaining, and red at 10%. Compact duration tags such as `5H` and `7D` keep both windows readable on small screens.

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

## Pair with a Mac

1. On the Mac, open **usAIge Settings → iPhone & Apple Watch Sync** and create a connection.
2. Open the iPhone Connection tab and enter the 8-character code.
3. The iPhone fetches the latest sanitized Mac snapshot and forwards it to Apple Watch.

Tokens never enter the WatchConnectivity payload or App Group snapshot file. The widget extension has no credential access and performs no authenticated network request.

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

Opening the watch app can request a live refresh while the iPhone is reachable. Successful iPhone refreshes also replace the watch cache and ask WidgetKit to reload the complication.

WidgetKit complications are not continuously running processes. Timeline reloads are best-effort and scheduled by watchOS. The complication refreshes after sync, around a known reset time, and on a periodic timeline; it marks snapshots older than 30 minutes as potentially stale. Guaranteed second-by-second remote quota updates would require a provider-backed push service and are outside this local-first version.

## Regenerate the Xcode project

If XcodeGen is installed:

```bash
xcodegen generate --spec Apple/project.yml --project Apple
```

Always commit `project.yml`, generated plist/entitlement files, and the updated `.xcodeproj` together.
