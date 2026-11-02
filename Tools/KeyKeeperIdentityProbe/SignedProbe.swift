import CryptoKit
import Darwin
import Foundation
import Security

struct ProbeReceipt: Codable {
    let sourceAccess: String
    let created: Bool
    let snapshotDigest: String
    let grantsTransferred: Int
}

enum SignedProbe {
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func createMetadata(_ bytes: Data, at url: URL) throws {
        try bytes.write(to: url, options: .withoutOverwriting)
    }

    static func metadataWriteSelfTest() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/keykeeper-metadata-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.json")
        let original = Data("synthetic-metadata".utf8)
        try createMetadata(original, at: url)
        var refused = false
        do { try createMetadata(Data("different".utf8), at: url) } catch { refused = true }
        guard refused, try Data(contentsOf: url) == original else { throw ProbeFailure.rejected }
        print("PASS metadata create-only: first write succeeded; replacement refused; source bytes unchanged")
    }

    static func random() throws -> Data {
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { throw ProbeFailure.io }
        return data
    }

    static func producer(context: ProbeContext, receiver: URL) throws {
        ProbeDiagnostics.phase(.producerIdentity)
        try ProbeIdentity.current(identifier: "com.keykeeper.app", team: context.team)
        try ProbeIdentity.receiver(receiver, team: context.team)
        // Negative real-signature boundary: the old executable is not a valid new receiver.
        let ownURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var wrongRejected = false
        do { try ProbeIdentity.receiver(ownURL, team: context.team) }
        catch { wrongRejected = true }
        guard wrongRejected else { throw ProbeFailure.signature }
        let snapshot = try ProbeCore.sample(secret: try random().base64EncodedString())
        let bytes = try snapshot.encoded(), metadata = try ProbeCore.metadata(snapshot), key = try random()
        let metadataURL = context.root.appendingPathComponent("synthetic-metadata.json")
        // Create-only at every layer: a repeated run ID cannot replace old evidence.
        guard !FileManager.default.fileExists(atPath: metadataURL.path) else { throw ProbeFailure.conflict }
        ProbeDiagnostics.phase(.sourceCreate)
        try ProbeKeychain.create(bytes, service: context.source, context: context)
        ProbeDiagnostics.phase(.integrityCreate)
        try ProbeKeychain.create(key, service: context.integrity, context: context)
        ProbeDiagnostics.phase(.metadataCreate)
        try createMetadata(metadata, at: metadataURL)
        ProbeDiagnostics.phase(.sourceReadback)
        guard let source = try ProbeKeychain.read(context.source, context: context),
              let sourceKey = try ProbeKeychain.read(context.integrity, context: context),
              source == bytes, sourceKey == key else { throw ProbeFailure.rejected }
        let wire = try ProbeCore.transfer(runID: context.runID, snapshot: source,
            metadata: Data(contentsOf: metadataURL), key: sourceKey)
        ProbeDiagnostics.phase(.firstTransfer)
        let first = try JSONDecoder().decode(ProbeReceipt.self,
            from: PrivatePipe.transfer(wire, receiver: receiver, context: context))
        ProbeDiagnostics.phase(.replayTransfer)
        let second = try JSONDecoder().decode(ProbeReceipt.self,
            from: PrivatePipe.transfer(wire, receiver: receiver, context: context))
        ProbeDiagnostics.phase(.sourceRecovery)
        guard first.created, !second.created, first.snapshotDigest == digest(bytes),
              second.snapshotDigest == first.snapshotDigest, first.grantsTransferred == 0,
              second.grantsTransferred == 0,
              try ProbeKeychain.read(context.source, context: context) == bytes,
              try ProbeKeychain.read(context.integrity, context: context) == key,
              try Data(contentsOf: metadataURL) == metadata else { throw ProbeFailure.rejected }
        print("PASS signed old→new: receiver authenticated; source access=\(first.sourceAccess); destination readback matched")
        print("PASS source retained: source item, integrity item, metadata unchanged; replay produced zero extra writes; grants transferred=0")
        print("snapshot SHA256: \(first.snapshotDigest)")
        print("metadata SHA256: \(digest(metadata))")
    }

    static func consumer(context: ProbeContext) throws {
        ProbeDiagnostics.phase(.consumerIdentity)
        try ProbeIdentity.current(identifier: "dev.keykeeper.app", team: context.team)
        try ProbeIdentity.parent(team: context.team)
        ProbeDiagnostics.phase(.sourceAccess)
        var sourceAccess: String
        do {
            sourceAccess = try ProbeKeychain.read(context.source, context: context) == nil ? "missing" : "readable"
        } catch ProbeFailure.keychain(let code) {
            guard [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem].contains(code) else { throw ProbeFailure.keychain(code) }
            sourceAccess = "denied(\(code))"
        }
        // Missing/denied direct access does not construct an empty snapshot or touch the target.
        // Only a complete authenticated bridge message can reach commit.
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        ProbeDiagnostics.phase(.receiveTransfer)
        let wire = try PrivatePipe.read(STDIN_FILENO, until: deadline)
        ProbeDiagnostics.phase(.destinationCommit)
        let created = try ProbeCore.commit(wire, runID: context.runID,
            read: { try ProbeKeychain.read(context.target, context: context) },
            create: { try ProbeKeychain.create($0, service: context.target, context: context) })
        ProbeDiagnostics.phase(.destinationReadback)
        guard let saved = try ProbeKeychain.read(context.target, context: context) else { throw ProbeFailure.rejected }
        let receipt = ProbeReceipt(sourceAccess: sourceAccess, created: created,
                                   snapshotDigest: digest(saved), grantsTransferred: 0)
        try PrivatePipe.write(ProbeCore.encode(receipt), fd: STDOUT_FILENO, until: deadline)
    }
}
