# KeyKeeper

**Your API keys, usable by scripts and AI tools, never visible to them.**

KeyKeeper is a macOS menu bar app plus a `keykeeper` CLI and thin Python/Node SDKs. Keys
live in the macOS Keychain, encrypted by the OS. Scripts, cron jobs and AI coding
assistants (Claude Code, Cursor, Copilot…) get them injected as environment variables at
runtime and only ever see the key *names*. There is no master password, no vault to
unlock, nothing to remember: logging into your Mac is the unlock.

## The problem

To let an AI tool call OpenAI, Stripe or your database you usually paste `sk-abc123…` into
the chat or a `.env` file. From there the key ends up in conversation context, logs,
screenshots and git history.

## How KeyKeeper works

```
┌──────────────────┐   IPC      ┌───────────────────┐   env vars    ┌──────────────┐
│ KeyKeeper app    │◀───────────│ keykeeper run     │──────────────▶│ your command │
│ (menu bar)       │            │ -c openai -- …    │               │ python, node │
│ reads the        │───────────▶│                   │   stdout      │ curl, agent  │
│ macOS Keychain   │   values   │ redacts secrets   │◀──────────────│              │
└──────────────────┘            └───────────────────┘               └──────────────┘
         │
         ▼
 macOS Keychain (one encrypted item, unlocked by your login)
 + meta.json (names, notes, field names — no values)
```

- **Store**: add a key in the menu bar app (or open a prefilled form with a
  `keykeeper://add?label=…&fields=…` link). Values go into a single Keychain item,
  encrypted by macOS and synced to nothing.
- **Use**: `keykeeper run -c <id> -- <command>` injects the secret fields as environment
  variables. Any secret that shows up in the command's output is replaced with `[REDACTED]`.
  The app starts automatically when a key is requested.
- **Approve**: the first time a new terminal session, script or agent uses a key, KeyKeeper
  asks you once in its own window. Approvals are listed on the credential's page and can
  be revoked.
- **After a reboot**: log in once, and everything — including cron jobs — works again.
  No password prompts, ever, in day-to-day use.

## Quick start

**Requirements:** macOS 14+.

1. Build the app (or use a release DMG when available):

   ```bash
   git clone https://github.com/IvyYang1999/KeyKeeper.git
   cd KeyKeeper
   ./scripts/build-app.sh          # produces dist/KeyKeeper-<version>.dmg and dist/dmg/KeyKeeper.app
   cp -R dist/dmg/KeyKeeper.app /Applications/
   open /Applications/KeyKeeper.app
   ```

2. First run: the setup screen installs the `keykeeper` CLI (asks for your password once)
   and shows the one-line prompt that installs the Claude Code skill.
3. Click **+** to add a key group, e.g. name `OpenAI`, field `api-key`. The ID (`openai`)
   and the environment variable name (`API_KEY`) are shown as you type.
4. Use it:

   ```bash
   keykeeper run -c openai -- python script.py     # script reads os.environ["API_KEY"]
   ```

That's the whole setup. No passphrase to choose, no recovery key to file away.

## Everyday commands

```bash
keykeeper list                 # IDs and labels
keykeeper list --detail        # plus notes and field names (secrets shown as ********)
keykeeper meta <id>            # one credential as JSON, no values

keykeeper run -c <id> [-c <id2>] [--prefix PREFIX_] [--verbose] [--tty] -- <command>

keykeeper status               # is the app reachable (it starts on demand anyway)

keykeeper grants list          # approved background callers
keykeeper grants revoke <id>
keykeeper requests list        # approval windows currently waiting

keykeeper get <id> <field>     # used by the SDKs; refuses to print to a terminal unless --reveal
```

`--tty` hands the command a real terminal (needed by editors, TUIs and interactive agents);
output redaction is off in that mode.

## Who can use a key

Every key group has one of two access modes, shown as a badge in the list:

| Badge | Meaning | Use it for |
|---|---|---|
| **Background OK** (default) | Scripts, cron jobs and agents can use the key after you approve each caller once. | Anything that runs unattended. |
| **Ask every time** | Every new terminal session must be approved in the KeyKeeper window while you are at the Mac. | Keys you only use by hand. |

