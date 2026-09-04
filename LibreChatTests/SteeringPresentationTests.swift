import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

final class SteeringPresentationTests: XCTestCase {
    func testDraftTrimsBoundariesAndRemovesNullsBeforeCounting() {
        let state = GenerationSteerDraftState(draft: " \nUse\0 a table  \n")

        XCTAssertEqual(state.normalizedText, "Use a table")
        XCTAssertEqual(state.utf16Count, 11)
        XCTAssertTrue(state.canSubmit)
        XCTAssertNil(state.validationMessage)
    }

    func testDraftRejectsEmptyAndUTF16Overflow() {
        let empty = GenerationSteerDraftState(draft: " \0\n ")
        XCTAssertFalse(empty.canSubmit)
        XCTAssertEqual(empty.validationMessage, "Write how you want the current response to change.")

        let overflow = GenerationSteerDraftState(
            draft: String(repeating: "😀", count: 8_001)
        )
        XCTAssertEqual(overflow.utf16Count, 16_002)
        XCTAssertFalse(overflow.canSubmit)
        XCTAssertEqual(
            overflow.validationMessage,
            "Shorten this direction to 16,000 characters or fewer."
        )
    }

    func testSelectionIdentityIncludesExactGenerationEpochAndClientIdentity() {
        let base = selection(epoch: 1_000, clientSteerID: "client-a")
        let same = selection(epoch: 1_000, clientSteerID: "client-a")
        let replacement = selection(epoch: 2_000, clientSteerID: "client-a")
        let secondAttempt = selection(epoch: 1_000, clientSteerID: "client-b")

        XCTAssertEqual(base, same)
        XCTAssertEqual(base.id, same.id)
        XCTAssertNotEqual(base.id, replacement.id)
        XCTAssertNotEqual(base.id, secondAttempt.id)
    }

    func testPresentationErrorsUseFiniteNonServerCopy() {
        XCTAssertEqual(
            GenerationSteeringPresentationError.from(
                GenerationSteeringError.textTooLong(maximumUTF16Length: 16_000)
            ),
            .invalidText
        )
        XCTAssertEqual(
            GenerationSteeringPresentationError.from(
                GenerationSteeringError.inactiveGeneration
            ),
            .generationChanged
        )
        XCTAssertEqual(
            GenerationSteeringPresentationError.from(
                GenerationSteeringPresentationError.staleAcknowledgement
            ),
            .staleAcknowledgement
        )
        XCTAssertEqual(
            GenerationSteeringPresentationError.from(
                LibreChatProtocolError.httpStatus(
                    500,
                    message: "https://private.invalid/secret",
                    retryAfter: nil
                )
            ),
            .rejected
        )
        XCTAssertFalse(
            GenerationSteeringPresentationError.rejected.localizedDescription
                .contains("private.invalid")
        )
    }

    private func selection(
        epoch: Int64,
        clientSteerID: String
    ) -> GenerationSteerSelection {
        GenerationSteerSelection(
            handle: GenerationHandle(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000091")!,
                streamID: "conversation",
                conversationID: ConversationID(rawValue: "conversation"),
                generationCreatedAt: epoch,
                protocolVersion: 2
            ),
            clientSteerID: clientSteerID
        )
    }
}

