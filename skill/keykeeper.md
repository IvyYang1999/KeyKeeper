---
name: keykeeper
description: Use when user mentions API keys, secrets, credentials, or KeyKeeper. Also use proactively when writing code that needs API keys or secrets.
---

# KeyKeeper - API Key Management

The user's API keys and credentials are managed by KeyKeeper.
Secret values are stored in macOS Keychain and MUST NOT appear in this conversation.

## Discovering Available Credentials

Run `keykeeper list --detail` to see all available credentials with their plain-text fields.
Secret field values are shown as `********` — this is expected.

## Using Credentials in Code

### Option A: Process-Level Injection (Recommended)

Use `keykeeper run` to inject secrets as environment variables into a subprocess.
Secrets only exist in the subprocess memory — they never appear in stdout or this conversation.

```bash
# Inject all secret fields from a credential as env vars
keykeeper run -c <credential-id> -- python script.py

# Inject from multiple credentials
keykeeper run -c stripe -c openai -- node server.js

# Add prefix to avoid naming conflicts
keykeeper run -c stripe --prefix STRIPE_ -- python script.py
```

Write code that reads from environment variables:

**Python:**
```python
import os
api_key = os.environ["API_KEY"]
```

**Node.js:**
```javascript
const apiKey = process.env.API_KEY;
```

Field names are converted to env var names automatically:
`api-key` → `API_KEY`, `base url` → `BASE_URL`

Use `--verbose` to see which variable names are injected (values are never printed).

### Option B: SDK Runtime Access

Use the SDK when you need secrets inside application logic rather than as env vars.

**Python:**
```python
from keykeeper import get_key, get_field

secret = get_key("credential-id", "field-name")
value = get_field("credential-id", "field-name")
```

**Node.js:**
```javascript
const { getKey, getField } = require('keykeeper');

const secret = await getKey("credential-id", "field-name");
const value = await getField("credential-id", "field-name");
```

## Rules

1. NEVER ask the user for API key values, secrets, or passwords
2. NEVER hardcode secret values in source code
3. NEVER print, log, or output the return value of `get_key()` / `getKey()` / `os.environ["SECRET"]`
4. Prefer `keykeeper run` (Option A) over SDK calls when possible — it provides stronger isolation
5. ALWAYS use `get_key()` / `getKey()` or `os.environ` for secret fields — never inline values
6. Use `keykeeper list --detail` to find the correct credential ID and field names
7. If a needed credential doesn't exist, tell the user to add it via the KeyKeeper app
