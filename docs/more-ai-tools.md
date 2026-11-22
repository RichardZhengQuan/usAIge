# More AI tools

usAIge reads fifteen AI tools on the Mac itself. This note records how the
newer ones were chosen and which other tools are left, using
[ClaudeBar](https://github.com/tddworks/ClaudeBar) (Apache-2.0) as the survey
of what exists and how each tool's usage can be read. usAIge does not copy
ClaudeBar's code: its provider docs and definitions say where each tool keeps
its quota, and usAIge's readers are its own Swift, kept to the boundaries in
[CONTRIBUTING.md](../CONTRIBUTING.md): no browser cookies, no Keychain reads
for these tools, no stored or refreshed credentials, and no guessed values.

Surveyed from ClaudeBar at commit `e999eb9` (2026-11-20).

## Built in

| Tool | Source | Needs from the user |
| --- | --- | --- |
| JetBrains AI | The quota file the IDE saves | Nothing |
| Windsurf (Devin Desktop) | The plan the app saves in `state.vscdb`, read-only | Nothing |
| Antigravity | Its local language server on `127.0.0.1`, while it runs | Nothing |
| GitHub Copilot | `gh auth token` and GitHub's Copilot endpoint | Turning it on in **AI Tools** |
| Kiro | `kiro-cli acp` | Nothing |
| Amp | `amp usage` | Nothing |
| Muse Code | `muse usage --json` | Nothing |
| Oh My Pi | `omp usage --json` | Nothing |
| Command Code | The key `cmd login` saved, and its usage API | Nothing |
| Cline | The login `cline auth` saved, and its usage API | Nothing |
| OpenCode Go | The OpenCode Zen key in `auth.json`, and its usage API | Nothing |

JetBrains AI and Windsurf came first because their apps already save their
quota in a file, so there is nothing to sign in to and nothing to request. The
others follow ClaudeBar's local sources, with these choices:

- **Antigravity** uses only the running app's local server. ClaudeBar's
  fallback reads a Google token from the Keychain while the app is closed, and
  runs `agy` to renew it; usAIge does neither. The server's self-signed
  certificate is accepted only for `127.0.0.1`.
- **GitHub Copilot** is off by default, because the GitHub CLI's token also
  covers the user's repositories. Only the Copilot API path is used; the
  Billing API needs a pasted token and username.
- **Kiro** uses the CLI's JSON-RPC mode only. The interactive `/usage` screen
  fallback is left out.
- **OpenCode Go** uses the usage API only. ClaudeBar's offline mode estimates
  usage from opencode's local history, which usAIge would not show as a limit.
- **Command Code, Cline, OpenCode Go** read only the file their own CLI login
  wrote. Environment-variable keys, pasted keys and extra accounts are not
  supported.
- **Oh My Pi** reports Claude, Codex and other accounts it is signed in to. They
  appear under Oh My Pi, named by provider and order, never by email. They can
  repeat the Claude or Codex rings when the same account is signed in both
  ways.

## Not built in

- **Kimi:** its CLI's `/usage` needs an interactive terminal, and its API mode
  reads browser cookies. Worth adding if Kimi gains a non-interactive usage
  command.
- **Gemini CLI:** individual sign-in was retired in June 2026, and keeping its
  token valid means running `gemini` to refresh it. Antigravity covers Gemini.
- **Browser sign-ins:** Devin (the web agent) reads browser cookies, which
  usAIge never does.
- **Pasted API keys and billing balances:** Warp, OpenRouter, DeepSeek, Z.ai,
  MiniMax, Alibaba, Mistral, Vercel AI Gateway, OpenAI API, Cloudflare AI,
  AWS Bedrock, Runcrate, and UberLLM need a key the user creates and usAIge
  stores. usAIge stores no provider credentials, so these belong in a paired
  remote adapter that keeps its own key and uploads normalized limits.
