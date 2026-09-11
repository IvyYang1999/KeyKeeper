---
name: keykeeper
description: Use when user mentions API keys, secrets, credentials, or KeyKeeper. Also use proactively when writing code that needs API keys or secrets.
---

# KeyKeeper - API Key Management

The user's API keys and credentials are managed by KeyKeeper, a macOS menu bar app.
Secret values live in the macOS Keychain and are served only by the KeyKeeper app,
which starts automatically when a key is requested.
**Secret values MUST NOT appear in this conversation, in code, or in terminal output.**

## Discovering available credentials

```bash
keykeeper list --detail      # every credential: ID, label, notes, field names (secrets shown as ********)
keykeeper meta <id>          # one credential as JSON, no secret values
keykeeper status             # is the app reachable (it starts on demand anyway)
```

The **ID** (left of the `|` in `keykeeper list`) is what you pass to `-c`.
Field names become environment variable names: `api-key` → `API_KEY`, `base url` → `BASE_URL`.

## Using credentials

### Option A: process-level injection (recommended)

`keykeeper run` injects every secret field of a credential as environment variables into a
subprocess. The values exist only in that process; anything the process prints that contains
a secret is replaced with `[REDACTED]`.

```bash
keykeeper run -c <credential-id> -- python script.py
keykeeper run -c stripe -c openai -- node server.js        # several credentials
keykeeper run -c stripe --prefix STRIPE_ -- python app.py  # STRIPE_API_KEY instead of API_KEY
keykeeper run -c my-api --tty -- opencode                   # interactive / full-screen programs
keykeeper run -c my-api --verbose -- ./job.sh               # prints the injected variable NAMES to stderr
```

Write code that reads from the environment:

```python
import os
api_key = os.environ["API_KEY"]
```

```javascript
const apiKey = process.env.API_KEY;
```

`--tty` is for programs that need a real terminal (TUI editors, agents with a UI). In that
mode output redaction is off, so keep it for interactive use only.

### Option B: SDK runtime access

```python
from keykeeper import get_key, get_field
secret = get_key("credential-id", "field-name")
```

```javascript
const { getKey, getField } = require('keykeeper');
const secret = await getKey("credential-id", "field-name");
```

## When a credential is missing

Do not ask for the value. Tell the user what to add, and give them a link that opens the
KeyKeeper form already filled in with the name and field names (they paste the values there):

```bash
open "keykeeper://add?label=OpenAI&fields=api-key,org-id"
```

Then continue once `keykeeper list` shows the new ID.

## Errors and what to do

| Message contains | Meaning | What to do |
|---|---|---|
| `could not be started` | The KeyKeeper app failed to launch. | Ask the user to open KeyKeeper from Applications once, then retry. |
| `not authorized` / `Approve it in the KeyKeeper window` | This caller has not been approved for that credential yet. | Tell the user an approval window is (or will be) open in KeyKeeper; they click Authorize. For unattended jobs, suggest setting the credential to "Background OK" in the app. |
| `Timed out … waiting for approval` | Nobody clicked Authorize within 2 minutes. | Run the command again while the user is at the Mac. |
| `not found. Run 'keykeeper list'` | Wrong credential ID or field name. | Run `keykeeper list --detail` and use the exact ID. |
| `Refusing to print a secret to the terminal` | `keykeeper get` was run in a terminal. | Use `keykeeper run` instead; never add `--reveal`. |

## Rules

1. NEVER ask the user for API key values, secrets or passwords.
2. NEVER hardcode secret values in source code or config files.
3. NEVER print, log, echo or return the value of `os.environ["…"]`, `get_key()` / `getKey()`.
4. NEVER run `keykeeper get` yourself; use `keykeeper run` (Option A) so the value never enters this conversation.
5. ALWAYS read secrets from the environment (or the SDK) inside the code you write.
6. Use `keykeeper list --detail` to find the exact credential ID and field names.
7. If a credential doesn't exist, offer the `keykeeper://add?…` link above; the user adds it in the app.
## Save without exposing a key to the model

After the user authorizes saving a key, use the provider's Copy button. Do not reveal the key, read the clipboard, paste it into a tool call, pass it as an argument, or write it to a file.

Run `keykeeper save -c <credential-id> --field <field-name> --from-clipboard` to restore an existing missing secret field. Add `--create` only for a new credential ID. KeyKeeper asks for one-time confirmation and reads the system clipboard inside the App; the CLI receives only success or a constant error. It never overwrites an existing value or grants read access. New credentials use strict protection. The user confirms real-key saves; do not auto-click approval without their explicit authorization for that save.

The clipboard must stay unchanged until confirmation. On timeout/connection failure, check the credential metadata and App state before retrying; never blindly repeat a write with an uncertain outcome. Website login/2FA may still require the user. A wholly missing store remains blocked; this command does not reset or recreate it.

This command reads the macOS system clipboard. A tool's browser-session clipboard may be isolated; do not assume `tab.clipboard` reaches KeyKeeper.

### Browser-session clipboard (Codex desktop)

Use `keykeeper save -c <credential-id> --field <field-name> --from-browser` (plus `--create` for a fresh ID). Keep this CLI process running: it prints a single-use loopback receiver URL, then waits for the final result. The link authorizes one pending write proposal, never a read; do not share or persist it. No fixed port or machine-specific setup is needed.

Open that exact URL in the **same browser session** holding the copied key. Focus the labeled paste area and use the browser's keyboard Paste action. Do not use clipboard `readText`, DOM extraction, `fill(secret)`, tool arguments, files or chat to transfer the value. The page consumes the paste event without placing the text in its input value. It then asks the user to confirm the exact ID/field in the native KeyKeeper window. Do not auto-approve real-key saves without explicit authorization for that save. Read the final CLI result; opening the page or seeing "waiting for confirmation" is not success.

Website Copy buttons and the browser tool's clipboard may use different buffers. A failed/empty Paste does not justify reading either buffer into the model. Cancel the pending import first; use `--from-clipboard` only when the user/provider action put the intended value into the system clipboard. If the source cannot be established, stop and ask the user to copy through a supported path. Never silently fall back to another clipboard, which could save an unrelated secret. Website-specific compatibility is not universal.

The import expires after 90 seconds. Closing a page during the submitted request or exiting the CLI cancels pending approval; cancellation after a completed save does not undo that save. The browser clipboard is **not** automatically cleared (the App cannot safely compare it); clear it through the browser's supported UI only if that will not replace newer user content. This is a same-Mac desktop workflow, not a cloud/remote-agent endpoint. Follow the browser tool's own permissions and user-confirmation requirements.
