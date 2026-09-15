# Approval UI fixes · frozen acceptance envelope

Scope: the two user-reported UI defects only. Baseline `5c480a8`.

| Required outcome | Verification | Owner |
| --- | --- | --- |
| Approval completion immediately updates the access-log action/status | Synthetic production-view/notification test and visual smoke | access-status package |
| History remains history; current authorization uses identity, target, field and validity | Positive + wrong identity/field + expired/revoked/error tests | access-status package |
| Repeated disclosure expansion/collapse preserves panel corners and fitted height | Real authorization-window regression + native visual smoke, including overflow | main |
| No storage/authorization-rule changes, no real secret reads or approvals | Scoped diff review + existing isolated CLI/App E2E | main |

Non-goals: plugin submission, MCP, new provider work, broad UI restyling, data migration,
changes to grant duration/scope, public release or automatic local installation.

Blocking risks: data loss, secret disclosure, unauthorized/wrong writes, broken launch or core
flow, unbounded work, explicit acceptance violations and existing regression failures.
Other findings remain follow-ups. No open-ended hardening sweep.

User gates: installing/restarting the production App requires a fresh confirmation. Synthetic
test instances use their own data directory, Keychain service and socket. Never accept a real
pending approval for a test. Keep all deployment hooks disabled.

Closeout: red tests → targeted fixes/tests → freeze candidate → one full gate and isolated
visual/E2E pass → scoped commits → final gate → ask for installation. Preserve Claude's layout.

## Candidate result · 2026-09-15

- Access log: current authorization is a separate projection from historical requests. The
  exact subject/target/field and core validity checks decide the current tag and action.
  Approval notifications refresh immediately. Active visible pages check expiry/revocation
  every two seconds; read errors stop automatic retries and remove approval actions.
- Window: the measured authorization panel reports its capped size to the controller. A
  plain AppKit container separates hosting content from native automatic window sizing;
  the controller sizes the full frame once, preserving the top edge. No corner mask or
  storage/authorization change was added.
- Root-cause evidence: baseline native content returned to 341pt while its window remained
  373pt. Disabling background animation, or hosting sizing constraints alone, did not fix
  the native reproduction. Detaching the direct hosting/contentView bridge did.
- Regression: identity-isolation test failed on baseline. Added eight tests; full gate
  passed 820 tests (11 existing opt-in skips), plugin package tests and debug build.
  Signed release build + isolated CLI/App E2E passed 46/46. Independent bounded review:
  ACCEPTED, no blockers in the frozen scope.
- Native visual: metadata-only test instance, no stored secret values. Repeated expansion
  and collapse returned to intact rounded corners and compact height. Real Access log →
  Approve now → local authentication → approval completion showed “Currently approved”,
  removed the button, and retained historical request text/time. No real grant was changed.
- Limits: automated native-window tests cover short and capped/scrolling content; scrollbar
  dragging was not separately visually checked. Terminal-session grants cannot be borrowed
  without that session's context. This is not a public release or production installation.
- Test receipts are in the private temporary run directory `/tmp/kk-approval-ui.pfarc7/`
  (`full-gate.log`, `e2e-gate.log`, targeted panel logs). No screenshots are committed.