@MainActor
final class SteeringModelFenceTests: XCTestCase {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "conversation")

    func testStaleSubmitAcknowledgementDoesNotMutateReplacementGeneration() async throws {
        let oldHandle = handle(epoch: 1_000, request: 1)
        let newHandle = handle(epoch: 2_000, request: 2)
        let repository = SteeringFenceRepositoryDouble()
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let firstRecovery = Task {
            await model.applyForegroundGenerationRecovery(signal(for: oldHandle, sequence: 1))
        }
        await waitUntil { model.generationSnapshot?.handle == oldHandle && model.isStreaming }

        let selection = try XCTUnwrap(model.generationSteerSelection())
        let submit = Task {
            try await model.submitSteer(selection, text: "Use a table", preempt: false)
        }
        await repository.waitForSubmit()

        model.installAuthoritativeGenerationForTesting(
            GenerationSnapshot(handle: newHandle, state: .streaming)
        )

        await repository.releaseSubmit(.deliveryUncertain(.init(
            clientSteerID: selection.clientSteerID,
            steerID: "old-steer",
            reason: .transport
        )))

        do {
            _ = try await submit.value
            XCTFail("Expected a stale acknowledgement")
        } catch let error as GenerationSteeringPresentationError {
            XCTAssertEqual(error, .staleAcknowledgement)
        }
        XCTAssertEqual(model.generationSnapshot?.handle, newHandle)
        XCTAssertTrue(model.generationSnapshot?.pendingSteers.isEmpty == true)
        XCTAssertNil(model.steeringStatusMessage)

        firstRecovery.cancel()
    }

    func testStaleCancelResultDoesNotMutateReplacementGeneration() async throws {
        let oldHandle = handle(epoch: 1_000, request: 3)
        let newHandle = handle(epoch: 2_000, request: 4)
        let pending = PendingSteer(id: "old-steer", clientSteerID: "client-old", text: "old")
        let repository = SteeringFenceRepositoryDouble()
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let firstRecovery = Task {
            await model.applyForegroundGenerationRecovery(
                signal(for: oldHandle, sequence: 10, pendingSteers: [pending])
            )
        }
        await waitUntil {
            model.generationSnapshot?.handle == oldHandle
                && model.generationSnapshot?.pendingSteers == [pending]
        }
        model.cancelPendingSteer(pending)
        await repository.waitForCancel()

        model.installAuthoritativeGenerationForTesting(
            GenerationSnapshot(handle: newHandle, state: .streaming)
        )
        await repository.releaseCancel(.deliveryUncertain(.init(
            clientSteerID: "client-old",
            steerID: "old-steer",
            reason: .invalidAcknowledgement
        )))

        await Task.yield()
        XCTAssertEqual(model.generationSnapshot?.handle, newHandle)
        XCTAssertTrue(model.generationSnapshot?.pendingSteers.isEmpty == true)
        XCTAssertNil(model.steeringStatusMessage)

        firstRecovery.cancel()
    }

    func testStaleArmResultDoesNotMutateReplacementGeneration() async throws {
        let oldHandle = handle(epoch: 1_000, request: 5)
        let newHandle = handle(epoch: 2_000, request: 6)
        let pending = PendingSteer(id: "old-steer", clientSteerID: "client-old", text: "old")
        let repository = SteeringFenceRepositoryDouble()
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let firstRecovery = Task {
            await model.applyForegroundGenerationRecovery(
                signal(for: oldHandle, sequence: 20, pendingSteers: [pending])
            )
        }
        await waitUntil {
            model.generationSnapshot?.handle == oldHandle
                && model.generationSnapshot?.pendingSteers == [pending]
        }
        model.armPendingSteer(pending)
        await repository.waitForArm()

        model.installAuthoritativeGenerationForTesting(
            GenerationSnapshot(handle: newHandle, state: .streaming)
        )
        await repository.releaseArm(.deliveryUncertain(.init(
            clientSteerID: "client-old",
            steerID: "old-steer",
            reason: .server(status: 503, code: "TEMPORARY")
        )))

        await Task.yield()
        XCTAssertEqual(model.generationSnapshot?.handle, newHandle)
        XCTAssertTrue(model.generationSnapshot?.pendingSteers.isEmpty == true)
        XCTAssertNil(model.steeringStatusMessage)

        firstRecovery.cancel()
    }

    private func makeModel(repository: SteeringFenceRepositoryDouble) -> ChatModel {
        ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Source",
                target: ConversationTarget(endpoint: "openAI", model: "test-model")
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
    }

    private func handle(epoch: Int64, request: UInt8) -> GenerationHandle {
        GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", request))")!,
            streamID: conversationID.rawValue,
            conversationID: conversationID,
            generationCreatedAt: epoch,
            protocolVersion: 2
        )
    }

    private func signal(
        for handle: GenerationHandle,
        sequence: UInt64,
        pendingSteers: [PendingSteer] = []
    ) -> GenerationRecoverySignal {
        GenerationRecoverySignal(
            sequence: sequence,
            profileID: profileID,
            accountID: accountID,
            activeSnapshots: [GenerationSnapshot(
                handle: handle,
                state: .streaming,
                pendingSteers: pendingSteers
            )]
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the fenced operation")
    }
}

