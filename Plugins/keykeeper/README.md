# KeyKeeper for Codex and Claude Code

One shared skill, two native plugin manifests. Requires KeyKeeper App + CLI on the same Mac.
No MCP server, hooks, background daemon, telemetry, or automatic credential authorization.

## 安装 / Install

在 KeyKeeper **设置 → AI 工具接入** 展开 Codex 或 Claude Code，复制安装命令到终端运行。
命令从已安装 App 内的插件包安装，不下载源码、不安装另一个密钥服务。先安装对应工具的 CLI。
Codex 也可以用设置里的「在 Codex 中查看插件」入口；若当前版本不支持该链接，使用命令。

Open **KeyKeeper Settings → AI tool integration**, expand your tool, and run its copied
command in Terminal. Install that tool's CLI first. The package comes from the installed
App. It doesn't require a checkout or Python (Python is only an optional readiness helper).

Then open a **new conversation** and ask:

> 检查 KeyKeeper，帮我使用 API key，不要显示密钥值。
> Check KeyKeeper and help me use my API key without showing its value.

Claude Code also exposes `/keykeeper:keykeeper`. In Codex, select the KeyKeeper skill if
automatic discovery doesn't trigger. Host install/trust prompts remain yours to approve.
Readiness does not fetch credentials. A real operation still follows KeyKeeper's native approval.

## From a checkout (developers)

Run from the repository root — not this plugin subdirectory:

```sh
codex plugin marketplace add .
codex plugin add keykeeper@keykeeper-plugins
```

```sh
claude plugin marketplace add .
claude plugin install keykeeper@keykeeper-plugins
```

The repository's two marketplace indexes resolve to this same directory. Remote GitHub
installation is only available **after these files have been published**; no public registry
approval or release is implied by this package.

## Updates, removal and existing skills

- The App and plugin are versioned separately; plugin installs are cached. After updating
  KeyKeeper, use the host's plugin update action, then start a new conversation. If you moved
  the App, first update the marketplace source to the new path shown in Settings; do not assume
  an already-installed plugin follows the App automatically.
- Claude Code: manage/update/remove `keykeeper@keykeeper-plugins` in `/plugin`.
- Codex: manage/remove KeyKeeper in its plugin UI, or use `codex plugin remove --help`.
- Installing this plugin does not overwrite or remove a standalone skill. If you already
  have one, choose one active source after confirming this plugin works; remove the old one
  only with your approval. Do not keep conflicting versions active.
- Removing the plugin does not delete keys or revoke grants. Revoke access in KeyKeeper when
  desired; disabling a skill is not a credential security boundary.
- Cloud agents and agents on another computer cannot access this Mac through this plugin.

## Limits and safety

The skill guides the agent toward metadata discovery, native save proposals and scoped
environment injection. It does **not** intercept arbitrary tool calls or guarantee model
compliance. Output redaction cannot stop malicious code or secret exfiltration. Don't inject
credentials into untrusted programs or an entire Agent process. Permission decisions remain
with KeyKeeper and the user. The plugin never asks for key values in chat.

Browser automation is provided by the host, not this plugin. Unsupported browser/file routes,
login/MFA and uncertain writes stop at a focused gate. No automatic credential rotation,
bulk `.env` import, password-manager migration or remote-vault connection is included.

Host documentation: [Claude Code plugins](https://code.claude.com/docs/en/plugins).
