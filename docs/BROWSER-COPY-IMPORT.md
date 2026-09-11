# Browser-copy import — native Chrome path ACCEPTED

## Final decision (2026-09-11)

The user's objective is automatic website Copy → KeyKeeper transfer without exposing the
value to the Agent or requiring manual copy/paste. The earlier page-owned-read strategy
below was NOT accepted and is superseded by the native Chrome workflow. Its speculative
read button was removed; the receiver returned to the already-installed paste implementation.
This is a transport correction, not a claim that in-app clipboard-read permissions are fixed.

Verified sequence: an ordinary Chrome tab, opened and operated only through native computer
use → native website Copy → native Paste into the local receiver → native one-time save
confirmation → independently authorized child-process hash comparison → fixed MATCH result.
Do not create/claim this transfer tab with browser-session tooling or mix its virtual
clipboard operations with native Copy/Paste. Existing browser-session paste remains supported
for sources that actually use that buffer; a Copy success toast does not prove interoperability.

Evidence:
- Gesture probe: trusted click, active user gesture, focused visible secure document and
  Copy success; the in-app same-origin read still returned NotAllowedError.
- Chrome browser-tool-managed test: native Paste returned MISMATCH; no value printed/saved.
- Ordinary Chrome native-only test: Paste returned MATCH. Isolated signed App saved the
  synthetic value; CLI success and separately one-time-authorized COPY_CHAIN_MATCH returned 0.
- Independent second trial regenerated the synthetic value. App/CLI binaries were copied
  byte-for-byte from installed version 95e4c187e631, compared before re-signing the isolated
  test bundle. A fresh data directory, Keychain service and socket were used. Native Copy
  and probe Paste matched; actual receiver save returned success; independent readback
  returned PRODUCTION_COPY_CHAIN_MATCH with exit 0. No persistent read grant was added.
- Production App/CLI were not replaced/restarted. No production credential was created or
  changed. Claude's native SwiftUI and shared translation files were not edited.
- Final targeted gate: 20 tests passed. Full gate: 291 tests, 4 existing skips, zero failures.
  Installed Codex skill and repository skill have identical SHA-256; YAML/name/description
  checks passed with Ruby (the Python validator's PyYAML dependency is unavailable locally).
  Both disposable test Keychain items were deleted after the test App stopped. Test servers
  and tabs were closed; current clipboard contents were not read or cleared during cleanup.

Reproducer: run `node scripts/browser-copy-fixture.mjs`. It generates synthetic values only,
prints their test digest and two local URLs, and exposes Copy/read/probe-Paste controls.
Use SOURCE in an ordinary native-controlled Chrome tab; do not claim it through browser tools.
The probe reports only MATCH/MISMATCH. Use a separately isolated KeyKeeper App for write
acceptance; never a production credential, arbitrary clipboard contents or raw-value output.

Known limits: native Chrome computer-use access and the user's permission to use Chrome are
required. Login/2FA and confirmation for real saves retain their existing gates. Other
providers/browser tools are not universally certified; in-app automatic read remains unsupported.
No browser clipboard-read permission was granted. Source website identity is not attested.
Native clipboard history/local processes remain outside the transport's secrecy guarantees.

## Historical rejected scope (retained for evidence)

Required: explicit page-owned clipboard-read button in the existing local receiver;
same source tab navigates to the receiver; no values in Agent context, DOM, logs or files;
retain native confirmation, no-overwrite, no-new-grants and the 90-second lifetime.
Read denial/empty/oversize, duplicate clicks, paste/read racing, cancellation/expiry while
clipboard permission is pending must fail closed. Existing keyboard-paste remains available.
Chinese/English copy and real signed isolated App + browser + Keychain readback required.

Non-goals: native SwiftUI redesign, Chrome extension changes/installation, Codex application
instrumentation or permission bypass, production test credentials, automatic recovery of a
real provider key, or switching to an unverified system clipboard.

Ownership: only BrowserImportPage.swift, its dedicated tests/harness and affected localization
assertions, SaveCommand.swift help/instructions, skill/keykeeper.md and this
note. Preserve Claude's native UI edits, unrelated dirty-tree changes and disabled deployment
hook. No production restart while Claude's deployment/form state is unknown.

Blockers: secret leakage, wrong/unauthorized writes, loss of existing data, bypassed approval,
unbounded activity, core incompatibility, or failure of the above explicit requirements.
Other browser/provider compatibility is a known limit, not an excuse to extend this batch.

Reproduction: website Clipboard API reported success, but browser-tool keyboard Paste failed
with an empty virtual clipboard. Page-owned read in the source tab matched the synthetic
value. A new receiver tab (including foreground) was denied; navigating the original source
tab to a different loopback origin and reading there matched. These are observations of this
runtime, not a claim that all browsers share the same clipboard permission model.

## 2026-09-11 candidate status: WAITING_BROWSER_GATE (not Accepted / not deployed)

- TDD: new synthetic lifecycle test failed before implementation, then passed in both
  languages. Targeted App/bridge/localization: 15 passed; CLI: 5 passed.
- Full Swift gate: 291 tests, 4 existing skips, 0 failures. Release compilation succeeded.
- Signed isolated App served the actual updated receiver. Visually checked keyboard focus,
  vertical scrolling, readable wrapping and reachable Cancel; Cancel returned no-save in
  both page and CLI. No credential exists in the fresh isolated browser-read namespace.
- Earlier same-tab cross-origin probe matched; the final end-to-end run subsequently hit
  a pending browser Clipboard API request (both read and write), not a verified transfer.
  Showing the current task's browser was queued; user foreground handoff requested.
  This remains a blocker to claiming actual browser → Keychain readback completion.
- Repository skill updated; installed skill/App deliberately unchanged pending acceptance.
  Native SwiftUI and shared translation catalog untouched. Deployment hook remains absent.
- Next: fresh source Copy success in the original visible tab, navigate that exact tab to
  a new isolated receiver, click Read, confirm only synthetic fixture, verify expected hash
  through a one-time-authorized child process (constant result only). Then install alongside
  the separately running native UI work, with restart/form state explicitly resolved.
- Known limits: browser/provider permission differences; initial idle status still says
  waiting for Paste; no universal background clipboard guarantee or automatic real-key recovery.

Safety incident in earlier discarded system-clipboard experiment: an unverified previous
clipboard value was saved only to a separate test namespace and the clipboard was cleared.
No value was read back or shown to the Agent. The test App was stopped and the exact test
Keychain item was deleted; production storage was not changed. User was informed. This is
not evidence of a working system-clipboard route; the final fresh namespace is separate.
