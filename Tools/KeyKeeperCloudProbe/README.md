# Synthetic CloudKit + iCloud Keychain probe

This executable is not shipped inside KeyKeeper. It never opens the production
vault, IPC socket, credential services, or approval store. Build/sign it as a
separate `.app` with identifier `dev.keykeeper.app`, the dedicated profile, and
exact CloudKit/keychain entitlements. The executable checks its signing identity
before constructing a CloudKit container. `self-test` performs no Keychain or
CloudKit IO (it uses a disposable synthetic local-file fixture).

## Preparation

- Use the profile-authorized environment (current Developer ID profile: Production).
- Container: `iCloud.dev.keykeeper.app`, **private database** only.
- Deploy record type `KeyKeeperSyntheticHead`: String fields `vaultID`, `keyID`,
  `revisionID`; Bytes field `ciphertext`. No plaintext credential, note, account,
  authorization or browser session field exists.
- On each Mac create a separate existing private directory (mode `0700`), such as
  `/private/tmp/keykeeper-cloud-<run UUID>`. Use its physical path, not `/tmp`.
- Both Macs must use the same run UUID and the same iCloud account. Never copy
  `state.json`, a Keychain item, or a root key between Macs: that would bypass the
  synchronization being tested.

## Commands

Run the signed app's `Contents/MacOS/KeyKeeperCloudProbe` executable, with these
arguments (replace `RUN_UUID` and `ROOT` with non-secret fixture identifiers):

```text
status  --synthetic --run-id RUN_UUID --root ROOT
seed    --synthetic --run-id RUN_UUID --root ROOT
read    --synthetic --run-id RUN_UUID --root ROOT --expect-digest SHA256_FROM_PREVIOUS_MAC
advance --synthetic --run-id RUN_UUID --root ROOT
```

1. A: `status`, then `seed`. Keep the reported snapshot SHA-256.
2. B: `status`, then `read --expect-digest <A hash>`. `waiting_for_key` means the
   selected iCloud Keychain key has not arrived; no replacement key is generated.
3. B: `advance`. Both its runtime-generated fake secret and note must change.
4. A: `read --expect-digest <B hash>`. A's original local state must not have been
   copied to B. Restarting the probe before each command verifies persisted state.

Only random synthetic value hashes, revision IDs, counts and result codes are
printed. No raw secret, account identifier, decrypted snapshot or SDK error
description is logged. `local_grants_transferred=0` describes this probe's schema:
it does not prove that production approval UI has been wired up.

## Failure behavior

All commands are single, bounded attempts. There is a 45-second process deadline
and 15/30-second request/resource limits for database operations. A timeout cancels
the current operation and exits; a server write may nevertheless have committed.
The next invocation first reads the head and reconciles the pending revision.
It never retries an uncertain write automatically. Unconfirmed candidates and the
previous confirmed state remain in a ciphertext-only local journal. If the head
does not establish that pending revision, stop and inspect; a new test run UUID can
be used without removing the previous evidence.

Only a missing initial head permits creating a random, immutable root-key ID.
Cloud writes use atomic `ifServerRecordUnchanged`; conflicts retain the pending
candidate rather than overwriting the cloud head. Changing the iCloud account
invalidates the invocation and cancels the current operation. One account-epoch
fence serializes notification invalidation with actual operation submission, root
key creation, and local confirmation (including its success report). Async callbacks
must present their original epoch permit before they can be acknowledged. A write
already accepted by Apple's server cannot be recalled: its candidate remains pending
for a later readback. The deadline cancellation path uses a separate operation lock,
so it does not wait for native Keychain IO holding the effect fence.
Per-directory `flock` excludes concurrent probes.
No key, cloud zone or cloud record deletion API is implemented.

## Acceptance limits

Local self-tests and one-Mac cloud write/readback do not prove two-Mac propagation.
The production app's bundle ID, startup/migration, opt-in settings, approvals and
Sparkle transition remain separate work. This probe intentionally exposes manual
commands rather than background scheduling or unrestricted credential import.
