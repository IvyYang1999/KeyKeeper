# Historical missing values — frozen acceptance envelope

Base: `43801c64cd2a31d0dfc772b846eb8d579437c6e8`. User selected preserving all
records while permitting complete values to synchronize. Real sync remains Off.
Artifacts: `/Users/yytyyf/Developer/keykeeper-missing-sync-20261104.noindex`.

## Current deliverables and contract

1. A readable, verified local metadata/blob pair may contain a declared secret field
   with no stored value. Capture preserves its metadata and explicitly marks the
   missing field; it never invents an empty value or drops the record. Denied reads,
   missing initialized blob, invalid signature, unknown data or corruption still fail
   closed, including a missing entire blob with declared secrets even if storeInitialized
   is absent/false. Orphan recovery values stay local and protected by the existing adapter.
2. `CloudCredentialBundle.missingSecretFields: [String] = []` is sorted/unique;
   secret keys and missing fields are disjoint and their union exactly equals the
   metadata's secret fields. Missing markers for plaintext/unknown fields are invalid.
   Complete bundles omit the field entirely, retaining exact v1 encoding. A snapshot
   containing any missing marker uses version 2; otherwise v1. Decode validates exact
   canonical bytes. Old v1 clients reject v2 before effects. Existing v1 pending/base/
   transition bytes must continue decoding and re-encoding identically.
3. Missing means unavailable, not deletion. Only when the entire credential metadata
   is equal may a missing field be completed from the opposite current snapshot.
   Never restore from the historical base. Existing present/present differences and
   metadata conflicts retain three-way review. Neither automatic merge nor explicit
   choice may replace an opposite present value with a missing marker; unsafe choices
   are disabled and rejected in Core. Explicit group/field deletion remains distinct
   and uses existing merge/review semantics. Apply independently rejects present-to-
   missing replacement while the secret field is still declared.
4. `CloudSyncStatus` exposes optional `missingCredentialCount` and `missingFieldCount`
   from successful existing captures/applies only; nil means not checked. Conflict
   rows expose `canChooseLocal/Remote` (default true), derived by the same Core merge
   guard. No values enter status/UI/IPC. Add errors `localDataUnavailable` and
   `unsupportedSnapshotVersion`; local storage/invalid snapshot failures must not be
   shown as network failures. Sync state stays default-off, and no new background read
   is added for counts.
5. Settings explains missing records are preserved and available values synchronize;
   unsafe conflict choices cannot be submitted; enable copy tells users to update
   all Macs for missing-value support. Existing list/CLI presence checks remain valid.
6. Synthetic production-seam acceptance covers mixed complete/incomplete data, another
   local store, durable reload, missing-to-present repair, grants remaining device-local,
   old-version rejection and no data loss. Real cloud transport/schema is unchanged;
   this batch does not repeat two-device/native transport tests or use real secrets.

## Coverage and ownership

| Explicit requirement | Field / executable boundary | Owner |
| --- | --- | --- |
| Explicit absence, exact legacy codec, v2 rejection | missingSecretFields / snapshot codec counterexamples | Root |
| No overwrite, deletion distinct, safe resolution | merge + canChoose / symmetric base and no-base tests | Root |
| Capture complete and missing records, guarded apply/recovery | actual adapter + journal + fake keychain tests | Local adapter builder |
| No extra read, count/error/review contract | coordinator/status / production runtime integration | Root + App builder |
| Visible missing state and disabled choices | presentation, card, locale, offscreen render | App builder |
| Signed deliverable retains accepted startup/installed behavior | source review, package preflight/manifest/notary | Root + independent verifier |

Core and App are separate packages sharing the above contract. Root alone owns SwiftPM
commands. Before dependent implementations, compile the first codec slice and execute
its v1/v2 synthetic boundary; do not accumulate untested implementation. Builders may
write disjoint files once notified, then Root runs their targeted gates sequentially.

## Not this batch / gates / closure

No real sync activation, migration, credential recovery/deletion, production-cloud writes,
new account permission, system settings, main merge, push or public release. No redesign
of merge policy outside missing markers, ordinary CRUD atomicity, or CLI version labeling.
Any installed update follows standing installation authorization and preflight/atomic
swap/rollback rules; no real data operation is implied. Real sync requires separate approval.

Blockers: data loss/corruption, secret/privacy leak, wrong or unauthorized effects,
core unusability, retry/resource storms, existing compatibility regressions, or violations
of the explicit requirements above. Further improvements are known limits, not blockers.

Close mechanically: first red → codec slice green → independent disjoint implementation
and targeted tests → freeze candidate → one bounded independent sweep → one full regression
and affected isolated seam → signed/pinned app package and exact archive verification.
Reuse unchanged native/cross-Mac evidence with its stated limits. Do not pretend a fixture
or the previous version proves the new real two-Mac App installation.
