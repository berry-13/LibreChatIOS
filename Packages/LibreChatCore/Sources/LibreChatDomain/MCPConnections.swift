import Foundation

public struct MCPPermissions: Codable, Equatable, Sendable {
    public var use: Bool
    public var create: Bool
    public var share: Bool
    public var sharePublicly: Bool
    public var configureOnBehalfOf: Bool

    public init(
        use: Bool = false,
        create: Bool = false,
        share: Bool = false,
        sharePublicly: Bool = false,
        configureOnBehalfOf: Bool = false
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
        self.configureOnBehalfOf = configureOnBehalfOf
    }
}

public struct MCPServerName: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isValidDisplayIdentity: Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == rawValue
            && !rawValue.isEmpty
            && rawValue.utf16.count <= 512
            && rawValue.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

public enum MCPTransportKind: Codable, Equatable, Sendable {
    case streamableHTTP
    case serverSentEvents
    case webSocket
    case localProcess
    case unknown(String)

    public var displayName: String {
        switch self {
        case .streamableHTTP: "Streamable HTTP"
        case .serverSentEvents: "Server-sent events"
        case .webSocket: "WebSocket"
        case .localProcess: "Server-hosted process"
        case .unknown: "Other"
        }
    }
}

public enum MCPServerSource: Codable, Equatable, Sendable {
    case serverConfiguration
    case organization
    case user
    case unknown(String)

    public var displayName: String {
        switch self {
        case .serverConfiguration: "Server managed"
        case .organization: "Organization managed"
        case .user: "User managed"
        case .unknown: "Managed by LibreChat"
        }
    }
}

public enum MCPConnectionState: Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error
    case unknown(String?)

    public var displayName: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .error: "Connection issue"
        case .unknown: "Status unavailable"
        }
    }
}

public enum MCPAuthorizationState: Codable, Equatable, Sendable {
    case notRequired
    case authorizing
    case authorized
    case needsAuthorization
    case error
    case unknown(String?)

    public var displayName: String {
        switch self {
        case .notRequired: "No sign-in required"
        case .authorizing: "Sign-in in progress"
        case .authorized: "Authorized"
        case .needsAuthorization: "Sign-in required"
        case .error: "Authorization issue"
        case .unknown: "Authorization unknown"
        }
    }
}

public struct MCPConnection: Identifiable, Codable, Equatable, Sendable {
    public var id: MCPServerName { name }

    public let name: MCPServerName
    public var title: String
    public var description: String?
    public var transport: MCPTransportKind
    public var source: MCPServerSource
    public var isAgentOnly: Bool
    public var requiresOAuth: Bool
    public var connectionState: MCPConnectionState
    public var authorizationState: MCPAuthorizationState
    public var inspectionFailed: Bool

    public init(
        name: MCPServerName,
        title: String,
        description: String? = nil,
        transport: MCPTransportKind,
        source: MCPServerSource,
        isAgentOnly: Bool = false,
        requiresOAuth: Bool = false,
        connectionState: MCPConnectionState = .unknown(nil),
        authorizationState: MCPAuthorizationState = .unknown(nil),
        inspectionFailed: Bool = false
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.transport = transport
        self.source = source
        self.isAgentOnly = isAgentOnly
        self.requiresOAuth = requiresOAuth
        self.connectionState = connectionState
        self.authorizationState = authorizationState
        self.inspectionFailed = inspectionFailed
    }
}

public struct MCPConnectionCatalog: Codable, Equatable, Sendable {
    public var connections: [MCPConnection]
    public var fetchedAt: Date

    public init(connections: [MCPConnection], fetchedAt: Date = Date()) {
        self.connections = connections
        self.fetchedAt = fetchedAt
    }
}
