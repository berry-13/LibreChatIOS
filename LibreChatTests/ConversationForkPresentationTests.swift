import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

final class ConversationForkPresentationTests: XCTestCase {
    func testSelectionIdentityIsExactToProfileAccountConversationAndMessage() {
        let base = selection(profile: "p", account: "a", conversation: "c", message: "m")

        XCTAssertEqual(base, selection(profile: "p", account: "a", conversation: "c", message: "m"))
        XCTAssertNotEqual(base.id, selection(profile: "p2", account: "a", conversation: "c", message: "m").id)
        XCTAssertNotEqual(base.id, selection(profile: "p", account: "a2", conversation: "c", message: "m").id)
        XCTAssertNotEqual(base.id, selection(profile: "p", account: "a", conversation: "c2", message: "m").id)
        XCTAssertNotEqual(base.id, selection(profile: "p", account: "a", conversation: "c", message: "m2").id)
    }

    func testPostDispatchFailuresUseNonRetryingUncertaintyCopy() {
        for error in [
            LibreChatProtocolError.transport("https://private.invalid/secret"),
            LibreChatProtocolError.invalidResponse,
            LibreChatProtocolError.decoding("private payload"),
            LibreChatProtocolError.httpStatus(
                503,
                message: "private server body",
                retryAfter: nil
            )
        ] {
            let mapped = ConversationForkPresentationError.from(error)
            XCTAssertEqual(mapped, .deliveryUncertain)
            XCTAssertFalse(mapped.localizedDescription.contains("private"))
        }
    }

    func testDefiniteRejectionAndStaleSelectionRemainDistinct() {
        XCTAssertEqual(
            ConversationForkPresentationError.from(
                LibreChatProtocolError.httpStatus(403, message: "denied", retryAfter: nil)
            ),
            .rejected
        )
        XCTAssertEqual(
            ConversationForkPresentationError.from(ConversationForkPresentationError.stale),
            .stale
        )
        XCTAssertEqual(
            ConversationForkPresentationError.from(ConversationForkError.preflightReadFailed),
            .preflightUnavailable
        )
        XCTAssertEqual(
            ConversationForkPresentationError.from(ConversationForkError.ambiguous),
            .deliveryUncertain
        )
    }

    private func selection(
        profile: String,
        account: String,
        conversation: String,
        message: String
    ) -> ConversationForkSelection {
        let conversationID = ConversationID(rawValue: conversation)
        return ConversationForkSelection(
            profileID: ServerProfileID(rawValue: profile),
            accountID: AccountID(rawValue: account),
            sourceConversationID: conversationID,
            targetMessage: ChatMessage(
                id: MessageID(rawValue: message),
                conversationID: conversationID,
                content: [.text("Message")],
                author: .user
            )
        )
    }
}

