import ArgumentParser
import Foundation
import KeyKeeperCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with secrets injected as environment variables",
        discussion: """
        Reads secret fields from macOS Keychain and injects them as environment \
        variables into the subprocess. Secrets exist only in the subprocess memory \
        and are never written to disk or stdout.

        Any secret value that appears in the subprocess stdout or stderr is \
        automatically replaced with [REDACTED]. This is an architectural safety \
        net — secrets cannot leak through output even if the code prints them.

        Environment variable names are derived from field names: uppercased with \
        non-alphanumeric characters replaced by underscores.

        Example:
          keykeeper run -c my-api -- python script.py
          keykeeper run -c stripe -c openai -- node server.js
        """
    )

    @Option(name: .shortAndLong, help: "Credential ID to inject (repeatable).")
    var credential: [String]

    @Option(name: .long, help: "Prefix for injected environment variable names (e.g. KEYKEEPER_).")
    var prefix: String = ""

    @Flag(name: .long, help: "Print injected variable names (not values) before running the command.")
    var verbose: Bool = false

    @Argument(parsing: .postTerminator, help: "The command and arguments to run.")
    var command: [String]

    func validate() throws {
        guard !command.isEmpty else {
            throw ValidationError("No command specified. Use '--' before the command, e.g.: keykeeper run -c my-api -- python script.py")
        }
        guard !credential.isEmpty else {
            throw ValidationError("At least one credential ID is required (-c <id>).")
        }
    }

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()
        let keychain = KeychainService()

        // Collect all secret fields from requested credentials
        var injectedEnv: [String: String] = [:]
        var secretValues: [String] = []

        for credId in credential {
            guard let cred = meta.credentials[credId] else {
                throw ValidationError("Credential '\(credId)' not found.")
            }

            for (fieldName, field) in cred.fields where field.secret {
                let envName = prefix + Self.envVarName(from: fieldName)

                if injectedEnv[envName] != nil {
                    throw ValidationError(
                        "Environment variable conflict: '\(envName)' would be set by multiple fields. " +
                        "Use --prefix to disambiguate."
                    )
                }

                let value = try keychain.retrieve(credentialId: credId, fieldName: fieldName)
                injectedEnv[envName] = value
                secretValues.append(value)
            }
        }

        if injectedEnv.isEmpty {
            FileHandle.standardError.write(
                Data("Warning: no secret fields found in the specified credential(s). Running command without injection.\n".utf8)
            )
        }

        if verbose {
            let names = injectedEnv.keys.sorted().joined(separator: ", ")
            FileHandle.standardError.write(
                Data("Injecting: \(names)\n".utf8)
            )
        }

        // Build subprocess environment: inherit current env + inject secrets
        var env = ProcessInfo.processInfo.environment
        for (key, value) in injectedEnv {
            env[key] = value
        }

        // Launch subprocess with piped output for redaction
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Sort secrets longest-first so longer matches take priority
        let sortedSecrets = secretValues
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        let redactor = OutputRedactor(
            secrets: sortedSecrets,
            stdout: FileHandle.standardOutput,
            stderr: FileHandle.standardError
        )

        // Read stdout and stderr on background queues
        redactor.startReading(pipe: stdoutPipe, target: .stdout)
        redactor.startReading(pipe: stderrPipe, target: .stderr)

        // Forward signals to child process
        let signalSources = Self.setupSignalForwarding(to: process)

        try process.run()
        process.waitUntilExit()

        // Wait for all output to be flushed
        redactor.waitUntilDone()

        // Clean up signal handlers
        for source in signalSources {
            source.cancel()
        }

        // Exit with the same code as the child
        throw ExitCode(process.terminationStatus)
    }

    /// Convert a field name to a valid environment variable name.
    /// "api-key" → "API_KEY", "base url" → "BASE_URL", "apiKey" → "APIKEY"
    static func envVarName(from fieldName: String) -> String {
        fieldName
            .uppercased()
            .map { $0.isLetter || $0.isNumber ? $0 : Character("_") }
            .map(String.init)
            .joined()
            .replacing(#/_{2,}/#, with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Set up signal forwarding so SIGINT/SIGTERM are passed to the child process.
    private static func setupSignalForwarding(to process: Process) -> [DispatchSourceSignal] {
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if process.isRunning {
                    kill(process.processIdentifier, sig)
                }
            }
            source.resume()
            sources.append(source)
        }
        return sources
    }
}

// MARK: - Output Redaction

/// Reads subprocess output, replaces secret values with [REDACTED], and writes to real output.
/// Uses a sliding-window buffer to handle secrets that span chunk boundaries.
final class OutputRedactor: @unchecked Sendable {
    enum Target { case stdout, stderr }

    private let secrets: [String]
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let maxSecretLen: Int
    private let group = DispatchGroup()

    init(secrets: [String], stdout: FileHandle, stderr: FileHandle) {
        self.secrets = secrets
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
        self.maxSecretLen = secrets.map(\.count).max() ?? 0
    }

    func startReading(pipe: Pipe, target: Target) {
        let handle = target == .stdout ? stdoutHandle : stderrHandle
        let readHandle = pipe.fileHandleForReading

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }

            guard !secrets.isEmpty else {
                // No secrets to redact — pass through directly
                Self.passThrough(from: readHandle, to: handle)
                return
            }

            // Sliding window: we hold back up to (maxSecretLen - 1) bytes
            // to handle secrets that span chunk boundaries.
            let overlapSize = maxSecretLen - 1
            var carryover = ""

            while true {
                let data = readHandle.availableData
                if data.isEmpty { break }  // EOF

                guard let chunk = String(data: data, encoding: .utf8) else {
                    // Binary data — write as-is (can't redact binary)
                    handle.write(data)
                    continue
                }

                let combined = carryover + chunk

                if combined.count <= overlapSize {
                    // Not enough data yet, buffer it
                    carryover = combined
                    continue
                }

                // Redact the combined buffer, but hold back the tail
                let safeEnd = combined.index(combined.endIndex, offsetBy: -overlapSize)
                let toProcess = String(combined[combined.startIndex..<safeEnd])
                carryover = String(combined[safeEnd..<combined.endIndex])

                let redacted = self.redact(toProcess)
                handle.write(Data(redacted.utf8))
            }

            // Flush remaining buffer
            if !carryover.isEmpty {
                let redacted = self.redact(carryover)
                handle.write(Data(redacted.utf8))
            }
        }
    }

    func waitUntilDone() {
        group.wait()
    }

    private func redact(_ text: String) -> String {
        var result = text
        for secret in secrets {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        return result
    }

    private static func passThrough(from source: FileHandle, to dest: FileHandle) {
        while true {
            let data = source.availableData
            if data.isEmpty { break }
            dest.write(data)
        }
    }
}
