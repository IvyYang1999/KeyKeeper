import Foundation

/// Secret-bearing transport, only extension → native host → App. Never a reply or log object.
public struct BrowserSessionImport: Codable, Sendable, Equatable {
    public var id: String
    public var origin: String
    public var label: String
    public var cookies: [BrowserSessionCookie]
    public static let maximumBytes = 131_072

    public init(id: String, origin: String, label: String, cookies: [BrowserSessionCookie]) {
        self.id = id; self.origin = origin; self.label = label; self.cookies = cookies
    }

    public static func canonicalOrigin(_ text: String) throws -> String {
        guard let parts = URLComponents(string: text), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty, let host = parts.host, validHost(host),
              parts.port.map({ (1...65535).contains($0) && $0 != 443 }) ?? true else {
            throw BrowserSessionError.invalidImport
        }
        let expected = "https://" + host + (parts.port.map { ":\($0)" } ?? "")
        guard text == expected else { throw BrowserSessionError.invalidImport }
        return expected
    }

    /// What someone types, turned into the exact form `canonicalOrigin` accepts.
    ///
    /// Typing `https://www.example.com/` and being told "no paths allowed" is not a useful
    /// conversation: that trailing slash is not a path to anyone but a parser. The canonical form
    /// stays strict — it is what gets stored and matched against — but the input does not have to
    /// be typed in it.
    public static func normalizeOrigin(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { return nil }
        // An http address here is a typo, not a request to drop TLS: sessions are https only.
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        guard let normalized = parts.string, (try? canonicalOrigin(normalized)) != nil else { return nil }
        return normalized
    }

    /// A name nobody should have to invent. The site is the name until someone says otherwise.
    public static func suggestedLabel(forOrigin origin: String) -> String? {
        guard let normalized = normalizeOrigin(origin), let host = URLComponents(string: normalized)?.host
        else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public func validate(now: Date = Date(), requireUnexpired: Bool = true) throws {
        let canonical = try Self.canonicalOrigin(origin)
        guard UUID(uuidString: id) != nil, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 160, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (1...64).contains(cookies.count),
              try JSONEncoder().encode(self).count <= Self.maximumBytes else { throw BrowserSessionError.invalidImport }
        let host = URLComponents(string: canonical)!.host!
        var names = Set<String>()
        for cookie in cookies {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard Self.validHost(domain), domain == host || (!cookie.hostOnly && host.hasSuffix("." + domain)),
                  !cookie.hostOnly || !cookie.domain.hasPrefix("."), cookie.path == "/",
                  !cookie.name.isEmpty, cookie.name.utf8.count <= 256,
                  cookie.name.utf8.allSatisfy({ (33...126).contains($0) && !Array("()<>@,;:\\\"/[]?={} ".utf8).contains($0) }),
                  cookie.value.utf8.count <= 4096,
                  cookie.value.utf8.allSatisfy({ $0 == 33 || (35...43).contains($0) || (45...58).contains($0) || (60...91).contains($0) || (93...126).contains($0) }),
                  ["lax", "strict", "no_restriction", "unspecified"].contains(cookie.sameSite),
                  cookie.sameSite != "no_restriction" || cookie.secure,
                  names.insert(cookie.name).inserted else { throw BrowserSessionError.invalidImport }
            if cookie.name.hasPrefix("__Secure-") || cookie.name.hasPrefix("__Host-") {
                guard cookie.secure else { throw BrowserSessionError.invalidImport }
            }
            if cookie.name.hasPrefix("__Host-") {
                guard cookie.hostOnly else { throw BrowserSessionError.invalidImport }
            }
            if let expiry = cookie.expirationDate {
                guard expiry.isFinite, expiry > 0 else { throw BrowserSessionError.invalidImport }
                if requireUnexpired && expiry <= now.timeIntervalSince1970 { throw BrowserSessionError.expired }
            }
        }
    }

    private static func validHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253, host == host.lowercased() else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

public struct BrowserSessionCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var hostOnly: Bool
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: String
    public var expirationDate: Double?
    public init(name: String, value: String, domain: String, hostOnly: Bool, path: String,
                secure: Bool, httpOnly: Bool, sameSite: String, expirationDate: Double?) {
        self.name = name; self.value = value; self.domain = domain; self.hostOnly = hostOnly
        self.path = path; self.secure = secure; self.httpOnly = httpOnly
        self.sameSite = sameSite; self.expirationDate = expirationDate
    }
}

/// The only data returned to an Agent. No Cookie names, values or raw snapshot.
public struct BrowserSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let origin: String
    public let label: String
    public let cookieCount: Int
    public let createdAt: Date
    public init(snapshot: BrowserSessionImport, createdAt: Date) {
        id = snapshot.id; origin = snapshot.origin; label = snapshot.label
        cookieCount = snapshot.cookies.count; self.createdAt = createdAt
    }
}

public enum BrowserSessionError: String, Error, Codable, Sendable {
    case invalidImport, unavailable, conflict, notFound, expired, capacity, denied, busy, disconnected, unsupported
}
