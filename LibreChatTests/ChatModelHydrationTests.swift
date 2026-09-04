import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class ChatModelHydrationTests: XCTestCase {
    func testPartialServerConversationHydratesBeforeSendAndAttachmentsBecomeAvailable() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let partial = Conversation(
            id: conversationID,
            title: "Search result",
            model: "partial-model",
            target: ConversationTarget(endpoint: "agents")
        )
        let authoritative = Conversation(
            id: conversationID,
            title: "Authoritative title",
            model: "server-model",
            target: ConversationTarget(
                endpoint: "agents",
                model: "server-model",
                agentID: "agent-1",
                spec: "server-spec"
            ),
            projectID: ProjectID(rawValue: "project-1")
        )
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: authoritative]
        )
        let uploadManager = try makeUploadManager(profileID: profileID, accountID: accountID)
        var callbacks: [(ConversationID, Conversation)] = []
        let model = makeModel(
            conversation: partial,
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: uploadManager,
            onConversationIdentityChanged: { callbacks.append(($0, $1)) }
        )

        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canStageAttachments)
        await model.loadIfNeeded()
        model.draft = "Ready after hydration"

        XCTAssertEqual(model.routingState, .authoritative)
        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertEqual(model.conversation, authoritative)
        XCTAssertEqual(callbacks.map(\.0), [conversationID])
        XCTAssertEqual(callbacks.map(\.1), [authoritative])
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(model.canStageAttachments)
        XCTAssertTrue(model.canStartNewChatWithAnotherTarget)
        XCTAssertNil(model.targetSwitchDisabledReason)
    }

    func testUnsentLocalDraftRemainsTargetSwitchableInPlace() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let local = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: "New chat",
            target: ConversationTarget(endpoint: "openAI", model: "fixture")
        )
        let repository = HydrationRepositoryDouble()
        let model = makeModel(
            conversation: local,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )

        await model.loadIfNeeded()

        // An unsent canvas is exactly where the anchored model dropdown
        // lives: it stays switchable without waiting for routing checks.
        XCTAssertTrue(model.canStartNewChatWithAnotherTarget)
        XCTAssertNil(model.targetSwitchDisabledReason)
        XCTAssertEqual(model.draft, "")

        let replacement = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: "New chat",
            target: ConversationTarget(endpoint: "openAI", model: "other-model")
        )
        var callbacks: [(ConversationID, Conversation)] = []
        let observingModel = makeModel(
            conversation: local,
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            onConversationIdentityChanged: { callbacks.append(($0, $1)) }
        )
        await observingModel.loadIfNeeded()
        observingModel.replaceUnsentDraft(with: replacement)

        XCTAssertEqual(observingModel.conversation.id, replacement.id)
        XCTAssertEqual(observingModel.conversation.target, replacement.target)
        XCTAssertEqual(callbacks.map(\.0), [local.id])
        XCTAssertEqual(callbacks.map { $0.1.id }, [replacement.id])
        // Regression: a replaced canvas draft used to be marked unverified,
        // which nothing ever re-hydrates — the target pill went
        // "unavailable" and sending stayed disabled until the page was
        // recreated. A draft's reviewed target is authoritative outright.
        XCTAssertEqual(observingModel.routingState, .authoritative)
        XCTAssertEqual(observingModel.historyState, .authoritative)
        XCTAssertNil(observingModel.generationDisabledReason)
        XCTAssertEqual(observingModel.executionTargetModel, "other-model")
        XCTAssertEqual(observingModel.executionTargetEndpoint, "openAI")
    }

    func testSkillSelectionIsExactAndRestoredAfterRejectedAdmission() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let target = ConversationTarget(
            endpoint: "openAI",
            model: "gpt",
            ephemeralAgent: EphemeralAgentConfiguration()
        )
        let catalog = SkillInvocationCatalog(
            profileID: profileID,
            accountID: accountID,
            target: target,
            skills: [ChatSkillSummary(
                id: SkillID(rawValue: "507f1f77bcf86cd799439011"),
                name: "review-code",
                displayTitle: "Review code",
                description: "Review this change",
                source: .inline,
                version: 1,
                fileCount: 0,
                availability: .available
            )]
        )
        let repository = HydrationRepositoryDouble(skillCatalog: catalog)
        let model = makeModel(
            conversation: Conversation(
                id: ConversationID(localDraftID: UUID()),
                title: "Skills",
                target: target
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            canUseSkills: true
        )
        await model.loadIfNeeded()
        await model.refreshSkillCatalog()

        XCTAssertTrue(model.replaceSelectedSkills(["review-code"]))
        model.draft = "Review this"
        XCTAssertTrue(model.canSend)

        model.send()
        await waitUntil { !model.isStreaming }

        let requests = await repository.sentRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.manualSkills, ["review-code"])
        XCTAssertEqual(model.draft, "Review this")
        XCTAssertEqual(model.selectedSkillNames, ["review-code"])
    }

    func testSkillPickerAllowsRemovingARevokedSelectionButBlocksNewUnavailableOrOverLimitRows() {
        XCTAssertTrue(SkillPickerInteractionPolicy.canToggle(
            isSelected: true,
            isSelectable: false,
            isAtLimit: true
        ))
        XCTAssertFalse(SkillPickerInteractionPolicy.canToggle(
            isSelected: false,
            isSelectable: false,
            isAtLimit: false
        ))
        XCTAssertFalse(SkillPickerInteractionPolicy.canToggle(
            isSelected: false,
            isSelectable: true,
            isAtLimit: true
        ))
        XCTAssertTrue(SkillPickerInteractionPolicy.canToggle(
            isSelected: false,
            isSelectable: true,
            isAtLimit: false
        ))
    }

    func testUnsupportedEndpointFamilyIsTruthfullyReadOnlyBeforeAnySendOrUpload() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversation = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: "Unsupported",
            target: ConversationTarget(
                endpoint: "resume",
                endpointType: "custom",
                model: "model"
            )
        )
        let repository = HydrationRepositoryDouble()
        let uploadManager = try makeUploadManager(profileID: profileID, accountID: accountID)
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: uploadManager
        )

        await model.loadIfNeeded()
        model.draft = "Must remain editable"

        XCTAssertTrue(model.canEditDraft)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canStageAttachments)
        XCTAssertEqual(
            model.generationDisabledReason,
            "This conversation’s endpoint cannot be routed safely by the native app. Start a new chat and choose a supported target."
        )
        XCTAssertEqual(
            model.attachmentDisabledReason,
            "This conversation’s endpoint cannot be routed safely by the native app. Start a new chat and choose a supported target."
        )
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 0)
    }

    func testHydrationFailureKeepsCachedBrowsingAndDraftEditingButBlocksSendAndAttach() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let partial = Conversation(
            id: conversationID,
            title: "Partial",
            target: ConversationTarget(endpoint: "openAI", model: "partial")
        )
        let cached = ChatMessage(
            id: MessageID(rawValue: "cached"),
            conversationID: conversationID,
            content: [.text("Saved message")],
            author: .assistant(name: "Assistant")
        )
        let repository = HydrationRepositoryDouble(
            cachedMessages: [cached],
            conversationError: LibreChatProtocolError.transport("offline"),
            messagesError: LibreChatProtocolError.transport("offline"),
            drafts: [conversationID: "Offline draft"]
        )
        let uploadManager = try makeUploadManager(profileID: profileID, accountID: accountID)
        let model = makeModel(
            conversation: partial,
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: uploadManager
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.routingState, .unavailable)
        XCTAssertEqual(model.historyState, .cachedAfterFailure)
        XCTAssertEqual(model.messages, [cached])
        XCTAssertTrue(model.isShowingCache)
        XCTAssertEqual(model.draft, "Offline draft")
        XCTAssertTrue(model.canEditDraft)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canStageAttachments)

        await model.attach(data: Data("not-uploaded".utf8), filename: "blocked.txt", mimeType: "text/plain")
        XCTAssertEqual(
            model.errorMessage,
            "Attachments are available after this conversation’s server routing is verified."
        )
    }

    func testSettledFirstSendPromotesThenInstallsAuthoritativeConversationAndHistory() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let localID = ConversationID(localDraftID: UUID())
        let canonicalID = ConversationID(rawValue: "canonical")
        let authoritative = Conversation(
            id: canonicalID,
            title: "Server title",
            model: "server-model",
            target: ConversationTarget(endpoint: "agents", model: "server-model", agentID: "agent-1"),
            projectID: ProjectID(rawValue: "project-1")
        )
        let history = [ChatMessage(
            id: MessageID(rawValue: "server-response"),
            conversationID: canonicalID,
            content: [.text("Authoritative response")],
            author: .assistant(name: "Assistant")
        )]
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [canonicalID: authoritative],
            messages: history,
            sendOutcome: .settled(conversationID: canonicalID)
        )
        var callbacks: [(ConversationID, Conversation)] = []
        let model = makeModel(
            conversation: Conversation(
                id: localID,
                title: "New chat",
                target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            onConversationIdentityChanged: { callbacks.append(($0, $1)) }
        )
        await model.loadIfNeeded()
        model.draft = "First request"

        model.send()
        await waitUntil { !model.isStreaming }

        XCTAssertEqual(model.conversation, authoritative)
        XCTAssertEqual(model.messages, history)
        XCTAssertEqual(model.routingState, .authoritative)
        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertEqual(callbacks.count, 2)
        XCTAssertEqual(callbacks[0].0, localID)
        XCTAssertEqual(callbacks[0].1.id, canonicalID)
        XCTAssertNil(callbacks[0].1.target, "Promotion must not carry inferred local routing")
        XCTAssertEqual(callbacks[1].0, canonicalID)
        XCTAssertEqual(callbacks[1].1, authoritative)
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
        let requests = await repository.sentRequests()
        XCTAssertNil(requests.first?.parentMessageID, "Only an empty/new history may use the wire root sentinel")
    }

    func testForeignProfileGenerationReceiptCannotPromoteOrReplaceLocalConversation() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let localID = ConversationID(localDraftID: UUID())
        let foreignHandle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "other-profile"),
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: "foreign",
            conversationID: ConversationID(rawValue: "foreign"),
            generationCreatedAt: 1,
            protocolVersion: 2
        )
        let repository = HydrationRepositoryDouble(sendOutcome: .streaming(foreignHandle))
        var callbacks: [(ConversationID, Conversation)] = []
        let model = makeModel(
            conversation: Conversation(
                id: localID,
                title: "Local",
                target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            onConversationIdentityChanged: { callbacks.append(($0, $1)) }
        )
        await model.loadIfNeeded()
        model.draft = "Must stay local"

        model.send()
        await waitUntil { !model.isStreaming }

        XCTAssertEqual(model.conversation.id, localID)
        XCTAssertEqual(model.draft, "Must stay local")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(model.errorMessage, "LibreChat returned generation ownership for another server account.")
    }

    func testSelectedBranchProjectionControlsVisibleHistorySendParentAndShareTarget() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let root = branchMessage("root", parent: nil, conversationID: conversationID, user: true)
        let oldResponse = branchMessage(
            "old-response",
            parent: "root",
            conversationID: conversationID
        )
        let newResponse = branchMessage(
            "new-response",
            parent: "root",
            conversationID: conversationID
        )
        // The flat-array tail belongs to an unselected older branch.
        let oldBranchTail = branchMessage(
            "old-branch-tail",
            parent: "old-response",
            conversationID: conversationID,
            user: true
        )
        let history = [root, oldResponse, newResponse, oldBranchTail]
        let conversation = Conversation(
            id: conversationID,
            title: "Branched",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: conversation],
            messages: history,
            sendOutcome: .settled(conversationID: conversationID)
        )
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )

        await model.loadIfNeeded()

        XCTAssertEqual(model.visibleMessages.map(\.id), [root.id, newResponse.id])
        XCTAssertEqual(model.shareTargetMessageID, newResponse.id)
        XCTAssertNotEqual(model.shareTargetMessageID, history.last?.id)

        model.selectSibling(oldResponse.id, under: .message(root.id))
        XCTAssertEqual(
            model.visibleMessages.map(\.id),
            [root.id, oldResponse.id, oldBranchTail.id]
        )
        XCTAssertEqual(model.shareTargetMessageID, oldBranchTail.id)

        model.draft = "Continue this selected branch"
        model.send()
        await waitUntil { !model.isStreaming }

        let sent = await repository.sentRequests()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.parentMessageID, oldBranchTail.id)
        XCTAssertEqual(model.visibleMessages.map(\.id), [root.id, oldResponse.id, oldBranchTail.id])
        XCTAssertEqual(model.shareTargetMessageID, oldBranchTail.id)
    }

    func testRenderProjectionPreservesUnchangedRowsDuringOptimisticStreamingAppend() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "projection-conversation")
        let conversation = Conversation(
            id: conversationID,
            title: "Large branched projection",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let root = branchMessage("root", parent: nil, conversationID: conversationID, user: true)
        var history = [root]
        var selectedParent = root.id
        for index in 0..<256 {
            let sibling = branchMessage(
                "sibling-\(index)",
                parent: selectedParent.rawValue,
                conversationID: conversationID
            )
            let selected = branchMessage(
                "selected-\(index)",
                parent: selectedParent.rawValue,
                conversationID: conversationID
            )
            history.append(sibling)
            history.append(selected)
            selectedParent = selected.id
        }
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: conversation],
            messages: history,
            sendOutcome: .settled(conversationID: conversationID)
        )
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )

        await model.loadIfNeeded()
        let before = model.renderProjection
        XCTAssertTrue(before.isStructurallyValid)
        XCTAssertEqual(before.visibleEntries.count, 257)
        XCTAssertEqual(before.visibleMessageCount, before.visibleEntries.count)

        model.draft = "Continue the selected branch"
        model.send()
        let after = model.renderProjection

        XCTAssertTrue(model.isStreaming)
        XCTAssertGreaterThan(after.revision, before.revision)
        XCTAssertEqual(
            Array(after.visibleEntries.prefix(before.visibleEntries.count)),
            before.visibleEntries,
            "A streaming append must retain the value projections for existing rows."
        )
        XCTAssertEqual(
            Array(after.visibleMessages.prefix(before.visibleMessages.count)),
            before.visibleMessages
        )
        XCTAssertEqual(after.visibleMessageCount, before.visibleMessageCount + 2)
        XCTAssertNotEqual(after.lastVisibleMessageID, before.lastVisibleMessageID)
        XCTAssertGreaterThan(
            after.lastVisiblePlainTextRevision,
            before.lastVisiblePlainTextRevision
        )
    }

    func testRenderProjectionFailsClosedForInvalidGraph() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "projection-invalid")
        let conversation = Conversation(
            id: conversationID,
            title: "Invalid projection",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let orphan = branchMessage(
            "orphan",
            parent: "missing-parent",
            conversationID: conversationID
        )
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: conversation],
            messages: [orphan]
        )
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )

        await model.loadIfNeeded()

        XCTAssertFalse(model.renderProjection.isStructurallyValid)
        XCTAssertTrue(model.renderProjection.visibleEntries.isEmpty)
        XCTAssertTrue(model.renderProjection.visibleMessages.isEmpty)
        XCTAssertEqual(model.renderProjection.visibleMessageCount, 0)
        XCTAssertNil(model.renderProjection.lastVisibleMessageID)
        XCTAssertNil(model.renderProjection.lastVisiblePlainText)
    }

    func testStructuralMessageAnomalyFailsClosedBeforeGeneration() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let conversation = Conversation(
            id: conversationID,
            title: "Invalid graph",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let orphan = branchMessage(
            "orphan",
            parent: "missing-parent",
            conversationID: conversationID
        )
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: conversation],
            messages: [orphan],
            sendOutcome: .settled(conversationID: conversationID)
        )
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )

        await model.loadIfNeeded()
        model.draft = "Must not send"

        XCTAssertFalse(model.hasValidMessageTree)
        XCTAssertTrue(model.visibleMessages.isEmpty)
        XCTAssertFalse(model.canSend)
        XCTAssertNil(model.shareTargetMessageID)

        model.send()

        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(
            model.errorMessage,
            "LibreChat returned an inconsistent message tree. Refresh before sending."
        )
    }

    func testMessageSearchFocusSelectsExactAncestorBranch() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let root = branchMessage("root", parent: nil, conversationID: conversationID, user: true)
        let matchedResponse = branchMessage(
            "matched-response",
            parent: "root",
            conversationID: conversationID
        )
        let defaultResponse = branchMessage(
            "default-response",
            parent: "root",
            conversationID: conversationID
        )
        let matchedTail = branchMessage(
            "matched-tail",
            parent: "matched-response",
            conversationID: conversationID,
            user: true
        )
        let conversation = Conversation(
            id: conversationID,
            title: "Branched search",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: conversation],
            messages: [root, matchedResponse, defaultResponse, matchedTail]
        )
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )
        await model.loadIfNeeded()
        XCTAssertEqual(model.visibleMessages.map(\.id), [root.id, defaultResponse.id])

        let outcome = model.focusSearchResult(ConversationMessageFocusRequest(
            sequence: 1,
            conversationID: conversationID,
            messageID: matchedTail.id
        ))

        XCTAssertEqual(outcome, .focused(matchedTail.id))
        XCTAssertEqual(
            model.visibleMessages.map(\.id),
            [root.id, matchedResponse.id, matchedTail.id]
        )
    }

    func testMissingOrForeignMessageSearchFocusNeverGuessesAnotherBranch() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let conversationID = ConversationID(rawValue: "conversation")
        let root = branchMessage("root", parent: nil, conversationID: conversationID, user: true)
        let response = branchMessage("response", parent: "root", conversationID: conversationID)
        let conversation = Conversation(
            id: conversationID,
            title: "Search",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let repository = HydrationRepositoryDouble(
            authoritativeConversations: [conversationID: conversation],
            messages: [root, response]
        )
        let model = makeModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository
        )
        await model.loadIfNeeded()
        let originalVisibleIDs = model.visibleMessages.map(\.id)

        XCTAssertEqual(
            model.focusSearchResult(ConversationMessageFocusRequest(
                sequence: 1,
                conversationID: ConversationID(rawValue: "foreign"),
                messageID: response.id
            )),
            .unavailable
        )
        XCTAssertEqual(model.visibleMessages.map(\.id), originalVisibleIDs)
        XCTAssertNil(model.errorMessage)

        XCTAssertEqual(
            model.focusSearchResult(ConversationMessageFocusRequest(
                sequence: 2,
                conversationID: conversationID,
                messageID: MessageID(rawValue: "missing")
            )),
            .unavailable
        )
        XCTAssertEqual(model.visibleMessages.map(\.id), originalVisibleIDs)
        XCTAssertEqual(
            model.errorMessage,
            "The matched message is no longer available in this conversation."
        )
    }

    private func makeModel(
        conversation: Conversation,
        profileID: ServerProfileID,
        accountID: AccountID,
        repository: HydrationRepositoryDouble,
        uploadManager: UploadManager? = nil,
        canUseSkills: Bool = false,
        onConversationIdentityChanged: @escaping @MainActor (ConversationID, Conversation) -> Void = { _, _ in }
    ) -> ChatModel {
        ChatModel(
            conversation: conversation,
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: uploadManager,
            canGenerate: { true },
            canUseSkills: { canUseSkills },
            compatibilityWarning: { nil },
            onUnauthorized: {},
            onConversationIdentityChanged: onConversationIdentityChanged
        )
    }

    private func branchMessage(
        _ id: String,
        parent: String?,
        conversationID: ConversationID,
        user: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: conversationID,
            parentMessageID: parent.map(MessageID.init(rawValue:)),
            content: [.text(id)],
            author: user ? .user : .assistant(name: "Assistant"),
            createdAt: Date(timeIntervalSince1970: TimeInterval(id.utf8.count))
        )
    }

    private func makeUploadManager(
        profileID: ServerProfileID,
        accountID: AccountID
    ) throws -> UploadManager {
        let dependencies = try AppDependencies(inMemory: true)
        let baseURL = URL(string: "https://chat.example.com")!
        let jar = ProfileCookieJar(
            profileID: profileID,
            baseURL: baseURL,
            secretStore: HydrationSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let authentication = LibreChatProtocol.AuthSession.isolated(transport: transport)
        let runtime = LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: authentication,
            restClient: RESTClient(transport: transport, authSession: authentication)
        )
        return UploadManager(
            profileID: profileID,
            accountID: accountID,
            runtime: runtime,
            cache: dependencies.cache
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for ChatModel async work")
    }
}

