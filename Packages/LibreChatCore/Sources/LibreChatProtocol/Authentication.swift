import CryptoKit
import Foundation
import LibreChatDomain
import os

private let authLog = Logger(subsystem: "LibreChatProtocol", category: "auth")

public struct AuthorizationCredential: Equatable, Sendable {
    public let headerValue: String
    public let revision: UInt64

    public init(headerValue: String, revision: UInt64) {
        self.headerValue = headerValue
        self.revision = revision
    }
}

public actor AuthSession {
    private let transport: HTTPTransport
    private let observability: ProtocolObservability
    /// Durable copy of the last authenticated session. Some deployments
    /// (proxies that strip `Set-Cookie`, servers without a refresh secret)
    /// never deliver a refresh cookie, so the access token itself is the only
    /// restorable credential.
    private let secretStore: any SecretStore
    private let sessionStorageKey: String
    private var accessToken: String?
    private var currentUser: UserAccount?
    private var credentialRevision: UInt64 = 0
    private var refreshTask: Task<AuthenticatedSession, Error>?
    /// Credential revision captured when the current refresh task started;
    /// a mismatch at adoption time means a clear raced the refresh.
    private var refreshTaskRevision: UInt64?

    public init(
        transport: HTTPTransport,
        profileID: ServerProfileID? = nil,
        secretStore: (any SecretStore)? = nil,
        observability: ProtocolObservability = .disabled
    ) {
        self.transport = transport
        self.secretStore = secretStore ?? MirroredSecretStore()
        self.sessionStorageKey = "session.\(profileID?.rawValue ?? "shared")"
        self.observability = observability
    }

    public func login(email: String, password: String) async throws -> LoginResult {
        observability.record(.authenticationLoginStarted)
        let body: Data
        do {
            body = try JSONEncoder().encode(LoginRequest(email: email, password: password))
        } catch {
            throw LibreChatProtocolError.encoding(error.localizedDescription)
        }
        let request = try await transport.request(
            method: .post,
            path: "api/auth/login",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        do {
            let response = try await transport.execute(request)
            try Self.validateLogin(response)
            let envelope: LoginEnvelope = try Self.decode(response.data)
            if envelope.twoFAPending == true, let token = envelope.tempToken?.nonEmpty {
                observability.record(.authenticationLoginCompleted(outcome: .requiresTwoFactor))
                return .requiresTwoFactor(TwoFactorChallenge(temporaryToken: token))
            }
            guard let token = envelope.token?.nonEmpty, let userDTO = envelope.user else {
                throw LibreChatProtocolError.invalidResponse
            }
            let session = AuthenticatedSession(accessToken: token, user: try userDTO.domainModel())
            setAuthenticated(session, reason: .authenticated)
            observability.record(.authenticationLoginCompleted(outcome: .authenticated))
            return .authenticated(session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            observability.record(.authenticationLoginCompleted(outcome: .rejected))
            throw error
        }
    }

    public func verifyTwoFactor(temporaryToken: String, code: String, backupCode: String? = nil) async throws -> AuthenticatedSession {
        let body: Data
        do {
            body = try JSONEncoder().encode(
                TwoFactorRequest(tempToken: temporaryToken, token: backupCode == nil ? code : nil, backupCode: backupCode)
            )
        } catch {
            throw LibreChatProtocolError.encoding(error.localizedDescription)
        }
        let request = try await transport.request(
            method: .post,
            path: "api/auth/2fa/verify-temp",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        let response = try await transport.execute(request)
        try Self.validate(response)
        let session = try Self.session(from: response.data)
        setAuthenticated(session, reason: .authenticated)
        return session
    }

    public func restoreSession() async throws -> AuthenticatedSession {
        if await hasSignedOutTombstone() {
            // A logout that could not delete its credential must not be
            // undone by the surviving refresh cookie.
            throw LibreChatProtocolError.unauthorized
        }
        if let persisted = await restorePersistedSessionIfStillValid() {
            return persisted
        }
        return try await refresh()
    }

    /// Restores from the durable access token when the server still accepts
    /// it. Deployments that never set a refresh cookie depend on this path.
    private func restorePersistedSessionIfStillValid() async -> AuthenticatedSession? {
        if Self.isSignedOutTombstoned(for: sessionStorageKey) {
            // A previous logout could not delete the persisted credential.
            // Retry the removal; until it succeeds the durable tombstone
            // keeps the account signed out across launches.
            do {
                try await secretStore.remove(sessionStorageKey)
                Self.clearSignedOutTombstone(for: sessionStorageKey)
            } catch {
                authLog.notice("Persisted session removal still failing; staying signed out.")
            }
            return nil
        }
        guard let data = try? await secretStore.data(for: sessionStorageKey),
              let session = try? JSONDecoder().decode(AuthenticatedSession.self, from: data),
              !session.accessToken.isEmpty else { return nil }
        do {
            var request = try await transport.request(method: .get, path: "api/user")
            request.setValue(
                "Bearer \(session.accessToken)",
                forHTTPHeaderField: "Authorization"
            )
        let response = try await transport.execute(request)
        guard (200..<300).contains(response.statusCode),
              !Self.isBrowserLoginRedirect(response.finalURL) else { return nil }
        // Adopt the server's current user so role or profile changes made
        // between launches are not overwritten by the stale persisted copy.
        // If the payload cannot be mapped, keep the persisted user rather
        // than failing the whole restore.
        let user: UserAccount
        if let dto: LibreChatUserDTO = try? Self.decode(response.data),
           let currentUser = try? dto.domainModel() {
            user = currentUser
        } else {
            user = session.user
        }
        let restored = AuthenticatedSession(accessToken: session.accessToken, user: user)
        setAuthenticated(restored, reason: .authenticated)
        return restored
        } catch {
            return nil
        }
    }

    public func beginTwoFactorSetup(
        reauthentication: TwoFactorProof? = nil
    ) async throws -> TwoFactorSetup {
        let response = try await authorizedRequest(
            method: .post,
            path: "api/auth/2fa/enable",
            body: reauthentication.map { try Self.encoded(TwoFactorProofRequest($0)) }
        )
        let envelope: TwoFactorSetupEnvelope = try Self.decode(response.data)
        guard let otpauthURL = URL(string: envelope.otpauthURL) else {
            throw LibreChatProtocolError.invalidResponse
        }
        return TwoFactorSetup(
            secret: Self.secret(from: otpauthURL),
            otpauthURL: otpauthURL,
            backupCodes: envelope.backupCodes
        )
    }

    public func confirmTwoFactorSetup(code: String) async throws {
        let body = try Self.encoded(TwoFactorCodeRequest(token: code))
        _ = try await authorizedRequest(
            method: .post,
            path: "api/auth/2fa/verify",
            body: body
        )
        _ = try await authorizedRequest(
            method: .post,
            path: "api/auth/2fa/confirm",
            body: body
        )
    }

    public func disableTwoFactor(proof: TwoFactorProof) async throws {
        let body = try Self.encoded(TwoFactorProofRequest(proof))
        _ = try await authorizedRequest(method: .post, path: "api/auth/2fa/disable", body: body)
    }

    public func regenerateBackupCodes(proof: TwoFactorProof) async throws -> [String] {
        let body = try Self.encoded(TwoFactorProofRequest(proof))
        let response = try await authorizedRequest(
            method: .post,
            path: "api/auth/2fa/backup/regenerate",
            body: body
        )
        let envelope: BackupCodesEnvelope = try Self.decode(response.data)
        return envelope.backupCodes
    }

    public func refresh() async throws -> AuthenticatedSession {
        observability.record(.authenticationRefreshRequested)
        return try await performRefresh()
    }

    public func refresh(ifRejected credential: AuthorizationCredential?) async throws -> AuthenticatedSession {
        observability.record(.authenticationRefreshRequested)
        if let session = authenticatedSession,
           credential == nil || credential?.revision != credentialRevision {
            observability.record(.authenticationRefreshCoalesced)
            return session
        }
        return try await performRefresh()
    }

    private func performRefresh() async throws -> AuthenticatedSession {
        if let refreshTask {
            observability.record(.authenticationRefreshCoalesced)
            do {
                let session = try await refreshTask.value
                try Self.ensureRefreshStaysWithinAccount(session, current: currentUser)
                adoptRefreshedSession(session)
                return session
            } catch {
                throw error
            }
        }
        let transport = self.transport
        let startedRevision = credentialRevision
        let task = Task<AuthenticatedSession, Error> {
            let request = try await transport.request(method: .post, path: "api/auth/refresh")
            let response = try await transport.execute(request)
            try Self.validate(response)
            return try Self.refreshSession(from: response.data)
        }
        refreshTask = task
        refreshTaskRevision = startedRevision
        defer { refreshTask = nil }
        do {
            let session = try await task.value
            try Self.ensureRefreshStaysWithinAccount(session, current: currentUser)
            adoptRefreshedSession(session)
            observability.record(.authenticationRefreshSucceeded)
            return session
        } catch {
            observability.record(.authenticationRefreshFailed)
            throw error
        }
    }

    /// A refresh answering with a different account than the one currently
    /// signed in is stale or foreign: replaying requests under that bearer
    /// would persist another account's data. Only explicit login or account
    /// replacement may change the user, never the cookie-refresh path.
    private static func ensureRefreshStaysWithinAccount(
        _ session: AuthenticatedSession,
        current: UserAccount?
    ) throws {
        if let current, current.id != session.user.id {
            throw LibreChatProtocolError.unauthorized
        }
    }

    private func adoptRefreshedSession(_ session: AuthenticatedSession) {
        // A clear that raced the in-flight refresh wins: the credential
        // revision moved since this refresh started, so its bearer must not
        // be reinstalled or persisted over the removed credentials.
        guard refreshTaskRevision == credentialRevision else { return }
        guard accessToken != session.accessToken || currentUser != session.user else { return }
        setAuthenticated(session, reason: .refreshed)
    }

    public func authorizationCredential() throws -> AuthorizationCredential {
        guard let accessToken else { throw LibreChatProtocolError.unauthorized }
        return AuthorizationCredential(
            headerValue: "Bearer \(accessToken)",
            revision: credentialRevision
        )
    }

    public func authorizationValue() throws -> String {
        try authorizationCredential().headerValue
    }

    public func user() -> UserAccount? { currentUser }

    public func updateTwoFactorStatus(_ enabled: Bool) {
        currentUser?.twoFactorEnabled = enabled
    }

    public func setAuthenticated(_ session: AuthenticatedSession) {
        setAuthenticated(session, reason: .authenticated)
    }

    private func setAuthenticated(
        _ session: AuthenticatedSession,
        reason: CredentialRevisionReason
    ) {
        accessToken = session.accessToken
        currentUser = session.user
        credentialRevision &+= 1
        if let encoded = try? JSONEncoder().encode(session) {
            persistSession(encoded)
        }
        observability.record(.authenticationCredentialRevisionChanged(
            reason: reason,
            revision: credentialRevision
        ))
    }

    /// Session persistence must never overtake a later credential clear:
    /// a detached write that lands after `clearAuthentication` would write
    /// the stale session straight back to the store. Chaining each write on
    /// the previous one keeps writes in auth-event order, and clearing
    /// awaits the chain before removing the stored session.
    private var pendingPersistenceWrite: Task<Void, Never>?

    private func persistSession(_ encoded: Data) {
        let previous = pendingPersistenceWrite
        let store = secretStore
        let key = sessionStorageKey
        let supersedesTombstone = Self.isSignedOutTombstoned(for: key)
        pendingPersistenceWrite = Task {
            await previous?.value
            do {
                try await store.set(encoded, for: key)
                // The marker is cleared only once the new session is
                // durably on disk; a failed write keeps the signed-out
                // tombstone in force.
                if supersedesTombstone {
                    Self.clearSignedOutTombstone(for: key)
                }
            } catch {
                authLog.error(
                    "Session persistence failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    public func clearAuthentication(clearCookies: Bool = false) async throws {
        // Cancel any in-flight refresh first so its completion cannot race
        // the persistence drain below; adoption stays fenced against the
        // cleared session in adoptRefreshedSession regardless.
        refreshTask?.cancel()
        accessToken = nil
        currentUser = nil
        credentialRevision &+= 1
        if let pending = pendingPersistenceWrite {
            _ = await pending.value
            pendingPersistenceWrite = nil
        }
        do {
            try await secretStore.remove(sessionStorageKey)
        } catch {
            // A failed removal must not silently leave a usable bearer on
            // disk: retry once, then durably tombstone the session so
            // restore cannot resurrect the account on later launches.
            do {
                try await secretStore.remove(sessionStorageKey)
            } catch {
                Self.writeSignedOutTombstone(for: sessionStorageKey)
                authLog.error(
                    "Persisted session removal failed; tombstoning the session: \(String(describing: error), privacy: .public)"
                )
                // The tombstone blocks bearer restore; the surviving refresh
                // cookie must go too, or the next launch refreshes back in.
                if clearCookies {
                    try? await transport.clearCookies()
                }
                throw error
            }
        }
        observability.record(.authenticationCredentialRevisionChanged(
            reason: .cleared,
            revision: credentialRevision
        ))
        refreshTask = nil
        if clearCookies {
            do {
                try await transport.clearCookies()
            } catch {
                // The persisted token is gone, but a surviving refresh cookie
                // could still mint a fresh session on the next launch: the
                // tombstone keeps restore from resurrecting the signed-out
                // account until a deliberate sign-in clears it.
                Self.writeSignedOutTombstone(for: sessionStorageKey)
                authLog.error(
                    "Cookie clearing failed; tombstoning the session: \(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }
    }

    // MARK: - Signed-out tombstone

    /// Durable record that a logout could not delete the persisted session
    /// credential. Restore checks it before every launch so a surviving
    /// bearer can never silently resurrect the signed-out account.
    private static var signedOutDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LibreChatSignedOut", directoryHint: .isDirectory)
    }

    private static func tombstoneURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return signedOutDirectory.appending(path: name)
    }

    private static func writeSignedOutTombstone(for key: String) {
        try? FileManager.default.createDirectory(at: signedOutDirectory, withIntermediateDirectories: true)
        try? Data().write(to: tombstoneURL(for: key), options: .atomic)
    }

    private static func clearSignedOutTombstone(for key: String) {
        try? FileManager.default.removeItem(at: tombstoneURL(for: key))
    }

    private static func isSignedOutTombstoned(for key: String) -> Bool {
        FileManager.default.fileExists(atPath: tombstoneURL(for: key).path)
    }

    private func hasSignedOutTombstone() -> Bool {
        Self.isSignedOutTombstoned(for: sessionStorageKey)
    }

    public func logout() async {
        // Build the best-effort request first: it needs the bearer and the
        // session cookies, which clearing below destroys. Local credentials
        // are cleared before the network call so a slow or unreachable
        // endpoint cannot leave the app signed in for the transport timeout;
        // the pre-built request still carries the captured credentials.
        var pendingRequest: URLRequest?
        if let accessToken {
            pendingRequest = try? await transport.request(
                method: .post,
                path: "api/auth/logout",
                headers: ["Authorization": "Bearer \(accessToken)"]
            )
        }
        try? await clearAuthentication(clearCookies: true)
        if let pendingRequest {
            _ = try? await transport.execute(pendingRequest)
        }
    }

    private static func validate(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode), !isBrowserLoginRedirect(response.finalURL) else {
            if response.statusCode == 401 || isBrowserLoginRedirect(response.finalURL) {
                throw LibreChatProtocolError.unauthorized
            }
            throw LibreChatProtocolError.httpStatus(
                response.statusCode,
                message: errorMessage(from: response.data),
                retryAfter: nil
            )
        }
    }

    private static func validateLogin(_ response: HTTPResponse) throws {
        guard response.statusCode != 422 || !requiresEmailVerification(response.data) else {
            throw AuthenticationLoginError.emailVerificationRequired
        }
        try validate(response)
    }

    private static func requiresEmailVerification(_ data: Data) -> Bool {
        guard let message = errorMessage(from: data)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return [
            "email not verified.",
            "email not verified",
            "email is not verified.",
            "email is not verified",
            "email verification required.",
            "email verification required"
        ].contains(message)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return object["message"]?.stringValue ?? object["error"]?.stringValue
        }
        return String(data: data, encoding: .utf8)
    }

    private static func isBrowserLoginRedirect(_ url: URL) -> Bool {
        url.lastPathComponent == "login" && !url.path.contains("/api/auth/")
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LibreChatProtocolError.decoding(error.localizedDescription)
        }
    }

    private static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw LibreChatProtocolError.encoding(error.localizedDescription) }
    }

    private static func secret(from otpauthURL: URL) -> String? {
        URLComponents(url: otpauthURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "secret" })?
            .value?
            .nonEmpty
    }

    private func authorizedRequest(
        method: HTTPMethod,
        path: String,
        body: Data? = nil
    ) async throws -> HTTPResponse {
        // Bind the credential BEFORE the request build: the cookie-jar read
        // is a suspension across which a same-profile account replacement
        // could swap sessions, sending A's code/proof under B's bearer.
        let initiatingValue = try authorizationValue()
        var request = try await transport.request(
            method: method,
            path: path,
            headers: body == nil ? [:] : ["Content-Type": "application/json"],
            body: body
        )
        request.setValue(initiatingValue, forHTTPHeaderField: "Authorization")
        var response = try await transport.execute(request)
        if response.statusCode == 401 {
            _ = try await refresh()
            request.setValue(try authorizationValue(), forHTTPHeaderField: "Authorization")
            response = try await transport.execute(request)
        }
        try Self.validate(response)
        return response
    }

    private static func session(from data: Data) throws -> AuthenticatedSession {
        let envelope: LoginEnvelope = try decode(data)
        guard let token = envelope.token?.nonEmpty, let user = envelope.user else {
            throw LibreChatProtocolError.unauthorized
        }
        return AuthenticatedSession(accessToken: token, user: try user.domainModel())
    }

    private static func refreshSession(from data: Data) throws -> AuthenticatedSession {
        guard let envelope = try? JSONDecoder().decode(LoginEnvelope.self, from: data),
              let token = envelope.token?.nonEmpty,
              let userDTO = envelope.user,
              let user = try? userDTO.domainModel() else {
            // LibreChat can return a plain-text 200 when no refresh cookie is
            // present. Any malformed refresh payload is unauthenticated rather
            // than a recoverable decoding problem.
            throw LibreChatProtocolError.unauthorized
        }
        return AuthenticatedSession(accessToken: token, user: user)
    }

    private var authenticatedSession: AuthenticatedSession? {
        guard let accessToken, let currentUser else { return nil }
        return AuthenticatedSession(accessToken: accessToken, user: currentUser)
    }
}

private struct LoginRequest: Encodable {
    let email: String
    let password: String
}

private struct LoginEnvelope: Decodable {
    let token: String?
    let user: LibreChatUserDTO?
    let twoFAPending: Bool?
    let tempToken: String?
}

private struct TwoFactorRequest: Encodable {
    let tempToken: String
    let token: String?
    let backupCode: String?
}

private struct TwoFactorCodeRequest: Encodable { let token: String }

private struct TwoFactorProofRequest: Encodable {
    let token: String?
    let backupCode: String?

    init(_ proof: TwoFactorProof) {
        switch proof {
        case let .authenticatorCode(value):
            token = value
            backupCode = nil
        case let .backupCode(value):
            token = nil
            backupCode = value
        }
    }
}

private struct TwoFactorSetupEnvelope: Decodable {
    let otpauthURL: String
    let backupCodes: [String]

    private enum CodingKeys: String, CodingKey {
        case otpauthURL = "otpauthUrl"
        case backupCodes
    }
}

private struct BackupCodesEnvelope: Decodable {
    let backupCodes: [String]
}

public struct LibreChatRuntime: Sendable {
    public let cookieJar: ProfileCookieJar
    public let transport: HTTPTransport
    public let authSession: AuthSession
    public let restClient: RESTClient

    public init(
        cookieJar: ProfileCookieJar,
        transport: HTTPTransport,
        authSession: AuthSession,
        restClient: RESTClient
    ) {
        self.cookieJar = cookieJar
        self.transport = transport
        self.authSession = authSession
        self.restClient = restClient
    }

    public static func live(
        profile: ServerProfile,
        secretStore: (any SecretStore)? = nil,
        observability: ProtocolObservability = .disabled
    ) -> LibreChatRuntime {
        let sessionStore = secretStore ?? MirroredSecretStore()
        let cookieJar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: profile.baseURL,
            secretStore: sessionStore
        )
        let transport = HTTPTransport.live(
            baseURL: profile.baseURL,
            cookieJar: cookieJar,
            observability: observability
        )
        let authSession = AuthSession(
            transport: transport,
            profileID: profile.id,
            secretStore: sessionStore,
            observability: observability
        )
        let restClient = RESTClient(
            transport: transport,
            authSession: authSession,
            observability: observability
        )
        return LibreChatRuntime(
            cookieJar: cookieJar,
            transport: transport,
            authSession: authSession,
            restClient: restClient
        )
    }
}
