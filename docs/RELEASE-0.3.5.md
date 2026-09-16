# 0.3.5 release envelope — 2026-09-16

Base: `99bb2cb` (Claude dotenv import), plus all completed commits since v0.3.4.
User explicitly requested 0.3.5 and confirmed public GitHub/feed/website publication.
During preparation Claude committed `ce8dbde` (licensing); public publication of that change
is a separate user gate. No license text was authored or altered by this release task.

## Must deliver

- Retain dotenv import, 113 providers, bundled Agent plugins and previous UI fixes.
- Import values never appear in plain metadata or CLI output; unsupported parsing must not silently truncate a value. Failed readback must not leave committed missing-value metadata.
- Full existing unit/plugin/build gates, signed isolated E2E and native synthetic import prompt smoke.
- Versioned notes, Developer ID-signed/notarized/stapled DMG, signature-verified update feed, GitHub Release and website download link.

## Not in this batch

- No real dotenv import, key rotation, store migration, authorization changes, automatic local installation or hook restoration.
- No new provider, UI redesign, shell evaluation, multiline dotenv grammar or general transactional-store redesign.

Only data loss/corruption, secret exposure, unauthorized writes, broken startup/core behavior or a direct violation above blocks this candidate. Future enhancements stay below.

## Known limits

- Empty/reserved/non-round-trippable variable names are skipped; shell expansion is never performed, malformed/multiline input is rejected. Originals remain untouched.
- Existing metadata/Keychain writes are separate persistence operations. An uncertain metadata failure preserves stored values for recovery; do not blindly retry or overwrite.
- Isolated E2E uses synthetic data; it is not a test of every provider's live account.
- This public release does not itself replace the developer's currently installed App.

## Evidence (append at completion)

- Red tests: `/tmp/kk-035-env-red.log` and `/tmp/kk-035-controller-red.log` reproduced classification, parsing and post-commit cleanup failures.
- Directed fixes: `/tmp/kk-035-env-final.log`, 15 tests, zero failures.
- Full gate: `/tmp/kk-035-full.log`, 852 tests / 13 opt-in skips / zero failures, plugin gate and build pass.
- Signed isolated E2E: `/tmp/kk-035-e2e.log`, 57/57, including protected ordinary settings through real App/CLI IPC.
- Native synthetic import: real signed candidate, independent data/Keychain/socket; previewed three field names and one skipped name, expanded/collapsed details with intact corners, approved synthetic import, asserted three protected fields and no metadata values. Test App then exited and cleaned its isolated Keychain items. No real credentials read or written.
- Website build: `/tmp/kk-035-site-build.log`, production build passed; not yet deployed at candidate freeze.
