# Sync prerequisite: production storage admission

Status: ACCEPTED for this production storage admission batch. Parent: `3db2682`.

## Acceptance envelope

The user asked to continue after the two-Mac synthetic proof. The next prerequisite
is production data protection, before a sync toggle or identity cutover. A toggle
cannot safely use the probe: current CRUD writes values and metadata separately,
and has no recoverable commit or shared synchronization barrier.

This batch delivers strict metadata integrity admission at existing production
read/write seams, startup maintenance and approval completion. It preserves the
legacy unsigned-file upgrade and explicit owner-confirmed metadata review.

Do not change the shipping bundle identity, install or publish, read/migrate real
vault contents, enable CloudKit, or offer an inert sync toggle. Recoverable local
transactions, cloud integration, conflict UI and real-data opt-in are subsequent
packages. This batch does not claim atomic CRUD after a mid-operation IO failure.

## Interface and coverage freeze

`MetaStore.load()` remains the raw decoder for CLI metadata and explicit review.
`loadForUse()` returns the verified metadata from one read; `prepareForMutation()`
checks before any value mutation. Both are requirements on `MetaStoring`, with
raw-load defaults for injected legacy test stores. Production overrides are strict.
Read-only admission must be non-interactive and cannot create a key or sign a file.
For genuine unsigned legacy data, mutation preparation may establish the first
signature before values change; a failed bootstrap must stop value changes.
Normal save cannot bless tampering or recreate a missing signed-file key. Explicit
`trustCurrentMetadata()` is separate and cannot bypass an unavailable integrity key.

| Current required outcome | Contract / validator | Owner |
| --- | --- | --- |
| Denied, missing signed-file key, malformed key never becomes unsigned | Core MetaStore/MetaIntegrity; original file/key bytes and zero-write assertions | Core builder |
| Real unsigned legacy data and fresh empty store still work | v0.3.3 fixture and first-signature tests | Core + integration |
| No value mutation before admission | Add/Detail/List, clipboard/env import, MetadataEditor; injected key failure with value counters | CRUD builder + Core |
| No launch maintenance or pending-import restoration on failed admission | Production launch/IPC seams; legacy files, grants and journals unchanged | Root |
| IPC and delayed approvals fail closed | Same trusted snapshot; errors cause no value read, grant or pending request | Root |
| Failure is distinguishable from an empty list | Production ViewModel, retained last-known rows, existing error view background smoke | CRUD builder + Root |
| Original production state remains unchanged | No installation, identity or CloudKit changes; clean isolated test parameters | Root |

Core and App are split into disjoint packages. Core first compiles/tests the frozen
API against synthetic input, then downstream App builders consume that interface.
No new external manifest/attestation system is required by this batch.

## Allowed blockers and closeout

Only data loss/corruption, secret leakage, unauthorized/wrong writes, core
unavailability, unbounded retries/resources, compatibility regression or failure of
the table above may block. Future completeness or elegance is a follow-up.

Write regression tests before fixes. First Core slice below 200 business lines;
run affected tests per package, freeze candidate, independent bounded aggregate
review, fix blockers as one group, then full regression and final integration gate.
UI evidence uses synthetic data in background and is not evidence of cloud syncing.
Keep validated prior two-Mac evidence; do not re-run that unchanged transport.

## Accepted evidence

- First Core red tests reproduced permission-error downgrading, signed-key
  recreation and malformed-key acceptance (3 tests, 12 failing assertions).
- First App red test proved unavailable integrity could still save a new value
  and report success. Root IPC/launch red tests proved a secret read and launch
  inventory access still occurred after integrity failure.
- Core targeted gate: 48 passed. CRUD/import targeted gate: 138 passed. IPC,
  startup, delayed-approval and legacy-upgrade targeted gate: 35 passed.
- Full candidate regression: 960 tests, 19 opt-in skips, zero failures.
- Independent verifier accepted immutable tree
  `30e6654244a563814bacbfa82a557faed0abe2d8`, verified unchanged before/after
  its bounded sweep and independently reran 27 targeted tests successfully.
- Background synthetic App ViewModel/notice/row rendering passed in Chinese and
  English, light/dark and 320/460-point widths. A real metadata file with a fake
  Keychain transitioned healthy → missing integrity key → restored key; the row
  remained, the notice appeared and disappeared. Screenshots were inspected.
  This is offscreen component evidence, not a foreground full-window interaction
  or real Keychain/iCloud acceptance claim.
- Shipping identity, installed app, main branch and real vault are unchanged.

## Known limits and next package

- Startup-blocked browser import recovery currently requires an App restart after
  access is restored. The list retry refreshes only its own model. Do not advertise
  that button as resuming every suspended subsystem.
- The unsigned compatibility path requires both no recorded MAC and no stored
  integrity key. A future identity cutover needs its own migration admission; this
  change alone is not permission to treat an inaccessible old identity as a new vault.
- Preflight cannot guarantee atomicity when IO fails after the first value change.
  Next: a recoverable encrypted local transaction for values + metadata, coordinated
  with local grants and pending approvals; then production cloud sync and its UI.
- No settings toggle, new identity installation, release or real-data opt-in was
  performed in this batch. Existing synthetic cross-Mac transport evidence remains valid.
