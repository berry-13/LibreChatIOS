import Foundation
import LibreChatDomain

struct ServerAddress: Equatable, Sendable {
    let url: URL

    var displayName: String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    static func parse(_ input: String) throws -> ServerAddress {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerAddressError.empty
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ServerAddressError.invalid
        }

        guard scheme == "https" || scheme == "http" else {
            throw ServerAddressError.unsupportedScheme
        }

        let localHosts = ["localhost", "127.0.0.1", "::1"]
        if scheme == "http" && !localHosts.contains(host) {
            throw ServerAddressError.insecureRemoteHost
        }

        guard components.user == nil, components.password == nil else {
            throw ServerAddressError.credentialsNotAllowed
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path == "/" ? "" : path

        guard let normalizedURL = components.url else {
            throw ServerAddressError.invalid
        }
        return ServerAddress(url: normalizedURL)
    }

    func endpoint(_ path: String, queryItems: [URLQueryItem] = []) -> URL {
        var result = url
        for component in path.split(separator: "/") {
            result.append(path: String(component))
        }

        guard !queryItems.isEmpty,
              var components = URLComponents(url: result, resolvingAgainstBaseURL: false) else {
            return result
        }
        components.queryItems = queryItems
        return components.url ?? result
    }
}

enum ServerAddressError: LocalizedError, Equatable {
    case empty
    case invalid
    case unsupportedScheme
    case insecureRemoteHost
    case credentialsNotAllowed

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter your LibreChat server address."
        case .invalid:
            return "That server address is not valid."
        case .unsupportedScheme:
            return "Use an HTTPS server address."
        case .insecureRemoteHost:
            return "Remote LibreChat servers must use HTTPS. HTTP is allowed only for local development."
        case .credentialsNotAllowed:
            return "Do not include a username or password in the server address."
        }
    }
}

enum SharedLinkAddress {
    static func parse(_ input: String, serverBaseURL: URL) throws -> SharedLinkID {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SharedLinkAddressError.empty }

        if !trimmed.contains("://") {
            return try identifier(trimmed)
        }

        guard let url = URL(string: trimmed),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              sameOrigin(url, serverBaseURL) else {
            throw SharedLinkAddressError.wrongServer
        }
        let baseComponents = pathComponents(serverBaseURL)
        let linkComponents = pathComponents(url)
        guard linkComponents.count == baseComponents.count + 2,
              Array(linkComponents.prefix(baseComponents.count)) == baseComponents,
              linkComponents[baseComponents.count] == "share" else {
            throw SharedLinkAddressError.invalid
        }
        return try identifier(linkComponents[baseComponents.count + 1])
    }

    private static func identifier(_ value: String) throws -> SharedLinkID {
        let identifier = SharedLinkID(rawValue: value)
        guard identifier.isSafePathComponent else {
            throw SharedLinkAddressError.invalid
        }
        return identifier
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func pathComponents(_ url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }
}

enum SharedLinkAddressError: LocalizedError, Equatable {
    case empty
    case invalid
    case wrongServer

    var errorDescription: String? {
        switch self {
        case .empty:
            "Paste a LibreChat shared link or enter its share ID."
        case .invalid:
            "That is not a valid LibreChat shared link."
        case .wrongServer:
            "That link belongs to a different LibreChat server. Switch servers first."
        }
    }
}
