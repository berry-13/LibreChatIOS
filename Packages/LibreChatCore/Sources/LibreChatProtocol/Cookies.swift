import CryptoKit
import Foundation
import LibreChatDomain
import OSLog
#if canImport(Security)
import Security
#endif

private let cookiesLog = Logger(subsystem: "LibreChatProtocol", category: "cookies")

public protocol SecretStore: Sendable {
    func data(for key: String) async throws -> Data?
    func set(_ data: Data, for key: String) async throws
    func remove(_ key: String) async throws
}

public actor KeychainSecretStore: SecretStore {
    private let service: String

    public init(service: String = "com.librechat.ios.secrets") {
        self.service = service
    }

    public func data(for key: String) async throws -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LibreChatProtocolError.keychain(status) }
        return result as? Data
        #else
        return nil
        #endif
    }

    public func set(_ data: Data, for key: String) async throws {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw LibreChatProtocolError.keychain(updateStatus)
        }
        var insertion = base
        attributes.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw LibreChatProtocolError.keychain(addStatus) }
        #endif
    }

    public func remove(_ key: String) async throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LibreChatProtocolError.keychain(status)
        }
        #endif
    }
}

public struct StoredCookie: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expiresAt: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expiresAt: Date?,
        isSecure: Bool,
        isHTTPOnly: Bool
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }

    public init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expiresAt = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.properties?[HTTPCookiePropertyKey("HttpOnly")] != nil
    }
}

/// Keychain-first secret store. DEBUG builds additionally maintain a file
/// mirror inside the app container so sessions survive environments where
/// the Keychain is unavailable or wiped — unsigned development builds and
/// Simulator reinstalls. Release builds keep credentials Keychain-only, and
/// every mirror file is excluded from device backups so stored session
/// credentials can never ride a backup off the device.
public actor MirroredSecretStore: SecretStore {
    private let primary: any SecretStore
    private let directory: URL

    public init(
        primary: any SecretStore = KeychainSecretStore(),
        directory: URL? = nil
    ) {
        self.primary = primary
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LibreChatSessionStore", directoryHint: .isDirectory)
        self.directory = base
    }

    public func data(for key: String) async throws -> Data? {
        let primaryData: Data?
        do {
            primaryData = try await primary.data(for: key)
        } catch {
            #if DEBUG
            // A throwing primary (missing entitlement, revoked access) must
            // not hide the mirror — the mirror may be the only copy that
            // exists in exactly those environments.
            cookiesLog.error(
                "Session keychain read failed; falling back to file mirror: \(String(describing: error), privacy: .public)"
            )
            primaryData = nil
            #else
            // Production has no mirror: a Keychain read failure must surface
            // instead of masquerading as a missing credential, which callers
            // would treat as definitive absence — refreshing without the
            // cookie and ultimately clearing a still-valid saved session.
            throw error
            #endif
        }
        if let primaryData {
            return primaryData
        }
        #if DEBUG
        let url = fileURL(for: key)
        guard let mirrored = try? Data(contentsOf: url) else { return nil }
        try? await primary.set(mirrored, for: key)
        return mirrored
        #else
        return nil
        #endif
    }

    public func set(_ data: Data, for key: String) async throws {
        do {
            try await primary.set(data, for: key)
        } catch {
            #if DEBUG
            // The mirror is the durability guarantee in development: unsigned
            // or entitlement-less builds cannot use the Keychain at all, and
            // Simulator reinstalls can drop it. A primary failure must
            // therefore never abort the mirror write — and must never be
            // silent.
            cookiesLog.error(
                "Session keychain write failed; continuing with file mirror: \(String(describing: error), privacy: .public)"
            )
            #else
            // Production keeps credentials Keychain-only: a failing Keychain
            // write must surface instead of leaking session bytes to disk.
            throw error
            #endif
        }
        #if DEBUG
        do {
            try writeMirror(data, for: key)
        } catch {
            cookiesLog.error("Session mirror write failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        #endif
    }

    public func remove(_ key: String) async throws {
        #if DEBUG
        // Logout must always delete the mirror: if the primary removal throws
        // (entitlement-less builds) and we aborted here, the surviving mirror
        // would resurrect the session on the next read.
        do {
            try await primary.remove(key)
        } catch {
            cookiesLog.error(
                "Session keychain removal failed; continuing with mirror removal: \(String(describing: error), privacy: .public)"
            )
        }
        try? FileManager.default.removeItem(at: fileURL(for: key))
        #else
        try await primary.remove(key)
        #endif
    }

    #if DEBUG
    /// Opaque on-disk name; the raw key contains profile identifiers.
    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name)
    }

    private func writeMirror(_ data: Data, for key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackups(directory)
        let url = fileURL(for: key)
        do {
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            // The DEBUG-only mirror must also work on macOS and in test
            // hosts, where the OS can refuse the iOS protection class; a
            // plain atomic write keeps the recovery mirror alive there.
            try data.write(to: url, options: [.atomic])
        }
        Self.excludeFromBackups(url)
    }

    /// Mirrored credentials must never be captured by device backups: file
    /// protection guards a locked device, not the backup archive.
    private static func excludeFromBackups(_ url: URL) {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }
    #endif
}

