# Releasing KeyKeeper updates

KeyKeeper uses Sparkle 2. The app checks the signed `appcast.xml` once a day. Automatic
installation is off by default; users can turn it on in Settings. The Sparkle private
key stays in the macOS login Keychain under account `com.keykeeper.app`. Never export it
into the repository or pass it on a command line.

On the first run of `prepare-update.sh`, macOS may ask whether `generate_appcast` may
access that key. Choose **Always Allow** once; never paste the private key into a terminal
or chat.

## First updater-enabled release

Existing KeyKeeper builds do not contain Sparkle, so this first release must still be
installed manually. Every later release can update it in place.

1. Ask the user to approve the exact next version. Update `VERSION` and
   `CHANGELOG.md`, add `release-notes/<version>.md`, then commit and let the normal
   tests finish.
2. Ensure KeyKeeper contains the Apple notarization credential named
   `app专用密码-swob` (or set `KEYKEEPER_NOTARY_CREDENTIAL_ID` to another credential ID),
   with fields `apple-id`, `apple-team-id`, and `apple-app-specific-password`.
3. Run `./scripts/prepare-update.sh`. It builds and notarizes the Developer ID-signed
   DMG, then creates a signed `appcast.xml`, but changes nothing remotely.
4. Inspect the candidate and get explicit approval to publish.
5. Run `./scripts/publish-update.sh --confirm-version <version>`. It creates and pushes
   the tag, publishes the DMG on GitHub Releases, then commits the appcast. That final
   push makes the update visible to installed apps.

Do not hand-edit `appcast.xml` after generation: signed feeds reject any modification.
If publishing fails after the tag or GitHub Release is created, leave the appcast
unpublished and inspect the existing remote state before retrying.
