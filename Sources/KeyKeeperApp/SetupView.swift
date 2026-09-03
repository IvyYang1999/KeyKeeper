import SwiftUI

struct SetupView: View {
    @Binding var setupComplete: Bool
    @State private var cliInstalled = false
    @State private var showManual = false
    @State private var isInstallingCLI = false
    @State private var errorMessage: String?

    // We only check CLI installation. Skill installation is delegated to Claude Code.
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

                if showManual {
                    manualSection
                } else {
                    mainSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 360, height: 480)
        .onAppear { checkCLI() }
    }

    // MARK: - Main Section

    @ViewBuilder
    private var mainSection: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Step 1: CLI
            StepCard(
                step: 1,
                done: cliInstalled,
                title: "Install CLI Tool",
                detail: "Installs the `keykeeper` binary to /usr/local/bin so your code can securely read keys from the encrypted vault at runtime.",
                actionLabel: cliInstalled ? nil : "Install CLI",
                isLoading: isInstallingCLI,
                action: installCLI
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Step 2: Skill — always delegate to Claude Code
            StepCard(
                step: 2,
                done: false,
                title: "Set Up Claude Code",
                detail: "Copy the message below and paste it into Claude Code. It will install the KeyKeeper skill in the correct location automatically.",
                actionLabel: nil,
                action: {}
            )

            CopyableCommand("Install the KeyKeeper skill for me. Download it from https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/skill/keykeeper.md and save it as a global skill.")

            // Skip / Get Started
            if cliInstalled {
                Button("Get Started") {
                    setupComplete = true
                    UserDefaults.standard.set(true, forKey: "setupComplete")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .help("You can set up the Claude Code skill later.")
            }
        }

        Button("I prefer to install everything manually") {
            withAnimation { showManual = true }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundColor(.accentColor)
    }

    // MARK: - Manual Section

    @ViewBuilder
    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manual Installation")
                .font(.headline)

            Text("Step 1: Install CLI").font(.subheadline.bold())
            CopyableCommand("sudo cp /Applications/KeyKeeper.app/Contents/MacOS/keykeeper /usr/local/bin/keykeeper && sudo chmod +x /usr/local/bin/keykeeper")

            Divider()

            Text("Step 2: Install Claude Code Skill").font(.subheadline.bold())
            Text("Paste this into Claude Code and let it handle the rest:")
                .font(.caption).foregroundColor(.secondary)
            CopyableCommand("Install the KeyKeeper skill for me. Download it from https://raw.githubusercontent.com/IvyYang1999/KeyKeeper/main/skill/keykeeper.md and save it as a global skill.")

            Divider()

            HStack {
                Button("Back") {
                    withAnimation { showManual = false }
                }
                .buttonStyle(.plain)
                .font(.caption)

                Spacer()

                Button("Check again") {
                    checkCLI()
                }
                .font(.caption)
            }
        }
    }

    // MARK: - Actions

    func checkCLI() {
        cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/keykeeper")
    }

    func installCLI() {
        isInstallingCLI = true
        errorMessage = nil

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
        checkCLI()
        isInstallingCLI = false
    }
}

// MARK: - Subviews

struct StepCard: View {
    let step: Int
    let done: Bool
    let title: String
    let detail: String
    var actionLabel: String?
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ZStack {
                    Circle()
                        .fill(done ? Color.green : Color.accentColor)
                        .frame(width: 24, height: 24)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    } else {
                        Text("\(step)")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                    }
                }
                Text(title).font(.callout.bold())
                Spacer()
                if let actionLabel {
                    Button(action: action) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(actionLabel)
                        }
                    }
                    .disabled(isLoading)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.lg)
        .background(DS.Fill.card, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
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
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
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
        .background(DS.Fill.codeBlock, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
    }
}
