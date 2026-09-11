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
Runtime compatibility finding (2026-09-11): Foundation here loses explicit `SameSite=None`
both from Set-Cookie and from public property construction. Until an end-to-end-preserving
adapter exists, the App rejects those snapshots **before saving** with `unsupported`.
The Core format retains that policy for future adapters; supported Lax/Strict policies must
round-trip through WebKit before navigation. Chrome's unspecified policy is made explicit Lax
(never broadened). This limits compatible websites; it is not a promise to recover every login.

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

## Local preview installation (explicit user gate)

This is an unpacked development preview, not a Chrome Web Store release. Installation does
not itself authorize reading any real website. Keep the currently installed save-bug fix
until Chrome integration acceptance is complete; do not restore the deployment hook.

1. Build the signed App with `scripts/build-app.sh --skip-dmg`. Do not auto-deploy it over
   a running production App with an unsaved form.
2. After user confirmation, install the candidate App, then open `chrome://extensions`,
   enable Developer mode and load `KeyKeeper.app/Contents/Resources/browser-extension`.
3. Copy the extension's public 32-letter ID (not a secret). Run:
   `keykeeper browser-install-host --extension-id <extension-id>`.
   It creates only this user's Chrome `NativeMessagingHosts/com.keykeeper.browser_sessions.json`,
   with exactly one allowed extension origin and the bundled host's absolute path. An existing
   different registration is never overwritten. `--app /absolute/KeyKeeper.app` selects a preview
   bundle deliberately; the default is `/Applications/KeyKeeper.app`.
4. Select a website in the intended normal Chrome profile and click the extension icon.
   A persistent small window displays the exact origin and a user-chosen, AI-visible label.
   Chrome's site-access grant is host-scoped (not port-scoped); the actual Cookie read uses the
   exact selected origin's root URL and only the current extension context's Cookie store.
   No background/profile-wide Cookie scan is performed. Incognito is unsupported.
5. Request save, approve the exact website/caller in KeyKeeper, and await the final saved
   result. A saved snapshot is not proof that the website remains logged in. Do not retry an
   uncertain result; check the App's list first. Keep the panel open until the result arrives.
6. Agent workflow: `keykeeper browser list`, then `keykeeper browser open <id>`.
   Each open requires native approval. Use `keykeeper browser stop <id>` to close it immediately;
   `keykeeper browser delete <id>` requires confirmation and stops the window before deleting
   only the selected snapshot. No CLI command returns Cookie values.

Stopping all windows is immediate. Closing/removing the local snapshot does not revoke the
server-side session or log Chrome out. Full account revocation uses the website's own security
settings. To remove the integration, disable/remove the Chrome extension; the native host
registration can then be removed after confirming its exact path. No account data deletion is implied.

### Known limits / follow-up

- Real Chrome installation, exact-host permission, popup-to-native transport and a compatible
  real-site session are separate acceptance gates. A mock visual preview is not their receipt.
- Host permission obtained for the current request is released on normal completion; a
  preexisting exact grant is retained. Closing/crashing the extension window can prevent its
  cleanup callback. In that case the user must check/revoke the extension's site access in Chrome.
  No background process in this extension reads Cookies, even if a grant remains. Crash-safe
  permission cleanup is a follow-up, not an assertion of automatic revocation.
- Only root-path unpartitioned Cookies are copied, never LocalStorage/IndexedDB. Cross-origin
  resources, SSO redirects, popups, uploads and downloads are blocked. Consequently many sites
  may fail to render or remain logged in. Explicit SameSite=None snapshots are rejected before save.
- A profile label is user-provided, not a cryptographic account identity. Inspect the website
  account after opening. The feature cannot guarantee read-only actions or protect against a
  malicious website, same-user processes, desktop operators or root.
- Production performs normal system TLS verification. The XCTest-only dependency injection
  pins the fixture's ephemeral localhost certificate, with no environment/IPC bypass in the App.

## Reproducible checks

`node --test tests-browser/import.test.mjs` covers exact-site permissions, cancellation/races,
payload restrictions and secret-free replies. `swift test --disable-keychain` runs regressions.
`KEYKEEPER_BROWSER_E2E=1 swift test --disable-keychain --filter SessionBrowserRuntimeTests`
additionally runs real desktop WebKit against a synthetic local HTTPS server (requires Node
and `/usr/bin/openssl`). It verifies authentication, HttpOnly, outside-origin image/navigation
denial and Cookie cleanup. No user keychain or real account is used by those tests.

`node tests-browser/preview.cjs` is a clearly separated mock UI fixture. It only serves an
allowlist of extension files and synthetic API replies; it is not bundled into the App.
