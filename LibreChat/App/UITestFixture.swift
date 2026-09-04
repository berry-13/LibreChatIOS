#if DEBUG
import Foundation
import LibreChatDomain
import LibreChatProtocol

/// Deterministic, process-local data for UI tests. This type is only compiled
/// into Debug builds and is reachable only through `-ui-test-fixtures`.
@MainActor
struct UITestFixture {
    let profile: ServerProfile
    let session: AuthenticatedSession

    static let standard: UITestFixture = {
        let profile = ServerProfile(
            id: ServerProfileID(rawValue: "ui-test-profile"),
            baseURL: URL(string: "https://ui-test.invalid")!,
            displayName: "UI Test Server",
            accountIdentifier: AccountID(rawValue: "ui-test-account"),
            trustPolicy: .system
        )
        let user = UserAccount(
            id: AccountID(rawValue: "ui-test-account"),
            name: "UI Test User",
            role: "USER"
        )
        return UITestFixture(
            profile: profile,
            session: AuthenticatedSession(accessToken: "ui-test-token", user: user)
        )
    }()

    static func runtime(profile: ServerProfile, cache: CacheCoordinator) -> ProfileRuntime {
        let secrets = UITestFixtureSecretStore()
        let cookieJar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: profile.baseURL,
            secretStore: secrets
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.protocolClasses = [UITestFixtureURLProtocol.self]
        let transport = HTTPTransport(
            baseURL: profile.baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: cookieJar
        )
        let authSession = AuthSession(transport: transport)
        let restClient = RESTClient(transport: transport, authSession: authSession)
        let runtime = LibreChatRuntime(
            cookieJar: cookieJar,
            transport: transport,
            authSession: authSession,
            restClient: restClient
        )
        let repository = LibreChatRepository(profile: profile, runtime: runtime, cache: cache)
        return ProfileRuntime(profile: profile, protocolRuntime: runtime, repository: repository)
    }
}

private actor UITestFixtureSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) async throws -> Data? { values[key] }
    func set(_ data: Data, for key: String) async throws { values[key] = data }
    func remove(_ key: String) async throws { values.removeValue(forKey: key) }
}