private actor HydrationRepositoryDouble: ChatFeatureRepository {
    private let authoritativeConversations: [ConversationID: Conversation]
    private let cachedMessageValues: [ChatMessage]
    private let messageValues: [ChatMessage]
    private let conversationError: LibreChatProtocolError?
    private let messagesError: LibreChatProtocolError?
    private let sendOutcome: ChatSendOutcome?
    private let skillCatalogValue: SkillInvocationCatalog?
    private var draftValues: [ConversationID: String]
    private var sends = 0
    private var requests: [ChatRequest] = []

    init(
        authoritativeConversations: [ConversationID: Conversation] = [:],
        cachedMessages: [ChatMessage] = [],
        messages: [ChatMessage] = [],
        conversationError: LibreChatProtocolError? = nil,
        messagesError: LibreChatProtocolError? = nil,
        drafts: [ConversationID: String] = [:],
        sendOutcome: ChatSendOutcome? = nil,
        skillCatalog: SkillInvocationCatalog? = nil
    ) {
        self.authoritativeConversations = authoritativeConversations
        cachedMessageValues = cachedMessages
        messageValues = messages
        self.conversationError = conversationError
        self.messagesError = messagesError
        draftValues = drafts
        self.sendOutcome = sendOutcome
        skillCatalogValue = skillCatalog
    }

    func sendCount() -> Int { sends }
    func sentRequests() -> [ChatRequest] { requests }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) throws -> Conversation {
        if let conversationError { throw conversationError }
        guard let conversation = authoritativeConversations[id] else {
            throw LibreChatProtocolError.httpStatus(404, message: "Not found", retryAfter: nil)
        }
        return conversation
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { cachedMessageValues }
    func messages(conversationID: ConversationID) throws -> [ChatMessage] {
        if let messagesError { throw messagesError }
        return messageValues
    }
    func searchConversations(query: String, cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) -> MessageSearchPage { MessageSearchPage(results: []) }
    func availableChatTargets() -> [ChatTargetOption] { [] }
    func createConversation(title: String, target: ConversationTarget) -> Conversation {
        Conversation(id: ConversationID(localDraftID: UUID()), title: title, target: target)
    }
    func delete(id: ConversationID) {}

    func send(_ request: ChatRequest) throws -> ChatSendOutcome {
        sends += 1
        requests.append(request)
        guard let sendOutcome else { throw LibreChatProtocolError.invalidResponse }
        return sendOutcome
    }
    func skillInvocationCatalog(for target: ConversationTarget) throws -> SkillInvocationCatalog {
        guard let skillCatalogValue, skillCatalogValue.target == target else {
            throw SkillInvocationError.unavailable
        }
        return skillCatalogValue
    }
    func snapshots(for handle: GenerationHandle) -> AsyncThrowingStream<GenerationSnapshot, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func resume(_ generation: GenerationHandle) {}
    func reconcile(_ generation: GenerationHandle) -> GenerationSnapshot {
        GenerationSnapshot(handle: generation, state: .reconciling)
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
    func draft(conversationID: ConversationID) -> String { draftValues[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) {
        draftValues[conversationID] = text
    }
}

private actor HydrationSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}
