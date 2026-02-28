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

**Python:**
```python
from keykeeper import get_key, get_field

# get_key() retrieves secret values from Keychain at runtime
secret = get_key("credential-id", "field-name")

# get_field() retrieves plain-text values
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
3. ALWAYS use `get_key()` / `getKey()` for secret fields
4. Use `keykeeper list --detail` to find the correct credential ID and field names
5. If a needed credential doesn't exist, tell the user to add it via the KeyKeeper app
