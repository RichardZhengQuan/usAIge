# Security policy

usAIge reads the Codex, Claude Code, Cursor, and Grok Build sign-ins that are
already on a Mac and relays normalized usage to paired iPhones and Apple
Watches. A bug that leaks, stores, logs, or relays one of those credentials is
a security issue. So is anything that lets a tampered update manifest, disk
image, or relay payload reach the app.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Report it privately
through GitHub's private vulnerability reporting for this repository:

https://github.com/RichardZhengQuan/usAIge/security/advisories/new

Include the affected version or commit, the platform, steps to reproduce, and
what an attacker could gain. The maintainer replies through the advisory and
coordinates the fix and disclosure there.

## Fixes and supported versions

usAIge is a public alpha. Fixes ship in the next release rather than as
patches to older builds, and the macOS app's in-app updater installs that
release. The latest build is always the one on the
[releases page](https://github.com/RichardZhengQuan/usAIge/releases).

## What is already in place

- Provider sign-ins are read into memory only to request each provider's
  current limits. They are never written to disk, logged, refreshed, or sent to
  the relay.
- Paired iPhones and Watches receive percentages and reset times, never bearer
  tokens.
- `update.json` carries an Ed25519 signature from a release key that is not in
  this repository, and each disk image is pinned by SHA-256 and checked for a
  valid code signature before it replaces the installed app.

Any way around one of those boundaries is in scope.
