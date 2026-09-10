import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class AppModelSelectionTests: XCTestCase {
    func testEmailLoginSurfaceFollowsAnonymousServerCapability() async throws {
        SelectionURLProtocol.resetRequests()

        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)

        await model.select(profile: Self.profile(id: "profile-no-email", host: "no-email.example"))

        XCTAssertFalse(model.canUseEmailLogin)
        XCTAssertFalse(model.canRequestPasswordReset)
        XCTAssertFalse(model.canResendEmailVerification)
        XCTAssertEqual(model.browserAuthenticationMethods, [.google])
    }

    func testNativeRegistrationRequiresServerEnablementWithoutWebChallenge() async throws {
        SelectionURLProtocol.resetRequests()
        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)

        await model.select(profile: Self.profile(id: "profile-native-registration", host: "native-register.example"))

        XCTAssertTrue(model.canUseEmailLogin)
        XCTAssertTrue(model.canRegisterAccount)
        XCTAssertTrue(model.canResendEmailVerification)
        XCTAssertFalse(model.registrationRequiresBrowserChallenge)
        XCTAssertEqual(model.registrationMinimumPasswordLength, 14)

        await model.select(profile: Self.profile(id: "profile-web-registration", host: "web-register.example"))

        XCTAssertFalse(model.canRegisterAccount)
        XCTAssertTrue(model.registrationRequiresBrowserChallenge)
    }

    func testVerificationResendRequiresAdvertisedEmailDeliveryAndUsesActiveProfile() async throws {
        SelectionURLProtocol.resetRequests()
        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)

        await model.select(profile: Self.profile(id: "profile-native-registration", host: "native-register.example"))
        let result = try await model.resendEmailVerification(email: "person@example.com")

        XCTAssertEqual(result.notice.message, "Check your email")
        XCTAssertEqual(
            SelectionURLProtocol.requestRecords().filter { $0.path == "/api/user/verify/resend" }.count,
            1
        )

        await model.select(profile: Self.profile(id: "profile-no-email", host: "no-email.example"))
        do {
            _ = try await model.resendEmailVerification(email: "person@example.com")
            XCTFail("A server without email delivery must fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected a capability error, got \(error)")
            }
        }
        XCTAssertEqual(
            SelectionURLProtocol.requestRecords().filter { $0.path == "/api/user/verify/resend" }.count,
            1,
            "The unavailable profile must not dispatch a resend"
        )
    }

    func testLaterProfileSelectionWinsWhenEarlierRestoreCompletesLast() async throws {
        let control = SelectionRequestControl(blockedHost: "a.example")
        SelectionURLProtocol.control = control
        SelectionURLProtocol.resetRequests()
        defer { SelectionURLProtocol.control = nil }

        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)
        let firstProfile = Self.profile(id: "profile-a", host: "a.example")
        let laterProfile = Self.profile(id: "profile-b", host: "b.example")

        let firstSelection = Task { await model.select(profile: firstProfile) }
        guard await control.waitUntilBlocked() else {
            control.releaseBlockedRequest()
            await firstSelection.value
            return XCTFail("The first profile did not reach the controllable discovery gate")
        }

        let laterSelection = Task { await model.select(profile: laterProfile) }
        for _ in 0..<1_000 {
            if model.phase == .signedIn, model.user?.id == AccountID(rawValue: "account-b.example") {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.selectedServer?.id, laterProfile.id)
        XCTAssertEqual(model.user?.id, AccountID(rawValue: "account-b.example"))

        control.releaseBlockedRequest()
        await firstSelection.value
        await laterSelection.value

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.selectedServer?.id, laterProfile.id)
        XCTAssertEqual(model.selectedServer?.accountIdentifier, AccountID(rawValue: "account-b.example"))
        XCTAssertEqual(model.user?.id, AccountID(rawValue: "account-b.example"))

        guard let repository = model.repository else {
            return XCTFail("The later profile should leave an active repository")
        }
        _ = try await repository.conversations()
        let conversationRequestHosts = SelectionURLProtocol.requestRecords()
            .filter { $0.path == "/api/convos" }
            .map(\.host)
        XCTAssertEqual(conversationRequestHosts, ["b.example"])
    }

    func testAvatarUploadCannotCommitIntoAProfileSelectedWhileUploadIsSuspended() async throws {
        let control = SelectionRequestControl(
            blockedHost: "avatar-switch-a.example",
            blockedPath: "/api/files/images/avatar"
        )
        SelectionURLProtocol.control = control
        SelectionURLProtocol.setAvatarMode(.success)
        SelectionURLProtocol.resetRequests()
        defer {
            control.releaseBlockedRequest()
            SelectionURLProtocol.control = nil
            SelectionURLProtocol.setAvatarMode(.success)
        }

        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)
        let firstProfile = Self.profile(id: "avatar-profile-a", host: "avatar-switch-a.example")
        let secondProfile = Self.profile(id: "avatar-profile-b", host: "avatar-switch-b.example")
        await model.select(profile: firstProfile)
        XCTAssertEqual(model.phase, .signedIn)

        let uploadTask = Task { @MainActor in
            try await model.uploadAccountAvatar(Self.testPNG)
        }
        guard await control.waitUntilBlocked() else {
            control.releaseBlockedRequest()
            _ = try? await uploadTask.value
            return XCTFail("Avatar upload did not reach its controllable POST")
        }

        await model.select(profile: secondProfile)
        XCTAssertEqual(model.selectedServer?.id, secondProfile.id)
        XCTAssertEqual(model.user?.id, AccountID(rawValue: "account-avatar-switch-b.example"))

        control.releaseBlockedRequest()
        do {
            _ = try await uploadTask.value
            XCTFail("A profile switch must fence the suspended upload")
        } catch is CancellationError {
            // Expected: AppModel's selection epoch rejects the old runtime.
        }

        let oldAccount = try await dependencies.cache.lastVerifiedAccount(
            profileID: firstProfile.id,
            accountID: AccountID(rawValue: "account-avatar-switch-a.example")
        )
        XCTAssertEqual(oldAccount?.avatarURL?.path, "/images/old.png")
        let newAccount = try await dependencies.cache.lastVerifiedAccount(
            profileID: secondProfile.id,
            accountID: AccountID(rawValue: "account-avatar-switch-b.example")
        )
        // The suspended upload's result must never appear on the newly
        // selected profile: its account keeps its own pre-upload avatar.
        XCTAssertEqual(newAccount?.avatarURL?.host, "avatar-switch-b.example")
        XCTAssertEqual(newAccount?.avatarURL?.path, "/images/old.png")
    }

    func testUnchangedAuthoritativeAvatarLeavesAppStateAndCacheUntouched() async throws {
        SelectionURLProtocol.resetRequests()
        SelectionURLProtocol.setAvatarMode(.lost)
        defer { SelectionURLProtocol.setAvatarMode(.success) }

        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)
        let profile = Self.profile(id: "avatar-unchanged", host: "avatar-unchanged.example")
        await model.select(profile: profile)
        let prior = try XCTUnwrap(model.user)
        let result = try await dependencies.cache.lastVerifiedAccount(
            profileID: profile.id,
            accountID: prior.id
        )
        XCTAssertEqual(result, prior)

        do {
            _ = try await model.uploadAccountAvatar(Self.testPNG)
            XCTFail("An unchanged authoritative avatar must not be reported as success")
        } catch let error as AccountProfileError {
            XCTAssertEqual(error, .avatarOutcomeUnknown)
        }

        XCTAssertEqual(model.user, prior)
        let cachedPrior = try await dependencies.cache.lastVerifiedAccount(
            profileID: profile.id,
            accountID: prior.id
        )
        XCTAssertEqual(
            cachedPrior,
            prior
        )
        XCTAssertEqual(
            SelectionURLProtocol.requestRecords().filter { $0.path == "/api/files/images/avatar" }.count,
            1
        )
    }

    func testConfirmedAvatarReconciliationPersistsOnlyTheAuthoritativeAccount() async throws {
        SelectionURLProtocol.resetRequests()
        SelectionURLProtocol.setAvatarMode(.success)

        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)
        let profile = Self.profile(id: "avatar-confirmed", host: "avatar-confirmed.example")
        await model.select(profile: profile)
        let oldAccount = try XCTUnwrap(model.user)

        let confirmed = try await model.uploadAccountAvatar(Self.testPNG)

        XCTAssertEqual(confirmed.avatarURL?.path, "/images/new.png")
        XCTAssertNotEqual(confirmed.avatarURL, oldAccount.avatarURL)
        XCTAssertEqual(model.user, confirmed)
        let cachedConfirmed = try await dependencies.cache.lastVerifiedAccount(
            profileID: profile.id,
            accountID: confirmed.id
        )
        XCTAssertEqual(
            cachedConfirmed,
            confirmed
        )
    }

    func testSignOutClearsForegroundRecoverySignalBeforeSameProfileRelogin() async throws {
        SelectionURLProtocol.resetRequests()
        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)
        let profile = Self.profile(id: "profile-relogin", host: "relogin.example")
        await model.select(profile: profile)
        XCTAssertEqual(model.phase, .signedIn)

        await model.applicationBecameActive()
        for _ in 0..<250 {
            if model.generationRecoverySignal != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.generationRecoverySignal)

        await model.applicationBecameInactive()
        XCTAssertNil(model.generationRecoverySignal)

        await model.applicationBecameActive()
        for _ in 0..<250 {
            if model.generationRecoverySignal != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.generationRecoverySignal)

        await model.signOut()
        XCTAssertNil(model.generationRecoverySignal)

        await model.select(profile: profile)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertNil(model.generationRecoverySignal)
    }

    func testAuthenticatedPolicyFailureHidesFeaturesUntilExplicitRefreshSucceeds() async throws {
        SelectionURLProtocol.resetRequests()
        SelectionURLProtocol.setPolicyRefreshSucceeds(false)
        defer { SelectionURLProtocol.setPolicyRefreshSucceeds(false) }

        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let model = AppModel(dependencies: dependencies)
        let profile = Self.profile(id: "profile-policy", host: "policy-fail.example")

        await model.select(profile: profile)

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertTrue(model.authenticatedServerPolicyUnavailable)
        XCTAssertEqual(model.selectedServer?.capabilities?.authenticatedPolicyVerified, false)
        XCTAssertFalse(model.selectedServer?.capabilities?.supportsAgents == true)
        XCTAssertFalse(model.canBrowseMCPConnections)
        XCTAssertFalse(model.canBrowseMemories)
        XCTAssertTrue(model.notice?.contains("account features could not be verified") == true)

        SelectionURLProtocol.setPolicyRefreshSucceeds(true)
        await model.refreshAuthenticatedServerPolicy()

        XCTAssertFalse(model.authenticatedServerPolicyUnavailable)
        XCTAssertEqual(model.selectedServer?.capabilities?.authenticatedPolicyVerified, true)
        XCTAssertTrue(model.selectedServer?.capabilities?.supportsAgents == true)
        XCTAssertNil(model.notice)
        XCTAssertEqual(
            SelectionURLProtocol.requestRecords().count(where: {
                $0.host == "policy-fail.example" && $0.path == "/api/config"
            }),
            3,
            "Anonymous discovery, the failed authenticated refresh, and the manual refresh must remain three distinct policy reads."
        )
    }

    func testSessionRestorationReconcilesReservedFollowUpBeforeActiveDiscovery() async throws {
        SelectionURLProtocol.resetRequests()
        let dependencies = try AppDependencies(
            inMemory: true,
            profileRuntimeFactory: { profile, cache in
                Self.makeRuntime(profile: profile, cache: cache)
            }
        )
        let profile = Self.profile(id: "profile-queue-recovery", host: "queue-recovery.example")
        let accountID = AccountID(rawValue: "account-queue-recovery.example")
        let conversationID = ConversationID(rawValue: "conversation")
        let namespace = try FollowUpQueueNamespace(
            profileID: profile.id,
            accountID: accountID,
            conversationID: conversationID
        )
        let sourceHandle = GenerationHandle(
            profileID: profile.id,
            accountID: accountID,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            streamID: conversationID.rawValue,
            conversationID: conversationID,
            generationCreatedAt: 1_000,
            protocolVersion: 2
        )
        let item = try FollowUpQueueItem(
            id: FollowUpQueueItemID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
            ),
            namespace: namespace,
            order: FollowUpQueueOrder(rawValue: 1),
            text: "Queued proof",
            target: FollowUpTargetFingerprint(
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            sourceAnchor: FollowUpSourceAnchor(
                handle: sourceHandle,
                sourceUserMessageID: MessageID(rawValue: "source-user")
            )
        )
        try await dependencies.cache.saveFollowUpQueue(
            FollowUpQueueSnapshot(namespace: namespace, items: [item])
        )
        let reserved = try await dependencies.cache.mutateFollowUpQueue(
            namespace: namespace
        ) { reducer in
            try reducer.reserveNext(
                after: .completed(
                    handle: sourceHandle,
                    responseMessageID: MessageID(rawValue: "assistant-source")
                ),
                attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
                clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
                clientMessageID: MessageID(rawValue: "queued-user-proof")
            )
        }
        let attempt = try XCTUnwrap(reserved.result)

        let model = AppModel(dependencies: dependencies)
        await model.select(profile: profile)
        for _ in 0..<1_000 {
            let snapshot = try await dependencies.cache.followUpQueue(namespace: namespace)
            if case .admitted = snapshot.items.first?.state { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        let snapshot = try await dependencies.cache.followUpQueue(namespace: namespace)
        guard case let .admitted(savedAttempt, handle) = snapshot.items.first?.state else {
            return XCTFail("Session restoration should recover the exact queued admission")
        }
        XCTAssertEqual(savedAttempt, attempt)
        XCTAssertEqual(handle.clientRequestID, attempt.clientRequestID)
        XCTAssertEqual(handle.generationCreatedAt, 2_000)
        for _ in 0..<1_000 {
            if SelectionURLProtocol.requestRecords().contains(where: {
                $0.path == "/api/agents/chat/active"
            }) { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let paths = SelectionURLProtocol.requestRecords().map(\.path)
        let statusIndex = try XCTUnwrap(paths.firstIndex(of: "/api/agents/chat/status/conversation"))
        let activeIndex = try XCTUnwrap(paths.firstIndex(of: "/api/agents/chat/active"))
        XCTAssertLessThan(statusIndex, activeIndex)
    }

    private static func profile(id: String, host: String) -> ServerProfile {
        ServerProfile(
            id: ServerProfileID(rawValue: id),
            baseURL: URL(string: "https://\(host)")!,
            displayName: host
        )
    }

    private static func makeRuntime(profile: ServerProfile, cache: CacheCoordinator) -> ProfileRuntime {
        let cookieJar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: profile.baseURL,
            secretStore: SelectionSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelectionURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let transport = HTTPTransport(
            baseURL: profile.baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: cookieJar
        )
        let authSession = AuthSession.isolated(transport: transport)
        let runtime = LibreChatRuntime(
            cookieJar: cookieJar,
            transport: transport,
            authSession: authSession,
            restClient: RESTClient(transport: transport, authSession: authSession)
        )
        return ProfileRuntime(
            profile: profile,
            protocolRuntime: runtime,
            repository: LibreChatRepository(profile: profile, runtime: runtime, cache: cache)
        )
    }

    private static let testPNG = AccountAvatarUpload(
        data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01]),
        mimeType: "image/png"
    )
}

private final class SelectionRequestControl: @unchecked Sendable {
    private let blockedHost: String
    private let blockedPath: String
    private let condition = NSCondition()
    private var didBlock = false
    private var isReleased = false

    init(blockedHost: String, blockedPath: String = "/api/config") {
        self.blockedHost = blockedHost
        self.blockedPath = blockedPath
    }

    func waitIfNeeded(host: String, path: String) {
        guard host == blockedHost, path == blockedPath else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !didBlock else { return }
        didBlock = true
        condition.broadcast()
        while !isReleased {
            condition.wait()
        }
    }

    func waitUntilBlocked() async -> Bool {
        for _ in 0..<5_000 {
            if condition.withLock({ didBlock }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition.withLock { didBlock }
    }

    func releaseBlockedRequest() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }
}

private final class SelectionURLProtocol: URLProtocol {
    enum AvatarMode: Sendable, Equatable {
        case success
        case lost
    }

    struct RequestRecord: Equatable {
        let host: String
        let path: String
    }

    nonisolated(unsafe) static var control: SelectionRequestControl?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var records: [RequestRecord] = []
    nonisolated(unsafe) private static var policyRefreshSucceeds = false
    nonisolated(unsafe) private static var avatarMode: AvatarMode = .success

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.records.append(RequestRecord(host: host, path: url.path)) }
        let control = Self.control
        let request = request
        let responder = SelectionURLProtocolResponder(protocol: self)
        DispatchQueue.global(qos: .userInitiated).async {
            control?.waitIfNeeded(host: host, path: url.path)
            if request.httpMethod == "POST",
               url.path == "/api/files/images/avatar",
               Self.lock.withLock({ Self.avatarMode == .lost }) {
                responder.fail(error: URLError(.networkConnectionLost))
                return
            }
            let (response, data) = Self.response(host: host, path: url.path, request: request)
            responder.finish(response: response, data: data)
        }
    }

    override func stopLoading() {}

    static func resetRequests() {
        lock.withLock { records.removeAll() }
    }

    static func requestRecords() -> [RequestRecord] {
        lock.withLock { records }
    }

    static func setPolicyRefreshSucceeds(_ succeeds: Bool) {
        lock.withLock { policyRefreshSucceeds = succeeds }
    }

    static func setAvatarMode(_ mode: AvatarMode) {
        lock.withLock { avatarMode = mode }
    }

    private static func response(
        host: String,
        path: String,
        request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let status: Int
        let body: String
        switch path {
        case "/api/config":
            if host == "policy-fail.example",
               request.value(forHTTPHeaderField: "Authorization") != nil,
               !lock.withLock({ policyRefreshSucceeds }) {
                status = 500
                body = #"{"error":"temporary policy failure"}"#
            } else if host == "no-email.example" {
                status = 200
                body = #"{"emailLoginEnabled":false,"passwordResetEnabled":true,"googleLoginEnabled":true}"#
            } else if host == "native-register.example" {
                status = 200
                body = #"{"emailLoginEnabled":true,"registrationEnabled":true,"emailEnabled":true,"minPasswordLength":14}"#
            } else if host == "web-register.example" {
                status = 200
                body = #"{"emailLoginEnabled":true,"registrationEnabled":true,"turnstile":{"siteKey":"public-site-key"}}"#
            } else {
                status = 200
                body = "{}"
            }
        case "/api/endpoints" where host == "policy-fail.example":
            status = 200
            body = #"{"agents":{"disableBuilder":false}}"#
        case "/api/auth/mobile/config":
            status = 404
            body = "{}"
        case "/api/auth/refresh":
            status = 200
            let avatar = host.hasPrefix("avatar-") || host.hasPrefix("avatar-switch-")
                ? ",\"avatar\":\"https://\(host)/images/old.png\""
                : ""
            body = "{\"token\":\"token-\(host)\",\"user\":{\"id\":\"account-\(host)\",\"name\":\"\(host)\"\(avatar)}}"
        case "/api/files/config" where host.hasPrefix("avatar-"):
            status = 200
            body = #"{"avatarSizeLimit":2097152}"#
        case "/api/files/images/avatar" where host.hasPrefix("avatar-"):
            status = 200
            body = #"{"url":"/images/new.png"}"#
        case "/api/user" where host.hasPrefix("avatar-"):
            status = 200
            let avatar = Self.lock.withLock({ Self.avatarMode == .success })
                ? "https://\(host)/images/new.png?rotated=2"
                : "https://\(host)/images/old.png?rotated=2"
            body = "{\"id\":\"account-\(host)\",\"avatar\":\"\(avatar)\"}"
        case "/api/user/verify/resend" where host == "native-register.example":
            status = 200
            body = #"{"message":"Check your email"}"#
        case "/api/agents/chat/active":
            status = 200
            body = #"{"activeJobIds":[]}"#
        case "/api/agents/chat/status/conversation" where host == "queue-recovery.example":
            status = 200
            body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof","files":[],"quotes":[],"manualSkills":[],"alwaysAppliedSkills":[]},"responseMessageId":"assistant-proof"}}"#
        case "/api/convos":
            status = 200
            body = "[]"
        default:
            status = 404
            body = "{}"
        }
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }
}

private final class SelectionURLProtocolResponder: @unchecked Sendable {
    private weak var protocolInstance: SelectionURLProtocol?

    init(protocol protocolInstance: SelectionURLProtocol) {
        self.protocolInstance = protocolInstance
    }

    func finish(response: HTTPURLResponse, data: Data) {
        guard let protocolInstance else { return }
        protocolInstance.client?.urlProtocol(
            protocolInstance,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }

    func fail(error: Error) {
        guard let protocolInstance else { return }
        protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: error)
    }
}

private actor SelectionSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}
