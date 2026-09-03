# KeyKeeper

**Secure API key management for AI coding tools.**

KeyKeeper is a macOS menu bar app + CLI + SDK that keeps your API keys in an age-encrypted vault so AI coding assistants (Claude Code, Cursor, Copilot, etc.) never see the raw secrets.

## The Problem

When you use AI coding tools, you often need to provide API keys — for OpenAI, Anthropic, Stripe, databases, etc. The common workflow is dangerous:

1. You paste `sk-abc123...` directly into the chat or a `.env` file
2. The AI sees the raw key and it becomes part of the conversation context
3. Keys end up in logs, training data, or accidentally committed to git

## The Solution

KeyKeeper separates **key storage** from **key usage**:

- You add keys through a **menu bar GUI** — secrets go straight into the encrypted vault
- Your code retrieves keys at runtime via a thin **SDK** (`get_key()`)
- AI tools see only the key *name* (e.g. `"openai-api-key"`), never the value

```
┌─────────────────┐      ┌──────────────┐      ┌─────────────┐
│  KeyKeeper App   │─────▶│  macOS       │◀─────│  SDK / CLI  │
│  (menu bar GUI)  │ save │  Age vault   │ read │  get_key()  │
└─────────────────┘      └──────────────┘      └──────┬──────┘
                                                      │
                                               ┌──────▼──────┐
                                               │  Your Code  │
                                               │  (runtime)  │
                                               └─────────────┘

AI assistant only sees: get_key("openai", "api-key")
AI assistant never sees: sk-abc123...
```

## Quick Start

**Requirements:** macOS 14+ and Swift 5.9+

```bash
# Clone and build
git clone https://github.com/yytyyf/KeyKeeper.git
cd KeyKeeper
swift build

# Run the CLI
swift run keykeeper list

# Run the menu bar app
swift run KeyKeeperApp
```

To install the CLI globally:

```bash
swift build -c release
cp .build/release/keykeeper /usr/local/bin/
```

## CLI Usage

```bash
# List all credentials
keykeeper list

# List with field details (secrets shown as ********)
keykeeper list --detail

# Get a field value (retrieves secret from the unlocked vault)
keykeeper get <credential-id> <field-name>

# Show credential metadata as JSON (no secret values)
keykeeper meta <credential-id>
```

**Examples:**

```bash
$ keykeeper list --detail
openai | OpenAI
  api-key: ********
  org-id: org-abc123

$ keykeeper get openai api-key
sk-abc123...

$ keykeeper meta openai
{
  "fields" : { ... },
  "label" : "OpenAI",
  "security" : "standard"
}
```

## SDK Usage

### Python

```bash
pip install ./sdk-python
```

```python
from keykeeper import get_key, get_field, list_credentials

# List all stored credentials
creds = list_credentials()

# Get a secret value (from the unlocked vault)
api_key = get_key("openai", "api-key")

# Get a plain-text field value
org_id = get_field("openai", "org-id")
```

### Node.js

```bash
npm install ./sdk-node
```

```javascript
const { getKey, getField, listCredentials } = require('keykeeper');

const creds = await listCredentials();
const apiKey = await getKey("openai", "api-key");
const orgId = await getField("openai", "org-id");
```

Both SDKs are thin wrappers around the `keykeeper` CLI binary — no native dependencies needed.

## Claude Code Integration

KeyKeeper ships with a [Claude Code skill](skill/keykeeper.md) that teaches the AI assistant how to use your credentials without ever seeing the secret values.

**Install the skill** (happens automatically on first run, or manually):

```bash
cp skill/keykeeper.md ~/.claude/skills/
```

Once installed, Claude Code will:

1. Run `keykeeper list --detail` to discover your available credentials
2. Use `get_key()` / `getKey()` in generated code to retrieve secrets at runtime
3. Never ask you for API key values or hardcode them

## Security Model

| Layer | What happens |
|-------|-------------|
| **Secret storage** | All secret field values are stored in an age-encrypted vault and are available only during an unlocked session |
| **Metadata storage** | Non-secret fields (labels, notes, links, org IDs) are stored in a plain JSON file at `~/.keykeeper/meta.json` |
| **Standard security** | Secrets are accessible when the Mac is unlocked |
| **Strict security** | Secret access requires explicit per-request approval after the vault is unlocked |
| **AI isolation** | The SDK returns secrets only at runtime in your process — the AI tool never receives secret values in its context |

**What is NOT encrypted:** Credential labels, notes, links, and non-secret field values live in `meta.json` as plain text. Only fields marked as `secret` go into the encrypted vault.

## Project Structure

```
KeyKeeper/
├── Sources/
│   ├── KeyKeeperCore/       # Data models, encrypted vault, meta storage
│   ├── KeyKeeperCLI/        # CLI tool (list, get, meta commands)
│   └── KeyKeeperApp/        # macOS menu bar app (SwiftUI)
├── sdk-python/              # Python SDK (wraps CLI)
├── sdk-node/                # Node.js SDK (wraps CLI)
├── skill/                   # Claude Code skill definition
├── Tests/                   # Unit tests
└── Package.swift            # Swift package manifest
```

## Contributing

Contributions are welcome! Here's how:

1. Fork the repository
2. Create a feature branch: `git checkout -b my-feature`
3. Make your changes and add tests
4. Run tests: `swift test`
5. Submit a pull request

Please keep PRs focused and include a clear description of what changed and why.

## License

[MIT](LICENSE)
