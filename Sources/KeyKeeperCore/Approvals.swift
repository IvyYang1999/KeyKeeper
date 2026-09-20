import Foundation

// One approval model for everything a person can say yes to: a key for a caller, a website login
// for a caller. Three models used to exist (strict grants, service grants, session grants), each
// with its own store, matching rules and edge cases — and every rule fixed in one had to be fixed
// in the other two, which on 2026-09-13 it repeatedly was not. See 方案-20260914-授权统一.

/// Who was approved. The fingerprint is what is matched; the display name is what is shown.
public struct ApprovalSubject: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var displayName: String

    public init(fingerprint: String, displayName: String) {
        self.fingerprint = fingerprint
        self.displayName = displayName
    }
}

/// What was approved.
public enum ApprovalTarget: Codable, Equatable, Sendable {
    /// `fields` nil means every secret field of the credential, now and later — what approving a
    /// strict credential has always meant. A list means those fields only.
    case credential(id: String, fields: [String]?)
    /// One saved website login, to open in a window.
    case session(id: String)

    private enum CodingKeys: String, CodingKey { case kind, id, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "credential": self = .credential(id: try c.decode(String.self, forKey: .id),
                                              fields: try c.decodeIfPresent([String].self, forKey: .fields))
        case "session": self = .session(id: try c.decode(String.self, forKey: .id))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown target \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .credential(let id, let fields):
            try c.encode("credential", forKey: .kind); try c.encode(id, forKey: .id)
            try c.encodeIfPresent(fields, forKey: .fields)
        case .session(let id):
            try c.encode("session", forKey: .kind); try c.encode(id, forKey: .id)
        }
    }

    public var credentialId: String? {
        if case .credential(let id, _) = self { return id }
        return nil
    }

    public var sessionId: String? {
        if case .session(let id) = self { return id }
        return nil
    }

    public func covers(credentialId: String, field: String) -> Bool {
        guard case .credential(let id, let fields) = self, id == credentialId else { return false }
        return fields.map { $0.contains(field) } ?? true
    }
}

/// How long an approval lasts.
public enum ApprovalDuration: Codable, Equatable, Sendable {
    /// The one run that asked.
    case once
    /// Until that terminal session ends (24-hour hard cap).
    case terminalSession(String)
    /// While the identified process (the agent app, the script's shell) is running: pid plus the
    /// kernel's start time, so a reused pid inherits nothing. yyt 2026-09-14: "the same agent doing
    /// the same job" — what people clicked "always" for. Seven-day hard cap.
    case process(pid: Int32, startedAt: Date)
    case timed(Date)
    case always

    private enum CodingKeys: String, CodingKey { case type, value, pid, startedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "once": self = .once
        case "terminalSession", "session": self = .terminalSession(try c.decode(String.self, forKey: .value))
        case "process": self = .process(pid: try c.decode(Int32.self, forKey: .pid), startedAt: try c.decode(Date.self, forKey: .startedAt))
        case "timed": self = .timed(try c.decode(Date.self, forKey: .value))
        case "always": self = .always
        case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown duration \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .once: try c.encode("once", forKey: .type)
        case .terminalSession(let id): try c.encode("terminalSession", forKey: .type); try c.encode(id, forKey: .value)
        case .process(let pid, let startedAt):
            try c.encode("process", forKey: .type); try c.encode(pid, forKey: .pid); try c.encode(startedAt, forKey: .startedAt)
        case .timed(let date): try c.encode("timed", forKey: .type); try c.encode(date, forKey: .value)
        case .always: try c.encode("always", forKey: .type)
        }
    }

    /// Two approvals of the same subject and target replace each other when their durations are
    /// of the same kind — except terminal sessions and processes, which coexist per session/run.
    func sameKind(as other: ApprovalDuration) -> Bool {
        switch (self, other) {
        case (.once, .once), (.timed, .timed), (.always, .always): return true
        case (.terminalSession(let a), .terminalSession(let b)): return a == b
        case (.process(let p, let s), .process(let q, let t)): return p == q && s == t
        default: return false
        }
    }
}

