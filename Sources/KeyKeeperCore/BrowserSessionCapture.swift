import Foundation

/// One cookie as a browser engine hands it over. Deliberately not `HTTPCookie`: this layer is
/// about which cookies are worth keeping, and that question is testable without a web view.
public struct CapturedCookie: Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: String
    public var expiresAt: Double?

    public init(name: String, value: String, domain: String, path: String,
                secure: Bool, httpOnly: Bool, sameSite: String, expiresAt: Double?) {
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite
        self.expiresAt = expiresAt
    }
}

/// Turning a login performed inside KeyKeeper's own isolated window into a snapshot.
///
/// The Chrome extension is not the only way to get a website session: you can also just log in
/// here, in a window that starts empty and keeps nothing of its own. That path needs no
/// extension at all, and the session it produces is independent — logging out in Chrome does
/// not invalidate it, and it does not touch your browser's login.
///
/// Both paths end in the same `BrowserSessionImport` and go through the same validation, so a
/// snapshot made here is not a second-class citizen with its own rules.
public enum BrowserSessionCapture {
    /// The same ceiling the extension enforces, so neither path can produce something the other
    /// would refuse.
    public static let maximumCookies = 64

    public static func snapshot(origin: String, label: String, cookies: [CapturedCookie],
                                now: Date = Date(), id: String = UUID().uuidString) throws -> BrowserSessionImport {
        let canonical = try BrowserSessionImport.canonicalOrigin(origin)
        guard let host = URLComponents(string: canonical)?.host else { throw BrowserSessionError.invalidImport }

        var seen = Set<String>()
        let kept = cookies.compactMap { cookie -> BrowserSessionCookie? in
            // Root path only: a cookie scoped to /admin is not the session, and the playback
            // window would have to guess where to put it back.
            guard cookie.path == "/" else { return nil }
            let bare = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard bare == host || host.hasSuffix("." + bare) else { return nil }
            // Already dead by the time we save it: keeping it makes a snapshot that looks usable
            // and is not.
            if let expiresAt = cookie.expiresAt, expiresAt <= now.timeIntervalSince1970 { return nil }
            guard seen.insert(cookie.name).inserted else { return nil }
            return BrowserSessionCookie(
                name: cookie.name, value: cookie.value, domain: cookie.domain,
                hostOnly: !cookie.domain.hasPrefix("."), path: "/",
                secure: cookie.secure, httpOnly: cookie.httpOnly,
                sameSite: cookie.sameSite, expirationDate: cookie.expiresAt)
        }
        guard !kept.isEmpty else { throw BrowserSessionError.invalidImport }

        let snapshot = BrowserSessionImport(
            id: id, origin: canonical,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            cookies: Array(kept.prefix(maximumCookies)))
        try snapshot.validate(now: now)
        return snapshot
    }
}
