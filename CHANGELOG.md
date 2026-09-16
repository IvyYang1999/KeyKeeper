# Changelog

## Unreleased

- License: the app, CLI and core move from MIT to FSL-1.1-MIT (source public, no competing products, MIT again after two years). SDKs, skill and plugin stay MIT. Earlier releases remain MIT.

## 0.3.5 - 2026-09-16

- Import a project's dotenv file with `keykeeper import`: the App previews variable names, asks for approval and stores all imported values in the Keychain. Imported credentials are inject-only; originals remain untouched. Single-line assignments only; malformed/multiline syntax fails closed, and empty/reserved/unsupported names are reported as skipped. No shell interpolation is performed.
- 113 provider templates, separated by region, plan and credential type; searchable brand/category picker, provider icons, expiry guidance and official management links. Templates can be selected while adding a credential or bound afterwards without renaming its existing fields.
- Bundled Codex and Claude Code plugins, with installation instructions in Settings. Installation does not grant credential access.
- Access and metadata changes have separate history tabs and drill-down details; usage permissions show the actual caller identity, scope and expiry. Current authorization is separate from historical decisions.
- Fix approval status refresh and window corners after expanding/collapsing details. Keep both Chrome import and KeyKeeper login available after saving a website session.
- Import hardening: never guess a value safe for plain metadata, preserve escaped quotes, reject partial parsing, and verify stored values before committing metadata.
- Missing request reasons are visibly flagged in the approval window rather than refusing the request outright.

## 0.3.4 - 2026-09-15

- Approvals moved from plain files into a single app-owned Keychain item; the old files are renamed and no longer read. "Always" is scoped to the approved program only, an unsigned app is identified by the file it runs from, and a fresh install enforces background approvals by default. Existing approvals ask once more.
- Approval window redesigned: the caller's message in the middle, KeyKeeper's own one-line verdict, three answers — just this once, while it runs (bound to the process or terminal session), don't ask again. The credential ID is shown when it differs from the title.
- A first request must carry `--reason`; `save --create` declares a purpose (`--purpose`, `--frequency`, `--background`); `run`/`get` may ask for a duration. Rules flag inflated requests; an optional second-model reviewer (any Anthropic/OpenAI-style endpoint) adds an opinion.
- Inject-only credentials: agent-created credentials are served only to `keykeeper run`; `get` and the SDKs are refused unless "Can be read out" is turned on.
- Plain fields written over the socket are not injected until confirmed in the app.
- Clipboard saves take what is on the clipboard and show a masked preview with the copy time; the "copy exactly once after the request" rule is gone.
- Login sessions can be opened inside KeyKeeper and handed to an agent once, for a run, or until revoked; credentials can record an expiry date.
- Fixes: the CLI no longer times out while an approval window is open; metadata changed outside KeyKeeper is flagged; field names that would become variables like PATH are refused; a tampered Chrome registration can be repaired; a "once" approval hands each field out once.

## 0.3.3 - 2026-09-13

- Clipboard saves accept only a copy made after the request, exactly once; what was already on the clipboard is refused (`--use-current-clipboard` opts out).
- `--expect base64:32 | hex:N | bytes:N | chars:N` refuses a value whose shape does not match, before anything is written; every save reports the stored value's shape without revealing it.
- `--replace` replaces an existing field after explicit confirmation, and `--expect-ed25519-public-key` proves a private key matches its public key before storing.
- Security: copying a secret in the app no longer syncs to other devices via Universal Clipboard.
- Security fix: "Use Password" in the approval window went back to Touch ID instead of showing the password sheet.
- The approval window says "No terminal session" instead of "Unknown terminal"; the Python and Node SDKs can pass a caller reason.
- Website sessions: the empty state explains and links to the bundled Chrome extension, its ID is pinned so it no longer depends on the app's install path, and registering the native host is one click in the app.

## 0.3.2 - 2026-09-13

- Fields can be marked plain instead of secret. Plain values live in `meta.json` in the clear, are injected by `keykeeper run` without an approval prompt, and can be written with `keykeeper edit --set/--unset`. A field can be converted either way in the app. Never put a password, token or key in a plain field.
- A credential holding no secret fields no longer asks for approval at all.
- Fix: renaming a field and converting it to plain in the same save no longer deletes the Keychain copy before the metadata is written.
- Fix: the credential title is sanitised before it becomes the authorization window's headline — any local process can rename a credential without a prompt.
- Fix: the save-time integrity check is scoped to the credential being edited, so one credential with missing values no longer blocks every other edit.
- Fix: Chinese translations for the plain-field interface, including the destructive confirmation button.
- Fix: a plain field's earlier names no longer claim an environment variable a current field name needs.
- Fix: launch no longer reads the Keychain on every start to record that a store exists.
- Release tooling: the generated appcast is now written where it is verified, the feed-signature check matches what Sparkle actually emits, `publish-update.sh` pushes `main` and refuses to upload a DMG the appcast did not sign.

## 0.3.1 - 2026-09-13

- Security: choosing "Use Password" in the approval window released the secret without any check. It now runs a real device-password check.
- Security: the credential name and key names shown in the approval window came from the caller. They now come from KeyKeeper's own records, and requests for unknown credentials are refused.
- Callers can state a reason for a request (`keykeeper run --reason "…"`), shown in the approval window as unverified plain text that never affects any decision.
- The approval duration picker says plainly what an approval covers.
- Fix: the approval window briefly showed square, unfrosted corners while the caller details expanded.

## 0.3.0 - 2026-09-12

- Show non-interactive local value-presence checks in the main window and menu bar, with explicit missing-field recovery guidance. `meta` includes `valueStatus`; `status --check-values` reports all credential states without exposing values.

- Add signed in-app updates with daily update notifications and optional automatic installation.
- Add a dedicated main window for keys, website sessions, caller access, activity and settings, alongside a compact menu bar.
- Add Simplified Chinese and English interfaces, with an independent language preference.
- Import keys through a native confirmation flow from browser paste, the system clipboard, supported Python source literals, and service-account JSON files.
- Support explicit temporary-file injection for credential files, with managed cleanup.
- Preview selected Chrome website sessions with per-launch confirmation and bounded sessions.
- Preserve unrevealed key values when editing field names, and withdraw authorization prompts when callers disconnect.
- Allow safe restoration of missing fields and addition of independent credentials without discarding recovery metadata.

## 0.2.0

- Store credentials in one macOS Keychain item and preserve access across Developer ID-signed updates.
