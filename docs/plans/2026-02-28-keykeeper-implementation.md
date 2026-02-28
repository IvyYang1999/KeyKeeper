# KeyKeeper Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS menu bar app that securely manages API keys via Keychain, with CLI/SDK for AI coding tools to access keys without exposing them in conversation context.

**Architecture:** SwiftUI menu bar app stores secrets in macOS Keychain and metadata in a local JSON file. A Swift CLI reads both stores. Python/Node SDKs wrap the CLI. A Claude Code Skill teaches AI to use the SDK instead of asking for keys.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Security.framework / Swift ArgumentParser / Python / Node.js

---

### Task 1: Project Scaffolding + Git Init

**Files:**
- Create: `Package.swift`
- Create: `Sources/KeyKeeperCore/Models.swift`
- Create: `Sources/KeyKeeperCLI/main.swift`
- Create: `.gitignore`
- Create: `README.md`
- Create: `LICENSE`

**Step 1: Initialize git repo**

```bash
cd ~/Projects/KeyKeeper
git init
```

**Step 2: Create `.gitignore`**

```gitignore
.DS_Store
.build/
*.xcodeproj
xcuserdata/
DerivedData/
.swiftpm/
__pycache__/
*.egg-info/
dist/
node_modules/
```

**Step 3: Create `LICENSE` (MIT)**

Standard MIT license with year 2026.

**Step 4: Create `Package.swift` for shared core + CLI**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyKeeper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "keykeeper", targets: ["KeyKeeperCLI"]),
        .library(name: "KeyKeeperCore", targets: ["KeyKeeperCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "KeyKeeperCore",
            dependencies: []
        ),
        .executableTarget(
            name: "KeyKeeperCLI",
            dependencies: [
                "KeyKeeperCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "KeyKeeperCoreTests",
            dependencies: ["KeyKeeperCore"]
        ),
    ]
)
```

**Step 5: Create stub files**

`Sources/KeyKeeperCore/Models.swift`:
```swift
import Foundation
// Placeholder - will be implemented in Task 2
```

`Sources/KeyKeeperCLI/main.swift`:
```swift
import ArgumentParser
// Placeholder - will be implemented in Task 4
```

**Step 6: Verify build**

Run: `cd ~/Projects/KeyKeeper && swift build`
Expected: BUILD SUCCEEDED

**Step 7: Create README.md**

Brief description: "KeyKeeper - Secure API key management for AI coding tools. macOS menu bar app + CLI + SDK."

**Step 8: Commit**

```bash
git add .gitignore LICENSE Package.swift Sources/ Tests/ README.md docs/
git commit -m "chore: initial project scaffolding with Swift Package"
```

---

### Task 2: Core Data Models + Meta Storage

**Files:**
- Create: `Sources/KeyKeeperCore/Models.swift`
- Create: `Sources/KeyKeeperCore/MetaStore.swift`
- Create: `Tests/KeyKeeperCoreTests/ModelsTests.swift`
- Create: `Tests/KeyKeeperCoreTests/MetaStoreTests.swift`

**Step 1: Write failing tests for Models**

`Tests/KeyKeeperCoreTests/ModelsTests.swift`:
```swift
import XCTest
@testable import KeyKeeperCore

final class ModelsTests: XCTestCase {
    func testCredentialFieldPlain() {
        let field = CredentialField(value: "cli_abc123", secret: false)
        XCTAssertEqual(field.value, "cli_abc123")
        XCTAssertFalse(field.secret)
    }

    func testCredentialFieldSecret() {
        let field = CredentialField(value: nil, secret: true)
        XCTAssertNil(field.value)
        XCTAssertTrue(field.secret)
    }

    func testCredentialCodable() throws {
        let cred = Credential(
            label: "Test API",
            notes: "some notes",
            links: ["https://example.com"],
            fields: [
                "api_key": CredentialField(value: nil, secret: true),
                "base_url": CredentialField(value: "https://api.example.com", secret: false)
            ],
            security: .standard,
            created: "2026-02-28",
            updated: "2026-02-28"
        )
        let data = try JSONEncoder().encode(cred)
        let decoded = try JSONDecoder().decode(Credential.self, from: data)
        XCTAssertEqual(decoded.label, "Test API")
        XCTAssertEqual(decoded.fields["base_url"]?.value, "https://api.example.com")
        XCTAssertTrue(decoded.fields["api_key"]?.secret ?? false)
    }

