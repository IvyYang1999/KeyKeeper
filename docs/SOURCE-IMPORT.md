# Source-literal import — frozen first batch

Goal: an Agent selects an exact local Python file and symbol; KeyKeeper extracts a
candidate string without executing the file or exposing its contents to the Agent.

Required: metadata-only new IPC type (old Apps fail closed), explicit Python symbol,
owned regular UTF-8 file <= 1 MiB, descriptor/identity checks across approval, reading
only after native confirmation, fixed isolated Python AST helper, bounded private pipes,
one supported unambiguous top-level assignment, text-typed no-overwrite save, original
file retention, Chinese path/symbol/caller confirmation, existing save regression gates,
signed isolated App + CLI synthetic E2E. Existing grants/storage recovery guards remain.

Supported expressions: a string literal (including Python escapes), or exactly two
positional arguments to `os.getenv` / `os.environ.get`, with literal string environment
name and literal string default. This extracts source text's candidate, NOT effective
environment/runtime/provider authentication. Dynamic expressions and multiple bindings
are rejected. No regular-expression fallback, eval, exec, module import of the source,
clipboard, plaintext temporary bridge, overwrite, automatic runtime install, real key
rotation, Vercel configuration, or real default-password import in this development batch.

Use an already installed Apple Python 3 in Command Line Tools or Xcode, not PATH/CWD or
a project virtual environment. Missing runtime or unsupported Python grammar fails closed.
No hidden Python installation prompt. This initial runtime prerequisite is a known limit.

Blockers: data loss/overwrite, unauthorized writes, secret leakage (including exceptions),
execution of source code, unbounded processing, incompatible existing imports, or failure
of these explicit requirements. Other languages and broader Python expressions are follow-up.

User gates: real-file access/save confirmation and a production restart if an unsaved form
would be lost. All development/GUI tests use synthetic values and the full triple-isolation
wrapper; no synthetic production writes. Deploy only a verified candidate, preserve rollback,
and do not restore post-commit deployment hooks or publish externally.

Coverage: source request/CLI → protocol tests; AST helper → syntax/no-execution/timeout
tests; file source → race/type tests; controller → approval/no-overwrite/cancellation tests;
real CLI → native confirmation → isolated Keychain readback → metadata-only result.

## Usage

```sh
keykeeper save -c my-service --field ADMIN_KEY --from-source /absolute/path/config.py --python-symbol ADMIN_KEY --create
```

Omit `--create` only for an existing missing text field. Existing values require a separate,
deliberate replacement workflow; this command cannot overwrite them. App and CLI must both
be updated. No change to the source file, runtime environment or provider configuration is made.

## Acceptance receipt — 2026-09-11

- TDD: extractor tests failed first for the missing type; CLI/file-source tests failed first
  for the missing protocol/options; six localization assertions failed before translations.
- Directed gates passed, followed by the frozen full Swift suite: 290 tests, 4 existing
  skips, 0 failures, with the existing real-browser E2E gate enabled.
- Release App and CLI built; a separately identified Developer-ID-signed App passed deep
  strict signature verification and ran against isolated data/socket/Keychain namespaces.
- Real native Chinese confirmation visibly displayed caller, exact source path/symbol,
  destination, candidate-only warning, no-overwrite and expiry; no secret preview.
- Real CLI save succeeded; metadata is a strict text field. A separate once-only read
  through `keykeeper run` returned only `READBACK_OK`. Duplicate create was refused.
- Replacing the synthetic source while approval was pending produced `fileChanged` and
  created no target. Unit tests also cover cancellation, unsupported syntax, bounded pipes,
  file ownership/type/symlink checks and preservation of the original file.
- Installed and packaged skill copies match. The provided skill validator could not run
  because PyYAML was unavailable; Ruby safe-YAML frontmatter/placeholder checks passed,
  and the new command was exercised through the real App rather than only text matching.
- No production credential/source read, overwrite, deployment or provider validation.
  Production restart/install remains an explicit handoff gate if an unsaved form is open.

Known limits: Python only, literal/default candidates only, trusted installed Apple Python
required, no proof that a source default is active online. No claim of isolation from
same-user/root debugging; the boundary is preventing values from entering Agent context,
IPC replies, command arguments/environment, screenshots or application logs.
