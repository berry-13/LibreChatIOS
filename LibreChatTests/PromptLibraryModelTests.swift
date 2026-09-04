import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class PromptLibraryModelTests: XCTestCase {
    func testOfflineStateDoesNotRequestPrivatePromptContent() async {
        let repository = PromptRepositoryDouble(results: [])
        let model = makeModel(repository: repository, offline: true)

        await model.reload()

        XCTAssertEqual(model.state, .offline)
        XCTAssertTrue(model.groups.isEmpty)
        let requestCount = await repository.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testPagingDeduplicatesAndARecoverableFailureKeepsCurrentResults() async {
        let first = group("507f1f77bcf86cd799439011", name: "First")
        let second = group("507f1f77bcf86cd799439012", name: "Second")
        let repository = PromptRepositoryDouble(results: [
            .success(PromptTemplatePage(groups: [first], nextCursor: "next")),
            .failure(.httpStatus(503, message: "busy", retryAfter: nil)),
            .success(PromptTemplatePage(groups: [first, second], nextCursor: nil)),
        ])
        let model = makeModel(repository: repository)

        await model.reload()
        await model.loadMoreIfNeeded(after: first)

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.groups, [first])
        XCTAssertNotNil(model.paginationError)
        XCTAssertTrue(model.canLoadMore)

        await model.loadMoreIfNeeded(after: first)

        XCTAssertEqual(model.groups, [first, second])
        XCTAssertNil(model.paginationError)
        XCTAssertNil(model.nextCursor)
    }

    func testSlowerStaleSearchCannotOverwriteNewerResults() async throws {
        let old = group("507f1f77bcf86cd799439011", name: "Old")
        let latest = group("507f1f77bcf86cd799439012", name: "Latest")
        let repository = PromptRepositoryDouble(
            resultsBySearch: [
                "old": .init(
                    delay: .milliseconds(150),
                    result: .success(PromptTemplatePage(groups: [old]))
                ),
                "new": .init(
                    delay: .zero,
                    result: .success(PromptTemplatePage(groups: [latest]))
                ),
            ]
        )
        let model = makeModel(repository: repository)
        model.query = "old"
        let stale = Task { await model.reload() }
        try await Task.sleep(for: .milliseconds(20))

        model.query = "new"
        await model.reload()
        await stale.value

        XCTAssertEqual(model.groups, [latest])
        XCTAssertEqual(model.state, .loaded)
    }

    func testUnauthorizedPageClearsContentAndExpiresSession() async {
        let first = group("507f1f77bcf86cd799439011", name: "First")
        let repository = PromptRepositoryDouble(results: [
            .success(PromptTemplatePage(groups: [first], nextCursor: "next")),
            .failure(.unauthorized),
        ])
        var expired = false
        let model = makeModel(repository: repository) { expired = true }

        await model.reload()
        await model.loadMoreIfNeeded(after: first)

        XCTAssertEqual(model.state, .unauthorized)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.nextCursor)
        XCTAssertTrue(expired)
    }

    func testUsageFailureNeverRemovesAlreadyVisiblePrompt() async {
        let first = group("507f1f77bcf86cd799439011", name: "First")
        let repository = PromptRepositoryDouble(
            results: [.success(PromptTemplatePage(groups: [first]))],
            usageResult: .failure(.httpStatus(503, message: "busy", retryAfter: nil))
        )
        let model = makeModel(repository: repository)
        await model.reload()

        await model.recordUsage(for: first.id)

        XCTAssertEqual(model.groups, [first])
        XCTAssertEqual(model.state, .loaded)
    }

    private func makeModel(
        repository: PromptRepositoryDouble,
        offline: Bool = false,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> PromptLibraryModel {
        PromptLibraryModel(
            repository: repository,
            isOffline: { offline },
            onUnauthorized: onUnauthorized
        )
    }

    private func group(_ id: String, name: String) -> PromptTemplateGroup {
        PromptTemplateGroup(
            id: PromptGroupID(rawValue: id),
            name: name,
            productionText: "Write about {{topic}}"
        )
    }
}

private actor PromptRepositoryDouble: PromptRepository {
    struct DelayedResult: Sendable {
        let delay: Duration
        let result: Result<PromptTemplatePage, LibreChatProtocolError>
    }

    private var results: [Result<PromptTemplatePage, LibreChatProtocolError>]
    private let resultsBySearch: [String: DelayedResult]
    private let usageResult: Result<Int, LibreChatProtocolError>
    private(set) var requestCount = 0

    init(
        results: [Result<PromptTemplatePage, LibreChatProtocolError>] = [],
        resultsBySearch: [String: DelayedResult] = [:],
        usageResult: Result<Int, LibreChatProtocolError> = .success(0)
    ) {
        self.results = results
        self.resultsBySearch = resultsBySearch
        self.usageResult = usageResult
    }

    func promptGroups(_ query: PromptTemplateQuery) async throws -> PromptTemplatePage {
        requestCount += 1
        if let keyed = resultsBySearch[query.search ?? ""] {
            try await Task.sleep(for: keyed.delay)
            return try keyed.result.get()
        }
        guard !results.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try results.removeFirst().get()
    }

    func recordPromptUsage(groupID: PromptGroupID) async throws -> Int {
        try usageResult.get()
    }
}