/// Answers "is that process still running" for `.process` approvals; injectable for tests.
public typealias ProcessAliveCheck = @Sendable (Int32, Date) -> Bool

public struct Approval: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var subject: ApprovalSubject
    public var target: ApprovalTarget
    public var duration: ApprovalDuration
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// A `.once` approval that has been used up.
    public var consumed: Bool
    /// For `.once` on a credential: the fields of the one run that have not been read yet. One
    /// approval covers that run however many fields it reads — it used to be spent on the first,
    /// so a credential with N secret fields prompted N times. Nil means spent on the first use.
    public var onceFieldsRemaining: [String]?
    /// What the caller said it needed the key for when the person approved. Its words, kept for
    /// the record; never a fact KeyKeeper verified.
    public var reason: String?
    /// The command line that was running when the person approved, as the caller reported it.
    public var command: String?

    public init(id: String = UUID().uuidString, subject: ApprovalSubject, target: ApprovalTarget,
                duration: ApprovalDuration, createdAt: Date = Date(), lastUsedAt: Date? = nil,
                consumed: Bool = false, onceFieldsRemaining: [String]? = nil, reason: String? = nil,
                command: String? = nil) {
        self.id = id
        self.subject = subject
        self.target = target
        self.duration = duration
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.consumed = consumed
        self.onceFieldsRemaining = onceFieldsRemaining
        self.reason = reason
        self.command = command
    }

    /// How long a "just this once" approval stays open for the rest of the run's fields.
    public static let onceWindow: TimeInterval = 120
    /// Terminal-session approvals end with the session, and in any case after a day.
    public static let terminalSessionMaxAge: TimeInterval = 24 * 60 * 60
    /// A process approval ends with the process, and in any case after a week.
    public static let processMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// `terminalSession` is the caller's current session; nil means it has none. `ignoringTerminalSession`
    /// asks "could this still apply to some session" — what pruning needs.
    public func isValid(now: Date, terminalSession: String? = nil, ignoringTerminalSession: Bool = false,
                        processAlive: ProcessAliveCheck = ProcessLiveness.isAlive) -> Bool {
        switch duration {
        case .once:
            guard !consumed else { return false }
            guard onceFieldsRemaining != nil else { return true }
            return now.timeIntervalSince(createdAt) < Self.onceWindow
        case .terminalSession(let id):
            let withinAge = now.timeIntervalSince(createdAt) < Self.terminalSessionMaxAge
            return withinAge && (ignoringTerminalSession || terminalSession == id)
        case .process(let pid, let startedAt):
            return now.timeIntervalSince(createdAt) < Self.processMaxAge && processAlive(pid, startedAt)
        case .timed(let until):
            return now < until
        case .always:
            return true
        }
    }

    /// A "once" approval hands each field out one time; the window only exists so the other
    /// fields of the same run can follow. 【独立审计 2026-09-14】isValid alone let the same field be
    /// read again and again for 120 s.
    public func stillCovers(field: String) -> Bool {
        guard case .once = duration, let remaining = onceFieldsRemaining else { return true }
        return remaining.contains(field)
    }

    /// What another process may see of an approval: whose (a name), what, how long — not the
    /// fingerprint, which names the script's path hash or the app's bundle. 【独立审计 2026-09-14】
    public func redactedForCaller() -> Approval {
        var copy = self
        let kind = subject.fingerprint.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        copy.subject = ApprovalSubject(fingerprint: kind + ":…", displayName: subject.displayName)
        return copy
    }

    func supersedes(_ other: Approval) -> Bool {
        subject.fingerprint == other.subject.fingerprint && target == other.target && duration.sameKind(as: other.duration)
    }
}

/// Whether reads of a "Background OK" credential by a caller nobody approved yet are allowed
/// (permissive) or ask first (enforced).
public enum ServiceAuthorizationMode: String, Codable, Sendable, Equatable {
    case permissive
    case enforced
}

