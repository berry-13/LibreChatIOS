import Foundation
import LibreChatDomain
import LibreChatProtocol
import Network
import Observation
import OSLog

enum GenerationRecoveryTrigger: Equatable, Sendable {
    case foreground
    case connectivity
}

/// A bounded handoff from app lifecycle recovery to the currently visible chat.
///
/// The repository has already reconciled these snapshots with the server. A
/// chat still verifies the profile, account, conversation, and exact handle
/// before reopening its own snapshot consumer.
struct GenerationRecoverySignal: Equatable, Sendable {
    let sequence: UInt64
    let profileID: ServerProfileID
    let accountID: AccountID
    let activeSnapshots: [GenerationSnapshot]
    let trigger: GenerationRecoveryTrigger

    init(
        sequence: UInt64,
        profileID: ServerProfileID,
        accountID: AccountID,
        activeSnapshots: [GenerationSnapshot],
        trigger: GenerationRecoveryTrigger = .foreground
    ) {
        self.sequence = sequence
        self.profileID = profileID
        self.accountID = accountID
        self.activeSnapshots = activeSnapshots
        self.trigger = trigger
    }
}

/// Reduces noisy `NWPathMonitor` callbacks to an offline-to-online edge.
///
/// The first observation is deliberately ignored: a launch-time reachable
/// path is not a connectivity return and foreground reconciliation owns that
/// recovery path.
struct ConnectivityRecoveryGate: Sendable {
    private(set) var lastReachable: Bool?

    mutating func receivesPath(reachable: Bool) -> Bool {
        defer { lastReachable = reachable }
        return lastReachable == false && reachable
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case restoring
        case needsServer
        case signedOut
        case signedIn
    }

    private static let legacyServerKey = "librechat.server-url"

    let dependencies: AppDependencies

    /// True when running against deterministic in-process UI test fixtures.
    var uiTestFixtureIsActive: Bool {
        #if DEBUG
        dependencies.uiTestFixture != nil
        #else
        false
        #endif
    }
    private(set) var phase: Phase = .restoring
    private(set) var profiles: [ServerProfile] = []
    private(set) var selectedServer: ServerProfile?
    private(set) var authenticationState: AuthenticationState = .restoring
    private(set) var compatibility: CompatibilityResult?
    private(set) var isWorking = false
    private(set) var isRefreshingServerPolicy = false
    private(set) var pendingAccountReplacement: AuthenticatedSession?
    private(set) var pendingTerms: PublicTermsOfService?
    private(set) var cacheEpoch = UUID()
    private(set) var generationRecoverySignal: GenerationRecoverySignal?
    var notice: String?

