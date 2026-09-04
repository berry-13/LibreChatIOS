import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

final class ProtocolContractTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.refreshCount = 0
        super.tearDown()
    }

    func testDecodesEventSplitAtEveryByteBoundary() throws {
        let payload = Data("event: message\nid: 42\ndata: {\"delta\":\"Hello\"}\n\n".utf8)
        var decoder = LibreChatProtocol.SSEDecoder()
        var events: [LibreChatProtocol.ServerSentEvent] = []
        for byte in payload { events.append(contentsOf: try decoder.append(Data([byte]))) }
        XCTAssertEqual(events, [.init(event: "message", id: "42", data: "{\"delta\":\"Hello\"}")])
    }

    func testJoinsMultilineDataAndIgnoresComments() throws {
        let payload = Data(": keep-alive\r\ndata: first\r\ndata: second\r\n\r\n".utf8)
        var decoder = LibreChatProtocol.SSEDecoder()
        XCTAssertEqual(try decoder.append(payload), [.init(data: "first\nsecond")])
    }

    func testConversationPageDecodesCurrentCursorEnvelope() throws {
        let fixture = Data(
            """
            {"conversations":[{"conversationId":"conversation-1","title":"Mobile plan","endpoint":"agents","model":"agent-model","agent_id":"agent-1","parentMessageId":"active-branch-message"}],"nextCursor":"opaque-cursor"}
            """.utf8
        )
        let page = try JSONDecoder().decode(LibreChatConversationPageDTO.self, from: fixture)
        let domain = try page.domainModel()
        XCTAssertEqual(domain.conversations.first?.id, ConversationID(rawValue: "conversation-1"))
        XCTAssertEqual(domain.conversations.first?.target?.agentID, "agent-1")
        XCTAssertEqual(domain.conversations.first?.target?.parentMessageID, MessageID(rawValue: "active-branch-message"))
        XCTAssertEqual(domain.nextCursor, "opaque-cursor")
    }

    func testMessagePreservesUnsupportedContent() throws {
        let fixture = Data(
            """
            {"messageId":"message-1","conversationId":"conversation-1","sender":"Assistant","isCreatedByUser":false,"content":[{"type":"tool_call","id":"search"},{"type":"text","text":"Hello "},{"type":"future_widget"}]}
            """.utf8
        )
        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: fixture).domainModel()
        XCTAssertEqual(message.content, [
            .tool(ToolCall(id: "search", name: "Tool", status: .running)),
            .text("Hello "),
            .unsupported(kind: "future_widget")
        ])
    }

    func testLoginDecodesAuthenticatedSession() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/login")
            return (
                Self.response(for: request, status: 200),
                Data("{\"token\":\"access-token\",\"user\":{\"id\":\"user-1\",\"email\":\"mobile@example.com\"}}".utf8)
            )
        }
        let runtime = makeRuntime()
        let result = try await runtime.authSession.login(email: "mobile@example.com", password: "secret")
        guard case let .authenticated(session) = result else { return XCTFail("Expected authentication") }
        XCTAssertEqual(session.accessToken, "access-token")
        XCTAssertEqual(session.user.id, AccountID(rawValue: "user-1"))
    }

    func testLoginDecodesTwoFactorChallengeSeparately() async throws {
        URLProtocolStub.handler = { request in
            (Self.response(for: request, status: 200), Data("{\"twoFAPending\":true,\"tempToken\":\"temporary-token\"}".utf8))
        }
        let result = try await makeRuntime().authSession.login(email: "mobile@example.com", password: "secret")
        XCTAssertEqual(result, .requiresTwoFactor(.init(temporaryToken: "temporary-token")))
    }

    func testRefreshRejectsPlainTextSuccessWithoutToken() async throws {
        URLProtocolStub.handler = { request in
            (Self.response(for: request, status: 200), Data("Refresh token not provided".utf8))
        }
        do {
            _ = try await makeRuntime().authSession.restoreSession()
            XCTFail("Expected unauthorized")
        } catch {
            guard case LibreChatProtocolError.unauthorized = error else {
                return XCTFail("Expected missing refresh credentials to sign out")
            }
        }
    }

    func testSimultaneousUnauthorizedRequestsPerformOneRefresh() async throws {
        URLProtocolStub.handler = { request in
            if request.url?.path == "/api/auth/refresh" {
                URLProtocolStub.incrementRefreshCount()
                Thread.sleep(forTimeInterval: 0.05)
                return (
                    Self.response(for: request, status: 200),
                    Data("{\"token\":\"new-token\",\"user\":{\"id\":\"user-1\"}}".utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            return (Self.response(for: request, status: 200), Data("{\"ok\":true}".utf8))
        }
        let runtime = makeRuntime()
        let request = APIRequest<[String: Bool]>(path: "api/protected")
        async let first = runtime.restClient.send(request)
        async let second = runtime.restClient.send(request)
        let results = try await [first, second]
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(URLProtocolStub.currentRefreshCount(), 1)
    }

    private func makeRuntime() -> LibreChatRuntime {
        let baseURL = URL(string: "https://chat.example.com")!
        let profile = ServerProfile(baseURL: baseURL, displayName: "Test")
        let jar = ProfileCookieJar(profileID: profile.id, baseURL: baseURL, secretStore: TestSecretStore())
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(baseURL: baseURL, session: URLSession(configuration: configuration), cookieJar: jar)
        let authentication = LibreChatProtocol.AuthSession.isolated(transport: transport)
        return LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: authentication,
            restClient: RESTClient(transport: transport, authSession: authentication)
        )
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}

private actor TestSecretStore: SecretStore {
    private var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var refreshCount = 0
    private static let countLock = NSLock()

    static func incrementRefreshCount() {
        countLock.lock(); defer { countLock.unlock() }
        refreshCount += 1
    }

    static func currentRefreshCount() -> Int {
        countLock.lock(); defer { countLock.unlock() }
        return refreshCount
    }

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