/// One line in the access log: what a background read decided and why.
public struct ServiceAuditEvent: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var credentialId: String
    public var fieldName: String
    public var subjectFingerprint: String
    public var subjectDisplayName: String
    public var mode: ServiceAuthorizationMode
    public var decision: String
    /// The caller's stated reason, when it gave one.
    public var reason: String?
    public var command: String?
    /// Correlates a missed request with its dismissible inbox item. Older audit rows omit it.
    public var requestID: String?

    public init(timestamp: Date = Date(), credentialId: String, fieldName: String,
                subjectFingerprint: String, subjectDisplayName: String,
                mode: ServiceAuthorizationMode, decision: String, reason: String? = nil, command: String? = nil,
                requestID: String? = nil) {
        self.timestamp = timestamp
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.subjectFingerprint = subjectFingerprint
        self.subjectDisplayName = subjectDisplayName
        self.mode = mode
        self.decision = decision
        self.reason = reason
        self.command = command
        self.requestID = requestID
    }
}

/// Where the second-opinion model lives, and its key. Kept in the app-owned Keychain item next
/// to the approvals — nothing else on the Mac can write it. 【独立审计 2026-09-14】the first cut
/// stored these in UserDefaults and named a KeyKeeper credential to read the key from: any
/// process could point that at a real credential (or rename one into it) and at its own server.
/// The key is typed in by the person and lives only here; it is never a credential.
public struct ReviewerSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var apiKey: String
    public var baseURL: String
    /// Nil means "guess from the host".
    public var api: ReviewerEndpoint.API?
    public var model: String

    public init(enabled: Bool = false, apiKey: String = "",
                baseURL: String = ReviewerEndpoint.defaultBaseURL, api: ReviewerEndpoint.API? = nil,
                model: String = ReviewerEndpoint.defaultModel) {
        self.enabled = enabled
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.api = api
        self.model = model
    }
}

/// Everything in the approvals Keychain item.
public struct ApprovalDocument: Codable, Equatable, Sendable {
    public var version: Int
    /// Fresh stores start enforced: a "Background OK" key is not readable by any local process
    /// until the person has seen that caller once. Stores migrated from 0.3.3 keep their mode.
    public var mode: ServiceAuthorizationMode
    public var approvals: [Approval]
    public var auditEvents: [ServiceAuditEvent]
    public var reviewerSettings: ReviewerSettings?

    public init(version: Int = 2, mode: ServiceAuthorizationMode = .enforced,
                approvals: [Approval] = [], auditEvents: [ServiceAuditEvent] = [],
                reviewerSettings: ReviewerSettings? = nil) {
        self.version = version
        self.mode = mode
        self.approvals = approvals
        self.auditEvents = auditEvents
        self.reviewerSettings = reviewerSettings
    }
}

/// Whether an approval may be remembered for — or matched against — this caller.
///
/// Unverified fingerprints are constants that a process can land in on purpose (run a copied
/// binary, then delete it); an approval stored under one would be one anybody could fall into.
public enum GrantIssuancePolicy {
    public static func mayRemember(subjectFingerprint: String?) -> Bool {
        guard let subjectFingerprint, !subjectFingerprint.isEmpty else { return false }
        return !subjectFingerprint.hasPrefix(CallerSubject.unverifiedPrefix)
    }
}

public enum ApprovalStoreError: Error, LocalizedError, Equatable {
    case unavailable
    case capacity

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "KeyKeeper could not read its approvals from the Keychain."
        case .capacity: return "Too many approvals are stored. Revoke some in KeyKeeper."
        }
    }
}

/// The approvals, in one Keychain item the app owns.
///
/// Same protection the credentials have: another process running as the user cannot read or
/// rewrite the item without the person clicking through a Keychain prompt. No signing, no key,
/// no first-launch migration of a signature — the machinery that produced two critical bugs on
/// 2026-09-13 is gone, not fixed.
///
/// One process, one instance (`shared` in the app), a lock around every read-modify-write.
public final class ApprovalStore: @unchecked Sendable {
    public static let maxApprovals = 512
    public static let maxAuditEvents = 500

