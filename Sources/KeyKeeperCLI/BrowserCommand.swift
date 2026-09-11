import Foundation
import ArgumentParser
import KeyKeeperCore
import Darwin

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browser", abstract:
        "Manage selected website sessions. No Cookie values are returned. Open/delete require native confirmation.")
    @Argument(help: "list, open, stop or delete") var action: String
    @Argument(help: "Session ID returned by list.") var id: String?
    mutating func run() throws {
        guard let operation = BrowserSessionRequest.Action(rawValue: action), operation != .save else {
            throw ValidationError("Use list, open, stop or delete. Import only through the Chrome extension.")
        }
        let result = try IPCClient.requestBrowserSession(.init(action: operation, id: id))
        guard result.success else { throw CommandFailure("Browser session: \(result.errorCode?.rawValue ?? "unavailable"). No Cookie values were returned.") }
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    }
}

struct BrowserNativeHostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browser-native-host", shouldDisplay: false)
    @Argument var origin: String
    mutating func run() throws {
        signal(SIGPIPE, SIG_IGN)
        var response: BrowserSessionResponse
        do {
            guard origin.range(of: #"^chrome-extension://[a-p]{32}/?$"#, options: .regularExpression) != nil,
                  isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else { throw BrowserSessionError.invalidImport }
            let bytes = try BrowserNativeMessaging.read(fd: STDIN_FILENO)
            let request = try JSONDecoder().decode(BrowserSessionRequest.self, from: bytes)
            guard request.action == .save else { throw BrowserSessionError.invalidImport }
            response = try IPCClient.requestBrowserSession(request, disconnectOnInputClose: true)
        } catch { response = .init(success: false, errorCode: error as? BrowserSessionError ?? .unavailable) }
        // Native framing only. Never print decoder errors or echo input on either stream.
        try? BrowserNativeMessaging.write(response, fd: STDOUT_FILENO)
    }
}
