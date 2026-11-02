# Optional iCloud sync product closeout — frozen envelope

Base `e84eb66`. 2026-11-02, synthetic-only implementation and acceptance.
User asks to finish optional secrets + metadata sync, with per-Mac caller approval
and preservation of existing data. Prior transport and local-commit evidence is reused.

## Must deliver in this candidate

- Real production wiring for a lazy, default-off cloud coordinator, settings/status,
  explicit enable, disable retaining data, one-shot retry, conflict review and explicit choices.
- Each run captures exact local revision before awaits, merges against durable last-common
  base, refuses conflicting/stale changes, commits locally through the accepted journal,
  stages a durable pending publication before one CAS upload, reads back before advancing base.
- Uncertain uploads retain pending; automatic retry only reads back. Explicit user retry
  first reads the current head, uses the same publication identity and conditional CAS.
  Single native operation ownership remains until completion; late callbacks after off or
  account change cannot apply local data or advance state. No retry/resource storm.
- Account-bound AES-GCM snapshots in CloudKit, immutable random-ID roots in synchronizable
  access-group Keychain, local base/pending in nonsynchronizable protected Keychain.
  No cloud client, reads or writes before opt-in; missing data/keys are errors, never emptiness.
- New signed identity dev.keykeeper.app uses independent local directory and DP access-group
  nonsynchronizable values. Legacy/test behavior unchanged. Old direct writers can only touch
  retained old storage; new App requires bound CLI messages from its first ready launch.
- User-confirmed, strict read-only old-identity helper/private pipe migration. Preserve complete
  raw value blob (including orphan and missing fields), verified metadata, relevant local
  auxiliary data. Fresh destination HMAC and empty enforced caller grants. Active imports block
  migration; unsupported local material blocks rather than silently disappearing. Sources never
  changed/deleted. Create-only/replay-safe target with recovery receipt and readback. No service
  restore/maintenance/secret serving before target admission. Explicit fresh-store bootstrap.
- Opt-in signed packaging path with correct helper identity/profile/entitlements, without
  switching current production installation. SDKs remain CLI wrappers.

## Not in this candidate / user gates

Do not enable real sync, read/migrate real credentials, install, publish, push, merge main,
change system settings, revoke old ACLs or delete originals. Sign/build synthetic artifacts
only after source/package validation; real OS focus or install needs its specific user gate.
Actual two-Mac production-app acceptance may remain waiting_sample with a concrete test package;
existing probe evidence does not masquerade as that new product evidence. iOS, sharing,
automatic grant transfer, browser-session cloud sync and normal CRUD crash rewrites are excluded.

## Coverage / ownership

| Requirement | Executable boundary | Owner |
| --- | --- | --- |
| Lazy/off, durable base/pending, CAS/readback, late callbacks | fake transport/state plus lifecycle failure tests | Coordinator |
| Local network-await lost-update protection | revision-bound capture/apply on real local commit adapter | Root |
| Account + ciphertext + key + record binding | production CloudKit adapter parser/fence/query fixtures | Root |
| Old writers cannot touch new vault; source preservation | namespace/query and migration interruption/replay tests | Identity |
| Actual production readiness before services | App startup/migration model and root factory seam | Root |
| Explicit enable/off/review, no secret rendering | presentational actions + model integration + background renders | UI + Root |
| Profile/helper/source packaging identity | opt-in script preflights and synthetic package inspection | Identity + Root |

Coordinator first freezes/compiles shared types with a minimal red→green test; downstream
adapters use those exact types. Identity and UI are independent file packages. One SwiftPM
process at a time. Each first vertical slice compiled before 200 new business lines.
Identity spans Core/tools/distribution as a deliberate exception: all three implement one
source→target trust boundary; extra migration/namespace/package counterexamples are required.
Root integration owns App wiring plus Core transport/local adapter, with independent verifier.

Only data loss/corruption, secret disclosure, unauthorized/wrong writes, core unavailability,
unbounded resource/retry behavior and violations above block acceptance. Other improvements
are follow-ups. Freeze immutable source candidate, bounded independent aggregate sweep, one
full regression, commit, final gate, source/log hashes and handoff. No moving-tree verifier loop.
