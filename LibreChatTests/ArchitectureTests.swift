import LibreChatDomain
import LibreChatProtocol
import SwiftData
import XCTest
@testable import LibreChat

/// In-memory secret store for tests that construct `AuthSession` directly.
/// The production default (`MirroredSecretStore`) writes to the Keychain and
/// a file mirror under the shared "session.shared" key, which leaks session
/// state between tests and across test runs.
actor InMemorySessionStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

extension AuthSession {
    /// Convenience for tests: an `AuthSession` whose durable session storage
    /// is private to this instance, so tests never observe or mutate the
    /// process-wide Keychain/file mirror.
    static func isolated(
        transport: HTTPTransport,
        observability: ProtocolObservability = .disabled
    ) -> AuthSession {
        AuthSession(
            transport: transport,
            secretStore: InMemorySessionStore(),
            observability: observability
        )
    }
}

@MainActor
final class ArchitectureTests: XCTestCase {
    func testMobileAuthenticationCallbackRequiresExactOriginPathAndUniqueQueryItems() throws {
        let valid = try XCTUnwrap(URL(string: "librechat://auth/callback?state=expected&code=single-use"))
        XCTAssertEqual(
            try MobileAuthenticationCallbackParser.authorizationCode(
                from: valid,
                expectedState: "expected"
            ),
            "single-use"
        )

        let invalidURLs = [
            "librechat://other/callback?state=expected&code=single-use",
            "librechat://auth/other?state=expected&code=single-use",
            "librechat://auth/callback?state=expected&state=expected&code=single-use",
            "librechat://auth/callback?state=expected&code=one&code=two",
            "librechat://auth/callback?state=expected&code=single-use&profile=other",
            "librechat://auth/callback?state=expected&code=single-use#fragment"
        ]
        for rawValue in invalidURLs {
            let url = try XCTUnwrap(URL(string: rawValue))
            XCTAssertThrowsError(
                try MobileAuthenticationCallbackParser.authorizationCode(
                    from: url,
                    expectedState: "expected"
                ),
                rawValue
            )
        }
    }

    func testMobileAuthenticationCallbackRejectsStateMismatchAndErrorResponse() throws {
        let mismatched = try XCTUnwrap(
            URL(string: "librechat://auth/callback?state=other&code=single-use")
        )
        XCTAssertThrowsError(
            try MobileAuthenticationCallbackParser.authorizationCode(
                from: mismatched,
                expectedState: "expected"
            )
        ) { error in
            guard case MobileAuthenticationError.stateMismatch = error else {
                return XCTFail("Expected a state mismatch, got \(error)")
            }
        }

        let denied = try XCTUnwrap(
            URL(string: "librechat://auth/callback?state=expected&error=access_denied")
        )
        XCTAssertThrowsError(
            try MobileAuthenticationCallbackParser.authorizationCode(
                from: denied,
                expectedState: "expected"
            )
        )

        let injectedDescription = try XCTUnwrap(
            URL(string: "librechat://auth/callback?state=expected&code=single-use&error_description=ignored")
        )
        XCTAssertThrowsError(
            try MobileAuthenticationCallbackParser.authorizationCode(
                from: injectedDescription,
                expectedState: "expected"
            )
        )
    }

    func testMobileAuthenticationEndpointStaysOnSelectedServerOriginAndBasePath() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://chat.example.com/librechat"))
        XCTAssertEqual(
            try MobileAuthenticationCoordinator.endpoint(
                "https://chat.example.com/librechat/api/auth/mobile/authorize",
                fallback: "unused",
                baseURL: baseURL
            ).path,
            "/librechat/api/auth/mobile/authorize"
        )
        XCTAssertEqual(
            try MobileAuthenticationCoordinator.endpoint(
                nil,
                fallback: "api/auth/mobile/authorize",
                baseURL: baseURL
            ).path,
            "/librechat/api/auth/mobile/authorize"
        )

