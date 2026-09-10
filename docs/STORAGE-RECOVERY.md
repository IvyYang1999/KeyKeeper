# Storage recovery and write protection

Credential labels, field names and approvals live in application data. Values live in
one encrypted login Keychain item. Seeing credentials in the app, or getting `ready`
from `keykeeper status`, does not prove those values are accessible. `ready` reports
the session state; it is not an inventory or recovery check.

## What the write guard checks

- A missing Keychain item plus metadata describing existing secret fields blocks
  normal store creation. An item observed earlier by the current store instance
  cannot silently be recreated after it disappears, even if metadata is empty.
- Before GUI add, edit or delete, all secret fields in metadata must exist in the
  blob. A partial store blocks mutations, including metadata-only edits. Available
  values can still be read; extra blob fields are preserved, not deleted.
- Updating a previously read item never falls back to creating it. First creation
  never overwrites an item created by another writer in the meantime.
- A genuinely new installation can create its first store. Multi-field editing and
  deleting the last credential remain supported.
- The explicit legacy migration command has a separate initialization path, since
  it creates the new store from legacy data. Do not use it as a missing-store repair
  command against the current App.

The guard detects inconsistency; it cannot recover missing values. It is not a
transaction spanning metadata and Keychain, and does not solve concurrent writes
from separate processes to an existing blob. Normal App use has one process owner.

## What counts as a recoverable backup

1. Preserve the original Keychain and KeyKeeper application data in a private local
   backup with source/copy hashes, sizes, stable source timestamps and a restore map.
2. Make a separate working copy. Keep original copies unchanged.
3. Unlock that working copy through the system interface. Enter any password locally;
   do not put it in commands, chat, logs or the repository. Avoid repeated guesses
   or resetting the Keychain. Copies of the same encrypted file require the same
   decryption material and are not independent unlock alternatives.
4. Verify the target item can be read, then compare credential/field coverage with
   metadata. Report presence and counts only. Never print or export plaintext values.
5. Plan restoration as a separate operation that preserves current/new values and
   approvals; do not overwrite the entire current login Keychain.

Matching file hashes prove copy integrity. Finding a service name proves a label
exists. Neither proves that the values can be decrypted or that the backup is complete.
The login password of a reinstalled Mac may not unlock a Keychain from before reinstall.

An independently decryptable encrypted export/import feature is not implemented.
It needs authenticated encryption, a user-held recovery factor independent of the
old login Keychain, wrong-key/tamper tests, and a full restore exercise into an empty
isolated environment. Until then, do not describe a file copy as verified recovery.

## Regression verification

Tests use synthetic in-memory blobs and temporary metadata. They cover missing and
partial stores, write-time disappearance, competing creation, unreadable metadata,
first use, multi-field edits, and resuming after synthetic values become available.
They do not prove that any user's old Keychain can be unlocked.