    private let io: KeychainBlobIO
    /// How `.process` approvals learn whether their process still runs. Tests inject one.
    public var processAlive: ProcessAliveCheck = ProcessLiveness.isAlive
    private let lock = NSLock()
    /// Whether the item was ever seen: decides create versus replace on the next write.
    private var observed = false

    public init(io: KeychainBlobIO) { self.io = io }

    /// The item name follows the credential store's, so an isolated instance gets its own.
    public static func serviceName(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        try SecItemBlobIO.serviceName(environment: environment) + ".approvals"
    }

    /// The app's one instance. Resolved lazily so the environment (an isolated instance) is honoured.
    public static let shared: ApprovalStore = {
        let name = (try? serviceName()) ?? SecItemBlobIO.defaultService + ".approvals"
        return ApprovalStore(io: SecItemBlobIO(service: name))
    }()

    // MARK: Reading

    /// Whether anything has ever been written. Migration keys off this.
    public func exists() throws -> Bool {
        try lock.withLock { try io.readBlob() != nil }
    }

    public func mode() throws -> ServiceAuthorizationMode { try lock.withLock { try load().mode } }

    public func all() throws -> [Approval] { try lock.withLock { try load().approvals } }

    public func approvals(forCredential credentialId: String) throws -> [Approval] {
        try all().filter { $0.target.credentialId == credentialId }
    }

    public func approvals(forSession sessionId: String) throws -> [Approval] {
        try all().filter { $0.target.sessionId == sessionId }
    }

    /// Whether any approval names this credential — a new credential under a reused ID must not
    /// inherit what was given to the old one.
    public func hasApprovals(forCredential credentialId: String) throws -> Bool {
        try !approvals(forCredential: credentialId).isEmpty
    }

