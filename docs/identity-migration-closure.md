# Local identity migration: implementation and acceptance boundary

This candidate keeps the currently shipped `com.keykeeper.app` resources unchanged. The opt-in
builder creates `dev.keykeeper.app` only after the candidate is committed and clean. It does not
install, launch, notarize, publish, or enable synchronization.

## Startup integration

Before constructing business stores, running maintenance, or starting the real IPC listener:

1. For the production `StorageIdentity.current`, construct `IdentityMigrationCoordinator.production()`.
2. `status()` is `.required`, `.pending`, or `.ready`; any error leaves services paused.
3. Required: after user confirmation, call `await IdentityMigrationBridge.read()`, then
   `migrate(source:)`. The helper is the XPC service `Contents/XPCServices/KeyKeeperMigrationBridge.xpc`
   (`dev.keykeeper.app.migration-bridge`). Do not log the source. After old data was copied, the App
   says once which old Keychain items are left for the person to delete (also in Settings); see
   "The old copy" below. KeyKeeper never deletes them.
   `unsignedMetadata` requires a separate explicit confirmation before `allowUnsignedMetadata: true`.
4. Pending: `recover()` uses only the already confirmed protected journal image. No new source capture.
5. Ready: call `applyPreferences()` before services, including ordinary ready launches. Its durable
   `identityMigrationPreferencesApplied` marker and missing-only writes cover interruption between the
   completed migration receipt and preferences application. Existing new-domain choices are preserved.
6. Serve only after ready and preferences succeeded. The new production identity always requires bound
   IPC requests, even while iCloud is off. Tests and legacy production keep existing namespace behavior.

An empty source is explicit fresh-vault bootstrap, not an interpretation of denied or missing initialized
stores. Signed metadata with no MAC key, invalid metadata, unavailable Keychain reads, missing initialized
blob/markers, unresolved proposals, unfinished old journals, unknown local filenames and destination
conflicts block. Unknown schemas block rather than discard fields. No old item or metadata file is removed.

## Data mapping

| Source | New local target | Treatment |
| --- | --- | --- |
| Complete old raw credentials blob | `dev.keykeeper.credentials` | Byte-for-byte, including orphan values and historically missing fields |
| Verified metadata | `Application Support/KeyKeeper-v2/meta.json` | All fields retained; fresh new-identity MAC and initialized flag |
| Metadata MAC key | `dev.keykeeper.metadata-mac` | Fresh; old key/source untouched |
| Approval document | `dev.keykeeper.credentials.approvals` | Audit and reviewer settings retained; grants empty and mode enforced |
| Browser snapshot document | `dev.keykeeper.browser-sessions` | Cookies/security retained locally; legacy grants removed |
| Terminal browser import receipts | `dev.keykeeper.credentials.browser-import-proposals` | Retained; nonterminal proposal blocks |
| Metadata change history and creation markers | New local directory | Validated known files only |
| Known local preferences | New preferences domain | Language, setup/sound/update choices and missed/history UI state; missing-only |
| Already migrated grant archives | Original directory | Rollback record remains unchanged; no grant re-import |

All new plaintext-value blobs, the new metadata key, and pending migration images use the data-protection
Keychain, access group `ZPTA4LP594.dev.keykeeper.app`, synchronizable=false and ThisDeviceOnly accessibility.
The old CLI has neither the new group entitlement nor its namespace. Actual cloud root keys and encrypted
CloudKit snapshots are a separate explicit opt-in flow. Local browser snapshots are not cloud-synced.

The forward journal is create-only on first admission. Interrupted target writes resume only if absent or
byte-identical; a third value blocks. Every item/file reads back before the completed receipt replaces the
pending image. File publication uses a private temporary file, fsync and atomic create-only link. Replay of
a completed migration performs no additional migration writes. The original source remains the rollback.

## Helper trust and signed seam harness

The helper has the old `com.keykeeper.app` signature and runs as an XPC service inside the new App.
Each incoming connection requires the new identity's signature (`setCodeSigningRequirement` on the
connection; a service listener does not support the listener-wide setter), which XPC checks against the
audit token stamped on each message when it was sent; the App in turn requires the old identity from
the service. The reply goes back over that verified connection.

