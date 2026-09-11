import Foundation

/// A distinct wire message: older Apps cannot silently interpret source import as JSON import.
public struct SourceImportRequest: Codable, Sendable, Equatable {
    public let target: ClipboardSaveRequest
    public let filePath: String
    public let pythonSymbol: String
    public static let maximumBytes = 1_048_576
    public init(target: ClipboardSaveRequest, filePath: String, pythonSymbol: String) {
        self.target = target; self.filePath = filePath; self.pythonSymbol = pythonSymbol
    }
    public static func validSymbol(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil
    }
    public func validate() throws {
        try target.validate()
        guard Self.validSymbol(pythonSymbol), filePath.hasPrefix("/"), filePath.hasSuffix(".py"),
              filePath.utf8.count <= 4096,
              !filePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ClipboardSaveError.invalidSource
        }
    }
}