    func testMetaFileCodable() throws {
        let meta = MetaFile(version: 1, credentials: [
            "test-api": Credential(
                label: "Test", notes: "", links: [],
                fields: ["key": CredentialField(value: nil, secret: true)],
                security: .standard, created: "2026-02-28", updated: "2026-02-28"
            )
        ])
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(MetaFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.credentials.count, 1)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ~/Projects/KeyKeeper && swift test`
Expected: FAIL - types not defined

**Step 3: Implement Models**

`Sources/KeyKeeperCore/Models.swift`:
```swift
import Foundation

public enum SecurityLevel: String, Codable, Sendable {
    case standard
    case strict
}

public struct CredentialField: Codable, Sendable {
    public var value: String?
    public var secret: Bool

    public init(value: String? = nil, secret: Bool) {
        self.value = value
        self.secret = secret
    }
}

public struct Credential: Codable, Sendable {
    public var label: String
    public var notes: String
    public var links: [String]
    public var fields: [String: CredentialField]
    public var security: SecurityLevel
    public var created: String
    public var updated: String

    public init(label: String, notes: String, links: [String],
                fields: [String: CredentialField], security: SecurityLevel,
                created: String, updated: String) {
        self.label = label
        self.notes = notes
        self.links = links
        self.fields = fields
        self.security = security
        self.created = created
        self.updated = updated
    }
}

public struct MetaFile: Codable, Sendable {
    public var version: Int
    public var credentials: [String: Credential]

    public init(version: Int = 1, credentials: [String: Credential] = [:]) {
        self.version = version
        self.credentials = credentials
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelsTests`
Expected: All tests PASS

**Step 5: Write failing tests for MetaStore**

`Tests/KeyKeeperCoreTests/MetaStoreTests.swift`:
```swift
import XCTest
@testable import KeyKeeperCore

final class MetaStoreTests: XCTestCase {
    var tmpDir: URL!
    var store: MetaStore!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = MetaStore(directory: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadCreatesDefaultWhenMissing() throws {
        let meta = try store.load()
        XCTAssertEqual(meta.version, 1)
        XCTAssertTrue(meta.credentials.isEmpty)
    }

    func testSaveAndLoad() throws {
        var meta = MetaFile()
        meta.credentials["test"] = Credential(
            label: "Test", notes: "n", links: [],
            fields: ["k": CredentialField(secret: true)],
            security: .standard, created: "2026-02-28", updated: "2026-02-28"
        )
        try store.save(meta)
        let loaded = try store.load()
        XCTAssertEqual(loaded.credentials.count, 1)
        XCTAssertEqual(loaded.credentials["test"]?.label, "Test")
    }
}
```

**Step 6: Run tests to verify they fail**

Run: `swift test --filter MetaStoreTests`
Expected: FAIL - MetaStore not defined

**Step 7: Implement MetaStore**

`Sources/KeyKeeperCore/MetaStore.swift`:
```swift
import Foundation

public final class MetaStore: Sendable {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("meta.json")
    }

    public static var `default`: MetaStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyKeeper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetaStore(directory: dir)
    }

    public func load() throws -> MetaFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return MetaFile()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(MetaFile.self, from: data)
    }

    public func save(_ meta: MetaFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(meta)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

**Step 8: Run all tests**

Run: `swift test`
Expected: All tests PASS

**Step 9: Commit**

```bash
git add Sources/KeyKeeperCore/ Tests/KeyKeeperCoreTests/
git commit -m "feat: core data models and meta.json storage"
```

---

### Task 3: Keychain Service

**Files:**
- Create: `Sources/KeyKeeperCore/KeychainService.swift`
- Create: `Tests/KeyKeeperCoreTests/KeychainServiceTests.swift`

**Step 1: Write failing tests**

`Tests/KeyKeeperCoreTests/KeychainServiceTests.swift`:
```swift
import XCTest
@testable import KeyKeeperCore

final class KeychainServiceTests: XCTestCase {
    let service = KeychainService()
    let testCredId = "test-\(UUID().uuidString)"

    override func tearDown() {
        try? service.delete(credentialId: testCredId, fieldName: "api_key")
    }

    func testSaveAndRetrieve() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "sk-test-123", security: .standard)
        let value = try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        XCTAssertEqual(value, "sk-test-123")
    }

    func testRetrieveNonExistent() {
        XCTAssertThrowsError(
            try service.retrieve(credentialId: "nonexistent", fieldName: "key")
        )
    }

    func testUpdate() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "old-value", security: .standard)
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "new-value", security: .standard)
        let value = try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        XCTAssertEqual(value, "new-value")
    }

    func testDelete() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "to-delete", security: .standard)
        try service.delete(credentialId: testCredId, fieldName: "api_key")
        XCTAssertThrowsError(
            try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        )
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter KeychainServiceTests`
Expected: FAIL - KeychainService not defined

**Step 3: Implement KeychainService**

`Sources/KeyKeeperCore/KeychainService.swift`:
```swift
import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case notFound
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Keychain save failed: \(s)"
        case .notFound: return "Key not found in Keychain"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        case .unexpectedData: return "Unexpected data format in Keychain"
        }
    }
}

public final class KeychainService: Sendable {
    public init() {}

    private func serviceName(credentialId: String, fieldName: String) -> String {
        "keykeeper.\(credentialId).\(fieldName)"
    }

    public func save(credentialId: String, fieldName: String,
                     value: String, security: SecurityLevel) throws {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let data = Data(value.utf8)

        // Try to delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
            kSecValueData as String: data,
        ]

        if security == .strict {
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence, nil
            )
            if let access = access {
                addQuery[kSecAttrAccessControl as String] = access
            }
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func retrieve(credentialId: String, fieldName: String) throws -> String {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.notFound
        }
        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    public func delete(credentialId: String, fieldName: String) throws {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter KeychainServiceTests`
Expected: All PASS (may prompt for Keychain access on first run)

**Step 5: Commit**

```bash
git add Sources/KeyKeeperCore/KeychainService.swift Tests/KeyKeeperCoreTests/KeychainServiceTests.swift
git commit -m "feat: Keychain service for secure secret storage"
```

---

### Task 4: CLI Tool

**Files:**
- Modify: `Sources/KeyKeeperCLI/main.swift` → full rewrite
- Create: `Sources/KeyKeeperCLI/ListCommand.swift`
- Create: `Sources/KeyKeeperCLI/GetCommand.swift`
- Create: `Sources/KeyKeeperCLI/MetaCommand.swift`

**Step 1: Implement CLI entry point**

`Sources/KeyKeeperCLI/main.swift`:
```swift
import ArgumentParser

@main
struct KeyKeeperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keykeeper",
        abstract: "Secure API key management for AI coding tools",
        subcommands: [ListCommand.self, GetCommand.self, MetaCommand.self]
    )
}
```

**Step 2: Implement ListCommand**

`Sources/KeyKeeperCLI/ListCommand.swift`:
```swift
import ArgumentParser
import KeyKeeperCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all stored credentials"
    )

    @Flag(name: .long, help: "Show plain-text field values")
    var detail = false

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        if meta.credentials.isEmpty {
            print("No credentials stored. Use the KeyKeeper app to add credentials.")
            return
        }

        for (id, cred) in meta.credentials.sorted(by: { $0.key < $1.key }) {
            print("\(id) | \(cred.label)")
            if detail {
                if !cred.notes.isEmpty {
                    print("  notes: \(cred.notes)")
                }
                for link in cred.links {
                    print("  link: \(link)")
                }
                for (fieldName, field) in cred.fields.sorted(by: { $0.key < $1.key }) {
                    if field.secret {
                        print("  \(fieldName): ********")
                    } else {
                        print("  \(fieldName): \(field.value ?? "")")
                    }
                }
            }
            print()
        }
    }
}
```

**Step 3: Implement GetCommand**

`Sources/KeyKeeperCLI/GetCommand.swift`:
```swift
import ArgumentParser
import KeyKeeperCore

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a field value for a credential"
    )

    @Argument(help: "Credential ID")
    var credentialId: String

    @Argument(help: "Field name")
    var fieldName: String

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        guard let cred = meta.credentials[credentialId] else {
            throw ValidationError("Credential '\(credentialId)' not found")
        }
        guard let field = cred.fields[fieldName] else {
            throw ValidationError("Field '\(fieldName)' not found in '\(credentialId)'")
        }

        if field.secret {
            let keychain = KeychainService()
            let value = try keychain.retrieve(credentialId: credentialId, fieldName: fieldName)
            print(value, terminator: "")
        } else {
            print(field.value ?? "", terminator: "")
        }
    }
}
```

**Step 4: Implement MetaCommand**

`Sources/KeyKeeperCLI/MetaCommand.swift`:
```swift
import ArgumentParser
import Foundation
import KeyKeeperCore

struct MetaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meta",
        abstract: "Show credential metadata as JSON (no secret values)"
    )

    @Argument(help: "Credential ID")
    var credentialId: String

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        guard let cred = meta.credentials[credentialId] else {
            throw ValidationError("Credential '\(credentialId)' not found")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cred)
        print(String(data: data, encoding: .utf8)!)
    }
}
```

**Step 5: Build and verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

Run: `swift run keykeeper --help`
Expected: Shows help with list, get, meta subcommands

Run: `swift run keykeeper list`
Expected: "No credentials stored." or lists existing credentials

**Step 6: Commit**

```bash
git add Sources/KeyKeeperCLI/
git commit -m "feat: CLI tool with list, get, and meta commands"
```

---

### Task 5: Python SDK

**Files:**
- Create: `sdk-python/pyproject.toml`
- Create: `sdk-python/keykeeper/__init__.py`
- Create: `sdk-python/tests/test_keykeeper.py`

**Step 1: Create pyproject.toml**

```toml
[build-system]
requires = ["setuptools>=68.0"]
build-backend = "setuptools.backends._legacy:_Backend"

[project]
name = "keykeeper"
version = "0.1.0"
description = "Secure API key access for AI coding tools"
readme = "README.md"
license = {text = "MIT"}
requires-python = ">=3.8"

[project.urls]
Homepage = "https://github.com/user/KeyKeeper"
```

**Step 2: Write failing tests**

`sdk-python/tests/test_keykeeper.py`:
```python
import subprocess
import unittest
from unittest.mock import patch, MagicMock
from keykeeper import list_credentials, get_field, get_key, KeyKeeperError


class TestListCredentials(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_list_parses_output(self, mock_run):
        mock_run.return_value = MagicMock(
            stdout="stripe | Stripe API\n\nopenai | OpenAI\n\n",
            returncode=0,
        )
        result = list_credentials()
        self.assertEqual(result, ["stripe", "openai"])

    @patch("keykeeper.subprocess.run")
    def test_list_empty(self, mock_run):
        mock_run.return_value = MagicMock(
            stdout="No credentials stored. Use the KeyKeeper app to add credentials.\n",
            returncode=0,
        )
        result = list_credentials()
        self.assertEqual(result, [])


class TestGetField(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_get_field_returns_value(self, mock_run):
        mock_run.return_value = MagicMock(stdout="cli_abc123", returncode=0)
        result = get_field("feishu", "app_id")
        self.assertEqual(result, "cli_abc123")

    @patch("keykeeper.subprocess.run")
    def test_get_field_not_found(self, mock_run):
        mock_run.return_value = MagicMock(
            stdout="", stderr="Error: Credential 'x' not found", returncode=1
        )
        with self.assertRaises(KeyKeeperError):
            get_field("x", "y")


class TestGetKey(unittest.TestCase):
    @patch("keykeeper.subprocess.run")
    def test_get_key_returns_secret(self, mock_run):
        mock_run.return_value = MagicMock(stdout="sk_live_xxx", returncode=0)
        result = get_key("stripe", "api_key")
        self.assertEqual(result, "sk_live_xxx")


if __name__ == "__main__":
    unittest.main()
```

**Step 3: Run tests to verify they fail**

Run: `cd ~/Projects/KeyKeeper/sdk-python && python3 -m pytest tests/ -v`
Expected: FAIL - module not found

**Step 4: Implement Python SDK**

`sdk-python/keykeeper/__init__.py`:
```python
import subprocess
import shutil

__version__ = "0.1.0"


class KeyKeeperError(Exception):
    pass


def _find_cli():
    path = shutil.which("keykeeper")
    if path:
        return path
    # Fallback: check common install locations
    for p in ["/usr/local/bin/keykeeper", "/opt/homebrew/bin/keykeeper"]:
        import os
        if os.path.isfile(p):
            return p
    raise KeyKeeperError(
        "keykeeper CLI not found. Install KeyKeeper from https://github.com/user/KeyKeeper"
    )


def _run(*args):
    cli = _find_cli()
    result = subprocess.run(
        [cli] + list(args), capture_output=True, text=True
    )
    if result.returncode != 0:
        raise KeyKeeperError(result.stderr.strip() or f"keykeeper exited with code {result.returncode}")
    return result.stdout


def list_credentials():
    output = _run("list")
    if "No credentials stored" in output:
        return []
    names = []
    for line in output.strip().split("\n"):
        line = line.strip()
        if " | " in line:
            names.append(line.split(" | ")[0].strip())
    return names


def get_field(credential_id, field_name):
    return _run("get", credential_id, field_name)


def get_key(credential_id, field_name):
    return _run("get", credential_id, field_name)
```

**Step 5: Run tests**

Run: `cd ~/Projects/KeyKeeper/sdk-python && python3 -m pytest tests/ -v`
Expected: All PASS

**Step 6: Commit**

```bash
git add sdk-python/
git commit -m "feat: Python SDK wrapping keykeeper CLI"
```

---

### Task 6: Node.js SDK

**Files:**
- Create: `sdk-node/package.json`
- Create: `sdk-node/src/index.js`
- Create: `sdk-node/tests/index.test.js`

**Step 1: Create package.json**

```json
{
  "name": "keykeeper",
  "version": "0.1.0",
  "description": "Secure API key access for AI coding tools",
  "main": "src/index.js",
  "scripts": {
    "test": "node --test tests/"
  },
  "license": "MIT"
}
```

**Step 2: Write failing tests**

`sdk-node/tests/index.test.js`:
```javascript
const { describe, it, mock } = require('node:test');
const assert = require('node:assert');
const { listCredentials, getField, getKey } = require('../src/index');

describe('listCredentials', () => {
  it('parses credential names from CLI output', async () => {
    // Integration test - requires keykeeper CLI installed
    // For unit testing, we test the parsing logic
    const result = await listCredentials();
    assert.ok(Array.isArray(result));
  });
});

describe('getField', () => {
  it('throws on nonexistent credential', async () => {
    await assert.rejects(
      () => getField('nonexistent-xyz', 'field'),
      { name: 'Error' }
    );
  });
});
```

**Step 3: Implement Node SDK**

`sdk-node/src/index.js`:
```javascript
const { execFile } = require('node:child_process');
const { which } = require('node:child_process');
const fs = require('node:fs');

function findCli() {
  const paths = [
    '/usr/local/bin/keykeeper',
    '/opt/homebrew/bin/keykeeper',
  ];
  for (const p of paths) {
    if (fs.existsSync(p)) return p;
  }
  throw new Error(
    'keykeeper CLI not found. Install KeyKeeper from https://github.com/user/KeyKeeper'
  );
}

function run(...args) {
  return new Promise((resolve, reject) => {
    const cli = findCli();
    execFile(cli, args, (error, stdout, stderr) => {
      if (error) {
        reject(new Error(stderr.trim() || `keykeeper exited with code ${error.code}`));
        return;
      }
      resolve(stdout);
    });
  });
}

async function listCredentials() {
  const output = await run('list');
  if (output.includes('No credentials stored')) return [];
  return output
    .trim()
    .split('\n')
    .filter(line => line.includes(' | '))
    .map(line => line.split(' | ')[0].trim());
}

async function getField(credentialId, fieldName) {
  return run('get', credentialId, fieldName);
}

async function getKey(credentialId, fieldName) {
  return run('get', credentialId, fieldName);
}

module.exports = { listCredentials, getField, getKey };
```

**Step 4: Run tests**

Run: `cd ~/Projects/KeyKeeper/sdk-node && node --test tests/`
Expected: Tests pass (or skip gracefully if CLI not installed yet)

**Step 5: Commit**

```bash
git add sdk-node/
git commit -m "feat: Node.js SDK wrapping keykeeper CLI"
```

---

### Task 7: Claude Code Skill

**Files:**
- Create: `skill/keykeeper.md`

**Step 1: Write the skill file**

`skill/keykeeper.md`:
```markdown
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
```

**Step 2: Commit**

```bash
git add skill/
git commit -m "feat: Claude Code skill for KeyKeeper integration"
```

---

### Task 8: macOS Menu Bar App - Project Setup

**Files:**
- Create: `KeyKeeperApp/KeyKeeperApp.xcodeproj` (via Xcode or swift package)
- Create: `KeyKeeperApp/KeyKeeperApp/KeyKeeperApp.swift`
- Create: `KeyKeeperApp/KeyKeeperApp/AppDelegate.swift`

**Step 1: Create Xcode project for the menu bar app**

This must be done via `xcodebuild` or by creating the project structure manually.
The app is a macOS App (SwiftUI lifecycle) with `LSUIElement = true` (no dock icon).

Create the app as a separate Xcode project that depends on `KeyKeeperCore` as a local package.

`KeyKeeperApp/KeyKeeperApp/KeyKeeperApp.swift`:
```swift
import SwiftUI

@main
struct KeyKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
```

`KeyKeeperApp/KeyKeeperApp/AppDelegate.swift`:
```swift
import AppKit
import SwiftUI
import KeyKeeperCore

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "KeyKeeper")
            button.action = #selector(togglePopover)
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MainView())
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

**Step 2: Verify it builds**

Run: `xcodebuild -project KeyKeeperApp/KeyKeeperApp.xcodeproj -scheme KeyKeeperApp build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add KeyKeeperApp/
git commit -m "feat: menu bar app skeleton with popover"
```

---

### Task 9: Menu Bar App - Credential List View

**Files:**
- Create: `KeyKeeperApp/KeyKeeperApp/Views/MainView.swift`
- Create: `KeyKeeperApp/KeyKeeperApp/Views/CredentialRow.swift`
- Create: `KeyKeeperApp/KeyKeeperApp/ViewModels/CredentialListViewModel.swift`

**Step 1: Implement ViewModel**

`KeyKeeperApp/KeyKeeperApp/ViewModels/CredentialListViewModel.swift`:
```swift
import Foundation
import KeyKeeperCore

@MainActor
class CredentialListViewModel: ObservableObject {
    @Published var credentials: [(id: String, credential: Credential)] = []
    @Published var searchText = ""

    private let store = MetaStore.default

    var filtered: [(id: String, credential: Credential)] {
        if searchText.isEmpty { return credentials }
        return credentials.filter {
            $0.id.localizedCaseInsensitiveContains(searchText) ||
            $0.credential.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() {
        guard let meta = try? store.load() else { return }
        credentials = meta.credentials
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, credential: $0.value) }
    }

    func delete(id: String) {
        guard var meta = try? store.load() else { return }
        let cred = meta.credentials[id]
        // Delete secret fields from Keychain
        let keychain = KeychainService()
        for (fieldName, field) in cred?.fields ?? [:] where field.secret {
            try? keychain.delete(credentialId: id, fieldName: fieldName)
        }
        meta.credentials.removeValue(forKey: id)
        try? store.save(meta)
        load()
    }
}
```

**Step 2: Implement views**

`KeyKeeperApp/KeyKeeperApp/Views/CredentialRow.swift`:
```swift
import SwiftUI
import KeyKeeperCore

struct CredentialRow: View {
    let id: String
    let credential: Credential

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(credential.label)
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(Array(credential.fields.sorted(by: { $0.key < $1.key })), id: \.key) { name, field in
                    if field.secret {
                        Label(name, systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(name): \(field.value ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
```

`KeyKeeperApp/KeyKeeperApp/Views/MainView.swift`:
```swift
import SwiftUI

struct MainView: View {
    @StateObject private var viewModel = CredentialListViewModel()
    @State private var showingAdd = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("KeyKeeper")
                    .font(.headline)
                Spacer()
                Button(action: { showingAdd = true }) {
                    Image(systemName: "plus")
                }
            }
            .padding()

            // Search
            TextField("Search...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            // List
            List {
                ForEach(viewModel.filtered, id: \.id) { item in
                    CredentialRow(id: item.id, credential: item.credential)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                viewModel.delete(id: item.id)
                            }
                        }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 360, height: 480)
        .onAppear { viewModel.load() }
        .sheet(isPresented: $showingAdd) {
            AddCredentialView(onSave: { viewModel.load() })
        }
    }
}
```

**Step 3: Build and verify**

Expected: App shows in menu bar, clicking opens popover with empty list

**Step 4: Commit**

```bash
git add KeyKeeperApp/
git commit -m "feat: credential list view with search and delete"
```

---

### Task 10: Menu Bar App - Add/Edit Credential View

**Files:**
- Create: `KeyKeeperApp/KeyKeeperApp/Views/AddCredentialView.swift`
- Create: `KeyKeeperApp/KeyKeeperApp/ViewModels/AddCredentialViewModel.swift`

**Step 1: Implement ViewModel**

`KeyKeeperApp/KeyKeeperApp/ViewModels/AddCredentialViewModel.swift`:
```swift
import Foundation
import KeyKeeperCore

struct FieldEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var isSecret: Bool = false
}

@MainActor
class AddCredentialViewModel: ObservableObject {
    @Published var label = ""
    @Published var credentialId = ""
    @Published var notes = ""
    @Published var links: [String] = [""]
    @Published var fields: [FieldEntry] = [FieldEntry()]
    @Published var security: SecurityLevel = .standard

    private let store = MetaStore.default
    private let keychain = KeychainService()

    var isValid: Bool {
        !label.isEmpty && !credentialId.isEmpty && fields.contains { !$0.name.isEmpty }
    }

    func autoGenerateId() {
        if credentialId.isEmpty {
            credentialId = label
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    func save() throws {
        var meta = try store.load()
        var credFields: [String: CredentialField] = [:]

        for field in fields where !field.name.isEmpty {
            if field.isSecret {
                try keychain.save(
                    credentialId: credentialId, fieldName: field.name,
                    value: field.value, security: security
                )
                credFields[field.name] = CredentialField(secret: true)
            } else {
                credFields[field.name] = CredentialField(value: field.value, secret: false)
            }
        }

        let now = ISO8601DateFormatter().string(from: Date()).prefix(10)
        meta.credentials[credentialId] = Credential(
            label: label, notes: notes,
            links: links.filter { !$0.isEmpty },
            fields: credFields, security: security,
            created: String(now), updated: String(now)
        )
        try store.save(meta)
    }
}
```

**Step 2: Implement Add View**

`KeyKeeperApp/KeyKeeperApp/Views/AddCredentialView.swift`:
```swift
import SwiftUI
import KeyKeeperCore

struct AddCredentialView: View {
    @StateObject private var vm = AddCredentialViewModel()
    @Environment(\.dismiss) private var dismiss
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Credential").font(.headline)

            TextField("Label", text: $vm.label)
                .onChange(of: vm.label) { _ in vm.autoGenerateId() }
            TextField("ID", text: $vm.credentialId)
                .font(.caption)
            TextField("Notes", text: $vm.notes, axis: .vertical)
                .lineLimit(3)

            // Links
            Section("Links") {
                ForEach(vm.links.indices, id: \.self) { i in
                    TextField("URL", text: $vm.links[i])
                }
                Button("+ Add Link") { vm.links.append("") }
                    .font(.caption)
            }

            // Fields
            Section("Fields") {
                ForEach(vm.fields.indices, id: \.self) { i in
                    HStack {
                        TextField("Name", text: $vm.fields[i].name)
                            .frame(width: 100)
                        if vm.fields[i].isSecret {
                            SecureField("Value", text: $vm.fields[i].value)
                        } else {
                            TextField("Value", text: $vm.fields[i].value)
                        }
                        Toggle(vm.fields[i].isSecret ? "Secret" : "Plain",
                               isOn: $vm.fields[i].isSecret)
                            .toggleStyle(.button)
                            .font(.caption)
                    }
                }
                Button("+ Add Field") { vm.fields.append(FieldEntry()) }
                    .font(.caption)
            }

            // Security
            Picker("Security", selection: $vm.security) {
                Text("Standard").tag(SecurityLevel.standard)
                Text("Strict (Touch ID)").tag(SecurityLevel.strict)
            }
            .pickerStyle(.segmented)

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    try? vm.save()
                    onSave()
                    dismiss()
                }
                .disabled(!vm.isValid)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 500)
    }
}
```

**Step 3: Build and test manually**

Expected: Clicking "+" opens add form, filling and saving creates credential visible in list and via CLI

**Step 4: Commit**

```bash
git add KeyKeeperApp/
git commit -m "feat: add credential view with dynamic fields"
```

---

### Task 11: First-Run Setup & CLI Install

**Files:**
- Create: `KeyKeeperApp/KeyKeeperApp/Views/SetupView.swift`

**Step 1: Implement setup flow**

The app checks on launch if CLI is installed at `/usr/local/bin/keykeeper`.
If not, shows a setup view offering to:
1. Install CLI (copies binary, requires admin password)
2. Install Claude Code Skill (copies `keykeeper.md` to `~/.claude/commands/`)

`KeyKeeperApp/KeyKeeperApp/Views/SetupView.swift`:
```swift
import SwiftUI

struct SetupView: View {
    @State private var cliInstalled = false
    @State private var skillInstalled = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to KeyKeeper").font(.title2)
            Text("Let's set up the CLI and Claude Code integration.")
                .foregroundColor(.secondary)

            // CLI Install
            HStack {
                Image(systemName: cliInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(cliInstalled ? .green : .secondary)
                Text("Install CLI tool")
                Spacer()
                if !cliInstalled {
                    Button("Install") { installCLI() }
                }
            }

            // Skill Install
            HStack {
                Image(systemName: skillInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(skillInstalled ? .green : .secondary)
                Text("Install Claude Code Skill")
                Spacer()
                if !skillInstalled {
                    Button("Install") { installSkill() }
                }
            }

            if cliInstalled && skillInstalled {
                Button("Get Started") {
                    UserDefaults.standard.set(true, forKey: "setupComplete")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { checkStatus() }
    }

    func checkStatus() {
        cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/keykeeper")
        let skillPath = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands/keykeeper.md")
        skillInstalled = FileManager.default.fileExists(atPath: skillPath.path)
    }

    func installCLI() {
        // Use privileged helper or AppleScript to copy binary
        let script = """
        do shell script "cp '\\(Bundle.main.bundlePath)/Contents/MacOS/keykeeper-cli' /usr/local/bin/keykeeper && chmod +x /usr/local/bin/keykeeper" with administrator privileges
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        checkStatus()
    }

    func installSkill() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/commands")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = Bundle.main.url(forResource: "keykeeper", withExtension: "md")!
        let dest = dir.appendingPathComponent("keykeeper.md")
        try? FileManager.default.copyItem(at: source, to: dest)
        checkStatus()
    }
}
```

**Step 2: Wire setup into app launch**

Add setup check in `MainView` — if `!UserDefaults.standard.bool(forKey: "setupComplete")`, show SetupView instead.

**Step 3: Commit**

```bash
git add KeyKeeperApp/
git commit -m "feat: first-run setup for CLI and Claude Code skill install"
```

---

### Task 12: Integration Test & Polish

**Step 1: End-to-end manual test**

1. Launch app → Setup view appears → Install CLI → Install Skill
2. Click "+" → Add "Anthropic" credential with `api_key` (secret) field
3. Open terminal → `keykeeper list --detail` → Shows "anthropic | Anthropic" with `api_key: ********`
4. Open new Claude Code session → mention API key → Claude Code runs `keykeeper list --detail`, writes code with `get_key()`
5. Run the code → macOS Keychain prompt → code works

**Step 2: Fix any issues found**

**Step 3: Final commit**

```bash
git add -A
git commit -m "chore: integration test fixes and polish"
```

---

### Task 13: GitHub Release

**Step 1: Create GitHub repo**

```bash
cd ~/Projects/KeyKeeper
gh repo create KeyKeeper --public --source=. --push
```

**Step 2: Write comprehensive README**

Cover: what it is, why it exists, install, usage with Claude Code, SDK examples, security model.

**Step 3: Push and tag**

```bash
git tag v0.1.0
git push origin main --tags
```
