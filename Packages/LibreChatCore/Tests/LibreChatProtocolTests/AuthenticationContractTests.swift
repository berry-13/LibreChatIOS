import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

/// Contract tests for the authentication endpoints in the pinned LibreChat
/// deployment. These intentionally assert the wire contract (verb, path,
/// request keys and the empty-200 responses), rather than only testing that a
/// Codable value happens to decode.
@Suite(.serialized)
struct AuthenticationContractTests {
    @Test func twoFactorSetupUsesPostAndDecodesCamelCaseResponse() async throws {
        AuthContractStub.reset()
        AuthContractStub.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/2fa/enable")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
            return Self.response(request, 200, body: "{\"otpauthUrl\":\"otpauth://totp/LibreChat:test\",\"backupCodes\":[\"A1\",\"B2\"]}")
        }

        let runtime = makeRuntime()
        await authenticate(runtime)
        let setup = try await runtime.authSession.beginTwoFactorSetup()

        #expect(setup.otpauthURL?.absoluteString == "otpauth://totp/LibreChat:test")
        #expect(setup.backupCodes == ["A1", "B2"])
    }

    @Test func twoFactorVerificationAndConfirmationUseTwoEmptyPostResponses() async throws {
        AuthContractStub.reset()
        AuthContractStub.handler = { request in
            #expect(request.httpMethod == "POST")
            let requestNumber = AuthContractStub.increment()
            #expect(request.url?.path == (requestNumber == 1 ? "/api/auth/2fa/verify" : "/api/auth/2fa/confirm"))
            #expect(Self.jsonObject(request)["token"] as? String == "123456")
            return Self.response(request, 200)
        }

        let runtime = makeRuntime()
        await authenticate(runtime)
        _ = try await runtime.authSession.confirmTwoFactorSetup(code: "123456")
        #expect(AuthContractStub.count() == 2)
    }

    @Test func twoFactorDisableSendsVerificationTokenNotPasswordKey() async throws {
        AuthContractStub.reset()
        AuthContractStub.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/2fa/disable")
            let json = Self.jsonObject(request)
            #expect(json["token"] as? String == "123456")
            #expect(json["password"] == nil)
            return Self.response(request, 200)
        }

        let runtime = makeRuntime()
        await authenticate(runtime)
        try await runtime.authSession.disableTwoFactor(proof: .authenticatorCode("123456"))
    }

    @Test func backupRegenerationUsesBackupSubrouteAndVerificationToken() async throws {
        AuthContractStub.reset()
        AuthContractStub.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/2fa/backup/regenerate")
            let json = Self.jsonObject(request)
            #expect(json["token"] as? String == "123456")
            #expect(json["password"] == nil)
            return Self.response(request, 200, body: "{\"backupCodes\":[\"C3\"],\"backupCodesHash\":\"redacted\"}")
        }

        let runtime = makeRuntime()
        await authenticate(runtime)
        let codes = try await runtime.authSession.regenerateBackupCodes(proof: .authenticatorCode("123456"))
        #expect(codes == ["C3"])
    }

    @Test func refreshPlainTextSuccessIsClassifiedAsUnauthorized() async {
        AuthContractStub.reset()
        AuthContractStub.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/auth/refresh")
            return Self.response(request, 200, headers: ["Content-Type": "text/plain"], body: "Refresh token not provided")
        }

        do {
            _ = try await makeRuntime().authSession.refresh()
            Issue.record("Expected refresh without a cookie to be unauthorized")
        } catch let error as LibreChatProtocolError {
            #expect(error == .unauthorized)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeRuntime() -> LibreChatRuntime {
        let url = URL(string: "https://chat.example.com")!
        let jar = ProfileCookieJar(
            profileID: .init(rawValue: "auth-contract"),
            baseURL: url,
            secretStore: MemorySecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthContractStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(baseURL: url, session: URLSession(configuration: configuration), cookieJar: jar)
        let auth = AuthSession(transport: transport)
        return LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: auth,
            restClient: RESTClient(transport: transport, authSession: auth)
        )
    }

    private func authenticate(_ runtime: LibreChatRuntime) async {
        await runtime.authSession.setAuthenticated(AuthenticatedSession(
            accessToken: "access",
            user: UserAccount(id: .init(rawValue: "u"))
        ))
    }

    private static func response(
        _ request: URLRequest,
        _ status: Int,
        headers: [String: String] = [:],
        body: String = ""
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!,
            Data(body.utf8)
        )
    }

    private static func jsonObject(_ request: URLRequest) -> [String: Any] {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(readAll)
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            Issue.record("Expected a JSON request body")
            return [:]
        }
        return object
    }

    private static func readAll(from stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class AuthContractStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        requestCount = 0
        lock.unlock()
    }

    static func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        requestCount += 1
        return requestCount
    }

    static func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
