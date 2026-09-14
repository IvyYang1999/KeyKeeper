import ArgumentParser
import Darwin
import Foundation
import KeyKeeperCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command with secrets injected as environment variables",
        discussion: """
        Asks the KeyKeeper app for the credential's secret fields (starting the app \
        automatically if needed). Text fields become environment variables. File \
        fields require --file credential-id:field=ENV_NAME: that variable receives \
        an owner-only temporary JSON path, removed after the command exits. \
        File mode writes plaintext to a private temporary directory; it is not secure erasure.

        Any secret value that appears in the subprocess stdout or stderr is \
        automatically replaced with [REDACTED]. This is an architectural safety \
        net, not a defense against encoded or transformed secrets.

        TUI/full-screen programs need a real TTY. Use --tty for those commands; \
        in that mode KeyKeeper inherits stdin/stdout/stderr directly and cannot \
        redact child-process output.

        Environment variable names are derived from field names: uppercased with \
        non-alphanumeric characters replaced by underscores.

        Example:
          keykeeper run -c my-api -- python script.py
          keykeeper run -c my-api --tty -- vim
          keykeeper run -c stripe -c openai -- node server.js

        If the caller is not approved yet, the error says exactly what to do next \
        (approve in the KeyKeeper window, or switch the credential to "Background OK" \
        in the app).
        """
    )

    @Option(name: .shortAndLong, help: "Credential ID to inject (repeatable).")
    var credential: [String]

    @Option(name: .long, help: "Prefix for injected environment variable names (e.g. KEYKEEPER_).")
    var prefix: String = ""

    @Option(name: .long, help: "File mapping credential-id:field=ENV_NAME (repeatable; requires -c for that credential). JSON contents never become an env value.")
    var file: [String] = []

    @Option(name: .long, help: "One line for the human: why you need this key and what you will do with it. Shown in the approval window, marked as unverified; it never changes what an approval grants.")
    var reason: String?

    @Option(name: .long, help: "How long you ask to be approved for: once, run (while this process or terminal session lives) or always. A wish the person sees next to KeyKeeper's own suggestion; they decide. session and 1h are accepted as older spellings of run.")
    var duration: RequestedDuration?

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
        guard file.isEmpty || !tty else { throw ValidationError("Credential files require output redaction; --file cannot be combined with --tty.") }
    }

    /// Plain values that live in meta.json (an account id, a region, an email): they are not
    /// secrets, so they are injected straight from metadata — no keychain, no approval, no
    /// audit entry. Earlier field names keep their variables, same as secret fields.
    static func nonSecretEnvironment(for credential: Credential, prefix: String) -> [String: String] {
        var result: [String: String] = [:]
        for (field, entry) in credential.fields.sorted(by: { $0.key < $1.key }) where !entry.secret && entry.setByCaller == nil {
            guard let value = entry.value, !value.isEmpty else { continue }
            for name in credential.environmentNames(forField: field, prefix: prefix) where result[name] == nil {
                result[name] = value
            }
        }
        return result
    }

    /// Variables a field's earlier names still set — minus any that would steer execution, which
    /// are dropped rather than refused so that renaming such a field actually fixes it.
    static func aliasEnvironmentNames(for credential: Credential, field: String, prefix: String) -> [String] {
        credential.environmentNames(forField: field, prefix: prefix).dropFirst()
            .filter { !EnvironmentVariableName.isReservedVariable($0) }
    }

    /// The variable names a plain field claims under its current name (aliases are best effort).
    static func nonSecretCurrentNames(for credential: Credential, prefix: String) -> Set<String> {
        Set(credential.fields.filter { !$0.value.secret && $0.value.setByCaller == nil && $0.value.value?.isEmpty == false }
            .map { EnvironmentVariableName.from(fieldName: $0.key, prefix: prefix) })
    }

    /// Why some plain fields are missing from the environment: a caller wrote them over the
    /// socket and nobody has confirmed them in the app. 【独立审计 2026-09-14】a plain value next
    /// to a key can redirect the key (`OPENAI_BASE_URL`, `HTTPS_PROXY`, `SSL_CERT_FILE`).
    static func unconfirmedPlainNote(credentialId: String, credential: Credential) -> String? {
        let pending = credential.unconfirmedPlainFields.sorted { $0.key < $1.key }
        guard !pending.isEmpty else { return nil }
        let list = pending.map { "\($0.key) (written by \($0.value))" }.joined(separator: ", ")
        return "Not injected from '\(credentialId)': \(list). A plain value set over the command line is not used until the person confirms it in KeyKeeper — open the credential there and click Confirm."
    }

    /// Plain values a credential contributes, split the same way secret ones are: a field's
    /// current name is a hard claim, its earlier names are best effort.
    ///
    /// Putting an old name in as a hard claim is what makes "a plain field once called X, and a
    /// secret field called X today" fail the whole command — with a `--prefix` suggestion that
    /// cannot help, because a prefix shifts both names equally.
    static func mergePlainFields(of credential: Credential, prefix: String,
                                 into injected: inout [String: String],
                                 aliases: inout [String: String]) throws {
        let currentNames = nonSecretCurrentNames(for: credential, prefix: prefix)
        for (envName, value) in nonSecretEnvironment(for: credential, prefix: prefix).sorted(by: { $0.key < $1.key }) {
            if EnvironmentVariableName.isReservedVariable(envName) {
                // A current name is refused; an earlier one is just not set, so the rename fixes it.
                guard !currentNames.contains(envName) else {
                    throw CommandFailure(EnvironmentVariableName.refusalMessage(envName))
                }
                continue
            }
            guard currentNames.contains(envName) else {
                aliases[envName] = aliases[envName] ?? value
                continue
            }
            if let existing = injected[envName], existing != value {
                throw CommandFailure(
                    "Environment variable conflict: '\(envName)' would be set by multiple fields. " +
                    "Use --prefix to disambiguate."
                )
            }
            injected[envName] = value
        }
    }

    /// An "ask every time" credential only needs an approval when something secret is actually
    /// read. If it holds nothing but plain metadata, a prompt would protect nothing.
    static func requiresAuthorization(for credential: Credential) -> Bool {
        credential.security == .strict && credential.fields.values.contains { $0.secret }
    }

    /// The caller's own sentence for the approval window, folded to one line and capped.
    func statedReason() -> CallerStatedReason? {
        CallerStatedReason.sanitize(reason)
    }

    /// The command about to run, for the approval window and the approval record. One line, capped.
    static func commandSummary(_ command: [String]) -> String? {
        let line = CallerStatedReason.printableLine(command.joined(separator: " "), limit: 200)
        return line.isEmpty ? nil : line
    }

    /// `-c` accepts current and earlier group IDs; everything after this uses the current one.
    static func resolveCredentialIds(_ names: [String], in meta: MetaFile) throws -> [String] {
        try names.map { name in
            guard let id = meta.resolveGroupId(name) else {
                throw CommandFailure("Credential '\(name)' not found. Run 'keykeeper list' to see the available IDs.")
            }
            return id
        }
    }

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()
        let session = SessionResolver.resolve()
        let credentialIds = try Self.resolveCredentialIds(credential, in: meta)
        let filePlan = try FileInjectionPlan(credentials: credentialIds, mappings: file, prefix: prefix, meta: meta)
        if filePlan.hasFiles { try CredentialFileLease.sweepStale() }
        var fileLease: CredentialFileLease?
        defer { fileLease?.close() }

        // Plain values are injected straight from meta.json; refuse if that file is not the one
        // the app signed. Only asked when something plain would actually be injected.
        let injectsPlainValues = credentialIds.contains { id in
            meta.credentials[id]?.fields.values.contains { !$0.secret && $0.setByCaller == nil && $0.value?.isEmpty == false } == true
        }
        for id in credentialIds {
            if let cred = meta.credentials[id], let note = Self.unconfirmedPlainNote(credentialId: id, credential: cred) {
                FileHandle.standardError.write(Data((note + "\n").utf8))
            }
        }
        if injectsPlainValues {
            let verdict = IPCClient.requestMetadataIntegrity()
            guard PlainValuePolicy.mayServe(verdict) else { throw CommandFailure(PlainValueRefusal.message(for: verdict)) }
        }

        // Collect all secret fields from requested credentials
        var injectedEnv: [String: String] = [:]
        var aliasEnv: [String: String] = [:]
        var secretValues: [String] = []

        for credId in credentialIds {
            guard let cred = meta.credentials[credId] else {
                throw CommandFailure("Credential '\(credId)' not found. Run 'keykeeper list' to see the available IDs.")
            }
            if let warning = CredentialExpiry.warning(credentialId: credId, expires: cred.expires) {
                FileHandle.standardError.write(Data((warning + "\n").utf8))
            }

            // Plain metadata values (an account id, a region): straight from meta.json.
            try Self.mergePlainFields(of: cred, prefix: prefix, into: &injectedEnv, aliases: &aliasEnv)

            let secretFieldNames = cred.fields
                .filter(\.value.secret)
                .map(\.key)
                .sorted()

            for fieldName in secretFieldNames {
                let envName = filePlan.environmentName(credential: credId, field: fieldName)
                    ?? (prefix + Self.envVarName(from: fieldName))

                if injectedEnv[envName] != nil {
                    throw CommandFailure(
                        "Environment variable conflict: '\(envName)' would be set by multiple fields. " +
                        "Use --prefix to disambiguate."
                    )
                }

                // Read secret via IPC — App owns the unlocked age session
                let value = try Self.readSecret(
                    credentialId: credId, credential: cred, fieldName: fieldName,
                    requestedFieldNames: secretFieldNames, session: session, statedReason: statedReason(),
                    requestedDuration: duration, commandSummary: Self.commandSummary(command)
                )
                if let format = cred.fields[fieldName]?.fileFormat {
                    _ = try format.validate(Data(value.utf8))
                    if fileLease == nil { fileLease = try CredentialFileLease() }
                    injectedEnv[envName] = try fileLease!.write(Data(value.utf8))
                    secretValues += format.redactionValues(for: value)
                } else {
                    injectedEnv[envName] = value
                    secretValues.append(value)
                    // Earlier field names keep their variables, so scripts written before a
                    // rename still work. A current name always wins over an old one.
                    for oldName in Self.aliasEnvironmentNames(for: cred, field: fieldName, prefix: prefix) {
                        aliasEnv[oldName] = aliasEnv[oldName] ?? value
                    }
                }
            }
        }
        for (name, value) in aliasEnv where injectedEnv[name] == nil {
            injectedEnv[name] = value
        }

        if injectedEnv.isEmpty {
            FileHandle.standardError.write(
                Data("Warning: nothing to inject from the specified credential(s) — no secret values and no plain fields. Running the command as is.\n".utf8)
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
    /// The CLI keeps no approvals of its own — they live in a Keychain item only the app can open —
    /// so it reads first and asks only when the app says this caller holds no approval.
    static func shouldRequestAuthorizationAfterRefusal(_ error: Error, security: SecurityLevel,
                                                       alreadyRetried: Bool) -> Bool {
        guard !alreadyRetried, security == .strict, case IPCError.noAuthorization = error else { return false }
        return true
    }

    /// Reads a secret, and if the app says this caller holds no approval, asks for one and tries
    /// exactly once more.
    static func readSecret(credentialId: String, credential: Credential, fieldName: String,
                           requestedFieldNames: [String],
                           session: SessionInfo, statedReason: CallerStatedReason?,
                           requestedDuration: RequestedDuration? = nil, commandSummary: String? = nil,
                           purpose: ValuePurpose = .inject) throws -> String {
        func read() throws -> String {
            try IPCClient.requestValue(credentialId: credentialId, fieldName: fieldName,
                                       sessionId: session.id, requestedFieldNames: requestedFieldNames,
                                       statedReason: statedReason, requestedDuration: requestedDuration,
                                       commandSummary: commandSummary, purpose: purpose)
        }
        do {
            return try read()
        } catch {
            guard shouldRequestAuthorizationAfterRefusal(error, security: credential.security, alreadyRetried: false) else {
                throw error
            }
            try requestApproval(credentialId: credentialId, credential: credential, session: session, statedReason: statedReason,
                                requestedDuration: requestedDuration, commandSummary: commandSummary)
            return try read()
        }
    }

    /// Ask the app to put the authorization window up for this credential.
    static func requestApproval(credentialId: String, credential: Credential, session: SessionInfo,
                                statedReason: CallerStatedReason? = nil,
                                requestedDuration: RequestedDuration? = nil, commandSummary: String? = nil) throws {
        let fieldNames = credential.fields.filter(\.value.secret).map(\.key).sorted()
        let request = AuthRequest(
            credentialId: credentialId,
            credentialLabel: credential.label,
            fieldNames: fieldNames,
            sessionId: session.id,
            sessionLabel: session.label,
            pid: ProcessInfo.processInfo.processIdentifier,
            statedReason: statedReason,
            requestedDuration: requestedDuration,
            commandSummary: commandSummary
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

enum PlainValueRefusal {
    /// Two different situations, two different sentences. 【独立审计第二轮】"could not reach the app"
    /// used to be reported as "changed outside KeyKeeper", sending people to look for a change that
    /// never happened.
    static func message(for verdict: MetadataIntegrityResponse.Verdict?) -> String {
        if verdict == .tampered {
            return "KeyKeeper's credential list was changed outside KeyKeeper. No plain values were used. Open KeyKeeper: it shows the warning and lets you confirm the list."
        }
        return "KeyKeeper could not confirm its credential list with the app (it is not running, still starting, or busy), so no plain values were used. Open KeyKeeper and run the command again."
    }
}
