# Changelog

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
