# Claude usage bridge

This optional local usAIge mod runs in an existing Claude Code subscription
session. usAIge reads Claude Desktop's recorded usage without the mod,
whichever app is installed first. The mod can produce fresh usage readings in
the background while its host engine stays active. usAIge checks the local
reports and native usage files every five seconds without opening Claude's
Usage page, reopening a Code session, or bringing Claude to the front.
Claude Code owns authentication and supplies an opaque authorization handle;
the bridge does not read passwords, keys, credentials, cookies, or settings.
It makes no model requests and sends no prompts. Its only shell command is the
silent keep-alive task described below, whose start can ask for permission.

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
session's engine stops. usAIge keeps checking local usage files and waits for
a fresh report or native reading; it does not reopen the session. Accepted
observations keep their original timestamps, and observations older than 30
minutes become unavailable. Collection resumes when Claude runs the host engine
again.

## Keeping one session's engine running

Claude Desktop stops idle Code session engines in two ways. Its memory governor
evicts idle engines when too many are running; this is what stopped
interactive sessions when observed. Its 15-minute idle timeout has so far been
seen pausing only scheduled-task sessions. Desktop's code skips both while the
session runs a background task. After a collector has written its first
report, it starts one such task through the session's own Bash tool:

```sh
until /bin/ps -o ppid= -p $$ | /usr/bin/grep -qx ' *1'; do /bin/sleep 60; done
```

The task prints nothing and never finishes while Claude runs it, because a
finished background task would wake the model. It exits by itself only when
Claude has gone without stopping it and its shell has been orphaned. The
collector stops it with Claude's TaskStop tool, which does not notify the
model, when the session ends or restarts, when the session has no subscription,
or when another session holds the lease.

Only one session on the Mac holds a task. The holder renews
`keep-alive.json` (its Claude Code session id, task id, and renewal time) in
the usage directory on every 30-second check. Other collecting sessions start
no task while that lease is younger than two minutes, so they still pause
normally. When the holder's engine stops, the lease expires and the next
collecting session with a running engine takes over. After a module reload the
new module adopts its session's running task, named in a lease renewed within
the last two minutes, instead of starting another. A session resumed after its
engine stopped without ending it (a crash or a forced quit) finds only an
expired lease, so it starts its own task.

The Bash call goes through Claude's normal permission check. Depending on the
session's permission mode, the start may show a permission prompt in that
session, or auto mode may decide it. To allow it without asking, add the exact
command above as a `Bash(...)` allow rule in the project's local settings. A
refused or failed start is not tried again until the collector restarts (a new
or resumed session, `/clear`, `/branch`, or a module reload); the collector
keeps refreshing usage without the task meanwhile.

The held session stays in memory (roughly 160 to 330 MB per Claude Code engine
here) and Claude's memory governor evicts other idle sessions instead. The
task appears in that session's background tasks; stopping it there lets Claude
pause the session normally, and the collector does not start another until the
session restarts. Claude still ends the engine when it quits, when the person
stops or archives the session, on sign-out, or on an account switch. Claude does
not start Code sessions at launch, so collection resumes only after a session
with the bridge runs again.

## Reloads and restarts

A module reload cancels the old timer and starts a new collector through the
host's replayed `session.start` event. `/clear`, `/resume`, and `/branch` end the
session without another `session.start`, so the collector restarts on the
settings `SessionStart` event that follows each of them. The app package includes the same mod under
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

Background collection does not use automatic session recovery or Usage-page
navigation. If both native polling and every collecting engine are stopped,
file checks alone cannot fetch new account data. usAIge waits quietly for
Claude to produce a fresh reading and leaves missing or expired data
unavailable.

Run the tests with `node --test tests/*.test.mjs` and the mod tests with
`claude plugin test <directory>`. Validate the mod with the supported Claude
Code executable using `--bare plugin validate <directory>`.

API references: [Anthropic mods API](https://code.claude.com/docs/en/plugins/mods/api),
[Anthropic mods declarations](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts).