In **Settings** you can require approval for new background callers ("Ask me before a new
script or agent uses a Background OK key") and turn on **Launch at Login** so the app is
in the menu bar from the start (it also launches on demand either way).

## SDKs

```bash
pip install ./sdk-python
npm install ./sdk-node
```

```python
from keykeeper import get_key, list_credentials, run
api_key = get_key("openai", "api-key")           # value returned over a pipe
run("openai", ["python", "script.py"])           # same as keykeeper run
```

```javascript
const { getKey, runWithSecrets } = require('keykeeper');
const apiKey = await getKey("openai", "api-key");
runWithSecrets("openai", ["node", "server.js"]);
```

Both SDKs shell out to the `keykeeper` CLI; no native dependencies.

## Claude Code integration

The [skill](skill/keykeeper.md) teaches Claude Code to discover credentials with
`keykeeper list --detail`, to run code through `keykeeper run`, to open a prefilled
`keykeeper://add?…` form when a key is missing, and never to ask for or print values.

Install it as a directory skill:

```bash
mkdir -p ~/.claude/skills/keykeeper
curl -fsSL https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/skill/keykeeper.md \
  -o ~/.claude/skills/keykeeper/SKILL.md
```

(Or paste the prompt shown on the setup screen into Claude Code and let it do this.)

## Security model

| Layer | What happens |
|---|---|
| Values at rest | One generic-password item in the macOS Keychain, encrypted by the OS with your login credentials. Nothing readable sits in a file. |
| Unlocking | Your macOS login. The keychain stays available while the screen is locked and re-locks at logout/reboot — the same model as Safari passwords, `gh`, `aws-vault` and `envchain`. |
| Metadata | `meta.json` holds labels, notes and field *names* in plain text. No values. |
| Using a key | `keykeeper run` injects values into the child process's environment and replaces them with `[REDACTED]` in its stdout/stderr. `keykeeper get` refuses to print to a terminal. |
| Who may ask | Per-credential mode (Background OK / Ask every time) plus per-caller approvals, shown and revocable in the app. Concurrent requests queue up instead of failing. |
| Other apps | The Keychain item's ACL trusts only KeyKeeper's signing identity; any other program that tries to read it triggers the macOS confirmation prompt. |
| Clipboard | Copying a value from the app marks it concealed for clipboard managers and clears it after 30 s unless you copied something else. |
| Backup | The item lives in your login keychain and is covered by your normal macOS backup/restore. An explicit encrypted-export command is on the roadmap. |

## Troubleshooting

| You see | Do |
|---|---|
| `The KeyKeeper app could not be started` | Open KeyKeeper from Applications once; check it isn't blocked by Gatekeeper. |
| `This caller is not authorized` | Click Authorize in the KeyKeeper window, or set the credential to Background OK. `keykeeper grants list` shows approvals. |
| `Timed out … waiting for approval` | Run it again while you're at the Mac; approval windows wait 2 minutes. |
| Cron jobs fail right after a reboot | Log in once; jobs work from then on (the login keychain unlocks with your session). |
| macOS asks about "confidential information" | You rebuilt KeyKeeper with a different signing identity. Click Always Allow once, or set a stable identity in `.signing-identity` (see `scripts/build-app.sh`). |
| `Refusing to print a secret to the terminal` | Use `keykeeper run`, or add `--reveal` if you really want it on screen. |
| Setup says the CLI is out of date | Click Update CLI (Settings › Command line) so CLI and app come from the same build. |

## Project structure

```
KeyKeeper/
├── Sources/
│   ├── KeyKeeperCore/   # Keychain blob store, metadata, grants, IPC protocol
│   ├── KeyKeeperCLI/    # keykeeper: list, get, meta, run, status, grants, requests, migrate-storage
│   └── KeyKeeperApp/    # menu bar app (SwiftUI): credentials, approvals, settings
├── sdk-python/          # Python SDK (wraps the CLI)
├── sdk-node/            # Node.js SDK (wraps the CLI)
├── skill/               # Claude Code skill
├── scripts/             # build-app.sh, install-cli.sh, git hooks
├── Tests/               # XCTest suites (swift test)
└── Package.swift
```

## Contributing

1. Fork and branch: `git checkout -b my-feature`
2. Bug fixes come with a test first (`swift test` runs in the pre-commit hook).
3. Keep commits atomic and open a pull request with what changed and why.

## License

[MIT](LICENSE)
