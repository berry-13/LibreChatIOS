import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class MemoryCenterModelTests: XCTestCase {
    func testOfflineNeverLoadsPrivateMemoryValues() async {
        let repository = MemoryRepositoryDouble(listResults: [])
        let model = makeModel(repository: repository, offline: true)

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .offline)
        XCTAssertNil(model.snapshot)
        let listCount = await repository.listCount
        XCTAssertEqual(listCount, 0)
    }

    func testLoadsFiltersPartitionsAndNeverNeedsRawAgentNameFallback() async {
        let memories = [
            UserMemory(key: "timezone", value: "Europe/Rome"),
            UserMemory(
                key: "tone",
                value: "Concise",
                agentID: AgentID(rawValue: "agent_private"),
                agentName: nil
            )
        ]
        let repository = MemoryRepositoryDouble(listResults: [.success(snapshot(memories))])
        let model = makeModel(repository: repository)

        await model.loadIfNeeded()
        XCTAssertEqual(model.visibleMemories.map(\.key), ["timezone", "tone"])
        XCTAssertEqual(model.partitionOptions.last?.label, "Agent-specific")

        model.partition = .agent(AgentID(rawValue: "agent_private"))
        XCTAssertEqual(model.visibleMemories.map(\.key), ["tone"])
        model.query = "rome"
        XCTAssertTrue(model.visibleMemories.isEmpty)
    }

    func testConfirmedCreateInstallsServerRowThenRefreshesUsage() async {
        let created = UserMemory(key: "food", value: "Vegetarian", tokenCount: 3)
        let repository = MemoryRepositoryDouble(
            listResults: [
                .success(snapshot([])),
                .success(snapshot([created], totalTokens: 3))
            ],
            created: created
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let succeeded = await model.create(key: "food", value: "Vegetarian")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.snapshot?.memories, [created])
        XCTAssertEqual(model.snapshot?.totalTokens, 3)
        let createInputs = await repository.createInputs
        XCTAssertEqual(createInputs, [CreateMemoryInput(key: "food", value: "Vegetarian")])
    }

    func testUnauthorizedRefreshClearsValuesAndExpiresSession() async {
        let repository = MemoryRepositoryDouble(
            listResults: [.failure(.unauthorized)]
        )
        var expired = false
        let model = makeModel(repository: repository) { expired = true }

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .unauthorized)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(expired)
    }

    func testPreferenceRemainsServerAuthoritativeOnFailure() async {
        let repository = MemoryRepositoryDouble(
            listResults: [.success(snapshot([]))],
            preferenceError: .httpStatus(403, message: "denied", retryAfter: nil)
        )
        let model = makeModel(repository: repository, memoriesEnabled: true)
        await model.loadIfNeeded()

        await model.setEnabled(false)

        XCTAssertTrue(model.memoriesEnabled)
        XCTAssertEqual(model.operationError, "Your current role does not allow that memory action.")
    }

    private func makeModel(
        repository: MemoryRepositoryDouble,
        offline: Bool = false,
        memoriesEnabled: Bool = true,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> MemoryCenterModel {
        MemoryCenterModel(
            repository: repository,
            permissions: MemoryPermissions(
                use: true,
                create: true,
                update: true,
                read: true,
                optOut: true
            ),
            memoriesEnabled: memoriesEnabled,
            isOffline: { offline },
            onUnauthorized: onUnauthorized,
            onPreferenceChanged: { _ in }
        )
    }

    private func snapshot(
        _ memories: [UserMemory],
        totalTokens: Int = 0
    ) -> MemorySnapshot {
        MemorySnapshot(
            memories: memories,
            totalTokens: totalTokens,
            tokenLimit: 1_000,
            characterLimit: 10_000,
            usagePercentage: 0
        )
    }
}

