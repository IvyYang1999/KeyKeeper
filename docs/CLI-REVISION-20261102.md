# CLI revision binding — frozen batch

Base: `c20d527`. Frozen before implementation; synthetic validation only.

## Current delivery

The supported new CLI obtains metadata (and requested value inventory) as one
App-verified snapshot under the vault gate. `run` retains this snapshot and its
revision across every secret/file read and authorization; `get` uses the same
path. `list`, `meta`, `run --plan` and `status --check-values` no longer combine a
raw metadata file with separately queried inventory. No fallback to raw files or
legacy wire requests when the App is old/unavailable. Ordinary `status` stays passive.

Revision consists of protocol version, a per-App-process random identity, the
content-mutation epoch and a canonical metadata digest. It is a consistency
precondition, never an authorization. Secret values/digests are not in the token.
All normal value write attempts invalidate the epoch, even if IO later fails.
Metadata digest catches metadata edits without relying on secret changes updating
the metadata HMAC. Commit/recovery already invalidates the epoch. App restart
invalidates every prior token. All secret responses and delayed approvals must
validate the original revision inside the same gate as their effects.

New `vaultSnapshot`, `revisionValue` and `revisionAuth` wire discriminators prevent
old Apps from silently ignoring new fields. Bound requests must contain a valid
revision; legacy discriminators may not smuggle one in. Stale/missing revision
errors must never trigger approval or automatic snapshot renewal. A failed run
starts no child and cleans any temporary credential files already materialized.

Before any local sync journal has been initialized, the new App preserves old
value/auth/integrity requests. Once journal initialization has happened, those
legacy serving paths fail closed (including after restart). Pending/corrupt journal
already blocks the common gate. New CLI mutating `migrate-storage` and
`--delete-legacy` are retired: refuse before fetching, opening Keychain IO or writing.
Its dry-run is read-only through the authoritative snapshot. The legacy injectable
executor may remain for historical tests, but is not exposed by the CLI.

## Explicit boundaries / user gates

Do not enable sync, install, publish, migrate real data or change system settings.
Do not implement cloud scheduling, settings/conflict UI, identity/ACL migration or
normal CRUD crash transactions. Existing approvals/inject-only rules remain in force.

An old executable can still directly read the public metadata file; an externally
authorized tool can write its own permitted Keychain items. IPC cannot revoke those
OS capabilities. This batch guarantees the supported new CLI/App protocol and
rejects legacy serving, not universal cross-process storage isolation. Production
identity migration/onboarding must retire old direct-write tools/access paths before
sync is enabled. No unsupported claim that a protocol flag alone solves that boundary.

## Bounded coverage / owners

| Required behavior | Contract / executable cases | Owner |
| --- | --- | --- |
| Shared revision schema, no secret in token | strict bounded token and snapshot models; malformed/missing/old-version fixtures | Core |
| Secret-only normal/sync change and restart reject | gate mutation epoch + instance ID; failed write invalidates | Core + App |
| Metadata/inventory consistent snapshot | actual IPC handler + temp metadata + fake Keychain | App |
| Pending and queued requests cannot cross revision | exact original token recheck before grant/read; alias preserves token | App |
| No legacy downgrade | discriminator pair checks; old App errors; journal initialized rejects legacy serving | Core + App + CLI |
| Whole run uses one snapshot | synthetic socket process tests: change between fields, zero child launch/file cleanup | CLI |
| Read-only commands use App snapshot | list/meta/plan/check-values socket fixtures; old App failure no raw-file fallback | CLI |
| Legacy migration cannot write/delete | command entry refuses before side effects; dry-run only snapshot | CLI |

Three implementation packages: shared Core contract/gate, App protocol producer,
CLI consumer. Before downstream code, the shared types must compile and pass a
synthetic encode/decode/validation slice. Every package runs a small red→green
slice before exceeding 200 new non-generated business lines. One shared SwiftPM
build at a time. After targeted gates, freeze one candidate for an independent
bounded sweep and one full regression; then commit and run the final gate.

Blockers are data loss/corruption, secrets leaked, unauthorized or wrong writes,
core unavailability, unbounded retries/resources or this explicit contract. Future
features and wider OS isolation remain recorded follow-ups.

## Accepted checkpoint — 2026-11-02

Independent bounded sweep accepted source candidate
`e781199494a2f92b18ec144c3e8d2bede34538b8` (24 changed files).
Core targeted 53 + App snapshot 1, CLI targeted 129, App/wire targeted 23
passed (overlapping sets). Frozen full regression passed 1,054 tests, with
19 existing opt-in skips and zero failures. Independent revalidation passed
62 tests (Core 24 / CLI 17 / App 21), no skips or failures.

Only this checkpoint text was added after acceptance; code and tests stayed
identical to the accepted candidate. The final post-commit regression and exact
source/log hashes are retained in the private batch receipt:
`/Users/yytyyf/Developer/keykeeper-cli-revision-ezrk0gyw.noindex/receipt.json`.

Evidence is synthetic: actual App request handlers with temporary metadata and
fake Keychain IO, plus real isolated CLI subprocesses/Unix sockets. These prove
the protocol and failure seams, not OS authorization migration or installed App
behavior. No layout changed, no real credential was read, and no App was installed.

Next production gates remain: retire legacy direct-write access during signed
identity migration; explicit HMAC bootstrap for a new/unsigned store; connect
long-lived cloud coordination, default-off settings and conflict handling; then
installation and end-to-end acceptance. Real data sync still needs separate user
confirmation. Existing two-Mac synthetic transport evidence remains reusable.

Timing evidence: contract frozen 18:29, first red 18:30, code frozen 18:43, full
gate 18:43–18:44, independent sweep completed 18:46 (Asia/Shanghai). Planning
started before the recorded contract checkpoint and was not separately timed;
there is no invented total. Implementation from freeze to candidate was about
14 minutes; first test was 80 seconds after freeze. External blocked time: zero.
One immutable candidate was accepted on its first review. Fixture/compile
corrections occurred before freeze; no verifier-driven code rework. No installed
user-visible delivery was attempted; handoff and final gate follow acceptance.