    /// The approval that lets this caller read this field right now, if any.
    public func valid(credentialId: String, field: String, fingerprint: String,
                      terminalSession: String?, now: Date = Date()) throws -> Approval? {
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: fingerprint) else { return nil }
        return try all().first {
            $0.subject.fingerprint == fingerprint
                && $0.target.covers(credentialId: credentialId, field: field)
                && $0.stillCovers(field: field)
                && $0.isValid(now: now, terminalSession: terminalSession, processAlive: processAlive)
        }
    }

    /// The approval that lets this caller open this login right now, if any.
    public func valid(sessionId: String, fingerprint: String, now: Date = Date()) throws -> Approval? {
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: fingerprint) else { return nil }
        return try all().first {
            $0.subject.fingerprint == fingerprint && $0.target.sessionId == sessionId && $0.isValid(now: now, processAlive: processAlive)
        }
    }

    public func auditEvents() throws -> [ServiceAuditEvent] { try lock.withLock { try load().auditEvents } }

    // MARK: Writing

    public func setMode(_ mode: ServiceAuthorizationMode) throws {
        try update { $0.mode = mode }
    }

    public func reviewerSettings() throws -> ReviewerSettings? { try lock.withLock { try load().reviewerSettings } }

    public func setReviewerSettings(_ settings: ReviewerSettings) throws {
        try update { $0.reviewerSettings = settings }
    }

    /// Store an approval. Never for a caller that cannot be identified: refused, not silently dropped.
    public func add(_ approval: Approval) throws {
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: approval.subject.fingerprint) else {
            throw ApprovalIssuanceError.unidentifiedCaller
        }
        try update { document in
            document.approvals.removeAll { approval.supersedes($0) }
            guard document.approvals.count < Self.maxApprovals else { throw ApprovalStoreError.capacity }
            document.approvals.append(approval)
        }
    }

    /// A value was handed out (or a window opened) under this approval.
    public func noteUse(id: String, field: String?, now: Date = Date()) throws {
        try update { document in
            guard let index = document.approvals.firstIndex(where: { $0.id == id }) else { return }
            document.approvals[index].lastUsedAt = now
            guard case .once = document.approvals[index].duration else { return }
            if let field, var remaining = document.approvals[index].onceFieldsRemaining {
                remaining.removeAll { $0 == field }
                document.approvals[index].onceFieldsRemaining = remaining
                document.approvals[index].consumed = remaining.isEmpty
            } else {
                document.approvals[index].consumed = true
            }
        }
    }

    /// Whether an approval with that ID was there to revoke.
    @discardableResult
    public func revoke(id: String) throws -> Bool {
        try update { document in
            let before = document.approvals.count
            document.approvals.removeAll { $0.id == id }
            return document.approvals.count != before
        }
    }

    public func revokeAll(forCredential credentialId: String) throws {
        try update { $0.approvals.removeAll { $0.target.credentialId == credentialId } }
    }

    /// A saved login was deleted: what was given to it goes with it, so a new snapshot under the
    /// same id inherits nothing.
    public func revokeAll(forSession sessionId: String) throws {
        try update { $0.approvals.removeAll { $0.target.sessionId == sessionId } }
    }

    /// A credential's group ID or field names changed: approvals follow them. Without this a
    /// rename silently voided every approval that named the old field.
    public func moveCredential(from oldId: String, to newId: String, fieldMap: [String: String]) throws {
        guard oldId != newId || !fieldMap.isEmpty else { return }
        try update { document in
            for index in document.approvals.indices {
                guard case .credential(let id, let fields) = document.approvals[index].target, id == oldId else { continue }
                let moved = fields.map { Array(Set($0.map { fieldMap[$0] ?? $0 })).sorted() }
                document.approvals[index].target = .credential(id: newId, fields: moved)
                if let remaining = document.approvals[index].onceFieldsRemaining {
                    document.approvals[index].onceFieldsRemaining = remaining.map { fieldMap[$0] ?? $0 }
                }
            }
        }
    }

    /// Before a credential gains a new secret field, turn "all fields, now and later" grants
    /// into the exact pre-existing set. Existing access keeps working; the new value inherits no
    /// read permission merely because it joined the same credential.
    public func freezeWildcardCredentialApprovals(credentialId: String, existingFields: [String]) throws {
        let fields = Array(Set(existingFields)).sorted()
        try update { document in
            for index in document.approvals.indices {
                guard case .credential(let id, nil) = document.approvals[index].target,
                      id == credentialId else { continue }
                document.approvals[index].target = .credential(id: id, fields: fields)
                if let remaining = document.approvals[index].onceFieldsRemaining {
                    document.approvals[index].onceFieldsRemaining = remaining.filter(fields.contains)
                }
            }
        }
    }

    public func recordAudit(_ event: ServiceAuditEvent) throws {
        try update { document in
            document.auditEvents.append(event)
            if document.auditEvents.count > Self.maxAuditEvents {
                document.auditEvents.removeFirst(document.auditEvents.count - Self.maxAuditEvents)
            }
        }
    }

    /// Spent and expired approvals grant nothing; they only clutter the list.
    public func pruneExpired(now: Date = Date()) throws {
        try update { $0.approvals.removeAll { !$0.isValid(now: now, ignoringTerminalSession: true, processAlive: processAlive) } }
    }

    /// Used by migration only: the whole document, at once.
    public func replaceAll(with document: ApprovalDocument) throws {
        try update { $0 = document }
    }

    // MARK: Document

    private func load() throws -> ApprovalDocument {
        guard let bytes = try io.readBlob() else { return ApprovalDocument() }
        observed = true
        guard bytes.count <= 4_194_304 else { throw ApprovalStoreError.unavailable }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(ApprovalDocument.self, from: bytes)
            guard document.version == 2 else { throw ApprovalStoreError.unavailable }
            return document
        } catch { throw ApprovalStoreError.unavailable }
    }

    @discardableResult
    private func update<T>(_ body: (inout ApprovalDocument) throws -> T) throws -> T {
        try lock.withLock {
            var document = try load()
            let result = try body(&document)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let bytes = try encoder.encode(document)
            try io.writeBlob(bytes, replacingExisting: observed)
            observed = true
            return result
        }
    }
}