    private var activeRuntime: ProfileRuntime?
    private(set) var uploadManager: UploadManager?
    private var didAttemptRestore = false
    private var profileSelectionEpoch = 0
    private let mobileAuthentication = MobileAuthenticationCoordinator()
    private let appLock = AppLockCoordinator()
    private(set) var isAppLocked = false
    private var generationRecoveryTask: Task<Void, Never>?
    private var generationRecoveryTaskID: UUID?
    private var generationRecoverySequence: UInt64 = 0
    private let connectivityMonitor: NWPathMonitor
    private let connectivityMonitorQueue = DispatchQueue(
        label: "com.librechat.connectivity-recovery",
        qos: .utility
    )
    private var connectivityRecoveryGate = ConnectivityRecoveryGate()
    private var isApplicationActive = true

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let monitor = NWPathMonitor()
        connectivityMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // Keep `NWPath` on the monitor queue. Its reachability bit is the
            // only information needed by the main-actor recovery coordinator.
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.receiveConnectivityPath(reachable: reachable)
            }
        }
        monitor.start(queue: connectivityMonitorQueue)
    }

    deinit {
        connectivityMonitor.cancel()
    }

    var user: UserAccount? { authenticationState.user }
    var cacheHealth: CacheHealth { dependencies.cacheHealth }
    var cacheRepairNotice: String? { cacheHealth.repairNotice }
    var repository: LibreChatRepository? { activeRuntime?.repository }
    var pendingTwoFactorToken: String? {
        if case let .awaitingTwoFactor(challenge) = authenticationState {
            return challenge.temporaryToken
        }
        return nil
    }
    var isOffline: Bool { authenticationState.isReadOnly }
    var canGenerate: Bool {
        guard !isOffline else { return false }
        return compatibility?.capabilities.generation.canGenerate
            ?? selectedServer?.capabilities?.generation.canGenerate
            ?? true
    }
    var canUseVoiceDictation: Bool {
        guard !isOffline else { return false }
        return compatibility?.capabilities.speechCapabilities?.supportsSpeechToText
            ?? selectedServer?.capabilities?.speechCapabilities?.supportsSpeechToText
            ?? false
    }
    var canUseReadAloud: Bool {
        guard !isOffline else { return false }
        return compatibility?.capabilities.speechCapabilities?.supportsTextToSpeech
            ?? selectedServer?.capabilities?.speechCapabilities?.supportsTextToSpeech
            ?? false
    }
    var compatibilityWarning: String? {
        compatibility?.warnings.first?.message
            ?? selectedServer?.capabilities.flatMap { capabilities in
                if case .unsupported = capabilities.generation {
                    return "This server can be browsed, but sending requires resumable generation protocol v2."
                }
                return nil
            }
    }
    var browserAuthenticationMethods: [AuthenticationMethod] {
        let methods = compatibility?.capabilities.authenticationMethods
            ?? selectedServer?.capabilities?.authenticationMethods
            ?? []
        return methods.filter { $0 != .email && $0 != .ldap }.sorted { $0.rawValue < $1.rawValue }
    }
    var supportsBrowserAuthentication: Bool {
        compatibility?.capabilities.supportsMobileAuthentication
            ?? selectedServer?.capabilities?.supportsMobileAuthentication
            ?? false
    }
    var canUseEmailLogin: Bool {
        if let preLogin = compatibility?.capabilities.preLogin
            ?? selectedServer?.capabilities?.preLogin {
            return preLogin.emailLoginEnabled
        }
        let methods = compatibility?.capabilities.authenticationMethods
            ?? selectedServer?.capabilities?.authenticationMethods
        return methods?.contains(.email) ?? true
    }
    var canRequestPasswordReset: Bool {
        guard let preLogin = compatibility?.capabilities.preLogin
            ?? selectedServer?.capabilities?.preLogin else { return false }
        return preLogin.emailLoginEnabled && preLogin.passwordResetEnabled
    }
    var canResendEmailVerification: Bool {
        guard let preLogin = compatibility?.capabilities.preLogin
            ?? selectedServer?.capabilities?.preLogin else { return false }
        return preLogin.emailLoginEnabled && preLogin.emailDeliveryEnabled
    }
    var canRegisterAccount: Bool {
        guard let preLogin = compatibility?.capabilities.preLogin
            ?? selectedServer?.capabilities?.preLogin else { return false }
        return preLogin.emailLoginEnabled
            && preLogin.registrationEnabled
            && !preLogin.requiresWebChallenge
    }
    var registrationRequiresBrowserChallenge: Bool {
        guard let preLogin = compatibility?.capabilities.preLogin
            ?? selectedServer?.capabilities?.preLogin else { return false }
        return preLogin.registrationEnabled && preLogin.requiresWebChallenge
    }
    var registrationMinimumPasswordLength: Int {
        compatibility?.capabilities.preLogin?.minimumPasswordLength
            ?? selectedServer?.capabilities?.preLogin?.minimumPasswordLength
            ?? 8
    }
    var registrationUsesEmailDelivery: Bool {
        compatibility?.capabilities.preLogin?.emailDeliveryEnabled
            ?? selectedServer?.capabilities?.preLogin?.emailDeliveryEnabled
            ?? false
    }
    var publicLegalConfiguration: PublicLegalConfiguration? {
        compatibility?.capabilities.publicLegal
            ?? selectedServer?.capabilities?.publicLegal
    }
    var canShareConversations: Bool {
        guard !isOffline else { return false }
        return compatibility?.capabilities.supportsSharedLinks
            ?? selectedServer?.capabilities?.supportsSharedLinks
            ?? false
    }
    var canSnapshotFilesInSharedLinks: Bool {
        compatibility?.capabilities.supportsSharedLinkFileSnapshots
            ?? selectedServer?.capabilities?.supportsSharedLinkFileSnapshots
            ?? false
    }
    var canUseBookmarks: Bool {
        guard !isOffline else { return false }
        if let discovered = compatibility?.capabilities.supportsBookmarks {
            return discovered
        }
        return selectedServer?.capabilities?.supportsBookmarks == true
    }
    var canDeleteAccount: Bool {
        guard phase == .signedIn, !isOffline else { return false }
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return capabilities?.authenticatedPolicyVerified == true
            && capabilities?.supportsAccountDeletion == true
    }
    var temporaryChatPolicy: TemporaryChatPolicy? {
        guard !isOffline else { return nil }
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        guard capabilities?.authenticatedPolicyVerified == true,
              capabilities?.temporaryChatPolicy?.isAvailable == true else { return nil }
        return capabilities?.temporaryChatPolicy
    }
    var memoryPermissions: MemoryPermissions? {
        compatibility?.capabilities.memoryPermissions
            ?? selectedServer?.capabilities?.memoryPermissions
    }
    var promptPermissions: PromptPermissions? {
        compatibility?.capabilities.promptPermissions
            ?? selectedServer?.capabilities?.promptPermissions
    }
    var agentPermissions: AgentPermissions? {
        compatibility?.capabilities.agentPermissions
            ?? selectedServer?.capabilities?.agentPermissions
    }
    var mcpPermissions: MCPPermissions? {
        compatibility?.capabilities.mcpPermissions
            ?? selectedServer?.capabilities?.mcpPermissions
    }
    var skillPermissions: SkillPermissions? {
        compatibility?.capabilities.skillPermissions
            ?? selectedServer?.capabilities?.skillPermissions
    }
    var canUseSkills: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return !isOffline
            && capabilities?.authenticatedPolicyVerified == true
            && capabilities?.supportsSkills == true
            && capabilities?.skillPermissions?.use == true
    }
    var canUsePrompts: Bool {
        !isOffline && promptPermissions?.use == true
    }
    /// Projects are deployment-gated: deployments without the feature (or
    /// in the fail-closed state after an authenticated refresh failure) must
    /// not present the Projects UI or preload `/api/projects`.
    var canUseProjects: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return !isOffline
            && capabilities?.authenticatedPolicyVerified == true
            && capabilities?.supportsProjects == true
    }
    var canUsePresets: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return !isOffline
            && capabilities?.authenticatedPolicyVerified == true
            && capabilities?.supportsPresets == true
    }
    var canBrowseAgents: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return !isOffline
            && capabilities?.authenticatedPolicyVerified == true
            && capabilities?.supportsAgents == true
            && capabilities?.agentPermissions?.use == true
    }
    var canCreateAgents: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return !isOffline
            && capabilities?.authenticatedPolicyVerified == true
            && capabilities?.supportsAgents == true
            && capabilities?.agentPermissions?.canManageMetadata == true
    }
    var canBrowseMemories: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return capabilities?.supportsMemories == true
            && capabilities?.memoryPermissions?.canRead == true
    }
    var canBrowseMCPConnections: Bool {
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return !isOffline
            && capabilities?.supportsMCP == true
            && capabilities?.mcpPermissions?.use == true
    }
    var authenticatedServerPolicyUnavailable: Bool {
        guard phase == .signedIn else { return false }
        let capabilities = compatibility?.capabilities ?? selectedServer?.capabilities
        return capabilities?.authenticatedPolicyVerified == false
    }
    var isAppLockEnabled: Bool { appLock.isEnabled }

    func restoreIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        #if DEBUG
        if let fixture = dependencies.uiTestFixture {
            await installUITestFixture(fixture)
            return
        }
        #endif
        do {
            profiles = try await dependencies.cache.profiles()
            try await migrateLegacyServerIfNeeded()
        } catch {
            AppLog.persistence.error("Profile restoration failed.")
        }

        guard let profile = profiles.first else {
            authenticationState = .needsServer
            phase = .needsServer
            return
        }
        await select(profile: profile, restoring: true)
        // A cold launch can reach .signedIn without ever passing through
        // applicationBecameInactive, so the device lock has to engage here
        // or the restored session sits unlocked until the next backgrounding.
        if appLock.isEnabled, phase == .signedIn { isAppLocked = true }
    }

    #if DEBUG
    private func installUITestFixture(_ fixture: UITestFixture) async {
        let runtime = dependencies.profileRuntime(for: fixture.profile)
        activeRuntime = runtime
        selectedServer = fixture.profile
        profiles = [fixture.profile]
        await runtime.protocolRuntime.authSession.setAuthenticated(fixture.session)
        do {
            try await accept(session: fixture.session, runtime: runtime, replacingAccount: false)
        } catch {
            authenticationState = .signedOut(fixture.profile.id)
            phase = .signedOut
            notice = "UI test fixtures could not start."
        }
    }
    #endif

    func connect(to input: String) async throws {
        isWorking = true
        notice = nil
        profileSelectionEpoch &+= 1
        let selectionEpoch = profileSelectionEpoch
        defer {
            // This connection owns the busy flag; a superseded run releases it.
            if selectionEpoch == profileSelectionEpoch { isWorking = false }
        }

        let address = try ServerAddress.parse(input)
        var profile = ServerProfile(
            baseURL: address.url,
            displayName: address.displayName,
            trustPolicy: address.url.scheme == "http" ? .localDevelopment : .system
        )
        let runtime = dependencies.profileRuntime(for: profile)
        try await runtime.repository.healthCheck()
        guard selectionEpoch == profileSelectionEpoch else { return }
        let compatibility = try await runtime.repository.discoverCapabilities()
        guard selectionEpoch == profileSelectionEpoch else { return }
        profile.capabilities = compatibility.capabilities
        try await dependencies.cache.save(profile: profile, selected: true)

        profiles.removeAll { $0.id == profile.id }
        profiles.insert(profile, at: 0)
        activeRuntime = runtime
        selectedServer = profile
        generationRecoverySignal = nil
        self.compatibility = compatibility
        authenticationState = .signedOut(profile.id)
        phase = .signedOut
    }

    func select(profile: ServerProfile, restoring: Bool = false) async {
        profileSelectionEpoch &+= 1
        let selectionEpoch = profileSelectionEpoch
        // Every session transition flushes session-scoped image caches so one
        // account's avatars, icons, and file previews can never render in
        // another account's session.
        ServerEntityImageStore.removeAllCachedImages()
        FileImagePreviewStore.removeAllCachedImages()
        let selectionUploadManager = uploadManager
        let outgoingRuntime = activeRuntime
        cancelGenerationRecovery()
        generationRecoverySignal = nil
        isWorking = true
        notice = nil
        authenticationState = .restoring
        phase = .restoring
        await selectionUploadManager?.resetAfterCachePurge()
        // The reset drains cancelled tasks and suspends; a concurrent scene
        // selection owns the shared manager after it resumes. This stale
        // selection owns the busy flag, so abandoning it must release that
        // too (the defer intentionally skips it).
        guard selectionEpoch == profileSelectionEpoch else {
            isWorking = false
            return
        }
        uploadManager = nil
        pendingAccountReplacement = nil
        pendingTerms = nil
        defer {
            if selectionEpoch == profileSelectionEpoch {
                isWorking = false
            }
        }

        // Stream cleanup belongs to the runtime this selection replaced.
        if let outgoingRepository = outgoingRuntime?.repository {
            await outgoingRepository.detachActiveStreams()
        }
        guard selectionEpoch == profileSelectionEpoch else { return }

        let runtime = dependencies.profileRuntime(for: profile)
        activeRuntime = runtime
        selectedServer = profile
        try? await dependencies.cache.save(profile: profile, selected: true)
        guard selectionEpoch == profileSelectionEpoch else { return }

        do {
            let discovered = try await runtime.repository.discoverCapabilities()
            guard selectionEpoch == profileSelectionEpoch else { return }
            compatibility = discovered
            updateSelectedCapabilities(discovered.capabilities)
        } catch {
            guard selectionEpoch == profileSelectionEpoch else { return }
            compatibility = profile.capabilities.map {
                CompatibilityResult(supported: true, warnings: [], capabilities: $0)
            }
        }

        do {
            let session = try await runtime.protocolRuntime.authSession.restoreSession()
            guard selectionEpoch == profileSelectionEpoch else { return }
            try await accept(
                session: session,
                runtime: runtime,
                replacingAccount: false,
                selectionEpoch: selectionEpoch
            )
        } catch is CancellationError {
            return
        } catch let error as LibreChatProtocolError {
            guard selectionEpoch == profileSelectionEpoch else { return }
            AppLog.authentication.error(
                "Session restore failed: \(String(describing: error), privacy: .public)"
            )
            switch error {
            case .transport:
                if let cached = try? await dependencies.cache.lastVerifiedAccount(
                    profileID: profile.id,
                    accountID: profile.accountIdentifier
                ) {
                    guard selectionEpoch == profileSelectionEpoch else { return }
                    let resolvedCached = Self.accountWithResolvedAvatar(
                        cached,
                        baseURL: profile.baseURL
                    )
                    await runtime.repository.activate(account: resolvedCached)
                    guard selectionEpoch == profileSelectionEpoch else { return }
                    authenticationState = .authenticatedOffline(resolvedCached)
                    phase = .signedIn
                    notice = "Offline. Showing the last verified cache; remote changes are disabled."
                } else {
                    authenticationState = .signedOut(profile.id)
                    phase = .signedOut
                    notice = "The server is saved, but it could not be reached."
                }
            default:
                await invalidateSession(
                    for: profile,
                    runtime: runtime,
                    selectionEpoch: selectionEpoch
                )
            }
        } catch {
            guard selectionEpoch == profileSelectionEpoch else { return }
            AppLog.authentication.error(
                "Session restore failed unexpectedly: \(String(describing: error), privacy: .public)"
            )
            authenticationState = .signedOut(profile.id)
            phase = .signedOut
            notice = "The server is saved, but the previous session could not be restored."
        }
    }

    func signIn(email: String, password: String) async throws {
        guard let activeRuntime else { throw LibreChatProtocolError.unsupported("Choose a server first.") }
        let selectionEpoch = profileSelectionEpoch
        isWorking = true
        notice = nil
        defer { isWorking = false }

        switch try await activeRuntime.protocolRuntime.authSession.login(email: email, password: password) {
        case let .authenticated(session):
            try validateBrowserAuthenticationContext(
                profileID: selectedServer?.id ?? activeRuntime.profile.id,
                runtime: activeRuntime,
                selectionEpoch: selectionEpoch
            )
            try await accept(
                session: session,
                runtime: activeRuntime,
                replacingAccount: false,
                selectionEpoch: selectionEpoch
            )
        case let .requiresTwoFactor(challenge):
            try validateBrowserAuthenticationContext(
                profileID: selectedServer?.id ?? activeRuntime.profile.id,
                runtime: activeRuntime,
                selectionEpoch: selectionEpoch
            )
            authenticationState = .awaitingTwoFactor(challenge)
        }
    }

    func signIn(using method: AuthenticationMethod) async throws {
        guard supportsBrowserAuthentication,
              let profile = selectedServer,
              let runtime = activeRuntime else {
            throw LibreChatProtocolError.unsupported(
                "This server does not provide the mobile authorization-code extension."
            )
        }
        let selectionEpoch = profileSelectionEpoch
        isWorking = true
        notice = nil
        defer { isWorking = false }
        let configuration = try await runtime.repository.mobileAuthenticationConfiguration()
        try validateBrowserAuthenticationContext(
            profileID: profile.id,
            runtime: runtime,
            selectionEpoch: selectionEpoch
        )
        let grant = try await mobileAuthentication.authorize(
            profile: profile,
            provider: method,
            configuration: configuration
        )
        try validateBrowserAuthenticationContext(
            profileID: profile.id,
            runtime: runtime,
            selectionEpoch: selectionEpoch
        )
        let session = try await runtime.repository.exchangeMobileAuthorization(grant)
        try validateBrowserAuthenticationContext(
            profileID: profile.id,
            runtime: runtime,
            selectionEpoch: selectionEpoch
        )
        try await accept(
            session: session,
            runtime: runtime,
            replacingAccount: false,
            selectionEpoch: selectionEpoch
        )
    }

    /// Adopts a social/OAuth session completed inside the in-app web view:
    /// the harvested cookies seed the profile jar, and a refresh mints the
    /// native access token. Works against stock LibreChat servers without
    /// the mobile authorization-code extension.
    func adoptSocialSession(cookies: [StoredCookie]) async throws {
        guard let profile = selectedServer,
              let runtime = activeRuntime else {
            throw LibreChatProtocolError.unsupported("Choose a server first.")
        }
        guard !cookies.isEmpty else {
            throw LibreChatProtocolError.unauthorized
        }
        let selectionEpoch = profileSelectionEpoch
        isWorking = true
        notice = nil
        defer { isWorking = false }
        // Cookie replacement must happen only after ownership is confirmed:
        // a scene switching to another profile during the landing callback
        // would otherwise get A's harvested cookies installed over B's jar.
        try validateBrowserAuthenticationContext(
            profileID: profile.id,
            runtime: runtime,
            selectionEpoch: selectionEpoch
        )
        try await runtime.protocolRuntime.cookieJar.replace(with: cookies)
        try validateBrowserAuthenticationContext(
            profileID: profile.id,
            runtime: runtime,
            selectionEpoch: selectionEpoch
        )
        let session = try await runtime.protocolRuntime.authSession.refresh()
        try validateBrowserAuthenticationContext(
            profileID: profile.id,
            runtime: runtime,
            selectionEpoch: selectionEpoch
        )
        try await accept(
            session: session,
            runtime: runtime,
            replacingAccount: false,
            selectionEpoch: selectionEpoch
        )
    }

    private func validateBrowserAuthenticationContext(
        profileID: ServerProfileID,
        runtime: ProfileRuntime,
        selectionEpoch: Int
    ) throws {
        guard selectionEpoch == profileSelectionEpoch,
              selectedServer?.id == profileID,
              activeRuntime?.profile.id == runtime.profile.id else {
            throw CancellationError()
        }
    }

    func verifyTwoFactor(code: String, backupCode: Bool = false) async throws {
        guard let activeRuntime,
              case let .awaitingTwoFactor(challenge) = authenticationState else {
            throw LibreChatProtocolError.invalidResponse
        }
        let selectionEpoch = profileSelectionEpoch
        isWorking = true
        notice = nil
        defer { isWorking = false }

        let session = try await activeRuntime.protocolRuntime.authSession.verifyTwoFactor(
            temporaryToken: challenge.temporaryToken,
            code: backupCode ? "" : code,
            backupCode: backupCode ? code : nil
        )
        try validateBrowserAuthenticationContext(
            profileID: selectedServer?.id ?? activeRuntime.profile.id,
            runtime: activeRuntime,
            selectionEpoch: selectionEpoch
        )
        try await accept(
            session: session,
            runtime: activeRuntime,
            replacingAccount: false,
            selectionEpoch: selectionEpoch
        )
    }

    func requestPasswordReset(email: String) async throws -> PasswordResetRequestResult {
        guard canRequestPasswordReset, let repository = activeRuntime?.repository else {
            throw LibreChatProtocolError.unsupported(
                "Password recovery is not available on this server."
            )
        }
        return try await repository.requestPasswordReset(email: email)
    }

    func registerAccount(_ registration: AccountRegistration) async throws -> RegistrationResult {
        guard canRegisterAccount, let repository = activeRuntime?.repository else {
            throw LibreChatProtocolError.unsupported(
                registrationRequiresBrowserChallenge
                    ? "Registration requires this server’s browser challenge."
                    : "Registration is not available on this server."
            )
        }
        return try await repository.register(registration)
    }

    func resendEmailVerification(email: String) async throws -> EmailVerificationResendResult {
        guard canResendEmailVerification, let repository = activeRuntime?.repository else {
            throw LibreChatProtocolError.unsupported(
                "Email verification delivery is not available on this server."
            )
        }
        return try await repository.resendEmailVerification(email: email)
    }

    func acceptPendingTerms() async throws {
        guard pendingTerms != nil, let termsRuntime = activeRuntime else {
            throw LibreChatProtocolError.invalidResponse
        }
        let selectionEpoch = profileSelectionEpoch
        _ = try await termsRuntime.repository.acceptTerms()
        // Another scene may have switched to an account whose own terms flow
        // is pending; only the originating profile's acceptance clears it.
        guard selectionEpoch == profileSelectionEpoch else { return }
        pendingTerms = nil
    }

    func declinePendingTerms() async {
        pendingTerms = nil
        await signOut()
    }

    func confirmAccountReplacement() async {
        guard let session = pendingAccountReplacement, let activeRuntime, let selectedServer else { return }
        let selectionEpoch = profileSelectionEpoch
        ServerEntityImageStore.removeAllCachedImages()
        FileImagePreviewStore.removeAllCachedImages()
        isWorking = true
        defer { isWorking = false }
        if let oldAccount = selectedServer.accountIdentifier {
            try? await dependencies.cache.purge(profileID: selectedServer.id, accountID: oldAccount)
        }
        do {
            try await accept(
                session: session,
                runtime: activeRuntime,
                replacingAccount: true,
                selectionEpoch: selectionEpoch
            )
        } catch {
            notice = error.userFacingMessage
        }
    }

    func cancelAccountReplacement() async {
        pendingAccountReplacement = nil
        generationRecoverySignal = nil
        ServerEntityImageStore.removeAllCachedImages()
        FileImagePreviewStore.removeAllCachedImages()
        let cancellingRuntime = activeRuntime
        let cancellingProfileID = selectedServer?.id
        let selectionEpoch = profileSelectionEpoch
        await cancellingRuntime?.protocolRuntime.authSession.logout()
        // A profile selected while the logout was suspended owns the shared
        // state; the stale cancellation must not sign it out.
        guard selectionEpoch == profileSelectionEpoch else { return }
        if let profileID = cancellingProfileID {
            authenticationState = .signedOut(profileID)
        }
        phase = .signedOut
    }

    func cancelTwoFactor() {
        authenticationState = .signedOut(selectedServer?.id)
    }

    func signOut() async {
        guard let selectedServer, let signingOutRuntime = activeRuntime else { return }
        let originatingAccountID = selectedServer.accountIdentifier
        let selectionEpoch = profileSelectionEpoch
        ServerEntityImageStore.removeAllCachedImages()
        FileImagePreviewStore.removeAllCachedImages()
        isWorking = true
        cancelGenerationRecovery()
        generationRecoverySignal = nil
        await signingOutRuntime.repository.detachActiveStreams()
        // A same-profile account replacement during the detach suspension
        // owns the shared session; the stale sign-out must not log it out.
        guard selectedServer.accountIdentifier == originatingAccountID else {
            isWorking = false
            return
        }
        await signingOutRuntime.protocolRuntime.authSession.logout()
        if let accountID = selectedServer.accountIdentifier {
            await hideCache(profileID: selectedServer.id, accountID: accountID)
            UploadManager.removeStagingDirectory(profileID: selectedServer.id, accountID: accountID)
            UnsentCanvasManifestStore.removeAll(
                profileID: selectedServer.id.rawValue,
                accountID: accountID.rawValue
            )
        }
        // Another scene switching servers mid-logout must not tear down the
        // newly selected session's state. The stale sign-out owned the busy
        // flag; abandoning it must release that flag or the setup screen
        // stays disabled.
        guard selectionEpoch == profileSelectionEpoch,
              self.selectedServer?.accountIdentifier == originatingAccountID else {
            isWorking = false
            return
        }
        authenticationState = .signedOut(selectedServer.id)
        await uploadManager?.resetAfterCachePurge()
        // The reset drains cancelled tasks and suspends; revalidate before
        // mutating the shared selection state. This stale sign-out owns the
        // busy flag, so abandoning it must release that too.
        guard selectionEpoch == profileSelectionEpoch else {
            isWorking = false
            return
        }
        uploadManager = nil
        pendingAccountReplacement = nil
        pendingTerms = nil
        isWorking = false
        phase = .signedOut
    }

    /// Builds an expiry callback bound to the profile selected at creation
    /// time: a 401 raised by a superseded session must never tear down the
    /// newly selected one.
    func expireSessionCallback() -> @MainActor () async -> Void {
        let originatingProfileID = selectedServer?.id
        let originatingAccountID = selectedServer?.accountIdentifier
        return { [weak self] in
            await self?.expireSession(
                for: originatingProfileID,
                originatingAccountID: originatingAccountID
            )
        }
    }

    func expireSession(
        for originatingProfileID: ServerProfileID? = nil,
        originatingAccountID: AccountID? = nil
    ) async {
        guard let selectedServer, let expiringRuntime = activeRuntime else { return }
        let expiringUploadManager = uploadManager
        let selectionEpoch = profileSelectionEpoch
        // A late 401 raised by a profile or account the user already switched
        // away from must never tear down the newly selected session.
        if let originatingProfileID, originatingProfileID != selectedServer.id { return }
        // Unbound callers (plain 401s) bind to the account that was current
        // at entry; bound callers keep their captured coordinate.
        let effectiveAccountID = originatingAccountID ?? selectedServer.accountIdentifier
        if let effectiveAccountID, selectedServer.accountIdentifier != effectiveAccountID { return }
        cancelGenerationRecovery()
        generationRecoverySignal = nil
        await expiringRuntime.repository.detachActiveStreams()
        // Ownership can also change across this suspension.
        guard selectedServer.accountIdentifier == effectiveAccountID else { return }
        try? await expiringRuntime.protocolRuntime.authSession.clearAuthentication(clearCookies: true)
        guard selectedServer.accountIdentifier == effectiveAccountID else { return }
        if let accountID = selectedServer.accountIdentifier {
            await hideCache(profileID: selectedServer.id, accountID: accountID)
            UploadManager.removeStagingDirectory(profileID: selectedServer.id, accountID: accountID)
            UnsentCanvasManifestStore.removeAll(
                profileID: selectedServer.id.rawValue,
                accountID: accountID.rawValue
            )
        }
        // Every lookup after a suspension must stay bound to the session
        // that actually expired.
        guard selectionEpoch == profileSelectionEpoch else { return }
        authenticationState = .signedOut(selectedServer.id)
        await expiringUploadManager?.resetAfterCachePurge()
        // Same post-drain revalidation as signOut.
        guard selectionEpoch == profileSelectionEpoch else { return }
        uploadManager = nil
        pendingTerms = nil
        notice = "Your session expired. Sign in to continue."
        phase = .signedOut
    }

    func chooseAnotherServer() async {
        // This transition changes the shared selection; the epoch fence must
        // advance so an in-flight sign-out for the removed profile cannot
        // overwrite the fresh .needsServer state afterwards.
        profileSelectionEpoch &+= 1
        let transitionEpoch = profileSelectionEpoch
        let outgoingRuntime = activeRuntime
        let outgoingUploadManager = uploadManager
        cancelGenerationRecovery()
        generationRecoverySignal = nil
        await outgoingRuntime?.repository.detachActiveStreams()
        // Ownership must be revalidated after every suspension and before
        // each global assignment: a superseded transition must never clear
        // the newly selected session's runtime or manager.
        guard transitionEpoch == profileSelectionEpoch else { return }
        activeRuntime = nil
        await outgoingUploadManager?.resetAfterCachePurge()
        guard transitionEpoch == profileSelectionEpoch else { return }
        uploadManager = nil
        selectedServer = nil
        authenticationState = .needsServer
        compatibility = nil
        pendingAccountReplacement = nil
        pendingTerms = nil
        notice = nil
        phase = .needsServer
    }

    func removeProfile(_ profile: ServerProfile) async {
        let runtime = selectedServer?.id == profile.id
            ? activeRuntime
            : dependencies.profileRuntime(for: profile)
        if let runtime {
            try? await runtime.protocolRuntime.authSession.clearAuthentication(clearCookies: true)
        }
        if selectedServer?.id == profile.id { await chooseAnotherServer() }
        do {
            try await dependencies.cache.remove(profileID: profile.id)
            profiles.removeAll { $0.id == profile.id }
        } catch {
            notice = "The server profile could not be removed completely."
            AppLog.persistence.error("Server profile purge failed.")
        }
    }

    func clearCache() async {
        guard cacheHealth.allowsUserInitiatedClear else {
            notice = cacheRepairNotice
            return
        }
        guard let selectedServer else { return }
        guard let purgeRuntime = activeRuntime else { return }
        let purgeProfile = selectedServer
        let purgeUploadManager = uploadManager
        let selectionEpoch = profileSelectionEpoch
        cancelGenerationRecovery()
        generationRecoverySignal = nil
        await purgeRuntime.repository.detachActiveStreams()
        // Drain the manager before the purge deletes its namespace: a
        // cancelled performUpload would otherwise recreate rows after the
        // purge, and in-flight requests could continue through it.
        await purgeUploadManager?.resetAfterCachePurge()
        let originatingAccountID = purgeProfile.accountIdentifier
        do {
            try await dependencies.cache.purge(
                profileID: purgeProfile.id,
                accountID: purgeProfile.accountIdentifier
            )
            // Only the originating profile's namespace was purged; a scene
            // that switched profiles mid-purge must keep its own uploads and
            // in-memory state untouched. Account replacement on the same
            // profile does not advance the epoch, hence the explicit check.
            guard selectionEpoch == profileSelectionEpoch,
                  purgeProfile.accountIdentifier == originatingAccountID else { return }
            await purgeRuntime.repository.resetInMemoryState()
            cacheEpoch = UUID()
            notice = "Saved cache cleared. LibreChat will reload this server's current data."
            if !isOffline, let repository = activeRuntime?.repository {
                startGenerationRecovery(
                    repository: repository,
                    profileID: selectedServer.id,
                    accountID: selectedServer.accountIdentifier
                )
            }
        } catch {
            notice = "The saved cache could not be cleared completely."
            AppLog.persistence.error("Cache purge failed.")
        }
    }

    /// Called synchronously from the scene-phase callback so the lock screen
    /// replaces the signed-in content before iOS can snapshot the scene.
    func discardUploadsForConversation(_ conversationID: ConversationID) async {
        await uploadManager?.discardUploads(for: conversationID)
    }

    func engageAppLockForInactiveScene() {
        if appLock.isEnabled, phase == .signedIn { isAppLocked = true }
    }

    /// The app enables multiple scenes: generation streams and the lock are
    /// global, so teardown engages only when the LAST active scene resigns.
    private var activeSceneCount = 0
    /// Advances on every scene transition so a stale inactive teardown can
    /// never cancel streams that a foreground recovery just registered.
    private var lifecycleGeneration = 0

    func sceneBecameActive() {
        activeSceneCount += 1
        guard activeSceneCount == 1 else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        Task { await applicationBecameActive(lifecycleGeneration: generation) }
    }

    func sceneResignedActive() {
        activeSceneCount = max(0, activeSceneCount - 1)
        // Privacy masking engages for EVERY resigning scene: iOS captures
        // that scene's snapshot even while another window stays active.
        engageAppLockForInactiveScene()
        guard activeSceneCount == 0 else { return }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        Task { await applicationBecameInactive(lifecycleGeneration: generation) }
    }

    func applicationBecameInactive(lifecycleGeneration generation: Int? = nil) async {
        isApplicationActive = false
        // The lock engages synchronously, before the first suspension point:
        // iOS can capture the app-switcher snapshot as soon as the scene
        // resigns active, and stream teardown below can await persistence
        // work with conversations still on screen.
        if appLock.isEnabled, phase == .signedIn { isAppLocked = true }
        AppLog.generation.info("Application became inactive; checkpointing and detaching generation streams.")
        cancelGenerationRecovery()
        generationRecoverySignal = nil
        // The validating closure is checked at the repository's
        // post-checkpoint cancellation boundary — after the await that could
        // have been superseded by a foreground recovery.
        await activeRuntime?.repository.detachActiveStreams(
            validating: { [weak self] in self?.lifecycleGeneration == generation }
        )
        if let generation, generation != lifecycleGeneration { return }
        // Checkpointing can have (re)created SQLite sidecars; re-apply their
        // backup exclusion while inactive/background — the state in which
        // iCloud backups actually run.
        AppDependencies.excludePrivateDataFromBackups(
            storeURL: AppDependencies.defaultCacheStoreURL
        )
    }

    func applicationBecameActive(lifecycleGeneration generation: Int? = nil) async {
        // A stale active callback (superseded by a later resignation) must
        // not mark the app active or restart work.
        guard generation == nil || generation == lifecycleGeneration else { return }
        isApplicationActive = true
        // SQLite can recreate -wal/-shm sidecars after the one-shot
        // exclusion; re-apply it on every activation so replacements never
        // stay backup-eligible.
        AppDependencies.excludePrivateDataFromBackups(storeURL: AppDependencies.defaultCacheStoreURL)
        guard phase == .signedIn, !isOffline, let repository = activeRuntime?.repository else { return }
        await uploadManager?.applicationBecameActive()
        // Re-check: the upload-manager round-trip is a suspension point.
        guard generation == nil || generation == lifecycleGeneration else { return }
        AppLog.generation.info("Application became active; starting generation reconciliation.")
        startGenerationRecovery(
            repository: repository,
            profileID: selectedServer?.id,
            accountID: selectedServer?.accountIdentifier,
            publishToVisibleChat: true
        )
    }

    func setAppLockEnabled(_ enabled: Bool) async {
        // Enabling without a usable device-authentication policy would brick
        // the app behind an unlock that can never succeed.
        if enabled {
            do {
                if try await appLock.canUnlock() == false {
                    notice = "Set up a passcode or biometrics before enabling the app lock."
                    return
                }
            } catch {
                notice = "Set up a passcode or biometrics before enabling the app lock."
                return
            }
        }
        appLock.isEnabled = enabled
        if !enabled { isAppLocked = false }
    }

    func unlockApp() async {
        do {
            if try await appLock.unlock() { isAppLocked = false }
        } catch {
            notice = "Device authentication was not completed."
        }
    }

    func beginTwoFactorSetup() async throws -> TwoFactorSetup {
        guard let activeRuntime else { throw LibreChatProtocolError.unauthorized }
        return try await activeRuntime.protocolRuntime.authSession.beginTwoFactorSetup()
    }

    func confirmTwoFactorSetup(code: String) async throws {
        guard let activeRuntime else { throw LibreChatProtocolError.unauthorized }
        let selectionEpoch = profileSelectionEpoch
        let originatingAccountID = user?.id
        try await activeRuntime.protocolRuntime.authSession.confirmTwoFactorSetup(code: code)
        await activeRuntime.protocolRuntime.authSession.updateTwoFactorStatus(true)
        // Another scene can switch profiles or accounts while the request is
        // suspended; the result must never mutate the new account's 2FA state.
        guard selectionEpoch == profileSelectionEpoch,
              user?.id == originatingAccountID else { return }
        updateTwoFactorStatus(true)
    }

    func regenerateBackupCodes(proof: TwoFactorProof) async throws -> [String] {
        guard let activeRuntime else { throw LibreChatProtocolError.unauthorized }
        return try await activeRuntime.protocolRuntime.authSession.regenerateBackupCodes(proof: proof)
    }

    func disableTwoFactor(proof: TwoFactorProof) async throws {
        guard let activeRuntime else { throw LibreChatProtocolError.unauthorized }
        let selectionEpoch = profileSelectionEpoch
        let originatingAccountID = user?.id
        try await activeRuntime.protocolRuntime.authSession.disableTwoFactor(proof: proof)
        await activeRuntime.protocolRuntime.authSession.updateTwoFactorStatus(false)
        guard selectionEpoch == profileSelectionEpoch,
              user?.id == originatingAccountID else { return }
        updateTwoFactorStatus(false)
    }

    /// Avatar mutations advance this so a profile GET that captured the old
    /// avatar can never overwrite the freshly reconciled account.
    private var accountStateRevision = 0

    func refreshAccountProfile() async throws -> UserAccount {
        guard phase == .signedIn,
              !isOffline,
              let runtime = activeRuntime,
              let profile = selectedServer else {
            throw LibreChatProtocolError.unauthorized
        }
        let selectionEpoch = profileSelectionEpoch
        accountStateRevision &+= 1
        let revision = accountStateRevision
        let account = try await runtime.repository.accountProfile()
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        guard profile.id == selectedServer?.id,
              account.id == selectedServer?.accountIdentifier else {
            throw AccountProfileError.accountMismatch
        }
        let resolvedAccount = Self.accountWithResolvedAvatar(account, baseURL: profile.baseURL)
        // An overlapping avatar mutation supersedes this older read.
        guard revision == accountStateRevision else { return resolvedAccount }
        authenticationState = .authenticated(resolvedAccount)
        try await dependencies.cache.saveAccount(profileID: profile.id, account: resolvedAccount)
        return resolvedAccount
    }

    /// LibreChat reports the account avatar as a site-relative path
    /// (`/images/<file>`). Left unresolved, the URL has no scheme or host:
    /// plain image requests fail and every surface falls back to initials.
    /// Resolve it against the active server origin with the same policy used
    /// for target icons, so the authenticated image pipeline can fetch it.
    static func accountWithResolvedAvatar(_ account: UserAccount, baseURL: URL) -> UserAccount {
        var resolved = account
        guard let raw = account.avatarURL?.absoluteString
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return account }
        resolved.avatarURL = TargetIconURLPolicy(
            allowsInsecureLoopback: baseURL.scheme?.lowercased() == "http"
        ).resolve(raw, relativeTo: baseURL)?.url
        return resolved
    }

    /// Fetches raw bytes for a server-hosted entity image through the active
    /// profile's authenticated transport (see `LibreChatRepository.imageData`).
    func imageData(at url: URL) async throws -> Data {
        guard let repository = activeRuntime?.repository else {
            throw LibreChatProtocolError.unauthorized
        }
        // Relative content paths (message image_url) resolve against the
        // selected server's origin.
        if url.absoluteString.hasPrefix("/") {
            guard let baseURL = selectedServer?.baseURL else {
                throw LibreChatProtocolError.unauthorized
            }
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = url.path
            components?.query = url.query
            guard let absolute = components?.url else {
                throw LibreChatProtocolError.invalidResponse
            }
            return try await repository.imageData(at: absolute)
        }
        return try await repository.imageData(at: url)
    }

    func uploadAccountAvatar(_ upload: AccountAvatarUpload) async throws -> UserAccount {
        guard phase == .signedIn,
              !isOffline,
              let runtime = activeRuntime,
              let profile = selectedServer,
              let account = user else {
            throw LibreChatProtocolError.unauthorized
        }
        let selectionEpoch = profileSelectionEpoch
        let reconciledAccount = try await runtime.repository.uploadAccountAvatar(
            upload,
            previousAvatarURL: account.avatarURL
        )
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        guard profile.id == selectedServer?.id,
              reconciledAccount.id == selectedServer?.accountIdentifier else {
            throw AccountProfileError.accountMismatch
        }
        let resolvedAccount = Self.accountWithResolvedAvatar(reconciledAccount, baseURL: profile.baseURL)
        // The confirmed avatar supersedes any profile read captured before it.
        accountStateRevision &+= 1
        authenticationState = .authenticated(resolvedAccount)
        try await dependencies.cache.saveAccount(profileID: profile.id, account: resolvedAccount)
        return resolvedAccount
    }

    func deleteCurrentAccount(proof: TwoFactorProof?) async throws {
        guard canDeleteAccount,
              let runtime = activeRuntime,
              var profile = selectedServer,
              let accountID = profile.accountIdentifier else {
            throw AccountDeletionError.notPermitted
        }
        if user?.twoFactorEnabled == true {
            guard let proof,
                  !proof.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AccountDeletionError.verificationRequired
            }
        }

        let selectionEpoch = profileSelectionEpoch
        let originatingAccountID = accountID
        try await runtime.repository.deleteAccount(proof: proof)
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)

        cancelGenerationRecovery()
        generationRecoverySignal = nil
        await runtime.repository.detachActiveStreams()
        try? await runtime.protocolRuntime.authSession.clearAuthentication(clearCookies: true)
        do {
            try await dependencies.cache.purge(profileID: profile.id, accountID: accountID)
        } catch {
            await hideCache(profileID: profile.id, accountID: accountID)
            AppLog.persistence.error("Deleted-account cache purge failed; the namespace was hidden.")
        }
        UnsentCanvasManifestStore.removeAll(
            profileID: profile.id.rawValue,
            accountID: accountID.rawValue
        )
        UploadManager.removeStagingDirectory(profileID: profile.id, accountID: accountID)
        await runtime.repository.resetInMemoryState()
        // Cleanup suspended past the earlier epoch check: if another scene
        // selected a different profile meanwhile, the deleted account's
        // manager must be torn down — but never the new profile's, and never
        // when a different account was installed on this same profile.
        guard selectionEpoch == profileSelectionEpoch,
              selectedServer?.accountIdentifier == originatingAccountID else { return }
        await uploadManager?.resetAfterCachePurge()
        // The reset drains cancelled upload tasks and suspends; revalidate
        // before the global mutations.
        guard selectionEpoch == profileSelectionEpoch,
              selectedServer?.accountIdentifier == originatingAccountID else { return }
        uploadManager = nil
        profile.accountIdentifier = nil
        if let capabilities = profile.capabilities {
            profile.capabilities = capabilities.failingClosedAuthenticatedPolicy()
        }
        selectedServer = profile
        compatibility = profile.capabilities.map {
            CompatibilityResult(supported: true, warnings: [], capabilities: $0)
        }
        replaceProfile(profile)
        try? await dependencies.cache.save(profile: profile, selected: true)
        authenticationState = .signedOut(profile.id)
        pendingTerms = nil
        notice = "Account deleted. Local data for that account was removed from this device."
        phase = .signedOut
    }

    private func updateTwoFactorStatus(_ enabled: Bool) {
        guard var user else { return }
        user.twoFactorEnabled = enabled
        authenticationState = .authenticated(user)
    }

    func recordMemoriesEnabled(
        _ enabled: Bool,
        profileID: ServerProfileID?,
        accountID: AccountID?
    ) async {
        guard var user, let selectedServer else { return }
        // A preference callback from a superseded profile must not corrupt
        // the active account's record.
        guard selectedServer.id == profileID, user.id == accountID else { return }
        user.memoriesEnabled = enabled
        authenticationState = .authenticated(user)
        try? await dependencies.cache.saveAccount(profileID: selectedServer.id, account: user)
    }

    private func accept(
        session: AuthenticatedSession,
        runtime: ProfileRuntime,
        replacingAccount: Bool,
        selectionEpoch: Int? = nil
    ) async throws {
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        guard var profile = selectedServer else { throw LibreChatProtocolError.invalidResponse }
        generationRecoverySignal = nil
        if let existing = profile.accountIdentifier,
           existing != session.user.id,
           !replacingAccount {
            pendingAccountReplacement = session
            authenticationState = .signedOut(profile.id)
            phase = .signedOut
            return
        }

        profile.accountIdentifier = session.user.id
        selectedServer = profile
        pendingAccountReplacement = nil
        pendingTerms = nil
        // The avatar filepath is resolved against this server's origin
        // before the account is persisted, so every avatar surface (account
        // button, Settings) fetches a complete, authenticated URL.
        let resolvedUser = Self.accountWithResolvedAvatar(session.user, baseURL: profile.baseURL)
        await runtime.repository.activate(account: session.user)
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        do {
            let authenticatedCompatibility = try await runtime.repository.discoverCapabilities(
                authenticated: true
            )
            try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
            compatibility = authenticatedCompatibility
            profile.capabilities = authenticatedCompatibility.capabilities
            selectedServer = profile
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
            let capabilities = (profile.capabilities ?? ServerCapabilities())
                .failingClosedAuthenticatedPolicy()
            compatibility = CompatibilityResult(
                supported: true,
                warnings: [.featureUnavailable("Authenticated server policy")],
                capabilities: capabilities
            )
            profile.capabilities = capabilities
            selectedServer = profile
            notice = "Signed in, but account features could not be verified. They remain unavailable until server policy refresh succeeds."
        }
        pendingTerms = nil
        if let terms = profile.capabilities?.publicLegal?.termsOfService,
           terms.requiresAcceptance {
            do {
                let status = try await runtime.repository.termsAcceptanceStatus()
                if !status.accepted { pendingTerms = terms }
            } catch {
                // Match LibreChat's web behavior: a failed optional terms
                // status lookup must not leave a newly authenticated session
                // half-installed. Authorization remains authoritative on the
                // next protected request.
                AppLog.authentication.error("Terms acceptance status could not be loaded.")
            }
        }
        let uploadManager = UploadManager(
            profileID: profile.id,
            accountID: session.user.id,
            runtime: runtime.protocolRuntime,
            cache: dependencies.cache
        )
        // Install before restoring: a selection that supersedes this one
        // during the suspending restore discovers the manager here and drains
        // it, so no restored upload dispatches after ownership was lost.
        self.uploadManager = uploadManager
        do {
            try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        } catch {
            await uploadManager.resetAfterCachePurge()
            self.uploadManager = nil
            throw error
        }
        await uploadManager.restore()
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        try await dependencies.cache.saveAccount(profileID: profile.id, account: resolvedUser)
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        try await dependencies.cache.save(profile: profile, selected: true)
        try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
        replaceProfile(profile)
        authenticationState = .authenticated(resolvedUser)
        phase = .signedIn
        AppLog.authentication.notice("Authenticated session committed to app state.")
        startGenerationRecovery(
            repository: runtime.repository,
            profileID: profile.id,
            accountID: session.user.id
        )
    }

    func refreshAuthenticatedServerPolicy() async {
        guard phase == .signedIn,
              !isRefreshingServerPolicy,
              let runtime = activeRuntime,
              var profile = selectedServer,
              profile.accountIdentifier != nil else { return }

        let selectionEpoch = profileSelectionEpoch
        let originatingAccountID = profile.accountIdentifier
        let wasUnavailable = authenticatedServerPolicyUnavailable
        isRefreshingServerPolicy = true
        defer {
            if selectionEpoch == profileSelectionEpoch {
                isRefreshingServerPolicy = false
            }
        }

        do {
            let result = try await runtime.repository.discoverCapabilities(authenticated: true)
            try ensureCurrent(runtime: runtime, selectionEpoch: selectionEpoch)
            // Same-profile account replacement during the refresh must not
            // receive A's refreshed policy projection.
            guard selectedServer?.accountIdentifier == originatingAccountID else { return }
            profile.capabilities = result.capabilities
            selectedServer = profile
            compatibility = result
            replaceProfile(profile)
            try? await dependencies.cache.save(profile: profile, selected: true)
            if wasUnavailable { notice = nil }
        } catch LibreChatProtocolError.unauthorized {
            // A 401 belonging to a superseded account must not sign out the
            // account now installed on this profile.
            guard selectedServer?.accountIdentifier == originatingAccountID else { return }
            await invalidateSession(
                for: profile,
                runtime: runtime,
                selectionEpoch: selectionEpoch,
                originatingAccountID: originatingAccountID
            )
        } catch {
            guard selectionEpoch == profileSelectionEpoch,
                  selectedServer?.id == profile.id,
                  selectedServer?.accountIdentifier == originatingAccountID else { return }
            let capabilities = (profile.capabilities ?? ServerCapabilities())
                .failingClosedAuthenticatedPolicy()
            profile.capabilities = capabilities
            selectedServer = profile
            compatibility = CompatibilityResult(
                supported: true,
                warnings: [.featureUnavailable("Authenticated server policy")],
                capabilities: capabilities
            )
            replaceProfile(profile)
            try? await dependencies.cache.save(profile: profile, selected: true)
            notice = "Account features are still unavailable because server policy could not be refreshed."
        }
    }

    private func ensureCurrent(
        runtime: ProfileRuntime,
        selectionEpoch: Int?
    ) throws {
        guard selectedServer?.id == runtime.profile.id,
              activeRuntime?.profile.id == runtime.profile.id,
              selectionEpoch.map({ $0 == profileSelectionEpoch }) ?? true else {
            throw CancellationError()
        }
    }

    private func startGenerationRecovery(
        repository: LibreChatRepository,
        profileID: ServerProfileID?,
        accountID: AccountID?,
        publishToVisibleChat: Bool = false,
        trigger: GenerationRecoveryTrigger = .foreground
    ) {
        guard let profileID, let accountID else { return }
        generationRecoveryTask?.cancel()
        let taskID = UUID()
        let selectionEpoch = profileSelectionEpoch
        generationRecoveryTaskID = taskID
        generationRecoveryTask = Task { [weak self] in
            do {
                guard let self else { return }
                let queueRecovery = try await self.reconcileFollowUpAdmissions(
                    repository: repository,
                    profileID: profileID,
                    accountID: accountID,
                    selectionEpoch: selectionEpoch
                )
                try Task.checkCancellation()
                let snapshots = try await repository.recoverActiveGenerations()
                try Task.checkCancellation()
                guard self.generationRecoveryTaskID == taskID,
                      self.profileSelectionEpoch == selectionEpoch,
                      self.selectedServer?.id == profileID,
                      self.selectedServer?.accountIdentifier == accountID else { return }
                if publishToVisibleChat {
                    if self.generationRecoverySequence < .max {
                        self.generationRecoverySequence += 1
                        self.generationRecoverySignal = GenerationRecoverySignal(
                            sequence: self.generationRecoverySequence,
                            profileID: profileID,
                            accountID: accountID,
                            activeSnapshots: snapshots,
                            trigger: trigger
                        )
                    }
                }
                AppLog.generation.info(
                    "Generation recovery completed; recoverableCount=\(snapshots.count, privacy: .public), queueJournalCount=\(queueRecovery.journalCount, privacy: .public), queueReconciledCount=\(queueRecovery.reconciledCount, privacy: .public)."
                )
                self.finishGenerationRecovery(taskID: taskID)
            } catch is CancellationError {
                self?.finishGenerationRecovery(taskID: taskID)
                return
            } catch LibreChatProtocolError.unauthorized {
                guard let self,
                      self.generationRecoveryTaskID == taskID,
                      self.profileSelectionEpoch == selectionEpoch,
                      self.selectedServer?.id == profileID,
                      self.selectedServer?.accountIdentifier == accountID else { return }
                self.finishGenerationRecovery(taskID: taskID)
                await self.expireSession()
            } catch {
                guard let self, self.generationRecoveryTaskID == taskID else { return }
                self.finishGenerationRecovery(taskID: taskID)
                AppLog.generation.error("Server generation discovery failed; local checkpoints remain available.")
            }
        }
    }

    private func reconcileFollowUpAdmissions(
        repository: LibreChatRepository,
        profileID: ServerProfileID,
        accountID: AccountID,
        selectionEpoch: Int
    ) async throws -> (journalCount: Int, reconciledCount: Int) {
        let namespaces: [FollowUpQueueNamespace]
        do {
            namespaces = try await dependencies.cache.followUpQueueNamespaces(
                profileID: profileID,
                accountID: accountID
            )
        } catch {
            // A malformed queue journal is never treated as empty or removed.
            // Ordinary generation recovery may continue, but automatic queue
            // actions remain disabled until that cache state is repaired.
            AppLog.persistence.error(
                "Follow-up queue discovery failed closed; automatic queue reconciliation was skipped."
            )
            return (0, 0)
        }

        var reconciledCount = 0
        for namespace in namespaces {
            try Task.checkCancellation()
            guard profileSelectionEpoch == selectionEpoch,
                  selectedServer?.id == profileID,
                  selectedServer?.accountIdentifier == accountID else {
                throw CancellationError()
            }
            let coordinator = FollowUpQueueDrainCoordinator(
                cache: dependencies.cache,
                repository: repository,
                namespace: namespace
            )
            do {
                switch try await coordinator.reconcileOutstandingAdmission() {
                case .admitted, .committed, .deliveredWithoutEpoch, .delivered:
                    reconciledCount += 1
                case .noWork, .deliveryUncertain, .blocked, .ambiguous:
                    break
                }
            } catch FollowUpDrainError.unauthorized {
                throw LibreChatProtocolError.unauthorized
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Transport-unavailable or individually corrupt journals stay
                // locked under their exact attempt and cannot block recovery
                // for another conversation in the same account.
                continue
            }
        }
        return (namespaces.count, reconciledCount)
    }

    private func cancelGenerationRecovery() {
        generationRecoveryTask?.cancel()
        generationRecoveryTask = nil
        generationRecoveryTaskID = nil
    }

    private func finishGenerationRecovery(taskID: UUID) {
        guard generationRecoveryTaskID == taskID else { return }
        generationRecoveryTask = nil
        generationRecoveryTaskID = nil
    }

    private func receiveConnectivityPath(reachable: Bool) {
        guard connectivityRecoveryGate.receivesPath(reachable: reachable),
              isApplicationActive,
              phase == .signedIn,
              !isOffline,
              let repository = activeRuntime?.repository,
              let profileID = selectedServer?.id,
              let accountID = selectedServer?.accountIdentifier else { return }

        AppLog.generation.info("Network connectivity returned; starting generation reconciliation.")
        Task { await uploadManager?.applicationBecameActive() }
        startGenerationRecovery(
            repository: repository,
            profileID: profileID,
            accountID: accountID,
            publishToVisibleChat: true,
            trigger: .connectivity
        )
    }

    private func invalidateSession(
        for profile: ServerProfile,
        runtime: ProfileRuntime,
        selectionEpoch: Int,
        originatingAccountID: AccountID? = nil
    ) async {
        try? await runtime.protocolRuntime.authSession.clearAuthentication(clearCookies: true)
        generationRecoverySignal = nil
        if let accountID = profile.accountIdentifier {
            await hideCache(profileID: profile.id, accountID: accountID)
        }
        // A same-profile account replacement across these suspensions owns
        // the shared session; the stale invalidation must not sign it out.
        guard selectionEpoch == profileSelectionEpoch,
              selectedServer?.id == profile.id,
              selectedServer?.accountIdentifier == profile.accountIdentifier else { return }
        authenticationState = .signedOut(profile.id)
        phase = .signedOut
    }

    private func hideCache(profileID: ServerProfileID, accountID: AccountID) async {
        do {
            try await dependencies.cache.setCacheVisible(
                false,
                profileID: profileID,
                accountID: accountID
            )
        } catch {
            // If visibility metadata cannot be persisted, deletion is safer than
            // exposing signed-out data through a later offline restoration.
            do {
                try await dependencies.cache.purge(profileID: profileID, accountID: accountID)
            } catch {
                AppLog.persistence.fault("Signed-out cache could not be hidden or purged.")
            }
        }
    }

    private func updateSelectedCapabilities(_ capabilities: ServerCapabilities) {
        guard var profile = selectedServer else { return }
        profile.capabilities = capabilities
        selectedServer = profile
        replaceProfile(profile)
    }

    private func replaceProfile(_ profile: ServerProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.insert(profile, at: 0)
        }
    }

    private func migrateLegacyServerIfNeeded() async throws {
        guard profiles.isEmpty,
              let saved = UserDefaults.standard.string(forKey: Self.legacyServerKey),
              let address = try? ServerAddress.parse(saved) else { return }
        let profile = ServerProfile(
            baseURL: address.url,
            displayName: address.displayName,
            trustPolicy: address.url.scheme == "http" ? .localDevelopment : .system
        )
        try await dependencies.cache.save(profile: profile, selected: true)
        profiles = [profile]
        UserDefaults.standard.removeObject(forKey: Self.legacyServerKey)
    }
}
