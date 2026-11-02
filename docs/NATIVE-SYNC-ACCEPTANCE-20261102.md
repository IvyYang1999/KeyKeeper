# Native sync acceptance — frozen batch 2026-11-02

Base: `2cf4bd4be4225e44c865825a1fa6d8928560ab60`, branch `codex/optional-icloud-sync`.
Artifacts: `/Users/yytyyf/Developer/keykeeper-native-acceptance-zrcwtvm_.noindex`.

## Must deliver

1. Configure `KeyKeeperVault` schema (vaultID/keyID/revisionID String, ciphertext Bytes) in the already authorized container and Production; no public access. If Apple login is unavailable, record an external gate, not a code failure.
2. An opt-in signed synthetic acceptance executable reusing the actual Core coordinator, durable local transaction/state, new-identity DP Keychain and native CloudKit adapter. Random run UUID isolates every local service, marker/directory, cloud zone and synchronization root. Missing/invalid isolation fails before IO. Normal product has no test entry point and retains its fixed production scope.
3. Verify default-off, explicit enable, secret+metadata readback, restart/reload, conditional update/conflict, disable and device-local grants with synthetic data. Native server change tags must pass the real archive/restore code. Bounded operations; uncertain upload never causes blind retry.
4. Prepare an Apple-silicon test package for Mac A seed → Mac B read/advance → Mac A verification. Bind source, executable, script and expected synthetic-state digests. Do not package keys or local sync state. Actual second-Mac evidence is `waiting_sample` until returned.

Frozen API before implementation: `CloudKitSyncTransport(identity:)` remains production-only; acceptance builds alone expose `init(identity:acceptanceRunID:UUID)`. `CloudSyncAcceptanceStores.open(runID:UUID, clientID:UUID, initializeIfAbsent:Bool)` derives fixed test paths/services from both IDs. Cloud zone/root use runID only; separate clientIDs allow two local clients without overlapping local state. Scope is checked against CKRecord system fields, preserving existing token encoding. Both IDs are mandatory. No environment-based identity fallback. Acceptance executable has a 180-second process deadline; the runner does not retry.

## Not this batch

No real credential reads/migration/sync, installed App replacement, public release, main merge, system setting changes, cleanup of old test items, or full-App native foreground/IPC acceptance. Existing signed migration-helper evidence and 1132-test suite remain valid for unchanged code. This executable proves the named production Core/native seams, not the entire App lifecycle/UI.

## Blocking risks and gates

Only data loss/corruption, secret/privacy leaks, unauthorized or wrong writes, unusable core path, unbounded native requests/retries/resources, compatibility regressions, or violations above can block this batch. Full-App UI and real migration remain separate existing gates. Apple login and the second Mac require user participation; real data synchronization remains separately confirmed.

## Coverage / owners

| Requirement | Contract / evidence | Owner |
|---|---|---|
| Exact schema, private-only | Portal field/role readback; native record accepted | Root |
| Native scope isolation | Typed run UUID; cross-scope record/token/root rejection; normal build unchanged | Core builder |
| All local IO is new-identity and isolated | Explicit `.current`, fixed UUID-derived directory/services, negative admission tests | Tool builder + verifier |
| Actual coordinator/local/state/native chain | Signed seed/read/advance/verify and storage readback | Tool builder; Root runs |
| Bounded and no unattended replay | Existing native fence + process deadline; no polling/retry loop | Tool builder + Root |
| Cross-device evidence | Artifact digests and expected synthetic digest, no local state copied | Root / user second Mac |

## Mechanical closeout

First targeted compile/test before expanding each vertical slice. One SwiftPM owner at a time. Freeze source + hashes; independent bounded review returns aggregated ACCEPTED or all blockers. Run affected tests, then one whole-suite gate on frozen code; commit with inactive hooks verified and final integration gate. Build/sign in separate scratch directory, validate profile/signature and package manifest, run bounded synthetic seam only after namespace review, notarize test bundle with existing authorized credentials, then hand off concrete second-Mac instructions. Preserve failures; no production fallback or repeated upload after uncertain result.