public enum ApprovalIssuanceError: Error, LocalizedError, Equatable {
    case unidentifiedCaller
    case missingTerminalSession
    case requestEnded

    public var errorDescription: String? {
        switch self {
        case .unidentifiedCaller:
            return "KeyKeeper could not identify the program asking, so this decision cannot be remembered."
        case .missingTerminalSession:
            return "无终端会话，请选 Always 或 1 hour"
        case .requestEnded:
            return "请求方已结束；这次调用不能再批准。请让 Agent 重新发起。"
        }
    }
}

public enum AccessDecision: Equatable {
    /// Read it; the approval it happened under, if any (nil: permissive mode, nobody approved).
    case allowed(Approval?)
    /// Somebody has to say yes first.
    case needsApproval
}

/// The one place that decides whether a caller may read a field.
public enum AccessPolicy {
    /// - strict: only an approval for this caller.
    /// - standard ("Background OK"): an approval, or — with nobody having approved — the mode
    ///   decides, and either way the access log gets a line.
    public static func decide(credential: Credential, credentialId: String, field: String,
                              caller: CallerIdentity, terminalSession: String?,
                              store: ApprovalStore, reason: String? = nil, command: String? = nil,
                              now: Date = Date(), requestID: String? = nil) throws -> AccessDecision {
        if let approval = try store.valid(credentialId: credentialId, field: field,
                                          fingerprint: caller.subject.fingerprint,
                                          terminalSession: terminalSession, now: now) {
            return .allowed(approval)
        }
        guard credential.security == .standard else { return .needsApproval }
        let mode = try store.mode()
        try store.recordAudit(ServiceAuditEvent(
            timestamp: now, credentialId: credentialId, fieldName: field,
            subjectFingerprint: caller.subject.fingerprint, subjectDisplayName: caller.displayName,
            mode: mode, decision: mode == .permissive ? "allowed_without_grant" : "prompt_required",
            reason: reason, command: command, requestID: requestID))
        return mode == .permissive ? .allowed(nil) : .needsApproval
    }

    /// "This terminal session" needs a session to bind to.
    public static func resolveIssuedDuration(requested: ApprovalDuration, terminalSession: String?) throws -> ApprovalDuration {
        guard case .terminalSession = requested else { return requested }
        guard let terminalSession, !terminalSession.isEmpty else { throw ApprovalIssuanceError.missingTerminalSession }
        return .terminalSession(terminalSession)
    }

    /// Keys that need approval go only to callers an approval can be held for. An unidentified
    /// caller used to get the prompt anyway, then an approval that could never match it, then a
    /// second prompt; refusing up front, with the reason, costs nobody a click.
    public static func strictRefusal(for fingerprint: String) -> String? {
        guard !GrantIssuancePolicy.mayRemember(subjectFingerprint: fingerprint) else { return nil }
        return "KeyKeeper could not identify the program asking (it may have exited, or macOS could not attribute it), so it cannot give it keys that need approval. No prompt was shown. Run the command again from a terminal or an app."
    }
}

/// A first request has to say why.
///
/// yyt 2026-09-14: the reason is the one thing in the window the person can judge "is this
/// necessary" by, so an agent asking for the first time must give one. Callers already approved
/// never see a prompt and are not asked; cron jobs keep running.
public enum ReasonPolicy {
    /// What the window says when a caller gave no reason. 0.3.4 refused such requests outright;
    /// that silently broke every integration written before 0.3.4 (they carry no --reason and
    /// discard stderr) the moment the identity change made them "first requests" again. The
    /// person now still sees the window, told plainly that nothing was said, with "just this
    /// once" recommended. The skill keeps --reason as a hard rule for agents.
    public static func missingReasonNote(statedReason: CallerStatedReason?, callerName: String) -> String? {
        if let text = statedReason?.text, !text.isEmpty { return nil }
        return "\(callerName) gave no reason for this request."
    }
}
