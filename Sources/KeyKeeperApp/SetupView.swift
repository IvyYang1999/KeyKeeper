import SwiftUI

struct SetupView: View {
    @Binding var setupComplete: Bool
    @State private var cliInstalled = false
    @State private var skillInstalled = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to KeyKeeper").font(.title2)
            Text("Set up CLI and Claude Code integration.")
                .foregroundColor(.secondary)

            HStack {
                Image(systemName: cliInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(cliInstalled ? .green : .secondary)
                Text("Install CLI tool")
                Spacer()
                if !cliInstalled {
                    Button("Install") { installCLI() }
                }
            }

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
                    setupComplete = true
                    UserDefaults.standard.set(true, forKey: "setupComplete")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 360, height: 300)
        .onAppear { checkStatus() }
    }

    func checkStatus() {
        cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/keykeeper")
        let skillPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands/keykeeper.md")
        skillInstalled = FileManager.default.fileExists(atPath: skillPath.path)
    }

    func installCLI() {
        // Find the CLI binary inside the .app bundle
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/keykeeper").path
        let escapedPath = bundleCLI.replacingOccurrences(of: "'", with: "'\\''")
        let script = "cp '\(escapedPath)' /usr/local/bin/keykeeper && chmod +x /usr/local/bin/keykeeper"
        let fullScript = "do shell script \"\(script)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: fullScript)?.executeAndReturnError(&error)
        checkStatus()
    }

    func installSkill() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/commands")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent("keykeeper.md")

        // Try to read skill file from app bundle Resources first
        if let bundleSkillURL = Bundle.main.url(forResource: "keykeeper", withExtension: "md"),
           let content = try? String(contentsOf: bundleSkillURL, encoding: .utf8) {
            try? content.write(to: dest, atomically: true, encoding: .utf8)
        } else {
            // Fallback: embedded skill content for development builds
            let skillContent = """
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
            3. ALWAYS use `get_key()` / `getKey()` for secret fields
            4. Use `keykeeper list --detail` to find the correct credential ID and field names
            5. If a needed credential doesn't exist, tell the user to add it via the KeyKeeper app
            """
            try? skillContent.write(to: dest, atomically: true, encoding: .utf8)
        }
        checkStatus()
    }
}
