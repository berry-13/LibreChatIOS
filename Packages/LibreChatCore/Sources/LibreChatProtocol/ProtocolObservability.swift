import Foundation

/// A bounded route vocabulary for diagnostics. The raw request path is never
/// exposed because it can contain account, conversation, message, or file IDs.
public enum ProtocolRoute: String, Codable, Equatable, Sendable {
    case health
    case configuration
    case authenticationLogin = "auth-login"
    case authenticationRefresh = "auth-refresh"
    case authenticationLogout = "auth-logout"
    case authenticationTwoFactor = "auth-2fa"
    case authenticationMobile = "auth-mobile"
    case accountAccess = "account-access"
    case terms
    case conversations
    case messages
    case agents
    case generation
    case files
    case search
    case projects
    case sharing
    case tags
    case roles
    case models
    case endpoints
    case other

    private static let knownAPIRoots: Set<String> = [
        "config", "auth", "user", "convos", "messages", "agents", "files",
        "search", "projects", "share", "tags", "roles", "models", "endpoints"
    ]

    /// Classifies a URL path without retaining or returning any path component.
    public static func classify(path: String) -> ProtocolRoute {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }

        guard !components.isEmpty else { return .other }
        if components.last == "health" { return .health }
        guard let apiIndex = components.indices.first(where: { index in
            components[index] == "api"
                && components.indices.contains(index + 1)
                && Self.knownAPIRoots.contains(components[index + 1])
        }) else { return .other }
        let route = Array(components[apiIndex...])
        guard route.count >= 2 else { return .other }

        switch route[1] {
        case "config":
            return .configuration
        case "auth":
            guard route.count >= 3 else { return .other }
            switch route[2] {
            case "login": return .authenticationLogin
            case "refresh": return .authenticationRefresh
            case "logout": return .authenticationLogout
            case "2fa": return .authenticationTwoFactor
            case "mobile": return .authenticationMobile
            case "register", "requestpasswordreset", "resetpassword": return .accountAccess
            default: return .other
            }
        case "user":
            guard route.count >= 3 else { return .accountAccess }
            switch route[2] {
            case "verify", "delete": return .accountAccess
            case "terms": return .terms
            default: return .other
            }
        case "convos": return .conversations
        case "messages": return .messages
        case "agents":
            return route.count >= 3 && route[2] == "chat" ? .generation : .agents
        case "files": return .files
        case "search": return .search
        case "projects": return .projects
        case "share": return .sharing
        case "tags": return .tags
        case "roles": return .roles
        case "models": return .models
        case "endpoints": return .endpoints
        default: return .other
        }
    }
}

public enum ProtocolTransportFailure: String, Codable, Equatable, Sendable {
    case cancelled
    case connectivity
    case invalidResponse = "invalid-response"
    case protocolFailure = "protocol-failure"
}

public enum AuthenticationLoginOutcome: String, Codable, Equatable, Sendable {
    case authenticated
    case requiresTwoFactor = "requires-2fa"
    case rejected
}

public enum CredentialRevisionReason: String, Codable, Equatable, Sendable {
    case authenticated
    case refreshed
    case cleared
}

public enum AuthorizationRecoveryOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
}

public enum ProtocolObservationEvent: Equatable, Sendable {
    case transportStarted(route: ProtocolRoute, method: HTTPMethod, attempt: Int)
    case transportResponded(route: ProtocolRoute, method: HTTPMethod, status: Int, attempt: Int)
    case transportFailed(
        route: ProtocolRoute,
        method: HTTPMethod,
        attempt: Int,
        failure: ProtocolTransportFailure
    )
    case transportRetryScheduled(route: ProtocolRoute, method: HTTPMethod, nextAttempt: Int)
    case eventStreamOpened(route: ProtocolRoute, status: Int)
    case authenticationLoginStarted
    case authenticationLoginCompleted(outcome: AuthenticationLoginOutcome)
    case authenticationRefreshRequested
    case authenticationRefreshCoalesced
    case authenticationRefreshSucceeded
    case authenticationRefreshFailed
    case authenticationCredentialRevisionChanged(reason: CredentialRevisionReason, revision: UInt64)
    case authorizationRecoveryStarted(route: ProtocolRoute, method: HTTPMethod)
    case authorizationRecoveryCompleted(
        route: ProtocolRoute,
        method: HTTPMethod,
        outcome: AuthorizationRecoveryOutcome
    )
}

/// A synchronous, `Sendable` observation hook. Live builds bridge this to
/// privacy-safe OSLog categories; tests can record the finite event vocabulary.
public struct ProtocolObservability: Sendable {
    private let handler: @Sendable (ProtocolObservationEvent) -> Void

    public init(_ handler: @escaping @Sendable (ProtocolObservationEvent) -> Void) {
        self.handler = handler
    }

    public func record(_ event: ProtocolObservationEvent) {
        handler(event)
    }

    public static let disabled = ProtocolObservability { _ in }
}
