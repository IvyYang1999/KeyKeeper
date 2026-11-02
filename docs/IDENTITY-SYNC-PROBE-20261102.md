# dev.keykeeper.app — synthetic migration and sync acceptance

Status: active; production identity and storage are unchanged.

## Frozen scope

User chose the new main App ID `dev.keykeeper.app` on 2026-11-02. Register it in the
existing team, associate dedicated `iCloud.dev.keykeeper.app`, and obtain a Developer
ID profile using an existing certificate. Validate the migration and encrypted sync
with synthetic credentials before any production identity switch or real-data opt-in.

This batch delivers a reusable backend/probe, not a production migration UI or release.
Do not edit the shipping Info.plist identity, install over KeyKeeper, migrate/inspect
real values, expand real Keychain ACLs, transfer caller grants, or publish an update.
The existing CloudVaultSnapshot/three-way merge is reused, not replaced.

## Required checks and ownership

| Requirement | Contract / evidence | Owner |
| --- | --- | --- |
| New identity is usable | Portal registration + decoded profile grants match app/container/team; signed isolated executable launches | Root |
| Old data remains recoverable | Old-signed process creates isolated synthetic Keychain source; source readback and metadata bytes unchanged after transfer | Migration probe |
| Identity boundary is real | New-signed consumer first tries old item with interaction forbidden; handles denied/missing distinctly; controlled private pipe and signature checks transfer only synthetic bundle | Migration probe |
| Missing integrity key cannot become success | Missing/denied synthetic HMAC evidence fails migration, zero destination writes | Migration probe |
| Values and metadata stay together | Existing validated bounded snapshot; authenticated AES-GCM envelope binds account/container/environment/vault/key ID | Crypto core |
| No plaintext or grants in cloud | Private custom UUID test zone, encrypted Data record only; local ACL/grants are excluded | Root + crypto core |
| Real cloud lifecycle | Profile-authorized environment; bounded single operation/deadline; explicit errors, no blind retries; immutable key IDs and create-only/CAS head | Root |
| Real cross-device sync | Same Apple account on two real Macs; independent local Keychain state, fake value/metadata A→B→A and local authorization evidence | Root + second Mac |

No mock or two processes on one Mac counts as two-device acceptance. If the second
Mac is unavailable, retain this candidate and label only that gate `waiting_sample`.
CloudKit creation may precede iCloud Keychain arrival: missing selected key means wait,
never generate a replacement or treat the vault as empty. Account changes invalidate
in-flight commits. Conflicts retain both versions and fail before any overwrite.

## Mechanical closeout

1. Register/configure/download and inspect the profile before signing probes.
2. First meaningful red test, then smallest compiled slice (before 200 new business lines).
3. Targeted tests during implementation; no real-data or foreground UI fallback.
4. Freeze candidate for one independent bounded review; fix all current blockers together.
5. Run one final complete existing regression gate and the signed synthetic probes.
6. Produce the second-Mac package/instructions and report each gate separately.

Blockers are data loss/corruption, secret leakage, wrong/unauthorized writes, unbounded
operations, core failure, or a direct violation of this frozen contract. No complete
production migration/installation claim is allowed from these probe results.

## Known production follow-ups

- Audit and harden MetaStore's missing/denied integrity-key handling before any identity
  cutover: errors must not be downgraded to unsigned metadata or permit MAC-less writes.
- Explicit migration admission before launch maintenance, UserDefaults domain migration,
  complete local auxiliary-store compatibility and real Sparkle identity transition.
- Production sync settings, local recovery commit journal, CRUD/pending-approval wiring,
  conflict UI and separate real-data opt-in remain required before shipping.

## Portal checkpoint

- 2026-11-02: `dev.keykeeper.app` successfully registered in the existing team, iCloud
  with CloudKit enabled. Dedicated `iCloud.dev.keykeeper.app` is associated. Developer
  ID profile downloaded and decoded: exact App ID/container, Production environment,
  team wildcard Keychain group and certificate matching the existing local identity.
  No certificate was created, exported or revoked. Production installation is unchanged.

## Verified checkpoints — 2026-11-02

- Real Developer ID signed old/new identity probe passed. Direct new-identity access to
  the old synthetic item was denied (`errSecAuthFailed`, -25293); authenticated private
  pipe transfer succeeded. Destination readback matched; old source, integrity key and
  metadata bytes remained unchanged; replay produced no additional write; grants=0.
- Synthetic migration rejection tests passed: missing/denied HMAC, invalid/truncated
  snapshot, missing secret field, mismatched MAC, conflicting destination and replay.
  Real create-only metadata and existing physical-directory admission regressions pass.
- Signed CloudKit status passed in Production. No account identifier was logged.
- `KeyKeeperSyntheticHead` schema was deployed only in the new dedicated container:
  `vaultID`, `keyID`, `revisionID` strings and `ciphertext` bytes. Default world-read
  access was removed for this new type. The probe uses only the private database.
- Real one-Mac CloudKit roundtrip passed: seed; read from a separate empty local
  directory with an expected snapshot digest; advance both random fake value and note;
  read the new revision/digest from that other directory. The two digests differ. This
  demonstrates actual encrypted server write/readback, not two-Mac key propagation.
- Account-change fault injection passed at submit, Keychain creation and confirmation
  boundaries; old callbacks cannot confirm, pending bytes remain, and deadline
  cancellation is independent of a blocked native effect. Independent review accepted.
- Complete `swift test --disable-keychain` passed: 932 tests, 18 skipped, zero failures.
  The existing opt-in GUI/WebKit gates were left disabled; this batch changes no UI.
- Second-Mac propagation remains `waiting_sample`. User confirmed that an Apple Silicon
  Mac is available and will run the prepared test package. No source state or root key
  is included in that package. Source/signed probes and synthetic source items remain.
