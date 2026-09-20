import Foundation

/// Intentionally small HTTP/1 request surface. No keepalive, chunking, CORS or pipelining.
enum BrowserImportHTTP {
    struct Request { let method: String; let path: String; let body: Data }
    enum Rejected: Error { case invalid }
    static let maximumBytes = 8192 + 65536

    static func parse(_ data: Data, host: String, ticket: String) throws -> Request? {
        guard data.count <= maximumBytes else { throw Rejected.invalid }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw Rejected.invalid }
            return nil
        }
        guard boundary.upperBound <= 8192,
              let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { throw Rejected.invalid }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].components(separatedBy: " ")
        guard start.count == 3, start[2] == "HTTP/1.1" else { throw Rejected.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Rejected.invalid }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  headers[name] == nil else { throw Rejected.invalid }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == host, headers["transfer-encoding"] == nil,
              headers["expect"] == nil else { throw Rejected.invalid }
        let body = Data(data[boundary.upperBound...])
        if start[0] == "GET", start[1] == "/" {
            guard body.isEmpty, headers["content-length"] == nil || headers["content-length"] == "0",
                  headers["sec-fetch-site"] != "cross-site" else { throw Rejected.invalid }
            return Request(method: "GET", path: "/", body: Data())
        }
        let authenticated = headers["origin"] == "http://\(host)" && headers["x-keykeeper-session"] == ticket
        guard start[0] == "POST", ["/import", "/cancel", "/status"].contains(start[1]), authenticated,
              headers["content-type"]?.lowercased().hasPrefix("text/plain") == true,
              let rawLength = headers["content-length"], !rawLength.isEmpty,
              rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength), length > 0, length <= 65536, body.count <= length else {
            throw Rejected.invalid
        }
        guard body.count == length else { return nil }
        if start[1] == "/status", body != Data("status".utf8) { throw Rejected.invalid }
        return Request(method: "POST", path: start[1], body: body)
    }
}
