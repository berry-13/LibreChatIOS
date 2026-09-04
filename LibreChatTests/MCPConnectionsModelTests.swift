import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class MCPConnectionsModelTests: XCTestCase {
    func testOfflineNeverLoadsOrRetainsConnectionMetadata() async {
        let repository = MCPRepositoryDouble(results: [])
        let model = MCPConnectionsModel(
            repository: repository,
            isOffline: { true },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .offline)
        XCTAssertNil(model.catalog)
        let calls = await repository.callCount
        XCTAssertEqual(calls, 0)
    }

    func testLoadsAndSearchesOnlySafePresentationFields() async {
        let catalog = MCPConnectionCatalog(connections: [
            connection(name: "files", title: "Files", description: "Search documents"),
            connection(name: "browser", title: "Web", description: "Browse approved sites")
        ])
        let repository = MCPRepositoryDouble(results: [.success(catalog)])
        let model = MCPConnectionsModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.visibleConnections.map(\.title), ["Files", "Web"])

        model.query = "approved"
        XCTAssertEqual(model.visibleConnections.map(\.title), ["Web"])
        model.query = "files"
        XCTAssertEqual(model.visibleConnections.map(\.title), ["Files"])
    }

    func testForbiddenRoleIsDistinctFromTransportFailure() async {
        let repository = MCPRepositoryDouble(results: [
            .failure(.httpStatus(403, message: "denied", retryAfter: nil))
        ])
        let model = MCPConnectionsModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .forbidden)
        XCTAssertNil(model.catalog)
    }

    func testUnauthorizedClearsPrivateStateAndExpiresSession() async {
        let first = MCPConnectionCatalog(connections: [
            connection(name: "private", title: "Private", description: "Internal")
        ])
        let repository = MCPRepositoryDouble(results: [
            .success(first),
            .failure(.unauthorized)
        ])
        var expired = false
        let model = MCPConnectionsModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: { expired = true }
        )

        await model.loadIfNeeded()
        XCTAssertNotNil(model.catalog)
        await model.reload()

        XCTAssertEqual(model.state, .unauthorized)
        XCTAssertNil(model.catalog)
        XCTAssertTrue(expired)
    }

    private func connection(
        name: String,
        title: String,
        description: String?
    ) -> MCPConnection {
        MCPConnection(
            name: MCPServerName(rawValue: name),
            title: title,
            description: description,
            transport: .streamableHTTP,
            source: .serverConfiguration,
            connectionState: .connected,
            authorizationState: .notRequired
        )
    }
}

private actor MCPRepositoryDouble: MCPRepository {
    private var results: [Result<MCPConnectionCatalog, LibreChatProtocolError>]
    private(set) var callCount = 0

    init(results: [Result<MCPConnectionCatalog, LibreChatProtocolError>]) {
        self.results = results
    }

    func mcpConnections() async throws -> MCPConnectionCatalog {
        callCount += 1
        guard !results.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try results.removeFirst().get()
    }
}
