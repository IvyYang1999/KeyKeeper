# Credential files — batch contract (2026-09-11)

## Acceptance envelope

Deliver a local macOS service-account JSON vertical slice: App-owned, explicit-confirmation
import from a file path or native chooser; protected storage with typed metadata; explicit
runtime file mapping; bounded private temporary files with exit/crash cleanup; safe UI and
skill instructions. Preserve existing text credentials, grants, missing-store protections,
and downloaded originals. No overwrite, rotation, export, arbitrary binary files, cloud
sync, public release or restoration of deployment hooks in this batch.

Only data loss, secret exposure, unauthorized/wrong writes, startup/core failure, unbounded
resources, existing regressions or violation of this contract block acceptance. Real-key
save/read approval and provider login remain user gates. Tests use synthetic documents only.

| Required behavior | Contract / implementation | Verification |
| --- | --- | --- |
| Bounded JSON, exact UTF-8 bytes, no content in metadata/errors | CredentialFileFormat + file reader | Valid/invalid/oversize/symlink/replacement tests |
| Explicit save, no overwrite/grant changes, cancellation | Existing single pending save controller + file IPC | Controller tests + isolated signed App/CLI |
| Old text behavior and metadata compatibility | Optional file format, explicit run mapping | Decode/edit/run regression tests |
| Private runtime paths, exit/failure/crash cleanup | File lease + watchdog | Permissions, concurrent lease, kill, launch failure tests |
| Agent/user entry and accurate instructions | App chooser/detail + CLI + skill | Real GUI smoke + help/skill checks |

Implementation exception: this one vertical slice touches shared Core, App and CLI together
because its authorization boundary must be tested end-to-end. Work is sequenced as bounded
modules with a first targeted test before the next capability; it is not a multi-node Graph.
Freeze the candidate, run one full test/build sweep, commit only this batch, back up and
deploy signed App/CLI, verify installed hashes/version. Existing dirty file modes and unrelated
changes are preserved; production credential stores and old recovery copies are not test data.

## Security boundaries / known limits

File content is a secret, not instructions or executable input. The App validates shape,
not provider identity or actual access. Import does not grant read access. A JSON filename,
path or listed field is not evidence of usable authentication.

Compatibility programs need a real plaintext file: owner-only permissions do not isolate
other processes running as the same user or root. Cleanup is unlinking, not secure erasure;
power loss, OS snapshots and hostile copies cannot be undone. Runtime watchdog cleanup and
later stale-lease cleanup reduce leftovers, not a promise of zero plaintext on disk.
Downloaded originals remain untouched. No background daemon/detached-child lifetime support.
Output redaction is a safety net, not protection against transformed/encoded secrets.

Replacement/rotation, generic binary/PEM support and SDK-specific file helpers are follow-ups.

## Usage

GUI: Add a key → enter a name with an unused ID → Import service-account JSON… → select a
file → confirm exact source/ID/field in the native window. Typed values must be empty; file
import uses strict protection, the ID as label and `credentials-json` as its field. Other
draft options are not applied. The original remains on disk.

CLI (path only; no secret in arguments):

```sh
keykeeper save -c ga4-service --field credentials-json --from-file /absolute/path/download.json --create
keykeeper run -c ga4-service --file ga4-service:credentials-json=GOOGLE_APPLICATION_CREDENTIALS -- python report.py
```

The explicit environment mapping follows Google's documented [ADC file-path contract](https://docs.cloud.google.com/docs/authentication/application-default-credentials).
It does not create a Google identity, grant GA4 access or verify a service-account key.
Prefer existing suitable keyless authentication; Google discourages unnecessary long-lived
service-account keys. This importer accepts service-account JSON only, not user ADC or
federation config files. No provider login or real analytics request is part of this test batch.

`--create` refuses any existing credential ID or orphaned value. Without it, only an
already-file-typed missing field can be restored, preserving metadata/grants. Text clipboard
imports cannot change a file field's type. File content is hidden in GUI editors; descriptive
metadata/security remain editable and whole-credential deletion retains its confirmation.

All file fields in the requested `-c` credentials must have exactly one `--file` mapping.
Mappings are preflighted before reading secrets, cannot overlap text variables, and reject
PATH/HOME/TMPDIR/SHELL/ENV/BASH_ENV and loader variables. At most 32 files per run, 64 KiB
each; no TTY file mode. Ordinary text credentials retain their original behavior.

The App opens a non-followed, nonblocking regular-file descriptor and records its identity,
owner/size/timestamps before approval. It compares both the descriptor and named path before
and after the bounded read. It does not normalize the document, execute contents, retain
source paths in credential metadata or clear the downloaded original.

Runtime leases use the OS per-user temp directory (not inherited TMPDIR), create-only files,
an inherited flock descriptor, and a separate same-binary cleanup process. EOF from the
owning CLI triggers cleanup, including SIGKILL. Next file-mode run sweeps up to 128 entries,
skipping locked active leases. Removal is nonrecursive and limited to 32 known filenames
plus the lock marker in an owner-only UUID lease directory. Unknown files are preserved.
Cleanup guard startup has a five-second bound; no credential file is written before its ACK.

## Acceptance — 2026-09-11

ACCEPTED for the frozen local service-account JSON batch. Full Swift regression: 240 tests,
4 existing skips, 0 failures (09:39 local). Added 14 tests across Core, App and CLI. Release
App/embedded CLI built and passed strict Developer ID signature verification.

Isolated signed App + separate socket/data/Keychain service, synthetic JSON only:

- CLI path → native Save once → Keychain → strict typed metadata → authorized real CLI child
  succeeded; exact original bytes and 0600/0700 runtime modes checked inside the child.
- Native chooser → Go to synthetic file → source/target confirmation → new strict list entry
  succeeded. Source original remained unchanged; duplicate create refused and Escape cancel
  returned non-success without a new entry.
- Normal child exit removed the runtime path. Real CLI SIGKILL removed its managed file;
  a concurrent second run retained its own file, then SIGTERM cleaned that file as well.
  Missing business executable returned nonzero. Active-lock/stale-lease cleanup unit tests pass.
- CUA screenshots reviewed: native source/target confirmation, Add initial/ready states,
  file detail, file-read-only editor, scroll to footer and system chooser. No secret contents
  appeared. Native picker focus needed an explicit click before its keyboard Go to action.
- Skill passed the standard skill validator in a disposable directory. Provider downloads,
  real credentials, actual GA4 reporting, public release and all provider-specific browser
  download implementations remain outside this batch.

First targeted test passed before the second module. Bounded pre-freeze tests found and fixed
duplicate-field type replacement and URL trailing-directory equality in stale cleanup.
The first lifecycle harness waited for stdout that the redactor intentionally buffers; it
was corrected to wait for a synthetic child receipt recording byte/permission checks, without
changing product behavior or the cleanup assertions. Output may be delayed by up to the
longest redaction pattern; transformed output is outside the guarantee.

Synthetic execution receipts/logs reside in `/tmp/keykeeper-file-e2e.f2oJnS`; no user credential
contents or UI screenshots are stored in this document or the test corpus. Production data,
old recovery backups and deployment hooks are not modified by the tests.