Earlier releases started the helper as a child process and read its output from a pipe; it is now an
XPC service so that the receiver of the old vault is the verified App itself. Its Info.plist sets
`XPCService.JoinExistingSession = true`: in a new security session the login keychain is unavailable
and reads fail with errSecInteractionNotAllowed.

The service rejects a running old App and holds the old endpoint startup lock (and, for capture, its
own socket lease). It reads fixed old sources twice and refuses changed snapshots. It never writes vault
items or metadata. Diagnostics are fixed numeric categories; the App gives up after a deadline.

## The old copy

After a migration the old Keychain items (values, metadata key, approvals, website sessions,
browser-import proposals, old sync journal) are a stale duplicate that anything signed as the earlier
KeyKeeper can still read without a prompt. KeyKeeper does not delete them. The Keychain offers no
"delete only if unchanged", so an automatic removal could not guarantee it deletes only what was
copied: a same-content item in another keychain, or a value saved between the last check and the
deletion, could be lost. The person deletes them in Keychain Access instead.

Right after copying old data, the startup screen lists the old item names still present and offers
Open Keychain Access and Continue; with none left it goes straight on. Settings shows the same list
("Copy from before 0.3.7", with Check Again) while any are left, but only after a completed migration
whose summary shows copied keys or website logins, never after a first install. The check
(`LegacyItemPresence`) asks the person's keychain search list for one item's attributes per name,
without the data-protection flag, never for its value, with authentication UI off; nothing is
changed and no dialog can appear. If the check fails, every name is listed rather than none. The XPC
service only captures; it has no removal request. The old folder (names, notes, plain fields, no
secret values) is left where it is.

`KeyKeeperMigrationProbe` is a synthetic-only signed seam harness. Its `seed` mode must be old-signed;
`verify` and `presence` must be new-signed. `verify` calls the actual packaged XPC service, passing the
isolated triple in the request (the service resolves it with the same rules); `presence` runs the
read-only check above against the fixture's item names and must report exactly the seeded item. Seeded
synthetic items are cleaned up outside the probe. It admits only a complete matching triple:

- `KEYKEEPER_KEYCHAIN_SERVICE=com.keykeeper.test.migration.<UUID>`
- `KEYKEEPER_DATA_DIR=<physical per-user temporary directory>/keykeeper-migration-<UUID>`
- `KEYKEEPER_TEST_SOCKET=/tmp/keykeeper-test-migration-<UUID>.sock`

A partial triple or production directory/service is rejected. Seed refuses an existing directory or item.
It creates only known synthetic contents. Verify compares locally and prints only PASS/FAIL. Never run the
production helper by itself for acceptance: without the isolated triple it intentionally selects real sources.

Build-only entry points (existing profile and certificate required; no new credentials):

```
python3 scripts/build-identity-candidate.py --profile <profile> --identity <certificate-SHA1> --output-parent <pure-local-parent> --migration-probes
python3 scripts/build-identity-candidate.py --profile <profile> --identity <certificate-SHA1> --output-parent <pure-local-parent>
```

Both reject dirty/untracked candidates, unsuitable profiles and File Provider output paths. Probe mode
creates old/new synthetic Apps. Product mode assembles a fresh bundle, signs the helper old, the outer App
new with its profile, and the CLI without the App keychain group. Normal `Resources/Info.plist`, dist,
installed App and user data are untouched.

## Evidence and limits

First namespace red→green completed before 200 business lines. Initial migration directed gate passed
16 tests, including interruption at every destination write, unknown write outcomes, replay, source changes,
missing/orphan fields, browser cookies, active proposals, unsigned/tampered metadata and file publication.
Two further acceptance cases cover unsupported local filenames and DP create/update queries; root's final
shared gate must include `IdentityMigrationTests|StorageIdentityTests` (18 tests total).

`python3 scripts/test-identity-candidate.py` passes two synthetic packaging tests (profile counterexamples
and old-helper/new-parent assembly); these do not execute codesign, Keychain or any App.

Not yet claimed: actual Developer ID/profile package acceptance, real signed private-pipe execution, new App
startup with synthetic DP stores, and two-Mac production-App synchronization. Existing transport probes
and these synthetic unit tests do not substitute for those OS/product seams. Real migration, installation,
and real-data sync retain their distinct user gates.
