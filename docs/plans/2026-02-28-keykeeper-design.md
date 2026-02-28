# KeyKeeper Design Document

## 概述

KeyKeeper 是一个 macOS 菜单栏应用，帮助开发者安全管理 API key，并与 AI 编程工具（如 Claude Code）无缝集成。核心理念：**AI 知道 key 的名字和上下文，但永远不接触 key 的值。**

## 问题

开发者在使用 AI 编程工具时，常常将 API key 直接粘贴到对话上下文中，导致泄露风险。现有工具（1Password CLI、direnv、Doppler）要么需要命令行操作，要么配置复杂，摩擦过大导致开发者绕过安全措施。

## 目标用户

独立开发者，使用 macOS，日常使用 AI 编程工具（Claude Code、Cursor 等），管理 10-50 个 API key。

## MVP 范围

### 包含
- macOS 菜单栏 App（SwiftUI）
- CLI 工具（Swift）
- Python SDK
- Node.js SDK
- Claude Code Skill

### 不包含
- 跨平台支持（Windows/Linux）
- 团队协作 / 共享 key
- 云端同步
- 自动轮换 key
- 费用监控
- MCP Server

---

## 架构

```
┌──────────────────────────────────────────────────────┐
│                     KeyKeeper                        │
│                                                      │
│  ┌──────────────┐  ┌───────────┐  ┌──────────────┐  │
│  │ 菜单栏 App   │  │   CLI     │  │ SDK (Py/Node)│  │
│  │ (SwiftUI)    │  │  (Swift)  │  │              │  │
│  └──────┬───────┘  └─────┬─────┘  └──────┬───────┘  │
│         │                │               │           │
│         ▼                ▼               ▼           │
│  ┌──────────────────────────────────────────────┐    │
│  │           macOS Keychain（密钥字段）          │    │
│  └──────────────────────────────────────────────┘    │
│  ┌──────────────────────────────────────────────┐    │
│  │    ~/Library/Application Support/KeyKeeper/  │    │
│  │         meta.json（元数据 + 明文字段）        │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  ┌──────────────┐                                    │
│  │ Claude Code  │ ← Skill 引导 AI 使用 CLI/SDK      │
│  │   Skill      │                                    │
│  └──────────────┘                                    │
└──────────────────────────────────────────────────────┘
```

### 数据流

- **写入**：用户通过菜单栏 App GUI → 密钥存入 Keychain，元数据存入 meta.json
- **读取（AI 上下文）**：`keykeeper list --detail` → 返回名称、备注、明文字段（不含密钥值）
- **读取（运行时）**：代码调用 SDK `get_key()` → SDK 调用 CLI → CLI 调用 Keychain API → macOS 授权 → 返回值到进程内存

---

## 数据模型

### 存储分离

| 数据类型 | 存储位置 | AI 可见 |
|---------|---------|---------|
| 密钥值（API Key、Secret） | macOS Keychain（加密） | 不可见 |
| 元数据（名称、备注、链接、明文字段） | meta.json | 可见 |

### meta.json 结构

```json
{
  "version": 1,
  "credentials": {
    "feishu-bot-hr": {
      "label": "飞书机器人 - HR 助手",
      "notes": "人事部门用的机器人，周一到周五活跃",
      "links": ["https://open.feishu.cn/app/cli_xxxxx"],
      "fields": {
        "app_id":     { "value": "cli_a1234567", "secret": false },
        "base_url":   { "value": "https://open.feishu.cn", "secret": false },
        "app_secret": { "secret": true }
      },
      "security": "standard",
      "created": "2026-02-28",
      "updated": "2026-02-28"
    },
    "anthropic": {
      "label": "Anthropic Claude API",
      "notes": "主力模型，按量付费",
      "links": ["https://console.anthropic.com/settings/keys"],
      "fields": {
        "api_key": { "secret": true }
      },
      "security": "standard",
      "created": "2026-02-28",
      "updated": "2026-02-28"
    }
  }
}
```

### Keychain 存储约定

- Service: `keykeeper.<credential-id>.<field-name>`（如 `keykeeper.feishu-bot-hr.app_secret`）
- Account: `keykeeper`

### 安全级别

| 级别 | Keychain 访问策略 | 适用场景 |
|------|------------------|---------|
| standard | 首次弹窗，"始终允许"后不再弹 | OpenAI key、测试环境 |
| strict | 每次访问需 Touch ID | Stripe 生产 key、支付相关 |

