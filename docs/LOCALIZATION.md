# Chinese UI — acceptance envelope (2026-09-11)

Deliver Simplified Chinese and English for the macOS list/detail/add/settings/setup,
authorization/save prompts, status menu and local browser import page. Add an App-only
System / 简体中文 / English preference; changing it must not change the macOS language,
credentials, grants, IDs, commands, CLI protocol or security semantics. Keep unknown strings
and unsupported languages on a readable English fallback. No website/CLI/manual translation,
Traditional Chinese, new permissions, release/push or hook restoration in this batch.

| Must deliver | Implementation | Gate |
| --- | --- | --- |
| Selection, fallback and argument preservation | App language resolver + central catalog | en/zh/system/fallback/interpolation tests |
| Settings choice updates visible UI | AppStorage + native picker | Real language-switch smoke |
| Main pages and approval/import copy | Explicit localized UI literals | Catalog coverage + Chinese/English GUI and browser checks |
| Existing behavior unchanged | No data/protocol/security changes | Existing English regression; synthetic fixtures only |
| Installed result | Signed App + matching CLI + backup | Full tests/build, installed hashes/version, real UI |

Blockers: data loss, secrets/privacy exposure, wrong/unauthorized writes, unusable startup or
core UI, unbounded work, existing regressions, or direct violations of this envelope. Other
polish is follow-up. Unit-test baseline language is English (`KEYKEEPER_UI_LANGUAGE=en`);
new tests exercise Chinese and language resolution explicitly. Isolated UI runs may use the
same bounded language override without changing persisted user preferences.

The system's preferred language is currently English first. After validation, choose 简体中文
inside KeyKeeper for this user, leaving the system language untouched. Keep original dirty
file modes/unrelated edits, existing credential backups and disabled deployment hooks.

## Implementation and bounded verification

- `L` interpolates only fixed templates; arguments are inserted once, never translated.
  The English catalog is the fallback; placeholder parity is tested across the Chinese catalog.
- AppStorage changes only `interfaceLanguage`. No view identity reset, draft reset, data migration,
  protocol change or grant-duration raw-value change is introduced.
- Browser copy is HTML-escaped or JSON-quoted; script-closing text is escaped independently.
- Real signed isolated App checked: English settings → Chinese, restart persistence, settings
  scrolling, add/more-options, file detail, native file-save approval/cancel, strict authorization
  with expanded caller details/deny, browser import/cancel. No real secret values were displayed.
- CLI test invocations MUST use all three overrides together: `KEYKEEPER_DATA_DIR`,
  `KEYKEEPER_KEYCHAIN_SERVICE` (`com.keykeeper.test.*`), and `KEYKEEPER_TEST_SOCKET`.
  A socket override alone is rejected and falls back to production. Use one explicit wrapper for
  every test CLI invocation, not manually repeated subsets. Close production during visual tests
  to avoid same-bundle window ambiguity.

Known limits: CLI/help/manual/site copy remains English. Apple-owned dialogs and updater UI may
follow the system language; unknown errors fall back to the underlying message. Already-open
approval windows keep the language in which they were created. No Traditional Chinese-specific
catalog. Existing startup/unlock explanatory copy is not redesigned in this language-only batch.

Test-operation incident: one synthetic `chinese-file-fixture` file credential was accidentally
created in production after a CLI invocation omitted two isolation overrides. It contained only
the synthetic fixture, used create-only semantics and did not overwrite any existing credential.
GUI deletion was refused by the existing missing-values recovery protection. The protection was
not bypassed; this harmless test entry remains a cleanup follow-up separate from localization.
Subsequent requests used the complete isolated wrapper and independent test storage.
