// Verify with the public key only. Never loads Keychain or production private keys.
import CryptoKit
import Foundation

struct InvalidCandidate: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw InvalidCandidate(message) }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func verify(plist: URL, feed: URL, archive: URL, version: String) throws -> [String: String] {
    try require(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil, "Invalid version")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    guard let text = info?["SUPublicEDKey"] as? String, let bytes = Data(base64Encoded: text) else {
        throw InvalidCandidate("Missing trusted public key")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    let feedData = try Data(contentsOf: feed)
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feedData.range(of: marker, options: .backwards) else {
        throw InvalidCandidate("Missing signed-feed block")
    }
    let content = feedData.prefix(upTo: range.lowerBound)
    let block = String(decoding: feedData.suffix(from: range.upperBound), as: UTF8.self)
    let lines = block.split(separator: "\n").map(String.init)
    try require(lines.count == 3 && lines[2] == "-->", "Malformed signed-feed block")
    try require(lines[0].hasPrefix("edSignature: ") && lines[1].hasPrefix("length: "), "Malformed signature metadata")
    let feedSignature = Data(base64Encoded: String(lines[0].dropFirst("edSignature: ".count))) ?? Data()
    try require(Int(lines[1].dropFirst("length: ".count)) == content.count, "Feed length mismatch")
    try require(publicKey.isValidSignature(feedSignature, for: content), "Feed signature mismatch")

    let xml = try XMLDocument(data: content, options: [.nodeLoadExternalEntitiesNever])
    let items = try xml.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
    guard let item = items.first else { throw InvalidCandidate("Empty update feed") }
    try require(item.elements(forName: "sparkle:version").first?.stringValue == version, "Latest feed version mismatch")
    let enclosures = item.elements(forName: "enclosure")
    try require(enclosures.count == 1, "Expected exactly one full update archive")
    let enclosure = enclosures[0]
    let expectedURL = "https://github.com/IvyYang1999/KeyKeeper/releases/download/v\(version)/KeyKeeper-\(version).dmg"
    try require(enclosure.attribute(forName: "url")?.stringValue == expectedURL, "Archive URL mismatch")
    let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archiveData.count), "Archive length mismatch")
    let archiveSignature = Data(base64Encoded: enclosure.attribute(forName: "sparkle:edSignature")?.stringValue ?? "") ?? Data()
    try require(publicKey.isValidSignature(archiveSignature, for: archiveData), "Archive signature mismatch (possibly a same-version rebuild)")
    return ["version": version, "dmgSHA256": sha256(archiveData), "feedSHA256": sha256(feedData)]
}

do {
    let args = CommandLine.arguments
    try require(args.count == 5, "Usage: verify-update <trusted Info.plist> <appcast.xml> <archive.dmg> <version>")
    let result = try verify(plist: URL(fileURLWithPath: args[1]), feed: URL(fileURLWithPath: args[2]),
                            archive: URL(fileURLWithPath: args[3]), version: args[4])
    let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: output, as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("UPDATE REJECTED: \(error)\n".utf8))
    exit(1)
}
