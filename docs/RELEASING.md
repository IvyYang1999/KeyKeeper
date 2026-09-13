# Releasing KeyKeeper updates

KeyKeeper uses Sparkle 2. The app checks the signed `appcast.xml` once a day. Automatic
installation is off by default; users can turn it on in Settings. Signing reads the
`private-key` secret field from `keykeeper-sparkle-signing-v2` (override with
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
`keykeeper save -c keykeeper-sparkle-signing-v2 --field private-key --from-clipboard --create --expect base64:32`,
wait for the native save prompt, copy from the exact source once, then confirm. Verify public
key identity before signing. Do not overwrite/delete a mis-stored credential to reuse its ID;
use a new ID and mark the earlier entry unusable. Freshness and shape are not source attestation.

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
4. Inspect the candidate and get explicit approval to publish.
5. Run `./scripts/publish-update.sh --confirm-version <version>`. It creates and pushes
   the tag, checks that the DMG on disk is the one the appcast signed, publishes it on
   GitHub Releases, then commits the appcast and pushes `main`. That last push is what
   makes the update visible to installed apps — the feed is read from `main`.
6. Point the website at the new version: in `keykeeper-landing`, update the download URL
   in `app/page.tsx` and the two `facts` strings in `app/i18n.ts`, then deploy with
   `vercel --prod --yes` (a git push does not deploy).

Do not hand-edit `appcast.xml` after generation: signed feeds reject any modification.
If publishing fails after the tag or GitHub Release is created, leave the appcast
unpublished and inspect the existing remote state before retrying.
