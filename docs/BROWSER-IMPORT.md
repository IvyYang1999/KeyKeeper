# Browser import — acceptance envelope (2026-09-11)

## Frozen scope

Ship a reusable macOS KeyKeeper feature, not a machine-specific helper: CLI starts a single-use browser import, returns a loopback URL, browser pastes without exposing text to the Agent, App confirms the exact target, existing guarded save writes only an absent field. New IDs are strict and inherit no grants. Existing clipboard save stays compatible.

Only loopback, random per-session authorization, exact Host/Origin validation, no CORS, no remote assets/analytics, no secret in URL/CLI/stdout/logs/files/DOM values. Paste event consumes text without inserting it into the input. Bounded size/connections/time; one pending import, one submission, no retries after an uncertain write. Cancel/timeout/disconnect must not save; existing data and metadata protection remains authoritative.

Acceptance matrix (single implementation owner):

| Must deliver | Contract / implementation | Gate |
| --- | --- | --- |
| Metadata-only initiation | IPC + CLI browser save | roundtrip/argument tests |
| Browser-session paste transport | bundled receiver + loopback server | real CUA synthetic paste |
| Authenticated local single-use request | HTTP parser/session controller | wrong Host/Origin/token, replay, size, timeout tests |
| One explicit native approval; no overwrite | existing ClipboardSaveController with per-request source | create/restore/cancel/concurrency/readback tests |
| Ordinary-user package | signed App and CLI + usage guide | release build and isolated signed App E2E |

Scope exception: one vertical package touches Core/CLI/App because the compatibility boundary is one end-to-end feature. No additional backend, SDK, browser extension or dependency. No real provider logins/keys, overwrite, batch approval, public release/push, hook restoration or backup redesign. User gate remains native save approval and website login/2FA. Blockers only: data loss, secret exposure, unauthorized/wrong writes, core failure, unbounded resource use, or a direct failure of this envelope.

Mechanical closure: first transport smoke → focused red tests → small compiled slice → focused tests → bounded frozen sweep and full regression → signed isolated E2E → scoped commit. Installation into production only after verified signed candidate and recoverable backup; no remote publication.

## Initial transport evidence

CUA browser-session clipboard containing a synthetic value → keyboard Paste → password-input paste handler (`preventDefault`) → loopback POST → fixed match result succeeded. No clipboard read API or secret-valued action argument was used during transfer. A webpage `navigator.clipboard.writeText` Copy button did not populate the virtual clipboard in that test: website copy and browser-tool clipboard can differ. Do not infer that every provider's Copy button uses the virtual clipboard; retain system clipboard import as a separate path. Real provider compatibility is not yet claimed.

## Usage

`keykeeper save -c my-provider --field api_key --from-browser --create`

Keep the CLI alive. Open its exact one-time URL in the browser session containing the copied key, click the paste area and press Command-V. The browser sends the paste without inserting the value in the input/DOM. Confirm the ID/field in the native App; the final CLI result is authoritative. Omit `--create` only to restore an existing missing secret field. Saving grants no read access; subsequent use remains independently authorized.

The URL fragment is a random 256-bit, short-lived **write-proposal ticket**, not the API key. It is removed from the visible URL before paste and never embedded in the HTML. Do not share or persist the link. The HTTP surface is bound to `127.0.0.1` on an ephemeral port, checks exact Host, Origin, ticket, framing and body bounds, rejects CORS/preflight and framing ambiguity, and permits one submission. At most 4 reading connections / 32 accepted connections per import, 5-second read deadline and 2-second response-send deadline. Whole request expires 90 seconds after initiation. No automatic retries.

## Known limits

- Same-machine macOS desktop only; not a remote/cloud-agent bridge. No changes to Codex itself are required for the tested keyboard-paste route.
- Browser and provider Copy behavior varies. Never silently switch buffers or extract a value to discover which one contains the key.
- The App does not clear the browser clipboard: it cannot safely compare it with newer content. Browser/tool/OS internals, clipboard managers and an already-compromised local process are outside this feature's secrecy guarantees. Swift/JavaScript immutable strings are released, not guaranteed physically zeroized.
- Source website identity is not attested. The native prompt binds the CLI caller and target, not the provenance of clipboard content. User confirms that target and intended copy.
- Closing the browser before paste leaves a bounded reservation until CLI exit, Cancel or timeout; closing the pending HTTP submission cancels approval. Once committed, cancellation cannot undo the save. An uncertain transport outcome requires checking App/metadata before any new write.
- Whole-store loss/corruption remains blocked; existing storage protection and metadata-commit-failure preservation remain unchanged.
- No public release or notarization is performed by this development task. Shipping to other users still requires the normal release channel.

## Accepted candidate — 2026-09-11

- Full Swift gate: 226 tests, 4 existing skips, 0 failures. Added 10 tests covering HTTP parsing, real loopback requests, deferred confirmation, cancellation/disconnection/expiry, replay isolation and CLI protocol. Existing no-overwrite/storage-loss/grants tests remain green.
- Signed Developer ID App + embedded CLI, isolated data/socket/Keychain: browser-session Paste → real HTTP → native confirmation → Keychain save → CLI success verified. New metadata was strict. In an explicitly test-only standard fixture, CLI child-process comparisons verified the created and restored values without printing them.
- Missing-field restoration preserved the original synthetic field and metadata SHA-256 `32f478dc79df454c449e15ac0c0005af9b50d7188a48c64e96a3ffb233da7e1e`. Existing-target refusal, native Escape cancellation, closing a submitted page, and pre-paste Cancel all left metadata unchanged and returned non-success.
- Real browser AX snapshots showed no pasted value; the page input stayed empty. Full desktop and 375px viewport screenshots reviewed; long names wrap without horizontal overflow (clientWidth == scrollWidth == 375), vertical scroll reaches Cancel. Native normal/long-name prompts, Command-Return and Escape checked. Browser override reset. VoiceOver audio and every provider's Copy behavior are not tested.
- Bundled Agent instructions passed the skill validator in a disposable directory; no global skill/permission configuration changed. UI skill catalog was consulted, but its detailed remote guide was unavailable; native controls and direct visual checks were used.
- Bounded sweep found one replay-isolation defect (a rejected duplicate cancelled the original pending request), fixed with a failing real-HTTP test first. Aggregate outcome: ACCEPTED for the frozen same-Mac synthetic transport envelope; provider recovery and public distribution remain separate gates.