        for rawValue in [
            "http://chat.example.com/librechat/api/auth/mobile/authorize",
            "https://other.example.com/librechat/api/auth/mobile/authorize",
            "https://chat.example.com/api/auth/mobile/authorize",
            "https://chat.example.com/librechat/%2e%2e/authorize"
        ] {
            XCTAssertThrowsError(
                try MobileAuthenticationCoordinator.endpoint(
                    rawValue,
                    fallback: "unused",
                    baseURL: baseURL
                ),
                rawValue
            )
        }
    }

    func testMobileAuthenticationFailsWhenSecureRandomGenerationFails() {
        XCTAssertThrowsError(
            try MobileAuthenticationCoordinator.randomURLSafeValue(
                byteCount: 32,
                randomBytes: { _ in throw MobileAuthenticationError.invalidConfiguration }
            )
        )
    }

    func testConversationListPartialRefreshKeepsAlreadyLoadedOlderChats() async {
        let older = Conversation(id: ConversationID(rawValue: "older"), title: "Older")
        let first = Conversation(id: ConversationID(rawValue: "first"), title: "First")
        let updatedFirst = Conversation(id: first.id, title: "First updated")
        let repository = ConversationListRepositoryDouble(pages: [
            ConversationPage(conversations: [first, older], nextCursor: nil),
            ConversationPage(conversations: [updatedFirst], nextCursor: "next")
        ])
        let model = ConversationListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.reload()
        await model.reload()

        XCTAssertEqual(model.conversations.map(\.id), [first.id, older.id])
        XCTAssertEqual(model.conversations.first?.title, "First updated")
        XCTAssertEqual(model.nextCursor, "next")
    }

    func testAmbiguousConversationDuplicationLocksOneSourceUntilAuthoritativeReload() async {
        let source = Conversation(id: ConversationID(rawValue: "source"), title: "Source")
        let copy = Conversation(id: ConversationID(rawValue: "copy"), title: "Source")
        let repository = ConversationListRepositoryDouble(
            pages: [ConversationPage(conversations: [source])],
            duplicateOutcomes: [
                .failure(.ambiguous),
                .success(ConversationDuplicationResult(conversation: copy, messages: []))
            ]
        )
        let model = ConversationListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")

        let first = await model.duplicate(source, profileID: profileID, accountID: accountID)
        XCTAssertNil(first)
        XCTAssertTrue(model.isDuplicationLocked(source))
        var requestCount = await repository.duplicateRequestCount()
        XCTAssertEqual(requestCount, 1)

        let blocked = await model.duplicate(source, profileID: profileID, accountID: accountID)
        XCTAssertNil(blocked)
        requestCount = await repository.duplicateRequestCount()
        XCTAssertEqual(requestCount, 1)

        await model.reload()
        XCTAssertFalse(model.isDuplicationLocked(source))
        let retried = await model.duplicate(source, profileID: profileID, accountID: accountID)
        XCTAssertEqual(retried, copy)
        XCTAssertEqual(model.conversations.first, copy)
        requestCount = await repository.duplicateRequestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testNewChatCatalogUsesServerDefaultAndRejectsAChoiceRemovedByRefresh() async {
        let original = ChatTargetOption(
            id: "endpoint:openAI:first",
            label: "First",
            target: ConversationTarget(endpoint: "openAI", model: "first")
        )
        let replacement = ChatTargetOption(
            id: "endpoint:openAI:second",
            label: "Second",
            target: ConversationTarget(endpoint: "openAI", model: "second")
        )
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let repository = ConversationListRepositoryDouble(
            pages: [],
            catalogs: [
                TargetCatalogSnapshot(
                    profileID: profileID,
                    accountID: accountID,
                    fetchedAt: Date(timeIntervalSince1970: 1),
                    options: [original],
                    effectiveDefaultOptionID: original.id,
                    agentDiscoveryStatus: .notSupported
                ),
                TargetCatalogSnapshot(
                    profileID: profileID,
                    accountID: accountID,
                    fetchedAt: Date(timeIntervalSince1970: 2),
                    options: [replacement],
                    effectiveDefaultOptionID: replacement.id,
                    agentDiscoveryStatus: .notSupported
                )
            ]
        )
        let model = ConversationListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadTargets()
        XCTAssertEqual(model.effectiveDefaultTargetID, original.id)

        await model.loadTargets(forceRefresh: true)
        XCTAssertEqual(model.effectiveDefaultTargetID, replacement.id)
        let staleConversation = await model.createConversation(title: "Stale", target: original)
        XCTAssertNil(staleConversation)
        XCTAssertEqual(
            model.targetError,
            "That model or agent is no longer available. Refresh and choose again."
        )
        XCTAssertEqual(model.creationError, model.targetError)
    }

    func testTargetSelectedFromAnExistingProjectChatCreatesANewScopedLocalDraft() async throws {
        let option = ChatTargetOption(
            id: "endpoint:openAI:next",
            label: "Next model",
            target: ConversationTarget(endpoint: "openAI", model: "next")
        )
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let projectID = ProjectID(rawValue: "project")
        let repository = ConversationListRepositoryDouble(
            pages: [],
            catalogs: [TargetCatalogSnapshot(
                profileID: profileID,
                accountID: accountID,
                fetchedAt: Date(timeIntervalSince1970: 1),
                options: [option],
                effectiveDefaultOptionID: option.id,
                agentDiscoveryStatus: .notSupported
            )]
        )
        let model = ConversationListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadTargets(forceRefresh: true)
        let created = await model.createConversation(
            title: "New chat",
            target: option,
            projectID: projectID
        )
        let conversation = try XCTUnwrap(created)

        XCTAssertTrue(conversation.id.isLocalDraft)
        XCTAssertEqual(conversation.projectID, projectID)
        XCTAssertEqual(conversation.target, option.target)
        // The unsent canvas is ephemeral: no sidebar row exists until the
        // server assigns a real conversation identity at first send.
        XCTAssertTrue(model.conversations.isEmpty)
        let remembered = await repository.rememberedTargetSelections()
        XCTAssertEqual(remembered.map(\.optionID), [option.id])
        XCTAssertEqual(remembered.map(\.profileID), [profileID])
        XCTAssertEqual(remembered.map(\.accountID), [accountID])
    }

    func testTargetRefreshFailsClosedWhenTheAccountBecomesOffline() async {
        let option = ChatTargetOption(
            id: "endpoint:openAI:online",
            label: "Online model",
            target: ConversationTarget(endpoint: "openAI", model: "online")
        )
        let repository = ConversationListRepositoryDouble(
            pages: [],
            catalogs: [TargetCatalogSnapshot(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                fetchedAt: Date(timeIntervalSince1970: 1),
                options: [option],
                effectiveDefaultOptionID: option.id,
                agentDiscoveryStatus: .notSupported
            )]
        )
        let connectivity = MutableOfflineState()
        let model = ConversationListModel(
            repository: repository,
            isOffline: { connectivity.value },
            onUnauthorized: {}
        )

        await model.loadTargets()
        XCTAssertEqual(model.availableTargets, [option])

        connectivity.value = true
        await model.loadTargets(forceRefresh: true)

        XCTAssertTrue(model.availableTargets.isEmpty)
        XCTAssertNil(model.effectiveDefaultTargetID)
        XCTAssertEqual(model.targetError, "Chat targets are unavailable offline.")
        let created = await model.createConversation(title: "Must not create", target: option)
        XCTAssertNil(created)
        XCTAssertEqual(model.creationError, "New chats are unavailable offline.")
    }

    func testTargetPickerGroupsAuthorizedOptionsWithoutChangingServerOrder() {
        let options = [
            ChatTargetOption(
                id: "endpoint:openAI:model-b",
                label: "OpenAI · Model B",
                target: ConversationTarget(endpoint: "openAI", model: "model-b")
            ),
            ChatTargetOption(
                id: "spec:careful",
                label: "Careful mode",
                subtitle: "Configured by this server",
                target: ConversationTarget(endpoint: "openAI", model: "model-a", spec: "careful")
            ),
            ChatTargetOption(
                id: "agent:saved-agent",
                label: "Research agent",
                target: ConversationTarget(endpoint: "agents", agentID: "saved-agent")
            ),
            ChatTargetOption(
                id: "endpoint:anthropic:model-a",
                label: "Anthropic · Model A",
                target: ConversationTarget(endpoint: "anthropic", model: "model-a")
            )
        ]

        let index = ChatTargetPickerIndex(options: options)

        XCTAssertEqual(index.groups.map(\.category), [.configured, .agents, .models])
        XCTAssertEqual(
            index.groups.first(where: { $0.category == .models })?.options.map(\.id),
            ["endpoint:openAI:model-b", "endpoint:anthropic:model-a"]
        )
    }

    func testTargetPickerSearchMatchesEveryTermAcrossSafePresentationMetadata() {
        let spec = ChatTargetOption(
            id: "spec:careful",
            label: "Careful mode",
            subtitle: "Long-form research",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-test", spec: "careful")
        )
        let agent = ChatTargetOption(
            id: "agent:opaque-server-id",
            label: "Research agent",
            target: ConversationTarget(endpoint: "agents", agentID: "opaque-server-id")
        )
        let index = ChatTargetPickerIndex(options: [spec, agent])

        XCTAssertEqual(index.matching("research long").flatMap(\.options).map(\.id), [spec.id])
        XCTAssertEqual(index.matching("agents research").flatMap(\.options).map(\.id), [agent.id])
        XCTAssertTrue(
            index.matching("opaque-server-id").isEmpty,
            "Raw server agent identifiers must not become presentation search metadata"
        )
        XCTAssertEqual(index.matching("   "), index.groups)
    }

    func testPhoneConversationNavigationPushesRowsAndPreservesNewChatRouteAcrossIdentityHandoff() {
        let existingID = ConversationID(rawValue: "existing")
        let localID = ConversationID(
            localDraftID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        )
        let canonicalID = ConversationID(rawValue: "canonical")
        var navigation = ConversationNavigationState()

        navigation.select(existingID, isPhone: true)
        navigation.select(existingID, isPhone: true)
        XCTAssertEqual(navigation.phonePath, [existingID], "Selecting one row twice must not stack duplicate chats")

        navigation.select(localID, isPhone: true)
        let presentationGeneration = navigation.detailPresentationGeneration
        XCTAssertEqual(navigation.phonePath, [existingID, localID])

        navigation.replaceIdentity(from: localID, with: canonicalID)

        XCTAssertEqual(navigation.selectedConversationID, canonicalID)
        XCTAssertEqual(navigation.resolvedConversationID(for: localID), canonicalID)
        XCTAssertEqual(
            navigation.detailPresentationGeneration,
            presentationGeneration,
            "Promoting a local draft must not replace its live ChatModel"
        )

        navigation.select(canonicalID, isPhone: true)
        XCTAssertEqual(
            navigation.phonePath,
            [existingID, localID],
            "The canonical ID must resolve to the existing local-draft route"
        )
    }

    func testTabletConversationNavigationReusesChatPresentationOnlyForIdentityHandoff() {
        let localID = ConversationID(
            localDraftID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        )
        let canonicalID = ConversationID(rawValue: "canonical")
        let otherID = ConversationID(rawValue: "other")
        var navigation = ConversationNavigationState()

        navigation.select(localID, isPhone: false)
        let localPresentationGeneration = navigation.detailPresentationGeneration
        navigation.replaceIdentity(from: localID, with: canonicalID)

        XCTAssertEqual(navigation.selectedConversationID, canonicalID)
        XCTAssertEqual(navigation.detailPresentationGeneration, localPresentationGeneration)

        navigation.select(otherID, isPhone: false)

        XCTAssertEqual(navigation.selectedConversationID, otherID)
        XCTAssertNotEqual(navigation.detailPresentationGeneration, localPresentationGeneration)
    }

    func testConversationNavigationReconcilesTabletAndPhoneSelectionsIndependently() {
        let firstID = ConversationID(rawValue: "first")
        var tabletNavigation = ConversationNavigationState()
        var phoneNavigation = ConversationNavigationState()

        tabletNavigation.reconcile(availableConversationIDs: [firstID], isPhone: false)
        phoneNavigation.reconcile(availableConversationIDs: [firstID], isPhone: true)

        XCTAssertEqual(tabletNavigation.selectedConversationID, firstID)
        XCTAssertNil(phoneNavigation.selectedConversationID)
        XCTAssertTrue(phoneNavigation.phonePath.isEmpty)
    }

    func testMessageSearchNavigationCarriesExactOneShotFocusAndNormalSelectionClearsIt() throws {
        let conversationID = ConversationID(rawValue: "conversation")
        let messageID = MessageID(rawValue: "matched-message")
        var navigation = ConversationNavigationState()

        navigation.selectMessage(messageID, in: conversationID, isPhone: true)

        XCTAssertEqual(navigation.phonePath, [conversationID])
        XCTAssertEqual(navigation.selectedConversationID, conversationID)
        let first = try XCTUnwrap(navigation.messageFocusRequest(for: conversationID))
        XCTAssertEqual(first.conversationID, conversationID)
        XCTAssertEqual(first.messageID, messageID)

        navigation.selectMessage(messageID, in: conversationID, isPhone: true)
        let second = try XCTUnwrap(navigation.messageFocusRequest(for: conversationID))
        XCTAssertNotEqual(second.sequence, first.sequence)
        XCTAssertEqual(
            navigation.phonePath,
            [conversationID],
            "Repeating a search focus must restart the task without stacking the same chat"
        )

        navigation.select(conversationID, isPhone: true)
        XCTAssertNil(navigation.messageFocusRequest(for: conversationID))
    }

    func testMessageSearchFocusIsScopedToSelectedConversationOnTablet() {
        let firstConversationID = ConversationID(rawValue: "first")
        let secondConversationID = ConversationID(rawValue: "second")
        let messageID = MessageID(rawValue: "matched-message")
        var navigation = ConversationNavigationState()

        navigation.select(firstConversationID, isPhone: false)
        let initialPresentation = navigation.detailPresentationGeneration
        navigation.selectMessage(messageID, in: firstConversationID, isPhone: false)

        XCTAssertEqual(navigation.detailPresentationGeneration, initialPresentation)
        XCTAssertNotNil(navigation.messageFocusRequest(for: firstConversationID))
        XCTAssertNil(navigation.messageFocusRequest(for: secondConversationID))

        navigation.select(secondConversationID, isPhone: false)
        XCTAssertNil(navigation.messageFocusRequest)
        XCTAssertNotEqual(navigation.detailPresentationGeneration, initialPresentation)
    }

    func testAuthenticatedCapabilitiesExposeSharedLinkFlags() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/config":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"sharedLinksEnabled":true,"publicSharedLinksEnabled":false,"sharedLinksSnapshotFilesEnabled":true,"allowAccountDeletion":true}"#.utf8)
                )
            case "/api/auth/mobile/config":
                return (Self.response(for: request, status: 404), Data(#"{"error":"Not installed"}"#.utf8))
            case "/api/endpoints":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"agents":{"disableBuilder":false},"openAI":{}}"#.utf8)
                )
            case "/api/roles/member":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"name":"member","permissions":{"BOOKMARKS":{"USE":true},"AGENTS":{"USE":true,"CREATE":true},"MCP_SERVERS":{"USE":true},"MEMORIES":{"USE":true,"READ":true}}}"#.utf8)
                )
            case "/api/files/speech/config/get":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"sttExternal":false,"ttsExternal":false}"#.utf8)
                )
            default:
                XCTFail("Unexpected capability request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        await repository.activate(account: UserAccount(
            id: AccountID(rawValue: "account"),
            role: "member"
        ))

        let result = try await repository.discoverCapabilities(authenticated: true)

        XCTAssertEqual(result.capabilities.supportsSharedLinks, true)
        XCTAssertEqual(result.capabilities.supportsPublicSharedLinks, false)
        XCTAssertEqual(result.capabilities.supportsSharedLinkFileSnapshots, true)
        XCTAssertEqual(result.capabilities.supportsAccountDeletion, true)
        XCTAssertEqual(result.capabilities.supportsBookmarks, true)
        XCTAssertEqual(result.capabilities.authenticatedPolicyVerified, true)
        XCTAssertTrue(result.capabilities.supportsAgents)
        XCTAssertEqual(
            result.capabilities.agentPermissions,
            AgentPermissions(use: true, create: true)
        )
        XCTAssertTrue(result.capabilities.supportsMCP)
        XCTAssertTrue(result.capabilities.supportsMemories)
    }

    func testAccountProfileReadRequiresTheExactActiveAccountIdentity() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"id":"account","name":"Berry","email":"berry@example.com","twoFactorEnabled":true,"unknown":"ignored"}"#.utf8)
            )
        }
        let (repository, _) = try await makeRepository()

        let profile = try await repository.accountProfile()

        XCTAssertEqual(profile.id.rawValue, "account")
        XCTAssertEqual(profile.name, "Berry")
        XCTAssertEqual(profile.email, "berry@example.com")
        XCTAssertEqual(profile.twoFactorEnabled, true)

        RepositoryURLProtocolStub.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data(#"{"id":"different-account","name":"Other"}"#.utf8)
            )
        }
        do {
            _ = try await repository.accountProfile()
            XCTFail("A different account must never replace the active profile identity")
        } catch let error as AccountProfileError {
            XCTAssertEqual(error, .accountMismatch)
        }
    }

    func testAccountAvatarUsesOneMultipartRequestAndResolvesTheReturnedProfileURL() async throws {
        let recorder = AccountRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/files/config"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"avatarSizeLimit":2097152}"#.utf8)
                )
            case ("POST", "/api/files/images/avatar"):
                recorder.record(request)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                let body = try Self.bodyData(for: request)
                let wire = String(decoding: body, as: UTF8.self)
                XCTAssertTrue(wire.contains("name=\"manual\"\r\n\r\ntrue"))
                XCTAssertTrue(wire.contains("filename=\"avatar.png\""))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"url":"/images/profile.png"}"#.utf8)
                )
            case ("GET", "/api/user"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"id":"account","avatar":"https://chat.example.com/images/profile.png?manual=true"}"#.utf8)
                )
            default:
                XCTFail("Unexpected account-avatar request")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        let account = try await repository.uploadAccountAvatar(
            AccountAvatarUpload(data: png, mimeType: "image/png"),
            previousAvatarURL: URL(string: "https://chat.example.com/images/old.png")
        )

        XCTAssertEqual(account.avatarURL?.absoluteString, "https://chat.example.com/images/profile.png?manual=true")
        XCTAssertEqual(recorder.count, 1)
    }

    func testAccountAvatarLostResponseReconcilesChangedAvatarWithoutReposting() async throws {
        let recorder = AccountRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/files/config"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"avatarSizeLimit":2097152}"#.utf8)
                )
            case ("POST", "/api/files/images/avatar"):
                recorder.record(request)
                throw URLError(.networkConnectionLost)
            case ("GET", "/api/user"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"id":"account","avatar":"https://chat.example.com/images/new.png"}"#.utf8)
                )
            default:
                XCTFail("Unexpected account-avatar request")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        let account = try await repository.uploadAccountAvatar(
            AccountAvatarUpload(data: png, mimeType: "image/png"),
            previousAvatarURL: URL(string: "https://chat.example.com/images/old.png")
        )

        XCTAssertEqual(account.avatarURL?.path, "/images/new.png")
        XCTAssertEqual(recorder.count, 1)
    }

    func testAccountAvatarUnchangedAuthoritativeAvatarIsFiniteUnknownWithoutRepost() async throws {
        let recorder = AccountRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/files/config"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"avatarSizeLimit":2097152}"#.utf8)
                )
            case ("POST", "/api/files/images/avatar"):
                recorder.record(request)
                throw URLError(.networkConnectionLost)
            case ("GET", "/api/user"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"id":"account","avatar":"https://chat.example.com/images/old.png?rotated=2"}"#.utf8)
                )
            default:
                XCTFail("Unexpected account-avatar request")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        do {
            _ = try await repository.uploadAccountAvatar(
                AccountAvatarUpload(data: png, mimeType: "image/png"),
                previousAvatarURL: URL(string: "https://chat.example.com/images/old.png?rotated=1")
            )
            XCTFail("An unchanged avatar cannot prove that the upload committed")
        } catch let error as AccountProfileError {
            XCTAssertEqual(error, .avatarOutcomeUnknown)
        }
        XCTAssertEqual(recorder.count, 1)
    }

    func testAccountDeletionIsOneShotAndLostDeliveryBecomesOutcomeUnknown() async throws {
        let recorder = AccountRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            recorder.record(request)
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/user/delete")
            let body = try Self.bodyData(for: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(object, ["backupCode": "one-use-code"])
            throw URLError(.networkConnectionLost)
        }
        let (repository, _) = try await makeRepository()

        do {
            try await repository.deleteAccount(proof: .backupCode("one-use-code"))
            XCTFail("Lost deletion delivery must remain outcome-unknown")
        } catch let error as AccountDeletionError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        XCTAssertEqual(recorder.count, 1)
    }

    func testRepositoryAccountAccessAndTermsUseExactAuthorizationBoundaries() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/auth/register"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try JSONSerialization.jsonObject(
                    with: Self.bodyData(for: request)
                ) as? [String: Any]
                XCTAssertEqual(body?["name"] as? String, "Person")
                XCTAssertEqual(body?["confirm_password"] as? String, "safe-password")
                XCTAssertNil(body?["username"])
                XCTAssertNil(body?["token"])
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"message":"Check your email"}"#.utf8)
                )
            case ("POST", "/api/auth/requestPasswordReset"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try JSONSerialization.jsonObject(
                    with: Self.bodyData(for: request)
                ) as? [String: Any]
                XCTAssertEqual(body?["email"] as? String, "person@example.com")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"message":"Check your email","link":"https://chat.example.com/reset-password?token=secret&userId=user"}"#.utf8)
                )
            case ("POST", "/api/auth/resetPassword"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = try JSONSerialization.jsonObject(
                    with: Self.bodyData(for: request)
                ) as? [String: Any]
                XCTAssertEqual(body?["userId"] as? String, "user")
                XCTAssertEqual(body?["token"] as? String, "one-shot")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"message":"Password reset was successful"}"#.utf8)
                )
            case ("POST", "/api/user/verify"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"message":"Email verification was successful","status":"success"}"#.utf8)
                )
            case ("POST", "/api/user/verify/resend"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"message":"Check your email"}"#.utf8)
                )
            case ("GET", "/api/user/terms"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"termsAccepted":false,"termsAcceptedAt":null}"#.utf8)
                )
            case ("POST", "/api/user/terms/accept"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"message":"Terms accepted successfully","termsAcceptedAt":"2026-08-18T10:00:00Z"}"#.utf8)
                )
            default:
                XCTFail("Unexpected account-access request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let registration = try await repository.register(AccountRegistration(
            name: "Person",
            email: "person@example.com",
            password: "safe-password",
            confirmationPassword: "safe-password"
        ))
        let reset = try await repository.requestPasswordReset(email: "person@example.com")
        let completion = try await repository.completePasswordReset(PasswordResetCompletion(
            userID: "user",
            token: "one-shot",
            password: "new-password"
        ))
        let verification = try await repository.verifyEmail(EmailVerification(
            email: "person@example.com",
            token: "one-shot"
        ))
        let resend = try await repository.resendEmailVerification(email: "person@example.com")
        let status = try await repository.termsAcceptanceStatus()
        let accepted = try await repository.acceptTerms()

        XCTAssertEqual(registration.notice.message, "Check your email")
        XCTAssertEqual(reset.recoveryURL?.scheme, "https")
        XCTAssertEqual(completion.notice.message, "Password reset was successful")
        XCTAssertEqual(verification.notice.status, "success")
        XCTAssertEqual(resend.notice.message, "Check your email")
        XCTAssertFalse(status.accepted)
        XCTAssertTrue(accepted.accepted)
        XCTAssertNotNil(accepted.acceptedAt)
    }

    func testRepositorySharedLinkOwnerLifecycleUsesPinnedRoutes() async throws {
        let conversationID = ConversationID(rawValue: "conversation")
        let shareID = SharedLinkID(rawValue: "share-safe-id")
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/share/link/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"success":false,"shareId":null,"conversationId":"conversation"}"#.utf8)
                )
            case ("POST", "/api/share/conversation"):
                let body = try JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                XCTAssertEqual(body?["targetMessageId"] as? String, "message")
                XCTAssertNil(body?["snapshotFiles"])
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"_id":"resource","shareId":"share-safe-id","conversationId":"conversation","targetMessageId":"message"}"#.utf8)
                )
            case ("PATCH", "/api/share/share-safe-id"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"_id":"resource","shareId":"share-safe-id","conversationId":"conversation","targetMessageId":"message"}"#.utf8)
                )
            case ("DELETE", "/api/share/share-safe-id"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"_id":"resource","success":true,"shareId":"share-safe-id","message":"Shared link deleted"}"#.utf8)
                )
            default:
                XCTFail("Unexpected shared-link request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let request = SharedLinkPublishRequest(targetMessageID: MessageID(rawValue: "message"))

        let initial = try await repository.sharedLink(for: conversationID)
        let created = try await repository.createSharedLink(for: conversationID, request: request)
        let updated = try await repository.updateSharedLink(shareID, request: request)
        let deleted = try await repository.deleteSharedLink(shareID)

        XCTAssertFalse(initial.isShared)
        XCTAssertEqual(created.shareID, shareID)
        XCTAssertEqual(updated.shareID, shareID)
        XCTAssertEqual(deleted.shareID, shareID)
    }

    func testRepositoryReadsPublicSnapshotWithoutBearerAndForksIntoCanonicalCache() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/share/public-share"):
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                let body = #"{"shareId":"public-share","conversationId":"pseudonymous-conversation","title":"Published","updatedAt":"2026-08-18T10:05:00Z","messages":[{"messageId":"pseudonymous-message","conversationId":"pseudonymous-conversation","sender":"Assistant","text":"Shared answer"}]}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case ("POST", "/api/share/public-share/fork"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                XCTAssertEqual(object["targetMessageIndex"] as? Int, 0)
                XCTAssertEqual(object["shareRevision"] as? String, "2026-08-18T10:05:00Z")
                let body = #"{"conversation":{"conversationId":"owned-conversation","title":"Forked"},"messages":[{"messageId":"owned-message","conversationId":"owned-conversation","sender":"Assistant","isCreatedByUser":false,"text":"Shared answer"}]}"#
                return (Self.response(for: request, status: 201), Data(body.utf8))
            default:
                XCTFail("Unexpected shared-snapshot request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, _) = try await makeRepository(dependencies: dependencies)
        let shareID = SharedLinkID(rawValue: "public-share")

        let snapshot = try await repository.sharedSnapshot(for: shareID)
        let forked = try await repository.forkSharedConversation(.init(
            shareID: shareID,
            targetMessageIndex: snapshot.messages.indices.last,
            shareRevision: snapshot.revision
        ))

        XCTAssertEqual(snapshot.conversationID, SharedConversationID(rawValue: "pseudonymous-conversation"))
        XCTAssertEqual(forked.conversation.id, ConversationID(rawValue: "owned-conversation"))
        let cachedConversations = try await dependencies.cache.conversations(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            limit: 10
        )
        XCTAssertEqual(cachedConversations?.conversations.map(\.id), [forked.conversation.id])
        let cachedMessages = try await dependencies.cache.messages(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversationID: forked.conversation.id
        )
        XCTAssertEqual(cachedMessages.map(\.id), [MessageID(rawValue: "owned-message")])
    }

    func testSharedSnapshotForkConflictRefreshesBeforeAllowingRetry() async {
        let repository = SharedSnapshotRepositoryDouble()
        let model = SharedSnapshotModel(
            shareID: SharedLinkID(rawValue: "share"),
            repository: repository,
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        let result = await model.fork()

        XCTAssertNil(result)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.snapshot?.revision, SharedSnapshotRevision(rawValue: "revision-2"))
        XCTAssertTrue(model.operationError?.contains("changed") == true)
        let snapshotCalls = await repository.snapshotCallCount()
        XCTAssertEqual(snapshotCalls, 2)
    }

    func testSharedSnapshotRequiresRevisionBeforeForking() async {
        let repository = SharedSnapshotFailureRepository(mode: .missingRevision)
        let model = SharedSnapshotModel(
            shareID: SharedLinkID(rawValue: "share"),
            repository: repository,
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        let result = await model.fork()

        XCTAssertNil(result)
        XCTAssertFalse(model.canForkSnapshot)
        XCTAssertTrue(model.forkUnavailableReason?.contains("revision") == true)
        let missingRevisionForkCalls = await repository.forkCallCount()
        XCTAssertEqual(missingRevisionForkCalls, 0)
    }

    func testSharedSnapshotAmbiguousForkCannotBeRepeatedBlindly() async {
        let repository = SharedSnapshotFailureRepository(mode: .transport)
        let model = SharedSnapshotModel(
            shareID: SharedLinkID(rawValue: "share"),
            repository: repository,
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        let firstResult = await model.fork()
        let secondResult = await model.fork()
        XCTAssertNil(firstResult)
        XCTAssertNil(secondResult)

        XCTAssertTrue(model.forkOutcomeMayBeAmbiguous)
        XCTAssertFalse(model.canForkSnapshot)
        XCTAssertTrue(model.forkUnavailableReason?.contains("may already exist") == true)
        let ambiguousForkCalls = await repository.forkCallCount()
        XCTAssertEqual(ambiguousForkCalls, 1)
    }

    func testSharedSnapshotForkAuthorizationAndExpiryFailClosed() async {
        let forbiddenRepository = SharedSnapshotFailureRepository(mode: .forbidden)
        let forbiddenModel = SharedSnapshotModel(
            shareID: SharedLinkID(rawValue: "share"),
            repository: forbiddenRepository,
            onUnauthorized: {}
        )
        await forbiddenModel.loadIfNeeded()
        let forbiddenResult = await forbiddenModel.fork()
        XCTAssertNil(forbiddenResult)
        XCTAssertNotNil(forbiddenModel.snapshot)
        XCTAssertFalse(forbiddenModel.canForkSnapshot)
        XCTAssertTrue(forbiddenModel.forkUnavailableReason?.contains("not allowed") == true)

        let expiredRepository = SharedSnapshotFailureRepository(mode: .expired)
        let expiredModel = SharedSnapshotModel(
            shareID: SharedLinkID(rawValue: "share"),
            repository: expiredRepository,
            onUnauthorized: {}
        )
        await expiredModel.loadIfNeeded()
        let expiredResult = await expiredModel.fork()
        XCTAssertNil(expiredResult)
        XCTAssertNil(expiredModel.snapshot)
        XCTAssertEqual(expiredModel.state, .failed("This shared snapshot is no longer available."))
    }

    func testSharedSnapshotReloadDoesNotLetAnOlderResponseOverwriteNewerState() async {
        let repository = ControlledSharedSnapshotRepository()
        let model = SharedSnapshotModel(
            shareID: SharedLinkID(rawValue: "share"),
            repository: repository,
            onUnauthorized: {}
        )

        let firstLoad = Task { await model.reload() }
        await repository.waitForRequestCount(1)
        let secondLoad = Task { await model.reload() }
        await repository.waitForRequestCount(2)

        await repository.resolve(request: 2, title: "Newer", revision: "revision-2")
        await secondLoad.value
        await repository.resolve(request: 1, title: "Older", revision: "revision-1")
        await firstLoad.value

        XCTAssertEqual(model.snapshot?.title, "Newer")
        XCTAssertEqual(model.snapshot?.revision, SharedSnapshotRevision(rawValue: "revision-2"))
    }

    func testSharedLinkModelResolvesCreateConflictAndPreservesDeploymentSubpath() async {
        let repository = SharedLinkRepositoryDouble()
        let model = SharedLinkOwnerModel(
            conversationID: ConversationID(rawValue: "conversation"),
            baseURL: URL(string: "https://chat.example.com/librechat/")!,
            repository: repository,
            onUnauthorized: {}
        )

        let url = await model.create(targetMessageID: MessageID(rawValue: "message"))
        let lookupCount = await repository.lookupCount()
        let snapshotFiles = await repository.createdSnapshotFiles()

        XCTAssertEqual(url?.absoluteString, "https://chat.example.com/librechat/share/server-share")
        XCTAssertEqual(model.state, .available)
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(snapshotFiles, false, "The owner flow must opt out of file snapshots by default")
    }

    func testSharedLinkRefresh404ClearsKnownDeadURL() async {
        let repository = SharedLinkFailureRepositoryDouble(mode: .expiredOnUpdate)
        let model = SharedLinkOwnerModel(
            conversationID: ConversationID(rawValue: "conversation"),
            baseURL: URL(string: "https://chat.example.com")!,
            repository: repository,
            onUnauthorized: {}
        )
        await model.reload()
        XCTAssertEqual(model.state, .available)

        _ = await model.refresh(targetMessageID: nil, snapshotFiles: false)

        XCTAssertEqual(model.state, .absent)
        XCTAssertNil(model.link)
        XCTAssertNil(model.shareURL)
    }

    func testSharedLinkPermissionDenialIsExplicit() async {
        let repository = SharedLinkFailureRepositoryDouble(mode: .deniedOnCreate)
        let model = SharedLinkOwnerModel(
            conversationID: ConversationID(rawValue: "conversation"),
            baseURL: URL(string: "https://chat.example.com")!,
            repository: repository,
            onUnauthorized: {}
        )

        _ = await model.create(targetMessageID: nil, snapshotFiles: false)

        XCTAssertEqual(
            model.state,
            .failed("Your LibreChat role does not allow creating or updating shared links.")
        )
    }

    func testProjectModelPreservesEmptyDescriptionAsClearCommand() async {
        let repository = ProjectRepositoryDouble()
        let model = ProjectListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )
        let id = ProjectID(rawValue: "project")

        let updated = await model.updateProject(id: id, description: "   ")
        let captured = await repository.capturedUpdate()

        XCTAssertEqual(captured?.description, "")
        XCTAssertEqual(updated?.description, "")
    }

    func testProjectSearchOptimismMatchesServerNameOnlySemantics() async throws {
        let repository = ProjectRepositoryDouble()
        let model = ProjectListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {},
            debounce: {}
        )
        model.searchQuery = "needle"
        model.searchChanged()
        try await Task.sleep(for: .milliseconds(30))

        _ = await model.createProject(name: "Other", description: "needle appears only here")

        XCTAssertTrue(model.projects.isEmpty)
    }

    func testStaleProjectPaginationFailureCannotExpireNewerSearch() async throws {
        let repository = ProjectPaginationRaceRepositoryDouble()
        var didExpireSession = false
        let model = ProjectListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: { didExpireSession = true },
            debounce: {}
        )
        await model.reload()
        let last = try XCTUnwrap(model.projects.last)

        let stalePage = Task { await model.loadMoreIfNeeded(after: last) }
        try await Task.sleep(for: .milliseconds(20))
        model.searchQuery = "fresh"
        await model.reload()
        await stalePage.value

        XCTAssertFalse(didExpireSession)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.projects.map(\.name), ["Fresh result"])
    }

    func testSearchModelRejectsLateResultsWhenQueryCyclesBack() async throws {
        let repository = SearchRepositoryDouble()
        let model = SearchModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {},
            debounce: {}
        )

        model.query = "alpha"
        model.queryChanged()
        try await Task.sleep(for: .milliseconds(20))
        model.query = "beta"
        model.queryChanged()
        try await Task.sleep(for: .milliseconds(20))
        model.query = "alpha"
        model.queryChanged()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.conversationResults.map(\.title), ["Fresh alpha"])
        XCTAssertFalse(model.resultsAreStale)
    }

    func testSearchModelFiltersSavedConversationTitlesAndModelsOffline() async throws {
        let repository = SearchRepositoryDouble(cached: [
            Conversation(id: .init(rawValue: "title"), title: "Swift concurrency", model: "other"),
            Conversation(id: .init(rawValue: "model"), title: "Architecture", model: "swift-model"),
            Conversation(id: .init(rawValue: "miss"), title: "Cooking", model: "chef")
        ])
        let model = SearchModel(
            repository: repository,
            isOffline: { true },
            onUnauthorized: {},
            debounce: {}
        )

        model.query = "swift"
        model.queryChanged()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(Set(model.conversationResults.map(\.id)), Set([
            ConversationID(rawValue: "title"),
            ConversationID(rawValue: "model")
        ]))
        XCTAssertEqual(model.state, .loaded)
    }

    func testRepositoryConversationSearchUsesCurrentRouteAndOpaqueCursor() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/convos")
            let queryItems = try XCTUnwrap(
                URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            )
            let values = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
                item.value.map { (item.name, $0) }
            })
            XCTAssertEqual(values["search"], "release notes")
            XCTAssertEqual(values["cursor"], "opaque+/=cursor")
            XCTAssertEqual(values["limit"], "12")
            XCTAssertEqual(values["isArchived"], "false")
            XCTAssertEqual(values["sortBy"], "updatedAt")
            XCTAssertEqual(values["sortDirection"], "desc")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"conversations":[{"conversationId":"match","title":"Release notes"}],"nextCursor":"page-two"}"#.utf8)
            )
        }
        let (repository, _) = try await makeRepository()

        let page = try await repository.searchConversations(
            query: "  release notes  ",
            cursor: "opaque+/=cursor",
            limit: 12
        )

        XCTAssertEqual(page.conversations.map(\.id), [ConversationID(rawValue: "match")])
        XCTAssertEqual(page.nextCursor, "page-two")
    }

    func testRepositoryMessageSearchUsesMessagesRouteAndPreservesConversationContext() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/messages")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queryItems, [URLQueryItem(name: "search", value: "needle")])
            return (
                Self.response(for: request, status: 200),
                Data(#"{"messages":[{"messageId":"message","conversationId":"conversation","title":"Found chat","model":"gpt-test","endpoint":"openAI","iconURL":"https://chat.example.com/icon.png","sender":"Assistant","text":"The needle is here","unknown":"ignored"}],"nextCursor":null}"#.utf8)
            )
        }
        let (repository, _) = try await makeRepository()

        let page = try await repository.searchMessages(query: " needle ")

        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(page.results[0].conversationTitle, "Found chat")
        XCTAssertEqual(page.results[0].message.conversationID, ConversationID(rawValue: "conversation"))
        XCTAssertEqual(page.results[0].message.plainText, "The needle is here")
        XCTAssertEqual(page.results[0].endpoint, "openAI")
        XCTAssertEqual(page.results[0].iconURL?.absoluteString, "https://chat.example.com/icon.png")
    }

    func testRepositoryProjectsAndMembershipUsePinnedRoutes() async throws {
        let projectID = ProjectID(rawValue: "507f1f77bcf86cd799439011")
        let conversationID = ConversationID(rawValue: "conversation")
        RepositoryURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/projects"):
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertTrue(query.contains(URLQueryItem(name: "cursor", value: "opaque-project-cursor")))
                XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "25")))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"projects":[{"_id":"507f1f77bcf86cd799439011","name":"Research","conversationCount":1}],"nextCursor":null}"#.utf8)
                )
            case ("PUT", "/api/projects/conversations/conversation"):
                let body = try JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                XCTAssertEqual(body?["projectId"] as? String, projectID.rawValue)
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversation":{"conversationId":"conversation","title":"Moved","chatProjectId":"507f1f77bcf86cd799439011"},"previousProjectId":null,"projectId":"507f1f77bcf86cd799439011"}"#.utf8)
                )
            case ("DELETE", "/api/projects/507f1f77bcf86cd799439011"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"deletedCount":1,"modifiedCount":1}"#.utf8)
                )
            case ("GET", "/api/convos"):
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertTrue(query.contains(URLQueryItem(name: "projectId", value: projectID.rawValue)))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversations":[{"conversationId":"conversation","title":"Moved","chatProjectId":"507f1f77bcf86cd799439011"}],"nextCursor":null}"#.utf8)
                )
            default:
                XCTFail("Unexpected project request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, _) = try await makeRepository(dependencies: dependencies)

        let projects = try await repository.projects(options: .init(
            cursor: "opaque-project-cursor",
            limit: 25
        ))
        let assignment = try await repository.assignConversation(id: conversationID, to: projectID)
        let conversations = try await repository.projectConversations(
            projectID: projectID,
            cursor: nil,
            limit: 25
        )
        try await dependencies.cache.save(
            page: ConversationPage(conversations: [
                assignment.conversation,
                Conversation(
                    id: .init(rawValue: "unrelated"),
                    title: "Elsewhere",
                    projectID: .init(rawValue: "other-project")
                )
            ]),
            profileID: .init(rawValue: "profile"),
            accountID: .init(rawValue: "account"),
            completeSynchronization: false
        )
        let deletion = try await repository.deleteProject(id: projectID)

        XCTAssertEqual(projects.projects.first?.id, projectID)
        XCTAssertEqual(assignment.conversation.projectID, projectID)
        XCTAssertEqual(conversations.conversations.first?.projectID, projectID)
        XCTAssertEqual(deletion.deletedCount, 1)
        let cached = try await dependencies.cache.conversations(
            profileID: .init(rawValue: "profile"),
            accountID: .init(rawValue: "account"),
            limit: 25
        )
        XCTAssertNil(cached?.conversations.first(where: { $0.id == conversationID })?.projectID)
        XCTAssertEqual(
            cached?.conversations.first(where: { $0.id.rawValue == "unrelated" })?.projectID,
            ProjectID(rawValue: "other-project")
        )
    }

    func testProfileAndAccountCacheIsolationOnSameHost() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let first = ServerProfile(id: .init(rawValue: "one"), baseURL: URL(string: "https://chat.example.com")!, displayName: "One")
        let second = ServerProfile(id: .init(rawValue: "two"), baseURL: URL(string: "https://chat.example.com")!, displayName: "Two")
        let account = UserAccount(id: .init(rawValue: "account"))
        try await dependencies.cache.save(profile: first)
        try await dependencies.cache.save(profile: second)
        try await dependencies.cache.saveAccount(profileID: first.id, account: account)
        try await dependencies.cache.saveAccount(profileID: second.id, account: account)

        let firstConversation = Conversation(id: .init(rawValue: "first"), title: "First")
        try await dependencies.cache.save(
            page: ConversationPage(conversations: [firstConversation]),
            profileID: first.id,
            accountID: account.id,
            completeSynchronization: true
        )

        let firstCache = try await dependencies.cache.conversations(profileID: first.id, accountID: account.id, limit: 25)
        let secondCache = try await dependencies.cache.conversations(profileID: second.id, accountID: account.id, limit: 25)
        XCTAssertEqual(firstCache?.conversations, [firstConversation])
        XCTAssertNil(secondCache)
    }

    func testSignedOutCacheCannotRestoreAnOfflineIdentity() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let account = UserAccount(id: AccountID(rawValue: "account"), email: "person@example.com")
        try await dependencies.cache.saveAccount(profileID: profileID, account: account)

        try await dependencies.cache.setCacheVisible(
            false,
            profileID: profileID,
            accountID: account.id
        )

        let restored = try await dependencies.cache.lastVerifiedAccount(
            profileID: profileID,
            accountID: account.id
        )
        XCTAssertNil(restored)
    }

    func testOfflineIdentityIsBoundToTheSelectedProfileAccountPair() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let first = UserAccount(id: AccountID(rawValue: "first"), email: "first@example.com")
        let second = UserAccount(id: AccountID(rawValue: "second"), email: "second@example.com")
        try await dependencies.cache.saveAccount(profileID: profileID, account: first)
        try await dependencies.cache.saveAccount(profileID: profileID, account: second)

        let restored = try await dependencies.cache.lastVerifiedAccount(
            profileID: profileID,
            accountID: first.id
        )

        XCTAssertEqual(restored?.id, first.id)
    }

    func testPartialPagesDoNotDeleteAndCompleteBoundaryDoes() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profile = ServerProfile(id: .init(rawValue: "profile"), baseURL: URL(string: "https://chat.example.com")!, displayName: "Test")
        let account = AccountID(rawValue: "account")
        let first = Conversation(id: .init(rawValue: "first"), title: "First")
        let second = Conversation(id: .init(rawValue: "second"), title: "Second")
        try await dependencies.cache.save(page: .init(conversations: [first, second]), profileID: profile.id, accountID: account, completeSynchronization: true)
        try await dependencies.cache.save(page: .init(conversations: [first], nextCursor: "more"), profileID: profile.id, accountID: account, completeSynchronization: false)
        let partial = try await dependencies.cache.conversations(profileID: profile.id, accountID: account, limit: 25)
        XCTAssertEqual(partial?.conversations.count, 2)
        try await dependencies.cache.save(page: .init(conversations: [first]), profileID: profile.id, accountID: account, completeSynchronization: true)
        let complete = try await dependencies.cache.conversations(profileID: profile.id, accountID: account, limit: 25)
        XCTAssertEqual(complete?.conversations, [first])
    }

    func testRepositoryCompletesConversationReconciliationAfterFinalPage() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/convos")
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cursor" })?.value
            if cursor == nil {
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversations":[{"conversationId":"first","title":"First"}],"nextCursor":"opaque-page-two"}"#.utf8)
                )
            }
            XCTAssertEqual(cursor, "opaque-page-two")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"conversations":[{"conversationId":"second","title":"Second"}],"nextCursor":null}"#.utf8)
            )
        }
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        try await dependencies.cache.save(
            page: ConversationPage(conversations: [
                Conversation(id: ConversationID(rawValue: "stale"), title: "Stale")
            ]),
            profileID: profileID,
            accountID: accountID,
            completeSynchronization: true
        )
        let (repository, _) = try await makeRepository(dependencies: dependencies)

        let firstPage = try await repository.conversations(cursor: nil, limit: 1)
        _ = try await repository.conversations(cursor: firstPage.nextCursor, limit: 1)

        let cached = try await dependencies.cache.conversations(
            profileID: profileID,
            accountID: accountID,
            limit: 25
        )
        XCTAssertEqual(Set(cached?.conversations.map(\.id) ?? []), Set([
            ConversationID(rawValue: "first"),
            ConversationID(rawValue: "second")
        ]))
    }

    func testConversationDeletionPurgesDraftGenerationAndUploadRecovery() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        try await dependencies.cache.save(
            page: ConversationPage(conversations: [
                Conversation(id: conversationID, title: "Delete me")
            ]),
            profileID: profileID,
            accountID: accountID,
            completeSynchronization: true
        )
        try await dependencies.cache.saveDraft(
            "Unsaved words",
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 1,
            protocolVersion: 2
        )
        try await dependencies.cache.save(GenerationSnapshot(handle: handle, state: .streaming))
        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "librechat-delete-\(UUID().uuidString).txt")
        try Data("draft upload".utf8).write(to: localURL)
        try await dependencies.cache.save(upload: PendingUpload(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            localURL: localURL,
            filename: "draft.txt"
        ))

        try await dependencies.cache.deleteConversation(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )

        let draft = try await dependencies.cache.draft(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let recoverable = try await dependencies.cache.recoverableGenerations(
            profileID: profileID,
            accountID: accountID
        )
        let uploads = try await dependencies.cache.uploads(
            profileID: profileID,
            accountID: accountID
        )
        XCTAssertEqual(draft, "")
        XCTAssertTrue(recoverable.isEmpty)
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testOnlyNonterminalGenerationCheckpointsRecover() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let handle = GenerationHandle(
            profileID: .init(rawValue: "profile"),
            accountID: .init(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "stream",
            conversationID: .init(rawValue: "conversation"),
            generationCreatedAt: 1,
            protocolVersion: 2
        )
        try await dependencies.cache.save(GenerationSnapshot(handle: handle, state: .streaming))
        let streaming = try await dependencies.cache.recoverableGenerations(profileID: handle.profileID, accountID: handle.accountID)
        XCTAssertEqual(streaming.count, 1)
        try await dependencies.cache.save(GenerationSnapshot(handle: handle, state: .completed))
        let completed = try await dependencies.cache.recoverableGenerations(profileID: handle.profileID, accountID: handle.accountID)
        XCTAssertTrue(completed.isEmpty)
    }

    func testGenerationStatusRestoresStructuredContentAndPendingAction() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/status/conversation")
            let body = #"{"active":true,"streamId":"conversation","status":"requires_action","createdAt":1000,"generationProtocolVersion":2,"resumeState":{"aggregatedContent":[{"type":"text","text":"Recovered"},{"type":"think","think":"Reasoning"}]},"pendingAction":{"actionId":"approval-1","payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":{},"tool_call_id":"call-1"}],"review_configs":[{"action_name":"shell","tool_call_id":"call-1","allowed_decisions":["approve","reject"]}]}}}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let (repository, handle) = try await makeRepository()

        let snapshot = try await repository.reconcile(handle)

        XCTAssertEqual(snapshot.response?.content, [.text("Recovered"), .reasoning("Reasoning")])
        guard case let .awaitingApproval(.toolApproval(approval)) = snapshot.state else {
            return XCTFail("Expected the status payload to restore its durable approval")
        }
        XCTAssertEqual(approval.id, "approval-1")
        XCTAssertEqual(approval.toolCallIDs, ["call-1"])
    }

    func testInactiveAbortedStatusDoesNotBecomeCompleted() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":false,"streamId":"conversation","status":"aborted","createdAt":1000,"generationProtocolVersion":2,"resumeState":{"responseMessageId":"assistant-1","aggregatedContent":[{"type":"text","text":"Partial"}]}}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                let body = #"[{"messageId":"assistant-1","conversationId":"conversation","sender":"Assistant","isCreatedByUser":false,"content":[{"type":"text","text":"Partial"}]}]"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()

        let snapshot = try await repository.reconcile(handle)

        XCTAssertEqual(snapshot.state, .aborted)
        XCTAssertEqual(snapshot.response?.id, MessageID(rawValue: "assistant-1"))
    }

    func testInactiveStatusSurfacesParkedSteerExactlyOnce() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":false,"streamId":"conversation","status":"aborted","createdAt":1000,"generationProtocolVersion":2,"unrecoveredSteers":[{"steerId":"parked-1","clientSteerId":"client-1","text":"Keep these words","preempt":true,"preemptRevision":3}]}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()

        _ = try await repository.reconcile(handle)
        let snapshot = try await repository.reconcile(handle)

        XCTAssertEqual(snapshot.state, .aborted)
        XCTAssertEqual(snapshot.recoverableSteers.map(\.id), ["parked-1"])
        XCTAssertEqual(snapshot.recoverableSteers.first?.preemptRevision, 3)
    }

    func testTerminalStatusSteerRecoveryIsDurableDeduplicatedAndClearedByExplicitEmptyProjection() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":false,"streamId":"conversation","status":"aborted","createdAt":1000,"generationProtocolVersion":2,"unrecoveredSteers":[{"steerId":"parked-1","clientSteerId":"client-1","text":"Keep these words"}]}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository(dependencies: dependencies)

        _ = try await repository.reconcile(handle)
        _ = try await repository.reconcile(handle)

        let active = try await repository.recoverableGenerations()
        let terminal = try await repository.recoverableSteerBatches(
            conversationID: handle.conversationID
        )
        XCTAssertTrue(active.isEmpty, "Terminal steer leftovers must never enter active generation recovery")
        XCTAssertEqual(terminal.count, 1)
        XCTAssertEqual(terminal.first?.steers.map(\.id), ["parked-1"])

        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":false,"streamId":"conversation","status":"aborted","createdAt":1000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        _ = try await repository.reconcile(handle)
        let preservedWhenProjectionIsAbsent = try await repository.recoverableSteerBatches(
            conversationID: handle.conversationID
        )
        XCTAssertEqual(preservedWhenProjectionIsAbsent.first?.steers.map(\.id), ["parked-1"])

        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":false,"streamId":"conversation","status":"aborted","createdAt":1000,"generationProtocolVersion":2,"unrecoveredSteers":[]}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }

        _ = try await repository.reconcile(handle)
        let cleared = try await repository.recoverableSteerBatches(
            conversationID: handle.conversationID
        )
        XCTAssertTrue(cleared.isEmpty)
    }

    func testFinalAndAbortTerminalFramesPersistSteerLeftoversOutsideActiveRecovery() async throws {
        let finalTransport = FiniteGenerationStreamTransport(events: [ServerSentEvent(
            id: "final-1",
            data: #"{"final":true,"pendingSteers":[{"steerId":"final-leftover","clientSteerId":"final-client","text":"Use this next"}],"responseMessage":{"text":"Done"}}"#
        )])
        let (finalRepository, finalHandle) = try await makeRepository(
            eventStreamTransport: finalTransport
        )
        let finalStream = await finalRepository.snapshots(for: finalHandle)
        var finalSnapshot: GenerationSnapshot?
        for try await snapshot in finalStream { finalSnapshot = snapshot }

        XCTAssertEqual(finalSnapshot?.state, .completed)
        let finalActive = try await finalRepository.recoverableGenerations()
        let finalBatches = try await finalRepository.recoverableSteerBatches(
            conversationID: finalHandle.conversationID
        )
        XCTAssertTrue(finalActive.isEmpty)
        XCTAssertEqual(finalBatches.first?.steers.map(\.id), ["final-leftover"])

        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/abort")
            let body = #"{"success":true,"aborted":"conversation","generationProtocolVersion":2,"pendingSteers":[{"steerId":"abort-leftover","clientSteerId":"abort-client","text":"Keep after abort"}]}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let abortTransport = FiniteGenerationStreamTransport(events: [ServerSentEvent(
            id: "abort-final",
            data: #"{"final":true,"aborted":true,"pendingSteers":[{"steerId":"abort-leftover","clientSteerId":"abort-client","text":"Keep after abort"}],"responseMessage":{"text":"Partial","unfinished":true}}"#
        )])
        let (abortRepository, abortHandle) = try await makeRepository(
            eventStreamTransport: abortTransport
        )

        try await abortRepository.stop(abortHandle)
        let abortStream = await abortRepository.snapshots(for: abortHandle)
        var abortSnapshot: GenerationSnapshot?
        for try await snapshot in abortStream { abortSnapshot = snapshot }

        XCTAssertEqual(abortSnapshot?.state, .aborted)
        let abortActive = try await abortRepository.recoverableGenerations()
        let abortBatches = try await abortRepository.recoverableSteerBatches(
            conversationID: abortHandle.conversationID
        )
        XCTAssertTrue(abortActive.isEmpty)
        XCTAssertEqual(abortBatches.first?.steers.map(\.id), ["abort-leftover"])
    }

    func testAbortAcknowledgementPreservesPendingSteerInRecoveryCheckpoint() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/abort")
            let body = #"{"success":true,"aborted":"conversation","generationProtocolVersion":2,"pendingSteers":[{"steerId":"abort-leftover","text":"Send this later","createdAt":1720000000100}]}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let (repository, handle) = try await makeRepository()

        try await repository.stop(handle)
        let recoverable = try await repository.recoverableGenerations()

        XCTAssertEqual(recoverable.count, 1)
        XCTAssertEqual(recoverable.first?.state, .stopping)
        XCTAssertEqual(recoverable.first?.recoverableSteers.map(\.id), ["abort-leftover"])
    }

    func testJoblessReconciliationDoesNotClaimANewerAssistantResponse() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":false,"streamId":"conversation","status":"settled","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                let body = #"[{"messageId":"assistant-a","conversationId":"conversation","sender":"Assistant","isCreatedByUser":false,"text":"Original response"},{"messageId":"assistant-b","conversationId":"conversation","sender":"Assistant","isCreatedByUser":false,"text":"Newer replacement"}]"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()

        let snapshot = try await repository.reconcile(handle)

        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertNil(
            snapshot.response,
            "A jobless status without responseMessageId must refresh history without attaching another generation's answer"
        )
    }

    func testStreamReplacementReconcilesImmediatelyAsSuperseded() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/status/conversation")
            let body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let streamTransport = FailingGenerationStreamTransport(
            error: .httpStatus(409, message: nil, retryAfter: nil)
        )
        let (repository, handle) = try await makeRepository(eventStreamTransport: streamTransport)

        let stream = await repository.snapshots(for: handle)
        var snapshots: [GenerationSnapshot] = []
        for try await snapshot in stream { snapshots.append(snapshot) }

        XCTAssertEqual(snapshots.map(\.state), [.superseded])
    }

    func testBatchedQuestionResponsePostsExactAnswerMap() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1","chatProjectId":"project-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/resume":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try Self.bodyData(for: request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertNil(object["answer"])
                XCTAssertEqual(
                    object["answers"] as? [String: String],
                    ["environment": "staging", "window": "7d"]
                )
                XCTAssertEqual(object["actionId"] as? String, "question-batch")
                let response = #"{"streamId":"conversation","conversationId":"conversation","status":"resuming","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()
        let question = UserQuestion(
            id: "question-batch",
            prompt: "Where and when?",
            questionIDs: ["environment", "window"]
        )

        _ = try await repository.respond(
            to: .userQuestion(question),
            handle: handle,
            toolResolutions: nil,
            answer: nil,
            batchAnswers: ["environment": "staging", "window": "7d"]
        )
    }

    func testDuplicateQuestionBatchIdentitiesPerformNoNetworkRequests() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail(
                "Duplicate question identities must be rejected before any network request: "
                    + (request.url?.path ?? "nil")
            )
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, handle) = try await makeRepository()
        let duplicate = UserQuestion(
            id: "question-batch",
            prompt: "Where and when?",
            questionIDs: ["environment", "environment"],
            items: [
                UserQuestionItem(id: "environment", prompt: "Environment?"),
                UserQuestionItem(id: "environment", prompt: "Again?"),
            ]
        )

        await assertUnsupported {
            _ = try await repository.respond(
                to: .userQuestion(duplicate),
                handle: handle,
                toolResolutions: nil,
                answer: nil,
                batchAnswers: ["environment": "staging"]
            )
        }
    }

    func testReorderedUniqueQuestionItemsRemainCompatibleWithAnswerMap() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/resume":
                let body = try Self.bodyData(for: request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(
                    object["answers"] as? [String: String],
                    ["environment": "staging", "window": "7d"]
                )
                let response = #"{"streamId":"conversation","conversationId":"conversation","status":"resuming","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()
        let reordered = UserQuestion(
            id: "question-batch",
            prompt: "Where and when?",
            questionIDs: ["environment", "window"],
            items: [
                UserQuestionItem(id: "window", prompt: "Window?"),
                UserQuestionItem(id: "environment", prompt: "Environment?"),
            ]
        )

        _ = try await repository.respond(
            to: .userQuestion(reordered),
            handle: handle,
            toolResolutions: nil,
            answer: nil,
            batchAnswers: ["environment": "staging", "window": "7d"]
        )
    }

    func testItemsWithoutQuestionIDsPerformNoNetworkRequests() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail(
                "Items without batch identities must be rejected before any network request: "
                    + (request.url?.path ?? "nil")
            )
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, handle) = try await makeRepository()
        let malformed = UserQuestion(
            id: "question-batch",
            prompt: "Where?",
            items: [
                UserQuestionItem(id: "environment", prompt: "Environment?"),
                UserQuestionItem(id: "environment", prompt: "Again?"),
            ]
        )

        await assertUnsupported {
            _ = try await repository.respond(
                to: .userQuestion(malformed),
                handle: handle,
                toolResolutions: nil,
                answer: "staging"
            )
        }
    }

    func testToolApprovalResponsePostsExactGenerationAndGraphFences() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/resume":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-LibreChat-Generation-Protocol"), "2")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                XCTAssertEqual(object["conversationId"] as? String, "conversation")
                XCTAssertEqual((object["generationCreatedAt"] as? NSNumber)?.int64Value, 1_000)
                XCTAssertEqual((object["generationProtocolVersion"] as? NSNumber)?.intValue, 2)
                XCTAssertEqual(object["actionId"] as? String, "approval")
                XCTAssertEqual(object["endpoint"] as? String, "agents")
                XCTAssertEqual(object["agent_id"] as? String, "agent-1")
                XCTAssertNil(object["answer"])
                XCTAssertNil(object["answers"])
                let decisions = try XCTUnwrap(object["decisions"] as? [[String: Any]])
                XCTAssertEqual(decisions.count, 2)
                XCTAssertEqual(decisions.map { $0["tool_call_id"] as? String }, ["call-1", "call-2"])
                XCTAssertTrue(decisions.allSatisfy { $0["decision"] as? String == "approve" })
                XCTAssertTrue(decisions.allSatisfy { $0["scope"] as? String == "once" })
                let response = #"{"streamId":"conversation","conversationId":"conversation","status":"resuming","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()
        let approval = ToolApprovalRequest(id: "approval", items: [
            ToolApprovalItem(
                id: "call-1",
                name: "Write",
                arguments: #"{"path":"a"}"#,
                allowedDecisions: [.approve, .reject]
            ),
            ToolApprovalItem(
                id: "call-2",
                name: "Write",
                arguments: #"{"path":"b"}"#,
                allowedDecisions: [.approve, .reject]
            ),
        ])

        _ = try await repository.respond(
            to: .toolApproval(approval),
            handle: handle,
            toolResolutions: [
                ToolApprovalResolution(toolCallID: "call-1", decision: .approve),
                ToolApprovalResolution(toolCallID: "call-2", decision: .approve),
            ],
            answer: nil
        )
    }

    func testToolApprovalResponsePostsMixedPerCallDecisionsAndRequiredPayloads() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/resume":
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                let decisions = try XCTUnwrap(object["decisions"] as? [[String: Any]])
                let decisionsByID = Dictionary(uniqueKeysWithValues: decisions.compactMap { decision in
                    (decision["tool_call_id"] as? String).map { ($0, decision) }
                })

                XCTAssertEqual(decisionsByID["approve"]?["decision"] as? String, "approve")
                XCTAssertEqual(decisionsByID["approve"]?["scope"] as? String, "once")
                XCTAssertNil(decisionsByID["approve"]?["editedArguments"])
                XCTAssertNil(decisionsByID["approve"]?["responseText"])

                XCTAssertEqual(decisionsByID["reject"]?["decision"] as? String, "reject")
                XCTAssertEqual(decisionsByID["reject"]?["reason"] as? String, "Unsafe destination")

                XCTAssertEqual(decisionsByID["respond"]?["decision"] as? String, "respond")
                XCTAssertEqual(decisionsByID["respond"]?["responseText"] as? String, "Use the cached result")

                XCTAssertEqual(decisionsByID["edit"]?["decision"] as? String, "edit")
                let edited = try XCTUnwrap(decisionsByID["edit"]?["editedArguments"] as? [String: Any])
                XCTAssertEqual(edited["path"] as? String, "/safe")
                XCTAssertEqual((edited["limit"] as? NSNumber)?.intValue, 2)

                let response = #"{"streamId":"conversation","conversationId":"conversation","status":"resuming","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()
        let approval = ToolApprovalRequest(id: "approval", items: [
            ToolApprovalItem(id: "approve", name: "Read", arguments: "{}", allowedDecisions: [.approve]),
            ToolApprovalItem(id: "reject", name: "Write", arguments: "{}", allowedDecisions: [.reject]),
            ToolApprovalItem(id: "edit", name: "Search", arguments: #"{"path":"/"}"#, allowedDecisions: [.edit]),
            ToolApprovalItem(id: "respond", name: "Cache", arguments: "{}", allowedDecisions: [.respond]),
        ])

        _ = try await repository.respond(
            to: .toolApproval(approval),
            handle: handle,
            toolResolutions: [
                ToolApprovalResolution(toolCallID: "approve", decision: .approve),
                ToolApprovalResolution(
                    toolCallID: "reject",
                    decision: .reject,
                    reason: "  Unsafe destination  "
                ),
                ToolApprovalResolution(
                    toolCallID: "edit",
                    decision: .edit,
                    editedArgumentsJSON: #"{"path":"/safe","limit":2}"#
                ),
                ToolApprovalResolution(
                    toolCallID: "respond",
                    decision: .respond,
                    responseText: "  Use the cached result  "
                ),
            ],
            answer: nil
        )
    }

    func testIncompleteAndStructurallyInvalidApprovalBatchesPerformNoNetworkRequests() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail("Invalid approval input must be rejected before any network request: \(request.url?.path ?? "nil")")
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, handle) = try await makeRepository()
        let twoCallApproval = ToolApprovalRequest(id: "batch", items: [
            ToolApprovalItem(id: "first", name: "First", arguments: "{}", allowedDecisions: [.approve]),
            ToolApprovalItem(id: "second", name: "Second", arguments: "{}", allowedDecisions: [.reject]),
        ])

        await assertUnsupported {
            _ = try await repository.respond(
                to: .toolApproval(twoCallApproval),
                handle: handle,
                toolResolutions: [ToolApprovalResolution(toolCallID: "first", decision: .approve)],
                answer: nil
            )
        }

        let editApproval = ToolApprovalRequest(id: "edit", items: [
            ToolApprovalItem(id: "edit", name: "Edit", arguments: "{}", allowedDecisions: [.edit]),
        ])
        await assertUnsupported {
            _ = try await repository.respond(
                to: .toolApproval(editApproval),
                handle: handle,
                toolResolutions: [
                    ToolApprovalResolution(
                        toolCallID: "edit",
                        decision: .edit,
                        editedArgumentsJSON: #"["not","an","object"]"#
                    )
                ],
                answer: nil
            )
        }

        let respondApproval = ToolApprovalRequest(id: "respond", items: [
            ToolApprovalItem(id: "respond", name: "Respond", arguments: "{}", allowedDecisions: [.respond]),
        ])
        await assertUnsupported {
            _ = try await repository.respond(
                to: .toolApproval(respondApproval),
                handle: handle,
                toolResolutions: [
                    ToolApprovalResolution(toolCallID: "respond", decision: .respond, responseText: "   ")
                ],
                answer: nil
            )
        }
    }

    func testGenerationMutationsRejectForeignOwnershipBeforeAnyNetworkRequest() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail("A foreign generation handle must not reach the server: \(request.url?.path ?? "nil")")
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, handle) = try await makeRepository()
        let foreign = GenerationHandle(
            profileID: ServerProfileID(rawValue: "other-profile"),
            accountID: handle.accountID,
            clientRequestID: handle.clientRequestID,
            streamID: handle.streamID,
            conversationID: handle.conversationID,
            generationCreatedAt: handle.generationCreatedAt,
            protocolVersion: handle.protocolVersion
        )

        do {
            _ = try await repository.respond(
                to: .userQuestion(UserQuestion(id: "question", prompt: "Continue?")),
                handle: foreign,
                toolResolutions: nil,
                answer: "Yes"
            )
            XCTFail("Expected foreign ownership to fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected an ownership error, got \(error)")
            }
        }

        do {
            try await repository.stop(foreign)
            XCTFail("Expected foreign stop ownership to fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected an ownership error, got \(error)")
            }
        }

        let stream = await repository.snapshots(for: foreign)
        do {
            for try await _ in stream {}
            XCTFail("Expected a foreign stream attachment to fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected an ownership error, got \(error)")
            }
        }
    }

    func testInteractionResponseRequiresAnExactProtocolAcknowledgement() async throws {
        let recorder = RepositoryRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/resume":
                recorder.record(clientRequestID: "resume")
                let response = #"{"streamId":"conversation","conversationId":"conversation","status":"resuming"}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, handle) = try await makeRepository()

        do {
            _ = try await repository.respond(
                to: .userQuestion(UserQuestion(id: "question", prompt: "Continue?")),
                handle: handle,
                toolResolutions: nil,
                answer: "Yes"
            )
            XCTFail("A protocol-less resume acknowledgement must fail closed")
        } catch let error as PendingInteractionResponseError {
            XCTAssertEqual(error, .postDispatch(.invalidResponse))
            XCTAssertFalse(error.isSafeToRetryPendingInteraction)
        }
        XCTAssertEqual(recorder.count, 1, "A malformed acknowledgement must not trigger a blind POST retry")
    }

    func testQuestionAnswerLengthUsesServerUTF16Semantics() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail("An oversized answer must be rejected before any network request: \(request.url?.path ?? "nil")")
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, handle) = try await makeRepository()
        let question = UserQuestion(id: "question", prompt: "Say something")

        do {
            _ = try await repository.respond(
                to: .userQuestion(question),
                handle: handle,
                toolResolutions: nil,
                answer: String(repeating: "🙂", count: 8_001)
            )
            XCTFail("Expected the 16,000 UTF-16 unit server limit to be enforced")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected a local unsupported-input error, got \(error)")
            }
        }
    }

    func testPendingInteractionIdentityResetsOnlyWhenAuthoritativePayloadChanges() {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let unchanged = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?", detail: "Choose one")
        )
        let changed = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue with which account?", detail: "Choose one")
        )

        XCTAssertEqual(
            PendingInteractionIdentity(handle: handle, interaction: unchanged),
            PendingInteractionIdentity(handle: handle, interaction: unchanged)
        )
        XCTAssertNotEqual(
            PendingInteractionIdentity(handle: handle, interaction: unchanged),
            PendingInteractionIdentity(handle: handle, interaction: changed),
            "A reused action ID with a changed authoritative payload must reset editor state"
        )
    }

    func testTemporaryChatGenerationUsesExactWireFlagAndNeverPersistsDraft() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/agents":
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                XCTAssertEqual(object["isTemporary"] as? Bool, true)
                XCTAssertEqual(object["text"] as? String, "Private prompt")
                XCTAssertEqual((object["generationProtocolVersion"] as? NSNumber)?.intValue, 2)
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"temporary-canonical","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected Temporary Chat request: \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, _) = try await makeRepository(dependencies: dependencies)
        let conversation = try await repository.createConversation(
            title: "Temporary",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1"),
            isTemporary: true
        )

        await repository.saveDraft("must not persist", conversationID: conversation.id)
        let storedDraft = try await dependencies.cache.draft(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversationID: conversation.id
        )
        XCTAssertEqual(storedDraft, "")

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Private prompt"
        ))
        guard case let .settled(conversationID) = outcome else {
            return XCTFail("Expected the terminal Temporary Chat receipt")
        }
        XCTAssertEqual(conversationID, ConversationID(rawValue: "temporary-canonical"))
    }

    func testModelSpecGenerationCarriesExactBrowserCompanionConfiguration() async throws {
        RepositoryURLProtocolStub.handler = { request in
            guard request.url?.path == "/api/agents/chat/openAI" else {
                XCTFail("Unexpected model-spec request: \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
            )
            XCTAssertEqual(object["spec"] as? String, "research")
            let ephemeral = try XCTUnwrap(object["ephemeralAgent"] as? [String: Any])
            XCTAssertEqual(ephemeral["mcp"] as? [String], ["docs", "search"])
            XCTAssertEqual(ephemeral["web_search"] as? Bool, true)
            XCTAssertEqual(ephemeral["file_search"] as? Bool, false)
            XCTAssertEqual(ephemeral["execute_code"] as? Bool, true)
            XCTAssertEqual(ephemeral["memory"] as? Bool, true)
            XCTAssertEqual(ephemeral["artifacts"] as? String, "default")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"conversationId":"canonical","status":"settled","generationProtocolVersion":2}"#.utf8)
            )
        }
        let (repository, _) = try await makeRepository()
        let conversation = try await repository.createConversation(
            title: "Spec",
            target: ConversationTarget(
                endpoint: "openAI",
                model: "gpt",
                spec: "research",
                ephemeralAgent: EphemeralAgentConfiguration(
                    mcpServers: ["docs", "search"],
                    webSearch: true,
                    fileSearch: false,
                    executeCode: true,
                    memory: true,
                    artifacts: .serverDefault
                )
            )
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Research this"
        ))

        guard case let .settled(conversationID) = outcome else {
            return XCTFail("Expected a settled model-spec receipt")
        }
        XCTAssertEqual(conversationID, ConversationID(rawValue: "canonical"))
    }

    func testAuthoritativeConversationHydrationRestoresVisibleModelSpecCompanion() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/config":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"modelSpecs":{"list":[{"name":"research","preset":{"endpoint":"openAI","model":"gpt"},"artifacts":"diagram","webSearch":true}]}}"#.utf8)
                )
            case "/api/auth/mobile/config", "/api/files/speech/config/get":
                return (Self.response(for: request, status: 404), Data())
            case "/api/endpoints":
                return (Self.response(for: request, status: 200), Data(#"{"openAI":{}}"#.utf8))
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Research","endpoint":"openAI","model":"gpt","spec":"research"}"#.utf8)
                )
            default:
                XCTFail("Unexpected hydration request: \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        _ = try await repository.discoverCapabilities(authenticated: true)

        let conversation = try await repository.conversation(
            id: ConversationID(rawValue: "conversation")
        )

        XCTAssertEqual(conversation.target?.ephemeralAgent, EphemeralAgentConfiguration(
            webSearch: true,
            artifacts: .named("diagram")
        ))
    }

    func testDiscoveringServerTemporaryChatPurgesPreviouslyCachedContent() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "temporary-server")
        try await dependencies.cache.save(
            page: ConversationPage(conversations: [
                Conversation(id: conversationID, title: "Previously cached")
            ]),
            profileID: profileID,
            accountID: accountID,
            completeSynchronization: false
        )
        try await dependencies.cache.save(
            messages: [ChatMessage(
                id: MessageID(rawValue: "private-message"),
                conversationID: conversationID,
                content: [.text("private")],
                author: .user
            )],
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        try await dependencies.cache.saveDraft(
            "private draft",
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/convos/temporary-server")
            let body = #"{"conversationId":"temporary-server","title":"Temporary","endpoint":"agents","agent_id":"agent-1","isTemporary":true,"expiredAt":"2030-01-02T03:04:05Z"}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let (repository, _) = try await makeRepository(dependencies: dependencies)

        let discovered = try await repository.conversation(id: conversationID)
        XCTAssertTrue(discovered.isTemporaryConversation)
        let cachedPage = try await dependencies.cache.conversations(
            profileID: profileID,
            accountID: accountID,
            limit: 25
        )
        let cachedMessages = try await dependencies.cache.messages(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let cachedDraft = try await dependencies.cache.draft(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertFalse(cachedPage?.conversations.contains { $0.id == conversationID } == true)
        XCTAssertTrue(cachedMessages.isEmpty)
        XCTAssertEqual(cachedDraft, "")
    }

    func testTemporaryConversationsStayOutOfConversationListPresentation() async {
        let temporary = Conversation(
            id: ConversationID(rawValue: "temporary"),
            title: "Temporary",
            isTemporary: true
        )
        let permanent = Conversation(id: ConversationID(rawValue: "permanent"), title: "Permanent")
        let repository = ConversationListRepositoryDouble(pages: [
            ConversationPage(conversations: [temporary, permanent])
        ])
        let model = ConversationListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        XCTAssertEqual(model.conversations.map(\.id), [temporary.id, permanent.id])
        XCTAssertEqual(model.listedConversations.map(\.id), [permanent.id])
    }

    func testGenerationStartRetriesExactRequestWithPredecessorFence() async throws {
        let recorder = RepositoryRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1","chatProjectId":"project-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/agents":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-LibreChat-Generation-Protocol"), "2")
                let body = try Self.bodyData(for: request)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                recorder.record(clientRequestID: object["clientRequestId"] as? String)
                XCTAssertEqual((object["expectedPredecessorCreatedAt"] as? NSNumber)?.int64Value, 1_000)
                XCTAssertEqual(object["parentMessageId"] as? String, "assistant-parent")
                XCTAssertEqual(object["chatProjectId"] as? String, "project-1")
                XCTAssertEqual(
                    (object["files"] as? [[String: Any]])?.first?["file_id"] as? String,
                    "uploaded-file"
                )
                if recorder.count < 5 {
                    return (Self.response(for: request, status: 503, headers: ["Retry-After": "0"]), Data(#"{"code":"SERVER_NOT_READY","error":"Retry"}"#.utf8))
                }
                let response = #"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            target: ConversationTarget(
                endpoint: "agents",
                agentID: "agent-1",
                parentMessageID: MessageID(rawValue: "stale-conversation-parent")
            ),
            projectID: ProjectID(rawValue: "project-1")
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            parentMessageID: MessageID(rawValue: "assistant-parent"),
            text: "Hello",
            attachments: [UploadedFile(id: "uploaded-file", filename: "brief.pdf")],
            expectedPredecessorCreatedAt: 1_000
        ))

        XCTAssertEqual(recorder.count, 5)
        XCTAssertEqual(recorder.uniqueClientRequestIDs.count, 1)
        guard case let .settled(conversationID) = outcome else {
            return XCTFail("A settled receipt must not create a synthetic stream handle")
        }
        XCTAssertEqual(conversationID, conversation.id)
    }

    func testPromptEditResubmitsAsExactUserSiblingWithoutMutatingHistory() async throws {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let messageID = MessageID(rawValue: "client-message-42")
        let recorder = RepositoryRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1","model":"agent-model"}"#.utf8)
                )
            case "/api/messages/conversation":
                // The selected source is not the flat-history tail. Its
                // direct parent is the only valid branch anchor.
                let history = #"""
                [
                  {"messageId":"assistant-parent","conversationId":"conversation","sender":"Assistant","text":"Earlier","isCreatedByUser":false},
                  {"messageId":"source-user","conversationId":"conversation","parentMessageId":"assistant-parent","sender":"User","text":"Original prompt","isCreatedByUser":true},
                  {"messageId":"other-sibling","conversationId":"conversation","parentMessageId":"assistant-parent","sender":"User","text":"Later branch","isCreatedByUser":true}
                ]
                """#
                return (Self.response(for: request, status: 200), Data(history.utf8))
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                )
            case "/api/agents/chat/agents":
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                recorder.record(clientRequestID: object["clientRequestId"] as? String)
                XCTAssertEqual(object["clientRequestId"] as? String, requestID.uuidString)
                XCTAssertEqual(object["messageId"] as? String, messageID.rawValue)
                XCTAssertEqual(object["parentMessageId"] as? String, "assistant-parent")
                XCTAssertEqual(object["conversationId"] as? String, "conversation")
                XCTAssertEqual(object["text"] as? String, "Revised prompt")
                XCTAssertEqual((object["generationProtocolVersion"] as? NSNumber)?.intValue, 2)
                XCTAssertEqual(object["isRegenerate"] as? Bool, false)
                XCTAssertEqual(object["isContinued"] as? Bool, false)
                XCTAssertNil(object["editedContent"])
                XCTAssertNil(object["isEdited"])
                XCTAssertNotEqual(object["messageId"] as? String, "source-user")
                XCTAssertEqual((object["files"] as? [[String: Any]])?.count, 0)
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected prompt-edit request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            model: "agent-model",
            target: ConversationTarget(endpoint: "agents", model: "agent-model", agentID: "agent-1")
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Revised prompt",
            clientRequestID: requestID,
            clientMessageID: messageID,
            action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
        ))

        guard case let .settled(conversationID) = outcome,
              conversationID == ConversationID(rawValue: "conversation") else {
            return XCTFail("Prompt edit should use the normal authoritative terminal outcome")
        }
        XCTAssertEqual(recorder.count, 1)
    }

    func testResponseRegenerateUsesExactSourceAndTargetWireCoordinates() async throws {
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let recorder = RepositoryRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1","model":"agent-model"}"#.utf8)
                )
            case "/api/messages/conversation":
                let history = #"""
                [
                  {"messageId":"source-user","conversationId":"conversation","text":"Original prompt","isCreatedByUser":true},
                  {"messageId":"target-assistant__","conversationId":"conversation","parentMessageId":"source-user","text":"Previous answer","isCreatedByUser":false,"sender":"Assistant"}
                ]
                """#
                return (Self.response(for: request, status: 200), Data(history.utf8))
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","createdAt":1000,"generationProtocolVersion":2}"#.utf8)
                )
            case "/api/agents/chat/agents":
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                recorder.record(
                    clientRequestID: object["clientRequestId"] as? String,
                    messageID: object["messageId"] as? String,
                    overrideParentMessageID: object["overrideParentMessageId"] as? String,
                    responseMessageID: object["responseMessageId"] as? String
                )
                XCTAssertEqual(object["clientRequestId"] as? String, requestID.uuidString)
                XCTAssertEqual(object["messageId"] as? String, "source-user")
                XCTAssertEqual(object["parentMessageId"] as? String, "00000000-0000-0000-0000-000000000000")
                XCTAssertEqual(object["overrideParentMessageId"] as? String, "source-user")
                XCTAssertEqual(object["responseMessageId"] as? String, "target-assistant_")
                XCTAssertEqual(object["text"] as? String, "Original prompt")
                XCTAssertEqual(object["isRegenerate"] as? Bool, true)
                XCTAssertEqual(object["isContinued"] as? Bool, false)
                XCTAssertEqual((object["generationProtocolVersion"] as? NSNumber)?.intValue, 2)
                XCTAssertEqual((object["expectedPredecessorCreatedAt"] as? NSNumber)?.int64Value, 1000)
                XCTAssertEqual((object["files"] as? [[String: Any]])?.count, 0)
                XCTAssertEqual(object["manualSkills"] as? [String], [])
                XCTAssertEqual(object["quotes"] as? [String], [])
                if recorder.count == 1 {
                    return (
                        Self.response(for: request, status: 503, headers: ["Retry-After": "0"]),
                        Data(#"{"code":"SERVER_NOT_READY","error":"Retry"}"#.utf8)
                    )
                }
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected response-regenerate request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            model: "agent-model",
            target: ConversationTarget(endpoint: "agents", model: "agent-model", agentID: "agent-1")
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Original prompt",
            clientRequestID: requestID,
            clientMessageID: MessageID(rawValue: "native-response-retry"),
            action: .regenerateResponse(
                sourceUserMessageID: MessageID(rawValue: "source-user"),
                targetAssistantMessageID: MessageID(rawValue: "target-assistant__")
            )
        ))

        guard case let .settled(conversationID) = outcome,
              conversationID == conversation.id else {
            return XCTFail("Response regeneration should use the normal authoritative terminal outcome")
        }
        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(recorder.uniqueClientRequestIDs.count, 1)
        XCTAssertEqual(recorder.uniqueMessageIDs.count, 1)
        XCTAssertEqual(recorder.uniqueOverrideParentMessageIDs.count, 1)
        XCTAssertEqual(recorder.uniqueResponseMessageIDs.count, 1)
    }

    func testResponseRegenerateRejectsAuthoritativeActiveGenerationBeforeHistoryOrPost() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":true,"status":"running","generationProtocolVersion":2,"streamId":"conversation","createdAt":1001}"#.utf8)
                )
            default:
                XCTFail("An active response regeneration must stop before history or generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Original",
                action: .regenerateResponse(
                    sourceUserMessageID: MessageID(rawValue: "source-user"),
                    targetAssistantMessageID: MessageID(rawValue: "target-assistant")
                )
            ))
            XCTFail("Active response regeneration must fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported active-generation error, got \(error)")
            }
        }
    }

    func testResponseRegenerateRejectsUnsupportedAuthoritativeGraphAndReplayMetadataBeforePost() async throws {
        let cases: [(String, String)] = [
            ("wrong-parent", #"[{"messageId":"source-user","conversationId":"conversation","text":"Original","isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"other-parent","text":"Answer","isCreatedByUser":false}]"#),
            ("wrong-role", #"[{"messageId":"source-user","conversationId":"conversation","text":"Original","isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"source-user","text":"Answer","isCreatedByUser":true}]"#),
            ("unfinished", #"[{"messageId":"source-user","conversationId":"conversation","text":"Original","unfinished":true,"isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"source-user","text":"Answer","isCreatedByUser":false}]"#),
            ("files", #"[{"messageId":"source-user","conversationId":"conversation","text":"Original","files":[{"file_id":"file-1"}],"isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"source-user","text":"Answer","isCreatedByUser":false}]"#),
            ("replay-metadata", #"[{"messageId":"source-user","conversationId":"conversation","text":"Original","manualSkills":["skill"],"quotes":["quote"],"isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"source-user","text":"Answer","isCreatedByUser":false}]"#),
            ("rich-target", #"[{"messageId":"source-user","conversationId":"conversation","text":"Original","isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"source-user","content":[{"type":"tool_call","name":"search"}],"isCreatedByUser":false}]"#),
            ("endpoint-mismatch", #"[{"messageId":"source-user","conversationId":"conversation","endpoint":"other-endpoint","text":"Original","isCreatedByUser":true},{"messageId":"target-assistant","conversationId":"conversation","parentMessageId":"source-user","text":"Answer","isCreatedByUser":false}]"#)
        ]

        for (label, history) in cases {
            RepositoryURLProtocolStub.handler = { request in
                switch request.url?.path {
                case "/api/convos/conversation":
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                    )
                case "/api/agents/chat/status/conversation":
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                    )
                case "/api/messages/conversation":
                    return (Self.response(for: request, status: 200), Data(history.utf8))
                default:
                    XCTFail("\(label) must fail before generation POST")
                    return (Self.response(for: request, status: 500), Data())
                }
            }
            let (repository, _) = try await makeRepository()
            do {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "conversation"),
                        title: "Test",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    text: "Original",
                    action: .regenerateResponse(
                        sourceUserMessageID: MessageID(rawValue: "source-user"),
                        targetAssistantMessageID: MessageID(rawValue: "target-assistant")
                    )
                ))
                XCTFail("Expected response regeneration case to fail closed: \(label)")
            } catch let error as LibreChatProtocolError {
                guard case .unsupported = error else {
                    return XCTFail("Expected unsupported \(label) error, got \(error)")
                }
            }
        }
    }

    func testResponseRegenerateFailsClosedWhenIdleStatusCannotBeVerified() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 503),
                    Data(#"{"error":"status unavailable"}"#.utf8)
                )
            default:
                XCTFail("Status verification failure must prevent history and generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Original",
                action: .regenerateResponse(
                    sourceUserMessageID: MessageID(rawValue: "source-user"),
                    targetAssistantMessageID: MessageID(rawValue: "target-assistant")
                )
            ))
            XCTFail("Response regeneration must fail closed when status is unavailable")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported status error, got \(error)")
            }
        }
    }

    func testGenerationRejectsUnsafeCallerMessageIDsBeforeAnyNetwork() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail("Unsafe caller message IDs must be rejected before network transport")
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, _) = try await makeRepository()
        let invalidIDs = [
            "",
            "new",
            "NO_PARENT",
            "00000000-0000-0000-0000-000000000000",
            "local-client-message",
            "LOCAL-client-message",
            "message/id",
            String(repeating: "x", count: 129)
        ]

        for invalidID in invalidIDs {
            do {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "conversation"),
                        title: "Test",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    text: "Hello",
                    clientMessageID: MessageID(rawValue: invalidID)
                ))
                XCTFail("Expected unsafe message ID to fail closed: \(invalidID)")
            } catch let error as LibreChatProtocolError {
                guard case .encoding = error else {
                    return XCTFail("Expected encoding rejection for \(invalidID), got \(error)")
                }
            }
        }
    }

    func testPromptEditRejectsRawArtifactAndCitationMarkersBeforeGenerationPost() async throws {
        let sourceTexts = [
            "Before\n:::artifact{identifier=\"notes\" type=\"text/plain\" title=\"Notes\"}\nunfinished",
            "Citation \\ue202turn0web0"
        ]

        for sourceText in sourceTexts {
            let recorder = RepositoryRequestRecorder()
            RepositoryURLProtocolStub.handler = { request in
                switch request.url?.path {
                case "/api/convos/conversation":
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                    )
                case "/api/agents/chat/status/conversation":
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                    )
                case "/api/messages/conversation":
                    let history: [[String: Any]] = [
                        [
                            "messageId": "parent",
                            "conversationId": "conversation",
                            "sender": "Assistant",
                            "text": "Earlier"
                        ],
                        [
                            "messageId": "source-user",
                            "conversationId": "conversation",
                            "parentMessageId": "parent",
                            "sender": "User",
                            "isCreatedByUser": true,
                            "text": sourceText
                        ]
                    ]
                    return (
                        Self.response(for: request, status: 200),
                        try JSONSerialization.data(withJSONObject: history)
                    )
                case "/api/agents/chat/agents":
                    recorder.record(clientRequestID: "unexpected-generation-post")
                    return (Self.response(for: request, status: 500), Data())
                default:
                    XCTFail("Semantic source markers must be rejected before generation transport")
                    return (Self.response(for: request, status: 500), Data())
                }
            }
            let (repository, _) = try await makeRepository()

            do {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "conversation"),
                        title: "Test",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    text: "Revised",
                    action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
                ))
                XCTFail("Prompt source marker should fail closed: \(sourceText)")
            } catch let error as LibreChatProtocolError {
                guard case .unsupported = error else {
                    return XCTFail("Expected unsupported source marker error, got \(error)")
                }
            }
            XCTAssertEqual(recorder.count, 0)
        }
    }

    func testPromptEditRequiresOneExactPrimaryTextCoordinate() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                )
            case "/api/messages/conversation":
                let history = #"[{"messageId":"parent","conversationId":"conversation","sender":"Assistant","text":"Earlier"},{"messageId":"source-user","conversationId":"conversation","parentMessageId":"parent","sender":"User","isCreatedByUser":true,"text":"Original","content":[{"type":"text","text":"Original"}]}]"#
                return (Self.response(for: request, status: 200), Data(history.utf8))
            default:
                XCTFail("Ambiguous editable coordinates must be rejected before generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Revised",
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Multiple editable coordinates must fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported coordinate error, got \(error)")
            }
        }
    }

    func testPromptEditRejectsUnsupportedSourceBeforeGenerationPost() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            case "/api/messages/conversation":
                let history = #"[{"messageId":"parent","conversationId":"conversation","sender":"Assistant","text":"Earlier"},{"messageId":"source-user","conversationId":"conversation","parentMessageId":"parent","sender":"User","isCreatedByUser":true,"text":"With file","files":[{"file_id":"file-1","filename":"brief.pdf"}]}]"#
                return (Self.response(for: request, status: 200), Data(history.utf8))
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unsupported source must be rejected before generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Revised",
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Attachment-bearing prompt should fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported source error, got \(error)")
            }
        }
    }

    func testPromptEditRejectsReplaySkillsAndQuotesBeforeGenerationPost() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                )
            case "/api/messages/conversation":
                let history = #"[{"messageId":"parent","conversationId":"conversation","sender":"Assistant","text":"Earlier"},{"messageId":"source-user","conversationId":"conversation","parentMessageId":"parent","sender":"User","isCreatedByUser":true,"text":"Original","manualSkills":["skill-a"],"quotes":["quote-a"]}]"#
                return (Self.response(for: request, status: 200), Data(history.utf8))
            default:
                XCTFail("Replay metadata must be rejected before generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Revised",
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Prompt edit with replay skills/quotes must fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported replay metadata error, got \(error)")
            }
        }
    }

    func testPromptEditRejectsFreshAttachmentsBeforeHistoryFetch() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            default:
                XCTFail("Fresh prompt-edit attachments must be rejected before history or generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Revised",
                attachments: [UploadedFile(id: "file-1", filename: "brief.pdf")],
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Fresh attachment-bearing prompt edit should fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported source error, got \(error)")
            }
        }
    }

    func testPromptEditRejectsConflictingSourceConfigurationBeforePost() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1","model":"current-model"}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                )
            case "/api/messages/conversation":
                let history = #"[{"messageId":"parent","conversationId":"conversation","sender":"Assistant","text":"Earlier"},{"messageId":"source-user","conversationId":"conversation","parentMessageId":"parent","sender":"User","isCreatedByUser":true,"endpoint":"other-endpoint","model":"other-model","text":"Original"}]"#
                return (Self.response(for: request, status: 200), Data(history.utf8))
            default:
                XCTFail("Conflicting source configuration must be rejected before generation transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    model: "current-model",
                    target: ConversationTarget(endpoint: "agents", model: "current-model", agentID: "agent-1")
                ),
                text: "Revised",
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Conflicting source configuration should fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported source configuration error, got \(error)")
            }
        }
    }

    func testPromptEditRequiresVerifiedResumableV2BeforeAnyNetwork() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail("Unknown generation capability must not negotiate through a prompt edit")
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, _) = try await makeRepository(
            capabilities: ServerCapabilities(generation: .unknown)
        )

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Revised",
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Unknown capability must fail closed")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported capability error, got \(error)")
            }
        }
    }

    func testPromptEditRequiresAuthoritativeIdleV2Status() async throws {
        for statusCode in [200, 500, 401] {
            RepositoryURLProtocolStub.handler = { request in
                switch request.url?.path {
                case "/api/convos/conversation":
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                    )
                case "/api/agents/chat/status/conversation":
                    if statusCode == 200 {
                        return (
                            Self.response(for: request, status: 200),
                            Data(#"{"active":true,"status":"requires_action","streamId":"conversation","createdAt":1000,"generationProtocolVersion":2}"#.utf8)
                        )
                    }
                    return (Self.response(for: request, status: statusCode), Data())
                case "/api/auth/refresh":
                    return (Self.response(for: request, status: 401), Data())
                default:
                    XCTFail("Prompt edit status preflight must prevent history and generation transport")
                    return (Self.response(for: request, status: 500), Data())
                }
            }
            let (repository, _) = try await makeRepository()
            do {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "conversation"),
                        title: "Test",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    text: "Revised",
                    action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
                ))
                XCTFail("Prompt edit must fail closed for status (statusCode)")
            } catch {
                // Both an active status and an unavailable/unauthorized
                // status are intentionally non-actionable.
            }
        }
    }

    func testPromptEditRejectsInvalidGraphAndActiveGeneration() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 1000,
            protocolVersion: 2
        )
        try await dependencies.cache.save(GenerationSnapshot(handle: handle, state: .streaming))
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8)
                )
            default:
                XCTFail("Active generation should be rejected before history or start transport")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository(dependencies: dependencies)

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Revised",
                action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
            ))
            XCTFail("Active generation should block prompt edit")
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected active-generation error, got \(error)")
            }
        }
    }

    func testGenerationStartRejectsImplicitOrExplicitRootWhenExistingHistoryIsNotEmpty() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                let body = #"[{"messageId":"persisted-root","conversationId":"conversation","sender":"User","isCreatedByUser":true,"text":"Hello"}]"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("A root branch parent must not start generation for nonempty history")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let rootRepresentations: [MessageID?] = [
            nil,
            MessageID(rawValue: "00000000-0000-0000-0000-000000000000"),
            MessageID(rawValue: "NO_PARENT")
        ]
        for parentMessageID in rootRepresentations {
            await assertUnsupported {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "conversation"),
                        title: "Test",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    parentMessageID: parentMessageID,
                    text: "Follow up"
                ))
            }
        }
    }

    func testGenerationStartUsesRootSentinelOnlyAfterExistingHistoryIsConfirmedEmpty() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            case "/api/agents/chat/agents":
                let body = try Self.bodyData(for: request)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(
                    object["parentMessageId"] as? String,
                    "00000000-0000-0000-0000-000000000000"
                )
                let response = #"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(response.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: Conversation(
                id: ConversationID(rawValue: "conversation"),
                title: "Test",
                target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
            ),
            text: "First message"
        ))

        guard case let .settled(conversationID) = outcome else {
            return XCTFail("An empty authoritative history should permit a root send")
        }
        XCTAssertEqual(conversationID, ConversationID(rawValue: "conversation"))
    }

    func testGenerationStartRejectsClientLocalParentBeforeTransport() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTFail("A client-local parent must be rejected before transport: \(request.url?.absoluteString ?? "nil")")
            return (Self.response(for: request, status: 500), Data())
        }
        let (repository, _) = try await makeRepository()

        await assertUnsupported {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                parentMessageID: MessageID(rawValue: "local-assistant-unconfirmed"),
                text: "Follow up"
            ))
        }
    }

    func testGenerationStartRejectsMalformedOrUnknownReceiptIdentities() async throws {
        let malformedReceipts = [
            #"{"conversationId":"conversation","streamId":"different","generationCreatedAt":1000,"generationProtocolVersion":2,"status":"started"}"#,
            #"{"conversationId":"conversation","streamId":"conversation","generationCreatedAt":-1,"generationProtocolVersion":2,"status":"started"}"#,
            #"{"conversationId":"conversation","streamId":"conversation","generationCreatedAt":1000,"generationProtocolVersion":2,"status":"mystery"}"#,
            #"{"status":"settled","generationProtocolVersion":2}"#
        ]

        for receipt in malformedReceipts {
            RepositoryURLProtocolStub.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/agents/chat/agents")
                return (Self.response(for: request, status: 200), Data(receipt.utf8))
            }
            let (repository, _) = try await makeRepository()

            do {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "new"),
                        title: "New chat",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    text: "Hello"
                ))
                XCTFail("Malformed start receipt was accepted: \(receipt)")
            } catch let error as LibreChatProtocolError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testPredecessorMismatchHandsOffOnlyToTheExactProvenWinner() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            case "/api/agents/chat/agents":
                let body = #"{"status":"predecessor_mismatch","code":"GENERATION_PREDECESSOR_MISMATCH","error":"A newer generation exists","streamId":"conversation","conversationId":"conversation","generationCreatedAt":2000,"predecessorVerified":true,"active":true,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 409), Data(body.utf8))
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Do not replace the newer run",
            expectedPredecessorCreatedAt: 1_000
        ))
        guard case let .handoff(handle) = outcome else {
            return XCTFail("Only an exact independently-proven winner may be handed off")
        }
        XCTAssertEqual(handle.streamID, "conversation")
        XCTAssertEqual(handle.generationCreatedAt, 2_000)
        XCTAssertNotEqual(handle.clientRequestID.uuidString, "")
    }

    func testReplacedReceiptHandsOffWithoutReusingLosingClientRequestID() async throws {
        let recorder = RepositoryRequestRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            case "/api/agents/chat/agents":
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                recorder.record(clientRequestID: object["clientRequestId"] as? String)
                let body = #"{"status":"replaced","streamId":"conversation","conversationId":"conversation","generationCreatedAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Do not attach this older submission"
        ))
        guard case let .handoff(handle) = outcome else {
            return XCTFail("A proven replacement must remain distinct from a successful original send")
        }
        XCTAssertNotEqual(handle.clientRequestID.uuidString, try XCTUnwrap(recorder.uniqueClientRequestIDs.first))
        XCTAssertEqual(handle.generationCreatedAt, 2_000)
    }

    func testPredecessorMismatchRejectsSameEpochOrInactiveWinnerProof() async throws {
        let proofBodies = [
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":1000,"generationProtocolVersion":2}"#,
            #"{"active":false,"streamId":"conversation","status":"complete","createdAt":2000,"generationProtocolVersion":2}"#,
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":3}"#,
            #"{"active":true,"streamId":"conversation","status":"running","generationProtocolVersion":2}"#
        ]
        for proof in proofBodies {
            RepositoryURLProtocolStub.handler = { request in
                switch request.url?.path {
                case "/api/convos/conversation":
                    return (Self.response(for: request, status: 200), Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#.utf8))
                case "/api/messages/conversation":
                    return (Self.response(for: request, status: 200), Data("[]".utf8))
                case "/api/agents/chat/agents":
                    return (Self.response(for: request, status: 409), Data(#"{"status":"predecessor_mismatch","streamId":"conversation","conversationId":"conversation","generationCreatedAt":2000,"generationProtocolVersion":2}"#.utf8))
                case "/api/agents/chat/status/conversation":
                    return (Self.response(for: request, status: 200), Data(proof.utf8))
                default:
                    return (Self.response(for: request, status: 404), Data())
                }
            }
            let (repository, _) = try await makeRepository()
            do {
                _ = try await repository.send(ChatRequest(
                    profileID: ServerProfileID(rawValue: "profile"),
                    accountID: AccountID(rawValue: "account"),
                    conversation: Conversation(
                        id: ConversationID(rawValue: "conversation"),
                        title: "Test",
                        target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                    ),
                    text: "Do not attach without exact proof",
                    expectedPredecessorCreatedAt: 1_000
                ))
                XCTFail("Malformed, same-epoch, or inactive winner proof must fail closed")
            } catch let LibreChatProtocolError.generationConflict(details) {
                XCTAssertEqual(details.status, "predecessor_mismatch")
            }
        }
    }

    func testReplacementProofUnauthorizedExpiresTheSessionInsteadOfBecomingAConflict() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            case "/api/agents/chat/agents":
                let body = #"{"status":"replaced","streamId":"conversation","conversationId":"conversation","generationCreatedAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/agents/chat/status/conversation", "/api/auth/refresh":
                return (Self.response(for: request, status: 401), Data())
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: conversation,
                text: "Do not hide an expired session"
            ))
            XCTFail("Expected status-proof authorization failure")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testActiveReconciliationRejectsUnfencedStatusBeforeApplyingItsContent() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/status/conversation")
            let body = #"{"active":true,"streamId":"other-stream","status":"running","createdAt":1000,"generationProtocolVersion":2,"resumeState":{"aggregatedContent":"foreign"}}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let (repository, handle) = try await makeRepository()

        do {
            _ = try await repository.reconcile(handle)
            XCTFail("An active status for another stream must not update this generation")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testActiveReconciliationMarksOnlyVerifiedDifferentEpochSuperseded() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/status/conversation")
            let body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"aggregatedContent":"new epoch"}}"#
            return (Self.response(for: request, status: 200), Data(body.utf8))
        }
        let (repository, handle) = try await makeRepository()

        let snapshot = try await repository.reconcile(handle)

        XCTAssertEqual(snapshot.state, .superseded)
        XCTAssertNil(snapshot.response)
    }

    func testActiveReconciliationRequiresEveryEpochProofCoordinate() async throws {
        let invalidBodies = [
            #"{"active":true,"streamId":"conversation","status":"running","generationProtocolVersion":2}"#,
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":1000}"#,
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":1000,"generationProtocolVersion":3}"#
        ]

        for body in invalidBodies {
            RepositoryURLProtocolStub.handler = { request in
                XCTAssertEqual(request.url?.path, "/api/agents/chat/status/conversation")
                return (Self.response(for: request, status: 200), Data(body.utf8))
            }
            let (repository, handle) = try await makeRepository()
            do {
                _ = try await repository.reconcile(handle)
                XCTFail("An active status missing a proof coordinate was accepted: \(body)")
            } catch let error as LibreChatProtocolError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testServerDiscoveryRecoversGenerationMissingFromLocalCheckpoints() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/active":
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-LibreChat-Generation-Protocol"), "2")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"activeJobIds":["conversation","conversation"]}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"aggregatedContent":[{"type":"text","text":"Recovered from the server"}]}}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let recovered = try await repository.recoverActiveGenerations()

        XCTAssertEqual(recovered.count, 1)
        let snapshot = try XCTUnwrap(recovered.first)
        XCTAssertEqual(snapshot.handle.streamID, "conversation")
        XCTAssertEqual(snapshot.handle.conversationID, ConversationID(rawValue: "conversation"))
        XCTAssertEqual(snapshot.handle.generationCreatedAt, 2_000)
        XCTAssertEqual(snapshot.handle.protocolVersion, 2)
        XCTAssertEqual(snapshot.state, .reconciling)
        XCTAssertEqual(snapshot.response?.content, [.text("Recovered from the server")])
        let persisted = try await repository.recoverableGenerations()
        XCTAssertEqual(persisted.map(\.handle), [snapshot.handle])
    }

    func testServerDiscoveryRejectsMismatchedGenerationIdentity() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/active":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"activeJobIds":["conversation"]}"#.utf8)
                )
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":true,"streamId":"different-conversation","status":"running","createdAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let recovered = try await repository.recoverActiveGenerations()

        XCTAssertTrue(recovered.isEmpty)
        let persisted = try await repository.recoverableGenerations()
        XCTAssertTrue(persisted.isEmpty)
    }

    func testAmbiguousNewConversationRecoveryUsesDeterministicServerID() async throws {
        let recorder = AmbiguousStartRecorder()
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let messageID = MessageID(rawValue: "client-message-43")
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/agents":
                let body = try Self.bodyData(for: request)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                recorder.record(
                    clientRequestID: object["clientRequestId"] as? String,
                    messageID: object["messageId"] as? String
                )
                XCTAssertEqual(object["conversationId"] as? String, "new")
                throw URLError(.networkConnectionLost)
            case let path? where path.hasPrefix("/api/agents/chat/status/"):
                XCTAssertEqual(path, "/api/agents/chat/status/\(try recorder.expectedConversationID())")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","generationProtocolVersion":2}"#.utf8)
                )
            case let path? where path.hasPrefix("/api/messages/"):
                let conversationID = try recorder.expectedConversationID()
                XCTAssertEqual(path, "/api/messages/\(conversationID)")
                let messageID = try recorder.messageID()
                let body = #"[{"messageId":"\#(messageID)","conversationId":"\#(conversationID)","sender":"User","isCreatedByUser":true,"text":"Hello"}]"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()
        let conversation = Conversation(
            id: ConversationID(rawValue: "new"),
            title: "New chat",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Hello",
            clientRequestID: requestID,
            clientMessageID: messageID
        ))

        guard case let .settled(conversationID) = outcome else {
            return XCTFail("An exact terminal history match must settle without inventing a stream lease")
        }
        XCTAssertEqual(recorder.attemptCount, 3)
        XCTAssertEqual(recorder.uniqueClientRequestIDs, [requestID.uuidString])
        XCTAssertEqual(recorder.uniqueMessageIDs, [messageID.rawValue])
        XCTAssertEqual(conversationID.rawValue, try recorder.expectedConversationID())
        XCTAssertNotEqual(conversationID.rawValue, "new")
    }

    func testAmbiguousNewConversationReattachesOnlyToItsDeterministicActiveRun() async throws {
        let recorder = AmbiguousStartRecorder()
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/agents":
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Self.bodyData(for: request)) as? [String: Any]
                )
                recorder.record(
                    clientRequestID: object["clientRequestId"] as? String,
                    messageID: object["messageId"] as? String
                )
                throw URLError(.networkConnectionLost)
            case let path? where path.hasPrefix("/api/agents/chat/status/"):
                let conversationID = try recorder.expectedConversationID()
                XCTAssertEqual(path, "/api/agents/chat/status/\(conversationID)")
                let body = #"{"active":true,"streamId":"\#(conversationID)","status":"running","createdAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: Conversation(
                id: ConversationID(rawValue: "new"),
                title: "New chat",
                target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
            ),
            text: "Hello"
        ))

        let handle = try XCTUnwrap(outcome.streamingHandle)
        XCTAssertEqual(recorder.attemptCount, 3)
        XCTAssertEqual(handle.conversationID.rawValue, try recorder.expectedConversationID())
        XCTAssertEqual(handle.streamID, handle.conversationID.rawValue)
        XCTAssertEqual(handle.generationCreatedAt, 2_000)
    }

    func testAmbiguousExistingConversationDoesNotAttachAnUnprovenActiveRun() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/convos/conversation":
                let body = #"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent-1"}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case "/api/messages/conversation":
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            case "/api/agents/chat/agents":
                throw URLError(.networkConnectionLost)
            case "/api/agents/chat/status/conversation":
                let body = #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.send(ChatRequest(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversation: Conversation(
                    id: ConversationID(rawValue: "conversation"),
                    title: "Test",
                    target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
                ),
                text: "Do not attach this to another run"
            ))
            XCTFail("An existing conversation needs idempotency proof before attaching an active run")
        } catch let error as LibreChatProtocolError {
            guard case .transport = error else {
                return XCTFail("Expected the original ambiguous transport failure, got \(error)")
            }
        }
    }

    func testAmbiguousFailedGenerationDoesNotBecomeCompleted() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/agents/chat/agents":
                throw URLError(.networkConnectionLost)
            case let path? where path.hasPrefix("/api/agents/chat/status/"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"error","createdAt":2000,"generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let outcome = try await repository.send(ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: Conversation(
                id: ConversationID(rawValue: "new"),
                title: "New chat",
                target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
            ),
            text: "Hello"
        ))
        guard case let .failed(_, failure) = outcome else {
            return XCTFail("An errored terminal receipt must not create a synthetic stream handle")
        }
        XCTAssertEqual(failure.code, "generation_failed")
    }

    func testEveryUnsentConversationHasAUniqueLocalIdentity() async throws {
        let (repository, _) = try await makeRepository()
        let target = ConversationTarget(endpoint: "agents", agentID: "agent-1")

        let first = try await repository.createConversation(title: "First", target: target)
        let second = try await repository.createConversation(title: "Second", target: target)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.isLocalDraft)
        XCTAssertTrue(second.id.isLocalDraft)
        XCTAssertEqual(first.id.serverValue, "new")
        XCTAssertEqual(second.id.serverValue, "new")
    }

    func testTargetDiscoveryWalksSavedAgentPagesAndDeduplicatesAgents() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/endpoints":
                return (Self.response(for: request, status: 200), Data(#"{"openAI":{"type":"openAI"},"agents":{"type":"agents"}}"#.utf8))
            case "/api/models":
                return (Self.response(for: request, status: 200), Data(#"{"openAI":["gpt-native"]}"#.utf8))
            case "/api/config":
                return (Self.response(for: request, status: 200), Data("{}".utf8))
            case "/api/agents":
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "requiredPermission" })?.value, "1")
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "limit" })?.value, "1000")
                let cursor = components.queryItems?.first(where: { $0.name == "cursor" })?.value
                if cursor == nil {
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"object":"list","data":[{"id":"agent-one","name":"One"}],"has_more":true,"after":"opaque==cursor"}"#.utf8)
                    )
                }
                XCTAssertEqual(cursor, "opaque==cursor")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"object":"list","data":[{"id":"agent-one","name":"One duplicate"},{"id":"agent-two","name":"Two"}],"has_more":false,"after":null}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let targets = try await repository.availableChatTargets()

        XCTAssertEqual(targets.filter { $0.target.endpoint == "agents" }.map(\.target.agentID), ["agent-one", "agent-two"])
        XCTAssertTrue(targets.contains { $0.target.endpoint == "openAI" && $0.target.model == "gpt-native" })
    }

    func testTargetCatalogFailsClosedWhenFreshAuthenticatedPolicyFails() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/endpoints":
                return (Self.response(for: request, status: 200), Data(#"{"openAI":{"order":0}}"#.utf8))
            case "/api/models":
                return (Self.response(for: request, status: 200), Data(#"{"openAI":["must-not-escape"]}"#.utf8))
            case "/api/config":
                return (Self.response(for: request, status: 500), Data(#"{"message":"unavailable"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        do {
            _ = try await repository.targetCatalog(recentOptionID: nil)
            XCTFail("A fresh authenticated policy failure must not authorize stale endpoint targets")
        } catch let LibreChatProtocolError.httpStatus(status, _, _) {
            XCTAssertEqual(status, 500)
        }
    }

    func testTargetCatalogChecksNonsecretUserKeyExpiryBeforeExposingEndpoint() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/endpoints":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"bedrock":{"order":0,"userProvideBearerToken":true}}"#.utf8)
                )
            case "/api/models":
                return (Self.response(for: request, status: 200), Data(#"{"bedrock":["nova"]}"#.utf8))
            case "/api/config":
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"modelSelect":true}}"#.utf8))
            case "/api/keys":
                let components = try XCTUnwrap(URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                ))
                XCTAssertEqual(components.queryItems?.first(where: { $0.name == "name" })?.value, "bedrock")
                return (Self.response(for: request, status: 200), Data(#"{"expiresAt":"never"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let snapshot = try await repository.targetCatalog(recentOptionID: nil)

        XCTAssertEqual(snapshot.profileID, ServerProfileID(rawValue: "profile"))
        XCTAssertEqual(snapshot.accountID, AccountID(rawValue: "account"))
        XCTAssertEqual(snapshot.agentDiscoveryStatus, .notSupported)
        XCTAssertEqual(snapshot.options.map(\.id), ["endpoint:bedrock:nova"])
        XCTAssertEqual(snapshot.effectiveDefaultOptionID, "endpoint:bedrock:nova")
    }

    func testTargetCatalogAgentPermissionDenialFailsClosedWithTypedEvidence() async throws {
        RepositoryURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/endpoints":
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"order":0}}"#.utf8))
            case "/api/models":
                return (Self.response(for: request, status: 200), Data(#"{}"#.utf8))
            case "/api/config":
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"modelSpecs":{"enforce":true,"list":[{"name":"ephemeral","preset":{"endpoint":"agents","agent_id":"ephemeral"}}]}}"#.utf8)
                )
            case "/api/agents":
                return (Self.response(for: request, status: 403), Data(#"{"message":"forbidden"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let (repository, _) = try await makeRepository()

        let snapshot = try await repository.targetCatalog(recentOptionID: nil)

        XCTAssertTrue(snapshot.options.isEmpty)
        XCTAssertEqual(snapshot.agentDiscoveryStatus, .permissionDenied)
        XCTAssertTrue(snapshot.warnings.contains(.agentPermissionDenied))
    }

    func testMultipartUploadCarriesLibreChatMessageAttachmentMetadata() throws {
        let upload = PendingUpload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversationID: ConversationID(localDraftID: UUID()),
            localURL: URL(fileURLWithPath: "/tmp/brief.pdf"),
            filename: "brief.pdf",
            mimeType: "application/pdf",
            endpoint: "agents",
            endpointType: "custom",
            width: 640,
            height: 480
        )

        let body = UploadManager.multipartBody(
            fileData: Data("contents".utf8),
            upload: upload,
            boundary: "Boundary"
        )
        let wire = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(wire.contains("name=\"endpoint\"\r\n\r\nagents"))
        XCTAssertTrue(wire.contains("name=\"endpointType\"\r\n\r\ncustom"))
        XCTAssertTrue(wire.contains("name=\"file_id\"\r\n\r\n00000000-0000-0000-0000-000000000123"))
        XCTAssertTrue(wire.contains("name=\"message_file\"\r\n\r\ntrue"))
        XCTAssertTrue(wire.contains("name=\"width\"\r\n\r\n640"))
        XCTAssertTrue(wire.contains("name=\"height\"\r\n\r\n480"))
        XCTAssertFalse(wire.contains("name=\"conversationId\""), "The server placeholder is implicit for a local draft")
        XCTAssertTrue(wire.contains("name=\"file\"; filename=\"brief.pdf\""))
        XCTAssertTrue(wire.contains("Content-Type: application/pdf"))
    }

    func testQueuedUploadUsageBatchesAreStableDeduplicatedAndServerBounded() {
        let ids = (0..<23).map { "file-\($0)" } + ["file-3", "", "file-22"]

        let batches = UploadManager.fileUsageBatches(ids)

        XCTAssertEqual(batches.map(\.count), [10, 10, 3])
        XCTAssertEqual(batches.flatMap { $0 }, (0..<23).map { "file-\($0)" })
    }

    func testQueuedUploadOwnershipPersistsAndTransfersWithoutLosingRemoteFile() async throws {
        RepositoryURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/files/usage")
            return (Self.response(for: request, status: 200), Data(#"{"held":1}"#.utf8))
        }

        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "upload-profile")
        let accountID = AccountID(rawValue: "upload-account")
        let conversationID = ConversationID(rawValue: "upload-conversation")
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let remoteFile = UploadedFile(
            id: "remote-file-321",
            filename: "queued.txt",
            mimeType: "text/plain"
        )
        let upload = PendingUpload(
            id: uploadID,
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            localURL: URL(fileURLWithPath: "/tmp/queued-upload-321.txt"),
            filename: remoteFile.filename,
            mimeType: remoteFile.mimeType,
            endpoint: "agents",
            endpointType: "custom",
            progress: 1,
            state: .completed,
            remoteIdentifier: remoteFile.id,
            remoteFile: remoteFile
        )
        try await dependencies.cache.save(upload: upload)

        let baseURL = URL(string: "https://chat.example.com")!
        let jar = ProfileCookieJar(
            profileID: profileID,
            baseURL: baseURL,
            secretStore: RepositorySecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RepositoryURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let authentication = LibreChatProtocol.AuthSession.isolated(transport: transport)
        await authentication.setAuthenticated(
            AuthenticatedSession(accessToken: "token", user: UserAccount(id: accountID))
        )
        let manager = UploadManager(
            profileID: profileID,
            accountID: accountID,
            runtime: LibreChatRuntime(
                cookieJar: jar,
                transport: transport,
                authSession: authentication,
                restClient: RESTClient(transport: transport, authSession: authentication)
            ),
            cache: dependencies.cache
        )
        await manager.restore()

        try await manager.markQueued(ids: [uploadID], conversationID: conversationID)
        var cached = try await dependencies.cache.uploads(profileID: profileID, accountID: accountID)
        XCTAssertEqual(cached.first?.state, .queued)
        XCTAssertEqual(cached.first?.remoteFile, remoteFile)

        try await manager.markUnqueued(ids: [uploadID], conversationID: conversationID)
        cached = try await dependencies.cache.uploads(profileID: profileID, accountID: accountID)
        XCTAssertEqual(cached.first?.state, .completed)
        XCTAssertEqual(cached.first?.remoteFile, remoteFile)

        try await manager.markQueued(ids: [uploadID], conversationID: conversationID)
        await manager.markAttached(ids: [uploadID], conversationID: conversationID)
        cached = try await dependencies.cache.uploads(profileID: profileID, accountID: accountID)
        XCTAssertEqual(cached.first?.state, .attached)
        XCTAssertEqual(cached.first?.remoteFile, remoteFile)
        await manager.resetAfterCachePurge()
        // The protocol stub's handler is shared static state swapped by the
        // next test; let any already-dispatched callback settle inside this
        // test's handler before yielding the suite.
        try? await Task.sleep(for: .milliseconds(150))
    }

    func testCompatibilityDisabledChatKeepsItsDraftEditableButCannotSend() async {
        let conversation = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: "Offline draft",
            model: "fixture-model",
            target: ConversationTarget(endpoint: "openAI", model: "fixture-model")
        )
        let model = ChatModel(
            conversation: conversation,
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: ChatFeatureRepositoryDouble(
                sendError: LibreChatProtocolError.unsupported("Not used by this test.")
            ),
            uploadManager: nil,
            canGenerate: { false },
            compatibilityWarning: { "This server cannot start generation." },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "Keep working offline"

        XCTAssertTrue(model.canEditDraft)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.generationDisabledReason, "This server cannot start generation.")
    }

    func testComposerExecutionScopeRedactsServerOwnedIdentifiers() async {
        let conversation = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: "Scoped model spec",
            model: "fixture-model",
            target: ConversationTarget(
                endpoint: "agents",
                model: "fixture-model",
                spec: "Research mode",
                ephemeralAgent: EphemeralAgentConfiguration(
                    mcpServers: ["private-connector", "finance-internal"],
                    webSearch: true,
                    fileSearch: true,
                    executeCode: true,
                    memory: true,
                    artifacts: .named("private-artifact-prompt")
                )
            )
        )
        let model = ChatModel(
            conversation: conversation,
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: ChatFeatureRepositoryDouble(
                sendError: LibreChatProtocolError.unsupported("Not used by this test.")
            ),
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()

        XCTAssertEqual(
            model.executionCapabilities,
            [
                "Web search",
                "File search",
                "Code execution",
                "Memory",
                "MCP (2 servers)",
                "Artifacts"
            ]
        )
        XCTAssertFalse(model.executionCapabilities?.joined().contains("private-connector") ?? true)
        XCTAssertFalse(model.executionCapabilities?.joined().contains("private-artifact-prompt") ?? true)

        let unsafeModel = ChatModel(
            conversation: Conversation(
                id: ConversationID(localDraftID: UUID()),
                title: "Unsafe model spec",
                model: "fixture-model",
                target: ConversationTarget(
                    endpoint: "agents",
                    model: "fixture-model",
                    spec: "Unsafe mode",
                    ephemeralAgent: EphemeralAgentConfiguration(
                        mcpServers: ["unsafe\u{0000}connector"],
                        webSearch: true
                    )
                )
            ),
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: ChatFeatureRepositoryDouble(
                sendError: LibreChatProtocolError.unsupported("Not used by this test.")
            ),
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await unsafeModel.loadIfNeeded()
        XCTAssertNil(unsafeModel.executionCapabilities)
    }

    func testStreamingChatKeepsComposerEditableAndPersistsNextMessageWithoutSecondPost() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let conversation = Conversation(
            id: conversationID,
            title: "Queue test",
            model: "fixture-model",
            target: ConversationTarget(
                endpoint: "agents",
                model: "fixture-model",
                agentID: "agent"
            )
        )
        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: conversationID.rawValue,
            conversationID: conversationID,
            generationCreatedAt: 1_000,
            protocolVersion: 2
        )
        let streaming = GenerationSnapshot(
            handle: handle,
            state: .streaming,
            response: ChatMessage(
                id: MessageID(rawValue: "assistant-streaming"),
                conversationID: conversationID,
                parentMessageID: MessageID(rawValue: "server-user-1"),
                content: [.text("Working")],
                author: .assistant(name: "Assistant"),
                isUnfinished: true
            )
        )
        let repository = ChatFeatureRepositoryDouble(
            sendOutcome: .streaming(handle),
            streamSnapshots: [handle: [streaming]],
            keepsStreamsOpen: true
        )
        let namespace = try FollowUpQueueNamespace(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        await repository.seedFollowUpQueue(try FollowUpQueueSnapshot(namespace: namespace))
        let model = ChatModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "First prompt"
        model.draftChanged()
        model.send()
        for _ in 0..<1_000 {
            if model.generationSnapshot?.handle == handle { break }
            await Task.yield()
        }

        XCTAssertTrue(model.isStreaming)
        XCTAssertTrue(model.canEditDraft)
        model.draft = "Follow up after this response"
        model.draftChanged()
        XCTAssertTrue(model.canQueueFollowUp)
        model.queueDraftFollowUp()
        for _ in 0..<1_000 {
            if model.activeFollowUpItems.count == 1 { break }
            await Task.yield()
        }

        XCTAssertEqual(model.activeFollowUpItems.map(\.text), ["Follow up after this response"])
        XCTAssertEqual(model.draft, "")
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1, "Queueing must persist locally without posting another generation")

        await repository.finishStreams()
    }

    func testChatModelRestoresDraftWhenGenerationOwnershipConflicts() async {
        let repository = ChatFeatureRepositoryDouble(
            sendError: LibreChatProtocolError.generationConflict(
                GenerationConflictDetails(
                    code: "GENERATION_PREDECESSOR_MISMATCH",
                    status: "predecessor_mismatch",
                    streamID: "conversation",
                    conversationID: "conversation",
                    generationCreatedAt: 2_000,
                    predecessorVerified: true,
                    active: true
                )
            )
        )
        let conversation = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: "New chat",
            target: ConversationTarget(endpoint: "agents", agentID: "agent")
        )
        let model = ChatModel(
            conversation: conversation,
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "Keep this message"

        model.send()

        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.draft, "Keep this message")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            "A newer response already owns this conversation. Your message was not sent."
        )
    }

    func testChatModelAdoptsProvenWinnerRestoresAndPersistsDraftWithoutResending() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let winner = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let completed = GenerationSnapshot(handle: winner, state: .completed)
        let repository = ChatFeatureRepositoryDouble(
            sendOutcome: .handoff(winner),
            reconciliations: [winner: GenerationSnapshot(handle: winner, state: .streaming)],
            streamSnapshots: [winner: [completed]]
        )
        let model = ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Test",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "Keep this unsent draft"
        model.send()

        for _ in 0..<1_000 {
            let resumed = await repository.resumedGenerationHandles()
            let streamed = await repository.streamedGenerationHandles()
            if resumed == [winner], streamed == [winner], !model.isStreaming { break }
            await Task.yield()
        }

        let sendCount = await repository.sendCount()
        let savedDraft = await repository.savedDraft(conversationID: conversationID)
        let resumedHandles = await repository.resumedGenerationHandles()
        let streamedHandles = await repository.streamedGenerationHandles()
        XCTAssertEqual(sendCount, 1)
        XCTAssertEqual(model.draft, "Keep this unsent draft")
        XCTAssertEqual(savedDraft, "Keep this unsent draft")
        XCTAssertEqual(resumedHandles, [winner])
        XCTAssertEqual(streamedHandles, [winner])
        XCTAssertFalse(model.messages.contains { $0.id.rawValue.hasPrefix("local-") })
        XCTAssertNil(model.errorMessage)
    }

    func testChatModelTerminalWinnerHandoffReloadsWithoutOpeningSSE() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let winner = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let authoritative = ChatMessage(
            id: MessageID(rawValue: "server-assistant"),
            conversationID: conversationID,
            content: [.text("Already finished")],
            author: .assistant(name: "Assistant")
        )
        let repository = ChatFeatureRepositoryDouble(
            sendOutcome: .handoff(winner),
            serverMessages: [authoritative],
            reconciliations: [winner: GenerationSnapshot(handle: winner, state: .completed)]
        )
        let model = ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Test",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "Keep this unsent draft"
        model.send()

        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        XCTAssertEqual(model.messages, [authoritative])
        XCTAssertEqual(model.draft, "Keep this unsent draft")
        let resumedHandles = await repository.resumedGenerationHandles()
        let streamedHandles = await repository.streamedGenerationHandles()
        XCTAssertTrue(resumedHandles.isEmpty)
        XCTAssertTrue(streamedHandles.isEmpty)
    }

    func testChatModelKeepsProvenWinnerRecoverableAfterTransientHandoffReconcileFailure() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let winner = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let repository = ChatFeatureRepositoryDouble(
            sendOutcome: .handoff(winner),
            reconciliationError: .transport("offline")
        )
        let model = ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Test",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "Keep this unsent draft"
        model.send()

        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }
        XCTAssertEqual(model.generationSnapshot?.handle, winner)
        XCTAssertEqual(model.generationSnapshot?.state, .reconciling)
        model.retryRecovery()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
        let resumedHandles = await repository.resumedGenerationHandles()
        XCTAssertEqual(resumedHandles, [winner])
        XCTAssertEqual(model.draft, "Keep this unsent draft")
    }

    @MainActor
    func testChatModelSettledReceiptPromotesLocalConversationAndUsesAuthoritativeHistory() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let localConversationID = ConversationID(localDraftID: UUID())
        let canonicalConversationID = ConversationID(rawValue: "canonical-conversation")
        let history = [
            ChatMessage(
                id: MessageID(rawValue: "server-user"),
                conversationID: canonicalConversationID,
                content: [.text("Claimed message")],
                author: .user
            ),
            ChatMessage(
                id: MessageID(rawValue: "server-assistant"),
                conversationID: canonicalConversationID,
                content: [.text("Authoritative reply")],
                author: .assistant(name: "Assistant")
            )
        ]
        let repository = ChatFeatureRepositoryDouble(
            sendOutcome: .settled(conversationID: canonicalConversationID),
            serverMessages: history
        )
        var identityChanges: [(previous: ConversationID, updated: ConversationID)] = []
        let model = ChatModel(
            conversation: Conversation(
                id: localConversationID,
                title: "New chat",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { previous, updated in
                identityChanges.append((previous: previous, updated: updated.id))
            }
        )
        await model.loadIfNeeded()
        model.draft = "Claimed message"
        model.send()

        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.conversation.id, canonicalConversationID)
        XCTAssertEqual(identityChanges.first?.previous, localConversationID)
        XCTAssertEqual(identityChanges.first?.updated, canonicalConversationID)
        XCTAssertEqual(identityChanges.last?.previous, canonicalConversationID)
        XCTAssertEqual(identityChanges.last?.updated, canonicalConversationID)
        XCTAssertEqual(model.messages, history)
        XCTAssertFalse(model.messages.contains { $0.id.rawValue.hasPrefix("local-assistant-") })
    }

    @MainActor
    func testChatModelSettledReceiptNeverRestoresDraftWhenHistoryRefreshIsTransientlyUnavailable() async {
        let localConversationID = ConversationID(localDraftID: UUID())
        let canonicalConversationID = ConversationID(rawValue: "canonical-conversation")
        let repository = ChatFeatureRepositoryDouble(
            sendOutcome: .settled(conversationID: canonicalConversationID),
            messagesError: .transport("offline")
        )
        let model = ChatModel(
            conversation: Conversation(
                id: localConversationID,
                title: "New chat",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
        await model.loadIfNeeded()
        model.draft = "Do not repost this"
        model.send()

        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.conversation.id, canonicalConversationID)
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertFalse(model.messages.contains { $0.id.rawValue.hasPrefix("local-assistant-") })
        XCTAssertTrue(
            model.errorMessage?.contains("Authoritative conversation history is unavailable") == true
        )
    }

    func testChatModelInvalidResumeAcknowledgementDoesNotPermitASecondSubmissionWhenStatusIsUnavailable() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            interactionError: .invalidResponse,
            reconciliationError: .transport("status unavailable")
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("may have received") == true { break }
            await Task.yield()
        }
        model.respondToInteraction(answer: "Yes")
        for _ in 0..<20 { await Task.yield() }

        let responseCount = await repository.interactionResponseCount()
        XCTAssertEqual(responseCount, 1)
        XCTAssertTrue(model.isRespondingToInteraction)
        XCTAssertEqual(model.generationSnapshot?.handle, handle)
        XCTAssertEqual(model.generationSnapshot?.pendingInteraction, interaction)
    }

    func testArtifactEditingRemainsReadOnlyWhileGenerationAwaitsApproval() async throws {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Which version should I use?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let rawArtifact = """
        :::artifact{identifier="notes" type="text/plain" title="Notes"}
        Current content
        :::
        """
        let artifact = try XCTUnwrap(
            ArtifactParser.parse(
                messageID: MessageID(rawValue: "assistant"),
                text: rawArtifact
            ).artifacts.first
        )
        let root = ChatMessage(
            id: MessageID(rawValue: "root"),
            conversationID: handle.conversationID,
            content: [.text("Build an artifact")],
            author: .user
        )
        let assistant = ChatMessage(
            id: artifact.identity.messageID,
            conversationID: handle.conversationID,
            parentMessageID: root.id,
            content: [.text(rawArtifact)],
            author: .assistant(name: "Assistant"),
            isUnfinished: false,
            artifactCatalog: [artifact]
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            reconciliations: [handle: pending],
            resumeFailure: .transport("stream unavailable"),
            resumeFailureCall: 1,
            serverMessages: [root, assistant]
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        XCTAssertEqual(model.generationSnapshot?.pendingInteraction, interaction)
        XCTAssertFalse(model.isStreaming)
        XCTAssertFalse(model.canEditArtifacts(in: assistant.id))
        do {
            try await model.editArtifact(artifact, updatedContent: "Unsafe update\n")
            XCTFail("A paused generation must retain exclusive artifact mutation ownership")
        } catch let error as ArtifactEditError {
            XCTAssertEqual(error, .unavailable)
        }
        let updateCount = await repository.artifactUpdateCount()
        XCTAssertEqual(updateCount, 0)
    }

    func testChatModelInteractionSubmissionUsesTheCompleteOwnedHandleWhenActionIDsCollide() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let owned = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let foreign = GenerationHandle(
            profileID: profileID,
            accountID: AccountID(rawValue: "other-account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 3_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "same-action", prompt: "Continue?")
        )
        let ownedPending = GenerationSnapshot(
            handle: owned,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let foreignPending = GenerationSnapshot(
            handle: foreign,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [foreignPending, ownedPending],
            reconciliations: [owned: ownedPending]
        )
        let model = makeInteractionChatModel(handle: owned, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<100 {
            if await repository.interactionResponseCount() == 1 { break }
            await Task.yield()
        }

        let submittedHandles = await repository.interactionResponseHandles()
        XCTAssertEqual(submittedHandles, [owned])
        XCTAssertFalse(submittedHandles.contains(foreign))
    }

    func testChatModelUnauthorizedInteractionResponseInvokesSessionExpiryPolicy() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            interactionError: .unauthorized,
            reconciliations: [handle: pending]
        )
        var unauthorizedCount = 0
        let model = makeInteractionChatModel(
            handle: handle,
            repository: repository,
            onUnauthorized: { unauthorizedCount += 1 }
        )
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<100 {
            if unauthorizedCount == 1 { break }
            await Task.yield()
        }

        let responseCount = await repository.interactionResponseCount()
        XCTAssertEqual(responseCount, 1)
        XCTAssertEqual(unauthorizedCount, 1)
        XCTAssertFalse(model.isRespondingToInteraction)
    }

    func testChatModelAcknowledgedInteractionAttachFailureStaysRecoverableWithoutReposting() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            reconciliations: [handle: pending],
            resumeFailure: .transport("stream unavailable"),
            resumeFailureCall: 2
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("response was submitted") == true { break }
            await Task.yield()
        }

        let responsesAfterFailure = await repository.interactionResponseCount()
        let resumesAfterFailure = await repository.resumedGenerationHandles()
        XCTAssertEqual(responsesAfterFailure, 1)
        XCTAssertEqual(resumesAfterFailure, [handle, handle])
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)

        model.respondToInteraction(answer: "Yes")
        model.retryRecovery()
        for _ in 0..<100 {
            if await repository.resumedGenerationHandles().count == 3 { break }
            await Task.yield()
        }

        let responsesAfterRecovery = await repository.interactionResponseCount()
        XCTAssertEqual(responsesAfterRecovery, 1, "Recovery must reopen the stream without repeating the consumed response")
    }

    func testChatModelAcknowledgedInteractionAttachCancellationStaysRecoverableWithoutReposting() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            reconciliations: [handle: pending],
            resumeCancellationCall: 2
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("response was submitted") == true { break }
            await Task.yield()
        }

        let responseCount = await repository.interactionResponseCount()
        XCTAssertEqual(responseCount, 1)
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)

        model.respondToInteraction(answer: "Yes")
        model.retryRecovery()
        for _ in 0..<100 {
            if await repository.resumedGenerationHandles().count == 3 { break }
            await Task.yield()
        }
        let responseCountAfterRecovery = await repository.interactionResponseCount()
        XCTAssertEqual(responseCountAfterRecovery, 1)
    }

    func testChatModelAcknowledgedInteractionStreamCancellationStaysRecoverableWithoutReposting() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            reconciliations: [handle: pending],
            streamCancellationCall: 2
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("response was submitted") == true { break }
            await Task.yield()
        }

        let responseCountAfterSubmission = await repository.interactionResponseCount()
        XCTAssertEqual(responseCountAfterSubmission, 1)
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)

        model.respondToInteraction(answer: "Yes")
        model.retryRecovery()
        for _ in 0..<100 {
            if await repository.resumedGenerationHandles().count == 3 { break }
            await Task.yield()
        }
        let responseCountAfterRetry = await repository.interactionResponseCount()
        XCTAssertEqual(responseCountAfterRetry, 1)
    }

    func testChatModelAcknowledgedInteractionResume401ClearsPendingWithoutReposting() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            reconciliations: [handle: pending],
            resumeFailure: .unauthorized,
            resumeFailureCall: 2
        )
        var unauthorizedCount = 0
        let model = makeInteractionChatModel(
            handle: handle,
            repository: repository,
            onUnauthorized: { unauthorizedCount += 1 }
        )
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if unauthorizedCount == 1 { break }
            await Task.yield()
        }

        let responseCount = await repository.interactionResponseCount()
        let resumedHandles = await repository.resumedGenerationHandles()
        XCTAssertEqual(responseCount, 1)
        XCTAssertEqual(resumedHandles, [handle, handle])
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(unauthorizedCount, 1)
    }

    func testChatModelAmbiguousAcknowledgementWithConsumedStatusNeverRestoresOrRepostsAction() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let consumed = GenerationSnapshot(handle: handle, state: .streaming)
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            interactionError: .invalidResponse,
            reconciliationSequence: [handle: [pending, consumed]],
            resumeFailure: .transport("stream unavailable"),
            resumeFailureCall: 2
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("response was submitted") == true { break }
            await Task.yield()
        }

        let responsesAfterFailure = await repository.interactionResponseCount()
        XCTAssertEqual(responsesAfterFailure, 1)
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)

        model.respondToInteraction(answer: "Yes")
        model.retryRecovery()
        for _ in 0..<100 {
            if await repository.resumedGenerationHandles().count == 3 { break }
            await Task.yield()
        }

        let responsesAfterRecovery = await repository.interactionResponseCount()
        XCTAssertEqual(responsesAfterRecovery, 1, "Authoritative consumed status must prevent any second response POST")
    }

    func testChatModelAmbiguousConsumedInteractionAttachCancellationStaysRecoverable() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let consumed = GenerationSnapshot(handle: handle, state: .streaming)
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            interactionError: .invalidResponse,
            reconciliationSequence: [handle: [pending, consumed]],
            resumeCancellationCall: 2
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("response was submitted") == true { break }
            await Task.yield()
        }

        let responseCount = await repository.interactionResponseCount()
        XCTAssertEqual(responseCount, 1)
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)

        model.respondToInteraction(answer: "Yes")
        model.retryRecovery()
        for _ in 0..<100 {
            if await repository.resumedGenerationHandles().count == 3 { break }
            await Task.yield()
        }
        let responseCountAfterRecovery = await repository.interactionResponseCount()
        XCTAssertEqual(responseCountAfterRecovery, 1)
    }

    func testChatModelAmbiguousConsumedInteractionStreamCancellationStaysRecoverable() async {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        let pending = GenerationSnapshot(
            handle: handle,
            state: .awaitingApproval(interaction),
            pendingInteraction: interaction
        )
        let consumed = GenerationSnapshot(handle: handle, state: .streaming)
        let repository = ChatFeatureRepositoryDouble(
            recoverableSnapshots: [pending],
            interactionError: .invalidResponse,
            reconciliationSequence: [handle: [pending, consumed]],
            streamCancellationCall: 2
        )
        let model = makeInteractionChatModel(handle: handle, repository: repository)
        await model.loadIfNeeded()
        for _ in 0..<100 {
            if !model.isStreaming { break }
            await Task.yield()
        }

        model.respondToInteraction(answer: "Yes")
        for _ in 0..<200 {
            if model.errorMessage?.contains("response was submitted") == true { break }
            await Task.yield()
        }

        let responseCountAfterSubmission = await repository.interactionResponseCount()
        XCTAssertEqual(responseCountAfterSubmission, 1)
        XCTAssertNil(model.generationSnapshot?.pendingInteraction)
        XCTAssertFalse(model.isRespondingToInteraction)
        XCTAssertFalse(model.isStreaming)

        model.respondToInteraction(answer: "Yes")
        model.retryRecovery()
        for _ in 0..<100 {
            if await repository.resumedGenerationHandles().count == 3 { break }
            await Task.yield()
        }
        let responseCountAfterRetry = await repository.interactionResponseCount()
        XCTAssertEqual(responseCountAfterRetry, 1)
    }

    func testVisibleChatAutomaticallyConsumesForegroundRecoveryOnce() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let response = ChatMessage(
            id: MessageID(rawValue: "assistant"),
            conversationID: conversationID,
            content: [.text("Recovered response")],
            author: .assistant(name: "Assistant")
        )
        let reconciled = GenerationSnapshot(handle: handle, state: .reconciling, response: response)
        let completed = GenerationSnapshot(handle: handle, state: .completed, response: response)
        let repository = ForegroundRecoveryRepositoryDouble(
            messagePages: [[], [response]],
            streams: [handle: [completed]]
        )
        let model = makeForegroundRecoveryChatModel(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            repository: repository
        )
        await model.loadIfNeeded()
        let signal = GenerationRecoverySignal(
            sequence: 1,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [reconciled]
        )

        await model.applyForegroundGenerationRecovery(signal)
        await model.applyForegroundGenerationRecovery(signal)

        let resumedHandles = await repository.resumedGenerationHandles()
        let streamedHandles = await repository.streamedGenerationHandles()
        XCTAssertEqual(resumedHandles, [handle])
        XCTAssertEqual(streamedHandles, [handle])
        XCTAssertEqual(model.generationSnapshot?.state, .completed)
        XCTAssertEqual(model.messages, [response])
        XCTAssertFalse(model.isStreaming)
    }

    func testForegroundRecoveryRefreshesReconciledQueueAndHistoryWithoutActiveGeneration() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let namespace = try FollowUpQueueNamespace(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let sourceHandle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 1_000,
            protocolVersion: 2
        )
        let item = try FollowUpQueueItem(
            id: FollowUpQueueItemID(),
            namespace: namespace,
            order: FollowUpQueueOrder(rawValue: 1),
            text: "Saved follow-up",
            target: FollowUpTargetFingerprint(
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            sourceAnchor: FollowUpSourceAnchor(
                handle: sourceHandle,
                sourceUserMessageID: MessageID(rawValue: "source-user")
            )
        )
        let initialQueue = try FollowUpQueueSnapshot(namespace: namespace, items: [item])
        var updatedReducer = FollowUpQueueReducer(snapshot: initialQueue)
        try updatedReducer.block(itemID: item.id, reason: .requiresUserReview)
        let updatedQueue = updatedReducer.snapshot
        let source = ChatMessage(
            id: MessageID(rawValue: "source-user"),
            conversationID: conversationID,
            content: [.text("Source")],
            author: .user
        )
        let durable = ChatMessage(
            id: MessageID(rawValue: "durable-user"),
            conversationID: conversationID,
            parentMessageID: source.id,
            content: [.text("Saved follow-up")],
            author: .user
        )
        let repository = ForegroundRecoveryRepositoryDouble(
            messagePages: [[source], [source, durable]],
            followUpSnapshots: [initialQueue, updatedQueue]
        )
        let model = makeForegroundRecoveryChatModel(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            repository: repository
        )
        await model.loadIfNeeded()

        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 1,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: []
        ))

        XCTAssertEqual(model.followUpQueue, updatedQueue)
        XCTAssertEqual(model.messages, [source, durable])
        let resumed = await repository.resumedGenerationHandles()
        XCTAssertTrue(resumed.isEmpty)
    }

    func testForegroundRecoveryFencesProfileAccountConversationAndExactActiveHandle() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let activeHandle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let replacementHandle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 3_000,
            protocolVersion: 2
        )
        let active = GenerationSnapshot(handle: activeHandle, state: .reconciling)
        let replacement = GenerationSnapshot(handle: replacementHandle, state: .reconciling)
        let terminal = GenerationSnapshot(handle: activeHandle, state: .completed)
        let repository = ForegroundRecoveryRepositoryDouble(
            streams: [activeHandle: []],
            reconciliations: [activeHandle: terminal]
        )
        let model = makeForegroundRecoveryChatModel(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            repository: repository
        )
        await model.loadIfNeeded()

        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 1,
            profileID: ServerProfileID(rawValue: "other-profile"),
            accountID: accountID,
            activeSnapshots: [active]
        ))
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 2,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [GenerationSnapshot(handle: GenerationHandle(
                profileID: profileID,
                accountID: AccountID(rawValue: "other-account"),
                clientRequestID: UUID(),
                streamID: "conversation",
                conversationID: conversationID,
                generationCreatedAt: 2_000,
                protocolVersion: 2
            ))]
        ))
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 3,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [GenerationSnapshot(handle: GenerationHandle(
                profileID: profileID,
                accountID: accountID,
                clientRequestID: UUID(),
                streamID: "other-conversation",
                conversationID: ConversationID(rawValue: "other-conversation"),
                generationCreatedAt: 2_000,
                protocolVersion: 2
            ))]
        ))
        var resumedHandles = await repository.resumedGenerationHandles()
        XCTAssertTrue(resumedHandles.isEmpty)

        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 4,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [active]
        ))
        resumedHandles = await repository.resumedGenerationHandles()
        XCTAssertEqual(resumedHandles, [activeHandle])
        XCTAssertFalse(model.isStreaming)

        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 5,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [replacement]
        ))

        resumedHandles = await repository.resumedGenerationHandles()
        let reconciledHandles = await repository.reconciledGenerationHandles()
        XCTAssertEqual(resumedHandles, [activeHandle])
        XCTAssertEqual(reconciledHandles, [activeHandle])
        XCTAssertEqual(model.generationSnapshot?.state, .completed)
        XCTAssertFalse(model.isStreaming)
    }

    func testConnectivityRecoveryGateOnlyEmitsOfflineToOnlineEdges() {
        var gate = ConnectivityRecoveryGate()

        XCTAssertFalse(gate.receivesPath(reachable: true))
        XCTAssertFalse(gate.receivesPath(reachable: true))
        XCTAssertFalse(gate.receivesPath(reachable: false))
        XCTAssertFalse(gate.receivesPath(reachable: false))
        XCTAssertTrue(gate.receivesPath(reachable: true))
        XCTAssertFalse(gate.receivesPath(reachable: true))
        XCTAssertFalse(gate.receivesPath(reachable: false))
        XCTAssertTrue(gate.receivesPath(reachable: true))
    }

    func testConnectivityRecoveryRequiresExactOwnedHandleAndRetriesOncePerSignal() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let replacementHandle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: 3_000,
            protocolVersion: 2
        )
        let recoverable = GenerationSnapshot(handle: handle, state: .reconciling)
        let repository = ForegroundRecoveryRepositoryDouble(streams: [handle: []])
        let model = makeForegroundRecoveryChatModel(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            repository: repository
        )
        await model.loadIfNeeded()

        // Foreground recovery establishes the visible model's exact handle.
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 1,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [recoverable]
        ))

        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 2,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [GenerationSnapshot(handle: replacementHandle, state: .reconciling)],
            trigger: .connectivity
        ))
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 3,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [GenerationSnapshot(handle: handle, state: .completed)],
            trigger: .connectivity
        ))
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 4,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [recoverable],
            trigger: .connectivity
        ))
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 4,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [recoverable],
            trigger: .connectivity
        ))
        await model.applyForegroundGenerationRecovery(GenerationRecoverySignal(
            sequence: 5,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [recoverable],
            trigger: .connectivity
        ))

        let resumedHandles = await repository.resumedGenerationHandles()
        XCTAssertEqual(resumedHandles, [handle, handle, handle])
        XCTAssertFalse(model.isStreaming)
    }

    private func makeForegroundRecoveryChatModel(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        repository: any ChatFeatureRepository
    ) -> ChatModel {
        ChatModel(
            conversation: Conversation(id: conversationID, title: "Conversation"),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: { _, _ in }
        )
    }

    func testPersistentCacheFailureEntersExplicitDegradedState() {
        struct InjectedPersistentStoreFailure: Error {}

        let dependencies = AppDependencies.live { _, _ in
            throw InjectedPersistentStoreFailure()
        }
        let model = AppModel(dependencies: dependencies)

        XCTAssertEqual(
            dependencies.cacheHealth,
            .degraded(.persistentStoreUnavailable)
        )
        XCTAssertNotNil(dependencies.cacheHealth.repairNotice)
        XCTAssertEqual(model.cacheHealth, dependencies.cacheHealth)
        XCTAssertNotNil(model.cacheRepairNotice)
        XCTAssertFalse(model.cacheRepairNotice?.contains("/") == true)
        XCTAssertFalse(dependencies.cacheHealth.allowsUserInitiatedClear)
    }

    func testPersistentCacheFailureIsRepairedByDiscardingTheStoreOnce() throws {
        struct InjectedPersistentStoreFailure: Error {}
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatCacheRepair-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "cache.store")
        // A stale write-ahead sidecar must not survive the repair.
        XCTAssertTrue(
            FileManager.default.createFile(atPath: storeURL.path + "-wal", contents: Data([0x1])),
            "The repair test needs a pre-existing sidecar to prove discarding"
        )

        var attempts = 0
        let dependencies = AppDependencies.live(
            persistentContainerFactory: { schema, _ in
                attempts += 1
                if attempts == 1 { throw InjectedPersistentStoreFailure() }
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
                )
            },
            storeURL: storeURL
        )

        XCTAssertEqual(
            attempts,
            2,
            "The store must be discarded and rebuilt exactly once before degrading"
        )
        XCTAssertEqual(dependencies.cacheHealth, .healthyPersistent)
        XCTAssertNil(AppModel(dependencies: dependencies).cacheRepairNotice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path + "-wal"))
    }

    func testV1PersistentCacheRoundTripsAcrossContainerReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatCacheRoundTrip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "cache.store")
        let profileID = ServerProfileID(rawValue: "round-trip-profile")
        let accountID = AccountID(rawValue: "round-trip-account")
        let conversationID = ConversationID(rawValue: "round-trip-conversation")
        let profile = ServerProfile(
            id: profileID,
            baseURL: try XCTUnwrap(URL(string: "https://cache.example.com")),
            displayName: "Cache test",
            accountIdentifier: accountID,
            capabilities: ServerCapabilities(generation: .resumable(version: 2))
        )
        let account = UserAccount(
            id: accountID,
            name: "Cache User",
            email: "cache@example.com"
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let conversation = Conversation(
            id: conversationID,
            title: "Persistent conversation",
            model: "test-model",
            updatedAt: fetchedAt
        )
        let message = ChatMessage(
            id: MessageID(rawValue: "round-trip-message"),
            conversationID: conversationID,
            content: [.text("Persisted response")],
            author: .assistant(name: "Assistant"),
            createdAt: fetchedAt
        )
        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "round-trip-stream",
            conversationID: conversationID,
            generationCreatedAt: 1_725_000_001_000,
            protocolVersion: 2
        )
        let snapshot = GenerationSnapshot(
            handle: handle,
            state: .reconciling,
            response: message,
            updatedAt: fetchedAt
        )
        let upload = PendingUpload(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            localURL: directory.appending(path: "staged.txt"),
            filename: "staged.txt",
            mimeType: "text/plain",
            progress: 0.25,
            state: .uploading
        )

        var writer: AppDependencies? = try AppDependencies(storeURL: storeURL)
        XCTAssertEqual(writer?.cacheHealth, .healthyPersistent)
        try await writer?.cache.save(profile: profile, selected: true)
        try await writer?.cache.saveAccount(profileID: profileID, account: account)
        try await writer?.cache.save(
            page: ConversationPage(
                conversations: [conversation],
                fetchedAt: fetchedAt,
                isFromCache: false
            ),
            profileID: profileID,
            accountID: accountID,
            completeSynchronization: true
        )
        try await writer?.cache.save(
            messages: [message],
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        try await writer?.cache.saveDraft(
            "Persistent draft",
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        try await writer?.cache.save(snapshot)
        try await writer?.cache.save(upload: upload)
        writer = nil

        let reader = try AppDependencies(storeURL: storeURL)
        let reopenedProfiles = try await reader.cache.profiles()
        let reopenedAccount = try await reader.cache.lastVerifiedAccount(
            profileID: profileID,
            accountID: accountID
        )
        let reopenedPage = try await reader.cache.conversations(
            profileID: profileID,
            accountID: accountID,
            limit: 20
        )
        let reopenedMessages = try await reader.cache.messages(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let reopenedDraft = try await reader.cache.draft(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let reopenedGenerations = try await reader.cache.recoverableGenerations(
            profileID: profileID,
            accountID: accountID
        )
        let reopenedUploads = try await reader.cache.uploads(
            profileID: profileID,
            accountID: accountID
        )

        XCTAssertEqual(reopenedProfiles, [profile])
        XCTAssertEqual(reopenedAccount, account)
        XCTAssertEqual(reopenedPage?.conversations, [conversation])
        XCTAssertEqual(reopenedMessages, [message])
        XCTAssertEqual(reopenedDraft, "Persistent draft")
        XCTAssertEqual(reopenedGenerations, [snapshot])
        XCTAssertEqual(reopenedUploads, [upload])
    }

    func testTerminalSteerAcknowledgementSurvivesReopenAndNilEpochKeyCollisions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatSteerRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "cache.store")
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let handleA = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: nil,
            protocolVersion: 2
        )
        let handleB = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: conversationID,
            generationCreatedAt: nil,
            protocolVersion: 2
        )
        let first = PendingSteer(id: "server-a1", clientSteerID: "client-a1", text: "First")
        let second = PendingSteer(id: "server-a2", clientSteerID: "client-a2", text: "Second")
        let sibling = PendingSteer(id: "server-b", clientSteerID: "client-b", text: "Sibling")

        var writer: AppDependencies? = try AppDependencies(storeURL: storeURL)
        try await writer?.cache.save(GenerationSnapshot(
            handle: handleA,
            state: .completed,
            recoverableSteers: [first, second]
        ))
        try await writer?.cache.save(GenerationSnapshot(
            handle: handleB,
            state: .aborted,
            recoverableSteers: [sibling]
        ))
        writer = nil

        var reader: AppDependencies? = try AppDependencies(storeURL: storeURL)
        let reopened = try await reader?.cache.terminalSteerRecoveries(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertEqual(Set(reopened?.map(\.handle) ?? []), Set([handleA, handleB]))
        let reopenedActive = try await reader?.cache.recoverableGenerations(
            profileID: profileID,
            accountID: accountID
        )
        XCTAssertTrue(reopenedActive?.isEmpty == true)

        let incompleteIdentity = try await reader?.cache.acknowledgeTerminalSteers(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            handle: handleA,
            identities: [.init(id: first.id)]
        )
        XCTAssertEqual(incompleteIdentity?.steers, [first, second])
        let partial = try await reader?.cache.acknowledgeTerminalSteers(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            handle: handleA,
            identities: [first.recoveryIdentity]
        )
        XCTAssertEqual(partial?.steers, [second])
        let duplicate = try await reader?.cache.acknowledgeTerminalSteers(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            handle: handleA,
            identities: [first.recoveryIdentity]
        )
        XCTAssertEqual(duplicate?.steers, [second])
        reader = nil

        let secondReader = try AppDependencies(storeURL: storeURL)
        let afterSecondReopen = try await secondReader.cache.terminalSteerRecoveries(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: afterSecondReopen.map { ($0.handle, $0.steers.map(\.id)) }),
            [handleA: ["server-a2"], handleB: ["server-b"]]
        )

        let fullyAcknowledged = try await secondReader.cache.acknowledgeTerminalSteers(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            handle: handleA,
            identities: [second.recoveryIdentity]
        )
        XCTAssertNil(fullyAcknowledged)
        let remaining = try await secondReader.cache.terminalSteerRecoveries(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertEqual(remaining.map(\.handle), [handleB])
    }

    func testTerminalSteerRecoveryAcknowledgementIsNamespaceAndHandleIsolated() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        let contexts: [(ServerProfileID, AccountID, String)] = [
            (.init(rawValue: "profile"), .init(rawValue: "account"), "target"),
            (.init(rawValue: "profile"), .init(rawValue: "account-sibling"), "sibling-account"),
            (.init(rawValue: "profile-sibling"), .init(rawValue: "account"), "sibling-profile")
        ]
        var handles: [GenerationHandle] = []
        for (profileID, accountID, steerID) in contexts {
            let handle = GenerationHandle(
                profileID: profileID,
                accountID: accountID,
                clientRequestID: UUID(),
                streamID: "conversation",
                conversationID: conversationID,
                generationCreatedAt: 10,
                protocolVersion: 2
            )
            handles.append(handle)
            try await dependencies.cache.save(GenerationSnapshot(
                handle: handle,
                state: .completed,
                recoverableSteers: [PendingSteer(id: steerID, text: steerID)]
            ))
        }

        do {
            _ = try await dependencies.cache.acknowledgeTerminalSteers(
                profileID: handles[0].profileID,
                accountID: handles[0].accountID,
                conversationID: .init(rawValue: "another-conversation"),
                handle: handles[0],
                identities: [.init(id: "target")]
            )
            XCTFail("A mismatched conversation must fail closed")
        } catch let error as RecoverableSteerError {
            XCTAssertEqual(error, .contextMismatch)
        }

        _ = try await dependencies.cache.acknowledgeTerminalSteers(
            profileID: handles[0].profileID,
            accountID: handles[0].accountID,
            conversationID: conversationID,
            handle: handles[0],
            identities: [.init(id: "target")]
        )
        for handle in handles.dropFirst() {
            let batches = try await dependencies.cache.terminalSteerRecoveries(
                profileID: handle.profileID,
                accountID: handle.accountID,
                conversationID: conversationID
            )
            XCTAssertEqual(batches.map(\.handle), [handle])
        }
    }

    func testLegacyNilEpochGenerationRecordKeyRemainsExactlyReadableAndRemovable() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let handle = GenerationHandle(
            profileID: .init(rawValue: "legacy-profile"),
            accountID: .init(rawValue: "legacy-account"),
            clientRequestID: UUID(),
            streamID: "legacy-stream",
            conversationID: .init(rawValue: "legacy-conversation"),
            generationCreatedAt: nil,
            protocolVersion: 2
        )
        let snapshot = GenerationSnapshot(
            handle: handle,
            state: .completed,
            recoverableSteers: [PendingSteer(id: "legacy-steer", text: "Still owned")]
        )
        let namespace = CacheNamespace.key(profileID: handle.profileID, accountID: handle.accountID)
        let container = await dependencies.cache.container
        let context = ModelContext(container)
        let record = GenerationRecoveryRecord(namespace: namespace, snapshot: snapshot)
        record.recordKey = "\(namespace)|generation|\(handle.streamID)|0"
        context.insert(record)
        try context.save()

        let batches = try await dependencies.cache.terminalSteerRecoveries(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID
        )
        XCTAssertEqual(batches.first?.handle, handle)
        XCTAssertEqual(batches.first?.steers.map(\.id), ["legacy-steer"])

        try await dependencies.cache.remove(handle: handle)
        let removed = try await dependencies.cache.terminalSteerRecoveries(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID
        )
        XCTAssertTrue(removed.isEmpty)
    }

    func testCachePurgesUseExactStoredProfileAndAccountOwnership() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let baseURL = try XCTUnwrap(URL(string: "https://cache.example.com"))
        let targetProfileID = ServerProfileID(rawValue: "profile")
        let collidingProfileID = ServerProfileID(rawValue: "profile|shadow")
        let targetAccountID = AccountID(rawValue: "account")
        let siblingAccountID = AccountID(rawValue: "account-extra")
        let conversationIDs = [
            ConversationID(rawValue: "target"),
            ConversationID(rawValue: "sibling"),
            ConversationID(rawValue: "other-profile")
        ]

        let targetProfile = ServerProfile(
            id: targetProfileID,
            baseURL: baseURL,
            displayName: "Target",
            accountIdentifier: targetAccountID
        )
        let collidingProfile = ServerProfile(
            id: collidingProfileID,
            baseURL: baseURL,
            displayName: "Other",
            accountIdentifier: targetAccountID
        )
        try await dependencies.cache.save(profile: targetProfile)
        try await dependencies.cache.save(profile: collidingProfile)

        for (profileID, accountID, conversationID) in [
            (targetProfileID, targetAccountID, conversationIDs[0]),
            (targetProfileID, siblingAccountID, conversationIDs[1]),
            (collidingProfileID, targetAccountID, conversationIDs[2])
        ] {
            try await dependencies.cache.saveAccount(
                profileID: profileID,
                account: UserAccount(id: accountID, name: conversationID.rawValue)
            )
            try await dependencies.cache.save(
                page: ConversationPage(
                    conversations: [Conversation(id: conversationID, title: conversationID.rawValue)],
                    fetchedAt: Date(),
                    isFromCache: false
                ),
                profileID: profileID,
                accountID: accountID,
                completeSynchronization: true
            )
        }

        try await dependencies.cache.purge(
            profileID: targetProfileID,
            accountID: targetAccountID
        )
        let removedAccount = try await dependencies.cache.lastVerifiedAccount(
            profileID: targetProfileID,
            accountID: targetAccountID
        )
        let siblingAfterAccountPurge = try await dependencies.cache.conversations(
            profileID: targetProfileID,
            accountID: siblingAccountID,
            limit: 10
        )
        XCTAssertNil(removedAccount)
        XCTAssertEqual(siblingAfterAccountPurge?.conversations.map(\.id), [conversationIDs[1]])

        try await dependencies.cache.purge(profileID: targetProfileID)
        let targetSiblingAfterProfilePurge = try await dependencies.cache.lastVerifiedAccount(
            profileID: targetProfileID,
            accountID: siblingAccountID
        )
        let collidingProfileAccount = try await dependencies.cache.lastVerifiedAccount(
            profileID: collidingProfileID,
            accountID: targetAccountID
        )
        let collidingProfileConversations = try await dependencies.cache.conversations(
            profileID: collidingProfileID,
            accountID: targetAccountID,
            limit: 10
        )
        XCTAssertNil(targetSiblingAfterProfilePurge)
        XCTAssertNotNil(collidingProfileAccount)
        XCTAssertEqual(collidingProfileConversations?.conversations.map(\.id), [conversationIDs[2]])
    }

    private func makeRepository(
        eventStreamTransport: (any EventStreamTransport)? = nil,
        dependencies suppliedDependencies: AppDependencies? = nil,
        capabilities suppliedCapabilities: ServerCapabilities? = nil
    ) async throws -> (LibreChatRepository, GenerationHandle) {
        let dependencies: AppDependencies
        if let suppliedDependencies {
            dependencies = suppliedDependencies
        } else {
            dependencies = try AppDependencies(inMemory: true)
        }
        let baseURL = URL(string: "https://chat.example.com")!
        let account = UserAccount(id: AccountID(rawValue: "account"))
        let profile = ServerProfile(
            id: ServerProfileID(rawValue: "profile"),
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id,
            capabilities: suppliedCapabilities ?? ServerCapabilities(generation: .resumable(version: 2))
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: RepositorySecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RepositoryURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let authentication = LibreChatProtocol.AuthSession.isolated(transport: transport)
        await authentication.setAuthenticated(AuthenticatedSession(accessToken: "token", user: account))
        let runtime = LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: authentication,
            restClient: RESTClient(transport: transport, authSession: authentication)
        )
        let repository = LibreChatRepository(
            profile: profile,
            runtime: runtime,
            cache: dependencies.cache,
            eventStreamTransport: eventStreamTransport,
            generationStartSleep: { _ in }
        )
        let handle = GenerationHandle(
            profileID: profile.id,
            accountID: account.id,
            clientRequestID: UUID(),
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 1000,
            protocolVersion: 2
        )
        return (repository, handle)
    }

    private func makeInteractionChatModel(
        handle: GenerationHandle,
        repository: ChatFeatureRepositoryDouble,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> ChatModel {
        ChatModel(
            conversation: Conversation(
                id: handle.conversationID,
                title: "Interaction",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            profileID: handle.profileID,
            accountID: handle.accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: onUnauthorized,
            onConversationIdentityChanged: { _, _ in }
        )
    }

    private func assertUnsupported(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected a local unsupported-input error", file: file, line: line)
        } catch let error as LibreChatProtocolError {
            guard case .unsupported = error else {
                return XCTFail("Expected unsupported, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected LibreChatProtocolError, got \(error)", file: file, line: line)
        }
    }

    nonisolated private static func response(
        for request: URLRequest,
        status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new }
        )!
    }

    nonisolated private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
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

private actor ChatFeatureRepositoryDouble: ChatFeatureRepository {
    private let sendError: LibreChatProtocolError?
    private let sendOutcome: ChatSendOutcome?
    private let serverMessages: [ChatMessage]
    private let messagesError: LibreChatProtocolError?
    private let reconciliations: [GenerationHandle: GenerationSnapshot]
    private var reconciliationSequence: [GenerationHandle: [GenerationSnapshot]]
    private let streamSnapshots: [GenerationHandle: [GenerationSnapshot]]
    private let reconciliationError: LibreChatProtocolError?
    private let recoverableSnapshots: [GenerationSnapshot]
    private let interactionError: LibreChatProtocolError?
    private let resumeFailure: LibreChatProtocolError?
    private let resumeFailureCall: Int?
    private let resumeCancellationCall: Int?
    private let streamCancellationCall: Int?
    private let keepsStreamsOpen: Bool
    private var sends = 0
    private var interactionHandles: [GenerationHandle] = []
    private var drafts: [ConversationID: String] = [:]
    private var resumedHandles: [GenerationHandle] = []
    private var streamedHandles: [GenerationHandle] = []
    private var artifactRequests: [ArtifactEditRequest] = []
    private var streamContinuations: [
        GenerationHandle: AsyncThrowingStream<GenerationSnapshot, Error>.Continuation
    ] = [:]
    private var followUpSnapshot: FollowUpQueueSnapshot?

    init(sendError: LibreChatProtocolError) {
        self.sendError = sendError
        sendOutcome = nil
        serverMessages = []
        messagesError = nil
        reconciliations = [:]
        streamSnapshots = [:]
        reconciliationError = nil
        reconciliationSequence = [:]
        recoverableSnapshots = []
        interactionError = nil
        resumeFailure = nil
        resumeFailureCall = nil
        resumeCancellationCall = nil
        streamCancellationCall = nil
        keepsStreamsOpen = false
    }

    init(
        sendOutcome: ChatSendOutcome,
        serverMessages: [ChatMessage] = [],
        messagesError: LibreChatProtocolError? = nil,
        reconciliations: [GenerationHandle: GenerationSnapshot] = [:],
        streamSnapshots: [GenerationHandle: [GenerationSnapshot]] = [:],
        reconciliationError: LibreChatProtocolError? = nil,
        keepsStreamsOpen: Bool = false
    ) {
        sendError = nil
        self.sendOutcome = sendOutcome
        self.serverMessages = serverMessages
        self.messagesError = messagesError
        self.reconciliations = reconciliations
        self.streamSnapshots = streamSnapshots
        self.reconciliationError = reconciliationError
        reconciliationSequence = [:]
        recoverableSnapshots = []
        interactionError = nil
        resumeFailure = nil
        resumeFailureCall = nil
        resumeCancellationCall = nil
        streamCancellationCall = nil
        self.keepsStreamsOpen = keepsStreamsOpen
    }

    init(
        recoverableSnapshots: [GenerationSnapshot],
        interactionError: LibreChatProtocolError? = nil,
        reconciliations: [GenerationHandle: GenerationSnapshot] = [:],
        reconciliationError: LibreChatProtocolError? = nil,
        reconciliationSequence: [GenerationHandle: [GenerationSnapshot]] = [:],
        resumeFailure: LibreChatProtocolError? = nil,
        resumeFailureCall: Int? = nil,
        resumeCancellationCall: Int? = nil,
        streamCancellationCall: Int? = nil,
        serverMessages: [ChatMessage] = []
    ) {
        sendError = nil
        sendOutcome = nil
        self.serverMessages = serverMessages
        messagesError = nil
        self.reconciliations = reconciliations
        streamSnapshots = [:]
        self.reconciliationError = reconciliationError
        self.reconciliationSequence = reconciliationSequence
        self.recoverableSnapshots = recoverableSnapshots
        self.interactionError = interactionError
        self.resumeFailure = resumeFailure
        self.resumeFailureCall = resumeFailureCall
        self.resumeCancellationCall = resumeCancellationCall
        self.streamCancellationCall = streamCancellationCall
        keepsStreamsOpen = false
    }

    func sendCount() -> Int { sends }
    func savedDraft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func resumedGenerationHandles() -> [GenerationHandle] { resumedHandles }
    func streamedGenerationHandles() -> [GenerationHandle] { streamedHandles }
    func interactionResponseCount() -> Int { interactionHandles.count }
    func interactionResponseHandles() -> [GenerationHandle] { interactionHandles }
    func artifactUpdateCount() -> Int { artifactRequests.count }
    func seedFollowUpQueue(_ snapshot: FollowUpQueueSnapshot) { followUpSnapshot = snapshot }
    func finishStreams() {
        streamContinuations.values.forEach { $0.finish() }
        streamContinuations.removeAll()
    }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func archivedConversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) throws -> Conversation {
        Conversation(
            id: id,
            title: "Test",
            target: ConversationTarget(endpoint: "agents", agentID: "agent")
        )
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { [] }
    func messages(conversationID: ConversationID) throws -> [ChatMessage] {
        if let messagesError { throw messagesError }
        return serverMessages
    }
    func searchConversations(query: String, cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) -> MessageSearchPage {
        MessageSearchPage(results: [])
    }
    func availableChatTargets() -> [ChatTargetOption] { [] }
    func createConversation(title: String, target: ConversationTarget) -> Conversation {
        Conversation(id: ConversationID(localDraftID: UUID()), title: title, target: target)
    }
    func delete(id: ConversationID) {}

    func send(_ request: ChatRequest) throws -> ChatSendOutcome {
        sends += 1
        if let sendOutcome { return sendOutcome }
        guard let sendError else { throw LibreChatProtocolError.invalidResponse }
        throw sendError
    }
    func snapshots(for handle: GenerationHandle) -> AsyncThrowingStream<GenerationSnapshot, Error> {
        streamedHandles.append(handle)
        let snapshots = streamSnapshots[handle] ?? []
        let pair = AsyncThrowingStream<GenerationSnapshot, Error>.makeStream()
        for snapshot in snapshots { pair.continuation.yield(snapshot) }
        if streamedHandles.count == streamCancellationCall {
            pair.continuation.finish(throwing: CancellationError())
        } else if keepsStreamsOpen {
            streamContinuations[handle] = pair.continuation
        } else {
            pair.continuation.finish()
        }
        return pair.stream
    }
    func resume(_ generation: GenerationHandle) throws {
        resumedHandles.append(generation)
        if let resumeCancellationCall,
           resumedHandles.count == resumeCancellationCall {
            throw CancellationError()
        }
        if let resumeFailure,
           resumedHandles.count == resumeFailureCall {
            throw resumeFailure
        }
    }
    func reconcile(_ generation: GenerationHandle) throws -> GenerationSnapshot {
        if let reconciliationError { throw reconciliationError }
        if var snapshots = reconciliationSequence[generation], !snapshots.isEmpty {
            let snapshot = snapshots.removeFirst()
            reconciliationSequence[generation] = snapshots
            return snapshot
        }
        return reconciliations[generation] ?? GenerationSnapshot(handle: generation, state: .reconciling)
    }
    func recoverActiveGenerations() -> [GenerationSnapshot] { [] }
    func stop(_ generation: GenerationHandle) {}

    func saveMessageEdit(_ request: MessageEditRequest) throws -> MessageEditResult {
        throw MessageEditPresentationError.unavailable
    }

    func updateArtifact(_ request: ArtifactEditRequest) throws -> ChatMessage {
        artifactRequests.append(request)
        guard let message = serverMessages.first(where: { $0.id == request.identity.messageID }) else {
            throw ArtifactEditError.messageNotFound
        }
        return message
    }

    func respond(
        to interaction: PendingInteraction,
        handle: GenerationHandle,
        toolResolutions: [ToolApprovalResolution]?,
        answer: String?,
        batchAnswers: [String: String]?
    ) throws -> GenerationSnapshot {
        interactionHandles.append(handle)
        if let interactionError { throw interactionError }
        return GenerationSnapshot(handle: handle, state: .streaming)
    }
    func recoverableGenerations() -> [GenerationSnapshot] { recoverableSnapshots }
    func draft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) {
        drafts[conversationID] = text
    }

    func followUpQueue(conversationID: ConversationID) throws -> FollowUpQueueSnapshot {
        guard let followUpSnapshot,
              followUpSnapshot.namespace.conversationID == conversationID else {
            throw FollowUpQueueError.invalidConversation
        }
        return followUpSnapshot
    }

    func enqueueFollowUp(_ item: FollowUpQueueItem) throws -> FollowUpQueueSnapshot {
        guard var snapshot = followUpSnapshot else {
            throw FollowUpQueueError.invalidConversation
        }
        var reducer = FollowUpQueueReducer(snapshot: snapshot)
        try reducer.enqueue(item)
        snapshot = reducer.snapshot
        followUpSnapshot = snapshot
        return snapshot
    }

    func removeQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID
    ) throws -> FollowUpQueueSnapshot {
        guard var snapshot = followUpSnapshot,
              snapshot.namespace.conversationID == conversationID else {
            throw FollowUpQueueError.invalidConversation
        }
        var reducer = FollowUpQueueReducer(snapshot: snapshot)
        try reducer.removeQueued(itemID: itemID)
        snapshot = reducer.snapshot
        followUpSnapshot = snapshot
        return snapshot
    }
}

private actor ForegroundRecoveryRepositoryDouble: ChatFeatureRepository {
    private var messagePages: [[ChatMessage]]
    private var followUpSnapshots: [FollowUpQueueSnapshot]
    private let streams: [GenerationHandle: [GenerationSnapshot]]
    private let reconciliations: [GenerationHandle: GenerationSnapshot]
    private var resumedHandles: [GenerationHandle] = []
    private var streamedHandles: [GenerationHandle] = []
    private var reconciledHandles: [GenerationHandle] = []
    private var drafts: [ConversationID: String] = [:]

    init(
        messagePages: [[ChatMessage]] = [[]],
        streams: [GenerationHandle: [GenerationSnapshot]] = [:],
        reconciliations: [GenerationHandle: GenerationSnapshot] = [:],
        followUpSnapshots: [FollowUpQueueSnapshot] = []
    ) {
        self.messagePages = messagePages
        self.followUpSnapshots = followUpSnapshots
        self.streams = streams
        self.reconciliations = reconciliations
    }

    func resumedGenerationHandles() -> [GenerationHandle] { resumedHandles }
    func streamedGenerationHandles() -> [GenerationHandle] { streamedHandles }
    func reconciledGenerationHandles() -> [GenerationHandle] { reconciledHandles }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func archivedConversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) throws -> Conversation {
        Conversation(
            id: id,
            title: "Conversation",
            target: ConversationTarget(endpoint: "agents", agentID: "agent")
        )
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { [] }
    func messages(conversationID: ConversationID) -> [ChatMessage] {
        guard !messagePages.isEmpty else { return [] }
        if messagePages.count == 1 { return messagePages[0] }
        return messagePages.removeFirst()
    }
    func searchConversations(query: String, cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) -> MessageSearchPage { MessageSearchPage(results: []) }
    func availableChatTargets() -> [ChatTargetOption] { [] }
    func targetCatalog(recentOptionID: String?) -> TargetCatalogSnapshot {
        TargetCatalogSnapshot(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            fetchedAt: Date(timeIntervalSince1970: 0),
            options: [],
            agentDiscoveryStatus: .notSupported
        )
    }
    func createConversation(title: String, target: ConversationTarget) -> Conversation {
        Conversation(id: ConversationID(localDraftID: UUID()), title: title, target: target)
    }
    func delete(id: ConversationID) {}

    func send(_ request: ChatRequest) throws -> ChatSendOutcome {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }
    func snapshots(for handle: GenerationHandle) -> AsyncThrowingStream<GenerationSnapshot, Error> {
        streamedHandles.append(handle)
        let snapshots = streams[handle] ?? []
        return AsyncThrowingStream(
            GenerationSnapshot.self,
            bufferingPolicy: .unbounded
        ) { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
            continuation.finish()
        }
    }
    func resume(_ generation: GenerationHandle) { resumedHandles.append(generation) }
    func reconcile(_ generation: GenerationHandle) throws -> GenerationSnapshot {
        reconciledHandles.append(generation)
        guard let snapshot = reconciliations[generation] else {
            throw LibreChatProtocolError.unsupported("No reconciliation fixture was installed.")
        }
        return snapshot
    }
    func recoverActiveGenerations() -> [GenerationSnapshot] { [] }
    func stop(_ generation: GenerationHandle) {}

    func saveMessageEdit(_ request: MessageEditRequest) throws -> MessageEditResult {
        throw MessageEditPresentationError.unavailable
    }

    func respond(
        to interaction: PendingInteraction,
        handle: GenerationHandle,
        toolResolutions: [ToolApprovalResolution]?,
        answer: String?,
        batchAnswers: [String: String]?
    ) -> GenerationSnapshot { GenerationSnapshot(handle: handle, state: .streaming) }
    func recoverableGenerations() -> [GenerationSnapshot] { [] }
    func followUpQueue(conversationID: ConversationID) throws -> FollowUpQueueSnapshot {
        guard !followUpSnapshots.isEmpty else { throw FollowUpQueueError.invalidTransition }
        let snapshot = followUpSnapshots.count == 1
            ? followUpSnapshots[0]
            : followUpSnapshots.removeFirst()
        guard snapshot.namespace.conversationID == conversationID else {
            throw FollowUpQueueError.contextMismatch
        }
        return snapshot
    }
    func draft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) {
        drafts[conversationID] = text
    }
}

private actor ConversationListRepositoryDouble: ConversationListFeatureRepository {
    enum DuplicateOutcome: Sendable {
        case success(ConversationDuplicationResult)
        case failure(ConversationDuplicationError)
    }

    struct RememberedTargetSelection: Equatable {
        let optionID: String
        let profileID: ServerProfileID
        let accountID: AccountID
    }

    private var pages: [ConversationPage]
    private var catalogs: [TargetCatalogSnapshot]
    private var duplicateOutcomes: [DuplicateOutcome]
    private var duplicateRequests = 0
    private var rememberedTargets: [RememberedTargetSelection] = []

    init(
        pages: [ConversationPage],
        catalogs: [TargetCatalogSnapshot] = [],
        duplicateOutcomes: [DuplicateOutcome] = []
    ) {
        self.pages = pages
        self.catalogs = catalogs
        self.duplicateOutcomes = duplicateOutcomes
    }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }

    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        guard !pages.isEmpty else { return ConversationPage(conversations: []) }
        return pages.removeFirst()
    }
    func archivedConversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }

    func conversation(id: ConversationID) throws -> Conversation {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }

    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { [] }
    func messages(conversationID: ConversationID) -> [ChatMessage] { [] }
    func searchConversations(query: String, cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) -> MessageSearchPage { MessageSearchPage(results: []) }
    func availableChatTargets() -> [ChatTargetOption] { [] }
    func targetCatalog(recentOptionID: String?) -> TargetCatalogSnapshot {
        guard !catalogs.isEmpty else {
            return TargetCatalogSnapshot(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                fetchedAt: Date(timeIntervalSince1970: 0),
                options: [],
                agentDiscoveryStatus: .notSupported
            )
        }
        return catalogs.removeFirst()
    }
    func newChatTargetCatalog() -> TargetCatalogSnapshot {
        targetCatalog(recentOptionID: nil)
    }
    func rememberRecentChatTargetOptionID(
        _ optionID: String,
        profileID: ServerProfileID,
        accountID: AccountID
    ) {
        rememberedTargets.append(.init(
            optionID: optionID,
            profileID: profileID,
            accountID: accountID
        ))
    }
    func rememberedTargetSelections() -> [RememberedTargetSelection] { rememberedTargets }
    func createConversation(title: String, target: ConversationTarget) -> Conversation {
        Conversation(id: ConversationID(localDraftID: UUID()), title: title, target: target)
    }
    func delete(id: ConversationID) {}
    func rename(id: ConversationID, title: String) throws -> Conversation {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }
    func archive(id: ConversationID, isArchived: Bool) throws -> Conversation {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }
    func pin(id: ConversationID, pinned: Bool) throws -> Conversation {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }
    func duplicate(
        _ request: ConversationDuplicationRequest
    ) throws -> ConversationDuplicationResult {
        duplicateRequests += 1
        guard !duplicateOutcomes.isEmpty else {
            throw ConversationDuplicationError.preflightReadFailed
        }
        switch duplicateOutcomes.removeFirst() {
        case let .success(result): return result
        case let .failure(error): throw error
        }
    }
    func duplicateRequestCount() -> Int { duplicateRequests }
}

@MainActor
private final class MutableOfflineState {
    var value = false
}

private actor SearchRepositoryDouble: ConversationRepository {
    private let cached: [Conversation]
    private var alphaCalls = 0

    init(cached: [Conversation] = []) {
        self.cached = cached
    }

    func cachedConversations(limit: Int) -> ConversationPage? {
        ConversationPage(conversations: Array(cached.prefix(limit)), isFromCache: true)
    }

    func conversations(cursor: String?, limit: Int) throws -> ConversationPage {
        ConversationPage(conversations: [])
    }

    func conversation(id: ConversationID) throws -> Conversation {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }

    func cachedMessages(conversationID: ConversationID) throws -> [ChatMessage] { [] }
    func messages(conversationID: ConversationID) throws -> [ChatMessage] { [] }

    func searchConversations(
        query: String,
        cursor: String?,
        limit: Int
    ) async throws -> ConversationPage {
        if query == "alpha" {
            alphaCalls += 1
            let call = alphaCalls
            try? await Task.sleep(for: call == 1 ? .milliseconds(250) : .milliseconds(100))
            return ConversationPage(conversations: [Conversation(
                id: .init(rawValue: call == 1 ? "stale-alpha" : "fresh-alpha"),
                title: call == 1 ? "Stale alpha" : "Fresh alpha"
            )])
        }
        try? await Task.sleep(for: .milliseconds(50))
        return ConversationPage(conversations: [Conversation(
            id: .init(rawValue: "beta"),
            title: "Beta"
        )])
    }

    func searchMessages(query: String) throws -> MessageSearchPage {
        MessageSearchPage(results: [])
    }

    func availableChatTargets() throws -> [ChatTargetOption] { [] }

    func createConversation(title: String, target: ConversationTarget) throws -> Conversation {
        throw LibreChatProtocolError.unsupported("Not used by this test.")
    }

    func delete(id: ConversationID) throws {}
}

private actor ProjectRepositoryDouble: ProjectRepository {
    private var lastUpdate: UpdateChatProjectInput?

    func capturedUpdate() -> UpdateChatProjectInput? { lastUpdate }

    func projects(options: ChatProjectListOptions) -> ChatProjectPage {
        ChatProjectPage(projects: [])
    }

    func project(id: ProjectID) -> ChatProject {
        ChatProject(id: id, name: "Project", conversationCount: 0)
    }

    func createProject(_ input: CreateChatProjectInput) -> ChatProject {
        ChatProject(
            id: ProjectID(rawValue: "project"),
            name: input.name,
            description: input.description,
            conversationCount: 0
        )
    }

    func updateProject(id: ProjectID, input: UpdateChatProjectInput) -> ChatProject {
        lastUpdate = input
        return ChatProject(
            id: id,
            name: input.name ?? "Project",
            description: input.description,
            conversationCount: 0
        )
    }

    func deleteProject(id: ProjectID) -> DeleteChatProjectResult {
        DeleteChatProjectResult(deletedCount: 1, modifiedCount: 0)
    }

    func assignConversation(
        id: ConversationID,
        to projectID: ProjectID?
    ) -> ConversationProjectAssignment {
        ConversationProjectAssignment(
            conversation: Conversation(id: id, title: "Conversation", projectID: projectID),
            previousProjectID: nil,
            projectID: projectID
        )
    }

    func projectConversations(
        projectID: ProjectID,
        cursor: String?,
        limit: Int
    ) -> ConversationPage {
        ConversationPage(conversations: [])
    }
}

private actor ProjectPaginationRaceRepositoryDouble: ProjectRepository {
    func projects(options: ChatProjectListOptions) async throws -> ChatProjectPage {
        if options.cursor == "next" {
            try await Task.sleep(for: .milliseconds(150))
            throw LibreChatProtocolError.unauthorized
        }
        let fresh = options.search == "fresh"
        return ChatProjectPage(
            projects: [ChatProject(
                id: ProjectID(rawValue: fresh ? "fresh" : "initial"),
                name: fresh ? "Fresh result" : "Initial result",
                conversationCount: 0
            )],
            nextCursor: fresh ? nil : "next"
        )
    }

    func project(id: ProjectID) -> ChatProject {
        ChatProject(id: id, name: "Project", conversationCount: 0)
    }

    func createProject(_ input: CreateChatProjectInput) -> ChatProject {
        ChatProject(id: .init(rawValue: "created"), name: input.name, conversationCount: 0)
    }

    func updateProject(id: ProjectID, input: UpdateChatProjectInput) -> ChatProject {
        ChatProject(id: id, name: input.name ?? "Project", conversationCount: 0)
    }

    func deleteProject(id: ProjectID) -> DeleteChatProjectResult {
        DeleteChatProjectResult(deletedCount: 1, modifiedCount: 0)
    }

    func assignConversation(
        id: ConversationID,
        to projectID: ProjectID?
    ) -> ConversationProjectAssignment {
        ConversationProjectAssignment(
            conversation: Conversation(id: id, title: "Conversation", projectID: projectID),
            previousProjectID: nil,
            projectID: projectID
        )
    }

    func projectConversations(
        projectID: ProjectID,
        cursor: String?,
        limit: Int
    ) -> ConversationPage {
        ConversationPage(conversations: [])
    }
}

private actor SharedLinkRepositoryDouble: SharedLinkRepository {
    private var lookups = 0
    private var createRequest: SharedLinkPublishRequest?

    func lookupCount() -> Int { lookups }
    func createdSnapshotFiles() -> Bool? { createRequest?.snapshotFiles }

    func sharedLink(for conversationID: ConversationID) -> SharedLinkState {
        lookups += 1
        return SharedLinkState(
            conversationID: conversationID,
            link: SharedLink(
                shareID: SharedLinkID(rawValue: "server-share"),
                resourceID: "resource",
                conversationID: conversationID,
                targetMessageID: MessageID(rawValue: "message")
            )
        )
    }

    func createSharedLink(
        for conversationID: ConversationID,
        request: SharedLinkPublishRequest
    ) throws -> SharedLinkMutationResult {
        createRequest = request
        throw LibreChatProtocolError.httpStatus(409, message: "Share already exists", retryAfter: nil)
    }

    func updateSharedLink(
        _ shareID: SharedLinkID,
        request: SharedLinkPublishRequest
    ) -> SharedLinkMutationResult {
        SharedLinkMutationResult(
            shareID: shareID,
            resourceID: "resource",
            conversationID: ConversationID(rawValue: "conversation"),
            targetMessageID: request.targetMessageID
        )
    }

    func deleteSharedLink(_ shareID: SharedLinkID) -> SharedLinkDeletionResult {
        SharedLinkDeletionResult(shareID: shareID, resourceID: "resource", message: "Deleted")
    }
}

private actor SharedLinkFailureRepositoryDouble: SharedLinkRepository {
    enum Mode: Equatable, Sendable {
        case expiredOnUpdate
        case deniedOnCreate
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func sharedLink(for conversationID: ConversationID) -> SharedLinkState {
        SharedLinkState(
            conversationID: conversationID,
            link: SharedLink(
                shareID: SharedLinkID(rawValue: "share"),
                conversationID: conversationID
            )
        )
    }

    func createSharedLink(
        for conversationID: ConversationID,
        request: SharedLinkPublishRequest
    ) throws -> SharedLinkMutationResult {
        if mode == .deniedOnCreate {
            throw LibreChatProtocolError.httpStatus(403, message: "Forbidden", retryAfter: nil)
        }
        return SharedLinkMutationResult(
            shareID: SharedLinkID(rawValue: "share"),
            conversationID: conversationID
        )
    }

    func updateSharedLink(
        _ shareID: SharedLinkID,
        request: SharedLinkPublishRequest
    ) throws -> SharedLinkMutationResult {
        if mode == .expiredOnUpdate {
            throw LibreChatProtocolError.httpStatus(404, message: "Share not found", retryAfter: nil)
        }
        return SharedLinkMutationResult(
            shareID: shareID,
            conversationID: ConversationID(rawValue: "conversation")
        )
    }

    func deleteSharedLink(_ shareID: SharedLinkID) -> SharedLinkDeletionResult {
        SharedLinkDeletionResult(shareID: shareID, message: "Deleted")
    }
}

private actor SharedSnapshotRepositoryDouble: SharedSnapshotRepository {
    private var snapshotCalls = 0

    func snapshotCallCount() -> Int { snapshotCalls }

    func sharedSnapshot(for shareID: SharedLinkID) -> SharedConversationSnapshot {
        snapshotCalls += 1
        return SharedConversationSnapshot(
            shareID: shareID,
            conversationID: SharedConversationID(rawValue: "shared-conversation-\(snapshotCalls)"),
            title: "Published",
            revision: SharedSnapshotRevision(rawValue: "revision-\(snapshotCalls)"),
            messages: []
        )
    }

    func forkSharedConversation(
        _ request: SharedConversationForkRequest
    ) throws -> SharedConversationForkResult {
        throw LibreChatProtocolError.httpStatus(409, message: "Revision changed", retryAfter: nil)
    }
}

private actor SharedSnapshotFailureRepository: SharedSnapshotRepository {
    enum Mode: Sendable, Equatable {
        case missingRevision
        case transport
        case forbidden
        case expired
    }

    private let mode: Mode
    private var forkCalls = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func forkCallCount() -> Int { forkCalls }

    func sharedSnapshot(for shareID: SharedLinkID) -> SharedConversationSnapshot {
        SharedConversationSnapshot(
            shareID: shareID,
            conversationID: SharedConversationID(rawValue: "shared-conversation"),
            title: "Published",
            revision: mode == .missingRevision ? nil : SharedSnapshotRevision(rawValue: "revision"),
            messages: []
        )
    }

    func forkSharedConversation(
        _ request: SharedConversationForkRequest
    ) throws -> SharedConversationForkResult {
        forkCalls += 1
        switch mode {
        case .missingRevision:
            throw LibreChatProtocolError.invalidResponse
        case .transport:
            throw LibreChatProtocolError.transport("Connection lost")
        case .forbidden:
            throw LibreChatProtocolError.httpStatus(403, message: "Forbidden", retryAfter: nil)
        case .expired:
            throw LibreChatProtocolError.httpStatus(404, message: "Not found", retryAfter: nil)
        }
    }
}

private actor ControlledSharedSnapshotRepository: SharedSnapshotRepository {
    private var requestCount = 0
    private var continuations: [Int: CheckedContinuation<SharedConversationSnapshot, Error>] = [:]

    func waitForRequestCount(_ expected: Int) async {
        while requestCount < expected {
            await Task.yield()
        }
    }

    func resolve(request: Int, title: String, revision: String) {
        continuations.removeValue(forKey: request)?.resume(returning: SharedConversationSnapshot(
            shareID: SharedLinkID(rawValue: "share"),
            conversationID: SharedConversationID(rawValue: "shared-\(request)"),
            title: title,
            revision: SharedSnapshotRevision(rawValue: revision),
            messages: []
        ))
    }

    func sharedSnapshot(for shareID: SharedLinkID) async throws -> SharedConversationSnapshot {
        requestCount += 1
        let currentRequest = requestCount
        return try await withCheckedThrowingContinuation { continuation in
            continuations[currentRequest] = continuation
        }
    }

    func forkSharedConversation(
        _ request: SharedConversationForkRequest
    ) throws -> SharedConversationForkResult {
        throw LibreChatProtocolError.invalidResponse
    }
}

private final class RepositoryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var clientRequestIDs: [String] = []
    private var messageIDs: [String] = []
    private var overrideParentMessageIDs: [String] = []
    private var responseMessageIDs: [String] = []

    var count: Int {
        lock.withLock { clientRequestIDs.count }
    }

    var uniqueClientRequestIDs: Set<String> {
        lock.withLock { Set(clientRequestIDs) }
    }

    var uniqueMessageIDs: Set<String> {
        lock.withLock { Set(messageIDs) }
    }

    var uniqueOverrideParentMessageIDs: Set<String> {
        lock.withLock { Set(overrideParentMessageIDs) }
    }

    var uniqueResponseMessageIDs: Set<String> {
        lock.withLock { Set(responseMessageIDs) }
    }

    func record(clientRequestID: String?) {
        guard let clientRequestID else { return }
        lock.withLock { clientRequestIDs.append(clientRequestID) }
    }

    func record(
        clientRequestID: String?,
        messageID: String?,
        overrideParentMessageID: String?,
        responseMessageID: String?
    ) {
        guard let clientRequestID,
              let messageID,
              let overrideParentMessageID,
              let responseMessageID else { return }
        lock.withLock {
            clientRequestIDs.append(clientRequestID)
            messageIDs.append(messageID)
            overrideParentMessageIDs.append(overrideParentMessageID)
            responseMessageIDs.append(responseMessageID)
        }
    }
}

private final class AccountRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var count: Int { lock.withLock { requests.count } }

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class AmbiguousStartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var clientRequestIDs: [String] = []
    private var messageIDs: [String] = []

    var attemptCount: Int {
        lock.withLock { clientRequestIDs.count }
    }

    var uniqueClientRequestIDs: Set<String> {
        lock.withLock { Set(clientRequestIDs) }
    }

    var uniqueMessageIDs: Set<String> {
        lock.withLock { Set(messageIDs) }
    }

    func record(clientRequestID: String?, messageID: String?) {
        guard let clientRequestID, let messageID else { return }
        lock.withLock {
            clientRequestIDs.append(clientRequestID)
            messageIDs.append(messageID)
        }
    }

    func expectedConversationID() throws -> String {
        let requestID = try lock.withLock {
            try XCTUnwrap(clientRequestIDs.first)
        }
        return LibreChatGenerationIdentity.newConversationID(
            userID: "account",
            clientRequestID: requestID
        )
    }

    func messageID() throws -> String {
        try lock.withLock { try XCTUnwrap(messageIDs.first) }
    }
}

private actor RepositorySecretStore: SecretStore {
    private var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private struct FailingGenerationStreamTransport: EventStreamTransport {
    let error: LibreChatProtocolError

    func events(request: URLRequest) async -> AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream { continuation in continuation.finish(throwing: error) }
    }
}

private struct FiniteGenerationStreamTransport: EventStreamTransport {
    let eventsToSend: [ServerSentEvent]

    init(events: [ServerSentEvent]) {
        eventsToSend = events
    }

    func events(request: URLRequest) async -> AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in eventsToSend { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private final class RepositoryURLProtocolStub: URLProtocol {
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
