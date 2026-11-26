# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

**[Report a vulnerability](https://github.com/IvyYang1999/KeyKeeper/security/advisories/new)**
(GitHub → Security → Report a vulnerability).

It helps to include the KeyKeeper version (Settings → About, or `keykeeper --version`), your
macOS version, and the steps that show the problem. Use made-up keys in anything you send.

Only the latest release is supported. Fixes ship as a new version through the in-app updater.

## What counts

KeyKeeper keeps API keys out of the places they leak by accident. The README says what it protects
against and what it does not: see
[What KeyKeeper protects against, and what it doesn't](README.md#what-keykeeper-protects-against-and-what-it-doesnt).

A report is in scope when KeyKeeper does less than that section says. Examples: a value handed to
a caller nobody approved, an approval window that shows something untrue, a stored value lost or
overwritten without the person choosing it, an update that installs without a valid signature.

Limits the README already states (software running under your macOS account, a command you
approved extracting the value on purpose) are known and not vulnerabilities by themselves, but a
cheap way to make any of them harder is welcome as an ordinary issue.
