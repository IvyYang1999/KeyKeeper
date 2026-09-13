# Releasing KeyKeeper updates

KeyKeeper uses Sparkle 2. The app checks the signed `appcast.xml` once a day. Automatic
installation is off by default; users can turn it on in Settings. The Sparkle private
key stays in the macOS login Keychain under account `com.keykeeper.app`. Never export it
into the repository or pass it on a command line.

The 0.3.0 candidate's update-signing identity was explicitly re-established on
2026-09-12 after the previous private key could not be found. Its public key is in
`Resources/Info.plist`; internal builds with the previous public key require a
one-time manual installation. Do not silently generate a replacement key during
future releases. Before packaging, use `generate_keys --account com.keykeeper.app -p`
to check that the existing public key matches the plist; this command does not
export the private key or create a new one. A missing or mismatched key is a stop
condition requiring recovery or an explicitly approved signing-identity change.

On the first run of `prepare-update.sh`, macOS may ask whether `generate_appcast` may
access that key. Choose **Always Allow** once; never paste the private key into a terminal
or chat.

## First updater-enabled release

Existing KeyKeeper builds do not contain Sparkle, so this first release must still be
installed manually. Every later release can update it in place.

1. Ask the user to approve the exact next version. Update `VERSION` and
   `CHANGELOG.md`, add `release-notes/<version>.md`, then commit and let the normal
   tests finish.
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
