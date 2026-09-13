# Changelog

## 0.3.2 - unreleased

- Fields can be marked plain instead of secret. Plain values live in `meta.json` in the clear, are injected by `keykeeper run` without an approval prompt, and can be written with `keykeeper edit --set/--unset`. A field can be converted either way in the app. Never put a password, token or key in a plain field.
- A credential holding no secret fields no longer asks for approval at all.
- Fix: renaming a field and converting it to plain in the same save no longer deletes the Keychain copy before the metadata is written.
- Fix: the credential title is sanitised before it becomes the authorization window's headline — any local process can rename a credential without a prompt.
- Fix: the save-time integrity check is scoped to the credential being edited, so one credential with missing values no longer blocks every other edit.
- Fix: Chinese translations for the plain-field interface, including the destructive confirmation button.

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
