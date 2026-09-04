import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

@Suite(.serialized)
struct HTTPTests {
    @Test func routeClassificationNeverExposesDynamicPathComponents() {
        #expect(ProtocolRoute.classify(path: "/librechat/api/auth/login") == .authenticationLogin)
        #expect(ProtocolRoute.classify(path: "/nested/librechat/api/auth/refresh") == .authenticationRefresh)
        #expect(ProtocolRoute.classify(path: "/librechat/api/messages/server-record-id") == .messages)
        #expect(ProtocolRoute.classify(path: "/librechat/api/messages/api") == .messages)
        #expect(ProtocolRoute.classify(path: "/librechat/api/files/download/account-id/file-id") == .files)
        #expect(ProtocolRoute.classify(path: "/librechat/health") == .health)
        #expect(ProtocolRoute.classify(path: "/unknown/account-id") == .other)
    }

    @Test func transportObservabilityUsesFiniteRouteAndAttemptValues() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            let attempt = ProtocolStub.increment()
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return (Self.response(request, 200), Data("{\"ok\":true}".utf8))
        }
        let recorder = ObservationRecorder()
        let runtime = makeRuntime(observability: ProtocolObservability(recorder.record))

        _ = try await runtime.restClient.send(APIRequest<[String: Bool]>(
            path: "api/messages/server-record-id",
            authorization: .none,
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))

        let events = recorder.events()
        #expect(events.contains(.transportStarted(route: .messages, method: .get, attempt: 1)))
        #expect(events.contains(.transportFailed(
            route: .messages,
            method: .get,
            attempt: 1,
            failure: .connectivity
        )))
        #expect(events.contains(.transportRetryScheduled(route: .messages, method: .get, nextAttempt: 2)))
        #expect(events.contains(.transportStarted(route: .messages, method: .get, attempt: 2)))
        #expect(events.contains(.transportResponded(route: .messages, method: .get, status: 200, attempt: 2)))
    }

    @Test func eventStreamObservabilityRecordsOnlyFiniteRouteAndStatus() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            (
                Self.response(request, 200),
                Data("event: message\ndata: {}\n\n".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolStub.self]
        let recorder = ObservationRecorder()
        let transport = URLSessionEventStreamTransport(
            session: URLSession(configuration: configuration),
            observability: ProtocolObservability(recorder.record)
        )
        let request = URLRequest(
            url: try #require(URL(string: "https://server.invalid/base/api/agents/chat/stream/private-coordinate"))
        )

        let stream = await transport.events(request: request)
        for try await _ in stream {}

        #expect(recorder.events() == [
            .eventStreamOpened(route: .generation, status: 200)
        ])
    }

    @Test func passwordLoginObservabilityRecordsOnlySemanticOutcome() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            (Self.response(request, 200), Data(#"{"token":"access-token","user":{"id":"user-record"}}"#.utf8))
        }
        let authenticatedRecorder = ObservationRecorder()
        let authenticatedRuntime = makeRuntime(
            observability: ProtocolObservability(authenticatedRecorder.record)
        )
        _ = try await authenticatedRuntime.authSession.login(email: "private@example.com", password: "secret")

        #expect(authenticatedRecorder.events().contains(.authenticationLoginStarted))
        #expect(authenticatedRecorder.events().contains(
            .authenticationLoginCompleted(outcome: .authenticated)
        ))
        #expect(authenticatedRecorder.events().contains(
            .authenticationCredentialRevisionChanged(reason: .authenticated, revision: 1)
        ))

        ProtocolStub.handler = { request in
            (Self.response(request, 200), Data(#"{"twoFAPending":true,"tempToken":"one-shot"}"#.utf8))
        }
        let twoFactorRecorder = ObservationRecorder()
        let twoFactorRuntime = makeRuntime(observability: ProtocolObservability(twoFactorRecorder.record))
        let result = try await twoFactorRuntime.authSession.login(email: "private@example.com", password: "secret")
        guard case .requiresTwoFactor = result else {
            Issue.record("Expected a two-factor challenge")
            return
        }
        #expect(twoFactorRecorder.events().contains(
            .authenticationLoginCompleted(outcome: .requiresTwoFactor)
        ))

        ProtocolStub.handler = { request in
            (Self.response(request, 401), Data(#"{"message":"private server text"}"#.utf8))
        }
        let rejectedRecorder = ObservationRecorder()
        let rejectedRuntime = makeRuntime(observability: ProtocolObservability(rejectedRecorder.record))
        do {
            _ = try await rejectedRuntime.authSession.login(email: "private@example.com", password: "secret")
            Issue.record("Expected login rejection")
        } catch {
            #expect(rejectedRecorder.events().contains(
                .authenticationLoginCompleted(outcome: .rejected)
            ))
        }
    }

    @Test func unverifiedEmailLoginMapsOnlyThePinned422SemanticWithoutAuthenticating() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            #expect(request.url?.path.hasSuffix("/api/auth/login") == true)
            return (
                Self.response(request, 422),
                Data(#"{"message":"Email not verified."}"#.utf8)
            )
        }
        let recorder = ObservationRecorder()
        let runtime = makeRuntime(observability: ProtocolObservability(recorder.record))

        do {
            _ = try await runtime.authSession.login(
                email: "private@example.com",
                password: "secret"
            )
            Issue.record("Expected verification requirement")
        } catch let error as AuthenticationLoginError {
            #expect(error == .emailVerificationRequired)
        }

        #expect(await runtime.authSession.user() == nil)
        #expect(recorder.events().contains(.authenticationLoginStarted))
        #expect(recorder.events().contains(
            .authenticationLoginCompleted(outcome: .rejected)
        ))

        ProtocolStub.handler = { request in
            (
                Self.response(request, 422),
                Data(#"{"message":"A different validation failure"}"#.utf8)
            )
        }
        do {
            _ = try await runtime.authSession.login(
                email: "private@example.com",
                password: "secret"
            )
            Issue.record("Expected generic 422 rejection")
        } catch let error as LibreChatProtocolError {
            guard case let .httpStatus(status, message, _) = error else {
                Issue.record("Expected an HTTP error")
                return
            }
            #expect(status == 422)
            #expect(message == "A different validation failure")
        }
    }

    @Test func idempotentRequestRetriesTransportOnce() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            let attempt = ProtocolStub.increment()
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return (Self.response(request, 200), Data("{\"ok\":true}".utf8))
        }
        let runtime = makeRuntime()
        let response = try await runtime.restClient.send(APIRequest<[String: Bool]>(
            path: "api/value",
            authorization: .none,
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))
        #expect(response["ok"] == true)
        #expect(ProtocolStub.count() == 2)
    }

    @Test func nonIdempotentRequestIsNotBlindlyRetried() async {
        ProtocolStub.reset()
        ProtocolStub.handler = { _ in
            _ = ProtocolStub.increment()
            throw URLError(.networkConnectionLost)
        }
        let runtime = makeRuntime()
        do {
            _ = try await runtime.restClient.send(APIRequest<[String: Bool]>(
                method: .post,
                path: "api/generate",
                authorization: .none,
                retryPolicy: .never
            ))
            Issue.record("Expected transport failure")
        } catch {
            #expect(ProtocolStub.count() == 1)
        }
    }

    @Test func nonIdempotent401IsNotReplayedAfterCredentialRefresh() async {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/auth/refresh" {
                _ = ProtocolStub.increment()
                return (
                    Self.response(request, 200),
                    Data(#"{"token":"fresh","user":{"id":"u"}}"#.utf8)
                )
            }
            _ = ProtocolStub.increment()
            return (Self.response(request, 401), Data(#"{"message":"expired"}"#.utf8))
        }
        let runtime = makeRuntime()
        await runtime.authSession.setAuthenticated(AuthenticatedSession(
            accessToken: "expired",
            user: UserAccount(id: .init(rawValue: "u"))
        ))

        do {
            _ = try await runtime.restClient.send(APIRequest<[String: Bool]>(
                method: .post,
                path: "api/agents",
                retryPolicy: .never
            ))
            Issue.record("Expected authorization failure")
        } catch let error as LibreChatProtocolError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(ProtocolStub.count() == 1)
    }

    @Test func retryAfterIsPreservedInHTTPError() async {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            (Self.response(request, 503, headers: ["Retry-After": "3"]), Data("{\"message\":\"warming up\"}".utf8))
        }
        do {
            _ = try await makeRuntime().restClient.send(APIRequest<[String: Bool]>(
                path: "api/value",
                authorization: .none,
                retryPolicy: .never
            ))
            Issue.record("Expected HTTP failure")
        } catch let LibreChatProtocolError.httpStatus(status, message, retryAfter) {
            #expect(status == 503)
            #expect(message == "warming up")
            #expect(retryAfter == 3)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func serverNotReadyIsDecodedAsAReadinessControl() async {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            (
                Self.response(request, 503, headers: ["Retry-After": "2"]),
                Data(#"{"code":"SERVER_NOT_READY","error":"Still starting"}"#.utf8)
            )
        }
        do {
            _ = try await makeRuntime().restClient.send(APIRequest<[String: Bool]>(
                path: "api/agents/chat/agents",
                authorization: .none,
                retryPolicy: .never
            ))
            Issue.record("Expected a readiness control error")
        } catch let LibreChatProtocolError.serverNotReady(retryAfter) {
            #expect(retryAfter == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func idempotentStatusRequestRetriesServerReadinessOnce() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            let attempt = ProtocolStub.increment()
            if attempt == 1 {
                return (
                    Self.response(request, 503, headers: ["Retry-After": "0"]),
                    Data(#"{"code":"SERVER_NOT_READY"}"#.utf8)
                )
            }
            return (Self.response(request, 200), Data(#"{"active":false}"#.utf8))
        }

        let response = try await makeRuntime().restClient.send(APIRequest<[String: Bool]>(
            path: "api/agents/chat/status/conversation",
            authorization: .none,
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))

        #expect(response["active"] == false)
        #expect(ProtocolStub.count() == 2)
    }

    @Test func predecessorMismatchPreservesGenerationCoordinates() async {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            let body = #"{"status":"predecessor_mismatch","code":"GENERATION_PREDECESSOR_MISMATCH","error":"A newer generation exists","streamId":"conversation","conversationId":"conversation","generationCreatedAt":2000,"predecessorVerified":true,"active":true,"generationProtocolVersion":2}"#
            return (Self.response(request, 409), Data(body.utf8))
        }
        do {
            _ = try await makeRuntime().restClient.send(APIRequest<[String: Bool]>(
                path: "api/agents/chat/agents",
                authorization: .none,
                retryPolicy: .never
            ))
            Issue.record("Expected a typed generation conflict")
        } catch let LibreChatProtocolError.generationConflict(details) {
            #expect(details.code == "GENERATION_PREDECESSOR_MISMATCH")
            #expect(details.status == "predecessor_mismatch")
            #expect(details.streamID == "conversation")
            #expect(details.conversationID == "conversation")
            #expect(details.generationCreatedAt == 2_000)
            #expect(details.predecessorVerified == true)
            #expect(details.active == true)
            #expect(details.generationProtocolVersion == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func concurrentAuthorizationMissesShareOneRefreshTask() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/auth/refresh" {
                _ = ProtocolStub.increment()
                Thread.sleep(forTimeInterval: 0.03)
                return (Self.response(request, 200), Data("{\"token\":\"fresh\",\"user\":{\"id\":\"u\"}}".utf8))
            }
            return (Self.response(request, 200), Data("{\"ok\":true}".utf8))
        }
        let runtime = makeRuntime()
        let request = APIRequest<[String: Bool]>(path: "api/protected")
        async let first = runtime.restClient.send(request)
        async let second = runtime.restClient.send(request)
        _ = try await [first, second]
        #expect(ProtocolStub.count() == 1)
    }

    @Test func simultaneous401ResponsesPerformExactlyOneRefresh() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/auth/refresh" {
                _ = ProtocolStub.increment()
                Thread.sleep(forTimeInterval: 0.03)
                return (Self.response(request, 200), Data("{\"token\":\"fresh\",\"user\":{\"id\":\"u\"}}".utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                return (Self.response(request, 401), Data("{\"message\":\"expired\"}".utf8))
            }
            return (Self.response(request, 200), Data("{\"ok\":true}".utf8))
        }
        let recorder = ObservationRecorder()
        let runtime = makeRuntime(observability: ProtocolObservability(recorder.record))
        await runtime.authSession.setAuthenticated(AuthenticatedSession(
            accessToken: "expired",
            user: UserAccount(id: .init(rawValue: "u"))
        ))
        let request = APIRequest<[String: Bool]>(path: "api/protected")
        async let first = runtime.restClient.send(request)
        async let second = runtime.restClient.send(request)
        _ = try await [first, second]
        #expect(ProtocolStub.count() == 1)
        #expect(recorder.count(.authenticationRefreshRequested) == 2)
        #expect(recorder.count(.authenticationRefreshCoalesced) == 1)
        #expect(recorder.count(.authenticationRefreshSucceeded) == 1)
        #expect(recorder.count(.authenticationRefreshFailed) == 0)
        #expect(recorder.count(
            .authorizationRecoveryStarted(route: .other, method: .get)
        ) == 2)
        #expect(recorder.count(
            .authorizationRecoveryCompleted(route: .other, method: .get, outcome: .succeeded)
        ) == 2)
        #expect(recorder.events().contains(
            .authenticationCredentialRevisionChanged(reason: .refreshed, revision: 2)
        ))
    }

    @Test func authorizedRawResponseRefreshesOnceAndUsesEncodedPathComponents() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/auth/refresh" {
                _ = ProtocolStub.increment()
                return (Self.response(request, 200), Data("{\"token\":\"fresh\",\"user\":{\"id\":\"u\"}}".utf8))
            }
            #expect(request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
            } == "/api/files/download/u/a%2Fb%20%25")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                return (Self.response(request, 401), Data())
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
            return (Self.response(request, 200), Data("bytes".utf8))
        }
        let runtime = makeRuntime()
        await runtime.authSession.setAuthenticated(AuthenticatedSession(
            accessToken: "expired",
            user: UserAccount(id: .init(rawValue: "u"))
        ))

        let response = try await runtime.restClient.rawResponse(
            method: .get,
            path: "ignored",
            pathComponents: ["api", "files", "download", "u", "a/b %"],
            authorized: true
        )

        #expect(response.data == Data("bytes".utf8))
        #expect(ProtocolStub.count() == 1)
    }

    @Test func authorizedDiskDownloadRefreshesOnceAndReturnsPrivateStagingBytes() async throws {
        ProtocolStub.reset()
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/auth/refresh" {
                _ = ProtocolStub.increment()
                return (Self.response(request, 200), Data("{\"token\":\"fresh\",\"user\":{\"id\":\"u\"}}".utf8))
            }
            #expect(request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
            } == "/api/files/download/u/a%2Fb%20%25")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/octet-stream")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired" {
                return (Self.response(request, 401), Data("unauthorized".utf8))
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
            return (
                Self.response(request, 200, headers: ["Content-Type": "application/pdf"]),
                Data("disk-backed-bytes".utf8)
            )
        }
        let runtime = makeRuntime()
        await runtime.authSession.setAuthenticated(AuthenticatedSession(
            accessToken: "expired",
            user: UserAccount(id: .init(rawValue: "u"))
        ))

        let response = try await runtime.restClient.downloadResponse(
            method: .get,
            path: "ignored",
            pathComponents: ["api", "files", "download", "u", "a/b %"],
            headers: ["Accept": "application/octet-stream"],
            authorized: true,
            retryPolicy: .never
        )
        defer { try? FileManager.default.removeItem(at: response.localURL) }

        #expect(response.localURL.lastPathComponent.contains("u") == false)
        #expect(try Data(contentsOf: response.localURL) == Data("disk-backed-bytes".utf8))
        #expect(response.headers["Content-Type"] == "application/pdf")
        #expect(ProtocolStub.count() == 1)
    }

    private func makeRuntime(
        observability: ProtocolObservability = .disabled
    ) -> LibreChatRuntime {
        let url = URL(string: "https://chat.example.com")!
        let jar = ProfileCookieJar(
            profileID: .init(rawValue: "test"),
            baseURL: url,
            secretStore: MemorySecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: url,
            session: URLSession(configuration: configuration),
            cookieJar: jar,
            observability: observability
        )
        let auth = AuthSession(transport: transport, observability: observability)
        return LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: auth,
            restClient: RESTClient(
                transport: transport,
                authSession: auth,
                observability: observability
            )
        )
    }

    private static func response(_ request: URLRequest, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

private final class ObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProtocolObservationEvent] = []

    func record(_ event: ProtocolObservationEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func events() -> [ProtocolObservationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func count(_ event: ProtocolObservationEvent) -> Int {
        events().count(where: { $0 == event })
    }
}

private final class ProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requestCount = 0
        handler = nil
    }

    static func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        requestCount += 1
        return requestCount
    }

    static func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
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
