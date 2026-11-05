import Foundation

private func readTrimmed(_ url: URL) -> String? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func gitDirectory(packageDirectory: URL) -> URL? {
    let dotGit = packageDirectory.appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
        return nil
    }
    if isDirectory.boolValue {
        return dotGit
    }

    guard let pointer = readTrimmed(dotGit), pointer.hasPrefix("gitdir: ") else {
        return nil
    }
    let location = String(pointer.dropFirst("gitdir: ".count))
    return URL(fileURLWithPath: location, relativeTo: packageDirectory).standardizedFileURL
}

/// A linked worktree keeps only HEAD in its own git directory; branch refs and packed-refs live
/// in the shared repository named by `commondir`. 【曾经的 bug】reading refs only from the worktree
/// directory made every worktree build `keykeeper unknown`.
private func commonDirectory(gitDirectory: URL) -> URL? {
    guard let pointer = readTrimmed(gitDirectory.appendingPathComponent("commondir")) else { return nil }
    return URL(fileURLWithPath: pointer, relativeTo: gitDirectory.appendingPathComponent("")).standardizedFileURL
}

private func isCommitIdentifier(_ candidate: String) -> Bool {
    candidate.count >= 7 && candidate.allSatisfy { $0.isHexDigit }
}

private func resolveRevision(packageDirectory: URL) -> String {
    if let injected = ProcessInfo.processInfo.environment["KEYKEEPER_BUILD_VERSION"],
       !injected.isEmpty,
       injected.count <= 64,
       injected.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) {
        return injected
    }

    guard let gitDirectory = gitDirectory(packageDirectory: packageDirectory),
          let head = readTrimmed(gitDirectory.appendingPathComponent("HEAD")) else {
        return "unknown"
    }

    if isCommitIdentifier(head) {
        return String(head.prefix(12))
    }

    guard head.hasPrefix("ref: ") else {
        return "unknown"
    }
    let reference = String(head.dropFirst("ref: ".count))
    let directories = [gitDirectory] + (commonDirectory(gitDirectory: gitDirectory).map { [$0] } ?? [])
    for directory in directories {
        if let revision = readTrimmed(directory.appendingPathComponent(reference)),
           isCommitIdentifier(revision) {
            return String(revision.prefix(12))
        }
    }
    for directory in directories {
        guard let packedReferences = readTrimmed(directory.appendingPathComponent("packed-refs")) else { continue }
        for line in packedReferences.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            if fields.count == 2, fields[1] == reference, isCommitIdentifier(fields[0]) {
                return String(fields[0].prefix(12))
            }
        }
    }
    return "unknown"
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("VersionGenerator requires package and output paths\n".utf8))
    exit(64)
}

let packageDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let revision = resolveRevision(packageDirectory: packageDirectory)
let source = """
// Generated at build time. Do not edit.
enum BuildVersion {
    static let identifier = "keykeeper \(revision)"
}
"""

do {
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try source.write(to: output, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("VersionGenerator failed: \(error)\n".utf8))
    exit(1)
}