public actor ProfileCookieJar {
    private let profileID: ServerProfileID
    private let baseURL: URL
    private let secretStore: any SecretStore
    private var cookies: [StoredCookie] = []
    private var restored = false

    public init(profileID: ServerProfileID, baseURL: URL, secretStore: any SecretStore = KeychainSecretStore()) {
        self.profileID = profileID
        self.baseURL = baseURL
        self.secretStore = secretStore
    }

    public func restore() async throws {
        guard !restored else { return }
        // The flag is set only after a definitive outcome. A transient
        // secret-store failure must keep restoration pending so the next
        // request retries instead of permanently missing the refresh cookie.
        guard let data = try await secretStore.data(for: storageKey) else {
            restored = true
            return
        }
        cookies = try JSONDecoder().decode([StoredCookie].self, from: data)
        removeExpired()
        restored = true
    }

    public func cookieHeader(for url: URL) async throws -> String? {
        // A transient secret-store failure propagates instead of degrading to
        // a cookie-less request: dispatching /api/auth/refresh without the
        // persisted refresh cookie would invalidate a recoverable session.
        try await restore()
        removeExpired()
        let eligible = cookies
            .filter { matches($0, url: url) }
            .sorted { $0.path.count > $1.path.count }
        if eligible.isEmpty {
            let storedCount = cookies.count
            // The raw path embeds conversation/message identifiers; only the
            // route class may be logged publicly.
            cookiesLog.notice(
                "Cookie header empty route=\(ProtocolRoute.classify(path: url.path).rawValue, privacy: .public) stored=\(storedCount, privacy: .public)"
            )
        }
        guard !eligible.isEmpty else { return nil }
        return eligible.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func absorb(responseHeaders: [String: String], for url: URL) async {
        try? await restore()
        // `URLSession` merges duplicate `Set-Cookie` headers into one
        // comma-joined string, and the comma inside `Expires` dates makes
        // `HTTPCookie.cookies(withResponseHeaderFields:)` drop every cookie
        // after the first. LibreChat rotates its refresh token through
        // `Set-Cookie` on every refresh, so losing it here signs the user out
        // on the next cold start. Split the merged header on cookie
        // boundaries only: a comma directly followed by `token=`, which never
        // matches the date form (`Wed, 21 Oct 2026 07:28:00 GMT; Path=/`)
        // because a `;` intervenes before the `=`.
        let cookieFields: [[String: String]] = responseHeaders
            .filter { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }
            .flatMap { (_, value) in Self.splitSetCookieValues(value) }
            .map { ["Set-Cookie": $0] }
        // `HTTPCookie` refuses to parse `Secure` cookies for non-HTTPS URLs.
        // LibreChat marks its auth cookies `Secure` even on plain-HTTP
        // deployments, and browsers exempt loopback origins from that rule
        // (they are secure contexts), so re-parse loopback responses as
        // HTTPS. Without this the refresh cookie is never stored and every
        // cold start after the access token expires signs the user out.
        let parseURL = Self.isSecureContextHost(url.host) ? Self.httpsVariant(of: url) : url
        let parsed = cookieFields
            .flatMap { HTTPCookie.cookies(withResponseHeaderFields: $0, for: parseURL) }
            .map(StoredCookie.init)
            .filter { domainMatches($0.domain, host: baseURL.host) }
        // Names only; values never enter logs.
        cookiesLog.notice(
            "Cookie absorb parsed=\(parsed.count, privacy: .public) names=\(parsed.map(\.name).joined(separator: ","), privacy: .public) rawFields=\(cookieFields.count, privacy: .public)"
        )
        guard !parsed.isEmpty else { return }
        for cookie in parsed {
            cookies.removeAll { existing in
                existing.name == cookie.name
                    && existing.domain.caseInsensitiveCompare(cookie.domain) == .orderedSame
                    && existing.path == cookie.path
            }
            if cookie.expiresAt.map({ $0 > Date() }) != false, !cookie.value.isEmpty {
                cookies.append(cookie)
            }
        }
        do {
            try await persist()
        } catch {
            cookiesLog.error(
                "Cookie persistence failed; the session will not survive a relaunch: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Splits a comma-joined `Set-Cookie` header value into individual cookie
    /// strings without breaking `Expires=Wed, 21 Oct ...` dates. A comma only
    /// starts a new cookie when a `token=` pair follows it directly; the date
    /// form (`Wed, 21 Oct 2026 07:28:00 GMT; Path=/`) never matches because
    /// a space, `;`, or `:` intervenes before any `=`.
    public static func splitSetCookieValues(_ merged: String) -> [String] {
        guard merged.contains(",") else { return [merged] }
        let pattern = ",(?=\\s*[^;,=\\s]+=)"
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex else { return [merged] }
        let ns = merged as NSString
        let range = NSRange(location: 0, length: ns.length)
        var parts: [String] = []
        var segmentStart = 0
        regex.enumerateMatches(in: merged, range: range) { match, _, _ in
            guard let match else { return }
            parts.append(ns.substring(with: NSRange(location: segmentStart, length: match.range.location - segmentStart)))
            segmentStart = match.range.location + match.range.length
        }
        parts.append(ns.substring(from: segmentStart))
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func replace(with cookies: [StoredCookie]) async throws {
        self.cookies = cookies.filter { domainMatches($0.domain, host: baseURL.host) }
        restored = true
        removeExpired()
        try await persist()
    }

    public func snapshot() async -> [StoredCookie] {
        try? await restore()
        removeExpired()
        return cookies
    }

    public func clear() async throws {
        cookies = []
        restored = true
        try await secretStore.remove(storageKey)
    }

    private var storageKey: String { "cookies.\(profileID.rawValue)" }

    private func persist() async throws {
        if cookies.isEmpty {
            try await secretStore.remove(storageKey)
        } else {
            try await secretStore.set(try JSONEncoder().encode(cookies), for: storageKey)
        }
    }

    private func removeExpired() {
        let now = Date()
        cookies.removeAll { $0.expiresAt.map { $0 <= now } == true }
    }

    private func matches(_ cookie: StoredCookie, url: URL) -> Bool {
        guard domainMatches(cookie.domain, host: url.host) else { return false }
        let isSecureContext = url.scheme?.lowercased() == "https"
            || Self.isSecureContextHost(url.host)
        if cookie.isSecure && !isSecureContext { return false }
        // RFC 6265 path-match: exact match, a cookie path ending in "/", or
        // a "/" boundary right after the prefix. Without the boundary a
        // cookie scoped to /api/auth would also leak to /api/authentication.
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath == requestPath || cookiePath.hasSuffix("/") { return true }
        let next = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return requestPath[next] == "/"
    }

    /// Browsers treat loopback origins as secure contexts: `Secure` cookies
    /// may be stored from and sent to `http://localhost`. LibreChat ships its
    /// auth cookies with the `Secure` attribute regardless of deployment
    /// scheme, so plain-HTTP (localhost/LAN development) setups depend on
    /// this exemption.
    static func isSecureContextHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".localhost")
    }

    private static func httpsVariant(of url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    private func domainMatches(_ domain: String, host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return host == domain || host.hasSuffix(".\(domain)")
    }
}