---

## 组件设计

### 1. 菜单栏 App（SwiftUI）

**功能：**
- 凭证列表：显示所有凭证，搜索/筛选
- 添加凭证：名称、备注、链接、动态字段（明文/密钥）
- 编辑凭证：修改任意字段，更新 key 值
- 删除凭证：同时删除 Keychain 条目和元数据
- 首次引导：安装 CLI（`/usr/local/bin/keykeeper`）+ 安装 Claude Code Skill

**技术：**
- SwiftUI + AppKit（NSStatusItem 菜单栏）
- Security.framework（Keychain 操作）
- 最低支持 macOS 13

### 2. CLI（Swift Package）

```
keykeeper list [--detail]     列出所有凭证（--detail 显示明文字段）
keykeeper get <id> <field>    获取字段值（密钥字段从 Keychain 读取）
keykeeper meta <id>           输出凭证的完整元数据（JSON，不含密钥值）
```

CLI 和 App 共享同一个 Keychain 和 meta.json，不需要 App 在后台运行。

### 3. Python SDK

```python
from keykeeper import get_key, get_field, list_credentials

# 获取密钥（从 Keychain，可能触发 Touch ID）
secret = get_key("feishu-bot-hr", "app_secret")

# 获取明文字段（从 meta.json）
app_id = get_field("feishu-bot-hr", "app_id")

# 列出所有凭证名称
creds = list_credentials()  # ["feishu-bot-hr", "feishu-bot-ops", "anthropic"]
```

内部实现：调用 `keykeeper` CLI，解析输出。

### 4. Node.js SDK

```javascript
const { getKey, getField, listCredentials } = require('keykeeper');

const secret = await getKey("feishu-bot-hr", "app_secret");
const appId = await getField("feishu-bot-hr", "app_id");
const creds = await listCredentials();
```

### 5. Claude Code Skill

```markdown
name: keykeeper
description: Use when user mentions API keys, secrets, credentials, or KeyKeeper

用户的 API key 和凭证由 KeyKeeper 管理。

获取可用凭证列表：运行 `keykeeper list --detail`
在代码中使用：
  Python: `from keykeeper import get_key, get_field`
  Node:   `const { getKey, getField } = require('keykeeper')`
绝对不要向用户索要 API key、secret 或密码的值。
```

安装位置：`~/.claude/commands/keykeeper.md`（全局 skill）

---

## 菜单栏 App UI

### 主界面（凭证列表）

```
┌────────────────────────────────────┐
│  🔑 KeyKeeper        [🔍] [+]     │
├────────────────────────────────────┤
│                                    │
│  飞书机器人 - HR 助手              │
│  app_id: cli_a1234  🔒 app_secret │
│                                    │
│  飞书机器人 - 运维告警              │
│  app_id: cli_b9876  🔒 app_secret │
│                                    │
│  Anthropic Claude API              │
│  🔒 api_key                        │
│                                    │
├────────────────────────────────────┤
│  ⚙️ 设置                           │
└────────────────────────────────────┘
```

### 添加/编辑凭证

```
┌─────────────────────────────────────┐
│  添加凭证                            │
│                                      │
│  名称：[                            ]│
│  备注：[                            ]│
│  链接：[                       ] [+] │
│                                      │
│  字段：                              │
│  ┌────────────┬──────────┬────────┐ │
│  │ 字段名      │ 值       │ 类型   │ │
│  ├────────────┼──────────┼────────┤ │
│  │ app_id     │ cli_1234 │ 🔓明文 │ │
│  │ app_secret │ ******** │ 🔒密钥 │ │
│  └────────────┴──────────┴────────┘ │
│  [+ 添加字段]                        │
│                                      │
│  安全级别：◉ 标准  ○ 严格(Touch ID)  │
│                                      │
│  [取消]              [保存]          │
└─────────────────────────────────────┘
```

---

## 技术栈

| 组件 | 技术 |
|------|------|
| 菜单栏 App | Swift, SwiftUI, AppKit, Security.framework |
| CLI | Swift Package Manager, ArgumentParser |
| Python SDK | Python 3.8+, subprocess, PyPI 发布 |
| Node SDK | Node 16+, child_process, npm 发布 |
| Skill | Markdown 文件 |

## 开源

- GitHub 仓库：`KeyKeeper`
- 许可证：MIT
- 语言：Swift（App + CLI），Python（SDK），JavaScript（SDK）
