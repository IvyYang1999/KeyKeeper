import Foundation
import Darwin
import KeyKeeperCore

/// Hold an open descriptor and identity snapshot, but do not read bytes before approval.
/// O_NONBLOCK prevents FIFOs/devices from hanging even before their type is checked.
@MainActor final class CredentialFileSource: ClipboardSaveSource {
    let fileFormat: CredentialFileFormat?
    let pythonSymbol: String?
    let displayFilePath: String?
    private let descriptor: Int32
    private let snapshot: stat

    init(filePath: String, pythonSymbol: String? = nil) throws {
        let target = ClipboardSaveRequest(credentialId: "validate", fieldName: "file")
        if let pythonSymbol {
            try SourceImportRequest(target: target, filePath: filePath, pythonSymbol: pythonSymbol).validate()
        } else {
            try FileImportRequest(target: target, filePath: filePath).validate()
        }
        self.pythonSymbol = pythonSymbol
        fileFormat = pythonSymbol == nil ? .serviceAccountJSON : nil
        let invalid: ClipboardSaveError = pythonSymbol == nil ? .invalidFile : .invalidSource
        let fd = open(filePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw invalid }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0,
              info.st_size <= (pythonSymbol == nil ? CredentialFileFormat.maximumBytes : SourceImportRequest.maximumBytes) else {
            close(fd); throw invalid
        }
        descriptor = fd; snapshot = info; displayFilePath = filePath
    }
    deinit { close(descriptor) }

    var changeCount: Int { unchanged() ? 0 : 1 }
    func clearIfUnchanged(since count: Int) { /* Never delete the downloaded original. */ }

    func readText() throws -> String? {
        guard unchanged() else { throw ClipboardSaveError.fileChanged }
        var data = Data(count: Int(snapshot.st_size) + 1)
        let count = data.withUnsafeMutableBytes { buffer in
            pread(descriptor, buffer.baseAddress!, buffer.count, 0)
        }
        guard count == snapshot.st_size, unchanged() else { throw ClipboardSaveError.fileChanged }
        data.count = count
        if let pythonSymbol { return try PythonSourceExtractor.extract(data, symbol: pythonSymbol) }
        return try CredentialFileFormat.serviceAccountJSON.validate(data)
    }

    private func unchanged() -> Bool {
        var current = stat(); var named = stat()
        guard let filePath = displayFilePath, fstat(descriptor, &current) == 0,
              lstat(filePath, &named) == 0 else { return false }
        return matches(current) && matches(named)
    }
    private func matches(_ info: stat) -> Bool {
        info.st_dev == snapshot.st_dev && info.st_ino == snapshot.st_ino &&
        info.st_size == snapshot.st_size && info.st_mode == snapshot.st_mode &&
        info.st_uid == snapshot.st_uid &&
        info.st_mtimespec.tv_sec == snapshot.st_mtimespec.tv_sec &&
        info.st_mtimespec.tv_nsec == snapshot.st_mtimespec.tv_nsec &&
        info.st_ctimespec.tv_sec == snapshot.st_ctimespec.tv_sec &&
        info.st_ctimespec.tv_nsec == snapshot.st_ctimespec.tv_nsec
    }
}
