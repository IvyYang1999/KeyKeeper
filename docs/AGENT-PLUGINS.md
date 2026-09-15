# Agent plugins · delivery contract (2026-09-15)

## Frozen acceptance envelope

- Ship one shared KeyKeeper workflow with installable Claude Code and Codex manifests.
- Package both marketplace indexes and the plugin inside the signed App; installation must
  work from that local package without a Git checkout, Python, or a public release.
- Add a small, bilingual Settings entry with per-tool installation commands and official
  host documentation. Copying commands never runs them or grants credential access.
- Check CLI readiness without reading secrets, clipboard contents, credential inventories,
  or host authentication/configuration. Handle missing/old CLI and unavailable App honestly.
- Validate both host loaders in disposable configurations, targeted tests, existing Swift
  gates, packaged resource integrity, and the actual Settings interaction in an isolated App.

Non-goals: 1Password adapter, bulk import, MCP secret endpoints, automatic hooks/approvals,
host installation, public marketplace submission, push/release, broad UI redesign.

User gates: host plugin install/trust; KeyKeeper native credential approval; actual credential
creation/replacement; replacing/restarting the user's installed App. Tests use synthetic data.

Blocking risks: secret disclosure, data loss, wrong/unauthorized writes, broken installation
or launch, unbounded work, failure of the explicit acceptance items or existing regressions.
Other improvements are follow-ups, not new blockers.

| Required outcome | Contract / test | Owner |
| --- | --- | --- |
| Shared two-host package | manifests + marketplace source resolution + host loader smoke | Codex |
| Readiness, no secret access | doctor allowlisted commands, fixed output, timeout tests | Codex |
| Settings install entry | command quoting / missing resource tests + isolated visual smoke | Codex |
| App ships exact package | build staging + file digest comparison | Codex |
| Safe use and recovery | shared skill review + existing isolated CLI save/run E2E | Codex |

Mechanical closeout: freeze candidate → full checks → isolated App smoke → record known
limits/results → commit; no restore of the disabled deployment hook, push, or release.

## Result · ACCEPTED (code and locally packaged candidate)

- Shared package: `Plugins/keykeeper`, plugin version `0.1.0`; separate native indexes resolve
  to the same skill. Capitalization intentionally matches the tracked `Plugins` directory on
  case-sensitive filesystems, not just default macOS volumes.
- Five Python package/doctor tests pass. Two Settings command/availability tests and eleven
  localization tests pass. Missing helper dependencies were installed in a disposable validation
  venv only; no runtime installation is required for plugin use.
- Official plugin-creator validator and skill validator pass. Claude Code 2.1.272 validates
  and installs the package; `plugin details` finds exactly one skill and no hooks/MCP servers.
- Both hosts install from the **built App's embedded marketplace** into separate test configs.
  Codex's real app-server `skills/list` identifies `keykeeper:keykeeper`, enabled, owned by
  `keykeeper@keykeeper-plugins`, loaded from the plugin cache. No model/API inference is involved.
- Readiness against the installed CLI reports available/ready with credential access unchecked;
  only help/version/status were queried, not the real credential inventory or values.
- Existing full gate: 801 Swift tests, 11 pre-existing opt-in skips, zero failures; debug build
  passes. Signed release App build and isolated CLI/App E2E: 46 passed, zero failed. Synthetic
  Keychain items are cleaned by the existing isolated harness.
- Native Computer Use confirms Settings → AI tool integration, both disclosure groups,
  copy-button success feedback, vertical scrolling, and command wrapping at ~773 px width.
  The test App uses isolated data/Keychain/socket; the real App was not replaced during testing.

### Known limits / next release

- No public push, registry publication, notarization or release in this batch. Public GitHub
  plugin installation becomes available only after these files are published.
- Codex deep-link parameters are unit-tested and its native plugin loader is verified. The
  final desktop preview cannot be visually inspected because Computer Use disallows controlling
  the Codex app; the tested CLI install path remains available. Claude's official documentation
  link is separate from the local install command.
- The old onboarding/standalone skill remains compatible and isn't silently removed. New users
  should use the plugins entry; unifying that older onboarding is follow-up UI work.
- This is skill-based integration, not a tool-call firewall. No promise of universal model
  compliance, secret-proof arbitrary subprocesses, cloud access, or automatic host updates.
- No real credential operation or live Agent inference was needed for acceptance. The existing
  synthetic App/CLI E2E covers safe import/run; a real task still requires native authorization.

User subsequently approved installing/restarting the local App, with no automatic Agent plugin
installation. Deployment closeout: retain old App/CLI, rebuild the committed candidate, rerun
isolated E2E, compare signing requirements, replace App/CLI, verify startup and bundled resources.
