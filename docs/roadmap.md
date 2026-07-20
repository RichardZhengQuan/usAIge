# Product roadmap

usAIge is being developed in three stages. Each stage builds on the product and
privacy boundaries established by the previous one.

## 1. macOS MVP

Establish the Mac as the trusted usage collector and deliver a dependable,
always-visible AI usage experience.

- Show live Codex limits and reset times in the floating macOS rail.
- Make critical quota states, stale data, connection failures, and agent status
  immediately understandable.
- Provide reliable refresh, notifications, settings, recovery, and release
  behavior before broadening the product surface.

## 2. iPhone and Apple Watch

Extend the Mac-collected experience across the Apple ecosystem without moving
provider credentials off the source machine.

- Relay the latest normalized limits from Mac through the usAIge service to
  independently paired and revocable iPhones.
- Support native iPhone and iPad views, widgets, background-refresh assistance,
  activity notifications, Apple Watch views, and complications.
- Preserve the latest available snapshot with an honest update age instead of
  promising continuous real-time background delivery.

## 3. Support more AI tools

Expand beyond the built-in Codex source through the existing paired-adapter
model.

- Prioritize the tools that matter most to usAIge users instead of competing on
  provider count alone.
- Use official provider APIs or documented local commands for machine-readable
  limits.
- Keep provider credentials and provider-specific logic with the adapter; send
  only normalized display metadata, remaining percentages, and reset times to
  usAIge.
- Do not scrape provider websites, reuse browser sessions, or invent values a
  provider does not expose.

The product sequence is therefore: **macOS MVP -> iPhone and Apple Watch ->
more AI tools**.
