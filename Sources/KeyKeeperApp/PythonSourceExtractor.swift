import Foundation
import Darwin
import Security
import KeyKeeperCore

enum PythonSourceExtractor {
    // Only this fixed helper is executed. The selected source is data on a private pipe.
    private static let helper = #"""
import ast, sys, resource
try:
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    source = sys.stdin.buffer.read(1048577)
    if len(source) > 1048576: raise ValueError()
    tree = ast.parse(source.decode('utf-8'), filename='<selected-source>', mode='exec')
    symbol = sys.argv[1]
    bindings = [n for n in ast.walk(tree) if isinstance(n, ast.Name) and n.id == symbol and isinstance(n.ctx, (ast.Store, ast.Del))]
    if len(bindings) != 1: raise ValueError()
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and n.name == symbol: raise ValueError()
        if isinstance(n, ast.alias) and (n.asname or n.name.split('.')[0]) == symbol: raise ValueError()
        if isinstance(n, ast.arg) and n.arg == symbol: raise ValueError()
        if isinstance(n, ast.ExceptHandler) and n.name == symbol: raise ValueError()
    matches = []
    for n in tree.body:
        target = n.targets[0] if isinstance(n, ast.Assign) and len(n.targets) == 1 else n.target if isinstance(n, ast.AnnAssign) else None
        if isinstance(target, ast.Name) and target.id == symbol: matches.append(n.value)
    if len(matches) != 1: raise ValueError()
    value = matches[0]
    if isinstance(value, ast.Call):
        def chain(node):
            if isinstance(node, ast.Name): return node.id
            if isinstance(node, ast.Attribute): return chain(node.value) + '.' + node.attr
            return ''
        if chain(value.func) not in ('os.getenv', 'os.environ.get') or len(value.args) != 2 or value.keywords: raise ValueError()
        if not isinstance(value.args[0], ast.Constant) or not isinstance(value.args[0].value, str): raise ValueError()
        value = value.args[1]
    if not isinstance(value, ast.Constant) or not isinstance(value.value, str): raise ValueError()
    output = value.value.encode('utf-8')
    if not value.value.strip() or '\x00' in value.value or len(output) > 65536: raise ValueError()
    sys.stdout.buffer.write(output)
except BaseException:
    sys.exit(2)
"""#

    static func extract(_ source: Data, symbol: String) throws -> String {
        guard !source.isEmpty, source.count <= SourceImportRequest.maximumBytes,
              SourceImportRequest.validSymbol(symbol), String(data: source, encoding: .utf8) != nil else {
            throw ClipboardSaveError.unsupportedSource
        }
        let locations = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                         "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        guard let executable = locations.map({ URL(fileURLWithPath: $0) }).first(where: appleSigned) else {
            throw ClipboardSaveError.sourceParserUnavailable
        }
        let bytes = try run(executable: executable, arguments: ["-I", "-S", "-c", helper, symbol], input: source)
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty, !value.contains("\0") else {
            throw ClipboardSaveError.unsupportedSource
        }
        return value
    }

    private static func appleSigned(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        var code: SecStaticCode?; var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Nonblocking, bounded private pipes. No source/value in argv, environment, files or logs.
    static func run(executable: URL, arguments: [String], input: Data, timeout: TimeInterval = 3) throws -> Data {
        let process = Process(), incoming = Pipe(), outgoing = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = incoming; process.standardOutput = outgoing; process.standardError = FileHandle.nullDevice
        let writer = incoming.fileHandleForWriting.fileDescriptor, reader = outgoing.fileHandleForReading.fileDescriptor
        guard fcntl(writer, F_SETFL, O_NONBLOCK) == 0, fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else {
            throw ClipboardSaveError.unsupportedSource
        }
        // A child exiting early must not SIGPIPE the App (or an XCTest host).
        _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        do { try process.run() } catch { throw ClipboardSaveError.sourceParserUnavailable }
        var writerClosed = false
        defer {
            if !writerClosed { try? incoming.fileHandleForWriting.close() }
            try? outgoing.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var offset = 0, output = Data(), eof = false
        while !eof || process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ClipboardSaveError.unsupportedSource }
            if !writerClosed {
                if offset == input.count { try? incoming.fileHandleForWriting.close(); writerClosed = true }
                else {
                    let written = input.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!.advanced(by: offset), min(8192, input.count - offset)) }
                    if written > 0 { offset += written }
                    else if written < 0 && ![EAGAIN, EINTR].contains(errno) { throw ClipboardSaveError.unsupportedSource }
                }
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let readCount = Darwin.read(reader, &buffer, buffer.count)
            if readCount > 0 {
                guard output.count + readCount <= 65_536 else { throw ClipboardSaveError.unsupportedSource }
                output.append(contentsOf: buffer.prefix(readCount))
            } else if readCount == 0 { eof = true }
            else if ![EAGAIN, EINTR].contains(errno) { throw ClipboardSaveError.unsupportedSource }
            if !eof || process.isRunning {
                var descriptors = [pollfd(fd: reader, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: writerClosed ? -1 : writer, events: Int16(POLLOUT), revents: 0)]
                _ = poll(&descriptors, 2, 10)
            }
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw ClipboardSaveError.unsupportedSource }
        return output
    }
}
