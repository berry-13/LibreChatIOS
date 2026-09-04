import Foundation
import LibreChatDomain
import LibreChatProtocol
import OSLog

actor LibreChatRepository: AccountAccessRepository, AccountProfileRepository, ConversationRepository, ConversationForkRepository, ConversationDuplicationRepository, TargetCatalogRepository, UserKeyRepository, AgentRepository, AgentManagementRepository, BasicAgentCreationRepository, SkillRepository, MCPRepository, MemoryRepository, PromptRepository, PromptManagementRepository, PresetRepository, PresetCreationRepository, FileLibraryRepository, ConversationManagementRepository, ConversationTagRepository, ProjectRepository, SharedLinkRepository, SharedSnapshotRepository, ChatRepository, ChatFollowUpRepository, RecoverableSteerRepository, RecoverableSteerDiscardRepository, GenerationSteeringRepository, MessageEditingRepository, MessageFeedbackRepository, ArtifactRepository, GeneratedFileRepository, SpeechTranscriptionRepository, SpeechSynthesisRepository {
    private static let generationProtocolVersion = 2
    private static let generationProtocolHeader = "X-LibreChat-Generation-Protocol"
    private static let noParentMessageID = "00000000-0000-0000-0000-000000000000"

    private var profile: ServerProfile
    private var accountID: AccountID?
    private var activeUserRole: String?
    private let runtime: LibreChatRuntime
    private let cache: CacheCoordinator
    private let generationSession: GenerationSession
    private let fileTransfer: FileTransferManager
    private var fileDeletionIDs: Set<String> = []
    private let generationStartSleep: @Sendable (Duration) async throws -> Void
    private let generationDecoder = LibreChatGenerationDecoder()
    private var initialResume: [GenerationHandle: Bool] = [:]
    private var lastCheckpoint: [GenerationHandle: Date] = [:]
    private var latestSnapshots: [GenerationHandle: GenerationSnapshot] = [:]
    private var activeStreamTasks: [GenerationHandle: Task<Void, Never>] = [:]
    private var steeringControlLanes: [GenerationHandle: SteeringControlLane] = [:]
    private var fileTransferEpoch: UInt64 = 0
    private var startupConfiguration: StartupConfigDTO?
    private var conversationSynchronizationIDs: Set<ConversationID>?
    private var nextConversationSynchronizationCursor: String?
    private var memoryCharacterLimit: Int?
    private var temporaryConversationIDs: Set<ConversationID> = []
    private var promptMutationID: UUID?
    private var presetMutationID: UUID?
    private var basicAgentCreationID: UUID?
    private var agentMutationIDs: [AgentID: UUID] = [:]
    private var skillActivationMutationID: UUID?

    init(
        profile: ServerProfile,
        runtime: LibreChatRuntime,
        cache: CacheCoordinator,
        eventStreamTransport: (any EventStreamTransport)? = nil,
        generationStartSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.profile = profile
        accountID = profile.accountIdentifier
        self.runtime = runtime
        self.cache = cache
        self.generationStartSleep = generationStartSleep
        generationSession = GenerationSession(
            transport: eventStreamTransport ?? URLSessionEventStreamTransport(
                observability: AppLog.protocolObservability
            )
        )
        fileTransfer = FileTransferManager(runtime: runtime)
    }

    func activate(account: UserAccount) {
        accountID = account.id
        activeUserRole = account.role
        startupConfiguration = nil
        profile.accountIdentifier = account.id
        conversationSynchronizationIDs = nil
        nextConversationSynchronizationCursor = nil
        memoryCharacterLimit = nil
        temporaryConversationIDs.removeAll()
        promptMutationID = nil
        presetMutationID = nil
        basicAgentCreationID = nil
        agentMutationIDs.removeAll()
        skillActivationMutationID = nil
    }

    func update(profile: ServerProfile) {
        let namespaceChanged = self.profile.id != profile.id
            || accountID != profile.accountIdentifier
        self.profile = profile
        accountID = profile.accountIdentifier
        if namespaceChanged {
            startupConfiguration = nil
            temporaryConversationIDs.removeAll()
            promptMutationID = nil
            presetMutationID = nil
            basicAgentCreationID = nil
            agentMutationIDs.removeAll()
            skillActivationMutationID = nil
        }
    }

    func currentCapabilities() -> ServerCapabilities? { profile.capabilities }

    func discoverCapabilities(authenticated: Bool = false) async throws -> CompatibilityResult {
        let request = APIRequest<StartupConfigDTO>(
            path: "api/config",
            authorization: authenticated ? .bearer : .none,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        let config = try await runtime.restClient.send(request)
        startupConfiguration = config
        var result = CapabilityDetector().detect(
            startup: config,
            authenticated: authenticated
        )
        do {
            let mobileRequest = APIRequest<MobileAuthenticationConfigDTO>(
                path: "api/auth/mobile/config",
                authorization: .none,
                retryPolicy: .idempotent(maximumAttempts: 1)
            )
            let mobile = try await runtime.restClient.send(mobileRequest)
            if mobile.protocolVersion == 1 {
                result.capabilities.supportsMobileAuthentication = true
            }
        } catch {
            // The mobile authorization-code extension is explicitly optional.
        }
        if authenticated {
            do {
                let endpointConfiguration = try await runtime.restClient.send(
                    APIRequest<JSONValue>(
                        path: "api/endpoints",
                        authorization: .bearer,
                        retryPolicy: .idempotent(maximumAttempts: 2)
                    )
                )
                // `/api/config` deliberately does not expose endpoint
                // configuration. Agent availability must be derived from the
                // authenticated endpoint catalog rather than a startup-config
                // heuristic or build version.
                result.capabilities.supportsAgents = endpointConfiguration
                    .objectValue?["agents"]?.objectValue != nil
                result.capabilities.supportsSkills = endpointConfiguration
                    .objectValue?["agents"]?.objectValue?["capabilities"]?.arrayValue?
                    .contains(where: { $0.stringValue == "skills" }) == true
            } catch LibreChatProtocolError.unauthorized {
                throw LibreChatProtocolError.unauthorized
            } catch {
                result.capabilities.supportsAgents = false
                result.warnings.append(.featureUnavailable("Agent discovery"))
            }
        }
        if authenticated, let roleName = activeUserRole, !roleName.isEmpty {
            do {
                let role = try await runtime.restClient.send(
                    LibreChatRolesAPI.get(roleName: roleName)
                )
                result.capabilities = LibreChatRoleCapabilityMapper.applying(
                    role,
                    to: result.capabilities
                )
                // The current-role response is stronger evidence than loose
                // interface-key matching. The feature entry points still let
                // their own routes return authoritative 403/404 results.
                result.capabilities.supportsMCP = role.mcpPermissions.use
                result.capabilities.supportsMemories = role.memoryPermissions.canRead
                result.capabilities.supportsAgents = result.capabilities.supportsAgents
                    && role.agentPermissions.use
                result.capabilities.supportsSkills = result.capabilities.supportsSkills == true
                    && role.skillPermissions.use
            } catch let error as LibreChatProtocolError {
                if case .unauthorized = error { throw error }
                // Permission discovery is additive. If the current server
                // cannot expose its role contract, keep the capability
                // unknown and fail closed in presentation.
            }
        }
        if authenticated {
            do {
                let speech = try await runtime.restClient.send(
                    LibreChatSpeechAPI.configuration()
                ).domainModel()
                result.capabilities.speechCapabilities = speech
                result.capabilities.supportsSpeech = result.capabilities.supportsSpeech
                    || speech.supportsSpeechToText
                    || speech.supportsTextToSpeech
            } catch LibreChatProtocolError.unauthorized {
                throw LibreChatProtocolError.unauthorized
            } catch let LibreChatProtocolError.httpStatus(status, _, _)
                where status == 404 || status == 405 {
                result.capabilities.speechCapabilities = SpeechCapabilities(
                    supportsSpeechToText: false,
                    supportsTextToSpeech: false
                )
            } catch {
                // Keep this feature unknown after transient discovery failure.
                // A later authenticated capability refresh may prove it.
                result.capabilities.speechCapabilities = nil
            }
        }
        profile.capabilities = result.capabilities
        try? await cache.save(profile: profile)
        return result
    }

    func mobileAuthenticationConfiguration() async throws -> MobileAuthenticationConfigDTO {
        let request = APIRequest<MobileAuthenticationConfigDTO>(
            path: "api/auth/mobile/config",
            authorization: .none,
            retryPolicy: .idempotent(maximumAttempts: 1)
        )
        return try await runtime.restClient.send(request)
    }

    func exchangeMobileAuthorization(_ grant: MobileAuthorizationGrant) async throws -> AuthenticatedSession {
        let payload = MobileTokenExchangeRequestDTO(
            code: grant.code,
            codeVerifier: grant.verifier,
            redirectURI: grant.redirectURI.absoluteString
        )
        let request = try APIRequest<MobileTokenResponseDTO>(
            path: "api/auth/mobile/token",
            body: payload,
            authorization: .none,
            retryPolicy: .never
        )
        let session = try await runtime.restClient.send(request).domainModel()
        await runtime.authSession.setAuthenticated(session)
        activate(account: session.user)
        return session
    }

    func healthCheck() async throws {
        let response = try await runtime.restClient.rawResponse(
            method: .get,
            path: "health",
            authorized: false
        )
        let value = String(decoding: response.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.caseInsensitiveCompare("OK") == .orderedSame else {
            throw LibreChatProtocolError.unsupported(
                "That address responded, but it does not look like a LibreChat server."
            )
        }
    }

    func requestPasswordReset(email: String) async throws -> PasswordResetRequestResult {
        let response = try await runtime.restClient.send(
            LibreChatAccountAccessAPI.requestPasswordReset(email: email)
        )
        return response.domainModel()
    }

    func register(_ registration: AccountRegistration) async throws -> RegistrationResult {
        try await runtime.restClient.send(
            LibreChatAccountAccessAPI.register(registration)
        ).domainModel()
    }

    func completePasswordReset(
        _ completion: PasswordResetCompletion
    ) async throws -> PasswordResetCompletionResult {
        try await runtime.restClient.send(
            LibreChatAccountAccessAPI.completePasswordReset(completion)
        ).domainModel()
    }

    func verifyEmail(_ verification: EmailVerification) async throws -> EmailVerificationResult {
        try await runtime.restClient.send(
            LibreChatAccountAccessAPI.verifyEmail(verification)
        ).domainModel()
    }

    func resendEmailVerification(email: String) async throws -> EmailVerificationResendResult {
        try await runtime.restClient.send(
            LibreChatAccountAccessAPI.resendEmailVerification(email: email)
        ).domainModel()
    }

    func termsAcceptanceStatus() async throws -> TermsAcceptanceStatus {
        try await runtime.restClient.send(
            LibreChatAccountAccessAPI.termsAcceptanceStatus()
        ).domainModel()
    }

    func acceptTerms() async throws -> TermsAcceptanceStatus {
        try await runtime.restClient.send(
            LibreChatAccountAccessAPI.acceptTerms()
        ).domainModel()
    }

    func cachedConversations(limit: Int) async throws -> ConversationPage? {
        let accountID = try activeAccountID()
        return try await cache.conversations(profileID: profile.id, accountID: accountID, limit: limit)
    }

    func conversations(cursor: String? = nil, limit: Int = 25) async throws -> ConversationPage {
        let accountID = try activeAccountID()
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "isArchived", value: "false"),
            URLQueryItem(name: "sortBy", value: "updatedAt"),
            URLQueryItem(name: "sortDirection", value: "desc")
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let request = APIRequest<LibreChatConversationPageDTO>(
            path: "api/convos",
            queryItems: query,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        let page = try await runtime.restClient.send(request).domainModel()
        var completeSynchronizationIDs: Set<ConversationID>?
        if cursor == nil {
            conversationSynchronizationIDs = Set(page.conversations.map(\.id))
            nextConversationSynchronizationCursor = page.nextCursor
            if page.nextCursor == nil {
                completeSynchronizationIDs = conversationSynchronizationIDs
            }
        } else if cursor == nextConversationSynchronizationCursor,
                  var received = conversationSynchronizationIDs {
            received.formUnion(page.conversations.map(\.id))
            conversationSynchronizationIDs = received
            nextConversationSynchronizationCursor = page.nextCursor
            if page.nextCursor == nil {
                completeSynchronizationIDs = received
            }
        } else {
            conversationSynchronizationIDs = nil
            nextConversationSynchronizationCursor = nil
        }
        try await cache.save(
            page: page,
            profileID: profile.id,
            accountID: accountID,
            completeSynchronization: false
        )
        if let completeSynchronizationIDs {
            try await cache.completeConversationSynchronization(
                profileID: profile.id,
                accountID: accountID,
                receivedIDs: completeSynchronizationIDs
            )
            conversationSynchronizationIDs = nil
            nextConversationSynchronizationCursor = nil
        }
        return page
    }

    func archivedConversations(
        cursor: String? = nil,
        limit: Int = 25
    ) async throws -> ConversationPage {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "isArchived", value: "true"),
            URLQueryItem(name: "sortBy", value: "updatedAt"),
            URLQueryItem(name: "sortDirection", value: "desc")
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await runtime.restClient.send(APIRequest<LibreChatConversationPageDTO>(
            path: "api/convos",
            queryItems: query,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )).domainModel()
    }

    func searchConversations(
        query: String,
        cursor: String? = nil,
        limit: Int = 25
    ) async throws -> ConversationPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return ConversationPage(conversations: [], nextCursor: nil)
        }
        let request = LibreChatSearchAPI.conversations(
            matching: trimmedQuery,
            cursor: cursor,
            limit: limit
        )
        return try await runtime.restClient.send(request).domainModel()
    }

    func searchMessages(query: String) async throws -> MessageSearchPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return MessageSearchPage(results: [], nextCursor: nil)
        }
        let request = LibreChatSearchAPI.messages(matching: trimmedQuery)
        return try await runtime.restClient.send(request).domainSearchPage()
    }

    func agents(
        search: String? = nil,
        cursor: String? = nil,
        limit: Int = 25
    ) async throws -> ChatAgentPage {
        _ = try activeAccountID()
        let response = try await runtime.restClient.send(
            LibreChatAgentsAPI.list(search: search, cursor: cursor, limit: limit)
        )
        let nextCursor: String?
        if response.hasMore {
            guard let value = response.after?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw LibreChatProtocolError.invalidResponse
            }
            nextCursor = value
        } else {
            nextCursor = nil
        }

        var seen = Set<AgentID>()
        let agents = response.data.compactMap { dto -> ChatAgentSummary? in
            guard let agent = try? dto.summaryModel(avatarBaseURL: profile.baseURL),
                  seen.insert(agent.id).inserted else {
                return nil
            }
            return agent
        }
        return ChatAgentPage(agents: agents, nextCursor: nextCursor)
    }

    func agent(id: AgentID) async throws -> ChatAgentDetail {
        _ = try activeAccountID()
        let request = try LibreChatAgentsAPI.detail(id: id)
        let detail = try await runtime.restClient.send(request).domainModel()
        guard detail.id == id else { throw LibreChatProtocolError.invalidResponse }
        return detail
    }

    func skillInvocationCatalog(
        for target: ConversationTarget
    ) async throws -> SkillInvocationCatalog {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        guard let roleName = activeUserRole?.trimmingCharacters(in: .whitespacesAndNewlines),
              !roleName.isEmpty,
              GenerationEndpointPolicy.route(for: target).supportsResumableV2 else {
            throw SkillInvocationError.unavailable
        }
        let roleRequest = try LibreChatRolesAPI.get(roleName: roleName)

        async let endpointsValue = runtime.restClient.send(APIRequest<JSONValue>(
            path: "api/endpoints",
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))
        async let startupValue = runtime.restClient.send(APIRequest<StartupConfigDTO>(
            path: "api/config",
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))
        async let roleValue = runtime.restClient.send(roleRequest)
        async let activeStateValue = runtime.restClient.send(
            LibreChatSkillsAPI.activeStates()
        )
        async let firstPageValue = runtime.restClient.send(
            LibreChatSkillsAPI.list(limit: 100)
        )

        let (endpoints, startup, role, activeStates, firstPage) = try await (
            endpointsValue,
            startupValue,
            roleValue,
            activeStateValue,
            firstPageValue
        )
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              role.skillPermissions.use,
              endpoints.objectValue?["agents"]?.objectValue?["capabilities"]?.arrayValue?
                .contains(where: { $0.stringValue == "skills" }) == true else {
            throw SkillInvocationError.unavailable
        }

        var wireSkills = firstPage.skills
        var page = firstPage
        var seenIDs = Set(firstPage.skills.compactMap(\.id))
        guard seenIDs.count == firstPage.skills.compactMap(\.id).count else {
            throw SkillInvocationError.invalidCatalog
        }
        var pageCount = 1
        while page.hasMore == true, pageCount < 10 {
            guard let cursor = page.after?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cursor.isEmpty else {
                throw SkillInvocationError.invalidCatalog
            }
            page = try await runtime.restClient.send(
                LibreChatSkillsAPI.list(limit: 100, cursor: cursor)
            )
            for skill in page.skills {
                guard let id = skill.id, seenIDs.insert(id).inserted else {
                    throw SkillInvocationError.invalidCatalog
                }
                wireSkills.append(skill)
            }
            pageCount += 1
        }
        guard page.hasMore != true else { throw SkillInvocationError.invalidCatalog }

        let scope: SkillInvocationTargetScope
        if target.endpoint == "agents" {
            guard let rawAgentID = target.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawAgentID.isEmpty else { throw SkillInvocationError.unavailable }
            let detail = try await agent(id: AgentID(rawValue: rawAgentID))
            scope = SkillInvocationTargetScope(
                capabilityEnabled: true,
                savedAgentScope: detail.skillScope
            )
        } else {
            guard let configuration = target.ephemeralAgent else {
                throw SkillInvocationError.unavailable
            }
            scope = SkillInvocationTargetScope(
                capabilityEnabled: true,
                ephemeralScope: configuration.skillScope,
                ephemeralBadgeEnabled: configuration.skillScope == nil
            )
        }

        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw SkillInvocationError.targetChanged
        }
        let sharedDefaultActive = startup.interface?
            .objectValue?["skills"]?
            .objectValue?["defaultActiveOnShare"]?
            .boolValue == true
        return try LibreChatSkillsMapper.catalog(
            profileID: requestedProfileID,
            accountID: requestedAccountID,
            target: target,
            page: LibreChatSkillPageDTO(
                skills: wireSkills,
                hasMore: false,
                after: nil
            ),
            activeStates: activeStates,
            scope: scope,
            sharedDefaultActive: sharedDefaultActive
        )
    }

    func accountSkillCatalog() async throws -> AccountSkillCatalog {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        guard let roleName = activeUserRole?.trimmingCharacters(in: .whitespacesAndNewlines),
              !roleName.isEmpty else {
            throw SkillManagementError.unavailable
        }
        let roleRequest = try LibreChatRolesAPI.get(roleName: roleName)

        async let endpointsValue = runtime.restClient.send(APIRequest<JSONValue>(
            path: "api/endpoints",
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))
        async let startupValue = runtime.restClient.send(APIRequest<StartupConfigDTO>(
            path: "api/config",
            retryPolicy: .idempotent(maximumAttempts: 2)
        ))
        async let roleValue = runtime.restClient.send(roleRequest)
        async let activeStateValue = runtime.restClient.send(
            LibreChatSkillsAPI.activeStates()
        )
        async let firstPageValue = runtime.restClient.send(
            LibreChatSkillsAPI.list(limit: 100)
        )

        let (endpoints, startup, role, activeStates, firstPage) = try await (
            endpointsValue,
            startupValue,
            roleValue,
            activeStateValue,
            firstPageValue
        )
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              role.skillPermissions.use,
              endpoints.objectValue?["agents"]?.objectValue?["capabilities"]?.arrayValue?
                .contains(where: { $0.stringValue == "skills" }) == true else {
            throw SkillManagementError.unavailable
        }

        var wireSkills = firstPage.skills
        var page = firstPage
        var seenIDs = Set(firstPage.skills.compactMap(\.id))
        guard seenIDs.count == firstPage.skills.compactMap(\.id).count else {
            throw SkillManagementError.invalidCatalog
        }
        var seenCursors = Set<String>()
        var pageCount = 1
        while page.hasMore == true {
            guard pageCount < 100, wireSkills.count <= 10_000,
                  let cursor = page.after?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cursor.isEmpty,
                  seenCursors.insert(cursor).inserted else {
                throw SkillManagementError.invalidCatalog
            }
            page = try await runtime.restClient.send(
                LibreChatSkillsAPI.list(limit: 100, cursor: cursor)
            )
            for skill in page.skills {
                guard let id = skill.id, seenIDs.insert(id).inserted else {
                    throw SkillManagementError.invalidCatalog
                }
                wireSkills.append(skill)
            }
            pageCount += 1
        }
        guard wireSkills.count <= 10_000,
              profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw SkillManagementError.reviewedScopeMismatch
        }

        let sharedDefaultActive = startup.interface?
            .objectValue?["skills"]?
            .objectValue?["defaultActiveOnShare"]?
            .boolValue == true
        return try LibreChatSkillsMapper.accountCatalog(
            profileID: requestedProfileID,
            accountID: requestedAccountID,
            page: LibreChatSkillPageDTO(skills: wireSkills, hasMore: false, after: nil),
            activeStates: activeStates,
            sharedDefaultActive: sharedDefaultActive
        )
    }

    func chatFavorites() async throws -> [ChatFavorite] {
        let response = try await runtime.restClient.send(LibreChatFavoritesAPI.list())
        return response.compactMap(\.favorite)
    }

    /// Whole-list replacement through LibreChat's one-shot favorites POST.
    /// The decoded response is authoritative; a lost response is reconciled
    /// by the next read, never by reposting.
    func replaceChatFavorites(_ favorites: [ChatFavorite]) async throws -> [ChatFavorite] {
        let response = try await runtime.restClient.send(
            try LibreChatFavoritesAPI.replace(favorites)
        )
        return response.compactMap(\.favorite)
    }

    func setSkillActivation(
        _ request: SkillActivationRequest
    ) async throws -> SkillActivationOutcome {
        guard skillActivationMutationID == nil else {
            throw SkillManagementError.mutationInProgress
        }
        let operationID = UUID()
        skillActivationMutationID = operationID
        defer {
            if skillActivationMutationID == operationID {
                skillActivationMutationID = nil
            }
        }

        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        guard request.profileID == requestedProfileID,
              request.accountID == requestedAccountID else {
            throw SkillManagementError.reviewedScopeMismatch
        }
        guard LibreChatSkillsAPI.isMutableSkillID(request.skillID.rawValue) else {
            throw SkillManagementError.immutableSkillIdentifier
        }

        let before = try await accountSkillCatalog()
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              before.profileID == requestedProfileID,
              before.accountID == requestedAccountID,
              before.isComplete else {
            throw SkillManagementError.reviewedScopeMismatch
        }
        guard let skill = before.skill(id: request.skillID),
              skill.canChangeActivation else {
            throw SkillManagementError.skillUnavailable
        }
        guard skill.isActive != request.isActive else {
            return .confirmed(before)
        }

        var nextStates = Dictionary(
            uniqueKeysWithValues: before.explicitStates.map { ($0.key.rawValue, $0.value) }
        )
        nextStates[request.skillID.rawValue] = request.isActive
        let update = try LibreChatSkillsAPI.updateActiveStates(nextStates)

        do {
            let response = try await runtime.restClient.send(update)
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                return .outcomeUnknown(.responseLostAfterDispatch)
            }
            if response.states[request.skillID.rawValue] == request.isActive,
               response.states.keys.allSatisfy(LibreChatSkillsAPI.isMutableSkillID) {
                return .confirmed(Self.applyingSkillActivation(
                    response.states,
                    requested: request,
                    to: before
                ))
            }
            return try await reconcileSkillActivation(request)
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            guard Self.skillActivationMutationIsUncertain(error) else { throw error }
            return try await reconcileSkillActivation(request)
        } catch is CancellationError {
            return try await reconcileSkillActivation(request)
        } catch {
            return try await reconcileSkillActivation(request)
        }
    }

    private func reconcileSkillActivation(
        _ request: SkillActivationRequest
    ) async throws -> SkillActivationOutcome {
        do {
            let catalog = try await accountSkillCatalog()
            guard catalog.profileID == request.profileID,
                  catalog.accountID == request.accountID,
                  profile.id == request.profileID,
                  accountID == request.accountID else {
                return .outcomeUnknown(.reconciliationUnavailable)
            }
            guard let skill = catalog.skill(id: request.skillID),
                  catalog.explicitStates[request.skillID] == request.isActive,
                  skill.isActive == request.isActive else {
                return .notConfirmed(catalog)
            }
            return .confirmed(catalog)
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            return .outcomeUnknown(.reconciliationUnavailable)
        }
    }

    private static func applyingSkillActivation(
        _ states: [String: Bool],
        requested request: SkillActivationRequest,
        to catalog: AccountSkillCatalog
    ) -> AccountSkillCatalog {
        var skills = catalog.skills
        if let index = skills.firstIndex(where: { $0.id == request.skillID }) {
            skills[index].isActive = request.isActive
            skills[index].activationBasis = .explicitOverride
        }
        return AccountSkillCatalog(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            skills: skills,
            explicitStates: Dictionary(uniqueKeysWithValues: states.map {
                (SkillID(rawValue: $0.key), $0.value)
            }),
            fetchedAt: Date(),
            isComplete: catalog.isComplete
        )
    }

    private static func skillActivationMutationIsUncertain(
        _ error: LibreChatProtocolError
    ) -> Bool {
        switch error {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            true
        case let .httpStatus(status, _, _) where status >= 500:
            true
        default:
            false
        }
    }

    func createBasicAgent(
        _ request: BasicAgentCreationRequest
    ) async throws -> BasicAgentCreationOutcome {
        let operationID = try beginBasicAgentCreation()
        defer { finishBasicAgentCreation(operationID) }

        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        guard request.profileID == requestedProfileID,
              request.accountID == requestedAccountID else {
            throw BasicAgentCreationError.reviewedScopeMismatch
        }
        guard let capabilities = profile.capabilities,
              capabilities.authenticatedPolicyVerified == true,
              capabilities.supportsAgents,
              capabilities.agentPermissions?.canManageMetadata == true else {
            throw LibreChatProtocolError.unsupported(
                "This account is not authorized to create saved agents."
            )
        }

        // The displayed model is only review context. Fetch the small raw
        // provider/model catalog again for this exact account immediately
        // before building the one-shot mutation.
        let modelDTO = try await runtime.restClient.send(
            LibreChatAgentsAPI.modelsForBasicCreation()
        )
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw BasicAgentCreationError.reviewedScopeMismatch
        }
        let catalog = modelDTO.basicAgentCreationCatalog(
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
        let createRequest = try LibreChatAgentsAPI.createBasic(
            request,
            validatingAgainst: catalog
        )

        do {
            let response = try await runtime.restClient.rawResponse(
                method: createRequest.method,
                path: createRequest.path,
                pathComponents: createRequest.pathComponents,
                queryItems: createRequest.queryItems,
                headers: createRequest.headers,
                body: createRequest.body,
                authorized: createRequest.authorization == .bearer,
                retryPolicy: createRequest.retryPolicy
            )
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                return .outcomeUnknown(.responseLostAfterDispatch)
            }
            do {
                let dto = try JSONDecoder().decode(
                    LibreChatBasicAgentCreationResponseDTO.self,
                    from: response.data
                )
                return try LibreChatAgentsAPI.confirmedBasicCreation(
                    from: dto,
                    statusCode: response.statusCode,
                    for: request,
                    validatingAgainst: catalog
                )
            } catch {
                // A malformed 2xx or wrong success status may still follow a
                // committed create. Never repeat the POST.
            }
        } catch is CancellationError {
            // Cancellation may race a committed server mutation.
        } catch let error as LibreChatProtocolError {
            guard Self.basicAgentCreationIsUncertain(error) else { throw error }
        } catch let error as BasicAgentCreationError {
            throw error
        } catch {
            // A response that cannot be decoded is post-dispatch ambiguity.
        }

        return try await reconcileBasicAgentCreation(
            request,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
    }

    func agentManagementDetail(id: AgentID) async throws -> ManagedAgentMetadata {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let detail = try await runtime.restClient.send(
            LibreChatAgentsAPI.expanded(id: id)
        ).managedDomainModel()
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw AgentManagementError.unavailable
        }
        guard detail.id == id else { throw AgentManagementError.invalidResponse }
        return detail
    }

    func agentResourcePermissions(id: AgentID) async throws -> AgentResourcePermissions {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let detail = try await agent(id: id)
        guard let resourceID = detail.resourceID else {
            throw AgentManagementError.invalidResponse
        }
        let permissions = try await runtime.restClient.send(
            LibreChatAgentsAPI.effectivePermissions(resourceID: resourceID)
        ).domainModel()
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw AgentManagementError.unavailable
        }
        return permissions
    }

    func agentVersions(id: AgentID) async throws -> AgentVersionHistory {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let history = try await runtime.restClient.send(
            LibreChatAgentsAPI.versions(id: id)
        ).domainModel(agentID: id)
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              history.agentID == id else {
            throw AgentManagementError.unavailable
        }
        return history
    }

    func updateAgentMetadata(
        _ input: AgentMetadataUpdateInput
    ) async throws -> ManagedAgentMetadata {
        let expected = try LibreChatAgentsAPI.metadataBody(input)
        let operationID = try beginAgentMutation(id: input.agentID)
        defer { finishAgentMutation(id: input.agentID, operationID: operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()

        _ = try await agentManagementDetail(id: input.agentID)

        do {
            let response = try await runtime.restClient.send(
                LibreChatAgentsAPI.updateMetadata(input)
            ).managedDomainModel()
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                throw AgentManagementError.outcomeUnknown
            }
            if Self.matches(response, expected: expected, id: input.agentID) {
                return response
            }
            // A malformed or mismatched 2xx response is ambiguous because the
            // server may already have committed the PATCH. Reconcile below.
        } catch is CancellationError {
            // URLSession cancellation may occur after the mutation reached the
            // server. Reconcile below without issuing another PATCH.
        } catch let error as AgentManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            guard Self.agentMutationIsUncertain(error) else { throw error }
        } catch {
            // Decoding a 2xx response can fail after the mutation committed.
        }

        return try await reconcileAgentMetadata(
            id: input.agentID,
            expected: expected,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
    }

    func duplicateAgent(id: AgentID) async throws -> ChatAgentSummary {
        let operationID = try beginAgentMutation(id: id)
        defer { finishAgentMutation(id: id, operationID: operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()

        _ = try await agentManagementDetail(id: id)

        do {
            let response = try await runtime.restClient.send(
                LibreChatAgentsAPI.duplicate(id: id)
            )
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID,
                  let agentDTO = response.agent else {
                throw AgentManagementError.outcomeUnknown
            }
            // The duplicate handler attempts to grant owner ACL after create,
            // but still returns 201 if that grant fails. Only a subsequent
            // directory read may prove EDIT, so the immediate acknowledgement
            // must remain fail-closed.
            let copy = try agentDTO.summaryModel(canEdit: false)
            guard copy.id != id else { throw AgentManagementError.outcomeUnknown }
            return copy
        } catch is CancellationError {
            throw AgentManagementError.outcomeUnknown
        } catch let error as AgentManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            if Self.agentMutationIsUncertain(error) {
                throw AgentManagementError.outcomeUnknown
            }
            throw error
        } catch {
            throw AgentManagementError.outcomeUnknown
        }
    }

    func revertAgentVersion(
        _ version: AgentVersionSummary
    ) async throws -> ManagedAgentMetadata {
        guard version.isRestorable, version.coordinate.serverIndex >= 0 else {
            throw AgentManagementError.invalidInput(
                "This saved agent version is no longer available. Refresh the history."
            )
        }
        let id = version.coordinate.agentID
        let operationID = try beginAgentMutation(id: id)
        defer { finishAgentMutation(id: id, operationID: operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()

        // Fetch the live array immediately before dispatch. The raw server
        // index is mutation authority, so a compacted, stale, or fabricated
        // summary must never select a different hidden configuration.
        let history = try await agentVersions(id: id)
        guard let liveVersion = history.versions.first(where: {
            $0.coordinate.serverIndex == version.coordinate.serverIndex
        }), liveVersion == version else {
            throw AgentManagementError.invalidInput(
                "This saved agent version changed. Refresh the history before restoring it."
            )
        }
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw AgentManagementError.unavailable
        }

        do {
            let response = try await runtime.restClient.send(
                LibreChatAgentsAPI.revert(version.coordinate)
            ).managedDomainModel()
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID,
                  response.id == id else {
                throw AgentManagementError.outcomeUnknown
            }
            return response
        } catch is CancellationError {
            throw AgentManagementError.outcomeUnknown
        } catch let error as AgentManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            if Self.agentMutationIsUncertain(error) {
                throw AgentManagementError.outcomeUnknown
            }
            throw error
        } catch {
            // A 2xx can arrive after the server committed the full hidden
            // configuration but before its safe acknowledgement decodes.
            throw AgentManagementError.outcomeUnknown
        }
    }

    func deleteAgent(id: AgentID) async throws {
        let operationID = try beginAgentMutation(id: id)
        defer { finishAgentMutation(id: id, operationID: operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let permissions = try await agentResourcePermissions(id: id)
        guard permissions.canDelete else {
            throw AgentManagementError.insufficientPermission
        }

        do {
            let response = try await runtime.restClient.send(
                LibreChatAgentsAPI.delete(id: id)
            )
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                throw AgentManagementError.outcomeUnknown
            }
            if response.confirmsDeletion() { return }
            // A malformed 2xx may still follow a committed deletion.
        } catch is CancellationError {
            // Cancellation after dispatch is ambiguous; reconcile below.
        } catch let error as AgentManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            if case let .httpStatus(status, _, _) = error, status == 404 {
                return
            }
            guard Self.agentMutationIsUncertain(error) else { throw error }
        } catch {
            // A decoding failure after a 2xx is also ambiguous.
        }

        try await reconcileAgentDeletion(
            id: id,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
    }

    func mcpConnections() async throws -> MCPConnectionCatalog {
        _ = try activeAccountID()
        async let servers = runtime.restClient.send(LibreChatMCPAPI.servers())
        async let statuses = runtime.restClient.send(LibreChatMCPAPI.connectionStatuses())
        return try await LibreChatMCPMapper.catalog(
            servers: servers,
            statuses: statuses
        )
    }

    func memories() async throws -> MemorySnapshot {
        _ = try activeAccountID()
        let snapshot = try await runtime.restClient.send(
            LibreChatMemoriesAPI.list()
        ).domainModel()
        memoryCharacterLimit = snapshot.characterLimit
        return snapshot
    }

    func createMemory(_ input: CreateMemoryInput) async throws -> UserMemory {
        _ = try activeAccountID()
        let limit = try await resolvedMemoryCharacterLimit()
        let memory = try await runtime.restClient.send(
            LibreChatMemoriesAPI.create(input, characterLimit: limit)
        ).createdMemory()
        guard memory.key == input.key.trimmingCharacters(in: .whitespacesAndNewlines),
              memory.agentID == input.agentID else {
            throw LibreChatProtocolError.invalidResponse
        }
        return memory
    }

    func updateMemory(_ input: UpdateMemoryInput) async throws -> UserMemory {
        _ = try activeAccountID()
        let limit = try await resolvedMemoryCharacterLimit()
        let memory = try await runtime.restClient.send(
            LibreChatMemoriesAPI.update(input, characterLimit: limit)
        ).updatedMemory()
        guard memory.key == input.key.trimmingCharacters(in: .whitespacesAndNewlines),
              memory.agentID == input.agentID else {
            throw LibreChatProtocolError.invalidResponse
        }
        return memory
    }

    func deleteMemory(_ input: DeleteMemoryInput) async throws {
        _ = try activeAccountID()
        let response = try await runtime.restClient.send(
            LibreChatMemoriesAPI.delete(input)
        )
        guard response.deleted == true else { throw LibreChatProtocolError.invalidResponse }
    }

    func setMemoriesEnabled(_ enabled: Bool) async throws -> Bool {
        _ = try activeAccountID()
        return try await runtime.restClient.send(
            LibreChatMemoriesAPI.setEnabled(enabled)
        ).enabledValue()
    }

    func promptGroups(_ query: PromptTemplateQuery) async throws -> PromptTemplatePage {
        _ = try activeAccountID()
        return try await runtime.restClient.send(
            LibreChatPromptsAPI.groups(query)
        ).domainModel()
    }

    /// The server's shared category directory (same endpoint the web
    /// client's prompt CategorySelector reads), backing the category
    /// dropdown in prompt and agent editors.
    func promptCategories() async throws -> [String] {
        _ = try activeAccountID()
        return try await runtime.restClient.send(
            LibreChatPromptsAPI.categories()
        )
        .map(\.value)
        .filter { !$0.isEmpty }
    }

    func recordPromptUsage(groupID: PromptGroupID) async throws -> Int {
        _ = try activeAccountID()
        return try await runtime.restClient.send(
            LibreChatPromptsAPI.recordUsage(groupID: groupID)
        ).count()
    }

    func promptManagementDetail(groupID: PromptGroupID) async throws -> PromptManagementDetail {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let groupDTO = try await runtime.restClient.send(
            LibreChatPromptsAPI.group(groupID: groupID)
        )
        let versionDTOs = try await runtime.restClient.send(
            LibreChatPromptsAPI.versions(groupID: groupID)
        )
        guard profile.id == requestedProfileID, accountID == requestedAccountID else {
            throw PromptManagementError.unavailable
        }
        let group = try groupDTO.managedDomainModel()
        guard group.id == groupID else { throw PromptManagementError.invalidResponse }
        var seen = Set<PromptVersionID>()
        let versions = try versionDTOs.map { dto -> ManagedPromptVersion in
            let version = try dto.domainModel(expectedGroupID: groupID)
            guard seen.insert(version.id).inserted else {
                throw PromptManagementError.invalidResponse
            }
            return version
        }
        guard versions.contains(where: { $0.id == group.productionVersionID }) else {
            throw PromptManagementError.invalidResponse
        }
        return PromptManagementDetail(group: group, versions: versions)
    }

    func createPromptGroup(_ input: CreatePromptGroupInput) async throws -> PromptManagementDetail {
        let operationID = try beginPromptMutation()
        defer { finishPromptMutation(operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        do {
            let response = try await runtime.restClient.send(LibreChatPromptsAPI.create(input))
            guard profile.id == requestedProfileID, accountID == requestedAccountID else {
                throw PromptManagementError.outcomeUnknown
            }
            guard let groupDTO = response.group,
                  let versionDTO = response.prompt else {
                throw PromptManagementError.outcomeUnknown
            }
            let group = try groupDTO.managedDomainModel()
            let version = try versionDTO.domainModel(expectedGroupID: group.id)
            guard group.productionVersionID == version.id else {
                throw PromptManagementError.outcomeUnknown
            }
            return PromptManagementDetail(group: group, versions: [version])
        } catch is CancellationError {
            throw PromptManagementError.outcomeUnknown
        } catch let error as PromptManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            if Self.promptMutationIsUncertain(error) {
                throw PromptManagementError.outcomeUnknown
            }
            throw error
        } catch {
            throw PromptManagementError.outcomeUnknown
        }
    }

    func addPromptVersion(_ input: AddPromptVersionInput) async throws -> ManagedPromptVersion {
        let operationID = try beginPromptMutation()
        defer { finishPromptMutation(operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        do {
            let response = try await runtime.restClient.send(LibreChatPromptsAPI.addVersion(input))
            guard profile.id == requestedProfileID, accountID == requestedAccountID else {
                throw PromptManagementError.outcomeUnknown
            }
            guard let prompt = response.prompt else {
                throw PromptManagementError.outcomeUnknown
            }
            return try prompt.domainModel(expectedGroupID: input.groupID)
        } catch is CancellationError {
            throw PromptManagementError.outcomeUnknown
        } catch let error as PromptManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            if Self.promptMutationIsUncertain(error) {
                throw PromptManagementError.outcomeUnknown
            }
            throw error
        } catch {
            throw PromptManagementError.outcomeUnknown
        }
    }

    func updatePromptGroup(_ input: UpdatePromptGroupInput) async throws -> ManagedPromptGroup {
        let operationID = try beginPromptMutation()
        defer { finishPromptMutation(operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        do {
            _ = try await runtime.restClient.send(LibreChatPromptsAPI.updateGroup(input))
        } catch is CancellationError {
            // The request may already have been applied. Reconcile below.
        } catch let error as PromptManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            guard Self.promptMutationIsUncertain(error) else { throw error }
        }
        do {
            let dto = try await runtime.restClient.send(
                LibreChatPromptsAPI.group(groupID: input.groupID)
            )
            guard profile.id == requestedProfileID, accountID == requestedAccountID else {
                throw PromptManagementError.outcomeUnknown
            }
            let group = try dto.managedDomainModel()
            guard Self.matches(group, input: input) else {
                throw PromptManagementError.outcomeUnknown
            }
            return group
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as PromptManagementError {
            throw error
        } catch {
            throw PromptManagementError.outcomeUnknown
        }
    }

    func promotePromptVersion(
        groupID: PromptGroupID,
        versionID: PromptVersionID
    ) async throws -> ManagedPromptGroup {
        let operationID = try beginPromptMutation()
        defer { finishPromptMutation(operationID) }
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let preflight = try await promptManagementDetail(groupID: groupID)
        guard preflight.versions.contains(where: { $0.id == versionID }) else {
            throw PromptManagementError.invalidInput(
                "The selected version does not belong to this template."
            )
        }
        do {
            _ = try await runtime.restClient.send(
                LibreChatPromptsAPI.promote(versionID: versionID)
            )
        } catch is CancellationError {
            // Reconcile exact production identity below.
        } catch let error as PromptManagementError {
            throw error
        } catch let error as LibreChatProtocolError {
            guard Self.promptMutationIsUncertain(error) else { throw error }
        }
        do {
            let dto = try await runtime.restClient.send(
                LibreChatPromptsAPI.group(groupID: groupID)
            )
            guard profile.id == requestedProfileID, accountID == requestedAccountID else {
                throw PromptManagementError.outcomeUnknown
            }
            let group = try dto.managedDomainModel()
            guard group.id == groupID, group.productionVersionID == versionID else {
                throw PromptManagementError.outcomeUnknown
            }
            return group
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as PromptManagementError {
            throw error
        } catch {
            throw PromptManagementError.outcomeUnknown
        }
    }

    func presets() async throws -> PresetLibrarySnapshot {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let dtos = try await runtime.restClient.send(LibreChatPresetsAPI.list())
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while presets were being loaded."
            )
        }
        return PresetLibraryMapper().snapshot(
            profileID: requestedProfileID,
            accountID: requestedAccountID,
            dtos: dtos
        )
    }

    func createPreset(
        _ request: PresetCreationRequest
    ) async throws -> PresetCreationOutcome {
        let operationID = try beginPresetMutation()
        defer { finishPresetMutation(operationID) }

        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        guard request.profileID == requestedProfileID,
              request.accountID == requestedAccountID else {
            throw PresetCreationError.reviewedScopeMismatch
        }

        // This network-backed catalog is the authorization/routing evidence
        // for the mutation. The UI's reviewed option is never sufficient on
        // its own, even when it came from this same repository moments ago.
        let catalog = try await targetCatalog(recentOptionID: nil)
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw PresetCreationError.reviewedScopeMismatch
        }
        let createRequest = try LibreChatPresetsAPI.create(
            request,
            validatingAgainst: catalog
        )

        do {
            let dto = try await runtime.restClient.send(createRequest)
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                return .outcomeUnknown(.responseLostAfterDispatch)
            }
            do {
                return try LibreChatPresetsAPI.confirmedCreation(
                    from: dto,
                    for: request,
                    validatingAgainst: catalog
                )
            } catch {
                // A malformed 201 can follow a committed server upsert. The
                // owner directory is the only safe reconciliation surface.
            }
        } catch is CancellationError {
            // Cancellation may occur after the server committed the upsert.
        } catch let error as LibreChatProtocolError {
            guard Self.presetMutationIsUncertain(error) else { throw error }
        } catch let error as PresetCreationError {
            throw error
        } catch {
            // Decoding an already-received 2xx is also post-dispatch ambiguity.
        }

        return try await reconcilePresetCreation(
            request,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
    }

    func fileLibrary() async throws -> FileLibrarySnapshot {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let records = try await runtime.restClient.send(LibreChatFilesAPI.catalog())
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while files were being loaded."
            )
        }
        return LibreChatFileCatalogMapper.snapshot(from: records)
    }

    func filePreview(fileID: String) async throws -> FilePreviewSnapshot {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let response = try await runtime.restClient.send(
            LibreChatFilesAPI.preview(fileID: fileID)
        )
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while the file preview was being loaded."
            )
        }
        return try response.domainModel(expectedFileID: fileID)
    }

    func downloadFile(_ item: FileLibraryItem) async throws -> DownloadedLibraryFile {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let requestedTransferEpoch = fileTransferEpoch
        let downloaded = try await fileTransfer.downloadLibraryFile(
            item,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              fileTransferEpoch == requestedTransferEpoch else {
            try? FileManager.default.removeItem(at: downloaded.localURL)
            throw LibreChatProtocolError.unsupported(
                "The file download no longer belongs to the active app session."
            )
        }
        return downloaded
    }

    func deleteFile(_ item: FileLibraryItem) async throws -> FileLibraryDeletionResult {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let request = try LibreChatFilesAPI.delete(item)
        guard fileDeletionIDs.insert(item.id).inserted else {
            throw FileLibraryError.deletionInProgress
        }
        defer { fileDeletionIDs.remove(item.id) }

        var attempt: FileLibraryDeletionResult.Attempt = .accepted
        do {
            _ = try await runtime.restClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if error.isUnauthorized { throw error }
            if case LibreChatProtocolError.httpStatus(403, _, _) = error { throw error }
            if case LibreChatProtocolError.httpStatus(let status, _, _) = error,
               (400..<500).contains(status) {
                attempt = .rejected
            } else {
                attempt = .deliveryUncertain
            }
        }

        let records: [LibreChatFileDTO]
        do {
            records = try await runtime.restClient.send(LibreChatFilesAPI.catalog())
        } catch {
            if error.isUnauthorized { throw error }
            throw FileLibraryError.deletionVerificationRequired
        }

        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while the file deletion was being verified."
            )
        }

        let snapshot = LibreChatFileCatalogMapper.snapshot(from: records)
        let disposition: FileLibraryDeletionResult.Disposition = records.contains {
            $0.fileID == item.id
        } ? .retained : .deleted
        return FileLibraryDeletionResult(
            disposition: disposition,
            attempt: attempt,
            snapshot: snapshot
        )
    }

    /// Fetches raw bytes for a server-hosted entity image (agent avatars,
    /// spec and endpoint icons) through the profile's authenticated transport.
    /// Servers with secure image links reject plain image requests without the
    /// session's refresh cookie, so same-origin assets ride the cookie jar;
    /// other-origin assets (public CDNs) use a plain fetch.
    func imageData(at url: URL) async throws -> Data {
        let baseComponents = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func defaultPort(for scheme: String?) -> Int {
            scheme?.lowercased() == "http" ? 80 : 443
        }
        if let components,
           let baseComponents,
           components.scheme?.lowercased() == baseComponents.scheme?.lowercased(),
           components.host?.lowercased() == baseComponents.host?.lowercased(),
           (components.port ?? defaultPort(for: components.scheme))
               == (baseComponents.port ?? defaultPort(for: baseComponents.scheme)) {
            var basePath = baseComponents.path
            if basePath.hasSuffix("/") { basePath.removeLast() }
            var fullPath = components.path
            if !basePath.isEmpty, fullPath.hasPrefix(basePath) {
                fullPath = String(fullPath.dropFirst(basePath.count))
            }
            let path = fullPath.hasPrefix("/") ? String(fullPath.dropFirst()) : fullPath
            let response = try await runtime.restClient.downloadResponse(
                method: .get,
                path: path,
                // The transport escapes query items itself; handing over the
                // percent-encoded form would double-escape signature
                // parameters and break authenticated image fetches.
                queryItems: components.queryItems ?? [],
                authorized: false
            )
            defer { try? FileManager.default.removeItem(at: response.localURL) }
            return try Data(contentsOf: response.localURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    func projects(options: ChatProjectListOptions = .init()) async throws -> ChatProjectPage {
        try await runtime.restClient.send(LibreChatProjectsAPI.list(options)).domainModel()
    }

    func project(id: ProjectID) async throws -> ChatProject {
        try await runtime.restClient.send(LibreChatProjectsAPI.project(id: id)).domainModel()
    }

    func createProject(_ input: CreateChatProjectInput) async throws -> ChatProject {
        let request = try LibreChatProjectsAPI.create(input)
        return try await runtime.restClient.send(request).domainModel()
    }

    func updateProject(
        id: ProjectID,
        input: UpdateChatProjectInput
    ) async throws -> ChatProject {
        let request = try LibreChatProjectsAPI.update(id: id, input: input)
        return try await runtime.restClient.send(request).domainModel()
    }

    func deleteProject(id: ProjectID) async throws -> DeleteChatProjectResult {
        let accountID = try activeAccountID()
        let result = try await runtime.restClient.send(LibreChatProjectsAPI.delete(id: id)).domainModel()
        do {
            try await cache.clearProjectMembership(
                projectID: id,
                profileID: profile.id,
                accountID: accountID
            )
        } catch {
            AppLog.persistence.error("Could not reconcile cached project membership after deletion.")
        }
        return result
    }

    func speechCapabilities() async throws -> SpeechCapabilities {
        guard accountID != nil else { throw LibreChatProtocolError.unauthorized }
        return try await runtime.restClient.send(
            LibreChatSpeechAPI.configuration()
        ).domainModel()
    }

    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscription {
        guard request.profileID == profile.id,
              request.accountID == accountID else {
            throw LibreChatProtocolError.unauthorized
        }
        let apiRequest = try LibreChatSpeechAPI.transcribe(request)
        return try await runtime.restClient.send(apiRequest).domainModel()
    }

    func speechSynthesisVoices() async throws -> [SpeechSynthesisVoice] {
        guard accountID != nil else { throw LibreChatProtocolError.unauthorized }
        let values = try await runtime.restClient.send(LibreChatSpeechAPI.voices())
        return LibreChatSpeechAPI.synthesisVoices(from: values)
    }

    func speechSynthesisVoicePreference() async throws -> SpeechSynthesisVoicePreference? {
        guard let accountID else { throw LibreChatProtocolError.unauthorized }
        return try await cache.speechSynthesisVoicePreference(
            profileID: profile.id,
            accountID: accountID
        )
    }

    func setSpeechSynthesisVoicePreference(
        _ preference: SpeechSynthesisVoicePreference
    ) async throws {
        guard let accountID else { throw LibreChatProtocolError.unauthorized }
        try await cache.saveSpeechSynthesisVoicePreference(
            preference,
            profileID: profile.id,
            accountID: accountID
        )
    }

    func synthesizeSpeech(
        _ request: SpeechSynthesisRequest
    ) async throws -> SynthesizedSpeechAudio {
        guard request.profileID == profile.id,
              request.accountID == accountID else {
            throw LibreChatProtocolError.unauthorized
        }
        let apiRequest = try LibreChatSpeechAPI.synthesize(request)
        let response = try await runtime.restClient.rawResponse(
            method: apiRequest.method,
            path: apiRequest.path,
            pathComponents: apiRequest.pathComponents,
            queryItems: apiRequest.queryItems,
            headers: apiRequest.headers,
            body: apiRequest.body,
            authorized: true,
            retryPolicy: apiRequest.retryPolicy
        )
        return try LibreChatSpeechAPI.synthesisAudio(from: response)
    }

    func sharedLink(for conversationID: ConversationID) async throws -> SharedLinkState {
        try await runtime.restClient.send(
            LibreChatSharedLinksAPI.lookup(conversationID: conversationID)
        ).domainModel(requestedConversationID: conversationID)
    }

    func createSharedLink(
        for conversationID: ConversationID,
        request: SharedLinkPublishRequest
    ) async throws -> SharedLinkMutationResult {
        let apiRequest = try LibreChatSharedLinksAPI.create(
            conversationID: conversationID,
            request: request
        )
        return try await runtime.restClient.send(apiRequest).domainModel()
    }

    func updateSharedLink(
        _ shareID: SharedLinkID,
        request: SharedLinkPublishRequest
    ) async throws -> SharedLinkMutationResult {
        let apiRequest = try LibreChatSharedLinksAPI.update(
            shareID: shareID,
            request: request
        )
        return try await runtime.restClient.send(apiRequest).domainModel()
    }

    func deleteSharedLink(_ shareID: SharedLinkID) async throws -> SharedLinkDeletionResult {
        try await runtime.restClient.send(
            try LibreChatSharedLinksAPI.delete(shareID: shareID)
        ).domainModel()
    }

    func sharedSnapshot(for shareID: SharedLinkID) async throws -> SharedConversationSnapshot {
        try await runtime.restClient.send(
            LibreChatSharedSnapshotsAPI.snapshot(shareID: shareID)
        ).domainModel(expectedShareID: shareID)
    }

    func forkSharedConversation(
        _ request: SharedConversationForkRequest
    ) async throws -> SharedConversationForkResult {
        let accountID = try activeAccountID()
        let apiRequest = try LibreChatSharedSnapshotsAPI.fork(request)
        let result = try await runtime.restClient.send(apiRequest).domainModel()
        do {
            try await cache.save(
                page: ConversationPage(conversations: [result.conversation]),
                profileID: profile.id,
                accountID: accountID,
                completeSynchronization: false
            )
            try await cache.save(
                messages: result.messages,
                profileID: profile.id,
                accountID: accountID,
                conversationID: result.conversation.id
            )
        } catch {
            // The server's validated response already proves creation. A local
            // cache failure must not turn that success into an ambiguous UI
            // that could tempt the user to create a duplicate fork.
            AppLog.persistence.error("Conversation fork cache persistence failed after authoritative creation.")
        }
        return result
    }

    func assignConversation(
        id: ConversationID,
        to projectID: ProjectID?
    ) async throws -> ConversationProjectAssignment {
        let accountID = try activeAccountID()
        let request = try LibreChatProjectsAPI.assign(conversationID: id, projectID: projectID)
        let assignment = try await runtime.restClient.send(request).domainModel()
        try await cache.save(
            page: ConversationPage(conversations: [assignment.conversation]),
            profileID: profile.id,
            accountID: accountID,
            completeSynchronization: false
        )
        return assignment
    }

    func projectConversations(
        projectID: ProjectID,
        cursor: String? = nil,
        limit: Int = 25
    ) async throws -> ConversationPage {
        var queryItems = [
            URLQueryItem(name: "projectId", value: projectID.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "isArchived", value: "false"),
            URLQueryItem(name: "sortBy", value: "updatedAt"),
            URLQueryItem(name: "sortDirection", value: "desc")
        ]
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        let request = APIRequest<LibreChatConversationPageDTO>(
            path: "api/convos",
            queryItems: queryItems,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        return try await runtime.restClient.send(request).domainModel()
    }

    func conversation(id: ConversationID) async throws -> LibreChatDomain.Conversation {
        let request = APIRequest<LibreChatConversationDTO>(
            path: "api/convos/\(id.rawValue)",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        var conversation = try await runtime.restClient.send(request).domainModel()
        if var target = conversation.target,
           let spec = target.spec,
           let startupConfiguration,
           let ephemeralAgent = TargetCatalogMapper().ephemeralAgentConfiguration(
               specName: spec,
               startup: startupConfiguration
           ) {
            target.ephemeralAgent = ephemeralAgent
            conversation.target = target
        }
        if conversation.isTemporaryConversation {
            await registerTemporaryConversation(conversation.id)
        }
        return conversation
    }

    func cachedMessages(conversationID: ConversationID) async throws -> [ChatMessage] {
        guard !temporaryConversationIDs.contains(conversationID) else { return [] }
        let accountID = try activeAccountID()
        return try await cache.messages(profileID: profile.id, accountID: accountID, conversationID: conversationID)
    }

    func messages(conversationID: ConversationID) async throws -> [ChatMessage] {
        let accountID = try activeAccountID()
        let request = APIRequest<[LibreChatMessageDTO]>(
            path: "api/messages",
            pathComponents: ["api", "messages", conversationID.rawValue],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        let dtos = try await runtime.restClient.send(request)
        let messages = try dtos.map { dto in
                let message = try dto.domainModel(defaultConversationID: conversationID)
                guard message.conversationID == conversationID else {
                    throw DTOMapperError.invalidField("message.conversationId")
                }
                return message
            }
        if dtos.contains(where: {
            $0.isTemporary == true || ($0.isTemporary == nil && $0.expiredAt != nil)
        }) {
            await registerTemporaryConversation(conversationID)
        }
        if !temporaryConversationIDs.contains(conversationID) {
            try await cache.save(
                messages: messages,
                profileID: profile.id,
                accountID: accountID,
                conversationID: conversationID
            )
        }
        return messages
    }

    /// Creates an owned conversation fork only after reading and validating
    /// the complete authoritative source graph. The server mutation has no
    /// idempotency key, so its request is never retried; ambiguous transport
    /// or malformed success responses are surfaced as a typed lockout.
    func fork(_ request: ConversationForkRequest) async throws -> ConversationForkResult {
        guard request.profileID == profile.id else {
            throw ConversationForkError.profileMismatch
        }
        let accountID = try activeAccountID()
        guard request.accountID == accountID else {
            throw ConversationForkError.accountMismatch
        }

        let sourceConversation: Conversation
        do {
            sourceConversation = try await conversation(id: request.conversationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            if error.isUnauthorized { throw error }
            throw ConversationForkError.preflightReadFailed
        }
        guard sourceConversation.id == request.conversationID else {
            throw ConversationForkError.preflightValidation(
                .crossConversationMessage(request.targetMessageID)
            )
        }

        let sourceHistory: [ChatMessage]
        do {
            sourceHistory = try await messages(conversationID: request.conversationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            if error.isUnauthorized { throw error }
            throw ConversationForkError.preflightReadFailed
        }

        let preflight: ConversationForkPreflight
        do {
            preflight = try ConversationForkValidator.preflight(
                request: request,
                conversation: sourceConversation,
                history: sourceHistory
            )
        } catch let error as ConversationForkValidationError {
            throw ConversationForkError.preflightValidation(error)
        }

        let apiRequest: APIRequest<ConversationForkResponseDTO>
        do {
            apiRequest = try LibreChatConversationForkAPI.fork(request)
        } catch {
            // Encoding occurs before dispatch, so it is a preflight failure,
            // not an outcome-unknown mutation.
            throw ConversationForkError.preflightReadFailed
        }

        let response: ConversationForkResponseDTO
        do {
            response = try await runtime.restClient.send(apiRequest)
        } catch is CancellationError {
            throw ConversationForkError.ambiguous
        } catch let error as LibreChatProtocolError {
            if error == .unauthorized { throw error }
            if case let .httpStatus(status, _, _) = error,
               (400...499).contains(status) {
                throw error
            }
            throw ConversationForkError.ambiguous
        } catch {
            throw ConversationForkError.ambiguous
        }

        let result: ConversationForkResult
        do {
            result = try response.domainModel(for: preflight)
        } catch {
            // A 2xx with an invalid ACK is still outcome-unknown: the server
            // may have committed the fork before returning malformed data.
            throw ConversationForkError.ambiguous
        }

        try await cache.save(
            page: ConversationPage(conversations: [result.conversation]),
            profileID: profile.id,
            accountID: accountID,
            completeSynchronization: false
        )
        try await cache.save(
            messages: result.messages,
            profileID: profile.id,
            accountID: accountID,
            conversationID: result.conversation.id
        )
        return result
    }

    /// Creates one whole-conversation copy from an authoritative, nonempty
    /// source graph. LibreChat exposes no idempotency or lookup coordinate for
    /// this mutation, so any post-dispatch ambiguity is locked and never
    /// reconciled by issuing a second POST.
    func duplicate(
        _ request: ConversationDuplicationRequest
    ) async throws -> ConversationDuplicationResult {
        guard request.profileID == profile.id else {
            throw ConversationDuplicationError.profileMismatch
        }
        let accountID = try activeAccountID()
        guard request.accountID == accountID else {
            throw ConversationDuplicationError.accountMismatch
        }

        let sourceConversation: Conversation
        do {
            sourceConversation = try await conversation(id: request.conversationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            if error.isUnauthorized { throw error }
            throw ConversationDuplicationError.preflightReadFailed
        }

        let sourceHistory: [ChatMessage]
        do {
            sourceHistory = try await messages(conversationID: request.conversationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            if error.isUnauthorized { throw error }
            throw ConversationDuplicationError.preflightReadFailed
        }

        let preflight: ConversationDuplicationPreflight
        do {
            preflight = try ConversationDuplicationValidator.preflight(
                request: request,
                conversation: sourceConversation,
                history: sourceHistory
            )
        } catch let error as ConversationDuplicationValidationError {
            throw ConversationDuplicationError.preflightValidation(error)
        }

        let apiRequest: APIRequest<ConversationDuplicationResponseDTO>
        do {
            apiRequest = try LibreChatConversationDuplicationAPI.duplicate(request)
        } catch {
            throw ConversationDuplicationError.preflightReadFailed
        }

        let response: ConversationDuplicationResponseDTO
        do {
            response = try await runtime.restClient.send(apiRequest)
        } catch is CancellationError {
            throw ConversationDuplicationError.ambiguous
        } catch let error as LibreChatProtocolError {
            if error == .unauthorized { throw error }
            if case let .httpStatus(status, _, _) = error,
               (400...499).contains(status) {
                throw error
            }
            throw ConversationDuplicationError.ambiguous
        } catch {
            throw ConversationDuplicationError.ambiguous
        }

        let result: ConversationDuplicationResult
        do {
            result = try response.domainModel(for: preflight)
        } catch {
            throw ConversationDuplicationError.ambiguous
        }

        do {
            try await cache.save(
                page: ConversationPage(conversations: [result.conversation]),
                profileID: profile.id,
                accountID: accountID,
                completeSynchronization: false
            )
            try await cache.save(
                messages: result.messages,
                profileID: profile.id,
                accountID: accountID,
                conversationID: result.conversation.id
            )
        } catch {
            // A validated response proves server creation. Local cache failure
            // must not turn it into a retryable or ambiguous UI outcome.
            AppLog.persistence.error("Conversation copy cache persistence failed after authoritative creation.")
        }
        return result
    }

    func saveMessageEdit(_ edit: MessageEditRequest) async throws -> MessageEditResult {
        try validateMessageEdit(edit)
        let request = try LibreChatMessagesAPI.update(
            coordinate: edit.coordinate,
            text: edit.text
        )

        do {
            _ = try await runtime.restClient.send(request)
            return try await reconcileMessageEdit(
                edit,
                resolution: .confirmedAfterResponse
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            if error.isUnauthorized { throw error }
            guard Self.messageEditRequiresReconciliation(error) else { throw error }
            return try await reconcileMessageEdit(
                edit,
                resolution: .reconciledAfterAmbiguousFailure
            )
        }
    }

    func updateMessageFeedback(
        _ request: MessageFeedbackRequest
    ) async throws -> MessageFeedbackResult {
        try validateMessageFeedback(request)
        let apiRequest = try LibreChatMessagesAPI.updateFeedback(request)

        do {
            let response = try await runtime.restClient.send(apiRequest)
            let result = try response.domainModel(expected: request.coordinate)
            guard result.feedback == request.feedback else {
                throw MessageFeedbackError.ambiguous(
                    RecoverableMessageFeedbackAmbiguity(
                        coordinate: request.coordinate,
                        submittedFeedback: request.feedback,
                        authoritativeFeedback: result.feedback,
                        reason: .authoritativeMismatch
                    )
                )
            }
            await cacheConfirmedFeedback(result)
            return result
        } catch is CancellationError {
            // Cancellation can race a committed PUT. Never make the sheet's
            // next tap a blind repost of an outcome-unknown mutation.
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: nil,
                    reason: .verificationUnavailable
                )
            )
        } catch let error {
            if error.isUnauthorized { throw error }
            if error is MessageFeedbackError { throw error }
            guard Self.messageFeedbackRequiresReconciliation(error) else { throw error }
            return try await reconcileMessageFeedback(request)
        }
    }

    private func validateMessageFeedback(_ request: MessageFeedbackRequest) throws {
        guard request.profileID == profile.id else {
            throw MessageFeedbackError.profileMismatch
        }
        guard request.accountID == (try activeAccountID()) else {
            throw MessageFeedbackError.accountMismatch
        }
        let conversationID = request.coordinate.conversationID.rawValue
        let messageID = request.coordinate.messageID.rawValue
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageFeedbackError.blankIdentifier
        }
        guard !request.coordinate.conversationID.isLocalDraft,
              messageID != "new",
              !messageID.hasPrefix("local-") else {
            throw MessageFeedbackError.localIdentifier
        }
        if let text = request.feedback?.text,
           text.utf16.count > MessageFeedbackRequest.maximumTextUTF16Length {
            throw MessageFeedbackError.textTooLong(
                maximumUTF16Length: MessageFeedbackRequest.maximumTextUTF16Length
            )
        }
    }

    private func reconcileMessageFeedback(
        _ request: MessageFeedbackRequest
    ) async throws -> MessageFeedbackResult {
        let dtoHistory: [LibreChatMessageDTO]
        do {
            dtoHistory = try await runtime.restClient.send(APIRequest(
                path: "api/messages",
                pathComponents: ["api", "messages", request.coordinate.conversationID.rawValue],
                retryPolicy: .idempotent(maximumAttempts: 2)
            ))
        } catch is CancellationError {
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: nil,
                    reason: .verificationUnavailable
                )
            )
        } catch let error {
            if error.isUnauthorized { throw error }
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: nil,
                    reason: .verificationUnavailable
                )
            )
        }

        let matches = dtoHistory.filter {
            $0.messageID == request.coordinate.messageID.rawValue
        }
        guard matches.count == 1, let matchingDTO = matches.first else {
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: nil,
                    reason: .messageMissing
                )
            )
        }

        let authoritativeFeedback: MessageFeedback?
        do {
            authoritativeFeedback = try matchingDTO.feedback?.domainModel()
        } catch {
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: nil,
                    reason: .authoritativeMismatch
                )
            )
        }

        let history: [ChatMessage]
        do {
            history = try dtoHistory.map { dto in
                let message = try dto.domainModel(
                    defaultConversationID: request.coordinate.conversationID
                )
                guard message.conversationID == request.coordinate.conversationID else {
                    throw DTOMapperError.invalidField("message.conversationId")
                }
                return message
            }
            guard MessageTree(messages: history).isStructurallyValid else {
                throw DTOMapperError.invalidField("messages.parentMessageId")
            }
        } catch {
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: authoritativeFeedback,
                    reason: .verificationUnavailable
                )
            )
        }

        let accountID = try activeAccountID()
        try? await cache.save(
            messages: history,
            profileID: profile.id,
            accountID: accountID,
            conversationID: request.coordinate.conversationID
        )
        guard authoritativeFeedback == request.feedback else {
            throw MessageFeedbackError.ambiguous(
                RecoverableMessageFeedbackAmbiguity(
                    coordinate: request.coordinate,
                    submittedFeedback: request.feedback,
                    authoritativeFeedback: authoritativeFeedback,
                    reason: .authoritativeMismatch
                )
            )
        }
        return MessageFeedbackResult(
            coordinate: request.coordinate,
            feedback: authoritativeFeedback,
            resolution: .reconciledAfterAmbiguousFailure,
            authoritativeHistory: history
        )
    }

    private func cacheConfirmedFeedback(_ result: MessageFeedbackResult) async {
        guard let accountID,
              var history = try? await cache.messages(
                  profileID: profile.id,
                  accountID: accountID,
                  conversationID: result.coordinate.conversationID
              ),
              let index = history.firstIndex(where: {
                  $0.id == result.coordinate.messageID
                      && $0.conversationID == result.coordinate.conversationID
              }) else { return }
        history[index].feedback = result.feedback
        try? await cache.save(
            messages: history,
            profileID: profile.id,
            accountID: accountID,
            conversationID: result.coordinate.conversationID
        )
    }

    private static func messageFeedbackRequiresReconciliation(_ error: Error) -> Bool {
        if error is DTOMapperError { return true }
        guard let error = error as? LibreChatProtocolError else { return false }
        return switch error {
        case .transport, .invalidResponse, .decoding, .serverNotReady:
            true
        case let .httpStatus(status, _, _):
            status >= 500
        default:
            false
        }
    }

    private func validateMessageEdit(_ edit: MessageEditRequest) throws {
        guard edit.profileID == profile.id else { throw MessageEditError.profileMismatch }
        guard edit.accountID == (try activeAccountID()) else { throw MessageEditError.accountMismatch }

        let conversationID = edit.coordinate.conversationID.rawValue
        let messageID = edit.coordinate.messageID.rawValue
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageEditError.blankIdentifier
        }
        guard !edit.coordinate.conversationID.isLocalDraft,
              messageID != "new",
              !messageID.hasPrefix("local-") else {
            throw MessageEditError.localIdentifier
        }
        guard !edit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageEditError.blankText
        }
        guard edit.text.utf16.count <= MessageEditRequest.maximumTextUTF16Length else {
            throw MessageEditError.textTooLong(
                maximumUTF16Length: MessageEditRequest.maximumTextUTF16Length
            )
        }
        if case let .contentPart(index, _) = edit.coordinate.location, index < 0 {
            throw MessageEditError.negativeContentPartIndex
        }
    }

    private func reconcileMessageEdit(
        _ edit: MessageEditRequest,
        resolution: MessageEditResolution
    ) async throws -> MessageEditResult {
        let history: [ChatMessage]
        do {
            history = try await messages(conversationID: edit.coordinate.conversationID)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error {
            if error.isUnauthorized { throw error }
            throw MessageEditError.ambiguous(RecoverableMessageEditAmbiguity(
                coordinate: edit.coordinate,
                submittedText: edit.text,
                authoritativeText: nil,
                reason: .verificationUnavailable
            ))
        }

        let authoritativeText = history
            .first(where: {
                $0.id == edit.coordinate.messageID
                    && $0.conversationID == edit.coordinate.conversationID
            })?
            .editableTextCatalog
            .first(where: { $0.location == edit.coordinate.location })?
            .text
        guard authoritativeText == edit.text else {
            throw MessageEditError.ambiguous(RecoverableMessageEditAmbiguity(
                coordinate: edit.coordinate,
                submittedText: edit.text,
                authoritativeText: authoritativeText,
                reason: .authoritativeMismatch
            ))
        }
        return MessageEditResult(
            coordinate: edit.coordinate,
            resolution: resolution,
            authoritativeHistory: history
        )
    }

    private static func messageEditRequiresReconciliation(_ error: Error) -> Bool {
        guard let error = error as? LibreChatProtocolError else { return false }
        return switch error {
        case .transport, .invalidResponse, .decoding, .serverNotReady:
            true
        case let .httpStatus(status, _, _):
            status >= 500
        default:
            false
        }
    }

    func updateArtifact(_ edit: ArtifactEditRequest) async throws -> ChatMessage {
        guard !edit.conversationID.isLocalDraft,
              !edit.identity.messageID.rawValue.hasPrefix("local-") else {
            throw ArtifactEditError.unavailable
        }
        let request = try LibreChatArtifactAPI.update(
            messageID: edit.identity.messageID,
            index: edit.identity.documentOrderIndex,
            original: edit.originalContent,
            updated: edit.updatedContent,
            isTemporary: edit.isTemporary
        )

        do {
            let response = try await runtime.restClient.send(request)
            let conversationID = response.conversationID
                .flatMap { $0.isEmpty ? nil : ConversationID(rawValue: $0) }
                ?? edit.conversationID
            return try await authoritativeArtifactMessage(
                conversationID: conversationID,
                identity: edit.identity
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let mutationError {
            if mutationError.isUnauthorized { throw mutationError }
            guard Self.artifactMutationRequiresReconciliation(mutationError) else {
                throw mutationError
            }

            do {
                let message = try await authoritativeArtifactMessage(
                    conversationID: edit.conversationID,
                    identity: edit.identity
                )
                guard let artifact = Self.artifact(in: message, identity: edit.identity) else {
                    throw ArtifactEditError.changedOnServer
                }
                if Self.artifactContentsMatch(
                    artifact.sourceContent,
                    edit.updatedContent
                ) {
                    return message
                }
                if !Self.artifactContentsMatch(
                    artifact.sourceContent,
                    edit.originalContent
                ) {
                    throw ArtifactEditError.changedOnServer
                }
                // The authoritative source still matches the submitted
                // original, so the mutation did not apply. Surface the
                // original failure and let the user explicitly retry.
                throw mutationError
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ArtifactEditError {
                throw error
            } catch let reconciliationError {
                if reconciliationError.isUnauthorized { throw reconciliationError }
                throw ArtifactEditError.verificationRequired
            }
        }
    }

    func refreshGeneratedFile(_ file: GeneratedFile) async throws -> GeneratedFile {
        guard let fileID = file.fileID, !fileID.isEmpty else {
            if file.lifecycle == .failed {
                throw GeneratedFileError.failed(file.previewError)
            }
            throw GeneratedFileError.missingServerIdentifier
        }
        let preview = try await runtime.restClient.send(
            LibreChatGeneratedFileAPI.preview(fileID: fileID)
        )
        return try preview.applying(to: file)
    }

    func downloadGeneratedFile(_ file: GeneratedFile) async throws -> DownloadedGeneratedFile {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let requestedTransferEpoch = fileTransferEpoch
        let downloaded = try await fileTransfer.downloadGeneratedFile(
            file,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              fileTransferEpoch == requestedTransferEpoch else {
            try? FileManager.default.removeItem(at: downloaded.localURL)
            throw LibreChatProtocolError.unsupported(
                "The file download no longer belongs to the active app session."
            )
        }
        return downloaded
    }

    private func authoritativeArtifactMessage(
        conversationID: ConversationID,
        identity: ArtifactIdentity
    ) async throws -> ChatMessage {
        let history = try await messages(conversationID: conversationID)
        guard let message = history.first(where: { $0.id == identity.messageID }) else {
            throw ArtifactEditError.messageNotFound
        }
        return message
    }

    private static func artifact(
        in message: ChatMessage,
        identity: ArtifactIdentity
    ) -> ParsedArtifact? {
        if let authoritative = message.artifactCatalog.first(where: { $0.identity == identity }) {
            return authoritative
        }
        var nextDocumentOrderIndex = 0
        for content in message.content {
            guard case let .text(text) = content else { continue }
            let document = ArtifactParser.parse(
                messageID: message.id,
                text: text,
                startingDocumentOrderIndex: nextDocumentOrderIndex
            )
            if let artifact = document.artifacts.first(where: { $0.identity == identity }) {
                return artifact
            }
            nextDocumentOrderIndex = document.nextDocumentOrderIndex
        }
        return nil
    }

    private static func artifactMutationRequiresReconciliation(_ error: Error) -> Bool {
        guard let error = error as? LibreChatProtocolError else { return false }
        return switch error {
        case .transport, .invalidResponse, .decoding, .serverNotReady:
            true
        case let .httpStatus(status, _, _):
            status == 400 || status >= 500
        default:
            false
        }
    }

    /// The server removes one trailing LF from `original` before matching and
    /// inserts a separator LF before the artifact closer when `updated` does
    /// not already end in one. Reconciliation must compare the editor value
    /// using the same one-newline equivalence or an applied edit looks stale.
    private static func artifactContentsMatch(_ left: String, _ right: String) -> Bool {
        func removingOneTrailingNewline(_ value: String) -> String {
            if value.hasSuffix("\r\n") { return String(value.dropLast(2)) }
            if value.hasSuffix("\n") { return String(value.dropLast()) }
            return value
        }
        return removingOneTrailingNewline(left) == removingOneTrailingNewline(right)
    }

    func delete(id: ConversationID) async throws {
        let accountID = try activeAccountID()
        if id.isLocalDraft {
            try await cache.deleteConversation(
                profileID: profile.id,
                accountID: accountID,
                conversationID: id
            )
            return
        }
        let payload = DeleteConversationRequest(conversationID: id.rawValue)
        let request = try APIRequest<EmptyResponse>(
            method: .delete,
            path: "api/convos",
            body: try JSONEncoder().encode(DeleteConversationEnvelope(arg: payload)),
            retryPolicy: .never
        )
        do {
            _ = try await runtime.restClient.send(request)
        } catch {
            let deletionError = error
            if let protocolError = error as? LibreChatProtocolError,
               case .httpStatus(404, _, _) = protocolError {
                try await cache.deleteConversation(
                    profileID: profile.id,
                    accountID: accountID,
                    conversationID: id
                )
                return
            }
            guard Self.isAmbiguousDeletionFailure(error) else { throw error }
            do {
                let existenceRequest = APIRequest<LibreChatConversationDTO>(
                    path: "api/convos/\(id.rawValue)",
                    retryPolicy: .idempotent(maximumAttempts: 2)
                )
                _ = try await runtime.restClient.send(existenceRequest)
            } catch let reconciliationError as LibreChatProtocolError {
                if case .httpStatus(404, _, _) = reconciliationError {
                    try await cache.deleteConversation(
                        profileID: profile.id,
                        accountID: accountID,
                        conversationID: id
                    )
                    return
                }
                if case .unauthorized = reconciliationError {
                    throw reconciliationError
                }
                throw LibreChatProtocolError.unsupported(
                    "LibreChat may have deleted this conversation, but the app could not confirm the result. Refresh before trying again."
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LibreChatProtocolError.unsupported(
                    "LibreChat may have deleted this conversation, but the app could not confirm the result. Refresh before trying again."
                )
            }
            throw deletionError
        }
        try await cache.deleteConversation(profileID: profile.id, accountID: accountID, conversationID: id)
    }

    func rename(id: ConversationID, title: String) async throws -> LibreChatDomain.Conversation {
        let accountID = try activeAccountID()
        let conversation = try await performConversationMutation(
            id: id,
            request: try LibreChatConversationManagementAPI.rename(conversationID: id, title: title),
            matches: { $0.title == title }
        )
        try await cache.save(
            page: ConversationPage(conversations: [conversation]),
            profileID: profile.id,
            accountID: accountID,
            completeSynchronization: false
        )
        return conversation
    }

    func archive(
        id: ConversationID,
        isArchived: Bool
    ) async throws -> LibreChatDomain.Conversation {
        let accountID = try activeAccountID()
        let conversation = try await performConversationMutation(
            id: id,
            request: try LibreChatConversationManagementAPI.archive(
                conversationID: id,
                isArchived: isArchived
            ),
            matches: { $0.isArchived == isArchived }
        )
        if isArchived {
            try await cache.removeConversationFromActiveList(
                profileID: profile.id,
                accountID: accountID,
                conversationID: id
            )
        } else {
            try await cache.save(
                page: ConversationPage(conversations: [conversation]),
                profileID: profile.id,
                accountID: accountID,
                completeSynchronization: false
            )
        }
        return conversation
    }

    func pin(id: ConversationID, pinned: Bool) async throws -> LibreChatDomain.Conversation {
        let accountID = try activeAccountID()
        let conversation = try await performConversationMutation(
            id: id,
            request: try LibreChatConversationManagementAPI.pin(conversationID: id, pinned: pinned),
            matches: { $0.pinned == pinned }
        )
        try await cache.save(
            page: ConversationPage(conversations: [conversation]),
            profileID: profile.id,
            accountID: accountID,
            completeSynchronization: false
        )
        return conversation
    }

    func conversationTags() async throws -> [ConversationTag] {
        try await runtime.restClient
            .send(LibreChatConversationTagsAPI.list())
            .domainModels()
    }

    func bookmarkedConversations(
        tag: String,
        cursor: String? = nil,
        limit: Int = 25
    ) async throws -> ConversationPage {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "isArchived", value: "false"),
            URLQueryItem(name: "sortBy", value: "updatedAt"),
            URLQueryItem(name: "sortDirection", value: "desc"),
            URLQueryItem(name: "tags", value: tag)
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await runtime.restClient.send(APIRequest<LibreChatConversationPageDTO>(
            path: "api/convos",
            queryItems: query,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )).domainModel()
        let accountID = try activeAccountID()
        try await cache.save(
            page: page,
            profileID: profile.id,
            accountID: accountID,
            completeSynchronization: false
        )
        return page
    }

    func createConversationTag(_ input: CreateConversationTagInput) async throws -> ConversationTag {
        let request = try LibreChatConversationTagsAPI.create(input)
        do {
            return try await runtime.restClient.send(request).domainModel()
        } catch {
            let originalError = error
            guard Self.isAmbiguousConversationMutationFailure(error) else { throw error }
            let authoritative = try await tagsAfterAmbiguousMutation()
            if let tag = authoritative.first(where: { $0.tag == input.tag }) {
                return tag
            }
            throw originalError
        }
    }

    func updateConversationTag(
        named tag: String,
        input: UpdateConversationTagInput
    ) async throws -> ConversationTag {
        let request = try LibreChatConversationTagsAPI.update(named: tag, input: input)
        do {
            return try await runtime.restClient.send(request).domainModel()
        } catch {
            let originalError = error
            guard Self.isAmbiguousConversationMutationFailure(error) else { throw error }
            let desiredName = input.tag ?? tag
            let authoritative = try await tagsAfterAmbiguousMutation()
            guard let candidate = authoritative.first(where: { $0.tag == desiredName }) else {
                throw originalError
            }
            let descriptionMatches = input.description.map { candidate.description == $0 } ?? true
            let positionMatches = input.position.map { candidate.position == $0 } ?? true
            guard descriptionMatches, positionMatches else { throw originalError }
            return candidate
        }
    }

    func deleteConversationTag(named tag: String) async throws -> ConversationTag {
        // A read-before-delete retains the exact directory record so an
        // ambiguous DELETE can return only after a subsequent list proves the
        // name is gone. The non-idempotent request itself is never replayed.
        let prior = try await conversationTags().first { $0.tag == tag }
        let request = try LibreChatConversationTagsAPI.delete(named: tag)
        do {
            return try await runtime.restClient.send(request).domainModel()
        } catch {
            let originalError = error
            guard Self.isAmbiguousConversationMutationFailure(error) else { throw error }
            let authoritative = try await tagsAfterAmbiguousMutation()
            if !authoritative.contains(where: { $0.tag == tag }), let prior {
                return prior
            }
            throw originalError
        }
    }

    func replaceConversationTags(
        conversationID: ConversationID,
        tags: [String]
    ) async throws -> [String] {
        let request = try LibreChatConversationTagsAPI.replace(
            conversationID: conversationID,
            tags: tags
        )
        let finalTags: [String]
        do {
            finalTags = try await runtime.restClient.send(request).domainModel()
        } catch {
            let originalError = error
            guard Self.isAmbiguousConversationMutationFailure(error) else { throw error }
            let authoritative: LibreChatDomain.Conversation
            do {
                authoritative = try await conversation(id: conversationID)
            } catch let reconciliationError as LibreChatProtocolError {
                if case .unauthorized = reconciliationError { throw reconciliationError }
                throw Self.tagMutationRefreshBeforeRetryError
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.tagMutationRefreshBeforeRetryError
            }
            let desired = Self.deduplicatedTags(tags)
            guard authoritative.tags == desired else { throw originalError }
            finalTags = desired
        }
        let accountID = try activeAccountID()
        try await cache.updateConversationTags(
            finalTags,
            profileID: profile.id,
            accountID: accountID,
            conversationID: conversationID
        )
        return finalTags
    }

    private func performConversationMutation(
        id: ConversationID,
        request: APIRequest<LibreChatConversationDTO>,
        matches: @escaping (LibreChatDomain.Conversation) -> Bool
    ) async throws -> LibreChatDomain.Conversation {
        do {
            return try await runtime.restClient.send(request).domainModel()
        } catch {
            let mutationError = error
            guard Self.isAmbiguousConversationMutationFailure(error) else { throw error }
            return try await reconcileConversationMutation(
                id: id,
                originalError: mutationError,
                matches: matches
            )
        }
    }

    private func reconcileConversationMutation(
        id: ConversationID,
        originalError: Error,
        matches: (LibreChatDomain.Conversation) -> Bool
    ) async throws -> LibreChatDomain.Conversation {
        let authoritative: LibreChatDomain.Conversation
        do {
            authoritative = try await conversation(id: id)
        } catch let error as LibreChatProtocolError {
            if case .unauthorized = error {
                throw error
            }
            throw Self.refreshBeforeRetryError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.refreshBeforeRetryError
        }

        let accountID = try activeAccountID()
        let mutationConfirmed = matches(authoritative)
        if mutationConfirmed, authoritative.isArchived == true {
            try await cache.removeConversationFromActiveList(
                profileID: profile.id,
                accountID: accountID,
                conversationID: authoritative.id
            )
        } else {
            try await cache.save(
                page: ConversationPage(conversations: [authoritative]),
                profileID: profile.id,
                accountID: accountID,
                completeSynchronization: false
            )
        }
        guard mutationConfirmed else { throw originalError }
        return authoritative
    }

    private static let refreshBeforeRetryError = LibreChatProtocolError.unsupported(
        "The conversation mutation could not be confirmed. Refresh before trying again."
    )

    private static let tagMutationRefreshBeforeRetryError = LibreChatProtocolError.unsupported(
        "The bookmark change could not be confirmed. Refresh before trying again."
    )

    private func tagsAfterAmbiguousMutation() async throws -> [ConversationTag] {
        do {
            return try await conversationTags()
        } catch let error as LibreChatProtocolError {
            if case .unauthorized = error { throw error }
            throw Self.tagMutationRefreshBeforeRetryError
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.tagMutationRefreshBeforeRetryError
        }
    }

    private static func deduplicatedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0).inserted }
    }

    private static func isAmbiguousConversationMutationFailure(_ error: Error) -> Bool {
        guard let protocolError = error as? LibreChatProtocolError else { return false }
        switch protocolError {
        case .transport:
            return true
        case let .httpStatus(status, _, _):
            return status >= 500
        default:
            return false
        }
    }

    private static func isAmbiguousDeletionFailure(_ error: Error) -> Bool {
        guard let protocolError = error as? LibreChatProtocolError else { return false }
        switch protocolError {
        case .transport:
            return true
        case let .httpStatus(status, _, _):
            return status >= 500
        default:
            return false
        }
    }

    func availableChatTargets() async throws -> [ChatTargetOption] {
        let catalog = try await targetCatalog(recentOptionID: nil)
        guard !catalog.options.isEmpty else {
            throw LibreChatProtocolError.unsupported(
                "This account has no selectable models or model specifications."
            )
        }
        return catalog.options
    }

    func newChatTargetCatalog() async throws -> TargetCatalogSnapshot {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let recentOptionID: String?
        do {
            recentOptionID = try await cache.recentChatTargetOptionID(
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
        } catch {
            AppLog.persistence.error("Recent chat target preference could not be read.")
            recentOptionID = nil
        }
        guard profile.id == requestedProfileID, accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while models were being loaded."
            )
        }
        let catalog = try await targetCatalog(recentOptionID: recentOptionID)
        guard catalog.profileID == requestedProfileID,
              catalog.accountID == requestedAccountID,
              profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while models were being loaded."
            )
        }
        return catalog
    }

    func rememberRecentChatTargetOptionID(
        _ optionID: String,
        profileID requestedProfileID: ServerProfileID,
        accountID requestedAccountID: AccountID
    ) async {
        do {
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                return
            }
            try await cache.saveRecentChatTargetOptionID(
                optionID,
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
        } catch {
            // The local draft already exists. A non-authoritative preference
            // write must never turn successful chat creation into a failure.
            AppLog.persistence.error("Recent chat target preference could not be saved.")
        }
    }

    func targetCatalog(recentOptionID: String?) async throws -> TargetCatalogSnapshot {
        let accountID = try activeAccountID()
        let endpointsRequest = APIRequest<JSONValue>(
            path: "api/endpoints",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        let modelsRequest = APIRequest<JSONValue>(
            path: "api/models",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        let startupRequest = APIRequest<StartupConfigDTO>(
            path: "api/config",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )

        async let endpoints = runtime.restClient.send(endpointsRequest)
        async let models = runtime.restClient.send(modelsRequest)
        async let authenticatedStartup = runtime.restClient.send(startupRequest)
        let (endpointValue, modelValue, refreshedStartup) = try await (
            endpoints,
            models,
            authenticatedStartup
        )
        startupConfiguration = refreshedStartup

        let endpointObjects = endpointValue.objectValue ?? [:]
        let fetchedAt = Date()
        let credentialFlags = [
            "userProvide",
            "userProvideAccessKeyId",
            "userProvideSecretAccessKey",
            "userProvideSessionToken",
            "userProvideBearerToken"
        ]
        let userProvidedCredentialSlots: [String: String] = Dictionary(
            uniqueKeysWithValues: endpointObjects.compactMap { endpoint, value -> (String, String)? in
                let config = value.objectValue
                guard credentialFlags.contains(where: { config?[$0]?.boolValue == true }) else {
                    return nil
                }
                let keyName = config?["azure"]?.boolValue == true ? "azureOpenAI" : endpoint
                return (endpoint, keyName)
            }
        )
        async let agentDiscovery = savedAgentDiscovery(
            endpointConfigured: endpointObjects["agents"]?.objectValue != nil
        )
        async let credentialSlotEvidence = userKeyEvidence(
            endpoints: Set(userProvidedCredentialSlots.values),
            fetchedAt: fetchedAt
        )
        let (resolvedAgentDiscovery, resolvedSlotEvidence) = try await (
            agentDiscovery,
            credentialSlotEvidence
        )
        let credentialEvidence: [String: TargetCredentialEvidence] = Dictionary(
            uniqueKeysWithValues: userProvidedCredentialSlots.map {
                ($0.key, resolvedSlotEvidence[$0.value] ?? .unavailable)
            }
        )

        return TargetCatalogMapper().snapshot(
            profileID: profile.id,
            accountID: accountID,
            fetchedAt: fetchedAt,
            baseURL: profile.baseURL,
            endpoints: endpointValue,
            models: modelValue,
            startup: refreshedStartup,
            agentDiscovery: resolvedAgentDiscovery,
            credentialEvidence: credentialEvidence,
            recentOptionID: recentOptionID
        )
    }

    // MARK: - Account profile

    func accountProfile() async throws -> UserAccount {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let dto = try await runtime.restClient.send(LibreChatAccountProfileAPI.profile())
        let user = try dto.domainModel()
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID,
              user.id == requestedAccountID else {
            throw AccountProfileError.accountMismatch
        }
        return user
    }

    func uploadAccountAvatar(
        _ upload: AccountAvatarUpload,
        previousAvatarURL: URL?
    ) async throws -> UserAccount {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let configuredLimit: Int64?
        do {
            let configuration = try await runtime.restClient.send(
                APIRequest<FileConfigurationDTO>(
                    path: "api/files/config",
                    authorization: .bearer,
                    retryPolicy: .idempotent(maximumAttempts: 2)
                )
            )
            // The raw config expresses size limits in MB (e.g. `2` for
            // 2 MiB); convert to bytes exactly like the upload path does.
            configuredLimit = configuration.mergedWithByteUnitsAndDefaults().avatarSizeLimit
        } catch {
            configuredLimit = nil
        }
        let maximumBytes: Int
        if let configuredLimit,
           configuredLimit >= 0,
           configuredLimit <= Int64(Int.max) {
            maximumBytes = Int(configuredLimit)
        } else {
            maximumBytes = LibreChatAccountProfileAPI.maximumAvatarBytes
        }
        let request = try LibreChatAccountProfileAPI.uploadAvatar(
            upload,
            boundary: "LibreChatAvatar-\(UUID().uuidString)",
            maximumBytes: maximumBytes
        )

        do {
            // This is deliberately raw and one-shot. A malformed 2xx body,
            // cancellation, or lost response can follow a committed upload;
            // none of those cases may replay the multipart request.
            let response = try await runtime.restClient.rawResponse(
                method: request.method,
                path: request.path,
                pathComponents: request.pathComponents,
                queryItems: request.queryItems,
                headers: request.headers,
                body: request.body,
                authorized: request.authorization == .bearer,
                retryPolicy: request.retryPolicy
            )
            try ensureAccountProfileScope(
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
            let dto = try JSONDecoder().decode(AccountAvatarResponseDTO.self, from: response.data)
            _ = try dto.domainURL(relativeTo: profile.baseURL)
        } catch is CancellationError {
            return try await reconcileAvatarUpload(
                previousAvatarURL: previousAvatarURL,
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
        } catch LibreChatProtocolError.unauthorized {
            // A 401 is definitive for this request and must reach the auth
            // boundary; do not mask it with a reconciliation GET.
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            guard Self.avatarMutationIsUncertain(error) else { throw error }
            return try await reconcileAvatarUpload(
                previousAvatarURL: previousAvatarURL,
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
        } catch let error as AccountProfileError {
            // A profile/account switch after dispatch is a fencing failure,
            // not evidence that the new runtime's account changed avatar.
            if error == .accountMismatch { throw error }
            return try await reconcileAvatarUpload(
                previousAvatarURL: previousAvatarURL,
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
        } catch {
            // A successful HTTP response with an invalid/malformed body is
            // also post-dispatch ambiguity. Reconcile instead of reposting.
            return try await reconcileAvatarUpload(
                previousAvatarURL: previousAvatarURL,
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
        }

        return try await reconcileAvatarUpload(
            previousAvatarURL: previousAvatarURL,
            profileID: requestedProfileID,
            accountID: requestedAccountID
        )
    }

    private func reconcileAvatarUpload(
        previousAvatarURL: URL?,
        profileID requestedProfileID: ServerProfileID,
        accountID requestedAccountID: AccountID
    ) async throws -> UserAccount {
        do {
            let account = try await accountProfile()
            try ensureAccountProfileScope(
                profileID: requestedProfileID,
                accountID: requestedAccountID
            )
            guard Self.avatarIdentity(account.avatarURL) != Self.avatarIdentity(previousAvatarURL) else {
                throw AccountProfileError.avatarOutcomeUnknown
            }
            return account
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as AccountProfileError {
            throw error
        } catch {
            throw AccountProfileError.avatarOutcomeUnknown
        }
    }

    private func ensureAccountProfileScope(
        profileID requestedProfileID: ServerProfileID,
        accountID requestedAccountID: AccountID
    ) throws {
        guard profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw AccountProfileError.accountMismatch
        }
    }

    private static func avatarMutationIsUncertain(_ error: LibreChatProtocolError) -> Bool {
        switch error {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            true
        case let .httpStatus(status, _, _) where status >= 500:
            true
        default:
            false
        }
    }

    /// Signed S3 URLs can rotate their query string during a normal GET. Do
    /// not mistake that URL refresh for proof that this upload committed.
    private static func avatarIdentity(_ url: URL?) -> String? {
        guard let url else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string
    }

    func deleteAccount(proof: TwoFactorProof?) async throws {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let request = try LibreChatAccountProfileAPI.deleteAccount(proof: proof)
        do {
            let response = try await runtime.restClient.send(request)
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                throw AccountDeletionError.outcomeUnknown
            }
            try response.validateConfirmation()
        } catch is CancellationError {
            throw AccountDeletionError.outcomeUnknown
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            switch error {
            case let .httpStatus(status, _, _) where status == 400:
                throw AccountDeletionError.verificationRejected
            case let .httpStatus(status, _, _) where status == 403:
                throw AccountDeletionError.notPermitted
            case let .httpStatus(status, _, _) where status >= 500:
                throw AccountDeletionError.outcomeUnknown
            case .transport, .decoding, .invalidResponse:
                throw AccountDeletionError.outcomeUnknown
            default:
                throw error
            }
        }
    }

    // MARK: - User-provided provider credentials

    func userKeyCatalog() async throws -> UserKeyCatalog {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let endpointValue = try await runtime.restClient.send(
            APIRequest<JSONValue>(
                path: "api/endpoints",
                retryPolicy: .idempotent(maximumAttempts: 2)
            )
        )
        guard profile.id == requestedProfileID, accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while provider credentials were being loaded."
            )
        }

        let fetchedAt = Date()
        let discovered = UserKeyCatalogMapper().requirements(from: endpointValue)
        let evidence = try await userKeyAvailability(
            endpointIDs: Set(discovered.map(\.id)),
            fetchedAt: fetchedAt
        )
        guard profile.id == requestedProfileID, accountID == requestedAccountID else {
            throw LibreChatProtocolError.unsupported(
                "The active LibreChat account changed while provider credentials were being loaded."
            )
        }
        return UserKeyCatalog(
            profileID: requestedProfileID,
            accountID: requestedAccountID,
            fetchedAt: fetchedAt,
            requirements: discovered.map { requirement in
                var requirement = requirement
                requirement.availability = evidence[requirement.id] ?? .unavailable
                return requirement
            }
        )
    }

    func saveUserKey(_ input: UserKeyUpdateInput) async throws -> UserKeyMutationResult {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let catalog = try await userKeyCatalog()
        guard catalog.profileID == requestedProfileID,
              catalog.accountID == requestedAccountID,
              profile.id == requestedProfileID,
              accountID == requestedAccountID,
              let requirement = catalog.requirements.first(where: { $0.id == input.endpointID }) else {
            throw UserKeyError.endpointUnavailable
        }
        let encodedValue = try UserKeyCredentialEncoder().encode(
            input.credentials,
            for: requirement
        )
        let request = try LibreChatUserKeysAPI.update(
            endpointID: input.endpointID,
            encodedValue: encodedValue,
            expiresAt: input.expiresAt
        )
        do {
            _ = try await runtime.restClient.send(request)
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            if Self.isAmbiguousUserKeyMutationFailure(error) {
                // Status can prove a first-time save or an exact expiry change,
                // but it can never prove that an existing secret was rotated.
                if let availability = try? await userKeyStatus(input.endpointID),
                   Self.statusProvesSave(
                    availability,
                    prior: requirement.availability,
                    requestedExpiry: input.expiresAt
                   ) {
                    return .confirmed(availability)
                }
                return .deliveryUncertain
            }
            throw error
        } catch is CancellationError {
            return .deliveryUncertain
        } catch {
            return .deliveryUncertain
        }

        guard profile.id == requestedProfileID, accountID == requestedAccountID else {
            return .deliveryUncertain
        }
        let availability = (try? await userKeyStatus(input.endpointID))
            ?? .stored(expiresAt: input.expiresAt)
        return availability.isUsable ? .confirmed(availability) : .deliveryUncertain
    }

    func revokeUserKey(_ endpointID: UserKeyEndpointID) async throws -> UserKeyMutationResult {
        let requestedProfileID = profile.id
        let requestedAccountID = try activeAccountID()
        let catalog = try await userKeyCatalog()
        guard catalog.profileID == requestedProfileID,
              catalog.accountID == requestedAccountID,
              catalog.requirements.contains(where: { $0.id == endpointID }),
              profile.id == requestedProfileID,
              accountID == requestedAccountID else {
            throw UserKeyError.endpointUnavailable
        }
        do {
            _ = try await runtime.restClient.send(
                LibreChatUserKeysAPI.revoke(endpointID: endpointID)
            )
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            guard Self.isAmbiguousUserKeyMutationFailure(error) else { throw error }
            if try await userKeyStatus(endpointID) == .missing {
                return .confirmed(.missing)
            }
            return .deliveryUncertain
        } catch is CancellationError {
            if try await userKeyStatus(endpointID) == .missing {
                return .confirmed(.missing)
            }
            return .deliveryUncertain
        } catch {
            return .deliveryUncertain
        }
        guard profile.id == requestedProfileID, accountID == requestedAccountID else {
            return .deliveryUncertain
        }
        let availability = try await userKeyStatus(endpointID)
        return availability == .missing ? .confirmed(.missing) : .deliveryUncertain
    }

    private func userKeyStatus(_ endpointID: UserKeyEndpointID) async throws -> UserKeyAvailability {
        try await runtime.restClient.send(
            LibreChatUserKeysAPI.status(endpointID: endpointID)
        ).domainAvailability(at: Date())
    }

    private func userKeyAvailability(
        endpointIDs: Set<UserKeyEndpointID>,
        fetchedAt: Date
    ) async throws -> [UserKeyEndpointID: UserKeyAvailability] {
        let restClient = runtime.restClient
        return try await withThrowingTaskGroup(
            of: (UserKeyEndpointID, UserKeyAvailability).self,
            returning: [UserKeyEndpointID: UserKeyAvailability].self
        ) { group in
            for endpointID in endpointIDs {
                group.addTask {
                    do {
                        let value = try await restClient.send(
                            LibreChatUserKeysAPI.status(endpointID: endpointID)
                        )
                        return (endpointID, value.domainAvailability(at: fetchedAt))
                    } catch LibreChatProtocolError.unauthorized {
                        throw LibreChatProtocolError.unauthorized
                    } catch {
                        return (endpointID, .unavailable)
                    }
                }
            }
            var result: [UserKeyEndpointID: UserKeyAvailability] = [:]
            for try await (endpointID, availability) in group {
                result[endpointID] = availability
            }
            return result
        }
    }

    private static func isAmbiguousUserKeyMutationFailure(
        _ error: LibreChatProtocolError
    ) -> Bool {
        switch error {
        case .transport, .invalidResponse, .decoding, .serverNotReady:
            true
        case let .httpStatus(status, _, _):
            status >= 500
        default:
            false
        }
    }

    private static func statusProvesSave(
        _ availability: UserKeyAvailability,
        prior: UserKeyAvailability,
        requestedExpiry: Date?
    ) -> Bool {
        guard case let .stored(actualExpiry) = availability else { return false }
        if case .missing = prior { return true }
        switch (requestedExpiry, actualExpiry) {
        case (nil, nil):
            return false
        case let (requested?, actual?):
            return abs(requested.timeIntervalSince(actual)) < 2
                && prior != availability
        default:
            return false
        }
    }

    private func savedAgentDiscovery(endpointConfigured: Bool) async throws -> AgentTargetDiscovery {
        guard endpointConfigured else { return .notSupported }
        var cursor: String?
        var seenCursors = Set<String>()
        var options: [ChatTargetOption] = []
        var seenAgentIDs = Set<String>()

        for _ in 0..<20 {
            var query = [
                URLQueryItem(name: "requiredPermission", value: "1"),
                URLQueryItem(name: "limit", value: "1000")
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

            let request = APIRequest<AgentListResponseDTO>(
                path: "api/agents",
                queryItems: query,
                retryPolicy: .idempotent(maximumAttempts: 2)
            )
            let page: AgentListResponseDTO
            do {
                page = try await runtime.restClient.send(request)
            } catch LibreChatProtocolError.unauthorized {
                throw LibreChatProtocolError.unauthorized
            } catch let LibreChatProtocolError.httpStatus(status, _, _) where status == 403 {
                return .permissionDenied
            } catch let LibreChatProtocolError.httpStatus(status, _, _) where status == 404 || status == 405 {
                return .unavailable
            } catch {
                AppLog.compatibility.error("Saved-agent discovery unavailable; agent targets are disabled.")
                return .unavailable
            }

            for dto in page.data {
                guard let option = try? dto.targetOption(baseURL: profile.baseURL),
                      let agentID = option.target.agentID,
                      seenAgentIDs.insert(agentID).inserted else { continue }
                options.append(option)
                if options.count >= 5_000 { return .available(options) }
            }

            guard page.hasMore else { return .available(options) }
            guard let next = page.after?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !next.isEmpty,
                  seenCursors.insert(next).inserted else {
                throw LibreChatProtocolError.invalidResponse
            }
            cursor = next
        }
        throw LibreChatProtocolError.invalidResponse
    }

    private func userKeyEvidence(
        endpoints: Set<String>,
        fetchedAt: Date
    ) async throws -> [String: TargetCredentialEvidence] {
        guard !endpoints.isEmpty else { return [:] }
        let restClient = runtime.restClient
        return try await withThrowingTaskGroup(
            of: (String, TargetCredentialEvidence).self,
            returning: [String: TargetCredentialEvidence].self
        ) { group in
            for endpoint in endpoints {
                group.addTask {
                    let request = APIRequest<UserKeyExpiryDTO>(
                        path: "api/keys",
                        queryItems: [URLQueryItem(name: "name", value: endpoint)],
                        retryPolicy: .idempotent(maximumAttempts: 2)
                    )
                    do {
                        let response = try await restClient.send(request)
                        return (endpoint, Self.keyEvidence(response.expiresAt, fetchedAt: fetchedAt))
                    } catch LibreChatProtocolError.unauthorized {
                        throw LibreChatProtocolError.unauthorized
                    } catch {
                        AppLog.compatibility.error("User-key status unavailable; affected targets are disabled.")
                        return (endpoint, .unavailable)
                    }
                }
            }

            var result: [String: TargetCredentialEvidence] = [:]
            for try await (endpoint, evidence) in group {
                result[endpoint] = evidence
            }
            return result
        }
    }

    private static func keyEvidence(
        _ rawExpiry: String?,
        fetchedAt: Date
    ) -> TargetCredentialEvidence {
        guard let rawExpiry = rawExpiry?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawExpiry.isEmpty else { return .missing }
        if rawExpiry.lowercased() == "never" { return .available }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expiry = fractional.date(from: rawExpiry)
            ?? ISO8601DateFormatter().date(from: rawExpiry) else {
            return .unavailable
        }
        return expiry > fetchedAt ? .available : .expired
    }

    func createConversation(title: String, target: ConversationTarget) async throws -> LibreChatDomain.Conversation {
        try await createConversation(title: title, target: target, isTemporary: false)
    }

    func createConversation(
        title: String,
        target: ConversationTarget,
        isTemporary: Bool
    ) async throws -> LibreChatDomain.Conversation {
        let conversation = LibreChatDomain.Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title,
            model: target.model,
            updatedAt: Date(),
            target: target,
            isTemporary: isTemporary
        )
        if isTemporary {
            await registerTemporaryConversation(conversation.id)
        }
        return conversation
    }

    func send(_ request: ChatRequest) async throws -> ChatSendOutcome {
        guard request.profileID == profile.id, request.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported("The active LibreChat account changed before this message was sent.")
        }
        if case .unsupported = profile.capabilities?.generation {
            throw LibreChatProtocolError.unsupported(
                "This server can be browsed, but sending requires resumable generation protocol v2."
            )
        }
        if let recoverySteerID = request.recoverySteerID {
            guard case .send = request.action,
                  !request.conversation.id.isLocalDraft,
                  request.clientMessageID.rawValue == recoverySteerID,
                  Self.isValidRecoverySteerIdentifier(recoverySteerID),
                  let predecessor = request.expectedPredecessorCreatedAt,
                  predecessor >= 0,
                  let generation = profile.capabilities?.generation,
                  case let .resumable(version) = generation,
                  version == Self.generationProtocolVersion else {
                throw LibreChatProtocolError.unsupported(
                    "A recovered response direction requires its exact v2 source, message identity, and predecessor epoch."
                )
            }
        } else if !Self.isSafeGenerationMessageID(request.clientMessageID) {
            throw LibreChatProtocolError.encoding(
                "The client message ID is not a safe persisted LibreChat message identifier."
            )
        }
        switch request.action {
        case .editPromptAndResubmit, .regenerateResponse:
            guard let generation = profile.capabilities?.generation,
                  case let .resumable(version) = generation,
                  version == Self.generationProtocolVersion else {
                throw LibreChatProtocolError.unsupported(
                    "This branch action requires a server whose resumable generation v2 capability has already been verified."
                )
            }
        case .send:
            break
        }

        var selectedParentMessageID = request.parentMessageID.flatMap { parentMessageID in
            Self.isRootParentSentinel(parentMessageID) ? nil : parentMessageID
        }
        if let parentMessageID = selectedParentMessageID,
           Self.isClientLocalMessageID(parentMessageID) {
            throw LibreChatProtocolError.unsupported(
                "The selected branch has not been confirmed by LibreChat. Refresh the conversation before sending."
            )
        }

        let fullConversation = if request.conversation.id.isLocalDraft {
            request.conversation
        } else {
            try await conversation(id: request.conversation.id)
        }
        let isTemporary = fullConversation.isTemporaryConversation
        if isTemporary {
            await registerTemporaryConversation(fullConversation.id)
        }

        let isPromptEdit: Bool
        let isResponseRegenerate: Bool
        var responseMessageID: String?
        var expectedPredecessorCreatedAt = request.expectedPredecessorCreatedAt
        switch request.action {
        case .send:
            isPromptEdit = false
            isResponseRegenerate = false
        case let .editPromptAndResubmit(sourceUserMessageID):
            isPromptEdit = true
            isResponseRegenerate = false
            guard !fullConversation.id.isLocalDraft else {
                throw LibreChatProtocolError.unsupported(
                    "A prompt can only be edited after LibreChat has confirmed the conversation."
                )
            }
            guard request.attachments.isEmpty else {
                throw LibreChatProtocolError.unsupported(
                    "Prompt edit with new or replayed attachments is not supported yet."
                )
            }
            guard !Self.isClientLocalMessageID(sourceUserMessageID) else {
                throw LibreChatProtocolError.unsupported(
                    "The selected prompt has not been confirmed by LibreChat. Refresh the conversation before editing it."
                )
            }
            let statusCreatedAt = try await rejectActiveGeneration(for: fullConversation.id)
            if let expected = request.expectedPredecessorCreatedAt,
               let actual = statusCreatedAt,
               expected != actual {
                throw LibreChatProtocolError.unsupported(
                    "The conversation changed before this prompt could be resubmitted. Refresh and try again."
                )
            }
            expectedPredecessorCreatedAt = statusCreatedAt ?? request.expectedPredecessorCreatedAt
            let history = try await messages(conversationID: fullConversation.id)
            selectedParentMessageID = try promptEditParent(
                sourceUserMessageID: sourceUserMessageID,
                conversationID: fullConversation.id,
                history: history,
                target: fullConversation.target
            )
        case let .regenerateResponse(sourceUserMessageID, targetAssistantMessageID):
            isPromptEdit = false
            isResponseRegenerate = true
            guard !fullConversation.id.isLocalDraft else {
                throw LibreChatProtocolError.unsupported(
                    "A response can only be regenerated after LibreChat has confirmed the conversation."
                )
            }
            guard request.attachments.isEmpty,
                  !Self.isClientLocalMessageID(sourceUserMessageID),
                  !Self.isClientLocalMessageID(targetAssistantMessageID),
                  Self.isSafeGenerationMessageID(sourceUserMessageID),
                  Self.isSafeGenerationMessageID(targetAssistantMessageID) else {
                throw LibreChatProtocolError.unsupported(
                    "Only confirmed server messages can be regenerated."
                )
            }
            let statusCreatedAt = try await rejectActiveGeneration(for: fullConversation.id)
            if let expected = request.expectedPredecessorCreatedAt,
               let actual = statusCreatedAt,
               expected != actual {
                throw LibreChatProtocolError.unsupported(
                    "The conversation changed before this response could be regenerated. Refresh and try again."
                )
            }
            expectedPredecessorCreatedAt = statusCreatedAt ?? request.expectedPredecessorCreatedAt
            let history = try await messages(conversationID: fullConversation.id)
            let selection = try responseRegenerationSelection(
                sourceUserMessageID: sourceUserMessageID,
                targetAssistantMessageID: targetAssistantMessageID,
                conversationID: fullConversation.id,
                history: history,
                target: fullConversation.target,
                expectedManualSkills: request.manualSkills
            )
            guard request.text == selection.sourceText else {
                throw LibreChatProtocolError.unsupported(
                    "The response source changed before regeneration. Refresh and try again."
                )
            }
            selectedParentMessageID = selection.parentMessageID
            let preliminary = Self.preliminaryResponseMessageID(for: targetAssistantMessageID)
            guard Self.isSafeGenerationMessageID(MessageID(rawValue: preliminary)) else {
                throw LibreChatProtocolError.unsupported(
                    "The selected response identifier cannot be represented safely by LibreChat."
                )
            }
            responseMessageID = preliminary
        }

        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibreChatProtocolError.unsupported("A message cannot be empty.")
        }
        guard request.text.utf16.count <= MessageEditRequest.maximumTextUTF16Length else {
            throw LibreChatProtocolError.unsupported(
                "This message exceeds the native client's maximum text length."
            )
        }

        if selectedParentMessageID == nil,
           !fullConversation.id.isLocalDraft,
           !isPromptEdit,
           !isResponseRegenerate {
            let authoritativeHistory = try await messages(conversationID: fullConversation.id)
            guard authoritativeHistory.isEmpty else {
                throw LibreChatProtocolError.unsupported(
                    "LibreChat has message history, but no selected branch parent was supplied. Refresh the conversation before sending."
                )
            }
        }
        guard let target = fullConversation.target, !target.endpoint.isEmpty else {
            throw LibreChatProtocolError.unsupported("This conversation has no endpoint information.")
        }
        let endpointPathComponent: String
        switch GenerationEndpointPolicy.route(for: target) {
        case let .resumableV2(component):
            endpointPathComponent = component
        case .unsupported(.assistantsProtocol):
            throw LibreChatProtocolError.unsupported(
                "Assistant-endpoint generation is not supported by this native client yet."
            )
        case .unsupported:
            throw LibreChatProtocolError.unsupported(
                "This conversation uses an endpoint family that the native client cannot route safely. Choose a supported target in New Chat."
            )
        }
        if target.endpoint == "agents", target.agentID?.isEmpty != false {
            throw LibreChatProtocolError.unsupported("This agent conversation is missing its agent identifier.")
        }
        guard target.ephemeralAgent?.isSafeForRequest != false else {
            throw LibreChatProtocolError.unsupported(
                "This model specification has an invalid request-scoped tool configuration. Refresh the server policy before sending."
            )
        }

        let validatedManualSkills: [String]
        if request.manualSkills.isEmpty {
            validatedManualSkills = []
        } else {
            guard request.recoverySteerID == nil else {
                throw LibreChatProtocolError.unsupported(
                    "Recovered response directions cannot be combined with a new Skills selection."
                )
            }
            let skillCatalog = try await skillInvocationCatalog(for: target)
            guard skillCatalog.profileID == profile.id,
                  skillCatalog.accountID == request.accountID,
                  skillCatalog.target == target,
                  skillCatalog.isComplete else {
                throw SkillInvocationError.invalidCatalog
            }
            validatedManualSkills = try skillCatalog.validatedSelection(request.manualSkills)
        }

        let clientRequestID = request.clientRequestID
        let messageID = if let recoverySteerID = request.recoverySteerID {
            recoverySteerID
        } else if isResponseRegenerate {
            switch request.action {
            case let .regenerateResponse(sourceUserMessageID, _): sourceUserMessageID.rawValue
            default: request.clientMessageID.rawValue
            }
        } else {
            request.clientMessageID.rawValue
        }
        let recoveryConversationID = if fullConversation.id.isLocalDraft {
            ConversationID(rawValue: LibreChatGenerationIdentity.newConversationID(
                userID: request.accountID.rawValue,
                clientRequestID: clientRequestID.uuidString
            ))
        } else {
            fullConversation.id
        }
        if isTemporary {
            await registerTemporaryConversation(recoveryConversationID)
        }
        let payload = GenerationStartRequest(
            text: request.text,
            sender: "User",
            clientTimestamp: ISO8601DateFormatter().string(from: Date()),
            isCreatedByUser: true,
            // Branch selection is client-owned and derived from the exact
            // authoritative message graph. Conversation routing metadata is
            // not a persisted LibreChat branch head and must never override it.
            parentMessageID: selectedParentMessageID?.rawValue
                ?? Self.noParentMessageID,
            conversationID: fullConversation.id.serverValue,
            messageID: messageID,
            endpoint: target.endpoint,
            endpointType: target.endpointType,
            model: target.model,
            agentID: target.agentID,
            assistantID: target.assistantID,
            spec: target.spec,
            promptPrefix: target.promptPrefix,
            ephemeralAgent: target.ephemeralAgent.map {
                GenerationEphemeralAgentRequest(
                    $0,
                    enableUnspecifiedSkills: !validatedManualSkills.isEmpty
                )
            },
            isTemporary: isTemporary,
            isRegenerate: isResponseRegenerate,
            isContinued: false,
            clientRequestID: clientRequestID.uuidString,
            timezone: TimeZone.current.identifier,
            generationProtocolVersion: Self.generationProtocolVersion,
            files: request.attachments.map { GenerationFileReference(fileID: $0.id) },
            chatProjectID: fullConversation.projectID?.rawValue,
            expectedPredecessorCreatedAt: expectedPredecessorCreatedAt,
            recoverySteerID: request.recoverySteerID,
            overrideUserMessageID: request.recoverySteerID,
            overrideParentMessageID: isResponseRegenerate ? messageID : nil,
            responseMessageID: responseMessageID,
            manualSkills: isResponseRegenerate
                ? validatedManualSkills
                : (validatedManualSkills.isEmpty ? nil : validatedManualSkills),
            quotes: isResponseRegenerate ? [] : nil
        )
        let startRequest = try APIRequest<GenerationStartResponseDTO>(
            path: "api/agents/chat",
            pathComponents: ["api", "agents", "chat", endpointPathComponent],
            headers: [Self.generationProtocolHeader: String(Self.generationProtocolVersion)],
            body: payload,
            retryPolicy: .never
        )

        AppLog.generation.info(
            "Generation start requested; protocol=\(Self.generationProtocolVersion, privacy: .public), localDraft=\(fullConversation.id.isLocalDraft, privacy: .public)."
        )

        let receipt = try await startGeneration(
            startRequest,
            conversationID: recoveryConversationID,
            messageID: MessageID(rawValue: messageID),
            allowsActiveDeterministicRecovery: fullConversation.id.isLocalDraft,
            allowsSettledHistoryRecovery: !isResponseRegenerate
        )

        guard receipt.generationProtocolVersion == Self.generationProtocolVersion else {
            AppLog.generation.error("Generation start rejected because the negotiated protocol was not resumable v2.")
            var capabilities = profile.capabilities ?? ServerCapabilities()
            capabilities.generation = .unsupported(advertisedVersion: receipt.generationProtocolVersion)
            profile.capabilities = capabilities
            try? await cache.save(profile: profile)
            throw LibreChatProtocolError.unsupported(
                "This server can be browsed, but sending requires resumable generation protocol v2."
            )
        }
        var capabilities = profile.capabilities ?? ServerCapabilities()
        capabilities.generation = .resumable(version: Self.generationProtocolVersion)
        profile.capabilities = capabilities
        try? await cache.save(profile: profile)

        let receiptStatus = receipt.status ?? "started"
        let acceptedStatuses = Set(["started", "resumed", "settled", "aborted", "error", "replaced", "predecessor_mismatch"])
        guard acceptedStatuses.contains(receiptStatus),
              let receiptConversationID = receipt.conversationID,
              !receiptConversationID.isEmpty else {
            AppLog.generation.error("Generation start returned an invalid receipt envelope.")
            throw LibreChatProtocolError.invalidResponse
        }
        if receiptStatus == "replaced" || receiptStatus == "predecessor_mismatch" {
            if let winner = try await provenWinnerHandoff(
                receipt: receipt,
                requestedConversationID: recoveryConversationID,
                expectedPredecessorCreatedAt: expectedPredecessorCreatedAt
            ) {
                AppLog.generation.notice(
                    "Generation admission handed off to an independently proven active winner."
                )
                return .handoff(winner)
            }
            throw LibreChatProtocolError.generationConflict(GenerationConflictDetails(
                code: receipt.code,
                status: receiptStatus,
                streamID: receipt.streamID,
                conversationID: receiptConversationID,
                generationCreatedAt: receipt.generationCreatedAt,
                predecessorVerified: receipt.predecessorVerified,
                active: receipt.active,
                generationProtocolVersion: receipt.generationProtocolVersion,
                message: "LibreChat could not verify an active replacement safely. Your draft was restored instead of attaching it."
            ))
        }
        switch receiptStatus {
        case "settled":
            // A terminal admission receipt is not a stream lease. Never
            // manufacture a handle or assign its eventual assistant message
            // to this optimistic submission; history is authoritative.
            return .settled(conversationID: ConversationID(rawValue: receiptConversationID))
        case "aborted":
            return .aborted(conversationID: ConversationID(rawValue: receiptConversationID))
        case "error":
            return .failed(
                conversationID: ConversationID(rawValue: receiptConversationID),
                failure: GenerationFailure(
                    code: receipt.code ?? "generation_failed",
                    message: "LibreChat could not complete this response.",
                    isRecoverable: false
                )
            )
        default:
            break
        }

        guard let streamID = receipt.streamID,
              !streamID.isEmpty,
              streamID == receiptConversationID,
              let generationCreatedAt = receipt.generationCreatedAt,
              generationCreatedAt >= 0 else {
            AppLog.generation.error("Generation start returned invalid resumable coordinates.")
            throw LibreChatProtocolError.invalidResponse
        }

        let handle = GenerationHandle(
            profileID: profile.id,
            accountID: request.accountID,
            clientRequestID: clientRequestID,
            streamID: streamID,
            conversationID: ConversationID(rawValue: receiptConversationID),
            generationCreatedAt: generationCreatedAt,
            protocolVersion: Self.generationProtocolVersion
        )
        let snapshot = GenerationSnapshot(handle: handle)
        try await persist(snapshot)
        await generationSession.install(snapshot)
        latestSnapshots[handle] = snapshot
        initialResume[handle] = receiptStatus == "resumed"
        AppLog.generation.info(
            "Generation start installed; status=\(receiptStatus, privacy: .public), protocol=\(Self.generationProtocolVersion, privacy: .public)."
        )
        return .streaming(handle)
    }

    /// Validates a prompt-edit source against the exact authoritative graph
    /// and returns its normalized direct parent.  In particular, this never
    /// uses a flat-history tail or conversation metadata as a branch anchor.
    private func promptEditParent(
        sourceUserMessageID: MessageID,
        conversationID: ConversationID,
        history: [ChatMessage],
        target: ConversationTarget?
    ) throws -> MessageID? {
        guard !history.isEmpty,
              history.allSatisfy({ $0.conversationID == conversationID }) else {
            throw LibreChatProtocolError.unsupported(
                "The conversation history contains messages from another conversation. Refresh before editing a prompt."
            )
        }
        let tree = MessageTree(messages: history)
        guard tree.isStructurallyValid else {
            throw LibreChatProtocolError.unsupported(
                "The conversation message graph is invalid; refresh it before editing a prompt."
            )
        }
        guard let selection = tree.siblings(containing: sourceUserMessageID) else {
            throw LibreChatProtocolError.unsupported(
                "The selected prompt is stale or is not part of this conversation. Refresh before editing it."
            )
        }
        let source = selection.selectedMessage
        guard source.conversationID == conversationID,
              case .user = source.author else {
            throw LibreChatProtocolError.unsupported(
                "Only a confirmed user prompt can be edited and resubmitted."
            )
        }
        guard source.isUnfinished != true else {
            throw LibreChatProtocolError.unsupported(
                "An unfinished prompt cannot be edited and resubmitted."
            )
        }
        guard !source.rawPlainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibreChatProtocolError.unsupported(
                "An empty prompt cannot be edited and resubmitted."
            )
        }
        guard source.citationAttachments.isEmpty,
              source.artifactCatalog.isEmpty,
              source.manualSkills?.isEmpty ?? true,
              source.quotes?.isEmpty ?? true else {
            throw LibreChatProtocolError.unsupported(
                "Only plain text prompts can be edited and resubmitted by this client."
            )
        }
        // Reconstructing `rawPlainText` from multiple rendered parts would
        // lose the exact PUT/GET coordinate LibreChat persisted. Require one
        // authoritative legacy `text` slot, and require its value to be the
        // complete source text. This also excludes reasoning/structured
        // content and legacy cache rows that have no exact editable catalog.
        guard source.content.count == 1,
              case let .text(sourceText) = source.content[0],
              source.editableTextCatalog.count == 1,
              case .primaryText = source.editableTextCatalog[0].location,
              source.editableTextCatalog[0].text == sourceText,
              source.rawPlainText == sourceText,
              !Self.containsReservedPromptMarkup(sourceText, messageID: source.id) else {
            throw LibreChatProtocolError.unsupported(
                "Only one unmarked, authoritative plain-text prompt can be edited and resubmitted."
            )
        }
        if let sourceEndpoint = source.endpoint,
           let targetEndpoint = target?.endpoint,
           sourceEndpoint != targetEndpoint {
            throw LibreChatProtocolError.unsupported(
                "The selected prompt uses configuration that cannot be replayed safely."
            )
        }
        // Ordinary GET /api/messages rows commonly omit routing fields on
        // user turns. A nil source value therefore carries no conflicting
        // replay evidence; the current conversation target remains the only
        // routing configuration sent by this text-only action.
        if let sourceModel = source.model,
           sourceModel != target?.model {
            throw LibreChatProtocolError.unsupported(
                "The selected prompt uses configuration that cannot be replayed safely."
            )
        }
        return selection.parentMessageID
    }

    private struct ResponseRegenerationSelection: Sendable {
        let parentMessageID: MessageID?
        let sourceText: String
    }

    /// Validates response regeneration against an exact authoritative
    /// user→assistant edge.  This intentionally supports only a plain-text
    /// source and plain-text assistant target. Persisted manual Skill names
    /// may be replayed only when the caller supplies the exact same list and
    /// fresh policy validation has already succeeded above.
    private func responseRegenerationSelection(
        sourceUserMessageID: MessageID,
        targetAssistantMessageID: MessageID,
        conversationID: ConversationID,
        history: [ChatMessage],
        target: ConversationTarget?,
        expectedManualSkills: [String]
    ) throws -> ResponseRegenerationSelection {
        guard !history.isEmpty,
              history.allSatisfy({ $0.conversationID == conversationID }) else {
            throw LibreChatProtocolError.unsupported(
                "The conversation history contains messages from another conversation. Refresh before regenerating."
            )
        }
        let tree = MessageTree(messages: history)
        guard tree.isStructurallyValid,
              let source = history.first(where: { $0.id == sourceUserMessageID }),
              let assistant = history.first(where: { $0.id == targetAssistantMessageID }) else {
            throw LibreChatProtocolError.unsupported(
                "The selected response is stale or is not part of this conversation. Refresh before regenerating."
            )
        }
        guard case .user = source.author,
              case .assistant = assistant.author,
              source.isUnfinished != true,
              assistant.isUnfinished != true,
              assistant.finishReason?.lowercased() != "error",
              let assistantSelection = tree.siblings(containing: targetAssistantMessageID),
              assistantSelection.parentMessageID == sourceUserMessageID else {
            throw LibreChatProtocolError.unsupported(
                "The selected response is not a finished direct child of the selected user prompt."
            )
        }
        guard source.content.count == 1,
              case let .text(sourceText) = source.content[0],
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.rawPlainText == sourceText,
              source.editableTextCatalog.count == 1,
              source.editableTextCatalog[0].location == .primaryText,
              source.editableTextCatalog[0].text == sourceText,
              source.citationAttachments.isEmpty,
              source.artifactCatalog.isEmpty,
              (source.manualSkills ?? []) == expectedManualSkills,
              source.quotes?.isEmpty ?? true,
              !Self.containsReservedPromptMarkup(sourceText, messageID: source.id) else {
            throw LibreChatProtocolError.unsupported(
                "Only one unmarked, authoritative plain-text prompt can be regenerated."
            )
        }
        guard assistant.content.allSatisfy({
            if case .text = $0 { return true }
            return false
        }),
              !assistant.content.isEmpty,
              assistant.citationAttachments.isEmpty,
              assistant.artifactCatalog.isEmpty,
              assistant.manualSkills?.isEmpty ?? true,
              assistant.quotes?.isEmpty ?? true else {
            throw LibreChatProtocolError.unsupported(
                "Only a plain-text assistant response can be regenerated by this client."
            )
        }
        if let sourceEndpoint = source.endpoint,
           sourceEndpoint != target?.endpoint,
           !sourceEndpoint.isEmpty {
            throw LibreChatProtocolError.unsupported(
                "The selected response uses configuration that cannot be replayed safely."
            )
        }
        if let assistantEndpoint = assistant.endpoint,
           assistantEndpoint != target?.endpoint,
           !assistantEndpoint.isEmpty {
            throw LibreChatProtocolError.unsupported(
                "The selected response uses configuration that cannot be replayed safely."
            )
        }
        if let sourceModel = source.model,
           sourceModel != target?.model,
           !sourceModel.isEmpty {
            throw LibreChatProtocolError.unsupported(
                "The selected response uses configuration that cannot be replayed safely."
            )
        }
        if let assistantModel = assistant.model,
           assistantModel != target?.model,
           !assistantModel.isEmpty {
            throw LibreChatProtocolError.unsupported(
                "The selected response uses configuration that cannot be replayed safely."
            )
        }
        guard let sourceSelection = tree.siblings(containing: sourceUserMessageID) else {
            throw LibreChatProtocolError.unsupported(
                "The selected prompt is not attached to a valid branch. Refresh before regenerating."
            )
        }
        return ResponseRegenerationSelection(
            parentMessageID: sourceSelection.parentMessageID,
            sourceText: sourceText
        )
    }

    /// A new prompt must not race an in-flight generation or a pending
    /// human/tool interaction in the same conversation.  Local checkpoints
    /// are authoritative enough to fail closed without making an additional
    /// start request or guessing from the history tail.
    private func rejectActiveGeneration(for conversationID: ConversationID) async throws -> Int64? {
        let inMemoryActive = latestSnapshots.values.contains {
            $0.handle.conversationID == conversationID && !$0.state.isTerminal
        }
        let accountID = try activeAccountID()
        let persistedActive = try await cache.recoverableGenerations(
            profileID: profile.id,
            accountID: accountID
        ).contains {
            $0.handle.conversationID == conversationID && !$0.state.isTerminal
        }
        guard !inMemoryActive, !persistedActive else {
            throw LibreChatProtocolError.unsupported(
                "Finish or resolve the active generation before editing or regenerating a branch."
            )
        }

        // LibreChat has no atomic 'expect idle' mutation fence. This
        // authoritative v2 preflight closes the known cross-client race as
        // far as possible; a generation that starts after this read is still
        // handled by the normal replaced/predecessor-mismatch winner proof.
        let status: GenerationStatusDTO
        do {
            status = try await generationStatus(
                conversationID: conversationID,
                protocolVersion: Self.generationProtocolVersion
            )
        } catch let error as LibreChatProtocolError {
            if error.isUnauthorized { throw error }
            throw LibreChatProtocolError.unsupported(
                "LibreChat could not verify that the conversation is idle. Try again before editing or regenerating."
            )
        } catch {
            throw LibreChatProtocolError.unsupported(
                "LibreChat could not verify that the conversation is idle. Try again before editing or regenerating."
            )
        }
        guard status.generationProtocolVersion == Self.generationProtocolVersion,
              !status.active else {
            throw LibreChatProtocolError.unsupported(
                "Finish or resolve the active generation before editing or regenerating a branch."
            )
        }
        return status.createdAt
    }

    func snapshots(for handle: GenerationHandle) async -> AsyncThrowingStream<GenerationSnapshot, Error> {
        let shouldInitiallyResume = initialResume.removeValue(forKey: handle) ?? true
        return AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                var resume = shouldInitiallyResume
                while !Task.isCancelled {
                    do {
                        AppLog.generation.info(
                            "Generation stream connecting; resume=\(resume, privacy: .public), reconnectAttempt=\(attempt, privacy: .public)."
                        )
                        let request = try await self.streamRequest(handle: handle, resume: resume)
                        let stream = await self.generationSession.snapshots(request: request, handle: handle)
                        var receivedTerminal = false
                        for try await snapshot in stream {
                            try Task.checkCancellation()
                            continuation.yield(snapshot)
                            self.record(snapshot)
                            await self.checkpoint(snapshot, force: Self.requiresImmediateCheckpoint(snapshot.state))
                            if snapshot.state.isTerminal {
                                AppLog.generation.info(
                                    "Generation stream reached a terminal state; kind=\(Self.logLabel(for: snapshot.state), privacy: .public)."
                                )
                                receivedTerminal = true
                                break
                            }
                        }
                        if receivedTerminal {
                            continuation.finish()
                            return
                        }
                    } catch is CancellationError {
                        continuation.finish()
                        return
                    } catch let error as LibreChatProtocolError {
                        if case .httpStatus(401, _, _) = error {
                            AppLog.generation.notice("Generation stream authorization expired; requesting one serialized refresh.")
                            do { _ = try await self.runtime.authSession.refresh() } catch {
                                AppLog.generation.error("Generation stream refresh failed; the stream will close as unauthorized.")
                                continuation.finish(throwing: LibreChatProtocolError.unauthorized)
                                return
                            }
                        } else if case .httpStatus(let status, _, _) = error,
                                  status == 404 || status == 409 {
                            AppLog.generation.notice(
                                "Generation stream requires authoritative reconciliation; status=\(status, privacy: .public)."
                            )
                            do {
                                let reconciled = try await self.reconcile(handle)
                                continuation.yield(reconciled)
                            } catch {
                                let reconciling = await self.generationSession.apply(
                                    SequencedGenerationEvent(event: .terminal(.reconciliationRequired(
                                        reason: status == 409 ? "generation_replaced" : "generation_missing"
                                    ))),
                                    to: handle
                                )
                                continuation.yield(reconciling)
                                await self.checkpoint(reconciling, force: true)
                            }
                            continuation.finish()
                            return
                        } else if Self.isFatalStreamError(error) {
                            AppLog.generation.error(
                                "Generation stream rejected a non-retriable request; the handle remains recoverable."
                            )
                            continuation.finish(throwing: error)
                            return
                        }
                    } catch {
                        // A resumable handle remains recoverable after transient transport failure.
                    }

                    attempt += 1
                    AppLog.generation.notice(
                        "Generation stream reconnect scheduled; attempt=\(attempt, privacy: .public)."
                    )
                    let reconnect = SequencedGenerationEvent(event: .reconnecting(attempt: attempt))
                    let reconnecting = await self.generationSession.apply(reconnect, to: handle)
                    continuation.yield(reconnecting)
                    await self.checkpoint(reconnecting, force: true)
                    guard attempt <= 5 else {
                        AppLog.generation.error("Generation stream exhausted its bounded reconnect attempts; the handle remains recoverable.")
                        continuation.finish()
                        return
                    }
                    let base = min(pow(2.0, Double(attempt - 1)) * 0.5, 8)
                    let jitter = Double.random(in: 0...(base * 0.2))
                    try? await Task.sleep(for: .milliseconds(Int((base + jitter) * 1_000)))
                    resume = true
                }
                continuation.finish()
            }
            self.register(task: task, for: handle)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func resume(_ generation: GenerationHandle) async throws {
        guard generation.profileID == profile.id, generation.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported("This generation belongs to another server profile.")
        }
        if let saved = try await cache.recoverableGenerations(
            profileID: generation.profileID,
            accountID: generation.accountID
        ).first(where: { $0.handle == generation }) {
            await generationSession.install(saved)
            latestSnapshots[generation] = saved
        }
        initialResume[generation] = true
    }

    func reconcile(_ generation: GenerationHandle) async throws -> GenerationSnapshot {
        guard generation.profileID == profile.id,
              generation.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported("This generation belongs to another server profile or account.")
        }
        let status = try await generationStatus(for: generation)
        return try await reconcile(generation, with: status)
    }

    func recoverActiveGenerations() async throws -> [GenerationSnapshot] {
        let accountID = try activeAccountID()
        let cached = try await cache.recoverableGenerations(profileID: profile.id, accountID: accountID)
        AppLog.generation.info(
            "Generation recovery started; cachedCheckpointCount=\(cached.count, privacy: .public)."
        )

        for saved in cached {
            try Task.checkCancellation()
            guard accountID == (try activeAccountID()) else {
                throw LibreChatProtocolError.unsupported("The active LibreChat account changed during generation recovery.")
            }
            await generationSession.install(saved)
            latestSnapshots[saved.handle] = saved
            do {
                _ = try await reconcile(saved.handle)
            } catch LibreChatProtocolError.unauthorized {
                throw LibreChatProtocolError.unauthorized
            } catch {
                // A local checkpoint remains recoverable when status is temporarily unavailable.
            }
        }

        let activeJobs: ActiveGenerationJobsDTO
        do {
            let request = APIRequest<ActiveGenerationJobsDTO>(
                path: "api/agents/chat/active",
                headers: [Self.generationProtocolHeader: String(Self.generationProtocolVersion)],
                retryPolicy: .idempotent(maximumAttempts: 2)
            )
            activeJobs = try await runtime.restClient.send(request)
            AppLog.generation.info(
                "Generation recovery discovery completed; activeJobCount=\(activeJobs.activeJobIDs.count, privacy: .public)."
            )
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            switch error {
            case .transport, .httpStatus(404, _, _), .httpStatus(405, _, _):
                return latestSnapshots.values
                    .filter { !$0.state.isTerminal }
                    .sorted { $0.updatedAt > $1.updatedAt }
            default:
                throw error
            }
        }

        for identifier in Set(activeJobs.activeJobIDs) where !identifier.isEmpty && identifier != "new" {
            try Task.checkCancellation()
            guard accountID == (try activeAccountID()) else {
                throw LibreChatProtocolError.unsupported("The active LibreChat account changed during generation recovery.")
            }
            let conversationID = ConversationID(rawValue: identifier)
            let status: GenerationStatusDTO
            do {
                status = try await generationStatus(
                    conversationID: conversationID,
                    protocolVersion: Self.generationProtocolVersion
                )
            } catch LibreChatProtocolError.unauthorized {
                throw LibreChatProtocolError.unauthorized
            } catch {
                continue
            }

            try Task.checkCancellation()
            guard accountID == (try activeAccountID()) else {
                throw LibreChatProtocolError.unsupported("The active LibreChat account changed during generation recovery.")
            }
            guard status.active,
                  status.status == "running" || status.status == "requires_action",
                  let streamID = status.streamID,
                  streamID == identifier,
                  let createdAt = status.createdAt,
                  createdAt >= 0,
                  status.generationProtocolVersion == Self.generationProtocolVersion else {
                continue
            }

            let handle = latestSnapshots.keys.first {
                $0.conversationID == conversationID
                    && $0.streamID == streamID
                    && $0.generationCreatedAt == createdAt
                    && $0.protocolVersion == Self.generationProtocolVersion
            } ?? GenerationHandle(
                profileID: profile.id,
                accountID: accountID,
                clientRequestID: UUID(),
                streamID: streamID,
                conversationID: conversationID,
                generationCreatedAt: createdAt,
                protocolVersion: Self.generationProtocolVersion
            )

            _ = try await reconcile(handle, with: status)
        }

        return latestSnapshots.values
            .filter { !$0.state.isTerminal }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func reconcile(
        _ generation: GenerationHandle,
        with status: GenerationStatusDTO
    ) async throws -> GenerationSnapshot {
        guard generation.profileID == profile.id,
              generation.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported("This generation belongs to another server profile or account.")
        }
        var snapshot = await generationSession.snapshot(for: generation) ?? GenerationSnapshot(handle: generation)

        if status.active {
            guard status.generationProtocolVersion == generation.protocolVersion,
                  status.streamID == generation.streamID,
                  let currentCreatedAt = status.createdAt,
                  currentCreatedAt >= 0,
                  let expectedCreatedAt = generation.generationCreatedAt else {
                // Do not let a malformed or different active status overwrite
                // this saved epoch's response/pending-action state.
                throw LibreChatProtocolError.invalidResponse
            }
            if currentCreatedAt != expectedCreatedAt {
                AppLog.generation.notice("Generation reconciliation found a different epoch; marking the saved handle superseded.")
                snapshot.state = .superseded
                snapshot.pendingInteraction = nil
                snapshot.updatedAt = Date()
                try await persist(snapshot)
                await generationSession.install(snapshot)
                latestSnapshots[generation] = snapshot
                return snapshot
            }
            if let event = generationDecoder.synchronizationEvent(from: status) {
                snapshot = await generationSession.apply(event, to: generation)
            }
            if case .awaitingApproval = snapshot.state {
                // The status payload restored a durable interaction that should remain actionable.
            } else {
                snapshot.state = .reconciling
            }
            snapshot.updatedAt = Date()
            try await persist(snapshot)
            await generationSession.install(snapshot)
            latestSnapshots[generation] = snapshot
            AppLog.generation.info(
                "Generation reconciliation restored an active state; kind=\(Self.logLabel(for: snapshot.state), privacy: .public)."
            )
            return snapshot
        }

        if let recoveryEvent = generationDecoder.recoverableSteersEvent(from: status.unrecoveredSteers) {
            snapshot = await generationSession.apply(recoveryEvent, to: generation)
        }

        let history: [ChatMessage]
        do {
            history = try await messages(conversationID: generation.conversationID)
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            history = []
        }
        let responseMessageID = status.resumeState?.objectValue?["responseMessageId"]?.stringValue
            .map(MessageID.init(rawValue:))
        let response = responseMessageID.flatMap { responseID in
            history.first { $0.id == responseID }
        }
        if let response { snapshot.response = response }
        switch status.status {
        case "aborted":
            snapshot.state = .aborted
        case "error":
            snapshot.state = .failed(GenerationFailure(
                code: "generation_failed",
                message: "LibreChat could not complete this response.",
                isRecoverable: false
            ))
        default:
            snapshot.state = snapshot.stopRequestedAt == nil ? .completed : .aborted
        }
        snapshot.pendingInteraction = nil
        snapshot.updatedAt = Date()
        try await persist(snapshot)
        await generationSession.install(snapshot)
        latestSnapshots[generation] = snapshot
        AppLog.generation.info(
            "Generation reconciliation reached a terminal state; kind=\(Self.logLabel(for: snapshot.state), privacy: .public)."
        )
        return snapshot
    }

    func stop(_ generation: GenerationHandle) async throws {
        guard generation.profileID == profile.id,
              generation.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported(
                "This generation belongs to another server profile or account."
            )
        }
        AppLog.generation.info("Generation stop requested.")
        let payload = AbortGenerationRequest(
            streamID: generation.streamID,
            conversationID: generation.conversationID.rawValue,
            generationCreatedAt: generation.generationCreatedAt,
            generationProtocolVersion: generation.protocolVersion
        )
        let request = try APIRequest<AbortGenerationResponseDTO>(
            path: "api/agents/chat/abort",
            headers: [Self.generationProtocolHeader: String(generation.protocolVersion)],
            body: payload,
            retryPolicy: .never
        )
        do {
            let response = try await runtime.restClient.send(request)
            if response.success == true,
               response.settled != true,
               response.persistenceFailed != true {
                AppLog.generation.info("Generation stop accepted; awaiting an authoritative terminal state.")
                if let recoveryEvent = generationDecoder.recoverableSteersEvent(from: response.pendingSteers) {
                    _ = await generationSession.apply(recoveryEvent, to: generation)
                }
                let snapshot = await generationSession.apply(
                    SequencedGenerationEvent(event: .stopRequested),
                    to: generation
                )
                try await persist(snapshot)
                latestSnapshots[generation] = snapshot
            } else {
                AppLog.generation.notice("Generation stop response was already settled or ambiguous; reconciling.")
                _ = try await reconcile(generation)
            }
        } catch let error as LibreChatProtocolError {
            switch error {
            case .httpStatus(404, _, _), .httpStatus(409, _, _):
                AppLog.generation.notice("Generation stop target changed before acknowledgement; reconciling.")
                _ = try await reconcile(generation)
            default:
                AppLog.generation.error("Generation stop failed before an authoritative outcome was established.")
                throw error
            }
        }
    }

    func respond(
        to interaction: PendingInteraction,
        handle: GenerationHandle,
        toolResolutions: [ToolApprovalResolution]? = nil,
        answer: String?,
        batchAnswers: [String: String]? = nil
    ) async throws -> GenerationSnapshot {
        guard handle.profileID == profile.id,
              handle.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported(
                "This pending action belongs to another server profile or account."
            )
        }
        guard let generationCreatedAt = handle.generationCreatedAt else {
            throw LibreChatProtocolError.invalidResponse
        }
        let actionID: String
        var decisions: [ToolApprovalResolutionPayload]?
        var resolvedAnswer: String?
        var resolvedAnswers: [String: String]?
        switch interaction {
        case let .toolApproval(request):
            actionID = request.id
            guard (request.streamID == nil || request.streamID == handle.streamID),
                  (request.conversationID == nil || request.conversationID == handle.conversationID),
                  !request.isExpired(),
                  let items = request.items,
                  !items.isEmpty,
                  let toolResolutions,
                  toolResolutions.count == items.count,
                  Set(toolResolutions.map(\.toolCallID)).count == toolResolutions.count,
                  Set(toolResolutions.map(\.toolCallID)) == Set(items.map(\.id)) else {
                throw LibreChatProtocolError.unsupported("LibreChat did not provide enough information to resolve this tool approval safely.")
            }
            let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            decisions = try toolResolutions.map { resolution in
                guard let item = itemsByID[resolution.toolCallID],
                      item.arguments != nil,
                      item.allowedDecisions.contains(resolution.decision),
                      resolution.scope == "once" else {
                    throw LibreChatProtocolError.unsupported("The server does not allow that decision for this tool call.")
                }
                let trimmedResponse = resolution.responseText?.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedReason = resolution.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                let editedArguments: [String: JSONValue]?
                switch resolution.decision {
                case .approve:
                    guard resolution.editedArgumentsJSON == nil,
                          trimmedResponse == nil,
                          trimmedReason == nil else {
                        throw LibreChatProtocolError.unsupported("Approve does not accept edited arguments, response text, or a reason.")
                    }
                    editedArguments = nil
                case .reject:
                    guard resolution.editedArgumentsJSON == nil,
                          trimmedResponse == nil,
                          (trimmedReason?.utf16.count ?? 0) <= 16_000 else {
                        throw LibreChatProtocolError.unsupported("The rejection reason is invalid.")
                    }
                    editedArguments = nil
                case .respond:
                    guard resolution.editedArgumentsJSON == nil,
                          let trimmedResponse,
                          !trimmedResponse.isEmpty,
                          trimmedResponse.utf16.count <= 16_000,
                          trimmedReason == nil else {
                        throw LibreChatProtocolError.unsupported("A response between 1 and 16,000 characters is required.")
                    }
                    editedArguments = nil
                case .edit:
                    guard trimmedResponse == nil,
                          trimmedReason == nil,
                          let raw = resolution.editedArgumentsJSON,
                          raw.utf16.count <= 100_000,
                          let data = raw.data(using: .utf8),
                          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                          let object = value.objectValue else {
                        throw LibreChatProtocolError.unsupported("Edited arguments must be a valid JSON object.")
                    }
                    editedArguments = object
                }
                return ToolApprovalResolutionPayload(
                    toolCallID: resolution.toolCallID,
                    decision: resolution.decision.rawValue,
                    editedArguments: editedArguments,
                    responseText: resolution.decision == .respond ? trimmedResponse : nil,
                    reason: resolution.decision == .reject ? trimmedReason : nil,
                    scope: "once"
                )
            }
        case let .userQuestion(question):
            actionID = question.id
            guard (question.streamID == nil || question.streamID == handle.streamID),
                  (question.conversationID == nil || question.conversationID == handle.conversationID) else {
                throw LibreChatProtocolError.unsupported("This question belongs to a different generation.")
            }
            guard !question.isExpired() else {
                throw LibreChatProtocolError.unsupported("This question has expired. Check the generation status before answering again.")
            }
            if let items = question.items {
                let itemIDs = items.map(\.id)
                guard !itemIDs.isEmpty,
                      !question.questionIDs.isEmpty,
                      Set(itemIDs).count == itemIDs.count,
                      Set(question.questionIDs).count == question.questionIDs.count,
                      itemIDs.count == question.questionIDs.count,
                      Set(itemIDs) == Set(question.questionIDs) else {
                    throw LibreChatProtocolError.unsupported(
                        "This question batch has invalid or duplicate identities."
                    )
                }
            }
            if question.questionIDs.isEmpty {
                guard let answer else {
                    throw LibreChatProtocolError.unsupported("An answer is required to continue this generation.")
                }
                let value = question.optionValues[answer] ?? answer
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf16.count <= 16_000 else {
                    throw LibreChatProtocolError.unsupported("The answer must be between 1 and 16,000 characters.")
                }
                resolvedAnswer = value
            } else {
                guard !question.questionIDs.isEmpty,
                      Set(question.questionIDs).count == question.questionIDs.count else {
                    throw LibreChatProtocolError.unsupported(
                        "This question batch has invalid or duplicate identities."
                    )
                }
                guard let batchAnswers,
                      Set(batchAnswers.keys) == Set(question.questionIDs),
                      batchAnswers.values.allSatisfy({
                          let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                          return !value.isEmpty && value.utf16.count <= 16_000
                      }) else {
                    throw LibreChatProtocolError.unsupported("Every pending question needs an answer before this generation can continue.")
                }
                resolvedAnswers = batchAnswers
            }
        case .externalAuthentication:
            throw LibreChatProtocolError.unsupported(
                "Complete the external authentication in the browser; this action cannot be resumed with a generic approval."
            )
        }
        // Resolve graph routing only after every user-controlled resolution is
        // locally complete and valid. An incomplete batch must not perform any
        // network request, including a conversation hydration GET.
        let currentConversation = try await conversation(id: handle.conversationID)
        guard let target = currentConversation.target,
              !target.endpoint.isEmpty else {
            throw LibreChatProtocolError.unsupported("This pending action is missing its original generation target.")
        }
        let payload = PendingInteractionResponse(
            conversationID: handle.conversationID.rawValue,
            generationCreatedAt: generationCreatedAt,
            generationProtocolVersion: handle.protocolVersion,
            actionID: actionID,
            endpoint: target.endpoint,
            agentID: target.agentID,
            decisions: decisions,
            answer: resolvedAnswer,
            answers: resolvedAnswers
        )
        let request = try APIRequest<GenerationResumeResponseDTO>(
            path: "api/agents/chat/resume",
            headers: [Self.generationProtocolHeader: String(handle.protocolVersion)],
            body: payload,
            retryPolicy: .never
        )
        let response: GenerationResumeResponseDTO
        do {
            response = try await runtime.restClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LibreChatProtocolError {
            // The request has crossed the dispatch boundary. Even a 4xx or
            // malformed 2xx response cannot be treated as a safe retry: the
            // server may already have consumed this action. The chat model
            // reconciles the exact handle/action before offering recovery.
            throw PendingInteractionResponseError.postDispatch(error)
        } catch {
            throw PendingInteractionResponseError.postDispatch(
                .transport(error.localizedDescription)
            )
        }
        guard response.status == "resuming",
              response.conversationID == handle.conversationID.rawValue,
              response.streamID == handle.streamID,
              response.generationProtocolVersion == handle.protocolVersion else {
            throw PendingInteractionResponseError.postDispatch(.invalidResponse)
        }
        let snapshot = await generationSession.apply(
            SequencedGenerationEvent(event: .lifecycle(.resumed)),
            to: handle
        )
        latestSnapshots[handle] = snapshot
        do {
            try await persist(snapshot)
        } catch {
            // The server acknowledgement is authoritative. A local checkpoint
            // failure must not turn a consumed action into a resubmittable UI.
            AppLog.persistence.error("Generation resume checkpoint failed after authoritative acknowledgement.")
        }
        return snapshot
    }

    // MARK: - Protocol-v2 generation steering controls

    func submitSteer(
        _ request: GenerationSteerRequest
    ) async throws -> GenerationSteerSubmissionOutcome {
        let normalizedText = try validateSteerSubmission(request)
        let lane = steeringLane(for: request.handle)
        await lane.acquire()
        do {
            // Waiting for another exact-handle mutation is pre-dispatch. A
            // cancelled waiter must never wake later and send unexpectedly.
            try Task.checkCancellation()
            // Revalidate after waiting. A terminal/replacement event must not
            // retarget this caller-owned operation to a newer generation.
            _ = try activeSteeringSnapshot(
                profileID: request.profileID,
                accountID: request.accountID,
                conversationID: request.conversationID,
                handle: request.handle
            )
            let epoch = try steeringEpoch(for: request.handle)
            let apiRequest = try LibreChatSteeringAPI.submit(
                conversationID: request.conversationID,
                generationCreatedAt: epoch,
                clientSteerID: request.clientSteerID,
                text: normalizedText,
                preempt: request.preempt
            )
            let response: HTTPResponse
            do {
                response = try await executeSteeringRequest(apiRequest)
            } catch is CancellationError {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: request.clientSteerID,
                    reason: .transport
                ))
            } catch let error as LibreChatProtocolError {
                if let uncertainty = Self.steeringUncertainty(
                    for: error,
                    clientSteerID: request.clientSteerID
                ) {
                    await lane.release()
                    return .deliveryUncertain(uncertainty)
                }
                throw error
            }

            let outcome: GenerationSteerSubmissionOutcome
            do {
                let dto = try JSONDecoder().decode(GenerationSteerReceiptDTO.self, from: response.data)
                outcome = try dto.domainOutcome(
                    statusCode: response.statusCode,
                    expectedConversationID: request.conversationID,
                    clientSteerID: request.clientSteerID,
                    expectedProtocolVersion: Self.generationProtocolVersion
                )
            } catch {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: request.clientSteerID,
                    reason: .invalidAcknowledgement
                ))
            }

            switch outcome {
            case let .queued(receipt), let .replayed(receipt):
                await installAcceptedSteer(
                    receipt,
                    normalizedText: normalizedText,
                    handle: request.handle
                )
            case let .leftover(receipt):
                await installReceiptLeftover(
                    receipt,
                    normalizedText: normalizedText,
                    handle: request.handle
                )
            case .settled, .deliveryUncertain:
                break
            }
            await lane.release()
            return outcome
        } catch {
            await lane.release()
            throw error
        }
    }

    func cancelSteer(
        _ request: GenerationSteerControlRequest
    ) async throws -> GenerationSteerCancelOutcome {
        try validateSteerControl(request)
        let lane = steeringLane(for: request.handle)
        await lane.acquire()
        do {
            try Task.checkCancellation()
            _ = try activeSteeringSnapshot(
                profileID: request.profileID,
                accountID: request.accountID,
                conversationID: request.conversationID,
                handle: request.handle
            )
            let apiRequest = try LibreChatSteeringAPI.cancel(
                conversationID: request.conversationID,
                generationCreatedAt: try steeringEpoch(for: request.handle),
                steerID: request.steerID,
                clientSteerID: request.clientSteerID
            )
            let response: HTTPResponse
            do {
                response = try await executeSteeringRequest(apiRequest)
            } catch is CancellationError {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: request.clientSteerID,
                    steerID: request.steerID,
                    reason: .transport
                ))
            } catch let error as LibreChatProtocolError {
                if let uncertainty = Self.steeringUncertainty(
                    for: error,
                    clientSteerID: request.clientSteerID,
                    steerID: request.steerID
                ) {
                    await lane.release()
                    return .deliveryUncertain(uncertainty)
                }
                throw error
            }
            let outcome: GenerationSteerCancelOutcome
            do {
                outcome = try JSONDecoder()
                    .decode(GenerationSteerCancelResponseDTO.self, from: response.data)
                    .domainOutcome(
                        statusCode: response.statusCode,
                        expectedProtocolVersion: Self.generationProtocolVersion
                    )
            } catch {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: request.clientSteerID,
                    steerID: request.steerID,
                    reason: .invalidAcknowledgement
                ))
            }
            if case .removed = outcome {
                await removeAcceptedCancelledSteer(request)
            }
            await lane.release()
            return outcome
        } catch {
            await lane.release()
            throw error
        }
    }

    func armSteer(
        _ request: GenerationSteerControlRequest
    ) async throws -> GenerationSteerArmOutcome {
        try validateSteerControl(request)
        let lane = steeringLane(for: request.handle)
        await lane.acquire()
        do {
            try Task.checkCancellation()
            _ = try activeSteeringSnapshot(
                profileID: request.profileID,
                accountID: request.accountID,
                conversationID: request.conversationID,
                handle: request.handle
            )
            let apiRequest = try LibreChatSteeringAPI.arm(
                conversationID: request.conversationID,
                generationCreatedAt: try steeringEpoch(for: request.handle),
                steerID: request.steerID,
                clientSteerID: request.clientSteerID
            )
            let response: HTTPResponse
            do {
                response = try await executeSteeringRequest(apiRequest)
            } catch is CancellationError {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: request.clientSteerID,
                    steerID: request.steerID,
                    reason: .transport
                ))
            } catch let error as LibreChatProtocolError {
                if let uncertainty = Self.steeringUncertainty(
                    for: error,
                    clientSteerID: request.clientSteerID,
                    steerID: request.steerID
                ) {
                    await lane.release()
                    return .deliveryUncertain(uncertainty)
                }
                throw error
            }
            let outcome: GenerationSteerArmOutcome
            do {
                outcome = try JSONDecoder()
                    .decode(GenerationSteerArmResponseDTO.self, from: response.data)
                    .domainOutcome(
                        statusCode: response.statusCode,
                        expectedProtocolVersion: Self.generationProtocolVersion
                    )
            } catch {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: request.clientSteerID,
                    steerID: request.steerID,
                    reason: .invalidAcknowledgement
                ))
            }
            if case let .armed(preemptRevision) = outcome {
                await installAcceptedArm(request, preemptRevision: preemptRevision)
            }
            await lane.release()
            return outcome
        } catch {
            await lane.release()
            throw error
        }
    }

    func recoverableGenerations() async throws -> [GenerationSnapshot] {
        try await cache.recoverableGenerations(profileID: profile.id, accountID: activeAccountID())
            .filter { !temporaryConversationIDs.contains($0.handle.conversationID) }
    }

    func followUpQueue(
        conversationID: ConversationID
    ) async throws -> FollowUpQueueSnapshot {
        try rejectTemporaryDurableQueue(conversationID)
        return try await cache.followUpQueue(
            namespace: followUpNamespace(conversationID: conversationID)
        )
    }

    func enqueueFollowUp(_ item: FollowUpQueueItem) async throws -> FollowUpQueueSnapshot {
        try rejectTemporaryDurableQueue(item.namespace.conversationID)
        let namespace = try followUpNamespace(conversationID: item.namespace.conversationID)
        guard item.namespace == namespace else { throw FollowUpQueueError.contextMismatch }
        return try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
            try reducer.enqueue(item)
        }.snapshot
    }

    func editQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID,
        text: String
    ) async throws -> FollowUpQueueSnapshot {
        let namespace = try followUpNamespace(conversationID: conversationID)
        return try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
            try reducer.editQueued(itemID: itemID, text: text)
        }.snapshot
    }

    func removeQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID
    ) async throws -> FollowUpQueueSnapshot {
        let namespace = try followUpNamespace(conversationID: conversationID)
        return try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
            try reducer.removeQueued(itemID: itemID)
        }.snapshot
    }

    func drainFollowUp(
        after signal: FollowUpGenerationSignal
    ) async throws -> FollowUpDrainResult {
        try rejectTemporaryDurableQueue(signal.handle.conversationID)
        let namespace = try followUpNamespace(conversationID: signal.handle.conversationID)
        return try await FollowUpQueueDrainCoordinator(
            cache: cache,
            repository: self,
            namespace: namespace
        ).drain(after: signal)
    }

    func recoverableSteerBatches(
        conversationID: ConversationID
    ) async throws -> [RecoverableSteerBatch] {
        try rejectTemporaryDurableQueue(conversationID)
        return try await cache.terminalSteerRecoveries(
            profileID: profile.id,
            accountID: activeAccountID(),
            conversationID: conversationID
        )
    }

    func acknowledgeRecoverableSteers(
        handle: GenerationHandle,
        identities: Set<RecoverableSteerIdentity>
    ) async throws -> RecoverableSteerBatch? {
        let accountID = try activeAccountID()
        guard handle.profileID == profile.id, handle.accountID == accountID else {
            throw RecoverableSteerError.contextMismatch
        }
        let remaining = try await cache.acknowledgeTerminalSteers(
            profileID: profile.id,
            accountID: accountID,
            conversationID: handle.conversationID,
            handle: handle,
            identities: identities
        )
        if var snapshot = latestSnapshots[handle] {
            snapshot.recoverableSteers = remaining?.steers ?? []
            snapshot.updatedAt = remaining?.checkpointedAt ?? Date()
            latestSnapshots[handle] = snapshot
            await generationSession.install(snapshot)
        }
        return remaining
    }

    func discardRecoverableSteer(
        _ request: RecoverableSteerDiscardRequest
    ) async throws -> RecoverableSteerDiscardOutcome {
        let clientSteerID = try await validateRecoverableSteerDiscard(request)
        let lane = steeringLane(for: request.sourceHandle)
        await lane.acquire()
        do {
            try Task.checkCancellation()
            // The recovery may have been acknowledged while this operation
            // waited for the exact-generation control lane.
            _ = try await validateRecoverableSteerDiscard(request)
            let apiRequest = try LibreChatSteeringAPI.discardRecoverable(
                conversationID: request.conversationID,
                generationCreatedAt: try steeringEpoch(for: request.sourceHandle),
                identity: request.identity
            )
            let response: HTTPResponse
            do {
                response = try await executeSteeringRequest(apiRequest)
            } catch is CancellationError {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: clientSteerID,
                    steerID: request.identity.id,
                    reason: .transport
                ))
            } catch let error as LibreChatProtocolError {
                if let outcome = Self.recoverableDiscardOutcome(
                    for: error,
                    clientSteerID: clientSteerID,
                    steerID: request.identity.id
                ) {
                    await lane.release()
                    return outcome
                }
                throw error
            }

            let outcome: RecoverableSteerDiscardOutcome
            do {
                outcome = try JSONDecoder()
                    .decode(GenerationSteerCancelResponseDTO.self, from: response.data)
                    .recoverableDiscardOutcome(
                        statusCode: response.statusCode,
                        identity: request.identity,
                        expectedProtocolVersion: Self.generationProtocolVersion
                    )
            } catch {
                await lane.release()
                return .deliveryUncertain(SteeringDeliveryUncertainty(
                    clientSteerID: clientSteerID,
                    steerID: request.identity.id,
                    reason: .invalidAcknowledgement
                ))
            }

            if case .discarded = outcome {
                do {
                    _ = try await acknowledgeRecoverableSteers(
                        handle: request.sourceHandle,
                        identities: Set([request.identity])
                    )
                } catch {
                    // The server proof is final. Preserve the exact identity
                    // in the outcome so a local acknowledgement can be
                    // repaired without repeating the cancel mutation.
                    AppLog.persistence.error(
                        "Terminal steer local acknowledgement failed after confirmed server discard."
                    )
                }
            }
            await lane.release()
            return outcome
        } catch {
            await lane.release()
            throw error
        }
    }

    func checkpointActiveGenerations() async {
        var candidateCount = 0
        var savedCount = 0
        for snapshot in latestSnapshots.values where !snapshot.state.isTerminal
            && !temporaryConversationIDs.contains(snapshot.handle.conversationID) {
            candidateCount += 1
            do {
                try await cache.save(snapshot)
                savedCount += 1
            } catch {
                AppLog.persistence.error("Generation checkpoint failed while detaching active streams.")
            }
        }
        AppLog.generation.info(
            "Generation checkpoint pass completed; candidateCount=\(candidateCount, privacy: .public), savedCount=\(savedCount, privacy: .public)."
        )
    }

    func detachActiveStreams() async {
        fileTransferEpoch &+= 1
        let activeStreamCount = activeStreamTasks.count
        await checkpointActiveGenerations()
        activeStreamTasks.values.forEach { $0.cancel() }
        activeStreamTasks.removeAll()
        AppLog.generation.info(
            "Generation streams detached; streamCount=\(activeStreamCount, privacy: .public)."
        )
    }

    func resetInMemoryState() {
        fileTransferEpoch &+= 1
        activeStreamTasks.values.forEach { $0.cancel() }
        activeStreamTasks.removeAll()
        initialResume.removeAll()
        lastCheckpoint.removeAll()
        latestSnapshots.removeAll()
        steeringControlLanes.removeAll()
        conversationSynchronizationIDs = nil
        nextConversationSynchronizationCursor = nil
        temporaryConversationIDs.removeAll()
        promptMutationID = nil
        presetMutationID = nil
        basicAgentCreationID = nil
        agentMutationIDs.removeAll()
        skillActivationMutationID = nil
    }

    func draft(conversationID: ConversationID) async -> String {
        guard !temporaryConversationIDs.contains(conversationID) else { return "" }
        guard let accountID else { return "" }
        return (try? await cache.draft(profileID: profile.id, accountID: accountID, conversationID: conversationID)) ?? ""
    }

    func saveDraft(_ text: String, conversationID: ConversationID) async {
        guard !temporaryConversationIDs.contains(conversationID) else { return }
        guard let accountID else { return }
        try? await cache.saveDraft(text, profileID: profile.id, accountID: accountID, conversationID: conversationID)
    }

    private func streamRequest(handle: GenerationHandle, resume: Bool) async throws -> URLRequest {
        guard handle.profileID == profile.id,
              handle.accountID == (try activeAccountID()) else {
            throw LibreChatProtocolError.unsupported(
                "This generation belongs to another server profile or account."
            )
        }
        var query = [URLQueryItem(name: "generationProtocolVersion", value: String(handle.protocolVersion))]
        if let created = handle.generationCreatedAt {
            query.insert(URLQueryItem(name: "generationCreatedAt", value: String(created)), at: 0)
        }
        if resume { query.append(URLQueryItem(name: "resume", value: "true")) }
        var request = try await runtime.transport.request(
            method: .get,
            path: "api/agents/chat/stream/\(handle.streamID)",
            queryItems: query,
            headers: [
                "Accept": "text/event-stream",
                Self.generationProtocolHeader: String(handle.protocolVersion)
            ]
        )
        do {
            request.setValue(try await runtime.authSession.authorizationValue(), forHTTPHeaderField: "Authorization")
        } catch {
            _ = try await runtime.authSession.refresh()
            request.setValue(try await runtime.authSession.authorizationValue(), forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func generationStatus(for handle: GenerationHandle) async throws -> GenerationStatusDTO {
        try await generationStatus(
            conversationID: handle.conversationID,
            protocolVersion: handle.protocolVersion
        )
    }

    /// Returns an admission proof only when the retained v2 status snapshot
    /// names the exact queued user row and frozen text/parent coordinates.
    /// Jobless status and merely same-conversation activity are deliberately
    /// insufficient: another client may own a newer generation epoch.
    func followUpAdmissionProof(
        for attempt: FollowUpAdmissionAttempt
    ) async throws -> FollowUpAdmissionProof? {
        let fingerprint = attempt.fingerprint
        let namespace = fingerprint.namespace
        guard namespace.profileID == profile.id,
              namespace.accountID == (try activeAccountID()),
              fingerprint.sourceAnchor.handle.protocolVersion == Self.generationProtocolVersion,
              let predecessorEpoch = fingerprint.sourceAnchor.handle.generationCreatedAt else {
            throw LibreChatProtocolError.unsupported(
                "This queued admission belongs to another server profile, account, or protocol."
            )
        }
        let status = try await generationStatus(
            conversationID: namespace.conversationID,
            protocolVersion: Self.generationProtocolVersion
        )
        guard status.generationProtocolVersion == Self.generationProtocolVersion,
              let streamID = status.streamID,
              streamID == namespace.conversationID.rawValue,
              let createdAt = status.createdAt,
              createdAt >= 0,
              createdAt > predecessorEpoch,
              let resume = status.resumeState?.objectValue,
              let user = resume["userMessage"]?.objectValue,
              user["messageId"]?.stringValue == attempt.clientMessageID.rawValue,
              user["conversationId"]?.stringValue == namespace.conversationID.rawValue,
              user["parentMessageId"]?.stringValue == fingerprint.parentMessageID.rawValue,
              user["text"]?.stringValue == fingerprint.text,
              Self.hasExactFollowUpFiles(
                  user["files"],
                  expectedIDs: fingerprint.attachments.map { $0.file.id }
              ),
              Self.isAbsentOrEmptyArray(user["quotes"]),
              Self.isAbsentOrEmptyArray(user["manualSkills"]),
              Self.isAbsentOrEmptyArray(user["alwaysAppliedSkills"]),
              let rawResponseMessageID = resume["responseMessageId"]?.stringValue,
              !rawResponseMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let responseMessageID = MessageID(rawValue: rawResponseMessageID)
        guard Self.isPersistedFollowUpMessageID(responseMessageID),
              responseMessageID != attempt.clientMessageID,
              responseMessageID != fingerprint.parentMessageID else {
            return nil
        }
        let handle = GenerationHandle(
            profileID: namespace.profileID,
            accountID: namespace.accountID,
            clientRequestID: attempt.clientRequestID,
            streamID: streamID,
            conversationID: namespace.conversationID,
            generationCreatedAt: createdAt,
            protocolVersion: Self.generationProtocolVersion
        )

        if status.active {
            guard status.status == "running" || status.status == "requires_action" else {
                return nil
            }
            // Install the exact caller-owned handle before app-wide active-job
            // discovery runs. Otherwise `/active` can recover the same epoch
            // under a synthetic client request ID and the visible chat cannot
            // prove ownership of the original queued admission.
            _ = try await reconcile(handle, with: status)
            return .active(handle)
        }
        switch status.status {
        case "complete":
            return .terminal(
                handle: handle,
                terminal: .completed(responseMessageID: responseMessageID)
            )
        case "aborted":
            return .terminal(handle: handle, terminal: .aborted)
        case "error":
            return .terminal(handle: handle, terminal: .failed)
        default:
            return nil
        }
    }

    private func generationStatus(
        conversationID: ConversationID,
        protocolVersion: Int
    ) async throws -> GenerationStatusDTO {
        let request = APIRequest<GenerationStatusDTO>(
            path: "api/agents/chat/status/\(conversationID.rawValue)",
            queryItems: [URLQueryItem(name: "generationProtocolVersion", value: String(protocolVersion))],
            headers: [Self.generationProtocolHeader: String(protocolVersion)],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        return try await runtime.restClient.send(request)
    }

    private static func isAbsentOrEmptyArray(_ value: JSONValue?) -> Bool {
        guard let value else { return true }
        return value.arrayValue?.isEmpty == true
    }

    private static func hasExactFollowUpFiles(
        _ value: JSONValue?,
        expectedIDs: [String]
    ) -> Bool {
        guard Set(expectedIDs).count == expectedIDs.count else { return false }
        guard let value else { return expectedIDs.isEmpty }
        guard let files = value.arrayValue else { return false }
        let observedIDs = files.compactMap { file -> String? in
            guard let object = file.objectValue,
                  let id = object["file_id"]?.stringValue,
                  !id.isEmpty else { return nil }
            return id
        }
        return observedIDs.count == files.count
            && Set(observedIDs).count == observedIDs.count
            && Set(observedIDs) == Set(expectedIDs)
    }

    private static func isPersistedFollowUpMessageID(_ id: MessageID) -> Bool {
        let value = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != "new",
              !value.hasPrefix("local-"),
              value != "NO_PARENT",
              value != "00000000-0000-0000-0000-000000000000" else {
            return false
        }
        return !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    /// Returns only a generation that an authoritative v2 status query proves
    /// is the active winner for this exact start receipt. The returned handle
    /// is never the losing request's client ID, so it cannot be mistaken for
    /// a successful original send.
    private func provenWinnerHandoff(
        receipt: GenerationStartResponseDTO,
        requestedConversationID: ConversationID,
        expectedPredecessorCreatedAt: Int64?
    ) async throws -> GenerationHandle? {
        guard let receiptStreamID = receipt.streamID,
              !receiptStreamID.isEmpty,
              let receiptConversationID = receipt.conversationID,
              receiptConversationID == requestedConversationID.rawValue,
              let receiptCreatedAt = receipt.generationCreatedAt,
              receiptCreatedAt >= 0,
              receipt.generationProtocolVersion == Self.generationProtocolVersion else {
            return nil
        }
        do {
            let status = try await generationStatus(
                conversationID: requestedConversationID,
                protocolVersion: Self.generationProtocolVersion
            )
            guard status.active,
                  status.status == "running" || status.status == "requires_action",
                  status.generationProtocolVersion == Self.generationProtocolVersion,
                  status.streamID == receiptStreamID,
                  receiptStreamID == requestedConversationID.rawValue,
                  status.createdAt == receiptCreatedAt else {
                return nil
            }
            if receipt.status == "predecessor_mismatch" {
                guard let expectedPredecessorCreatedAt,
                      receiptCreatedAt != expectedPredecessorCreatedAt else {
                    return nil
                }
            }

            let accountID = try activeAccountID()
            let coordinatesMatch: (GenerationHandle) -> Bool = { handle in
                handle.profileID == self.profile.id
                    && handle.accountID == accountID
                    && handle.conversationID == requestedConversationID
                    && handle.streamID == receiptStreamID
                    && handle.generationCreatedAt == receiptCreatedAt
                    && handle.protocolVersion == Self.generationProtocolVersion
            }
            let handle: GenerationHandle
            if let existing = latestSnapshots.keys.first(where: coordinatesMatch) {
                handle = existing
            } else if let saved = try await cache.recoverableGenerations(
                profileID: profile.id,
                accountID: accountID
            ).first(where: { coordinatesMatch($0.handle) }) {
                handle = saved.handle
                await generationSession.install(saved)
                latestSnapshots[handle] = saved
            } else {
                handle = GenerationHandle(
                    profileID: profile.id,
                    accountID: accountID,
                    clientRequestID: UUID(),
                    streamID: receiptStreamID,
                    conversationID: requestedConversationID,
                    generationCreatedAt: receiptCreatedAt,
                    protocolVersion: Self.generationProtocolVersion
                )
                let snapshot = GenerationSnapshot(handle: handle)
                try await persist(snapshot)
                await generationSession.install(snapshot)
                latestSnapshots[handle] = snapshot
            }
            initialResume[handle] = true
            return handle
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            return nil
        }
    }

    private func startGeneration(
        _ request: APIRequest<GenerationStartResponseDTO>,
        conversationID: ConversationID,
        messageID: MessageID,
        allowsActiveDeterministicRecovery: Bool,
        allowsSettledHistoryRecovery: Bool
    ) async throws -> GenerationStartResponseDTO {
        var lastAmbiguousError: LibreChatProtocolError?
        let clock = ContinuousClock()
        let readinessDeadline = clock.now.advanced(by: .seconds(120))
        var requestAttempts = 0
        var networkAttempts = 0

        startAttempts: while true {
            requestAttempts += 1
            do {
                return try await runtime.restClient.send(request)
            } catch let error as LibreChatProtocolError {
                if case let .generationConflict(details) = error {
                    return GenerationStartResponseDTO(
                        streamID: details.streamID,
                        conversationID: details.conversationID ?? conversationID.rawValue,
                        generationCreatedAt: details.generationCreatedAt,
                        generationProtocolVersion: details.generationProtocolVersion
                            ?? Self.generationProtocolVersion,
                        status: details.status ?? "predecessor_mismatch",
                        code: details.code,
                        predecessorVerified: details.predecessorVerified,
                        active: details.active
                    )
                }
                let fallbackDelay = min(pow(2.0, Double(requestAttempts - 1)), 8)
                let delay: Duration
                switch error {
                case .transport:
                    networkAttempts += 1
                    guard networkAttempts < 3 else { break startAttempts }
                    AppLog.generation.notice(
                        "Generation start response was ambiguous after transport failure; retrying the same idempotency key, networkAttempt=\(networkAttempts, privacy: .public)."
                    )
                    delay = .milliseconds(Int(fallbackDelay * 1_000))
                case let .serverNotReady(retryAfter):
                    let remaining = clock.now.duration(to: readinessDeadline)
                    guard remaining > .zero else { break startAttempts }
                    AppLog.generation.notice(
                        "Generation server is not ready; retrying the same idempotency key, requestAttempt=\(requestAttempts, privacy: .public)."
                    )
                    let requestedSeconds = if let retryAfter, retryAfter.isFinite {
                        min(max(0, retryAfter), 120)
                    } else {
                        fallbackDelay
                    }
                    let requested = Duration.milliseconds(
                        Int(requestedSeconds * 1_000)
                    )
                    delay = min(requested, remaining)
                default:
                    throw error
                }
                lastAmbiguousError = error
                try await generationStartSleep(delay)
            }
        }
        if let recovered = try await recoverAmbiguousStart(
            conversationID: conversationID,
            messageID: messageID,
            allowsActiveDeterministicRecovery: allowsActiveDeterministicRecovery,
            allowsSettledHistoryRecovery: allowsSettledHistoryRecovery
        ) {
            AppLog.generation.notice("Generation start ambiguity resolved through authoritative status/history reconciliation.")
            return recovered
        }
        AppLog.generation.error("Generation start ambiguity could not be resolved within the bounded retry policy.")
        throw lastAmbiguousError ?? LibreChatProtocolError.invalidResponse
    }

    private func recoverAmbiguousStart(
        conversationID: ConversationID,
        messageID: MessageID,
        allowsActiveDeterministicRecovery: Bool,
        allowsSettledHistoryRecovery: Bool
    ) async throws -> GenerationStartResponseDTO? {
        do {
            let status = try await generationStatus(
                conversationID: conversationID,
                protocolVersion: Self.generationProtocolVersion
            )
            if status.active {
                guard allowsActiveDeterministicRecovery,
                      (status.status == "running" || status.status == "requires_action"),
                      let streamID = status.streamID,
                      streamID == conversationID.rawValue,
                      let createdAt = status.createdAt,
                      createdAt >= 0,
                      status.generationProtocolVersion == Self.generationProtocolVersion else {
                    return nil
                }
                return GenerationStartResponseDTO(
                    streamID: streamID,
                    conversationID: conversationID.rawValue,
                    generationCreatedAt: createdAt,
                    generationProtocolVersion: Self.generationProtocolVersion,
                    status: "resumed"
                )
            }
            if status.status == "aborted" || status.status == "error" {
                return GenerationStartResponseDTO(
                    streamID: nil,
                    conversationID: conversationID.rawValue,
                    generationCreatedAt: status.createdAt,
                    generationProtocolVersion: Self.generationProtocolVersion,
                    status: status.status
                )
            }
            guard status.status == "complete" || status.status == "settled" else {
                return nil
            }
            guard allowsSettledHistoryRecovery else { return nil }
            if try await messages(conversationID: conversationID).contains(where: { $0.id == messageID }) {
                return GenerationStartResponseDTO(
                    streamID: nil,
                    conversationID: conversationID.rawValue,
                    generationCreatedAt: nil,
                    generationProtocolVersion: Self.generationProtocolVersion,
                    status: "settled"
                )
            }
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            // Recovery is best-effort: an unreachable status probe only means
            // the fast path is unavailable, so the failure is logged and the
            // caller falls back to the slower reconciliation path.
            AppLog.generation.debug("Settled-history recovery probe failed; falling back. \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    private func checkpoint(_ snapshot: GenerationSnapshot, force: Bool) async {
        let prior = lastCheckpoint[snapshot.handle] ?? .distantPast
        guard force || snapshot.updatedAt.timeIntervalSince(prior) >= 2 else { return }
        do {
            try await persist(snapshot)
            if snapshot.state.isTerminal {
                lastCheckpoint[snapshot.handle] = nil
            } else {
                lastCheckpoint[snapshot.handle] = snapshot.updatedAt
            }
        } catch {
            AppLog.persistence.error("Generation checkpoint failed.")
        }
    }

    private func persist(_ snapshot: GenerationSnapshot) async throws {
        guard !temporaryConversationIDs.contains(snapshot.handle.conversationID) else {
            lastCheckpoint[snapshot.handle] = nil
            return
        }
        if snapshot.state.isTerminal {
            if snapshot.recoverableSteers.isEmpty {
                try await cache.remove(handle: snapshot.handle)
            } else {
                try await cache.save(snapshot)
            }
            lastCheckpoint[snapshot.handle] = nil
        } else {
            try await cache.save(snapshot)
        }
    }

    private func record(_ snapshot: GenerationSnapshot) {
        latestSnapshots[snapshot.handle] = snapshot
        if snapshot.state.isTerminal { activeStreamTasks[snapshot.handle] = nil }
    }

    private func register(task: Task<Void, Never>, for handle: GenerationHandle) {
        activeStreamTasks[handle]?.cancel()
        activeStreamTasks[handle] = task
    }

    private static func requiresImmediateCheckpoint(_ state: GenerationState) -> Bool {
        switch state {
        case .awaitingApproval, .stopping, .reconciling, .superseded, .completed, .aborted, .failed: true
        default: false
        }
    }

    private static func isClientLocalMessageID(_ messageID: MessageID) -> Bool {
        messageID.rawValue.hasPrefix("local-")
    }

    private func registerTemporaryConversation(_ conversationID: ConversationID) async {
        guard temporaryConversationIDs.insert(conversationID).inserted,
              let accountID else { return }
        do {
            try await cache.purgeTemporaryConversationContent(
                profileID: profile.id,
                accountID: accountID,
                conversationID: conversationID
            )
        } catch {
            AppLog.persistence.error("Temporary Chat local cache purge failed.")
        }
    }

    private func rejectTemporaryDurableQueue(_ conversationID: ConversationID) throws {
        guard !temporaryConversationIDs.contains(conversationID) else {
            throw LibreChatProtocolError.unsupported(
                "Temporary Chat follow-ups stay in the live composer and are not written to the durable queue."
            )
        }
    }

    /// Generation creates a persisted user message, so a caller-provided
    /// coordinate must remain safe across JSON, cache, and URL/path handling.
    /// LibreChat normally uses UUIDs, while compatible deployments and test
    /// fixtures also use opaque URL-safe identifiers; accept that common
    /// persisted subset rather than silently rewriting the caller's retry ID.
    private static func isSafeGenerationMessageID(_ messageID: MessageID) -> Bool {
        let value = messageID.rawValue
        guard (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45, 46, 95, 126:
                      true // ASCII alphanumeric, '-', '.', '_', '~'
                  default:
                      false
                  }
              }) else {
            return false
        }
        switch value.uppercased() {
        case "NEW", "NO_PARENT", "00000000-0000-0000-0000-000000000000":
            return false
        default:
            return !value.lowercased().hasPrefix("local-")
        }
    }

    private static func isValidRecoverySteerIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 58, 95:
                true // ASCII alphanumeric, '-', ':', '_'
            default:
                false
            }
        }
    }

    private static func preliminaryResponseMessageID(for target: MessageID) -> String {
        let normalized = String(target.rawValue.reversed().drop(while: { $0 == "_" }).reversed())
        return normalized + "_"
    }

    private static func containsReservedPromptMarkup(_ text: String, messageID: MessageID) -> Bool {
        let artifactDocument = ArtifactParser.parse(messageID: messageID, text: text)
        guard artifactDocument.nextDocumentOrderIndex == 0 else { return true }

        let citationResolution = CitationMarkerResolver.resolve(
            text,
            sources: CitationSourceCatalog()
        )
        return citationResolution.cleanedText != text
            || citationResolution.discardedAnchorCount > 0
            || !citationResolution.citations.isEmpty
            || !citationResolution.highlights.isEmpty
    }

    private static func isRootParentSentinel(_ messageID: MessageID) -> Bool {
        switch messageID.rawValue.uppercased() {
        case "00000000-0000-0000-0000-000000000000", "NO_PARENT": return true
        default: return false
        }
    }

    private static func isFatalStreamError(_ error: LibreChatProtocolError) -> Bool {
        switch error {
        case .invalidResponse, .unauthorized, .generationConflict, .decoding,
             .encoding, .unsupported, .keychain:
            true
        case let .httpStatus(status, _, _):
            (400..<500).contains(status) && status != 429
        case .serverNotReady, .transport:
            false
        }
    }

    private static func logLabel(for state: GenerationState) -> String {
        switch state {
        case .completed: "completed"
        case .aborted: "aborted"
        case .failed: "failed"
        case .superseded: "superseded"
        case .starting: "starting"
        case .streaming: "streaming"
        case .awaitingApproval: "awaitingApproval"
        case .reconnecting: "reconnecting"
        case .reconciling: "reconciling"
        case .stopping: "stopping"
        }
    }

    private func steeringLane(for handle: GenerationHandle) -> SteeringControlLane {
        if let lane = steeringControlLanes[handle] { return lane }
        let lane = SteeringControlLane()
        steeringControlLanes[handle] = lane
        return lane
    }

    private func validateSteerSubmission(_ request: GenerationSteerRequest) throws -> String {
        _ = try activeSteeringSnapshot(
            profileID: request.profileID,
            accountID: request.accountID,
            conversationID: request.conversationID,
            handle: request.handle
        )
        guard Self.isValidSteeringIdentifier(request.clientSteerID) else {
            throw GenerationSteeringError.invalidClientSteerID
        }
        let normalized = request.text
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GenerationSteeringError.emptyText }
        guard normalized.utf16.count <= 16_000 else {
            throw GenerationSteeringError.textTooLong(maximumUTF16Length: 16_000)
        }
        return normalized
    }

    private func validateSteerControl(_ request: GenerationSteerControlRequest) throws {
        _ = try activeSteeringSnapshot(
            profileID: request.profileID,
            accountID: request.accountID,
            conversationID: request.conversationID,
            handle: request.handle
        )
        guard Self.isValidSteeringIdentifier(request.clientSteerID) else {
            throw GenerationSteeringError.invalidClientSteerID
        }
        guard Self.isValidSteeringIdentifier(request.steerID) else {
            throw GenerationSteeringError.invalidSteerID
        }
    }

    private func validateRecoverableSteerDiscard(
        _ request: RecoverableSteerDiscardRequest
    ) async throws -> String {
        guard let currentAccountID = accountID else {
            throw LibreChatProtocolError.unauthorized
        }
        let handle = request.sourceHandle
        guard request.profileID == profile.id,
              request.accountID == currentAccountID,
              handle.profileID == request.profileID,
              handle.accountID == request.accountID,
              handle.conversationID == request.conversationID else {
            throw RecoverableSteerDiscardError.contextMismatch
        }
        let rawConversationID = request.conversationID.rawValue
        guard !request.conversationID.isLocalDraft,
              !rawConversationID.isEmpty,
              rawConversationID == rawConversationID.trimmingCharacters(in: .whitespacesAndNewlines),
              handle.streamID == rawConversationID else {
            throw RecoverableSteerDiscardError.invalidConversation
        }
        guard handle.generationCreatedAt.map({ $0 >= 0 }) == true else {
            throw RecoverableSteerDiscardError.invalidGenerationEpoch
        }
        guard handle.protocolVersion == Self.generationProtocolVersion,
              let capabilities = profile.capabilities,
              case let .resumable(version) = capabilities.generation,
              version == Self.generationProtocolVersion else {
            throw RecoverableSteerDiscardError.protocolMismatch
        }
        guard Self.isValidRecoverableServerSteerID(request.identity.id) else {
            throw RecoverableSteerDiscardError.invalidSteerID
        }
        guard let clientSteerID = request.identity.clientSteerID,
              Self.isValidSteeringIdentifier(clientSteerID) else {
            throw RecoverableSteerDiscardError.invalidClientSteerID
        }
        let batches = try await cache.terminalSteerRecoveries(
            profileID: request.profileID,
            accountID: request.accountID,
            conversationID: request.conversationID
        )
        guard let exactBatch = batches.first(where: { $0.handle == handle }),
              exactBatch.steers.contains(where: { $0.recoveryIdentity == request.identity }) else {
            throw RecoverableSteerDiscardError.sourceNotRecoverable
        }
        return clientSteerID
    }

    private func activeSteeringSnapshot(
        profileID: ServerProfileID,
        accountID requestedAccountID: AccountID,
        conversationID: ConversationID,
        handle: GenerationHandle
    ) throws -> GenerationSnapshot {
        guard let currentAccountID = accountID else {
            throw LibreChatProtocolError.unauthorized
        }
        guard profileID == profile.id,
              requestedAccountID == currentAccountID,
              handle.profileID == profileID,
              handle.accountID == requestedAccountID,
              handle.conversationID == conversationID else {
            throw GenerationSteeringError.contextMismatch
        }
        let rawConversationID = conversationID.rawValue
        guard !conversationID.isLocalDraft,
              !rawConversationID.isEmpty,
              rawConversationID == rawConversationID.trimmingCharacters(in: .whitespacesAndNewlines),
              handle.streamID == rawConversationID else {
            throw GenerationSteeringError.invalidConversation
        }
        _ = try steeringEpoch(for: handle)
        guard handle.protocolVersion == Self.generationProtocolVersion else {
            throw GenerationSteeringError.protocolMismatch
        }
        guard let capabilities = profile.capabilities,
              case let .resumable(version) = capabilities.generation,
              version == Self.generationProtocolVersion else {
            throw GenerationSteeringError.protocolMismatch
        }
        guard let snapshot = latestSnapshots[handle],
              !snapshot.state.isTerminal else {
            throw GenerationSteeringError.inactiveGeneration
        }
        if case .stopping = snapshot.state {
            throw GenerationSteeringError.inactiveGeneration
        }
        return snapshot
    }

    private func steeringEpoch(for handle: GenerationHandle) throws -> Int64 {
        guard let epoch = handle.generationCreatedAt, epoch >= 0 else {
            throw GenerationSteeringError.invalidGenerationEpoch
        }
        return epoch
    }

    private static func isValidSteeringIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: true
            default: false
            }
        }
    }

    private static func isValidRecoverableServerSteerID(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 58, 95: true
            default: false
            }
        }
    }

    private func executeSteeringRequest<Response: Decodable & Sendable>(
        _ request: APIRequest<Response>
    ) async throws -> HTTPResponse {
        try await runtime.restClient.rawResponse(
            method: request.method,
            path: request.path,
            pathComponents: request.pathComponents,
            queryItems: request.queryItems,
            headers: request.headers,
            body: request.body,
            authorized: request.authorization == .bearer,
            retryPolicy: request.retryPolicy
        )
    }

    private static func steeringUncertainty(
        for error: LibreChatProtocolError,
        clientSteerID: String,
        steerID: String? = nil
    ) -> SteeringDeliveryUncertainty? {
        let reason: SteeringDeliveryUncertainty.Reason
        switch error {
        case .transport, .invalidResponse:
            reason = .transport
        case let .httpStatus(status, _, _) where (500..<600).contains(status):
            reason = .server(status: status, code: nil)
        case .serverNotReady:
            reason = .server(status: 503, code: "SERVER_NOT_READY")
        default:
            return nil
        }
        return SteeringDeliveryUncertainty(
            clientSteerID: clientSteerID,
            steerID: steerID,
            reason: reason
        )
    }

    private static func recoverableDiscardOutcome(
        for error: LibreChatProtocolError,
        clientSteerID: String,
        steerID: String
    ) -> RecoverableSteerDiscardOutcome? {
        switch error {
        case .unauthorized:
            return .unauthorized
        case let .generationConflict(details):
            return .conflict(code: boundedSteeringCode(details.code))
        case let .httpStatus(status, _, _) where status == 409:
            return .conflict(code: nil)
        default:
            guard let uncertainty = steeringUncertainty(
                for: error,
                clientSteerID: clientSteerID,
                steerID: steerID
            ) else { return nil }
            return .deliveryUncertain(uncertainty)
        }
    }

    private static func boundedSteeringCode(_ value: String?) -> String? {
        guard let value,
              (1...128).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 95: true
                  default: false
                  }
              }) else { return nil }
        return value
    }

    private func beginPromptMutation() throws -> UUID {
        guard promptMutationID == nil else {
            throw PromptManagementError.unavailable
        }
        let operationID = UUID()
        promptMutationID = operationID
        return operationID
    }

    private func finishPromptMutation(_ operationID: UUID) {
        guard promptMutationID == operationID else { return }
        promptMutationID = nil
    }

    private static func promptMutationIsUncertain(_ error: LibreChatProtocolError) -> Bool {
        switch error {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            true
        case let .httpStatus(status, _, _) where status >= 500:
            true
        default:
            false
        }
    }

    private func beginPresetMutation() throws -> UUID {
        guard presetMutationID == nil else {
            throw LibreChatProtocolError.unsupported("A preset is already being saved.")
        }
        let operationID = UUID()
        presetMutationID = operationID
        return operationID
    }

    private func finishPresetMutation(_ operationID: UUID) {
        guard presetMutationID == operationID else { return }
        presetMutationID = nil
    }

    private func reconcilePresetCreation(
        _ request: PresetCreationRequest,
        profileID requestedProfileID: ServerProfileID,
        accountID requestedAccountID: AccountID
    ) async throws -> PresetCreationOutcome {
        do {
            let dtos = try await runtime.restClient.send(LibreChatPresetsAPI.list())
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                return .outcomeUnknown(.reconciliationUnavailable)
            }
            let matches = dtos.filter { dto in
                (try? dto.domainModel().id) == request.presetID
            }
            guard matches.count == 1, let match = matches.first else {
                return .outcomeUnknown(.responseLostAfterDispatch)
            }

            // The owner row proves only that the non-idempotent create was
            // committed. Its model or agent may have been revoked after the
            // preflight and before this reconciliation read, so confirmation
            // must use new authenticated routing evidence rather than the
            // catalog captured before dispatch.
            let catalog = try await targetCatalog(recentOptionID: nil)
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID,
                  catalog.profileID == requestedProfileID,
                  catalog.accountID == requestedAccountID else {
                return .outcomeUnknown(.reconciliationUnavailable)
            }
            do {
                return try LibreChatPresetsAPI.confirmedCreation(
                    from: match,
                    for: request,
                    validatingAgainst: catalog
                )
            } catch {
                return .outcomeUnknown(.responseLostAfterDispatch)
            }
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            return .outcomeUnknown(.reconciliationUnavailable)
        }
    }

    private static func presetMutationIsUncertain(
        _ error: LibreChatProtocolError
    ) -> Bool {
        switch error {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            true
        case let .httpStatus(status, _, _) where status >= 500:
            true
        default:
            false
        }
    }

    private func beginBasicAgentCreation() throws -> UUID {
        guard basicAgentCreationID == nil else {
            throw LibreChatProtocolError.unsupported("An agent is already being created.")
        }
        let operationID = UUID()
        basicAgentCreationID = operationID
        return operationID
    }

    private func finishBasicAgentCreation(_ operationID: UUID) {
        guard basicAgentCreationID == operationID else { return }
        basicAgentCreationID = nil
    }

    private func reconcileBasicAgentCreation(
        _ request: BasicAgentCreationRequest,
        profileID requestedProfileID: ServerProfileID,
        accountID requestedAccountID: AccountID
    ) async throws -> BasicAgentCreationOutcome {
        do {
            // LibreChat does not accept a caller-owned idempotency key for
            // agent creation. This bounded owner-directory read can reveal
            // the possible result to the next refresh, but even one exact new
            // row cannot be cryptographically attributed to this POST when
            // another client may create concurrently. Keep the outcome
            // unknown instead of inventing confirmation or reposting.
            _ = try await runtime.restClient.send(
                LibreChatAgentsAPI.list(search: request.name, limit: 100)
            )
            guard profile.id == requestedProfileID,
                  accountID == requestedAccountID else {
                return .outcomeUnknown(.reconciliationUnavailable)
            }
            return .outcomeUnknown(.responseLostAfterDispatch)
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch {
            return .outcomeUnknown(.reconciliationUnavailable)
        }
    }

    private static func basicAgentCreationIsUncertain(
        _ error: LibreChatProtocolError
    ) -> Bool {
        switch error {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            true
        case let .httpStatus(status, _, _) where status >= 500:
            true
        default:
            false
        }
    }

    private func beginAgentMutation(id: AgentID) throws -> UUID {
        guard agentMutationIDs[id] == nil else {
            throw AgentManagementError.unavailable
        }
        let operationID = UUID()
        agentMutationIDs[id] = operationID
        return operationID
    }

    private func finishAgentMutation(id: AgentID, operationID: UUID) {
        guard agentMutationIDs[id] == operationID else { return }
        agentMutationIDs[id] = nil
    }

    private func reconcileAgentMetadata(
        id: AgentID,
        expected: LibreChatAgentMetadataUpdateDTO,
        profileID: ServerProfileID,
        accountID expectedAccountID: AccountID
    ) async throws -> ManagedAgentMetadata {
        do {
            let response = try await runtime.restClient.send(
                LibreChatAgentsAPI.expanded(id: id)
            ).managedDomainModel()
            guard profile.id == profileID,
                  accountID == expectedAccountID,
                  Self.matches(response, expected: expected, id: id) else {
                throw AgentManagementError.outcomeUnknown
            }
            return response
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as AgentManagementError {
            throw error
        } catch {
            throw AgentManagementError.outcomeUnknown
        }
    }

    private func reconcileAgentDeletion(
        id: AgentID,
        profileID: ServerProfileID,
        accountID expectedAccountID: AccountID
    ) async throws {
        do {
            let response = try await runtime.restClient.send(
                LibreChatAgentsAPI.detail(id: id)
            ).domainModel()
            guard profile.id == profileID,
                  accountID == expectedAccountID else {
                throw AgentManagementError.outcomeUnknown
            }
            guard response.id == id else {
                throw AgentManagementError.outcomeUnknown
            }
            throw AgentManagementError.deletionNotApplied
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let error as LibreChatProtocolError {
            if case let .httpStatus(status, _, _) = error, status == 404 {
                guard profile.id == profileID,
                      accountID == expectedAccountID else {
                    throw AgentManagementError.outcomeUnknown
                }
                return
            }
            throw AgentManagementError.outcomeUnknown
        } catch let error as AgentManagementError {
            throw error
        } catch {
            throw AgentManagementError.outcomeUnknown
        }
    }

    private static func agentMutationIsUncertain(_ error: LibreChatProtocolError) -> Bool {
        switch error {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            true
        case let .httpStatus(status, _, _) where status >= 500:
            true
        default:
            false
        }
    }

    private static func matches(
        _ metadata: ManagedAgentMetadata,
        expected: LibreChatAgentMetadataUpdateDTO,
        id: AgentID
    ) -> Bool {
        metadata.id == id
            && metadata.name == expected.name
            && (metadata.description ?? "") == expected.description
            && (metadata.category ?? "") == expected.category
    }

    private static func matches(
        _ group: ManagedPromptGroup,
        input: UpdatePromptGroupInput
    ) -> Bool {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = input.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = input.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = input.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        return group.id == input.groupID
            && group.name == name
            && group.summary == summary
            && group.category == category
            && group.command == (command?.isEmpty == false ? command : nil)
    }

    private func installAcceptedSteer(
        _ receipt: GenerationSteerReceipt,
        normalizedText: String,
        handle: GenerationHandle
    ) async {
        guard var snapshot = latestSnapshots[handle],
              !snapshot.state.isTerminal else { return }
        if case .stopping = snapshot.state { return }

        let receiptIDs = Set([receipt.steerID, receipt.clientSteerID])
        let wasApplied = snapshot.appliedSteers.contains { applied in
            !receiptIDs.isDisjoint(with: Set([applied.id, applied.clientSteerID].compactMap { $0 }))
        }
        let isRecoverable = snapshot.recoverableSteers.contains { pending in
            !receiptIDs.isDisjoint(with: Set([pending.id, pending.clientSteerID].compactMap { $0 }))
        }
        guard !wasApplied, !isRecoverable else { return }

        let incoming = PendingSteer(
            id: receipt.steerID,
            clientSteerID: receipt.clientSteerID,
            text: normalizedText,
            files: [],
            preempt: receipt.preempt,
            preemptRevision: receipt.preemptRevision
        )
        if let index = snapshot.pendingSteers.firstIndex(where: { pending in
            pending.id == receipt.steerID || pending.clientSteerID == receipt.clientSteerID
        }) {
            let existing = snapshot.pendingSteers[index]
            // A partial identity may be promoted, but conflicting proof never
            // overwrites a different queued item.
            guard (existing.id == receipt.steerID || existing.clientSteerID == receipt.clientSteerID),
                  existing.clientSteerID.map({ $0 == receipt.clientSteerID }) ?? true else {
                return
            }
            if let existingRevision = existing.preemptRevision,
               receipt.preemptRevision.map({ $0 < existingRevision }) ?? true {
                var preserved = incoming
                preserved.preempt = existing.preempt
                preserved.preemptRevision = existingRevision
                snapshot.pendingSteers[index] = preserved
            } else {
                snapshot.pendingSteers[index] = incoming
            }
        } else {
            snapshot.pendingSteers.append(incoming)
        }
        await installSteeringSnapshot(snapshot)
    }

    private func removeAcceptedCancelledSteer(_ request: GenerationSteerControlRequest) async {
        guard var snapshot = latestSnapshots[request.handle],
              !snapshot.state.isTerminal else { return }
        snapshot.pendingSteers.removeAll { pending in
            pending.id == request.steerID
                && (pending.clientSteerID == nil || pending.clientSteerID == request.clientSteerID)
        }
        await installSteeringSnapshot(snapshot)
    }

    private func installReceiptLeftover(
        _ receipt: GenerationSteerReceipt,
        normalizedText: String,
        handle: GenerationHandle
    ) async {
        guard var snapshot = latestSnapshots[handle] else { return }
        let receiptIDs = Set([receipt.steerID, receipt.clientSteerID])
        let wasApplied = snapshot.appliedSteers.contains { applied in
            !receiptIDs.isDisjoint(with: Set([applied.id, applied.clientSteerID].compactMap { $0 }))
        }
        snapshot.pendingSteers.removeAll { pending in
            !receiptIDs.isDisjoint(with: Set([pending.id, pending.clientSteerID].compactMap { $0 }))
        }
        if !wasApplied,
           !snapshot.recoverableSteers.contains(where: { pending in
               !receiptIDs.isDisjoint(with: Set([pending.id, pending.clientSteerID].compactMap { $0 }))
           }) {
            snapshot.recoverableSteers.append(PendingSteer(
                id: receipt.steerID,
                clientSteerID: receipt.clientSteerID,
                text: normalizedText,
                files: [],
                preempt: receipt.preempt,
                preemptRevision: receipt.preemptRevision
            ))
        }
        // The replay receipt proves this exact epoch is settled but does not
        // disclose whether its terminal cause was completion, abort, or
        // failure. `superseded` is the fail-closed terminal state: it prevents
        // active recovery without inventing a clean-completion outcome.
        if !snapshot.state.isTerminal { snapshot.state = .superseded }
        snapshot.pendingInteraction = nil
        activeStreamTasks[handle]?.cancel()
        activeStreamTasks[handle] = nil
        await installSteeringSnapshot(snapshot)
    }

    private func installAcceptedArm(
        _ request: GenerationSteerControlRequest,
        preemptRevision: Int
    ) async {
        guard var snapshot = latestSnapshots[request.handle],
              !snapshot.state.isTerminal,
              let index = snapshot.pendingSteers.firstIndex(where: { pending in
                  pending.id == request.steerID
                      && (pending.clientSteerID == nil || pending.clientSteerID == request.clientSteerID)
              }) else { return }
        let currentRevision = snapshot.pendingSteers[index].preemptRevision ?? -1
        guard preemptRevision >= currentRevision else { return }
        snapshot.pendingSteers[index].clientSteerID = request.clientSteerID
        snapshot.pendingSteers[index].preempt = true
        snapshot.pendingSteers[index].preemptRevision = preemptRevision
        await installSteeringSnapshot(snapshot)
    }

    private func installSteeringSnapshot(_ snapshot: GenerationSnapshot) async {
        var snapshot = snapshot
        snapshot.updatedAt = Date()
        latestSnapshots[snapshot.handle] = snapshot
        await generationSession.install(snapshot)
        do {
            try await persist(snapshot)
        } catch {
            // A proven server acknowledgement remains authoritative even if
            // its local recovery checkpoint cannot be written immediately.
            AppLog.persistence.error("Generation steer checkpoint failed after authoritative acknowledgement.")
        }
    }

    private func activeAccountID() throws -> AccountID {
        guard let accountID else { throw LibreChatProtocolError.unauthorized }
        return accountID
    }

    private func resolvedMemoryCharacterLimit() async throws -> Int {
        if let memoryCharacterLimit { return memoryCharacterLimit }
        return try await memories().characterLimit
    }

    private func followUpNamespace(
        conversationID: ConversationID
    ) throws -> FollowUpQueueNamespace {
        try FollowUpQueueNamespace(
            profileID: profile.id,
            accountID: activeAccountID(),
            conversationID: conversationID
        )
    }
}

/// FIFO admission for mutations that share one exact generation handle. The
/// repository owns a distinct lane for every conversation/epoch coordinate,
/// so a replacement generation can never inherit an older lane's operation.
private actor SteeringControlLane {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct GenerationStartRequest: Encodable, Sendable {
    let text: String
    let sender: String
    let clientTimestamp: String
    let isCreatedByUser: Bool
    let parentMessageID: String
    let conversationID: String
    let messageID: String
    let endpoint: String
    let endpointType: String?
    let model: String?
    let agentID: String?
    let assistantID: String?
    let spec: String?
    let promptPrefix: String?
    let ephemeralAgent: GenerationEphemeralAgentRequest?
    let isTemporary: Bool
    let isRegenerate: Bool
    let isContinued: Bool
    let clientRequestID: String
    let timezone: String
    let generationProtocolVersion: Int
    let files: [GenerationFileReference]
    let chatProjectID: String?
    let expectedPredecessorCreatedAt: Int64?
    let recoverySteerID: String?
    let overrideUserMessageID: String?
    let overrideParentMessageID: String?
    let responseMessageID: String?
    let manualSkills: [String]?
    let quotes: [String]?

    private enum CodingKeys: String, CodingKey {
        case text, sender, clientTimestamp, isCreatedByUser, endpoint, endpointType, model, spec, promptPrefix, ephemeralAgent
        case parentMessageID = "parentMessageId"
        case conversationID = "conversationId"
        case messageID = "messageId"
        case agentID = "agent_id"
        case assistantID = "assistant_id"
        case isTemporary, isRegenerate, isContinued
        case clientRequestID = "clientRequestId"
        case timezone, generationProtocolVersion, files, expectedPredecessorCreatedAt
        case recoverySteerID = "recoverySteerId"
        case overrideUserMessageID = "overrideUserMessageId"
        case overrideParentMessageID = "overrideParentMessageId"
        case responseMessageID = "responseMessageId"
        case manualSkills, quotes
        case chatProjectID = "chatProjectId"
    }
}

private struct GenerationEphemeralAgentRequest: Encodable, Sendable {
    let mcp: [String]
    let webSearch: Bool
    let fileSearch: Bool
    let executeCode: Bool
    let artifacts: String
    let memory: Bool
    let skills: Bool?

    init(
        _ configuration: EphemeralAgentConfiguration,
        enableUnspecifiedSkills: Bool = false
    ) {
        mcp = configuration.mcpServers
        webSearch = configuration.webSearch
        fileSearch = configuration.fileSearch
        executeCode = configuration.executeCode
        memory = configuration.memory
        // A model specification's explicit true/false/name scope is resolved
        // server-side from `spec`. Only an omitted model-spec field may be
        // opted into by the request-scoped ephemeral agent.
        skills = configuration.skillScope == nil && enableUnspecifiedSkills
            ? true
            : nil
        switch configuration.artifacts {
        case .disabled:
            artifacts = ""
        case .serverDefault:
            artifacts = "default"
        case let .named(value):
            artifacts = value
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mcp, artifacts, memory, skills
        case webSearch = "web_search"
        case fileSearch = "file_search"
        case executeCode = "execute_code"
    }
}

private struct GenerationFileReference: Encodable, Sendable {
    let fileID: String

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
    }
}

private struct AbortGenerationRequest: Encodable, Sendable {
    let streamID: String
    let conversationID: String
    let generationCreatedAt: Int64?
    let generationProtocolVersion: Int

    private enum CodingKeys: String, CodingKey {
        case streamID = "streamId"
        case conversationID = "conversationId"
        case generationCreatedAt, generationProtocolVersion
    }
}

private struct AbortGenerationResponseDTO: Decodable, Sendable {
    let success: Bool?
    /// Current LibreChat returns the aborted stream id here; older fixtures
    /// have also used a boolean, so keep the acknowledgement value permissive.
    let aborted: JSONValue?
    let persistenceFailed: Bool?
    let settled: Bool?
    let code: String?
    let pendingSteers: [JSONValue]?
}

private struct ToolApprovalResolutionPayload: Encodable, Sendable {
    let toolCallID: String
    let decision: String
    let editedArguments: [String: JSONValue]?
    let responseText: String?
    let reason: String?
    let scope: String

    private enum CodingKeys: String, CodingKey {
        case toolCallID = "tool_call_id"
        case decision, editedArguments, responseText, reason, scope
    }
}

private struct PendingInteractionResponse: Encodable, Sendable {
    let conversationID: String
    let generationCreatedAt: Int64
    let generationProtocolVersion: Int
    let actionID: String
    let endpoint: String
    let agentID: String?
    let decisions: [ToolApprovalResolutionPayload]?
    let answer: String?
    let answers: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case generationCreatedAt, generationProtocolVersion
        case actionID = "actionId"
        case endpoint, decisions, answer, answers
        case agentID = "agent_id"
    }
}

private struct GenerationResumeResponseDTO: Decodable, Sendable {
    let streamID: String?
    let conversationID: String?
    let status: String?
    let generationProtocolVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case streamID = "streamId"
        case conversationID = "conversationId"
        case status, generationProtocolVersion
    }
}

private struct DeleteConversationRequest: Encodable, Sendable {
    let conversationID: String

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
    }
}

private struct DeleteConversationEnvelope: Encodable, Sendable {
    let arg: DeleteConversationRequest
}
