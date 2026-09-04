import Foundation
import LibreChatDomain

public struct LibreChatMCPServerDTO: Decodable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var type: String?
    public var source: String?
    public var consumeOnly: Bool?
    public var requiresOAuth: Bool?
    public var inspectionFailed: Bool?

    public init(
        title: String? = nil,
        description: String? = nil,
        type: String? = nil,
        source: String? = nil,
        consumeOnly: Bool? = nil,
        requiresOAuth: Bool? = nil,
        inspectionFailed: Bool? = nil
    ) {
        self.title = title
        self.description = description
        self.type = type
        self.source = source
        self.consumeOnly = consumeOnly
        self.requiresOAuth = requiresOAuth
        self.inspectionFailed = inspectionFailed
    }
}

/// `/api/mcp/servers` is a top-level dictionary keyed by the server's stable
/// configuration name rather than a conventional list envelope.
public struct LibreChatMCPServersDTO: Decodable, Equatable, Sendable {
    public var servers: [String: LibreChatMCPServerDTO]

    public init(servers: [String: LibreChatMCPServerDTO] = [:]) {
        self.servers = servers
    }

    public init(from decoder: Decoder) throws {
        servers = try decoder.singleValueContainer().decode([String: LibreChatMCPServerDTO].self)
    }
}

public struct LibreChatMCPConnectionStatusDTO: Decodable, Equatable, Sendable {
    public var requiresOAuth: Bool?
    public var connectionState: String?
    public var authorizationState: String?

    public init(
        requiresOAuth: Bool? = nil,
        connectionState: String? = nil,
        authorizationState: String? = nil
    ) {
        self.requiresOAuth = requiresOAuth
        self.connectionState = connectionState
        self.authorizationState = authorizationState
    }
}

public struct LibreChatMCPConnectionStatusesDTO: Decodable, Equatable, Sendable {
    public var success: Bool?
    public var connectionStatus: [String: LibreChatMCPConnectionStatusDTO]

    public init(
        success: Bool? = nil,
        connectionStatus: [String: LibreChatMCPConnectionStatusDTO] = [:]
    ) {
        self.success = success
        self.connectionStatus = connectionStatus
    }
}

public enum LibreChatMCPMapper {
    public static func catalog(
        servers: LibreChatMCPServersDTO,
        statuses: LibreChatMCPConnectionStatusesDTO,
        fetchedAt: Date = Date()
    ) throws -> MCPConnectionCatalog {
        guard statuses.success == true else {
            throw LibreChatProtocolError.invalidResponse
        }

        let connections = servers.servers.compactMap { rawName, server -> MCPConnection? in
            let name = MCPServerName(rawValue: rawName)
            guard name.isValidDisplayIdentity else { return nil }

            let status = statuses.connectionStatus[rawName]
            let title = normalized(server.title, limit: 200) ?? rawName
            return MCPConnection(
                name: name,
                title: title,
                description: normalized(server.description, limit: 4_000),
                transport: transport(server.type),
                source: source(server.source),
                isAgentOnly: server.consumeOnly == true,
                requiresOAuth: status?.requiresOAuth ?? server.requiresOAuth == true,
                connectionState: connectionState(status?.connectionState),
                authorizationState: authorizationState(status?.authorizationState),
                inspectionFailed: server.inspectionFailed == true
            )
        }.sorted {
            let lhs = $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rhs = $1.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return lhs == rhs ? $0.name.rawValue < $1.name.rawValue : lhs < rhs
        }

        return MCPConnectionCatalog(connections: connections, fetchedAt: fetchedAt)
    }

    private static func normalized(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf16.count <= limit else { return nil }
        return trimmed
    }

    private static func transport(_ value: String?) -> MCPTransportKind {
        switch value?.lowercased() {
        case "streamable-http", "http": .streamableHTTP
        case "sse": .serverSentEvents
        case "websocket": .webSocket
        case "stdio": .localProcess
        case let value?: .unknown(value)
        case nil: .unknown("")
        }
    }

    private static func source(_ value: String?) -> MCPServerSource {
        switch value?.lowercased() {
        case "yaml", "config": .serverConfiguration
        case "plugin": .organization
        case "user": .user
        case let value?: .unknown(value)
        case nil: .unknown("")
        }
    }

    private static func connectionState(_ value: String?) -> MCPConnectionState {
        switch value?.lowercased() {
        case "disconnected": .disconnected
        case "connecting": .connecting
        case "connected": .connected
        case "error": .error
        case let value: .unknown(value)
        }
    }

    private static func authorizationState(_ value: String?) -> MCPAuthorizationState {
        switch value?.lowercased() {
        case "not_required": .notRequired
        case "authorizing": .authorizing
        case "authorized": .authorized
        case "needs_authorization": .needsAuthorization
        case "error": .error
        case let value: .unknown(value)
        }
    }
}

public enum LibreChatMCPAPI {
    public static func servers() -> APIRequest<LibreChatMCPServersDTO> {
        APIRequest(
            method: .get,
            path: "api/mcp/servers",
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func connectionStatuses() -> APIRequest<LibreChatMCPConnectionStatusesDTO> {
        APIRequest(
            method: .get,
            path: "api/mcp/connection/status",
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }
}
