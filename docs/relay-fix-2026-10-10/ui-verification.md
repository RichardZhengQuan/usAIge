# Relay UI verification — 2026-10-10

Rendered the final integrated `HUDSettingsView` and actual `SettingsWindowSizing` against remote-main base `8b74aa4` with the relay changes for version 0.2.17. The window retained the latest main content-driven sizing: width 520 points, with each page measured and fitted using `HUDSettingsMetrics`. Saved PNGs exclude the native title bar and use 2× scale. Error and missing-channel views measured 520 × 551 points, loading and verified-empty views 520 × 534 points, and the recovered pairing page 520 × 474 points. No clipped text, overlapping controls, or hidden recovery action was found in the inspected light and dark views.

The fixture preserved the final source's native layout, bundled tool marks, Claude app connection explanation, and accessibility labels. Its synthetic local snapshots and connection statuses provided the same populated local section as the reported screenshot without accessing providers.

The standalone fixture compiled every Swift source under `Sources/UsageHUD` except the app's `UsageHUDApp.swift` entrypoint. It used its own @main and application delegate; the production `AppDelegate` class was never instantiated. A fake login service prevented login-item registration, a disposable defaults suite and temporary credential file isolated settings, and an ephemeral URLSession with URLProtocol intercepted every request. Unknown routes were rejected. No provider account, production relay credential, installed usAIge app, or live backend was used for this UI verification.

## Saved evidence

| State | Evidence | Result |
| --- | --- | --- |
| Transient relay failure | [Dark](error-dark.png), [light](error-light.png) | Shows Couldn’t load remote tools, a plain explanation, and native Retry. It does not claim the tool list is empty. |
| Retry in progress | [Dark](loading-dark.png) | Shows a progress indicator and Loading remote tools. Retry is absent during loading, preventing another click. |
| Successful empty response | [Dark](empty-dark.png) | A simulated 200 response with an empty tools list clears the previous error and shows No remote tools paired. |
| Verified missing saved channel | [Dark](missingchannel-dark.png), [light](missingchannel-light.png) | A simulated JSON 404 with code channel_not_found shows Saved connection is no longer available and native Reconnect. The explanation states that iPhones and AI tools must be paired again. |
| Explicit recovery completed | [Dark](reconnected-pairing-dark.png), [light](reconnected-pairing-light.png) | Clicking Reconnect rechecks the missing channel, creates a fresh fake channel, and opens Connect AI Tool with a fresh fake pairing code. The paired list loads successfully as empty. |

CUA inspected and clicked the actual SwiftUI controls. The Retry accessibility label was Retry loading remote AI tools, with help explaining that it checks paired tools and refreshes their limits. Its resulting native accessibility text was No remote tools paired. The Reconnect accessibility label was Reconnect this Mac to the sync service, with help explaining that phones and tools must pair again. Its resulting native accessibility tree exposed Connect AI Tool, the fresh fake code 222222, Copy Connection Instructions, Create New Code, and No remote tools paired. The native disabled Creating progress action was also inspected during recovery.

Saved bitmap captures were refreshed after changing appearance and compared with direct CUA screenshots of the foreground window. A clean isolated recovery run confirmed the explicit Reconnect click and complete final pairing page. The fixture was quit after each verification scenario and its disposable defaults domain was removed.

## Fixture commands

Build against the final integrated source:

```sh
python3 /private/tmp/gptusage-relay-ui-preview-20261010/build.py /private/tmp/usaige-relay-release-20261010
```

The build script invokes `swiftc -swift-version 6 -parse-as-library`, uses a temporary module cache, includes the actual application Swift files plus `Fixture.swift`, and copies the actual ToolMarks resources into the standalone fixture bundle. Compilation passed; only the two existing deprecated `onChange` warnings in `LegacyCompatibilityViews.swift` were reported.

Launch the ordinary error/Retry scenario:

```sh
/private/tmp/gptusage-relay-ui-preview-20261010/RelayPreview.app/Contents/MacOS/RelayPreview
```

Launch the verified missing-channel/Reconnect scenario:

```sh
/private/tmp/gptusage-relay-ui-preview-20261010/RelayPreview.app/Contents/MacOS/RelayPreview --missing-channel
```

Native GUI execution required an approved run outside the workspace sandbox on this host. Build output and fixture state stayed under `/private/tmp`; the fixture application and credential file were not copied into this evidence directory. These UI results establish rendered behavior with controlled responses. Backend deployment, public endpoint checks, required CI, and installed-client behavior are separate validations.
