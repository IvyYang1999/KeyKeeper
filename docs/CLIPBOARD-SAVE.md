# Clipboard save — frozen first delivery

## Acceptance envelope

- `keykeeper save -c <id> --field <name> --from-clipboard` sends metadata only to the App.
- A visible, single-use confirmation identifies the OS-resolved caller, exact credential ID and field. No secret preview, read grant or persistent save grant.
- The App reads the system clipboard only after approval. Changed clipboard, cancel, expiration, disconnected caller and concurrent save requests fail closed.
- Save only absent values: restore an existing secret field or create a new strict single-field credential. Never overwrite any existing value, change grants, delete fields, or silently recreate a missing/corrupt/unsupported store.
- Partial stores remain protected from ordinary editing. This explicit repair path preserves unrelated values and metadata; missing entire stores remain blocked.
- Only a constant result reaches CLI/stdout/logs. No secret arguments, stdin, payload, screenshot or file. Successful save clears only the unchanged clipboard.
- Test with synthetic content: protocol/CLI, storage, confirmation controller, real CLI→IPC→App→Keychain→readback, plus visible confirmation/cancel. Then signed package, verify and deploy App + CLI together. Keep automatic deployment hooks disabled.

## Coverage and scope exception

One small vertical package crosses Core, CLI and App because the delivery unit is the real write path. Coverage: metadata-only DTO/roundtrip tests; no-overwrite Core/SaveMissingTests; confirmation/clipboard/lifecycle App tests; CLI argument and old-App compatibility tests; real signed synthetic smoke at integration. Same agent owns implementation and one bounded final sweep; no delegated agents requested.

Out of scope: provider logins, real credential recovery, key rotation, batch/automatic approval, existing-value replacement, encrypted backup/export, stdin/SDK writes, browser extensions. Browser copy may already enter third-party clipboard history; this feature cannot undo that. Login/2FA remains a human gate.

If blob write succeeds but metadata persistence fails, preserve the value and report a repair-required error, never destroy it to simulate rollback. Cross-file crash recovery is a known limitation; do not report success without both commits and readback. No retry after an uncertain write.

## Usage

Copy the intended key using the provider's Copy button, without exposing it to the model. Restore an existing missing secret field:

```sh
keykeeper save -c 硅基流动 --field key --from-clipboard
```

Create a new credential (label defaults to ID, strict protection, no inherited read grants):

```sh
keykeeper save -c new-provider --field api_key --from-clipboard --create
```

Confirm the exact ID and field in the KeyKeeper window. Click **Save once** or press Command-Return; Return/Escape cancel. Each request expires in 90 seconds. There is no `--yes`, `--value`, overwrite or unattended-approval mode. Copy only after the website login has completed. Neither the CLI nor the Agent needs to read the clipboard.

An older App returns a version-mismatch error without saving. Update App and CLI together. Whole-store loss still requires recovery; this command does not reset a Keychain or turn a missing store into an empty one.

The signed real-App smoke uses `KEYKEEPER_DATA_DIR`, a `com.keykeeper.test.*` Keychain service and a `/tmp/keykeeper-test-*` socket together. Production keeps its normal stores and socket; the test override is ignored unless all three isolation settings match the test constraints.