@MainActor
final class PromptRepositoryWireTests: XCTestCase {
    private let groupID = PromptGroupID(rawValue: "507f1f77bcf86cd799439011")
    private let productionVersionID = PromptVersionID(rawValue: "507f1f77bcf86cd799439012")
    private let draftVersionID = PromptVersionID(rawValue: "507f1f77bcf86cd799439013")

    override func tearDown() {
        PromptURLProtocolStub.handler = nil
        PromptURLProtocolStub.requestIndex = 0
        super.tearDown()
    }

    func testRepositoryUsesExactBearerDirectoryAndNonRetriedUsageWire() async throws {
        PromptURLProtocolStub.handler = { request, index in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            if index == 0 {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query, [
                    URLQueryItem(name: "limit", value: "25"),
                    URLQueryItem(name: "name", value: "brief"),
                ])
                return (
                    Self.response(request, status: 200),
                    Data(#"{"promptGroups":[{"_id":"507f1f77bcf86cd799439011","name":"Brief","productionPrompt":{"prompt":"Write {{topic}}"}}],"has_more":false}"#.utf8)
                )
            }
            XCTAssertEqual(index, 1)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups/507f1f77bcf86cd799439011/use")
            XCTAssertNil(request.httpBody)
            return (
                Self.response(request, status: 200),
                Data(#"{"numberOfGenerations":7}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        let page = try await repository.promptGroups(.init(search: " brief ", limit: 25))
        let count = try await repository.recordPromptUsage(
            groupID: PromptGroupID(rawValue: "507f1f77bcf86cd799439011")
        )

        XCTAssertEqual(page.groups.map(\.name), ["Brief"])
        XCTAssertEqual(count, 7)
        XCTAssertEqual(PromptURLProtocolStub.requestIndex, 2)
    }

    func testManagementDetailReadsExactGroupAndVersionSet() async throws {
        let groupID = groupID
        let productionVersionID = productionVersionID
        let draftVersionID = draftVersionID
        PromptURLProtocolStub.handler = { request, index in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups/\(groupID.rawValue)")
                return (
                    Self.response(request, status: 200),
                    Self.groupData(groupID: groupID, productionVersionID: productionVersionID)
                )
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts")
                XCTAssertEqual(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                    [URLQueryItem(name: "groupId", value: groupID.rawValue)]
                )
                return (
                    Self.response(request, status: 200),
                    Self.versionsData(
                        groupID: groupID,
                        productionVersionID: productionVersionID,
                        draftVersionID: draftVersionID
                    )
                )
            default:
                XCTFail("Unexpected prompt-management request \(index)")
                throw URLError(.badServerResponse)
            }
        }
        let repository = try await makeRepository()

        let detail = try await repository.promptManagementDetail(groupID: groupID)

        XCTAssertEqual(detail.group.id, groupID)
        XCTAssertEqual(detail.group.productionVersionID, productionVersionID)
        XCTAssertEqual(detail.versions.map(\.id), [productionVersionID, draftVersionID])
        XCTAssertEqual(PromptURLProtocolStub.requestIndex, 2)
    }

    func testCreateLostResponseIsOutcomeUnknownAndNeverReposted() async throws {
        PromptURLProtocolStub.handler = { request, index in
            XCTAssertEqual(index, 0)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/subpath/api/prompts")
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let prompt = try XCTUnwrap(object["prompt"] as? [String: Any])
            let group = try XCTUnwrap(object["group"] as? [String: Any])
            XCTAssertEqual(prompt["prompt"] as? String, "Private prompt")
            XCTAssertEqual(group["name"] as? String, "Private template")
            throw URLError(.networkConnectionLost)
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.createPromptGroup(CreatePromptGroupInput(
                name: "Private template",
                text: "Private prompt"
            ))
            XCTFail("Expected an ambiguous creation outcome")
        } catch let error as PromptManagementError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        XCTAssertEqual(PromptURLProtocolStub.requestIndex, 1)
    }

    func testAddVersionLostResponseIsOutcomeUnknownAndNeverReposted() async throws {
        let groupID = groupID
        PromptURLProtocolStub.handler = { request, index in
            XCTAssertEqual(index, 0)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.url?.path,
                "/subpath/api/prompts/groups/\(groupID.rawValue)/prompts"
            )
            throw URLError(.networkConnectionLost)
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.addPromptVersion(AddPromptVersionInput(
                groupID: groupID,
                text: "Second version",
                kind: .text
            ))
            XCTFail("Expected an ambiguous version outcome")
        } catch let error as PromptManagementError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        XCTAssertEqual(PromptURLProtocolStub.requestIndex, 1)
    }

    func testMetadataUpdateReconcilesAnAmbiguousPatchWithoutReposting() async throws {
        let groupID = groupID
        let productionVersionID = productionVersionID
        PromptURLProtocolStub.handler = { request, index in
            switch index {
            case 0:
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups/\(groupID.rawValue)")
                return (Self.response(request, status: 503), Data(#"{"message":"busy"}"#.utf8))
            case 1:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups/\(groupID.rawValue)")
                return (
                    Self.response(request, status: 200),
                    Self.groupData(
                        groupID: groupID,
                        productionVersionID: productionVersionID,
                        name: "Renamed",
                        summary: "Updated",
                        category: "private",
                        command: nil
                    )
                )
            default:
                XCTFail("Mutation was reposted instead of reconciled")
                throw URLError(.badServerResponse)
            }
        }
        let repository = try await makeRepository()

        let group = try await repository.updatePromptGroup(UpdatePromptGroupInput(
            groupID: groupID,
            name: "Renamed",
            summary: "Updated",
            category: "private",
            command: nil
        ))

        XCTAssertEqual(group.name, "Renamed")
        XCTAssertEqual(group.summary, "Updated")
        XCTAssertEqual(PromptURLProtocolStub.requestIndex, 2)
    }

    func testPromotionPreflightsMembershipThenReconcilesAmbiguousPatch() async throws {
        let groupID = groupID
        let oldVersionID = productionVersionID
        let promotedVersionID = draftVersionID
        PromptURLProtocolStub.handler = { request, index in
            switch index {
            case 0:
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups/\(groupID.rawValue)")
                return (
                    Self.response(request, status: 200),
                    Self.groupData(groupID: groupID, productionVersionID: oldVersionID)
                )
            case 1:
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts")
                return (
                    Self.response(request, status: 200),
                    Self.versionsData(
                        groupID: groupID,
                        productionVersionID: oldVersionID,
                        draftVersionID: promotedVersionID
                    )
                )
            case 2:
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(
                    request.url?.path,
                    "/subpath/api/prompts/\(promotedVersionID.rawValue)/tags/production"
                )
                return (Self.response(request, status: 503), Data(#"{"message":"busy"}"#.utf8))
            case 3:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/subpath/api/prompts/groups/\(groupID.rawValue)")
                return (
                    Self.response(request, status: 200),
                    Self.groupData(groupID: groupID, productionVersionID: promotedVersionID)
                )
            default:
                XCTFail("Promotion was reposted instead of reconciled")
                throw URLError(.badServerResponse)
            }
        }
        let repository = try await makeRepository()

        let group = try await repository.promotePromptVersion(
            groupID: groupID,
            versionID: promotedVersionID
        )

        XCTAssertEqual(group.productionVersionID, promotedVersionID)
        XCTAssertEqual(PromptURLProtocolStub.requestIndex, 4)
    }

    private func makeRepository() async throws -> LibreChatRepository {
        let dependencies = try AppDependencies(inMemory: true)
        let account = UserAccount(id: AccountID(rawValue: "account"))
        let baseURL = URL(string: "https://chat.example.com/subpath")!
        let profile = ServerProfile(
            id: ServerProfileID(rawValue: "profile"),
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id,
            capabilities: ServerCapabilities(
                promptPermissions: PromptPermissions(use: true)
            )
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: PromptSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PromptURLProtocolStub.self]
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

    nonisolated private static func response(
        _ request: URLRequest,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func groupData(
        groupID: PromptGroupID,
        productionVersionID: PromptVersionID,
        name: String = "Private template",
        summary: String = "Private summary",
        category: String = "private",
        command: String? = "private-template"
    ) -> Data {
        var object: [String: Any] = [
            "_id": groupID.rawValue,
            "name": name,
            "oneliner": summary,
            "category": category,
            "productionId": productionVersionID.rawValue,
        ]
        if let command { object["command"] = command }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    nonisolated private static func versionsData(
        groupID: PromptGroupID,
        productionVersionID: PromptVersionID,
        draftVersionID: PromptVersionID
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            [
                "_id": productionVersionID.rawValue,
                "groupId": groupID.rawValue,
                "prompt": "Production text",
                "type": "text",
            ],
            [
                "_id": draftVersionID.rawValue,
                "groupId": groupID.rawValue,
                "prompt": "Draft text",
                "type": "chat",
            ],
        ], options: [.sortedKeys])
    }
}

private actor PromptSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class PromptURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestIndex = 0
    nonisolated(unsafe) static var handler: (
        @Sendable (URLRequest, Int) throws -> (HTTPURLResponse, Data)
    )?

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// The loading system hands custom protocols a request whose `httpBody`
    /// was converted into a one-shot `httpBodyStream`; materialize it back so
    /// handlers can keep reading `httpBody`.
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
        let index = Self.requestIndex
        Self.requestIndex += 1
        do {
            let (response, data) = try handler(request, index)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
