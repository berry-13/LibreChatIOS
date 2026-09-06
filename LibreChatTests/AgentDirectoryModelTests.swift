import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class AgentDirectoryModelTests: XCTestCase {
    func testManagementAvailabilityKeepsEditAndDeleteResourceBitsIndependent() {
        let deleteOnly = AgentManagementAvailability(
            hasRolePermission: true,
            rowCanEdit: false,
            resourcePermissions: AgentResourcePermissions(canDelete: true)
        )
        XCTAssertTrue(deleteOnly.showsMenu)
        XCTAssertFalse(deleteOnly.canEditOrDuplicate)
        XCTAssertTrue(deleteOnly.canDelete)

        let editOnly = AgentManagementAvailability(
            hasRolePermission: true,
            rowCanEdit: true,
            resourcePermissions: AgentResourcePermissions(canEdit: true)
        )
        XCTAssertTrue(editOnly.showsMenu)
        XCTAssertTrue(editOnly.canEditOrDuplicate)
        XCTAssertFalse(editOnly.canDelete)

        let missingRole = AgentManagementAvailability(
            hasRolePermission: false,
            rowCanEdit: true,
            resourcePermissions: AgentResourcePermissions(canDelete: true)
        )
        XCTAssertFalse(missingRole.showsMenu)
        XCTAssertFalse(missingRole.canEditOrDuplicate)
        XCTAssertFalse(missingRole.canDelete)
    }

    func testLoadsPaginatesAndDeduplicatesAgents() async {
        let repository = AgentRepositoryDouble(
            pages: [
                "root": ChatAgentPage(
                    agents: [summary("agent_a"), summary("agent_b")],
                    nextCursor: "next"
                ),
                "next": ChatAgentPage(
                    agents: [summary("agent_b"), summary("agent_c")],
                    nextCursor: nil
                )
            ]
        )
        let model = AgentDirectoryModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        XCTAssertEqual(model.agents.map(\.id.rawValue), ["agent_a", "agent_b"])
        await model.loadMoreIfNeeded(after: model.agents[1])
        XCTAssertEqual(model.agents.map(\.id.rawValue), ["agent_a", "agent_b", "agent_c"])
        XCTAssertNil(model.nextCursor)
        let requests = await repository.requests
        XCTAssertEqual(requests.map(\.cursor), [nil, "next"])
    }

    func testOfflineStateDoesNotDispatchAgentRequest() async {
        let repository = AgentRepositoryDouble(pages: [:])
        let model = AgentDirectoryModel(
            repository: repository,
            isOffline: { true },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .offline)
        let requests = await repository.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnauthorizedClearsRowsAndExpiresSession() async {
        let repository = AgentRepositoryDouble(
            pages: [:],
            listError: LibreChatProtocolError.unauthorized
        )
        var expired = false
        let model = AgentDirectoryModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: { expired = true }
        )

        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .unauthorized)
        XCTAssertTrue(model.agents.isEmpty)
        XCTAssertTrue(expired)
    }

    func testAgentStartResolutionNeverSilentlyChoosesAmbiguousSpec() {
        let agentID = AgentID(rawValue: "agent_a")
        let direct = option(id: "agent:agent_a", agentID: agentID.rawValue)
        let specA = option(id: "spec:a", agentID: agentID.rawValue)
        let specB = option(id: "spec:b", agentID: agentID.rawValue)

        XCTAssertEqual(
            AgentStartTargetResolver.resolve(agentID: agentID, options: [specA, direct, specB]),
            .available(direct)
        )
        XCTAssertEqual(
            AgentStartTargetResolver.resolve(agentID: agentID, options: [specA]),
            .available(specA)
        )
        XCTAssertEqual(
            AgentStartTargetResolver.resolve(agentID: agentID, options: [specA, specB]),
            .ambiguous
        )
        XCTAssertEqual(
            AgentStartTargetResolver.resolve(agentID: agentID, options: []),
            .unavailable
        )
    }

    func testBasicAgentChoiceAndDraftKeepOnlyReviewedSimpleModels() throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let catalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(),
            options: [
                ChatTargetOption(
                    id: "openai",
                    label: "GPT Safe",
                    target: ConversationTarget(endpoint: "openAI", model: "gpt-safe")
                ),
                ChatTargetOption(
                    id: "duplicate",
                    label: "Duplicate",
                    target: ConversationTarget(endpoint: "openAI", model: "gpt-safe")
                ),
                ChatTargetOption(
                    id: "agent",
                    label: "Saved agent",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent_a")
                ),
                ChatTargetOption(
                    id: "spec",
                    label: "Spec",
                    target: ConversationTarget(endpoint: "openAI", model: "gpt-safe", spec: "research")
                )
            ],
            agentDiscoveryStatus: .notSupported
        )

        let choices = BasicAgentCreationChoice.choices(from: catalog)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0].review, BasicAgentModelReview(provider: "openAI", model: "gpt-safe"))

        var draft = BasicAgentCreationDraft()
        draft.name = " Researcher "
        draft.description = " Evidence first "
        draft.instructions = "Use primary sources."
        draft.category = " Work "
        XCTAssertTrue(draft.canCreate)
        let request = draft.request(
            context: BasicAgentCreationContext(
                profileID: profileID,
                accountID: accountID,
                choices: choices
            ),
            choice: choices[0]
        )
        XCTAssertEqual(request.name, "Researcher")
        XCTAssertEqual(request.description, "Evidence first")
        XCTAssertEqual(request.instructions, "Use primary sources.")
        XCTAssertEqual(request.category, "Work")

        draft.name = "bad\nname"
        XCTAssertFalse(draft.canCreate)
        draft.name = "Researcher"
        draft.instructions = "bad\0secret"
        XCTAssertFalse(draft.canCreate)
    }

    func testConfirmedBasicAgentCreationReloadsDirectoryAndUnknownLocksUntilRefresh() async throws {
        let directory = AgentRepositoryDouble(
            pages: ["root": ChatAgentPage(agents: [summary("agent_a")])]
        )
        let creation = AgentCreationRepositoryDouble(
            outcomes: [
                .outcomeUnknown(.responseLostAfterDispatch),
                .confirmed(BasicAgentCreationResult(
                    agentID: AgentID(rawValue: "agent_new"),
                    resourceID: AgentResourceID(rawValue: "507f1f77bcf86cd799439011"),
                    name: "Researcher",
                    provider: "openAI",
                    model: "gpt-safe"
                ))
            ]
        )
        let model = AgentDirectoryModel(
            repository: directory,
            creationRepository: creation,
            isOffline: { false },
            creationEnabled: { true },
            onUnauthorized: {}
        )
        await model.loadIfNeeded()
        let request = Self.basicCreationRequest()

        let first = try await model.createBasicAgent(request)
        XCTAssertEqual(first, .outcomeUnknown(.responseLostAfterDispatch))
        XCTAssertTrue(model.creationRequiresRefresh)
        XCTAssertFalse(model.canCreateAgent)
        do {
            _ = try await model.createBasicAgent(request)
            XCTFail("Expected a refresh fence")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requestsBeforeRefresh = await creation.requestCount()
        XCTAssertEqual(requestsBeforeRefresh, 1)

        await model.reload()
        XCTAssertFalse(model.creationRequiresRefresh)
        let second = try await model.createBasicAgent(request)
        guard case .confirmed = second else { return XCTFail("Expected confirmation") }
        let creationRequestCount = await creation.requestCount()
        let directoryRequestCount = await directory.requests.count
        XCTAssertEqual(creationRequestCount, 2)
        XCTAssertGreaterThanOrEqual(directoryRequestCount, 3)
    }

    func testDisabledBasicAgentCreationDoesNotDispatch() async throws {
        let directory = AgentRepositoryDouble(
            pages: ["root": ChatAgentPage(agents: [])]
        )
        let creation = AgentCreationRepositoryDouble(outcomes: [])
        let model = AgentDirectoryModel(
            repository: directory,
            creationRepository: creation,
            isOffline: { false },
            creationEnabled: { false },
            onUnauthorized: {}
        )
        await model.loadIfNeeded()
        XCTAssertFalse(model.canCreateAgent)
        do {
            _ = try await model.createBasicAgent(Self.basicCreationRequest())
            XCTFail("Expected fail-closed capability gate")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let requestCount = await creation.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    private func summary(_ id: String) -> ChatAgentSummary {
        ChatAgentSummary(id: AgentID(rawValue: id), name: id)
    }

    private func option(id: String, agentID: String) -> ChatTargetOption {
        ChatTargetOption(
            id: id,
            label: id,
            target: ConversationTarget(endpoint: "agents", agentID: agentID)
        )
    }

    private static func basicCreationRequest() -> BasicAgentCreationRequest {
        BasicAgentCreationRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            name: "Researcher",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe")
        )
    }
}

@MainActor
final class AgentRepositoryTests: XCTestCase {
    override func tearDown() {
        AgentURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testListUsesBearerACLQueryAndMapsOpaqueCursor() async throws {
        AgentURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/agents")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [
                URLQueryItem(name: "requiredPermission", value: "1"),
                URLQueryItem(name: "limit", value: "25"),
                URLQueryItem(name: "search", value: "research"),
                URLQueryItem(name: "cursor", value: "before==")
            ])
            return (
                Self.response(request, status: 200),
                Data(#"{"data":[{"id":"agent_a","name":"A"},{"id":"agent_a","name":"Duplicate"},{"name":"Malformed"}],"has_more":true,"after":"after=="}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        let page = try await repository.agents(
            search: "research",
            cursor: "before==",
            limit: 25
        )

        XCTAssertEqual(page.agents.map(\.name), ["A"])
        XCTAssertEqual(page.nextCursor, "after==")
    }

    func testListFailsClosedWhenServerClaimsAnotherPageWithoutCursor() async throws {
        AgentURLProtocolStub.handler = { request in
            (Self.response(request, status: 200), Data(#"{"data":[],"has_more":true}"#.utf8))
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.agents(search: nil, cursor: nil, limit: 25)
            XCTFail("Expected invalid pagination metadata")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testBasicAgentCreationUsesFreshModelsOneSafePostAndStrict201() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/models"):
                return (Self.response(request, status: 200), Data(#"{"openAI":["gpt-safe"]}"#.utf8))
            case ("POST", "/api/agents"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                )
                XCTAssertEqual(Set(object.keys), [
                    "name", "description", "instructions", "provider", "model", "tools", "category"
                ])
                XCTAssertEqual(object["name"] as? String, "Researcher")
                XCTAssertEqual(object["provider"] as? String, "openAI")
                XCTAssertEqual(object["model"] as? String, "gpt-safe")
                XCTAssertEqual(object["tools"] as? [String], [])
                XCTAssertNil(object["actions"])
                XCTAssertNil(object["files"])
                XCTAssertNil(object["mcp"])
                XCTAssertNil(object["credentials"])
                return (
                    Self.response(request, status: 201),
                    Data(#"{"id":"agent_new","_id":"507f1f77bcf86cd799439011","name":"Researcher","provider":"openAI","model":"gpt-safe"}"#.utf8)
                )
            case ("GET", "/api/agents/agent_new/expanded"):
                // Creation now verifies the authored metadata through an owner
                // expanded read before reporting confirmation; the echo
                // includes the authored description.
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_new","name":"Researcher","description":"Find evidence","provider":"openAI","model":"gpt-safe"}"#.utf8)
                )
            case ("GET", "/api/agents"):
                // The confirmed outcome triggers a directory refresh.
                return (
                    Self.response(request, status: 200),
                    Data(#"{"data":[{"id":"agent_new","name":"Researcher"}],"has_more":false}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let outcome = try await repository.createBasicAgent(Self.basicCreationRequest())

        guard case let .confirmed(result) = outcome else {
            return XCTFail("Expected strict direct confirmation, got \(outcome)")
        }
        XCTAssertEqual(result.agentID, AgentID(rawValue: "agent_new"))
        XCTAssertEqual(scenario.count(method: "POST"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testAmbiguousBasicAgentCreationReadsDirectoryOnceAndNeverReposts() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/models"):
                return (Self.response(request, status: 200), Data(#"{"openAI":["gpt-safe"]}"#.utf8))
            case ("POST", "/api/agents"):
                return (Self.response(request, status: 503), Data(#"{"message":"uncertain"}"#.utf8))
            case ("GET", "/api/agents"):
                let components = try XCTUnwrap(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                )
                XCTAssertTrue(components.queryItems?.contains(
                    URLQueryItem(name: "search", value: "Researcher")
                ) == true)
                return (
                    Self.response(request, status: 200),
                    Data(#"{"data":[{"id":"agent_new","name":"Researcher"}],"has_more":false}"#.utf8)
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let outcome = try await repository.createBasicAgent(Self.basicCreationRequest())

        XCTAssertEqual(outcome, .outcomeUnknown(.responseLostAfterDispatch))
        XCTAssertEqual(scenario.count(method: "POST"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testBasicAgentCreation401NeverRefreshesAndReplaysThePost() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/models"):
                return (Self.response(request, status: 200), Data(#"{"openAI":["gpt-safe"]}"#.utf8))
            case ("POST", "/api/agents"):
                return (Self.response(request, status: 401), Data(#"{"message":"expired"}"#.utf8))
            case (_, "/api/auth/refresh"):
                XCTFail("A dispatched non-idempotent create must not be replayed after refresh")
                return (
                    Self.response(request, status: 200),
                    Data(#"{"token":"fresh","user":{"id":"account"}}"#.utf8)
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.createBasicAgent(Self.basicCreationRequest())
            XCTFail("Expected authorization failure")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }

        XCTAssertEqual(scenario.count(method: "POST"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 1)
    }

    func testDetailRejectsAResponseForAnotherAgent() async throws {
        AgentURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/agent_a")
            return (
                Self.response(request, status: 200),
                Data(#"{"id":"agent_b","name":"Wrong agent"}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.agent(id: AgentID(rawValue: "agent_a"))
            XCTFail("Expected exact identity rejection")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testMetadataPatchReconcilesOneAmbiguousRequestWithExpandedRead() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            let step = scenario.record(request)
            switch step {
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/agents/agent_a/expanded")
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_a","name":"Before","description":"Old","category":"work"}"#.utf8)
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(request.url?.path, "/api/agents/agent_a")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
                )
                XCTAssertEqual(object, [
                    "name": "After",
                    "description": "",
                    "category": "research"
                ])
                return (Self.response(request, status: 500), Data(#"{"error":"uncertain"}"#.utf8))
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/agents/agent_a/expanded")
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_a","name":"After","description":"","category":"research","version":3}"#.utf8)
                )
            default:
                XCTFail("Unexpected request \(step)")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.updateAgentMetadata(AgentMetadataUpdateInput(
            agentID: AgentID(rawValue: "agent_a"),
            name: "After",
            description: "",
            category: "research"
        ))

        XCTAssertEqual(result.name, "After")
        XCTAssertNil(result.description)
        XCTAssertEqual(result.category, "research")
        XCTAssertEqual(result.version, 3)
        XCTAssertEqual(scenario.count(method: "PATCH"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testDuplicateLostResponseIsOutcomeUnknownAndNeverReposted() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            if request.httpMethod == "GET" {
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_a","name":"Original"}"#.utf8)
                )
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/agents/agent_a/duplicate")
            throw URLError(.networkConnectionLost)
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.duplicateAgent(id: AgentID(rawValue: "agent_a"))
            XCTFail("Expected an outcome-unknown duplicate")
        } catch let error as AgentManagementError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        XCTAssertEqual(scenario.count(method: "POST"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 1)
    }

    func testDuplicateRequiresAConfirmedDifferentAgentIdentity() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            if request.httpMethod == "GET" {
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_a","name":"Original"}"#.utf8)
                )
            }
            return (
                Self.response(request, status: 201),
                Data(#"{"agent":{"id":"agent_copy","name":"Original copy","category":"work"},"actions":[]}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        let copy = try await repository.duplicateAgent(id: AgentID(rawValue: "agent_a"))

        XCTAssertEqual(copy.id, AgentID(rawValue: "agent_copy"))
        XCTAssertEqual(copy.name, "Original copy")
        XCTAssertFalse(copy.canEdit, "A 201 response does not prove the post-create EDIT ACL grant succeeded.")
        XCTAssertEqual(scenario.count(method: "POST"), 1)
    }

    func testDeleteUsesLiveEffectivePermissionAndExactAcknowledgement() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/agents/agent_a"):
                return (
                    Self.response(request, status: 200),
                    Data(#"{"_id":"507f1f77bcf86cd799439011","id":"agent_a","name":"Agent"}"#.utf8)
                )
            case ("GET", "/api/permissions/agent/507f1f77bcf86cd799439011/effective"):
                return (Self.response(request, status: 200), Data(#"{"permissionBits":7}"#.utf8))
            case ("DELETE", "/api/agents/agent_a"):
                return (Self.response(request, status: 200), Data(#"{"message":"Agent deleted"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        try await repository.deleteAgent(id: AgentID(rawValue: "agent_a"))

        XCTAssertEqual(scenario.count(method: "DELETE"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testAmbiguousDeleteAcceptsOnlyAuthoritativeNotFoundReconciliation() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            let step = scenario.record(request)
            switch step {
            case 1:
                return (
                    Self.response(request, status: 200),
                    Data(#"{"_id":"507f1f77bcf86cd799439011","id":"agent_a","name":"Agent"}"#.utf8)
                )
            case 2:
                return (Self.response(request, status: 200), Data(#"{"permissionBits":15}"#.utf8))
            case 3:
                XCTAssertEqual(request.httpMethod, "DELETE")
                return (Self.response(request, status: 500), Data(#"{"error":"uncertain"}"#.utf8))
            case 4:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/agents/agent_a")
                return (Self.response(request, status: 404), Data(#"{"error":"Agent not found"}"#.utf8))
            default:
                XCTFail("Unexpected request \(step)")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        try await repository.deleteAgent(id: AgentID(rawValue: "agent_a"))

        XCTAssertEqual(scenario.count(method: "DELETE"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 3)
    }

    func testDeleteWithoutExactDeleteBitNeverDispatchesMutation() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            if request.url?.path == "/api/agents/agent_a" {
                return (
                    Self.response(request, status: 200),
                    Data(#"{"_id":"507f1f77bcf86cd799439011","id":"agent_a","name":"Agent"}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/api/permissions/agent/507f1f77bcf86cd799439011/effective")
            return (Self.response(request, status: 200), Data(#"{"permissionBits":3}"#.utf8))
        }
        let repository = try await makeRepository()

        do {
            try await repository.deleteAgent(id: AgentID(rawValue: "agent_a"))
            XCTFail("Expected deletion to fail closed without DELETE")
        } catch let error as AgentManagementError {
            XCTAssertEqual(error, .insufficientPermission)
        }
        XCTAssertEqual(scenario.count(method: "DELETE"), 0)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testDeleteWithoutMongoResourceIdentityNeverChecksACLOrDispatchesMutation() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/agents/agent_a")
            return (
                Self.response(request, status: 200),
                Data(#"{"id":"agent_a","name":"Agent without ACL coordinate"}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        do {
            try await repository.deleteAgent(id: AgentID(rawValue: "agent_a"))
            XCTFail("Expected deletion to fail closed without the Mongo ACL resource ID")
        } catch let error as AgentManagementError {
            XCTAssertEqual(error, .invalidResponse)
        }
        XCTAssertEqual(scenario.count(method: "GET"), 1)
        XCTAssertEqual(scenario.count(method: "DELETE"), 0)
    }

    func testAmbiguousDeleteWithExactExistingAgentBecomesSafelyRetryable() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            let step = scenario.record(request)
            switch step {
            case 1:
                return (
                    Self.response(request, status: 200),
                    Data(#"{"_id":"507f1f77bcf86cd799439011","id":"agent_a","name":"Agent"}"#.utf8)
                )
            case 2:
                return (Self.response(request, status: 200), Data(#"{"permissionBits":7}"#.utf8))
            case 3:
                return (Self.response(request, status: 500), Data(#"{"error":"uncertain"}"#.utf8))
            case 4:
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_a","name":"Still here"}"#.utf8)
                )
            default:
                XCTFail("Unexpected request \(step)")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        do {
            try await repository.deleteAgent(id: AgentID(rawValue: "agent_a"))
            XCTFail("Expected exact existence proof")
        } catch let error as AgentManagementError {
            XCTAssertEqual(error, .deletionNotApplied)
        }
        XCTAssertEqual(scenario.count(method: "DELETE"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 3)
    }

    func testVersionHistoryPreservesServerCoordinatesAndSafeMetadataOnly() async throws {
        AgentURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/agents/agent_a/versions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (
                Self.response(request, status: 200),
                Data(
                    #"[{"name":"First","instructions":"private","tools":["secret"]},42,{"name":"Third","description":"Safe","category":"work"}]"#.utf8
                )
            )
        }
        let repository = try await makeRepository()

        let history = try await repository.agentVersions(id: AgentID(rawValue: "agent_a"))

        XCTAssertEqual(history.versions.map(\.coordinate.serverIndex), [0, 1, 2])
        XCTAssertEqual(history.versions[0].name, "First")
        XCTAssertFalse(history.versions[1].isRestorable)
        XCTAssertEqual(history.versions[2].description, "Safe")
        XCTAssertEqual(history.versions[2].category, "work")
    }

    func testVersionRevertUsesFreshExactIndexAndOneShotServerMutation() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/agents/agent_a/versions"):
                return (
                    Self.response(request, status: 200),
                    Data(#"[{"name":"First"},{"name":"Second","description":"Safe"}]"#.utf8)
                )
            case ("POST", "/api/agents/agent_a/revert"):
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Int]
                )
                XCTAssertEqual(object, ["version_index": 1])
                return (
                    Self.response(request, status: 200),
                    Data(#"{"id":"agent_a","name":"Second","description":"Safe","version":9,"instructions":"must not escape"}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()
        let history = try await repository.agentVersions(id: AgentID(rawValue: "agent_a"))
        let version = try XCTUnwrap(history.versions.last)

        let restored = try await repository.revertAgentVersion(version)

        XCTAssertEqual(restored.id, AgentID(rawValue: "agent_a"))
        XCTAssertEqual(restored.name, "Second")
        XCTAssertEqual(restored.description, "Safe")
        XCTAssertEqual(restored.version, 9)
        XCTAssertEqual(scenario.count(method: "POST"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testLostVersionRevertAcknowledgementIsOutcomeUnknownAndNeverReposted() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            if request.httpMethod == "GET" {
                return (
                    Self.response(request, status: 200),
                    Data(#"[{"name":"First"}]"#.utf8)
                )
            }
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/agents/agent_a/revert")
            throw URLError(.networkConnectionLost)
        }
        let repository = try await makeRepository()
        let history = try await repository.agentVersions(id: AgentID(rawValue: "agent_a"))
        let version = try XCTUnwrap(history.versions.first)

        do {
            _ = try await repository.revertAgentVersion(version)
            XCTFail("Expected an outcome-unknown revert")
        } catch let error as AgentManagementError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        XCTAssertEqual(scenario.count(method: "POST"), 1)
        XCTAssertEqual(scenario.count(method: "GET"), 2)
    }

    func testStaleVersionSummaryNeverDispatchesRevertMutation() async throws {
        let scenario = AgentHTTPScenario()
        AgentURLProtocolStub.handler = { request in
            _ = scenario.record(request)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/agents/agent_a/versions")
            return (
                Self.response(request, status: 200),
                Data(#"[{"name":"Server value"}]"#.utf8)
            )
        }
        let repository = try await makeRepository()
        let stale = AgentVersionSummary(
            coordinate: AgentVersionCoordinate(
                agentID: AgentID(rawValue: "agent_a"),
                serverIndex: 0
            ),
            name: "Stale value"
        )

        do {
            _ = try await repository.revertAgentVersion(stale)
            XCTFail("Expected stale version rejection")
        } catch let error as AgentManagementError {
            guard case .invalidInput = error else {
                return XCTFail("Expected invalid input, got \(error)")
            }
        }
        XCTAssertEqual(scenario.count(method: "GET"), 1)
        XCTAssertEqual(scenario.count(method: "POST"), 0)
    }

    private func makeRepository() async throws -> LibreChatRepository {
        let dependencies = try AppDependencies(inMemory: true)
        let account = UserAccount(id: AccountID(rawValue: "account"))
        let baseURL = URL(string: "https://chat.example.com")!
        let profile = ServerProfile(
            id: ServerProfileID(rawValue: "profile"),
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id,
            capabilities: ServerCapabilities(
                authenticatedPolicyVerified: true,
                supportsAgents: true,
                agentPermissions: AgentPermissions(use: true, create: true)
            )
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: AgentSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let authentication = AuthSession.isolated(transport: transport)
        await authentication.setAuthenticated(
            AuthenticatedSession(accessToken: "token", user: account)
        )
        let runtime = LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: authentication,
            restClient: RESTClient(transport: transport, authSession: authentication)
        )
        return LibreChatRepository(profile: profile, runtime: runtime, cache: dependencies.cache)
    }

    private static func basicCreationRequest() -> BasicAgentCreationRequest {
        BasicAgentCreationRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            name: "Researcher",
            description: "Find evidence",
            instructions: "Use primary sources.",
            category: "Research",
            reviewedModel: BasicAgentModelReview(provider: "openAI", model: "gpt-safe")
        )
    }

    nonisolated private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}

private actor AgentRepositoryDouble: AgentRepository {
    struct Request: Equatable, Sendable {
        var search: String?
        var cursor: String?
        var limit: Int
    }

    private let pages: [String: ChatAgentPage]
    private let listError: LibreChatProtocolError?
    private(set) var requests: [Request] = []

    init(pages: [String: ChatAgentPage], listError: LibreChatProtocolError? = nil) {
        self.pages = pages
        self.listError = listError
    }

    func agents(search: String?, cursor: String?, limit: Int) async throws -> ChatAgentPage {
        requests.append(Request(search: search, cursor: cursor, limit: limit))
        if let listError { throw listError }
        return pages[cursor ?? "root"] ?? ChatAgentPage(agents: [])
    }

    func agent(id: AgentID) async throws -> ChatAgentDetail {
        ChatAgentDetail(id: id, name: id.rawValue)
    }
}

private actor AgentCreationRepositoryDouble: BasicAgentCreationRepository {
    private var outcomes: [BasicAgentCreationOutcome]
    private var requests: [BasicAgentCreationRequest] = []

    init(outcomes: [BasicAgentCreationOutcome]) {
        self.outcomes = outcomes
    }

    func requestCount() -> Int { requests.count }

    func createBasicAgent(
        _ request: BasicAgentCreationRequest
    ) throws -> BasicAgentCreationOutcome {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw LibreChatProtocolError.unsupported("No outcome configured")
        }
        return outcomes.removeFirst()
    }
}

private actor AgentSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class AgentURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// The loading system hands custom protocols a request whose `httpBody`
    /// was converted into a one-shot `httpBodyStream`; materialize it back so
    /// handler assertions can keep reading `httpBody`.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            request.httpBody = data
        }
        return request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class AgentHTTPScenario: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return requests.count
    }

    func count(method: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count { $0.httpMethod == method }
    }
}
