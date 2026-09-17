# Contributing to usAIge

usAIge is a small native codebase: a Swift package for the macOS app in
`Sources/UsageHUD`, Xcode projects for the iPhone, iPad, and Apple Watch
clients in `usAIge-iOS.xcodeproj` and `Apple/`, and the relay and website in
`site/`. Bug reports, questions, and pull requests are welcome on
[GitHub](https://github.com/RichardZhengQuan/usAIge).

## Setting up

- macOS app: Xcode 26 (`Package.swift` needs swift-tools 6.2) on an
  Apple-silicon Mac. The README's **Build and run macOS** section covers
  running from source, and **Package the application** covers building an
  ad-hoc signed `dist/usAIge.app`.
- iPhone, iPad, and Apple Watch: Xcode 26. The committed projects reference the
  maintainer's Apple Developer team and the `group.com.richardq.usaige` App
  Group, so for device builds set your own `DEVELOPMENT_TEAM` and App Group
  identifier in the Xcode project, or in `Apple/project.yml` and regenerate
  with XcodeGen. Simulator builds need neither.
- Relay and website: Node.js 22 or later, then `npm ci` inside `site/`.

## Building and testing

The macOS suite:

```bash
swift build --build-tests
swift test --skip-build
```

The relay:

```bash
cd site && npm ci && node --experimental-strip-types --test tests/relay-contract.test.mjs && npm run lint
```

CI runs exactly these on every push to `main` and every pull request, so a
green local run is a green pull request. The README's **Verification** section
lists the opt-in live tests that exercise the real sign-ins on your Mac; they
print only normalized limits.

## Sending a change

1. Branch from `main` and keep the change focused on one thing.
2. Add or update tests beside the code you touch: `Tests/UsageHUDTests` for
   macOS, `iOS/Tests` for the iPhone app, `site/tests` for the relay.
3. Open a pull request that says what changed, why, and what you ran to verify
   it. CI must pass before it is merged.

## Boundaries to keep

usAIge earns its place on a Mac by being safe with other tools' sign-ins. Any
change must keep these properties, and a change that needs to cross one of
them should start as an issue rather than a pull request:

- Provider credentials are read into memory only to request that provider's
  current limits. They are never written to disk, logged, refreshed, rotated,
  or sent to the relay.
- Paired iPhones and Watches receive normalized percentages, reset times, and
  session status only.
- Values the provider does not report are omitted, not guessed.
- No browser cookies, web pages, or screen pixels are read.

## Releases

Releases are cut by the maintainer with `scripts/package-dmg.sh`. The
manifest at `site/public/update.json` is signed with an Ed25519 key that is
not in this repository, and the app only installs manifests signed by the key
pinned in `UpdateSigning.pinnedPublicKeyBase64`. A fork that ships its own
in-app updates must generate its own key with
`scripts/generate-update-signing-key.swift` and pin its public half.
