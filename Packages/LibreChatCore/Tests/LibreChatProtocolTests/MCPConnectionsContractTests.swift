import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct MCPConnectionsContractTests {
    @Test func listAndStatusMapOnlySafePresentationMetadata() throws {
        let servers = try JSONDecoder().decode(
            LibreChatMCPServersDTO.self,
            from: Data(
                #"{"research":{"title":"  Research  ","description":"  Search approved sources  ","type":"streamable-http","source":"yaml","requiresOAuth":true,"url":"https://internal.example/mcp","oauth":{"client_secret":"never"},"headers":{"Authorization":"never"},"future":{"x":1}},"agent-only":{"type":"stdio","source":"plugin","consumeOnly":true,"inspectionFailed":true}," bad ":{"title":"Dropped"}}"#.utf8
            )
        )
        let statuses = try JSONDecoder().decode(
            LibreChatMCPConnectionStatusesDTO.self,
            from: Data(
                #"{"success":true,"connectionStatus":{"research":{"connectionState":"connected","requiresOAuth":true,"authorizationState":"authorized","error":"not exposed"},"agent-only":{"connectionState":"error","requiresOAuth":false,"authorizationState":"not_required"},"foreign":{"connectionState":"connected"}},"oauthTimeout":120000,"future":true}"#.utf8
            )
        )

        let catalog = try LibreChatMCPMapper.catalog(
            servers: servers,
            statuses: statuses,
            fetchedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(catalog.connections.map(\.name.rawValue) == ["agent-only", "research"])
        let research = try #require(catalog.connections.last)
        #expect(research.title == "Research")
        #expect(research.description == "Search approved sources")
        #expect(research.transport == .streamableHTTP)
        #expect(research.source == .serverConfiguration)
        #expect(research.connectionState == .connected)
        #expect(research.authorizationState == .authorized)
        #expect(research.requiresOAuth)
        #expect(!research.isAgentOnly)

        let agentOnly = try #require(catalog.connections.first)
        #expect(agentOnly.transport == .localProcess)
        #expect(agentOnly.source == .organization)
        #expect(agentOnly.connectionState == .error)
        #expect(agentOnly.authorizationState == .notRequired)
        #expect(agentOnly.isAgentOnly)
        #expect(agentOnly.inspectionFailed)
    }

    @Test func unknownEvolvingStatesRemainVisibleWithoutBecomingAuthorized() throws {
        let servers = LibreChatMCPServersDTO(servers: [
            "future": LibreChatMCPServerDTO(
                title: "Future",
                type: "quantum",
                source: "future-source",
                requiresOAuth: true
            )
        ])
        let statuses = LibreChatMCPConnectionStatusesDTO(
            success: true,
            connectionStatus: [
                "future": LibreChatMCPConnectionStatusDTO(
                    connectionState: "future-state",
                    authorizationState: "future-auth"
                )
            ]
        )

        let connection = try #require(
            LibreChatMCPMapper.catalog(servers: servers, statuses: statuses).connections.first
        )
        #expect(connection.transport == .unknown("quantum"))
        #expect(connection.source == .unknown("future-source"))
        #expect(connection.connectionState == .unknown("future-state"))
        #expect(connection.authorizationState == .unknown("future-auth"))
        #expect(connection.requiresOAuth)
    }

    @Test func statusEnvelopeMustBeAuthoritativelySuccessful() {
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            try LibreChatMCPMapper.catalog(
                servers: LibreChatMCPServersDTO(),
                statuses: LibreChatMCPConnectionStatusesDTO(success: false)
            )
        }
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            try LibreChatMCPMapper.catalog(
                servers: LibreChatMCPServersDTO(),
                statuses: LibreChatMCPConnectionStatusesDTO(success: nil)
            )
        }
    }

    @Test func factoriesUseExactBearerReadOnlyRoutes() {
        let servers = LibreChatMCPAPI.servers()
        #expect(servers.method == .get)
        #expect(servers.path == "api/mcp/servers")
        #expect(servers.authorization == .bearer)
        #expect(servers.retryPolicy == .idempotent(maximumAttempts: 2))

        let status = LibreChatMCPAPI.connectionStatuses()
        #expect(status.method == .get)
        #expect(status.path == "api/mcp/connection/status")
        #expect(status.authorization == .bearer)
        #expect(status.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func rolePermissionRequiresExplicitUseAndPreservesOtherBits() throws {
        let role = try JSONDecoder().decode(
            LibreChatRoleDTO.self,
            from: Data(
                #"{"permissions":{"MCP_SERVERS":{"USE":true,"CREATE":false,"SHARE":true,"SHARE_PUBLIC":false,"CONFIGURE_OBO":true}}}"#.utf8
            )
        )
        let permissions = role.mcpPermissions
        #expect(permissions.use)
        #expect(!permissions.create)
        #expect(permissions.share)
        #expect(!permissions.sharePublicly)
        #expect(permissions.configureOnBehalfOf)

        let mapped = LibreChatRoleCapabilityMapper.applying(
            role,
            to: ServerCapabilities(supportsMCP: true)
        )
        #expect(mapped.mcpPermissions == permissions)

        let missing = try JSONDecoder().decode(
            LibreChatRoleDTO.self,
            from: Data(#"{"permissions":{}}"#.utf8)
        )
        #expect(missing.mcpPermissions == MCPPermissions())
    }
}