@MainActor
final class ConversationForkModelTests: XCTestCase {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "conversation")

    func testExactVisibleMessageForkIsOneShotAndDoesNotMutateSourceHistory() async throws {
        let source = sourceMessages()
        let repository = ConversationForkModelRepositoryDouble(
            sourceMessages: source,
            behavior: .suspended
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Next message"
        let selection = try XCTUnwrap(
            model.conversationForkSelection(for: MessageID(rawValue: "assistant"))
        )

        let task = Task { try await model.forkConversation(selection) }
        await waitForFork(repository)
        XCTAssertTrue(model.isForkingConversation)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.messages, source)

        await repository.completeSuspendedFork()
        let result = try await task.value
        XCTAssertEqual(result.conversation.id, ConversationID(rawValue: "forked"))
        XCTAssertEqual(model.messages, source)
        XCTAssertFalse(model.isForkingConversation)
        let requests = await repository.forkRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].profileID, profileID)
        XCTAssertEqual(requests[0].accountID, accountID)
        XCTAssertEqual(requests[0].conversationID, conversationID)
        XCTAssertEqual(requests[0].targetMessageID, MessageID(rawValue: "assistant"))
        XCTAssertEqual(requests[0].option, .directPath)
        XCTAssertFalse(requests[0].splitAtTarget)
        XCTAssertNil(requests[0].latestMessageID)
    }

    func testAmbiguousForkLocksExactTargetButPreflightFailureRemainsRetryable() async throws {
        let ambiguousRepository = ConversationForkModelRepositoryDouble(
            sourceMessages: sourceMessages(),
            behavior: .ambiguous
        )
        let ambiguousModel = makeModel(repository: ambiguousRepository)
        await ambiguousModel.loadIfNeeded()
        let ambiguousSelection = try XCTUnwrap(
            ambiguousModel.conversationForkSelection(for: MessageID(rawValue: "assistant"))
        )
        do {
            _ = try await ambiguousModel.forkConversation(ambiguousSelection)
            XCTFail("Expected a typed outcome-unknown fork")
        } catch let error as ConversationForkPresentationError {
            XCTAssertEqual(error, .deliveryUncertain)
        }
        XCTAssertNil(
            ambiguousModel.conversationForkSelection(for: MessageID(rawValue: "assistant")),
            "The same source/target must not mint another non-idempotent fork in this model lifetime"
        )
        let ambiguousCalls = await ambiguousRepository.forkRequests().count
        XCTAssertEqual(ambiguousCalls, 1)

        let preflightRepository = ConversationForkModelRepositoryDouble(
            sourceMessages: sourceMessages(),
            behavior: .preflightUnavailable
        )
        let preflightModel = makeModel(repository: preflightRepository)
        await preflightModel.loadIfNeeded()
        let preflightSelection = try XCTUnwrap(
            preflightModel.conversationForkSelection(for: MessageID(rawValue: "assistant"))
        )
        do {
            _ = try await preflightModel.forkConversation(preflightSelection)
            XCTFail("Expected a preflight read failure")
        } catch let error as ConversationForkPresentationError {
            XCTAssertEqual(error, .preflightUnavailable)
        }
        XCTAssertNotNil(
            preflightModel.conversationForkSelection(for: MessageID(rawValue: "assistant")),
            "A typed zero-POST preflight failure remains safe for explicit retry"
        )
    }

    func testCompletionRejectsSourceConversationCollisionAndLocksTarget() async throws {
        let repository = ConversationForkModelRepositoryDouble(
            sourceMessages: sourceMessages(),
            behavior: .success,
            resultConversationID: conversationID
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(
            model.conversationForkSelection(for: MessageID(rawValue: "assistant"))
        )

        do {
            _ = try await model.forkConversation(selection)
            XCTFail("Expected a source-conversation collision to be rejected")
        } catch let error as ConversationForkPresentationError {
            XCTAssertEqual(error, .invalidResult)
        }
        XCTAssertNil(
            model.conversationForkSelection(for: MessageID(rawValue: "assistant")),
            "An invalid completion must not be offered again without authoritative review"
        )
        let requests = await repository.forkRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testProfileAccountAndConversationSelectionIdentityChangesFailBeforeDispatch() async throws {
        let repository = ConversationForkModelRepositoryDouble(
            sourceMessages: sourceMessages(),
            behavior: .success
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(
            model.conversationForkSelection(for: MessageID(rawValue: "assistant"))
        )
        let mismatches = [
            ConversationForkSelection(
                profileID: ServerProfileID(rawValue: "other-profile"),
                accountID: selection.accountID,
                sourceConversationID: selection.sourceConversationID,
                targetMessage: selection.targetMessage
            ),
            ConversationForkSelection(
                profileID: selection.profileID,
                accountID: AccountID(rawValue: "other-account"),
                sourceConversationID: selection.sourceConversationID,
                targetMessage: selection.targetMessage
            ),
            ConversationForkSelection(
                profileID: selection.profileID,
                accountID: selection.accountID,
                sourceConversationID: ConversationID(rawValue: "other-conversation"),
                targetMessage: selection.targetMessage
            )
        ]

        for mismatch in mismatches {
            do {
                _ = try await model.forkConversation(mismatch)
                XCTFail("Expected stale identity to be rejected")
            } catch let error as ConversationForkPresentationError {
                XCTAssertEqual(error, .stale)
            }
        }
        let requests = await repository.forkRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func makeModel(
        repository: ConversationForkModelRepositoryDouble
    ) -> ChatModel {
        ChatModel(
            conversation: Conversation(id: conversationID, title: "Source"),
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

    private func sourceMessages() -> [ChatMessage] {
        [
            ChatMessage(
                id: MessageID(rawValue: "user"),
                conversationID: conversationID,
                content: [.text("Prompt")],
                author: .user
            ),
            ChatMessage(
                id: MessageID(rawValue: "assistant"),
                conversationID: conversationID,
                parentMessageID: MessageID(rawValue: "user"),
                content: [.text("Response")],
                author: .assistant(name: "Assistant"),
                model: "test-model",
                endpoint: "openAI",
                isUnfinished: false,
                finishReason: "stop"
            )
        ]
    }

    private func waitForFork(_ repository: ConversationForkModelRepositoryDouble) async {
        for _ in 0..<500 {
            if await repository.forkRequests().isEmpty == false { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the suspended fork request")
    }
}

private actor ConversationForkModelRepositoryDouble: ChatFeatureRepository {
    enum Behavior: Sendable {
        case success
        case suspended
        case ambiguous
        case preflightUnavailable
    }

    private let sourceMessages: [ChatMessage]
    private let behavior: Behavior
    private let resultConversationID: ConversationID?
    private var requests: [ConversationForkRequest] = []
    private var continuation: CheckedContinuation<ConversationForkResult, any Error>?
    private var drafts: [ConversationID: String] = [:]

    init(
        sourceMessages: [ChatMessage],
        behavior: Behavior,
        resultConversationID: ConversationID? = nil
    ) {
        self.sourceMessages = sourceMessages
        self.behavior = behavior
        self.resultConversationID = resultConversationID
    }

    func forkRequests() -> [ConversationForkRequest] { requests }

    func completeSuspendedFork() {
        continuation?.resume(returning: result())
        continuation = nil
    }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) -> Conversation {
        Conversation(
            id: id,
            title: "Source",
            target: ConversationTarget(endpoint: "openAI", model: "test-model")
        )
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { sourceMessages }
    func messages(conversationID: ConversationID) -> [ChatMessage] { sourceMessages }
    func searchConversations(query: String, cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) -> MessageSearchPage { MessageSearchPage(results: []) }
    func availableChatTargets() -> [ChatTargetOption] { [] }
    func createConversation(title: String, target: ConversationTarget) -> Conversation {
        Conversation(id: ConversationID(localDraftID: UUID()), title: title, target: target)
    }
    func delete(id: ConversationID) {}

    func fork(_ request: ConversationForkRequest) async throws -> ConversationForkResult {
        requests.append(request)
        switch behavior {
        case .success:
            return result()
        case .suspended:
            return try await withCheckedThrowingContinuation { continuation = $0 }
        case .ambiguous:
            throw ConversationForkError.ambiguous
        case .preflightUnavailable:
            throw ConversationForkError.preflightReadFailed
        }
    }

    func send(_ request: ChatRequest) -> ChatSendOutcome {
        .settled(conversationID: request.conversation.id)
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
    ) -> GenerationSnapshot {
        GenerationSnapshot(handle: handle, state: .streaming)
    }
    func recoverableGenerations() -> [GenerationSnapshot] { [] }
    func draft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) { drafts[conversationID] = text }

    private func result() -> ConversationForkResult {
        let forkedID = resultConversationID ?? ConversationID(rawValue: "forked")
        return ConversationForkResult(
            conversation: Conversation(
                id: forkedID,
                title: "Source",
                target: ConversationTarget(endpoint: "openAI", model: "test-model")
            ),
            messages: [
                ChatMessage(
                    id: MessageID(rawValue: "forked-user"),
                    conversationID: forkedID,
                    content: [.text("Prompt")],
                    author: .user
                )
            ]
        )
    }
}
