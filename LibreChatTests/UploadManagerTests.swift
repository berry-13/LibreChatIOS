import LibreChatDomain
import LibreChatProtocol
import XCTest
import UIKit
@testable import LibreChat

@MainActor
final class UploadManagerTests: XCTestCase {
    override func tearDown() {
        UploadManagerURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testImageUploadAcceptsServerIDThroughMatchingTemporaryID() async throws {
        let recorder = UploadRequestRecorder()
        UploadManagerURLProtocolStub.handler = { request in
            recorder.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/files/config"):
                return (Self.response(request, status: 404), Data())
            case ("POST", "/api/files/images"):
                let body = try Self.bodyData(request)
                recorder.captureMultipartBody(body)
                let clientID = try XCTUnwrap(Self.multipartField("file_id", in: body))
                let json = """
                {"file_id":"server-image","temp_file_id":"\(clientID)","filename":"camera.jpg","type":"image/jpeg","width":20,"height":10}
                """
                return (Self.response(request, status: 200), Data(json.utf8))
            case ("POST", "/api/files/usage"):
                return (Self.response(request, status: 200), Data(#"{"held":1}"#.utf8))
            case ("DELETE", "/api/files"):
                return (Self.response(request, status: 200), Data(#"{"message":"deleted"}"#.utf8))
            default:
                XCTFail("Unexpected upload request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(request, status: 404), Data())
            }
        }
        let context = try await makeManager()

        let staged = try await context.manager.stage(
            data: try imageData(),
            filename: "camera.jpg",
            mimeType: "image/jpeg",
            conversationID: context.conversationID,
            target: ConversationTarget(endpoint: "agents")
        )
        let completed = try await waitForUpload(
            id: staged.id,
            state: .completed,
            context: context
        )

        XCTAssertEqual(completed.remoteIdentifier, "server-image")
        XCTAssertEqual(completed.remoteFile?.temporaryID, staged.id.uuidString)
        XCTAssertEqual(recorder.count(method: "POST", path: "/api/files/images"), 1)
        await context.manager.cancel(id: staged.id)
        await context.manager.resetAfterCachePurge()
    }

    func testLostUploadAcknowledgementReconcilesByTemporaryIDWithoutRepost() async throws {
        let recorder = UploadRequestRecorder()
        UploadManagerURLProtocolStub.handler = { request in
            recorder.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/files/config"):
                return (Self.response(request, status: 404), Data())
            case ("POST", "/api/files/images"):
                recorder.captureMultipartBody(try Self.bodyData(request))
                throw URLError(.networkConnectionLost)
            case ("GET", "/api/files"):
                let clientID = try XCTUnwrap(recorder.multipartClientFileID)
                let json = """
                [{"file_id":"recovered-server-image","temp_file_id":"\(clientID)","filename":"camera.jpg","type":"image/jpeg","width":20,"height":10}]
                """
                return (Self.response(request, status: 200), Data(json.utf8))
            case ("POST", "/api/files/usage"):
                return (Self.response(request, status: 200), Data(#"{"held":1}"#.utf8))
            case ("DELETE", "/api/files"):
                return (Self.response(request, status: 200), Data(#"{"message":"deleted"}"#.utf8))
            default:
                return (Self.response(request, status: 404), Data())
            }
        }
        let context = try await makeManager()

        let staged = try await context.manager.stage(
            data: try imageData(),
            filename: "camera.jpg",
            mimeType: "image/jpeg",
            conversationID: context.conversationID,
            target: ConversationTarget(endpoint: "agents")
        )
        let completed = try await waitForUpload(
            id: staged.id,
            state: .completed,
            context: context
        )

        XCTAssertEqual(completed.remoteIdentifier, "recovered-server-image")
        XCTAssertEqual(recorder.count(method: "POST", path: "/api/files/images"), 1)
        XCTAssertEqual(recorder.count(method: "GET", path: "/api/files"), 1)
        await context.manager.cancel(id: staged.id)
        await context.manager.resetAfterCachePurge()
    }

    func testUnresolvedAmbiguousUploadLocksBlindRetry() async throws {
        let recorder = UploadRequestRecorder()
        UploadManagerURLProtocolStub.handler = { request in
            recorder.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/files/config"):
                return (Self.response(request, status: 404), Data())
            case ("POST", "/api/files/images"):
                recorder.captureMultipartBody(try Self.bodyData(request))
                return (
                    Self.response(request, status: 200),
                    Data(#"{"file_id":"foreign-server-image","temp_file_id":"foreign-client","filename":"camera.jpg","type":"image/jpeg"}"#.utf8)
                )
            case ("GET", "/api/files"):
                guard recorder.shouldReturnRecovery,
                      let clientID = recorder.multipartClientFileID else {
                    return (Self.response(request, status: 200), Data("[]".utf8))
                }
                let json = """
                [{"file_id":"late-server-image","temp_file_id":"\(clientID)","filename":"camera.jpg","type":"image/jpeg","width":20,"height":10}]
                """
                return (Self.response(request, status: 200), Data(json.utf8))
            default:
                return (Self.response(request, status: 404), Data())
            }
        }
        let context = try await makeManager()

        let staged = try await context.manager.stage(
            data: try imageData(),
            filename: "camera.jpg",
            mimeType: "image/jpeg",
            conversationID: context.conversationID,
            target: ConversationTarget(endpoint: "agents")
        )
        _ = try await waitForUpload(
            id: staged.id,
            state: .deliveryUncertain,
            context: context
        )
        try await context.manager.retry(id: staged.id)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.count(method: "POST", path: "/api/files/images"), 1)
        let cached = try await context.cache.uploads(
            profileID: context.profileID,
            accountID: context.accountID
        )
        XCTAssertEqual(cached.first(where: { $0.id == staged.id })?.state, .deliveryUncertain)
        recorder.enableRecovery()
        try await context.manager.reconcileDelivery(id: staged.id)
        let completed = try await waitForUpload(
            id: staged.id,
            state: .completed,
            context: context
        )
        XCTAssertEqual(completed.remoteIdentifier, "late-server-image")
        XCTAssertEqual(recorder.count(method: "POST", path: "/api/files/images"), 1)
        XCTAssertEqual(recorder.count(method: "GET", path: "/api/files"), 2)
        await context.manager.cancel(id: staged.id)
        await context.manager.resetAfterCachePurge()
    }

    private func makeManager() async throws -> UploadTestContext {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "camera-profile-\(UUID().uuidString)")
        let accountID = AccountID(rawValue: "camera-account")
        let baseURL = try XCTUnwrap(URL(string: "https://upload.example.com"))
        let jar = ProfileCookieJar(
            profileID: profileID,
            baseURL: baseURL,
            secretStore: UploadManagerSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadManagerURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let auth = LibreChatProtocol.AuthSession.isolated(transport: transport)
        await auth.setAuthenticated(
            AuthenticatedSession(accessToken: "token", user: UserAccount(id: accountID))
        )
        let manager = UploadManager(
            profileID: profileID,
            accountID: accountID,
            runtime: LibreChatRuntime(
                cookieJar: jar,
                transport: transport,
                authSession: auth,
                restClient: RESTClient(transport: transport, authSession: auth)
            ),
            cache: dependencies.cache
        )
        return UploadTestContext(
            manager: manager,
            cache: dependencies.cache,
            profileID: profileID,
            accountID: accountID,
            conversationID: ConversationID(rawValue: "camera-conversation")
        )
    }

    private func imageData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func waitForUpload(
        id: UUID,
        state: PendingUpload.State,
        context: UploadTestContext
    ) async throws -> PendingUpload {
        // Generous budget: reconciliation spans multiple stubbed round trips
        // plus cache writes, which a loaded CI runner can outgrow in 2s.
        for _ in 0..<500 {
            let uploads = try await context.cache.uploads(
                profileID: context.profileID,
                accountID: context.accountID
            )
            if let upload = uploads.first(where: { $0.id == id && $0.state == state }) {
                return upload
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Upload did not reach \(state.rawValue)")
        throw CocoaError(.coderValueNotFound)
    }

    nonisolated private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return result }
            result.append(buffer, count: count)
        }
    }

    nonisolated private static func multipartField(_ name: String, in body: Data) -> String? {
        let marker = Data("name=\"\(name)\"\r\n\r\n".utf8)
        let lineEnding = Data("\r\n".utf8)
        guard let markerRange = body.range(of: marker) else { return nil }
        let valueStart = markerRange.upperBound
        guard let valueEnd = body[valueStart...].range(of: lineEnding)?.lowerBound else { return nil }
        return String(data: body[valueStart..<valueEnd], encoding: .utf8)
    }
}

private struct UploadTestContext {
    let manager: UploadManager
    let cache: CacheCoordinator
    let profileID: ServerProfileID
    let accountID: AccountID
    let conversationID: ConversationID
}

private actor UploadManagerSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class UploadRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var clientFileID: String?
    private var returnsRecovery = false

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func count(method: String, path: String) -> Int {
        lock.withLock {
            requests.count { $0.httpMethod == method && $0.url?.path == path }
        }
    }

    func captureMultipartBody(_ body: Data) {
        let marker = Data("name=\"file_id\"\r\n\r\n".utf8)
        let lineEnding = Data("\r\n".utf8)
        guard let markerRange = body.range(of: marker),
              let valueEnd = body[markerRange.upperBound...].range(of: lineEnding)?.lowerBound,
              let value = String(data: body[markerRange.upperBound..<valueEnd], encoding: .utf8) else {
            return
        }
        lock.withLock { clientFileID = value }
    }

    func enableRecovery() {
        lock.withLock { returnsRecovery = true }
    }

    var shouldReturnRecovery: Bool {
        lock.withLock { returnsRecovery }
    }

    var multipartClientFileID: String? {
        lock.withLock { clientFileID }
    }
}

private final class UploadManagerURLProtocolStub: URLProtocol {
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
