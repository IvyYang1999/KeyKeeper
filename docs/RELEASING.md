# Releasing KeyKeeper updates

KeyKeeper uses Sparkle 2. While running, it checks the signed `appcast.xml` every six
hours by default. Signed updates download in the background and install on quit;
if the app stays open, the default reminder interval after downloading is one day
(Sparkle's unconfigured default is one week). Sleep, offline periods and a stopped
app delay checks: this is polling, not push delivery or a timing guarantee. Existing
explicit Sparkle preferences take precedence over these defaults. Settings offers
“Download updates in the background”; switching it off keeps checks and download prompts.
Signing reads the
`private-key` secret field from `keykeeper-sparkle-signing` (override with
`KEYKEEPER_SPARKLE_CREDENTIAL_ID`). The original login Keychain entry under account
`com.keykeeper.app` is retained for recovery. Never export private keys into files or argv.

The 0.3.0 candidate's update-signing identity was explicitly re-established on
2026-09-12 after the previous private key could not be found. Its public key is in
`Resources/Info.plist`; internal builds with the previous public key require a
one-time manual installation. Do not silently generate a replacement key during
future releases. Before packaging, use `generate_keys --account com.keykeeper.app -p`
to check that the existing public key matches the plist; this command does not
export the private key or create a new one. A missing or mismatched key is a stop
condition requiring recovery or an explicitly approved signing-identity change.

`prepare-update.sh` uses KeyKeeper authorization, verifies the 32-byte Base64 seed against
the built App's public key, then passes that same value to `generate_appcast --ed-key-file -`
over stdin. It never falls back to the login Keychain. A mismatch stops signing. This removes
Sparkle's direct Keychain access, not KeyKeeper's own authorization or OS lock requirements.
Verification requires Apple Python 3 and an OpenSSL build supporting Ed25519; the RFC 8032
self-test fails closed if the runtime is unavailable. Legacy 96-byte keys are unsupported.

For initial setup, use an installed 0.3.3 App and CLI. Start
`keykeeper save -c keykeeper-sparkle-signing --field private-key --from-clipboard --create --expect base64:32`,
wait for the native save prompt, copy from the exact source once, then confirm. Verify public
key identity before signing. For a mis-stored existing field, use `--replace` instead of `--create`,
and add `--expect-ed25519-public-key <SUPublicEDKey from the trusted App plist>` so identity is
checked BEFORE replacement. Confirm the native replacement prompt; old values survive failed
validation. Do not delete the credential or change its ID/type. Existing read permissions remain.
Freshness and shape alone are not source attestation.

## First updater-enabled release

Existing KeyKeeper builds do not contain Sparkle, so this first release must still be
installed manually. Every later release can update it in place.

1. Ask the user to approve the exact next version. Update `VERSION` and
   `CHANGELOG.md`, add `release-notes/<version>.md`, then commit and let the normal
   tests finish.
1b. Prove the Sparkle signing key is the one this app trusts: `./scripts/verify-sparkle-key.sh`.
   It derives the ed25519 public key from the stored private key and compares it with
   SUPublicEDKey, printing only whether they match — the key is never displayed. Note that
   `sign_update --verify` is NOT this check: it only proves a key is self-consistent, never
   that it is this app's key.
2. Ensure KeyKeeper contains the Apple notarization credential named `apple-notary`
   (or set `KEYKEEPER_NOTARY_CREDENTIAL_ID` to another credential ID), with fields
   `apple-id`, `apple-team-id` and `apple-app-specific-password`. The first two are plain
   fields, so only the app-specific password asks for an approval.
3. Run `./scripts/prepare-update.sh`. It builds and notarizes the Developer ID-signed
   DMG, then creates a signed `appcast.xml`, but changes nothing remotely.
   Preparation can run in a local `.noindex` worktree whose HEAD exactly equals
   committed `main`. Transfer the verified DMG, appcast and receipt unchanged to
   main for publishing; verify digests after transfer. This keeps app build copies
   out of Spotlight without changing the release's source commit.
4. Inspect the candidate and get explicit approval to publish.
5. Run `./scripts/publish-update.sh --confirm-version <version>`. It verifies the feed
   and archive signatures against the App's public key, and checks the immutable
   `dist/KeyKeeper-<version>.update.json` prepared receipt (source commit, archive,
   feed and release-notes digests). It reconciles the existing remote tag/Release,
   creates a draft when needed, uploads without clobbering, downloads the remote
   asset to verify its actual SHA-256, then makes the release public. Finally it
   commits only the feed, pushes `main` and reads the public feed back byte-for-byte.
   A push alone is not success. The feed-only commit skips the legacy auto-install
   hooks, so publishing never silently restarts the maintainer's live App.
6. Point the website at the new version: in `keykeeper-landing`, update the download URL
   in `app/page.tsx` and the two `facts` strings in `app/i18n.ts`, then deploy with
   `vercel --prod --yes` (a git push does not deploy).

Do not hand-edit `appcast.xml` after generation: signed feeds reject any modification.
If publishing fails, keep the exact candidate and receipt; re-run the same publish
command. It reads existing state before writing, reuses matching tags/assets, and
stops on mismatches, unknown network outcomes or stale public feed bytes. Never
rebuild a tagged version or overwrite its asset. `prepare-update.sh` refuses to
rebuild a version with a local tag or prepared receipt. A historical candidate
without a receipt requires explicit source reconciliation, not a fabricated receipt.

## Verification boundaries

- `python3 -B scripts/test-verify-update.py`: cryptographic positive/negative cases,
  including a different archive of the same size. Only the public RFC 8032 fixture
  key is used; no production secrets.
- `python3 -B scripts/test-publish-update.py`: interrupted upload/publish/push and
  stale-feed scenarios, plus real Git commit/tag/push/resume against a local bare
  fixture. GitHub itself is simulated in these tests.
- `UpdateDefaultsTests` reads the real Sparkle settings implementation with a fresh
  synthetic bundle and an explicitly opted-out user. No live updater is started.
- A public release still needs an isolated installed-old-version → signed-new-version
  Sparkle upgrade, checking the launched version and CLI symlink. These tests alone
  do not prove production delivery. Never run that test against the live user vault
  or force-quit the maintainer's App.
