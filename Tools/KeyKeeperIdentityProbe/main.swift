import Foundation
import Security
import Darwin

do {
    ProbeDiagnostics.phase(.startup)
    signal(SIGPIPE, SIG_IGN)
    // Process-local setting only. Neither probe can display a Keychain authorization dialog.
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw ProbeFailure.rejected }
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["self-test"] {
        ProbeDiagnostics.phase(.selfTest)
        try ProbeCore.selfTest()
        try SignedProbe.metadataWriteSelfTest()
        try ProbeContext.selfTest()
    } else {
        guard let action = arguments.first else { throw ProbeFailure.rejected }
        ProbeDiagnostics.phase(.isolation)
        let context = try ProbeContext(arguments: Array(arguments.dropFirst()))
        switch action {
        case "producer":
            guard let index = arguments.firstIndex(of: "--receiver"), index + 1 < arguments.count else { throw ProbeFailure.isolation }
            try SignedProbe.producer(context: context, receiver: URL(fileURLWithPath: arguments[index + 1]))
        case "consumer": try SignedProbe.consumer(context: context)
        default: throw ProbeFailure.rejected
        }
    }
} catch let failure as ProbeFailure {
    FileHandle.standardError.write(Data("FAIL identity probe: \(failure.category)\n".utf8))
    exit(1)
} catch {
    // Never include Codable payloads or underlying errors in probe output.
    FileHandle.standardError.write(Data("FAIL identity probe: unexpected\n".utf8))
    exit(1)
}
