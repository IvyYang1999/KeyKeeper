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

        TUI/full-screen programs need a real TTY. Use --tty for those commands; \
        in that mode KeyKeeper inherits stdin/stdout/stderr directly and cannot \
        redact child-process output.

        Environment variable names are derived from field names: uppercased with \
        non-alphanumeric characters replaced by underscores.

        Example:
          keykeeper run -c my-api -- python script.py
          keykeeper run -c my-api --tty -- vim
          keykeeper run -c stripe -c openai -- node server.js
        """
    )

    @Option(name: .shortAndLong, help: "Credential ID to inject (repeatable).")
    var credential: [String]

    @Option(name: .long, help: "Prefix for injected environment variable names (e.g. KEYKEEPER_).")
    var prefix: String = ""

    @Flag(name: .long, help: "Print injected variable names (not values) before running the command.")
    var verbose: Bool = false

    @Flag(name: .long, help: "Run with inherited TTY; disables stdout/stderr redaction for TUI programs.")
    var tty: Bool = false

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
        let grantStore = GrantStore.default
        let session = SessionResolver.resolve()

        // Collect all secret fields from requested credentials
        var injectedEnv: [String: String] = [:]
        var secretValues: [String] = []

        for credId in credential {
            guard let cred = meta.credentials[credId] else {
                throw ValidationError("Credential '\(credId)' not found.")
            }

            // For strict credentials, check/request grant before accessing Keychain
            if cred.security == .strict {
                try Self.ensureGrant(
                    credentialId: credId, credential: cred,
                    grantStore: grantStore, session: session
                )
            }

            let secretFieldNames = cred.fields
                .filter(\.value.secret)
                .map(\.key)
                .sorted()

            for fieldName in secretFieldNames {
                let envName = prefix + Self.envVarName(from: fieldName)

                if injectedEnv[envName] != nil {
                    throw ValidationError(
                        "Environment variable conflict: '\(envName)' would be set by multiple fields. " +
                        "Use --prefix to disambiguate."
                    )
                }

                // Read secret via IPC — App owns the Keychain entries, no ACL prompts
                let value = try IPCClient.requestValue(
                    credentialId: credId,
                    fieldName: fieldName,
                    sessionId: session.id,
                    requestedFieldNames: secretFieldNames
                )
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

        // Launch subprocess.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = env

        if tty {
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError

            let signalSources = Self.setupSignalForwarding(to: process)
            try process.run()
            process.waitUntilExit()
            for source in signalSources {
                source.cancel()
            }
            throw ExitCode(process.terminationStatus)
        }

        // Pipe output for redaction in the default safety mode.
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

    /// Ensure a valid grant exists for a strict credential.
    /// If no valid grant, request authorization via IPC to the app.
    static func ensureGrant(credentialId: String, credential: Credential,
                            grantStore: GrantStore, session: SessionInfo) throws {
        // Check for existing valid grant
        if try GrantAuthorizationPolicy.validGrantForValueAccess(
            credentialId: credentialId,
            sessionId: session.id,
            grantStore: grantStore
        ) != nil {
            return
        }

        // No valid grant — request authorization from the app
        let fieldNames = credential.fields.filter(\.value.secret).map(\.key).sorted()
        let request = AuthRequest(
            credentialId: credentialId,
            credentialLabel: credential.label,
            fieldNames: fieldNames,
            sessionId: session.id,
            sessionLabel: session.label,
            pid: ProcessInfo.processInfo.processIdentifier
        )

        FileHandle.standardError.write(
            Data("Requesting authorization for '\(credential.label)' from KeyKeeper app...\n".utf8)
        )

        let response = try IPCClient.requestAuthorization(request)

        guard response.granted else {
            throw IPCError.denied(response.error)
        }
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

/// Stateful byte matcher used by each output stream.
///
/// `process(_:)` deliberately retains the longest possible pattern prefix;
/// `finish()` resolves that retained suffix at EOF.
struct OutputRedactionMatcher {
    private static let standardReplacement = Array("[REDACTED]".utf8)

    private let patterns: [[UInt8]]
    private let maxPatternLength: Int
    private let replacement: [UInt8]
    private var carryover: [UInt8] = []

    init(secrets: [String]) {
        let encodedValues = secrets
            .map { Array($0.utf8) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        self.patterns = encodedValues
        self.maxPatternLength = encodedValues.first?.count ?? 0
        self.replacement = Self.safeReplacement(for: encodedValues)
    }

    var pendingByteCount: Int { carryover.count }

    mutating func process(_ data: Data) -> Data {
        guard !patterns.isEmpty else { return data }

        carryover.append(contentsOf: data)
        return Data(redactAvailableBytes(flushAll: false))
    }

    mutating func finish() -> Data {
        guard !patterns.isEmpty else { return Data() }
        return Data(redactAvailableBytes(flushAll: true))
    }

    private mutating func redactAvailableBytes(flushAll: Bool) -> [UInt8] {
        // Until EOF, retain enough raw bytes for the longest pattern to begin in
        // this read and finish in the next one.
        let overlapSize = maxPatternLength - 1
        let processingLimit = flushAll
            ? carryover.count
            : max(0, carryover.count - overlapSize)
        var output: [UInt8] = []
        var index = 0

        while index < processingLimit {
            let unread = carryover[index...]
            if let match = patterns.first(where: { unread.starts(with: $0) }) {
                output.append(contentsOf: replacement)
                index += match.count
            } else {
                output.append(carryover[index])
                index += 1
            }
        }

        carryover = Array(carryover[index...])
        return output
    }

    private static func safeReplacement(for patterns: [[UInt8]]) -> [UInt8] {
        if isBoundarySafe(standardReplacement, for: patterns) {
            return standardReplacement
        }

        if !patterns.contains(where: { contains($0, in: standardReplacement) }) {
            // A private-use scalar keeps the visible marker while separating it
            // from preserved bytes. Try the full range so a delimiter already used
            // by one credential does not weaken another credential's boundary.
            for value in 0xE000...0xF8FF {
                guard let scalar = UnicodeScalar(value) else { continue }
                let delimiter = Array(String(scalar).utf8)
                let candidate = delimiter + standardReplacement + delimiter
                if isBoundarySafe(candidate, for: patterns) {
                    return candidate
                }
            }
        }

        let alternative = Array("[FILTERED]".utf8)
        if isBoundarySafe(alternative, for: patterns) {
            return alternative
        }

        // Credential values are valid UTF-8, so 0xFF cannot occur in a pattern.
        // This fallback favors non-disclosure over textual rendering in the
        // pathological case where every private-use delimiter is unsafe.
        let binaryDelimiter: UInt8 = 0xFF
        let wrapped = [binaryDelimiter] + standardReplacement + [binaryDelimiter]
        if isBoundarySafe(wrapped, for: patterns) {
            return wrapped
        }
        return [binaryDelimiter]
    }

    private static func isBoundarySafe(
        _ candidate: [UInt8],
        for patterns: [[UInt8]]
    ) -> Bool {
        guard !candidate.isEmpty else { return false }

        for pattern in patterns {
            if contains(pattern, in: candidate) {
                return false
            }

            guard pattern.count > 1 else { continue }
            for splitIndex in 1..<pattern.count {
                if candidate.starts(with: pattern[splitIndex...])
                    || candidate.suffix(splitIndex).elementsEqual(pattern[..<splitIndex]) {
                    return false
                }
            }
        }
        return true
    }

    private static func contains(_ pattern: [UInt8], in bytes: [UInt8]) -> Bool {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return false }
        for index in 0...(bytes.count - pattern.count) {
            if bytes[index...].starts(with: pattern) {
                return true
            }
        }
        return false
    }
}

/// Reads subprocess output, replaces secret values with [REDACTED], and writes to real output.
/// Uses a sliding-window buffer to handle secrets that span chunk boundaries.
final class OutputRedactor: @unchecked Sendable {
    enum Target { case stdout, stderr }

    private let secrets: [String]
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let group = DispatchGroup()

    init(secrets: [String], stdout: FileHandle, stderr: FileHandle) {
        self.secrets = secrets
        self.stdoutHandle = stdout
        self.stderrHandle = stderr
    }

    func startReading(pipe: Pipe, target: Target) {
        let handle = target == .stdout ? stdoutHandle : stderrHandle
        let readHandle = pipe.fileHandleForReading

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }

            var matcher = OutputRedactionMatcher(secrets: secrets)

            while true {
                let data = readHandle.availableData
                if data.isEmpty { break }  // EOF

                let output = matcher.process(data)
                if !output.isEmpty {
                    handle.write(output)
                }
            }

            // EOF: run the remaining bytes through the same matcher before writing.
            let output = matcher.finish()
            if !output.isEmpty {
                handle.write(output)
            }
        }
    }

    func waitUntilDone() {
        group.wait()
    }
}
