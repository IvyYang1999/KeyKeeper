import ArgumentParser
import Darwin
import Foundation
import KeyKeeperCore

protocol PassphraseReading {
    func readPassphrase() throws -> String
}

enum PassphraseReaderError: Error, LocalizedError {
    case interactiveTerminalRequired
    case promptFailed

    var errorDescription: String? {
        switch self {
        case .interactiveTerminalRequired:
            return "unlock requires an interactive terminal; run it from a TTY"
        case .promptFailed:
            return "Could not read the passphrase from the interactive terminal"
        }
    }
}

struct TerminalPassphraseReader: PassphraseReading {
    private let isStandardInputTerminal: () -> Bool
    private let readHiddenPassphrase: () throws -> String

    init(
        isStandardInputTerminal: @escaping () -> Bool = {
            isatty(STDIN_FILENO) == 1
        },
        readHiddenPassphrase: @escaping () throws -> String = {
            var buffer = [CChar](repeating: 0, count: 4_096)
            defer {
                buffer.withUnsafeMutableBufferPointer { pointer in
                    pointer.initialize(repeating: 0)
                }
            }
            guard readpassphrase(
                "Passphrase: ",
                &buffer,
                buffer.count,
                RPP_ECHO_OFF | RPP_REQUIRE_TTY
            ) != nil else {
                throw PassphraseReaderError.promptFailed
            }
            return String(cString: buffer)
        }
    ) {
        self.isStandardInputTerminal = isStandardInputTerminal
        self.readHiddenPassphrase = readHiddenPassphrase
    }

    func readPassphrase() throws -> String {
        guard isStandardInputTerminal() else {
            throw PassphraseReaderError.interactiveTerminalRequired
        }
        return try readHiddenPassphrase()
    }
}

struct SessionCommandExecutor {
    typealias Request = (SessionControlRequest, Bool) throws -> SessionControlResponse

    private let request: Request

    init(_ request: @escaping Request) {
        self.request = request
    }

    static let live = SessionCommandExecutor { request, launchIfNeeded in
        try IPCClient.requestSessionControl(request, launchIfNeeded: launchIfNeeded)
    }

    func unlock(using passphraseReader: PassphraseReading) throws -> String {
        let passphrase = try passphraseReader.readPassphrase()
        let response = try request(
            SessionControlRequest(action: .unlock, passphrase: passphrase),
            true
        )
        return try formattedOutput(for: response)
    }

    func lock() throws -> String {
        do {
            let response = try request(SessionControlRequest(action: .lock), false)
            return try formattedOutput(for: response)
        } catch IPCError.appNotRunning {
            return "locked"
        }
    }

    func status() throws -> String {
        do {
            let response = try request(SessionControlRequest(action: .status), false)
            return try formattedOutput(for: response)
        } catch IPCError.appNotRunning {
            return "locked (app not running)"
        }
    }

    private func formattedOutput(for response: SessionControlResponse) throws -> String {
        guard response.success else {
            throw ValidationError(response.error ?? "Session control request failed")
        }
        switch response.state {
        case .locked:
            return "locked"
        case .unlockedManual:
            return "unlocked (until you lock manually or the KeyKeeper app quits/restarts)"
        case .unlockedUntil:
            guard let expiresAt = response.expiresAt else {
                throw ValidationError("App returned an invalid session status")
            }
            return "unlocked (until \(Self.dateFormatter.string(from: expiresAt)))"
        case .none:
            throw ValidationError("App returned an invalid session status")
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct UnlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Unlock the credential session using a hidden TTY prompt"
    )

    func run() throws {
        print(try SessionCommandExecutor.live.unlock(using: TerminalPassphraseReader()))
    }
}

struct LockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Lock the credential session"
    )

    func run() throws {
        print(try SessionCommandExecutor.live.lock())
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the credential session status"
    )

    func run() throws {
        print(try SessionCommandExecutor.live.status())
    }
}
