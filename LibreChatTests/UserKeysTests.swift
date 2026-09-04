import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class UserKeysRepositoryTests: XCTestCase {
    override func tearDown() {
        UserKeysURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testCatalogUsesFreshEndpointPolicyAndReturnsExpiryMetadataOnly() async throws {
        let repository = try await makeRepository()
        let capture = UserKeysRequestCapture()
        UserKeysURLProtocolStub.handler = { request in
            capture.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return Self.jsonResponse(
                    request,
                    #"{"openAI":{"userProvide":true,"userProvideURL":true},"assistants":{"userProvide":true}}"#
                )
            case ("GET", "/api/keys"):
                XCTAssertEqual(request.url?.query, "name=openAI")
                return Self.jsonResponse(request, #"{"expiresAt":"never"}"#)
            default:
                XCTFail("Unexpected user-key catalog request")
                return Self.response(request, status: 404, data: Data())
            }
        }

        let catalog = try await repository.userKeyCatalog()

        XCTAssertEqual(catalog.profileID.rawValue, "profile")
        XCTAssertEqual(catalog.accountID.rawValue, "account")
        XCTAssertEqual(catalog.requirements.count, 1)
        XCTAssertEqual(catalog.requirements.first?.id.rawValue, "openAI")
        XCTAssertEqual(catalog.requirements.first?.availability, .stored(expiresAt: nil))
        XCTAssertEqual(capture.methods, ["GET", "GET"])
        XCTAssertTrue(capture.bodies.allSatisfy(\.isEmpty))
    }

    func testSaveUsesExactNeverRetryBodyThenRefreshesStatus() async throws {
        let repository = try await makeRepository()
        let capture = UserKeysRequestCapture()
        UserKeysURLProtocolStub.handler = { request in
            capture.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return Self.jsonResponse(request, #"{"openAI":{"userProvide":true}}"#)
            case ("GET", "/api/keys"):
                let expiry: Any = capture.methods.contains("PUT") ? "never" : NSNull()
                let data = try JSONSerialization.data(withJSONObject: ["expiresAt": expiry])
                return Self.response(request, status: 200, data: data)
            case ("PUT", "/api/keys"):
                return Self.response(request, status: 201, data: Data())
            default:
                return Self.response(request, status: 404, data: Data())
            }
        }

        let result = try await repository.saveUserKey(UserKeyUpdateInput(
            endpointID: UserKeyEndpointID(rawValue: "openAI"),
            credentials: .openAI(apiKey: "top-secret", baseURL: nil),
            expiresAt: nil
        ))

        XCTAssertEqual(result, .confirmed(.stored(expiresAt: nil)))
        XCTAssertEqual(capture.methods, ["GET", "GET", "PUT", "GET"])
        XCTAssertEqual(capture.methods.filter { $0 == "PUT" }.count, 1)
        let put = try XCTUnwrap(capture.requests.first { $0.httpMethod == "PUT" })
        let body = try Self.bodyObject(put)
        XCTAssertEqual(body["name"] as? String, "openAI")
        XCTAssertEqual(body["expiresAt"] as? String, "")
        let value = try XCTUnwrap(body["value"] as? String)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: String]
        )
        XCTAssertEqual(envelope, ["apiKey": "top-secret", "baseURL": ""])
    }

    func testLostRotationResponseIsUncertainAndNeverRepostsSecret() async throws {
        let repository = try await makeRepository()
        let capture = UserKeysRequestCapture()
        UserKeysURLProtocolStub.handler = { request in
            capture.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return Self.jsonResponse(request, #"{"anthropic":{"userProvide":true}}"#)
            case ("GET", "/api/keys"):
                return Self.jsonResponse(request, #"{"expiresAt":"never"}"#)
            case ("PUT", "/api/keys"):
                throw URLError(.networkConnectionLost)
            default:
                return Self.response(request, status: 404, data: Data())
            }
        }

        let result = try await repository.saveUserKey(UserKeyUpdateInput(
            endpointID: UserKeyEndpointID(rawValue: "anthropic"),
            credentials: .simple(secret: "rotated-secret"),
            expiresAt: nil
        ))

        XCTAssertEqual(result, .deliveryUncertain)
        XCTAssertEqual(capture.methods.filter { $0 == "PUT" }.count, 1)
        XCTAssertEqual(capture.methods, ["GET", "GET", "PUT", "GET"])
    }

    func testLostRevokeResponseCommitsOnlyWhenStatusProvesMissing() async throws {
        let repository = try await makeRepository()
        let capture = UserKeysRequestCapture()
        UserKeysURLProtocolStub.handler = { request in
            capture.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return Self.jsonResponse(request, #"{"anthropic":{"userProvide":true}}"#)
            case ("GET", "/api/keys"):
                let expiry = capture.methods.contains("DELETE") ? "null" : #""never""#
                return Self.jsonResponse(request, "{\"expiresAt\":\(expiry)}")
            case ("DELETE", "/api/keys/anthropic"):
                throw URLError(.networkConnectionLost)
            default:
                return Self.response(request, status: 404, data: Data())
            }
        }

        let result = try await repository.revokeUserKey(
            UserKeyEndpointID(rawValue: "anthropic")
        )

        XCTAssertEqual(result, .confirmed(.missing))
        XCTAssertEqual(capture.methods.filter { $0 == "DELETE" }.count, 1)
        XCTAssertEqual(capture.methods, ["GET", "GET", "DELETE", "GET"])
        let revoke = try XCTUnwrap(capture.requests.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(revoke.url?.path, "/api/keys/anthropic")
        XCTAssertTrue(try Self.bodyData(revoke).isEmpty)
    }

    func testUnauthorizedCatalogNeverReturnsPrivateStatus() async throws {
        let repository = try await makeRepository()
        UserKeysURLProtocolStub.handler = { request in
            Self.response(request, status: 401, data: Data(#"{"message":"expired"}"#.utf8))
        }
        do {
            _ = try await repository.userKeyCatalog()
            XCTFail("Expected unauthorized")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    private func makeRepository() async throws -> LibreChatRepository {
        let dependencies = try AppDependencies(inMemory: true)
        let baseURL = URL(string: "https://chat.example.com")!
        let account = UserAccount(id: AccountID(rawValue: "account"))
        let profile = ServerProfile(
            id: ServerProfileID(rawValue: "profile"),
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: UserKeysSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserKeysURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let auth = LibreChatProtocol.AuthSession.isolated(transport: transport)
        await auth.setAuthenticated(AuthenticatedSession(accessToken: "token", user: account))
        return LibreChatRepository(
            profile: profile,
            runtime: LibreChatRuntime(
                cookieJar: jar,
                transport: transport,
                authSession: auth,
                restClient: RESTClient(transport: transport, authSession: auth)
            ),
            cache: dependencies.cache
        )
    }

    nonisolated private static func jsonResponse(
        _ request: URLRequest,
        _ json: String
    ) -> (HTTPURLResponse, Data) {
        response(request, status: 200, data: Data(json.utf8))
    }

    nonisolated private static func response(
        _ request: URLRequest,
        status: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            data
        )
    }

    nonisolated private static func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData(request)) as? [String: Any]
        )
    }

    nonisolated fileprivate static func bodyData(_ request: URLRequest) throws -> Data {
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

@MainActor
final class UserKeysModelTests: XCTestCase {
    func testOfflineNeverReadsCredentialMetadata() async {
        let repository = UserKeysRepositoryDouble(catalogResults: [])
        let model = UserKeysModel(
            repository: repository,
            isOffline: { true },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .offline)
        XCTAssertNil(model.catalog)
        let catalogCalls = await repository.catalogCallCount
        XCTAssertEqual(catalogCalls, 0)
    }

    func testModelStoresOnlyNonsecretCatalogAndRefreshesAfterConfirmedSave() async {
        let initial = Self.catalog(availability: .missing)
        let refreshed = Self.catalog(availability: .stored(expiresAt: nil))
        let repository = UserKeysRepositoryDouble(
            catalogResults: [.success(initial), .success(refreshed)],
            saveResults: [.success(.confirmed(.stored(expiresAt: nil)))]
        )
        let model = UserKeysModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )
        await model.loadIfNeeded()
        let requirement = try! XCTUnwrap(model.catalog?.requirements.first)

        let saved = await model.save(
            requirement: requirement,
            credentials: .simple(secret: "never-observable"),
            expiration: .never
        )

        XCTAssertTrue(saved)
        XCTAssertEqual(model.catalog, refreshed)
        XCTAssertNil(model.activeMutation)
        XCTAssertNil(model.operationMessage)
        let inputs = await repository.saveInputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.endpointID.rawValue, "anthropic")
    }

    func testDeliveryUncertaintyDoesNotInventStoredStatusOrRetry() async throws {
        let initial = Self.catalog(availability: .missing)
        let repository = UserKeysRepositoryDouble(
            catalogResults: [.success(initial)],
            saveResults: [.success(.deliveryUncertain)]
        )
        let model = UserKeysModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )
        await model.loadIfNeeded()
        let requirement = try XCTUnwrap(model.catalog?.requirements.first)

        let saved = await model.save(
            requirement: requirement,
            credentials: .simple(secret: "one-shot"),
            expiration: .twelveHours
        )

        XCTAssertFalse(saved)
        XCTAssertEqual(model.catalog?.requirements.first?.availability, .missing)
        XCTAssertNotNil(model.operationMessage)
        let saveCalls = await repository.saveCallCount
        let catalogCalls = await repository.catalogCallCount
        XCTAssertEqual(saveCalls, 1)
        XCTAssertEqual(catalogCalls, 1)
    }

    func testUnauthorizedClearsCatalogAndExpiresSession() async {
        let repository = UserKeysRepositoryDouble(
            catalogResults: [.failure(.unauthorized)]
        )
        var expired = false
        let model = UserKeysModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: { expired = true }
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .unauthorized)
        XCTAssertNil(model.catalog)
        XCTAssertTrue(expired)
    }

    nonisolated private static func catalog(
        availability: UserKeyAvailability
    ) -> UserKeyCatalog {
        UserKeyCatalog(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            fetchedAt: Date(timeIntervalSince1970: 100),
            requirements: [UserKeyRequirement(
                id: UserKeyEndpointID(rawValue: "anthropic"),
                displayName: "Anthropic",
                form: .simple,
                availability: availability
            )]
        )
    }
}