/// A URLProtocol with an allowlist of static local responses. Unhandled paths
/// return a local 404; no request can escape to a real server.
private final class UITestFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// The loading system hands custom protocols a request whose `httpBody`
    /// was converted into a one-shot `httpBodyStream`; materialize it back so
    /// fixture handlers can keep reading `httpBody`.
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
        let payload = UITestFixtureResponse.payload(for: request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://ui-test.invalid")!,
            statusCode: payload.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": payload.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum UITestFixtureResponse {
    private static let fileState = UITestFixtureFileState()
    private static let agentState = UITestFixtureAgentState()

    struct Payload {
        let statusCode: Int
        let data: Data
        let contentType: String

        init(statusCode: Int, data: Data, contentType: String = "application/json") {
            self.statusCode = statusCode
            self.data = data
            self.contentType = contentType
        }
    }

    static func payload(for request: URLRequest) -> Payload {
        let path = request.url?.path ?? ""
        if request.httpMethod == "DELETE", path == "/api/files" {
            fileState.deleteBudgetFile()
            return success(["message": "Files deleted successfully"])
        }
        if request.httpMethod == "POST", path == "/api/presets",
           let data = request.httpBody,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Echo only the small native-safe shape. This keeps the UI fixture
            // honest: accidental default/order/tool fields are not needed to
            // make the create flow pass.
            let allowedKeys = [
                "presetId", "title", "endpoint", "endpointType", "model",
                "agent_id", "assistant_id", "spec", "promptPrefix"
            ]
            let response = Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
                body[key].map { (key, $0) }
            })
            return Payload(statusCode: 201, data: json(response))
        }
        if request.httpMethod == "POST", path == "/api/agents",
           let data = request.httpBody,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = body["name"] as? String,
           let provider = body["provider"] as? String,
           let model = body["model"] as? String,
           body["tools"] as? [String] == [] {
            let created: [String: Any] = [
                "id": "agent_fixture_created",
                "_id": "507f1f77bcf86cd799439011",
                "name": name,
                "description": body["description"] as? String ?? "",
                "category": body["category"] as? String ?? "",
                "provider": provider,
                "model": model,
                "isEditable": true
            ]
            agentState.install(created)
            return Payload(statusCode: 201, data: json(created))
        }
        return switch path {
        case "/api/auth/refresh":
            success([
                "token": "ui-test-token",
                "user": [
                    "_id": "ui-test-account",
                    "name": "UI Test User",
                    "role": "USER"
                ]
            ])
        case "/api/config":
            success([
                "appTitle": "LibreChat UI Tests",
                "emailLoginEnabled": true,
                "endpoints": [
                    "openAI": ["type": "openAI", "name": "OpenAI"],
                    "agents": ["type": "agents", "name": "Agents"]
                ],
                "interface": [
                    "modelSelect": true,
                    "presets": true,
                    "temporaryChat": true,
                    "temporaryChatRetention": 24
                ]
            ])
        case "/api/roles/USER":
            success([
                "name": "USER",
                "permissions": [
                    "TEMPORARY_CHAT": ["USE": true],
                    "AGENTS": ["USE": true, "CREATE": true]
                ]
            ])
        case "/api/endpoints":
            success([
                "openAI": ["type": "openAI", "name": "OpenAI"],
                "agents": ["type": "agents", "name": "Agents", "disableBuilder": false]
            ])
        case "/api/models":
            success(["openAI": ["fixture-model", "fixture-model-2"]])
        case "/api/presets":
            success([
                [
                    "presetId": "preset-fixture",
                    "title": "Research mode",
                    "defaultPreset": true,
                    "endpoint": "openAI",
                    "model": "fixture-model-2",
                    "promptPrefix": "Use concise primary-source citations."
                ],
                [
                    "presetId": "preset-blocked",
                    "title": "Unsupported tuning",
                    "endpoint": "openAI",
                    "model": "fixture-model",
                    "temperature": 0.2
                ]
            ])
        case "/api/agents":
            success(agentState.catalog())
        case "/api/convos":
            success([conversation])
        case "/api/convos/fixture-conversation":
            success(conversation)
        case "/api/messages":
            success([
                "messages": [searchResult],
                "nextCursor": NSNull()
            ])
        case "/api/messages/fixture-conversation":
            success(history)
        case "/api/files/file-fixture-budget/preview":
            success([
                "file_id": "file-fixture-budget",
                "status": "ready",
                "text": "Budget preview fixture",
                "textFormat": "text"
            ])
        case "/api/files/download/ui-test-account/file-fixture-budget":
            Payload(
                statusCode: 200,
                data: Data("fixture pdf bytes".utf8),
                contentType: "application/octet-stream"
            )
        case "/api/files":
            success(fileState.catalog)
        case "/api/agents/chat/active":
            success(["activeJobIds": []])
        default:
            Payload(statusCode: 404, data: json(["message": "No UI test fixture for this route."]))
        }
    }

    private static var budgetFile: [String: Any] {
        [
                    "file_id": "file-fixture-budget",
                    "filename": "Budget.pdf",
                    "filepath": "/fixture/budget.pdf",
                    "bytes": 2_048,
                    "type": "application/pdf",
                    "context": "message_attachment",
                    "source": "s3",
                    "embedded": true,
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-02T00:00:00Z"
        ]
    }

    private static var photoFile: [String: Any] {
        [
                    "file_id": "file-fixture-photo",
                    "filename": "Reference photo.jpg",
                    "filepath": "/fixture/reference-photo.jpg",
                    "bytes": 4_096,
                    "type": "image/jpeg",
                    "context": "message_attachment",
                    "source": "local",
                    "embedded": false,
                    "width": 800,
                    "height": 600,
                    "createdAt": "2026-01-03T00:00:00Z",
                    "updatedAt": "2026-01-03T00:00:00Z"
        ]
    }

    private static var history: [[String: Any]] {
        var messages = (1...20).map { message(index: $0) }
        messages.append([
            "messageId": "fixture-search-branch-user",
            "conversationId": "fixture-conversation",
            "parentMessageId": "fixture-message-20",
            "text": "Alternate branch question",
            "sender": "User",
            "isCreatedByUser": true,
            "endpoint": "openAI",
            "model": "fixture-model",
            "createdAt": "2026-01-01T00:00:00Z"
        ])
        messages.append(searchResult)
        messages.append(contentsOf: (21...80).map { message(index: $0) })
        return messages
    }

    private static func message(index: Int) -> [String: Any] {
            var message: [String: Any] = [
                "messageId": "fixture-message-\(index)",
                "conversationId": "fixture-conversation",
                "text": index == 78
                    ? """
                    Fixture message 078
                    :::artifact{identifier="fixture-notes" type="text/markdown" title="Fixture artifact"}
                    # Native artifact workspace
                    This stays native and readable.
                    :::
                    """
                    : String(format: "Fixture message %03d", index),
                "sender": index.isMultiple(of: 2) ? "Assistant" : "User",
                "isCreatedByUser": !index.isMultiple(of: 2),
                "endpoint": "openAI",
                "model": "fixture-model",
                "createdAt": "2026-01-01T00:00:00Z"
            ]
            if index > 1 {
                message["parentMessageId"] = "fixture-message-\(index - 1)"
            }
            return message
    }

    private static var searchResult: [String: Any] {
        [
            "messageId": "fixture-search-match",
            "conversationId": "fixture-conversation",
            "parentMessageId": "fixture-search-branch-user",
            "title": "Fixture conversation",
            "text": "Exact branch search match",
            "sender": "Assistant",
            "isCreatedByUser": false,
            "endpoint": "openAI",
            "model": "fixture-model",
            "createdAt": "2026-01-01T00:00:00Z"
        ]
    }

    private static var conversation: [String: Any] {
        [
            "conversationId": "fixture-conversation",
            "title": "Fixture conversation",
            "endpoint": "openAI",
            "endpointType": "openAI",
            "model": "fixture-model",
            "updatedAt": "2026-01-01T00:00:00Z",
            "isArchived": false
        ]
    }

    private static func success(_ value: Any) -> Payload {
        Payload(statusCode: 200, data: json(value))
    }

    private static func json(_ value: Any) -> Data {
        // All values are source-controlled literals, so serialization failure
        // is a test fixture programming error rather than runtime input.
        try! JSONSerialization.data(withJSONObject: value, options: [])
    }

    private final class UITestFixtureFileState: @unchecked Sendable {
        private let lock = NSLock()
        private var budgetWasDeleted = false

        var catalog: [[String: Any]] {
            lock.withLock {
                budgetWasDeleted ? [photoFile] : [budgetFile, photoFile]
            }
        }

        func deleteBudgetFile() {
            lock.withLock { budgetWasDeleted = true }
        }
    }

    private final class UITestFixtureAgentState: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [String: Any]?

        func install(_ agent: [String: Any]) {
            lock.withLock { created = agent }
        }

        func catalog() -> [String: Any] {
            lock.withLock {
                var rows: [[String: Any]] = [[
                    "id": "agent_fixture_existing",
                    "_id": "507f1f77bcf86cd799439010",
                    "name": "Fixture analyst",
                    "description": "Existing deterministic saved agent",
                    "provider": "openAI",
                    "model": "fixture-model",
                    "isEditable": true
                ]]
                if let created { rows.insert(created, at: 0) }
                return ["data": rows, "has_more": false]
            }
        }
    }
}
#endif
