# Claude usage bridge

This optional local usAIge mod runs in an existing Claude Code subscription
session. usAIge does not need it on first run: whichever app is installed first,
once Claude Desktop has recorded a usage reading, usAIge refreshes stale readings
by opening Claude's public `claude://claude.ai/settings/usage` link. When a
current report from this mod is available, that page stays closed.
Claude Code owns authentication and supplies an opaque authorization handle;
the bridge does not read passwords, keys, credentials, cookies, or settings.
It makes no model requests and adds no prompts or commands.

The collector refreshes immediately on session start, checks every 30 seconds
while the session stays open, and fetches at most every five minutes after a
successful refresh. Failed requests retry after two minutes. A 429 waits at
least 15 minutes and honors a longer `Retry-After`. Background ticks run
between Claude turns, independently of Claude Desktop's normal plan poller.

Each refresh binds the organization from Claude's profile before fetching
usage. Only usage windows and extra-usage figures are shared with usAIge:

```json
{
  "schemaVersion": 1,
  "observedAt": "2026-10-14T00:00:00.000Z",
  "organizationID": "00000000-0000-0000-0000-000000000000",
  "usage": {
    "five_hour": { "utilization": 12, "resets_at": "2026-10-14T02:00:00Z" },
    "seven_day": { "utilization": 34, "resets_at": "2026-10-20T00:00:00Z" }
  }
}
```

The response is written to
`~/Library/Application Support/usAIge/claude-usage/response.json`.
`status.json` beside it records fixed error reasons and retry times. Failed
refreshes never rewrite the last response or advance its observation time.
Once an attempt binds an organization, its status includes `organizationID`,
including a later usage failure. Consumers must reject a previous response
when a newer status binds another organization or says the subscription
session is unavailable. Failed profiles carry no organization from an earlier
attempt.
The SDK has no rename API; consumers reject incomplete JSON and retry their
next local read. The only environment value read is `HOME`, because the SDK
does not expose a home-directory method.

Requires Claude Code 2.1.287 or later with a subscription session. An API-key
session cannot supply subscription limits. The collector stops when its
session's engine stops, including host eviction under memory pressure. The
optional usAIge recovery monitor reopens that existing session when Claude's
local lifecycle log confirms an idle timeout or governor eviction. It does
not send a prompt, start a new session, or launch Claude after the user quits it.
A module reload cancels the old timer and starts a new collector through the
host's replayed `session.start` event. The app package includes the same mod under
`Contents/Resources/ClaudeUsageBridge`; validation and tests do not enable it.

For a project-scoped Desktop Code installation, register the bundled local
marketplace and install only for the current checkout:

```sh
claude --bare plugin marketplace add /Applications/usAIge.app/Contents/Resources --scope local
claude --bare plugin install usaige-usage-bridge@usaige-local --scope local
```

These commands update local `extraKnownMarketplaces` and `enabledPlugins`
settings and install Claude's normal plugin cache. For source development,
use this repository's `Integrations` directory as the marketplace source.
Project settings cannot set `CLAUDE_CODE_PLUGIN_DIRS`; Claude intentionally
ignores that environment key in both project and local settings.

Claude must trust the workspace and start a Code session there before the
collector can run. An existing session loads the installation with
`/reload-plugins`; the host replays `session.start` for newly loaded modules.
The Desktop usage popup alone does not start a Code engine. No global Claude
settings, credentials, or API-key helper need to be changed.

After the collector has produced a successful report, automatic reopening can
be explicitly enabled in
`~/Library/Application Support/usAIge/claude-usage/recovery.json`:

```json
{
  "schemaVersion": 1,
  "desktopSessionID": "local_00000000-0000-0000-0000-000000000000",
  "enabled": true
}
```

Use the existing Desktop session's `local_…` ID from its continuation URL,
not the CLI's separate session UUID. Recovery can bring Claude to the front.
It runs in the same 30-second usAIge check as the Usage-page refresh and takes
precedence: the page is used only when no configured session needs reopening.
After either route opens, both wait at least 90 seconds, including across usAIge
restarts. If the reopened collector writes a new status in that time, its retry
deadline also holds the page back. Otherwise the page is the fallback.
It requires an exact native idle/eviction marker after the last successful
report, respects `nextAttemptAt` plus 90 seconds for in-flight work, and ignores
later stops, starts, or warm resumes. Missing or incomplete status files defer
recovery so they cannot hide a retry deadline. Attempts are persisted in `recovery-attempt.json` so
restarting usAIge cannot repeat a pause; different pauses have a 15-minute
cooldown. Hiding Claude in the rail or setting `enabled` to `false` prevents
automatic reopening. A missing marker, quit app, archived session, or host
resume restriction remains unavailable instead of triggering sign-in.

Run the tests with `node --test tests/*.test.mjs`. Validate the mod with the
supported Claude Code executable using `--bare plugin validate <directory>`.

API references: [Anthropic mods API](https://code.claude.com/docs/en/plugins/mods/api),
[Anthropic mods declarations](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts).
