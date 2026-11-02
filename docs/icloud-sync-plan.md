# Optional iCloud sync — acceptance envelope

Status: implementation in progress; not shipped or enabled. Base: `b0fe0a1`.

2026-11-02 update: the user chose `dev.keykeeper.app`. Its App ID, dedicated CloudKit
container and matching Developer ID profile are registered. The current synthetic-only
batch is frozen in `IDENTITY-SYNC-PROBE-20261102.md`; it does not change the installed
app or turn on real-data sync. Earlier portal failures below are historical evidence.

## User contract (2026-10-29)

- Opt in, off by default. Synchronize credential values and metadata together.
- Each Mac confirms its own callers. Never synchronize approvals, approval settings,
  audit logs, website sessions, pending imports, or machine-local signing identities.
- Preserve existing data. Missing, unreadable, incomplete, or corrupt data is an error,
  never an empty vault. No silent last-writer-wins conflict resolution.
- Disabling sync retains the local vault and does not delete another device's data.

## Implementation boundaries

Three sequential slices avoid changing storage, App UI, and distribution simultaneously:

1. Pure, bounded snapshot contract and three-way merge: metadata and secret fields
   form one validated bundle; edits/deletions compared against the last common base.
   Divergent changes remain explicit conflicts, independent changes can merge.
2. Provisioned Apple transport and recoverable local commit: account-bound encrypted
   snapshots, compare-and-swap cloud writes, local encrypted recovery journal, fail
   closed during incomplete commits. Original storage remains recoverable. Integrate
   actual CRUD, pending authorization, local grants, and metadata integrity seams.
3. Off-by-default settings, native confirmation, status/conflict/recovery UI, signed
   packaging, isolated end-to-end tests, then two-Mac synthetic-data acceptance.

The current app has no data-protection-keychain access-group entitlements or embedded
provisioning profile. Apple TN3137 requires a profile authorizing these entitlements.
Developer-account capability/profile changes need user approval; real-data opt-in is
a separate user action. Do not claim two-device sync based on mocks or a local readback.

Transport selection must close account-change and conflict guarantees before wiring
production. A single synchronizable mutable Keychain blob is NOT a safe multi-writer
database. Do not put plaintext snapshots in iCloud Drive or a local backup file.

## Coverage / acceptance mapping

| Must deliver | Contract / validation | Owner |
| --- | --- | --- |
| Values and metadata together | Exact secret-field set, no secret values inside metadata; bounded codec | Core |
| No data loss on conflicting edits | Base/local/remote comparison; delete-vs-edit and both arrival orders | Core |
| No cross-Mac grants | Explicit export schema excludes grants; import invalidates changed-item grants and pending requests | Core + App |
| No account crossover | Account-bound state, sign-out/change stops writes until explicit confirmation | Transport |
| Safe existing-data migration | Verified encrypted checkpoint and recoverable commit before new state is exposed | Storage |
| Optional, default off | No transport creation/reads/writes until consent; disable keeps local data | App |
| Actually works across Macs | Provisioned signed build, synthetic secret + metadata round-trip and per-Mac approval | Distribution + real-device acceptance |

Allowed blockers: data loss/corruption, secret leakage, unauthorized/wrong writes,
core unavailability, unbounded retries/resources, or direct failure of this contract.
Excluded: sharing with other Apple Accounts, iOS/watchOS, syncing browser sessions,
automatic grant transfer, publishing a release, enabling real-data sync without consent.

## Mechanical closeout

First red tests, then a small compiled slice. Run affected tests while implementing.
Freeze candidate before one bounded regression sweep; aggregate blockers. Integrate,
then one final gate. Use only synthetic values. Visual fixtures prove rendering only,
not cloud transport or production storage. Two-Mac evidence is `waiting_sample` until
the actual second device is available. Never substitute a mock for that acceptance.

Sources checked: Apple TN3137 (Mac keychains); Security `kSecAttrSynchronizable`;
CloudKit `CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged`.

## Checkpoint — 2026-10-29 12:18 Asia/Shanghai

- Pure snapshot/merge slice implemented in `CloudVaultSnapshot.swift`; 12 new synthetic
  tests cover bundled values/metadata, missing and orphan fields, metadata-only vs value
  conflicts, deletion in both orders, initial pairing, alias collisions, idempotence,
  unknown schema/fields, bounded payloads, and redacted ordinary debug descriptions.
