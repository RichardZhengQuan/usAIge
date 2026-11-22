# More AI tools

usAIge reads Codex, Claude, Cursor, Grok Build, JetBrains AI, and Windsurf on
the Mac itself. This note records which other tools could follow, using
[ClaudeBar](https://github.com/tddworks/ClaudeBar) (Apache-2.0) as the survey
of what exists and how each tool's usage can be read. usAIge does not copy
ClaudeBar's code: its provider docs say where each tool keeps its quota, and
usAIge writes its own readers that keep to the boundaries in
[CONTRIBUTING.md](../CONTRIBUTING.md): no browser cookies, no stored or
refreshed credentials, and no guessed values.

Surveyed from ClaudeBar at commit `e999eb9` (2026-11-20).

## Added first

JetBrains AI and Windsurf were chosen first because each tool's own app already
saves its quota in a local file. usAIge reads that file, with no sign-in, no
Keychain prompt, and no network request, so these are the most reliable sources
that need nothing new from the user.

| Tool | What usAIge reads |
| --- | --- |
| JetBrains AI | `AIAssistantQuotaManager2.xml` in the options folder of the JetBrains IDE (or Android Studio) that saved it last |
| Windsurf (Devin Desktop) | The saved-plan rows of the app's `state.vscdb`, opened read-only |

## Worth adding next

In order of value to usAIge users and fit with its boundaries:

1. **Antigravity.** Google's replacement for the Gemini CLI, so it is the way
   to show Gemini limits now that Google retired Code Assist sign-in for
   individual Gemini CLI users in June 2026 (per ClaudeBar's Gemini notes).
   While the Antigravity app or `agy` runs, its language server answers on
   `127.0.0.1` with the Gemini and third-party-model pools, each with 5-hour
   and weekly windows. The port comes from `lsof` and a per-process CSRF token
   from the process's arguments; nothing is stored. The server uses a
   self-signed certificate, so usAIge would need a trust exception scoped to
   `127.0.0.1`, which deserves its own review. ClaudeBar's fallback while the
   app is closed reads a Google token from the Keychain; leave that out.
   Antigravity is installed on the maintainer's Mac, so it can be verified live.
2. **GitHub Copilot.** The most widely used tool here. ClaudeBar reads monthly
   AI credits from GitHub's Copilot API with the GitHub CLI's sign-in
   (`gh auth login`, Keychain item `gh:github.com`). That sign-in is a broad
   GitHub token, and reading it shows a Keychain prompt, so it needs an
   explicit opt-in in **AI Tools** rather than automatic detection.
3. **CLI-reported tools: Kiro, Amp, Muse Code, Oh My Pi.** Each tool's own CLI
   prints its quota (`kiro-cli` `/usage`, `amp usage`, `muse usage --json`,
   `omp usage --json`), so usAIge would run a command and read no credentials,
   like Grok Build's `grok models`. Muse and Oh My Pi print JSON and are the
   most robust; Amp and Kiro print text that changes between versions. Each has
   a smaller user base, so add them when users ask.
4. **Sign-in files plus an API: Command Code, Cline, OpenCode Go.** Each tool's
   CLI login leaves an API key in a file (`~/.commandcode/auth.json`,
   `~/.cline/data/settings/providers.json`, opencode's `auth.json`) that the
   usage API accepts, the same pattern as Grok Build's `auth.json`. OpenCode is
   installed on the maintainer's Mac. Use OpenCode Go's API only: ClaudeBar's
   offline mode estimates usage from opencode's history, which usAIge would not
   show.

## Not a fit for the built-in sources

- **Browser sign-ins:** Devin (the web agent) and Kimi's API mode read browser
  cookies, which usAIge never does. Kimi's CLI mode could join group 3.
- **Pasted API keys and billing balances:** Warp, OpenRouter, DeepSeek, Z.ai,
  MiniMax, Alibaba, Mistral, Vercel AI Gateway, OpenAI API, Cloudflare AI,
  AWS Bedrock, Runcrate, and UberLLM need a key the user creates and usAIge
  stores. usAIge stores no provider credentials, so these belong in a paired
  remote adapter that keeps its own key and uploads normalized limits.
- **Gemini CLI:** individual sign-in is retired, and keeping its token valid
  means running `gemini` to refresh it. Antigravity covers Gemini instead.
