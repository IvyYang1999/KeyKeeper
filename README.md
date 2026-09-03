# KeyKeeper

**Your API keys, usable by scripts and AI tools, never visible to them.**

KeyKeeper is a macOS menu bar app plus a `keykeeper` CLI and thin Python/Node SDKs. Keys
live in an encrypted vault on your Mac. Scripts, cron jobs and AI coding assistants
(Claude Code, Cursor, Copilot…) get them injected as environment variables at runtime and
only ever see the key *names*.

## The problem

To let an AI tool call OpenAI, Stripe or your database you usually paste `sk-abc123…` into
the chat or a `.env` file. From there the key ends up in conversation context, logs,
screenshots and git history.

## How KeyKeeper works

```
┌──────────────────┐   unlock    ┌───────────────────┐   env vars    ┌──────────────┐
│ KeyKeeper app    │◀────────────│ keykeeper run     │──────────────▶│ your command │
│ (menu bar)       │   IPC       │ -c openai -- …    │               │ python, node │
│ holds the        │────────────▶│                   │   stdout      │ curl, agent  │
│ unlocked vault   │   values    │ redacts secrets   │◀──────────────│              │
└──────────────────┘             └───────────────────┘               └──────────────┘
         │
         ▼
 ~/Library/Application Support/KeyKeeper/
   vault.age      (age-encrypted values)
   identity.age   (age identity, protected by your passphrase)
   meta.json      (names, notes, field names — no values)
```

- **Store**: add a key in the menu bar app (or open a prefilled form with a
  `keykeeper://add?label=…&fields=…` link). Values are encrypted with
  [age](https://github.com/FiloSottile/age); the identity is protected by a passphrase you choose.
- **Unlock**: after a reboot or app restart the vault is locked. Unlock it in the menu bar
  (the icon shows a lock) or with `keykeeper unlock`. It stays unlocked until you lock it or quit.
- **Use**: `keykeeper run -c <id> -- <command>` injects the secret fields as environment
  variables. Any secret that shows up in the command's output is replaced with `[REDACTED]`.
- **Approve**: the first time a new terminal session, script or agent uses a key, KeyKeeper
  asks you once. Approvals are listed on the credential's page and can be revoked.

## Quick start

**Requirements:** macOS 14+, and `age` (`brew install age`).

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
3. Create your vault: choose a passphrase, then **save the recovery key it shows you**.
   KeyKeeper keeps no copy; it is the only way back in if you forget the passphrase.
4. Click **+** to add a key group, e.g. name `OpenAI`, field `api-key`. The ID (`openai`)
   and the environment variable name (`API_KEY`) are shown as you type.
5. Use it:

   ```bash
   keykeeper run -c openai -- python script.py     # script reads os.environ["API_KEY"]
   ```

## Everyday commands

```bash
keykeeper list                 # IDs and labels
keykeeper list --detail        # plus notes and field names (secrets shown as ********)
keykeeper meta <id>            # one credential as JSON, no values

keykeeper run -c <id> [-c <id2>] [--prefix PREFIX_] [--verbose] [--tty] -- <command>

keykeeper status               # locked / unlocked
keykeeper unlock               # hidden passphrase prompt; starts the app if needed
keykeeper lock

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
ready after a reboot (you still unlock it once).

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
| Values at rest | age-encrypted `vault.age`; the age identity in `identity.age` is sealed with PBKDF2 + AES-256-GCM under your passphrase. A second, emergency recipient (the recovery key shown once at creation) can also decrypt the vault. |
| Unlocked session | Lives only in the KeyKeeper app's memory. Locked on quit, on reboot, or when you click Lock. The CLI never sees the identity; it asks the app for individual values over a Unix socket. |
| Metadata | `meta.json` holds labels, notes and field *names* in plain text. No values. |
| Using a key | `keykeeper run` injects values into the child process's environment and replaces them with `[REDACTED]` in its stdout/stderr. `keykeeper get` refuses to print to a terminal. |
| Who may ask | Per-credential mode (Background OK / Ask every time) plus per-caller approvals, shown and revocable in the app. Concurrent requests queue up instead of failing. |
| Clipboard | Copying a value from the app marks it concealed for clipboard managers and clears it after 30 s unless you copied something else. |
| Passphrase | Only ever typed into the app or a hidden TTY prompt. No flags, environment variables or pipes. |

Folder: `~/Library/Application Support/KeyKeeper/` (Settings › Show data folder). Back it up
together with your passphrase and recovery key.

## Troubleshooting

| You see | Do |
|---|---|
| `The vault is locked` | `keykeeper unlock`, or click the lock icon in the menu bar. |
| `The KeyKeeper app is not running` | `keykeeper unlock` starts it; or open it from Applications and turn on Launch at Login. |
| `This caller is not authorized` | Click Authorize in the KeyKeeper window, or set the credential to Background OK. `keykeeper grants list` shows approvals. |
| `Timed out … waiting for approval` | Run it again while you're at the Mac; approval windows wait 2 minutes. |
| Cron jobs fail after a reboot | Expected: the vault locks on reboot. Unlock once; consider Launch at Login so the app is already up. |
| `Refusing to print a secret to the terminal` | Use `keykeeper run`, or add `--reveal` if you really want it on screen. |
| Setup says the CLI is out of date | Click Update CLI (Settings › Command line) so CLI and app come from the same build. |

## Project structure

```
KeyKeeper/
├── Sources/
│   ├── KeyKeeperCore/   # age vault, session manager, metadata, grants, IPC protocol
│   ├── KeyKeeperCLI/    # keykeeper: list, meta, run, get, unlock/lock/status, grants, requests
│   └── KeyKeeperApp/    # menu bar app (SwiftUI): vault banner, credentials, approvals, settings
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