- `swift test --disable-keychain --filter
  'CloudVaultSnapshotTests|KeychainBlobStoreTests|MetaStoreTests|ApprovalStoreTests'`:
  **54 tests, 0 failures**. No real Keychain IO, UI, or cloud transport used by this slice.
- First targeted compilation failed before the new contract types existed; first
  implemented slice then passed 7 tests, followed by the expanded 54-test check above.
- No production wiring, migration, cloud adapter, encryption transport, settings switch,
  entitlement/profile change, installation, or two-device test has been completed.
  This is NOT acceptance of the complete user feature. Do not expose the codec as IPC,
  put its plaintext output in files, or enable automatic migration from this checkpoint.
- User approved Apple Developer capability/profile configuration on 2026-10-29;
  actual secret syncing remains a separate opt-in. The official Developer Identifiers
  page redirected to Apple sign-in; awaiting user login/MFA before any portal mutation.
  Confirmed the installed app's bundle ID/team match the existing release; no certificate,
  identifier, capability, profile, or installed app has been changed.
  Source changes are only in the pure-local
  `codex/optional-icloud-sync` worktree; main and the installed 0.3.6 are unchanged.

## Portal checkpoint — 2026-10-29

- User completed Apple Developer login in Chrome and explicitly approved registering
  `com.keykeeper.app` with iCloud/CloudKit, a dedicated `iCloud.com.keykeeper.app`
  container, and a Developer ID profile reusing the existing signing certificate.
  Real-data synchronization is still NOT approved.
- The first submission returned session-expired. A fresh identifier listing showed
  no KeyKeeper entry. A new form in the refreshed session then returned:
  `An App ID with Identifier 'com.keykeeper.app' is not available. Please enter a different string.`
- Re-read the current team's App IDs and all-platform/all-type profiles: no matching
  App ID or profile exists there. No App ID, container, profile, or certificate change
  has been confirmed. Do not repeat registration without a relevant state change.
- Blocker: the existing bundle identifier cannot currently be provisioned in this
  team. The portal does not disclose whether another team owns it or it is reserved.
  Do not silently change the main app's bundle identifier, reuse another product's
  profile, or treat ordinary Developer ID signing as proof of registered App ID ownership.
  Resolve ownership with the user/Apple, or separately approve a compatible identity
  migration/isolated sync-helper design before continuing portal mutations.

### Read-only ownership investigation

- Developer portal account menu exposes only the existing team. Local Xcode preferences
  contain one account record and one paid individual team, matching the installed app.
  These are current/local observations, not proof about all historical accounts/devices.
- Decoded 9 local provisioning profiles in Xcode's current profile directory: all are
  from that same team; none matches KeyKeeper by profile name or application identifier.
  No private key, account token, or device identifier was read out or changed.
- Git history introduces `com.keykeeper.app` as a literal in the original bundle script
  (`9c694d3`, 2026-02-28). Current installed 0.3.6 uses the expected Developer ID team,
  but that signature does not establish Apple App ID registration/ownership.
- Apple's TN3125 confirms that a Mac app without restricted entitlements does not need
  a provisioning profile. Adding restricted entitlements changes that requirement.
  Source: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Apple's public US storefront lookup returned no published app for this bundle ID.
  This does not establish availability or rule out unpublished/reserved identifiers.
- App Store Connect's authenticated UI requires accepting its Terms of Service before
  showing apps. Acceptance was not authorized/performed; its app list remains unchecked.
- Result: no evidence of an alternate owner controlled by this user was found in the
  inspected sources. Apple must resolve any historical-account/reservation ambiguity;
  do not characterize the unavailable identifier as confirmed third-party ownership.

### User-requested retry — 2026-11-02 Asia/Shanghai

- After the 2026-10-31 login-page stall, the user completed a fresh Chrome login on
  November 2. Verified the expected team and no KeyKeeper entry in its App ID list.
- A new form used the unchanged `com.keykeeper.app`, description `KeyKeeper`, and
  iCloud with CloudKit support. The confirmation page showed those exact selections;
  In-App Purchase was Apple's disabled, default selection. No other capability was enabled.
- Submitted once under the previously approved scope. Apple again returned exactly:
  `An App ID with Identifier 'com.keykeeper.app' is not available. Please enter a different string.`
  This attempt was not rejected for an expired session. No successful external
  configuration change, installation, or real-data synchronization occurred.
- Current blocker remains identifier availability. Do not silently switch identity
  or repeat the same submission; request Apple's ownership/reservation investigation,
  or separately agree a compatible alternative before new portal mutations.
