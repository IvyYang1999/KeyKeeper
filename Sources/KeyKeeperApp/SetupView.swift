import SwiftUI

struct SetupView: View {
    @Binding var setupComplete: Bool
    @State private var cliInstalled = false
    @State private var skillInstalled = false
    @State private var isSettingUp = false
    @State private var errorMessage: String?
    @State private var showManual = false

    var allDone: Bool { cliInstalled && skillInstalled }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                Image(systemName: "key.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)
                    .padding(.top, 16)

                Text("Welcome to KeyKeeper")
                    .font(.title2.bold())

                Text("Securely manage your API keys.\nAI tools use them without seeing the values.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .font(.callout)

                Divider().padding(.horizontal)

                if allDone {
                    doneSection
                } else if showManual {
                    manualSection
                } else {
                    overviewSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 360, height: 480)
        .onAppear { checkStatus() }
    }

    // MARK: - All Done

    @ViewBuilder
    private var doneSection: some View {
        VStack(spacing: 12) {
            Label("CLI installed at /usr/local/bin/keykeeper", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.callout)
            Label("Skill installed at ~/.claude/commands/keykeeper.md", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.callout)
        }
        .padding()

        Button("Get Started") {
            setupComplete = true
            UserDefaults.standard.set(true, forKey: "setupComplete")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Overview (default)

    @ViewBuilder
    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What needs to be installed")
                .font(.headline)

            SetupItemCard(
                installed: cliInstalled,
                title: "1. CLI Tool",
                what: "The `keykeeper` command-line binary",
                where_: "/usr/local/bin/keykeeper",
                why: "So your Python/Node code can read keys from Keychain at runtime"
            )

            SetupItemCard(
                installed: skillInstalled,
                title: "2. Claude Code Skill",
                what: "A markdown file that teaches Claude Code how to use KeyKeeper",
                where_: "~/.claude/commands/keykeeper.md",
                why: "So Claude Code writes get_key(\"name\") instead of asking you for keys"
            )
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundColor(.red)
                .padding(.horizontal)
        }

        // Primary: Auto setup
        Button(action: { runSetup() }) {
            if isSettingUp {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 8)
            } else {
                Text("Auto Setup")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isSettingUp)
        .help("Copies CLI to /usr/local/bin (needs admin password) and skill to ~/.claude/commands/")

        // Secondary: Show manual commands
        Button("I prefer to install manually") {
            withAnimation { showManual = true }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundColor(.accentColor)
    }

    // MARK: - Manual install

    @ViewBuilder
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manual Installation")
                .font(.headline)

            Text("Option A: Run these commands yourself")
                .font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 4) {
                Text("Install CLI:").font(.caption.bold())
                CopyableCommand("sudo cp \"\(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keykeeper").path)\" /usr/local/bin/keykeeper && sudo chmod +x /usr/local/bin/keykeeper")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Install Claude Code Skill:").font(.caption.bold())
                CopyableCommand("mkdir -p ~/.claude/commands && curl -o ~/.claude/commands/keykeeper.md https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/skill/keykeeper.md")
            }

            Divider()

            Text("Option B: Ask Claude Code to do it")
                .font(.subheadline.bold())

            Text("Paste this into Claude Code:")
                .font(.caption).foregroundColor(.secondary)

            CopyableCommand("Help me install KeyKeeper CLI and skill. Run: sudo cp /Applications/KeyKeeper.app/Contents/MacOS/keykeeper /usr/local/bin/keykeeper && mkdir -p ~/.claude/commands && curl -o ~/.claude/commands/keykeeper.md https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/skill/keykeeper.md")

            Divider()

            HStack {
                Button("Back") {
                    withAnimation { showManual = false }
                }
                .buttonStyle(.plain)
                .font(.caption)

                Spacer()

                Button("I've installed, check again") {
                    checkStatus()
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Actions

    func runSetup() {
        isSettingUp = true
        errorMessage = nil

        if !cliInstalled { installCLI() }
        if !skillInstalled { installSkill() }

        isSettingUp = false
    }

    func checkStatus() {
        cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/keykeeper")
        let skillPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands/keykeeper.md")
        skillInstalled = FileManager.default.fileExists(atPath: skillPath.path)
    }

    func installCLI() {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/keykeeper").path
        let escapedPath = bundleCLI.replacingOccurrences(of: "'", with: "'\\''")
        let script = "cp '\(escapedPath)' /usr/local/bin/keykeeper && chmod +x /usr/local/bin/keykeeper"
        let fullScript = "do shell script \"\(script)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: fullScript)?.executeAndReturnError(&error)
        if error != nil {
            errorMessage = "CLI install cancelled or failed."
        }
        checkStatus()
    }

    func installSkill() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude/commands")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent("keykeeper.md")

        if let bundleSkillURL = Bundle.main.url(forResource: "keykeeper", withExtension: "md"),
           let content = try? String(contentsOf: bundleSkillURL, encoding: .utf8) {
            try? content.write(to: dest, atomically: true, encoding: .utf8)
        } else {
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

// MARK: - Subviews

struct SetupItemCard: View {
    let installed: Bool
    let title: String
    let what: String
    let where_: String
    let why: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(installed ? .green : .secondary)
                Text(title).font(.callout.bold())
            }
            Group {
                Text("What: ").bold() + Text(what)
                Text("Where: ").bold() + Text(where_).font(.system(.caption, design: .monospaced))
                Text("Why: ").bold() + Text(why)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(4)
            Spacer()
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(copied ? .green : .accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}