private actor SteeringFenceRepositoryDouble: ChatFeatureRepository {
    private var submitContinuation: CheckedContinuation<GenerationSteerSubmissionOutcome, any Error>?
    private var cancelContinuation: CheckedContinuation<GenerationSteerCancelOutcome, any Error>?
    private var armContinuation: CheckedContinuation<GenerationSteerArmOutcome, any Error>?
    private var submitRequestCount = 0
    private var cancelRequestCount = 0
    private var armRequestCount = 0

    func waitForSubmit() async {
        for _ in 0..<500 {
            if submitRequestCount > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for submit")
    }

    func waitForCancel() async {
        for _ in 0..<500 {
            if cancelRequestCount > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for cancel")
    }

    func waitForArm() async {
        for _ in 0..<500 {
            if armRequestCount > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for arm")
    }

    func releaseSubmit(_ outcome: GenerationSteerSubmissionOutcome) {
        submitContinuation?.resume(returning: outcome)
        submitContinuation = nil
    }

    func releaseCancel(_ outcome: GenerationSteerCancelOutcome) {
        cancelContinuation?.resume(returning: outcome)
        cancelContinuation = nil
    }

    func releaseArm(_ outcome: GenerationSteerArmOutcome) {
        armContinuation?.resume(returning: outcome)
        armContinuation = nil
    }

    func submitSteer(_ request: GenerationSteerRequest) async throws -> GenerationSteerSubmissionOutcome {
        submitRequestCount += 1
        return try await withCheckedThrowingContinuation { submitContinuation = $0 }
    }

    func cancelSteer(_ request: GenerationSteerControlRequest) async throws -> GenerationSteerCancelOutcome {
        cancelRequestCount += 1
        return try await withCheckedThrowingContinuation { cancelContinuation = $0 }
    }

    func armSteer(_ request: GenerationSteerControlRequest) async throws -> GenerationSteerArmOutcome {
        armRequestCount += 1
        return try await withCheckedThrowingContinuation { armContinuation = $0 }
    }

    func cachedConversations(limit: Int) async throws -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) async throws -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) async throws -> Conversation {
        Conversation(
            id: id,
            title: "Source",
            target: ConversationTarget(endpoint: "openAI", model: "test-model")
        )
    }
    func cachedMessages(conversationID: ConversationID) async throws -> [ChatMessage] {
        try await messages(conversationID: conversationID)
    }
    func messages(conversationID: ConversationID) async throws -> [ChatMessage] {
        [ChatMessage(
            id: MessageID(rawValue: "user"),
            conversationID: conversationID,
            content: [.text("Prompt")],
            author: .user
        )]
    }
    func searchConversations(query: String, cursor: String?, limit: Int) async throws -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) async throws -> MessageSearchPage {
        MessageSearchPage(results: [])
    }
    func availableChatTargets() async throws -> [ChatTargetOption] { [] }
    func createConversation(title: String, target: ConversationTarget) async throws -> Conversation {
        Conversation(id: ConversationID(localDraftID: UUID()), title: title, target: target)
    }
    func delete(id: ConversationID) async throws {}
    func send(_ request: ChatRequest) async throws -> ChatSendOutcome {
        .settled(conversationID: request.conversation.id)
    }
    func snapshots(for handle: GenerationHandle) async -> AsyncThrowingStream<GenerationSnapshot, Error> {
        AsyncThrowingStream { _ in }
    }
    func resume(_ generation: GenerationHandle) async throws {}
    func reconcile(_ generation: GenerationHandle) async throws -> GenerationSnapshot {
        GenerationSnapshot(handle: generation, state: .streaming)
    }
    func recoverActiveGenerations() async throws -> [GenerationSnapshot] { [] }
    func stop(_ generation: GenerationHandle) async throws {}
    func saveMessageEdit(_ request: MessageEditRequest) async throws -> MessageEditResult {
        throw MessageEditPresentationError.unavailable
    }
    func respond(
        to interaction: PendingInteraction,
        handle: GenerationHandle,
        toolResolutions: [ToolApprovalResolution]?,
        answer: String?,
        batchAnswers: [String: String]?
    ) async throws -> GenerationSnapshot {
        GenerationSnapshot(handle: handle, state: .streaming)
    }
    func recoverableGenerations() async throws -> [GenerationSnapshot] { [] }
    func draft(conversationID: ConversationID) async -> String { "" }
    func saveDraft(_ text: String, conversationID: ConversationID) async {}
}
