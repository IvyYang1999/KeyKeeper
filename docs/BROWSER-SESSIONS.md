# Website session delegation — frozen first batch (2026-09-11)

Goal: a user deliberately selects a website in their browser, approves a local encrypted
snapshot, and lets an Agent request a time-limited isolated browser window without returning
Cookie values through the Agent interface. This is separate from the pending public release.

## Acceptance envelope

| Required first-batch capability | Contract / implementation | Validation |
| --- | --- | --- |
| Explicit selected website/profile, not a whole-browser export | Chromium extension, active tab + optional exact host permission | Mock Chrome permission/cookie calls + isolated browser fixture |
| Bounded, domain-checked Cookie snapshot; no values in normal replies | Core session import + metadata-only response | wrong origin, malformed/oversized/expired cookies, response tests |
| Encrypted storage separate from legacy API keys | dedicated Keychain service + creation marker | fake IO, missing/corrupt store, duplicate/conflict, delete tests |
| Human approval before save and each Agent open | native confirmation with OS-resolved caller | deny/timeout/disconnect/no-write tests + real native UI |
| Isolated browser with no raw-cookie read endpoint | nonpersistent WKWebView, selected origin only, 15-minute lifetime | synthetic authenticated page, outside-origin denial, close/revoke cleanup |
| Management and withdrawal | App session list/open/delete/stop | Chinese UI interaction + state tests |
| Installable integration | bundled native host/extension, explicit registration | real Native Messaging framing + documented install/user gate |

Implementation is split sequentially into bounded Core validation/storage, native bridge,
browser/approval UI, extension/integration work packages. This deliberately spans four layers
because the smallest useful result is an end-to-end seam, not a standalone Cookie exporter.
Each slice gets a targeted test before expanding it; one final full regression after freeze.

Non-goals: Safari, Chrome Web Store publication, Codex embedded-browser injection, cloud
Agents, all-profile scanning, silent permission installation, LocalStorage/IndexedDB/partitioned
Cookie migration, automatic refresh, persistent Agent grants, universal website compatibility,
read-only account permissions, public release, restoration/deletion of existing API keys.
Only unpartitioned root-path Cookies are supported initially. Domain-scoped Cookies are narrowed
to the selected host in the isolated browser. HTTPS only outside isolated loopback fixtures.

Agent authorization controls requests to start a browser session, not other operators of the
same macOS desktop. A logged-in website may expose private account data and allow writes;
the UI must not imply read-only access. No raw Cookie getter is provided, but this does not
make malicious websites or same-user/root processes safe. Closing a managed browser deletes
its ephemeral local state, not the original browser's Cookies or server-side sessions.

User gates: browser choice, extension installation/host permissions, real session import/open
confirmation, and any website login/2FA. Only synthetic local sessions are used for development.
All test CLI calls use one wrapper with data directory, test Keychain service and test socket
together; no socket-only overrides or production synthetic writes. Production data is read-only.

Blockers: data loss, unintended writes, secrets exposed through tool output/logs/files, permission
bypass, core startup/use failure, unbounded work, or failure of a requirement above. Future
compatibility/polish is a follow-up. Unsupported real-browser installation remains an explicit
integration gate; mocks do not count as a shipped feature.
