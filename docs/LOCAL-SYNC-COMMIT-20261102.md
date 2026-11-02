# Recoverable local sync apply — frozen batch

Parent: `03cfd4e`. Status: frozen before implementation.

## Deliver / exclude

Deliver the local apply/recovery backend for a validated sync snapshot, using the
actual metadata file and Keychain IO seams. The dedicated journal lives in the
macOS Keychain (OS-encrypted at rest), never in a plaintext file or cloud payload.
Before/after raw metadata/value images preserve recovery evidence. Changed local
credential grants are invalidated before new data becomes available; grants are
never restored from an old approval-document backup.

Existing CRUD is not rewritten into this transaction format. It must share an
outer operation gate with the new apply/recovery path, so no ordinary operation
observes half a commit or writes into one. Startup recovery runs after exclusive
IPC endpoint acquisition and before import restoration or launch maintenance.

Do not enable cloud sync, add a toggle, migrate real data, switch identity, install,
publish, or alter the accepted CloudKit probe. No GUI redesign. All validation is
synthetic. Native Keychain operations are synchronous and bounded by one attempt;
there is no retry loop or new native authorization probe.

This batch does NOT claim that a multi-request CLI command sees one revision:
the current CLI can read plain metadata before a completed commit and secrets
after it. Revision binding/batched reads (including old-client fail-closed policy)
is a required subsequent package BEFORE any production cloud sync is enabled.

## Frozen boundaries

- A journal transaction has a business UUID, namespace binding, exact before/after
  images and computed changed credential IDs. Transport IDs do not define identity.
- One persistent journal plus a non-secret initialized marker; missing journal
  after initialization, corruption, denied IO or an uncertain write blocks access.
- Write-ahead preparation must read back exactly before touching existing data.
  Revoke affected grants, install values, install signed metadata, verify both,
  then mark completion. Recovery only rolls forward; it never restores old grants.
- At recovery each resource must match its recorded before or after bytes. A third
  state is a conflict and is never overwritten. IO errors are checked by readback,
  not blind retry. Repeated recovery/completed replay is idempotent.
- A single recursive gate precedes all store locks. Whole normal mutations and
  IPC decision→read→noteUse share it. Transaction/recovery advances a local epoch;
  queued approvals/reads with an older epoch cannot issue grants or return values.
- Local apply requires enforced caller approval mode. It does not silently change
  a user's permissive setting or allow imported values to bypass local approval.
- Incomplete local metadata/value inventory blocks sync apply without destroying
  historical recovery evidence; ordinary healthy-credential edits still work.
- Plan preparation requires already signed local metadata and an existing integrity
  key. It never bootstraps a key or signs the old file outside the journal. Ordinary
  legacy CRUD bootstrap remains unchanged; first-use sync onboarding must handle
  this explicit prerequisite before exposing the production sync switch.

## Coverage / owners

| Current requirement | Boundary / executable validation | Owner |
| --- | --- | --- |
| Journal never plaintext; bound, bounded, strict schema | Keychain journal codec, marker and denied/malformed/missing cases | Journal builder |
| Crash/uncertain writes recover | Fault before/after each write; recreate coordinator; second recovery zero effects | Journal builder |
| No stale/duplicate overwrite | Business-ID/content mismatch, stale expected image, before/after/third-state cases | Journal builder + adapter |
| Actual values + signed metadata apply | Production adapter with real temporary metadata files and fake Keychain IO | Root |
| Grants never resurrect; permissive mode refuses | Actual ApprovalStore revocation and readback tests; unaffected grants/audit retained | Root |
| Ordinary reads/writes exclude pending commit | Shared gate + production stores + CRUD entry points, latch concurrency | Gate builder |
| Old approvals cannot authorize rotated secret | Epoch captured at request and rechecked under gate in UI/queued completion | Root |
| Recovery precedes startup effects | IPC ownership → recovery → imports/maintenance; duplicate zero recovery | Root |

Core journal/engine, shared gate/CRUD integration, and App orchestration are
separate packages. Freeze their interfaces and exercise a synthetic producer→
consumer slice before expanding integration. No external manifest system is
introduced; immutable Git candidates and targeted regression logs bind evidence.

## Closeout

First meaningful red test, minimal compiled slice (<200 new business lines before
first test), then affected gates. Freeze once, independent aggregate sweep, repair
only contract/data/security/compatibility blockers, full regression once and final
post-integration gate once. Existing cross-Mac probe evidence is unchanged.

Allowed blockers: loss/corruption, secret leakage, unauthorized/wrong writes,
core unavailability, unbounded resources/retries or explicit contract failure.
Future full-cloud scheduling, account pairing, conflict choices, CLI revision
binding and normal-CRUD crash atomicity remain follow-ups, not this batch's scope.

## Accepted backend checkpoint — 2026-11-02

- Independent bounded sweep: **ACCEPTED** for immutable candidate tree
  `4d9d9ff68ba2d9026101be6f8bca8cee9fb40bf3` (before this documentation closeout).
- Targeted journal/engine 22 tests; gate/stores/CRUD/IPC 132 tests; final adapter,
  startup and exact-grant integration 24 tests, all passed. Independent recheck:
  54 tests passed. Some sets overlap and must not be added as distinct coverage.
- Full frozen-candidate regression: Core 409 (4 skipped), CLI 115, App 490 (15
  skipped): **1,014 tests, 19 existing opt-in skips, zero failures**.
- The first adapter integration run caught a test comparing an in-memory Date to
  the persisted ISO8601 representation. The corrected assertion compares the
  stored unrelated approval before/after, preserving the actual invariance check.
- Evidence and file digests are retained in the private local directory
  `/Users/yytyyf/Developer/keykeeper-local-commit-2r4cj4n6.noindex/`.
- No real vault/Keychain contents, cloud state, installed application, production
  identity, main branch or remote release were changed by this batch.

Next production-enablement package MUST cover raw CLI metadata reads even while a
local transaction is pending, whole-command revision/batched reads and old-client
fail-closed behavior. It must also audit `migrate-storage`'s direct BlobStore writes.
The current gate is an App-process boundary, not a claim of cross-process isolation.
Runtime recovery must reload caches even when `recover()` returns an empty affected
ID list: a previous completion write may have succeeded before its readback failed.
Startup naturally reconstructs those caches; no runtime recovery UI is exposed yet.