private actor MemoryRepositoryDouble: MemoryRepository {
    private var listResults: [Result<MemorySnapshot, LibreChatProtocolError>]
    private let created: UserMemory?
    private let preferenceError: LibreChatProtocolError?
    private(set) var listCount = 0
    private(set) var createInputs: [CreateMemoryInput] = []

    init(
        listResults: [Result<MemorySnapshot, LibreChatProtocolError>],
        created: UserMemory? = nil,
        preferenceError: LibreChatProtocolError? = nil
    ) {
        self.listResults = listResults
        self.created = created
        self.preferenceError = preferenceError
    }

    func memories() async throws -> MemorySnapshot {
        listCount += 1
        guard !listResults.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try listResults.removeFirst().get()
    }

    func createMemory(_ input: CreateMemoryInput) async throws -> UserMemory {
        createInputs.append(input)
        guard let created else { throw LibreChatProtocolError.invalidResponse }
        return created
    }

    func updateMemory(_ input: UpdateMemoryInput) async throws -> UserMemory {
        throw LibreChatProtocolError.unsupported("Not used by this fixture.")
    }

    func deleteMemory(_ input: DeleteMemoryInput) async throws {
        throw LibreChatProtocolError.unsupported("Not used by this fixture.")
    }

    func setMemoriesEnabled(_ enabled: Bool) async throws -> Bool {
        if let preferenceError { throw preferenceError }
        return enabled
    }
}

@MainActor
final class MemoryRepositoryWireTests: XCTestCase {
    override func tearDown() {
        MemoryURLProtocolStub.handler = nil
        MemoryURLProtocolStub.requestIndex = 0
        super.tearDown()
    }

    func testRepositoryUsesBearerListThenExactNonRetriedCreateWire() async throws {
        MemoryURLProtocolStub.handler = { request, index in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            if index == 0 {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/memories")
                return (
                    Self.response(request, status: 200),
                    Data(#"{"memories":[],"totalTokens":0,"tokenLimit":100,"charLimit":24,"usagePercentage":0}"#.utf8)
                )
            }
            XCTAssertEqual(index, 1)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/memories")
            let body = try Self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["key"] as? String, "tone")
            XCTAssertEqual(object["value"] as? String, "concise")
            XCTAssertNil(object["agentId"])
            return (
                Self.response(request, status: 201),
                Data(#"{"created":true,"memory":{"key":"tone","value":"concise","tokenCount":2}}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        _ = try await repository.memories()
        let memory = try await repository.createMemory(
            CreateMemoryInput(key: " tone ", value: " concise ")
        )

        XCTAssertEqual(memory.key, "tone")
        XCTAssertEqual(memory.value, "concise")
        XCTAssertEqual(MemoryURLProtocolStub.requestIndex, 2)
    }

    func testRepositoryRejectsMutationResponseFromAnotherPartition() async throws {
        MemoryURLProtocolStub.handler = { request, index in
            if index == 0 {
                return (
                    Self.response(request, status: 200),
                    Data(#"{"memories":[],"totalTokens":0,"charLimit":100}"#.utf8)
                )
            }
            return (
                Self.response(request, status: 201),
                Data(#"{"created":true,"memory":{"key":"tone","value":"concise","agentId":"agent_foreign"}}"#.utf8)
            )
        }
        let repository = try await makeRepository()
        _ = try await repository.memories()

        do {
            _ = try await repository.createMemory(
                CreateMemoryInput(key: "tone", value: "concise")
            )
            XCTFail("Expected exact partition rejection")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .invalidResponse)
        }
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
                supportsMemories: true,
                memoryPermissions: MemoryPermissions(
                    use: true,
                    create: true,
                    update: true,
                    read: true,
                    optOut: true
                )
            )
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: MemorySecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryURLProtocolStub.self]
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

    nonisolated private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            data.append(buffer, count: count)
        }
    }
}

private actor MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class MemoryURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestIndex = 0
    nonisolated(unsafe) static var handler: (
        @Sendable (URLRequest, Int) throws -> (HTTPURLResponse, Data)
    )?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
