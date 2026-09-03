import ArgumentParser
import Darwin
import Foundation
import KeyKeeperCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with secrets injected as environment variables",
        discussion: """
        Reads secret fields from the unlocked age vault and injects them as environment \
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

            // For strict credentials, check/request grant before accessing the value
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

                // Read secret via IPC — App owns the unlocked age session
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

        // Signals are installed before spawning so none can be lost in the launch window.
        let signalForwarder = BusinessProcessSignalForwarder()
        defer { signalForwarder.cancel() }

        if tty {
            let child = try BusinessProcessLauncher.launch(
                command: command,
                environment: env,
                standardOutput: nil,
                standardError: nil,
                startSuspended: true
            )
            try child.waitUntilSuspended()
            signalForwarder.attach(to: child)
            defer { child.terminateForParentExit() }

            let terminalControl = try TerminalForegroundControl(
                processGroupIdentifier: child.processGroupIdentifier
            )
            defer { terminalControl?.restore() }
            child.resume()

            throw ExitCode(try child.wait())
        }

        // Pipe output for redaction in the default safety mode.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        for handle in [
            stdoutPipe.fileHandleForReading,
            stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading,
            stderrPipe.fileHandleForWriting,
        ] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }

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

        let child: BusinessProcessHandle
        do {
            child = try BusinessProcessLauncher.launch(
                command: command,
                environment: env,
                standardOutput: stdoutPipe.fileHandleForWriting,
                standardError: stderrPipe.fileHandleForWriting
            )
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            redactor.waitUntilDone()
            throw error
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        signalForwarder.attach(to: child)
        defer { child.terminateForParentExit() }

        let terminationStatus = try child.wait()

        // Wait for all output to be flushed
        redactor.waitUntilDone()

        // Exit with the same code as the child
        throw ExitCode(terminationStatus)
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
        EnvironmentVariableName.from(fieldName: fieldName)
    }

}

// MARK: - Business Process Lifecycle

/// A launched user command and the write end of its parent-liveness pipe.
/// There is intentionally no timeout here: user commands may legitimately run for hours.
final class BusinessProcessHandle: @unchecked Sendable {
    let processIdentifier: pid_t
    let processGroupIdentifier: pid_t

    private let lock = NSLock()
    private var parentLivenessHandle: FileHandle?
    private var terminationStatus: Int32?

    init(processIdentifier: pid_t, parentLivenessHandle: FileHandle) {
        self.processIdentifier = processIdentifier
        processGroupIdentifier = processIdentifier
        self.parentLivenessHandle = parentLivenessHandle
    }

    func forward(signal signalNumber: Int32) {
        _ = kill(-processGroupIdentifier, signalNumber)
    }

    func resume() {
        _ = kill(-processGroupIdentifier, SIGCONT)
    }

    func waitUntilSuspended() throws {
        var rawStatus: Int32 = 0
        while waitpid(processIdentifier, &rawStatus, WUNTRACED) == -1 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }
        guard rawStatus & 0xFF == 0x7F else {
            let status = Self.decodeWaitStatus(rawStatus)
            lock.lock()
            terminationStatus = status
            lock.unlock()
            closeParentLivenessChannel()
            throw POSIXError(.ECHILD)
        }
    }

    /// Closing this descriptor models every parent exit, including SIGKILL and crashes.
    /// The guard process inherited the read end and kills the business process group on EOF.
    func closeParentLivenessChannel() {
        lock.lock()
        let handle = parentLivenessHandle
        parentLivenessHandle = nil
        lock.unlock()
        try? handle?.close()
    }

    func wait() throws -> Int32 {
        lock.lock()
        if let terminationStatus {
            lock.unlock()
            return terminationStatus
        }
        lock.unlock()

        var rawStatus: Int32 = 0
        while waitpid(processIdentifier, &rawStatus, 0) == -1 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }

        let status = Self.decodeWaitStatus(rawStatus)
        lock.lock()
        terminationStatus = status
        lock.unlock()
        closeParentLivenessChannel()
        return status
    }

    /// Used only while the parent is unwinding before the command has been reaped.
    /// A hard group kill is deliberate here: this is parent-death cleanup, not a runtime timeout.
    func terminateForParentExit() {
        lock.lock()
        let isRunning = terminationStatus == nil
        lock.unlock()
        guard isRunning else { return }

        closeParentLivenessChannel()
        _ = kill(-processGroupIdentifier, SIGKILL)
    }

    deinit {
        terminateForParentExit()
    }

    private static func decodeWaitStatus(_ status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7F
        if terminatingSignal == 0 {
            return (status >> 8) & 0xFF
        }
        return terminatingSignal
    }
}

enum BusinessProcessLauncher {
    private static let shellPath = "/bin/sh"
    private static let parentLivenessDescriptor: Int32 = 3

    static func launch(
        command: [String],
        environment: [String: String],
        standardOutput: FileHandle?,
        standardError: FileHandle?,
        startSuspended: Bool = false
    ) throws -> BusinessProcessHandle {
        let parentLivenessPipe = Pipe()
        let readDescriptor = parentLivenessPipe.fileHandleForReading.fileDescriptor
        let writeDescriptor = parentLivenessPipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            readDescriptor,
            parentLivenessDescriptor
        ))
        if readDescriptor != parentLivenessDescriptor {
            try check(posix_spawn_file_actions_addclose(&fileActions, readDescriptor))
        }
        try check(posix_spawn_file_actions_addclose(&fileActions, writeDescriptor))
        if let standardOutput {
            try check(posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutput.fileDescriptor,
                STDOUT_FILENO
            ))
        }
        if let standardError {
            try check(posix_spawn_file_actions_adddup2(
                &fileActions,
                standardError.fileDescriptor,
                STDERR_FILENO
            ))
        }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            sigaddset(&defaultSignals, signalNumber)
        }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
        try check(posix_spawnattr_setflags(&attributes, flags))

        let arguments = [
            shellPath,
            "-c",
            parentGuardScript(startSuspended: startSuspended),
            "keykeeper-parent-guard",
            "/usr/bin/env",
        ] + command
        let environmentEntries = environment.keys.sorted().map { key in
            "\(key)=\(environment[key]!)"
        }

        var processIdentifier: pid_t = 0
        let spawnResult = try withCStringArray(arguments) { argumentPointers in
            try withCStringArray(environmentEntries) { environmentPointers in
                posix_spawn(
                    &processIdentifier,
                    shellPath,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        try? parentLivenessPipe.fileHandleForReading.close()

        guard spawnResult == 0 else {
            try? parentLivenessPipe.fileHandleForWriting.close()
            try check(spawnResult)
            throw POSIXError(.EIO)
        }

        return BusinessProcessHandle(
            processIdentifier: processIdentifier,
            parentLivenessHandle: parentLivenessPipe.fileHandleForWriting
        )
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    private static func parentGuardScript(startSuspended: Bool) -> String {
        let suspendBeforeExec = startSuspended ? "kill -STOP \"$$\"" : ":"
        return """
        (
          trap '' HUP INT TERM
          IFS= read -r _ <&3
          /bin/kill -KILL -- -$$ 2>/dev/null
        ) &
        \(suspendBeforeExec)
        exec 3<&-
        exec "$@"
        """
    }

    private static func withCStringArray<T>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        let allocated = try strings.map { string -> UnsafeMutablePointer<CChar> in
            guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
            return pointer
        }
        defer { allocated.forEach { free($0) } }

        var pointers = allocated.map(Optional.some)
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private final class BusinessProcessSignalForwarder: @unchecked Sendable {
    private static let forwardedSignals = [SIGINT, SIGTERM, SIGHUP]

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.keykeeper.business-process-signals")
    private var child: BusinessProcessHandle?
    private var pendingSignals: [Int32] = []
    private var sources: [DispatchSourceSignal] = []

    init() {
        for signalNumber in Self.forwardedSignals {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { [weak self] in
                self?.receive(signal: signalNumber)
            }
            source.resume()
            sources.append(source)
        }
    }

    func attach(to child: BusinessProcessHandle) {
        lock.lock()
        self.child = child
        let pendingSignals = self.pendingSignals
        self.pendingSignals.removeAll()
        lock.unlock()

        for signalNumber in pendingSignals {
            child.forward(signal: signalNumber)
        }
    }

    func cancel() {
        lock.lock()
        child = nil
        pendingSignals.removeAll()
        let sources = self.sources
        self.sources.removeAll()
        lock.unlock()

        sources.forEach { $0.cancel() }
        for signalNumber in Self.forwardedSignals {
            Darwin.signal(signalNumber, SIG_DFL)
        }
    }

    private func receive(signal signalNumber: Int32) {
        lock.lock()
        guard let child else {
            pendingSignals.append(signalNumber)
            lock.unlock()
            return
        }
        lock.unlock()
        child.forward(signal: signalNumber)
    }
}

private final class TerminalForegroundControl {
    private let originalProcessGroup: pid_t
    private var needsRestore: Bool

    init?(processGroupIdentifier: pid_t) throws {
        guard isatty(STDIN_FILENO) == 1 else { return nil }
        let originalProcessGroup = tcgetpgrp(STDIN_FILENO)
        guard originalProcessGroup >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.originalProcessGroup = originalProcessGroup
        needsRestore = true
        try Self.setForegroundProcessGroup(processGroupIdentifier)
    }

    func restore() {
        guard needsRestore else { return }
        needsRestore = false
        try? Self.setForegroundProcessGroup(originalProcessGroup)
    }

    deinit {
        restore()
    }

    private static func setForegroundProcessGroup(_ processGroupIdentifier: pid_t) throws {
        let previousHandler = Darwin.signal(SIGTTOU, SIG_IGN)
        defer { Darwin.signal(SIGTTOU, previousHandler) }
        guard tcsetpgrp(STDIN_FILENO, processGroupIdentifier) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
