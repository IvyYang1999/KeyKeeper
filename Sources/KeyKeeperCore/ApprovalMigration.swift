import Foundation

/// Moves approvals from the files earlier versions wrote (grants.json, service-grants.json) and
/// from the website-session document into the approvals Keychain item, once.
///
/// Runs only while the item does not exist yet. The files are renamed, not deleted — they are
/// the record of what used to be — and approvals with no recorded owner are left in them:
/// they could never match any caller again, so importing them would only clutter the list.
public enum ApprovalMigration {
    public struct Result: Equatable {
        public var imported = 0
        public var skippedUnowned = 0
        public var renamedFiles: [String] = []
    }

    /// Legacy shapes, exactly as the old stores wrote them.
    struct LegacyGrant: Decodable {
        struct Duration: Decodable { var type: String; var value: String? }
        var id: String; var credentialId: String; var sessionId: String?
        var duration: LegacyDuration; var createdAt: Date; var consumed: Bool
        var subjectFingerprint: String?; var subjectDisplayName: String?; var onceFieldsRemaining: [String]?
    }
    struct LegacyServiceGrant: Decodable {
        var id: String; var credentialId: String; var subjectFingerprint: String; var subjectDisplayName: String
        var fields: [String]; var duration: LegacyDuration; var createdAt: Date; var lastUsedAt: Date?
    }
    struct LegacyGrantFile: Decodable { var grants: [LegacyGrant] }
    struct LegacyServiceGrantFile: Decodable {
        var mode: ServiceAuthorizationMode?; var grants: [LegacyServiceGrant]; var auditEvents: [ServiceAuditEvent]?
    }
    struct LegacySessionGrant: Decodable {
        var id: String; var sessionId: String; var subjectFingerprint: String; var subjectDisplayName: String
        var duration: LegacyDuration; var createdAt: Date; var lastUsedAt: Date?; var consumed: Bool
    }
    /// {"type": "once" | "session" | "timed" | "always", "value": …}
    struct LegacyDuration: Decodable {
        var duration: ApprovalDuration
        init(from decoder: Decoder) throws { duration = try ApprovalDuration(from: decoder) }
    }

    /// `sessionGrants` hands over what the session document still holds (and clears it).
    public static func runIfNeeded(directory: URL, store: ApprovalStore,
                                   sessionGrants: () throws -> Data? = { nil },
                                   now: Date = Date()) throws -> Result? {
        guard try !store.exists() else { return nil }
        let grantsURL = directory.appendingPathComponent("grants.json")
        let serviceURL = directory.appendingPathComponent("service-grants.json")
        let sessionData = try sessionGrants()
        let hasFiles = FileManager.default.fileExists(atPath: grantsURL.path) || FileManager.default.fileExists(atPath: serviceURL.path)
        guard hasFiles || sessionData != nil else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var document = ApprovalDocument()
        var result = Result()

        func adopt(_ approval: Approval) {
            guard GrantIssuancePolicy.mayRemember(subjectFingerprint: approval.subject.fingerprint) else {
                result.skippedUnowned += 1; return
            }
            guard approval.isValid(now: now, ignoringTerminalSession: true) else { return }
            document.approvals.append(approval); result.imported += 1
        }

        if let data = try? Data(contentsOf: grantsURL), let file = try? decoder.decode(LegacyGrantFile.self, from: data) {
            for grant in file.grants {
                adopt(Approval(id: grant.id,
                               subject: ApprovalSubject(fingerprint: grant.subjectFingerprint ?? "",
                                                        displayName: grant.subjectDisplayName ?? grant.subjectFingerprint ?? ""),
                               target: .credential(id: grant.credentialId, fields: nil),
                               duration: grant.duration.duration, createdAt: grant.createdAt,
                               consumed: grant.consumed, onceFieldsRemaining: grant.onceFieldsRemaining))
            }
        }
        if let data = try? Data(contentsOf: serviceURL), let file = try? decoder.decode(LegacyServiceGrantFile.self, from: data) {
            document.mode = file.mode ?? .permissive
            document.auditEvents = Array((file.auditEvents ?? []).suffix(ApprovalStore.maxAuditEvents))
            for grant in file.grants {
                let once = grant.duration.duration == .once
                adopt(Approval(id: grant.id,
                               subject: ApprovalSubject(fingerprint: grant.subjectFingerprint, displayName: grant.subjectDisplayName),
                               target: .credential(id: grant.credentialId, fields: grant.fields),
                               duration: grant.duration.duration, createdAt: grant.createdAt, lastUsedAt: grant.lastUsedAt,
                               consumed: once && grant.fields.isEmpty, onceFieldsRemaining: once ? grant.fields : nil))
            }
        }
        if let sessionData, let grants = try? decoder.decode([LegacySessionGrant].self, from: sessionData) {
            for grant in grants {
                adopt(Approval(id: grant.id,
                               subject: ApprovalSubject(fingerprint: grant.subjectFingerprint, displayName: grant.subjectDisplayName),
                               target: .session(id: grant.sessionId),
                               duration: grant.duration.duration, createdAt: grant.createdAt,
                               lastUsedAt: grant.lastUsedAt, consumed: grant.consumed))
            }
        }

        try store.replaceAll(with: document)

        let stamp = ISO8601DateFormatter().string(from: now).prefix(10)
        for url in [grantsURL, serviceURL] where FileManager.default.fileExists(atPath: url.path) {
            let renamed = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".migrated-\(stamp)")
            try? FileManager.default.removeItem(at: renamed)
            try FileManager.default.moveItem(at: url, to: renamed)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
            result.renamedFiles.append(renamed.lastPathComponent)
        }
        return result
    }
}