private actor UserKeysRepositoryDouble: UserKeyRepository {
    private var catalogResults: [Result<UserKeyCatalog, LibreChatProtocolError>]
    private var saveResults: [Result<UserKeyMutationResult, LibreChatProtocolError>]
    private var revokeResults: [Result<UserKeyMutationResult, LibreChatProtocolError>]
    private(set) var catalogCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var saveInputs: [UserKeyUpdateInput] = []

    init(
        catalogResults: [Result<UserKeyCatalog, LibreChatProtocolError>],
        saveResults: [Result<UserKeyMutationResult, LibreChatProtocolError>] = [],
        revokeResults: [Result<UserKeyMutationResult, LibreChatProtocolError>] = []
    ) {
        self.catalogResults = catalogResults
        self.saveResults = saveResults
        self.revokeResults = revokeResults
    }

    func userKeyCatalog() async throws -> UserKeyCatalog {
        catalogCallCount += 1
        guard !catalogResults.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try catalogResults.removeFirst().get()
    }

    func saveUserKey(_ input: UserKeyUpdateInput) async throws -> UserKeyMutationResult {
        saveCallCount += 1
        saveInputs.append(input)
        guard !saveResults.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try saveResults.removeFirst().get()
    }

    func revokeUserKey(_ endpointID: UserKeyEndpointID) async throws -> UserKeyMutationResult {
        guard !revokeResults.isEmpty else { throw LibreChatProtocolError.invalidResponse }
        return try revokeResults.removeFirst().get()
    }
}

private actor UserKeysSecretStore: SecretStore {
    private var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class UserKeysURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private final class UserKeysRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }
    var methods: [String] { lock.withLock { storage.compactMap(\.httpMethod) } }
    var bodies: [Data] {
        lock.withLock {
            storage.compactMap { try? UserKeysRepositoryTests.bodyData($0) }
        }
    }

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
