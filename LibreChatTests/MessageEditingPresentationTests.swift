import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class MessageEditingPresentationTests: XCTestCase {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "conversation")

    func testEligibilityUsesVisibleExactCoordinatesAndExcludesUnsafeText() async {
        let root = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "User text")]
        )
        let assistant = message(
            id: "assistant",
            parent: "root",
            author: .assistant(name: "Assistant"),
            catalog: [
                .init(location: .primaryText, text: "Answer"),
                .init(location: .contentPart(index: 2, kind: .reasoning), text: "Reasoning"),
                .init(
                    location: .contentPart(index: 5, kind: .text),
                    text: ":::artifact{identifier=\"notes\" type=\"text/plain\" title=\"Notes\"}\nBody\n:::"
                ),
                .init(
                    location: .contentPart(index: 6, kind: .text),
                    text: ":::artifact{identifier=\"partial\" type=\"text/plain\" title=\"Partial\"}\nunfinished"
                ),
                .init(location: .contentPart(index: 8, kind: .text), text: "Cited \u{E202}turn0search0"),
                .init(location: .contentPart(index: 9, kind: .text), text: #"Cited \ue202turn0search0"#)
            ]
        )
        let oldSibling = message(
            id: "old-sibling",
            parent: "root",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Hidden")]
        )
        // Incoming ordinal makes `assistant` the selected sibling.
        let repository = MessageEditRepositoryDouble(messages: [root, oldSibling, assistant])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let rootSelections = model.editableMessageTextSelections(for: root.id)
        XCTAssertEqual(rootSelections.map(\.title), ["Edit saved message text"])
        XCTAssertTrue(rootSelections[0].hasDescendants)

        let assistantSelections = model.editableMessageTextSelections(for: assistant.id)
        XCTAssertEqual(assistantSelections.map(\.coordinate.location), [
            .primaryText,
            .contentPart(index: 2, kind: .reasoning)
        ])
        XCTAssertEqual(assistantSelections.map(\.title), [
            "Edit saved response text",
            "Edit reasoning part 3"
        ])
        XCTAssertTrue(model.editableMessageTextSelections(for: oldSibling.id).isEmpty)
    }

    func testDuplicateCoordinateAndUnfinishedOrLocalMessagesFailClosed() async {
        let duplicate = message(
            id: "duplicate",
            author: .user,
            catalog: [
                .init(location: .primaryText, text: "One"),
                .init(location: .primaryText, text: "Two")
            ]
        )
        var unfinished = message(
            id: "unfinished",
            parent: "duplicate",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Partial")]
        )
        unfinished.isUnfinished = true
        let local = message(
            id: "local-user-fixture",
            parent: "unfinished",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Local")]
        )
        let repository = MessageEditRepositoryDouble(messages: [duplicate, unfinished, local])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertTrue(model.editableMessageTextSelections(for: duplicate.id).isEmpty)
        XCTAssertTrue(model.editableMessageTextSelections(for: unfinished.id).isEmpty)
        XCTAssertTrue(model.editableMessageTextSelections(for: local.id).isEmpty)
    }

    func testArtifactEditRequiresExactAuthoritativeVisibleCatalogBeforeRepositoryMutation() async throws {
        let root = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Build an artifact")]
        )
        let artifact = parsedArtifact(messageID: "assistant", source: "Before\n")
        let assistant = ChatMessage(
            id: artifact.identity.messageID,
            conversationID: conversationID,
            parentMessageID: root.id,
            content: [.text(artifact.rawContainer)],
            author: .assistant(name: "Assistant"),
            isUnfinished: false,
            artifactCatalog: [artifact]
        )
        let repository = MessageEditRepositoryDouble(messages: [root, assistant])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertTrue(model.canEditArtifacts(in: assistant.id))
        try await model.editArtifact(artifact, updatedContent: "After\n")
        let requests = await repository.artifactRequestsReceived()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.identity, artifact.identity)
        XCTAssertEqual(requests.first?.originalContent, "Before\n")
        XCTAssertEqual(requests.first?.updatedContent, "After\n")

        let stale = parsedArtifact(messageID: "assistant", source: "Stale baseline\n")
        do {
            try await model.editArtifact(stale, updatedContent: "Never sent\n")
            XCTFail("A stale artifact baseline must fail before transport")
        } catch let error as ArtifactEditError {
            XCTAssertEqual(error, .changedOnServer)
        }
        let requestsAfterStaleAttempt = await repository.artifactRequestsReceived()
        XCTAssertEqual(requestsAfterStaleAttempt.count, 1)
    }

    func testArtifactEditIsUnavailableForCachedHistoryAfterRefreshFailure() async {
        let artifact = parsedArtifact(messageID: "assistant", source: "Cached\n")
        let assistant = ChatMessage(
            id: artifact.identity.messageID,
            conversationID: conversationID,
            content: [.text(artifact.rawContainer)],
            author: .assistant(name: "Assistant"),
            isUnfinished: false,
            artifactCatalog: [artifact]
        )
        let repository = MessageEditRepositoryDouble(
            messages: [assistant],
            cachedMessages: [assistant],
            messagesError: .transport("offline")
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertFalse(model.canEditArtifacts(in: assistant.id))
        do {
            try await model.editArtifact(artifact, updatedContent: "Offline change\n")
            XCTFail("Cached history must not admit an artifact mutation")
        } catch let error as ArtifactEditError {
            XCTAssertEqual(error, .unavailable)
        } catch {
            XCTFail("Expected ArtifactEditError.unavailable, got \(error)")
        }
        let requests = await repository.artifactRequestsReceived()
        XCTAssertEqual(requests.count, 0)
    }

    func testArtifactEditBlocksActiveRecoveringAndPendingInteractionGenerations() async throws {
        let (root, assistant, artifact) = artifactThread()
        let repository = MessageEditRepositoryDouble(messages: [root, assistant])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        XCTAssertTrue(model.canEditArtifacts(in: assistant.id))

        let handle = GenerationHandle(
            profileID: profileID,
            accountID: accountID,
            clientRequestID: UUID(),
            streamID: conversationID.rawValue,
            conversationID: conversationID,
            generationCreatedAt: 2_000,
            protocolVersion: 2
        )
        let pending = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Choose a source")
        )
        let snapshots: [GenerationSnapshot] = [
            GenerationSnapshot(handle: handle, state: .streaming),
            GenerationSnapshot(handle: handle, state: .reconciling),
            GenerationSnapshot(
                handle: handle,
                state: .awaitingApproval(pending),
                pendingInteraction: pending
            )
        ]

        for snapshot in snapshots {
            model.installAuthoritativeGenerationForTesting(snapshot)
            XCTAssertFalse(model.canEditArtifacts(in: assistant.id))
            do {
                try await model.editArtifact(artifact, updatedContent: "Unsafe update\n")
                XCTFail("A nonterminal generation must retain artifact mutation ownership")
            } catch let error as ArtifactEditError {
                XCTAssertEqual(error, .unavailable)
            }
        }
        let requests = await repository.artifactRequestsReceived()
        XCTAssertTrue(requests.isEmpty)
    }

    func testArtifactEditRechecksPersistedSourceImmediatelyBeforePost() async throws {
        let (root, assistant, current) = artifactThread(source: "Server source\n")
        let repository = MessageEditRepositoryDouble(messages: [root, assistant])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        let stale = parsedArtifact(messageID: "assistant", source: "Sheet source\n")
        do {
            try await model.editArtifact(stale, updatedContent: "My draft\n")
            XCTFail("A source changed since sheet selection must not post")
        } catch let error as ArtifactEditError {
            XCTAssertEqual(error, .changedOnServer)
        }
        let requests = await repository.artifactRequestsReceived()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(model.messages.first(where: { $0.id == current.identity.messageID }), assistant)
    }

    func testArtifactEditInvalidatesSessionOn401WithoutApplyingDraftOptimistically() async throws {
        let (root, assistant, artifact) = artifactThread()
        // The transport's response validator maps every HTTP 401 to the
        // semantic `.unauthorized` error before repositories see it.
        let repository = MessageEditRepositoryDouble(
            messages: [root, assistant],
            artifactBehavior: .protocolFailure(.unauthorized)
        )
        var invalidationCount = 0
        let model = makeModel(repository: repository, onUnauthorized: {
            invalidationCount += 1
        })
        await model.loadIfNeeded()

        do {
            try await model.editArtifact(artifact, updatedContent: "Unsaved draft\n")
            XCTFail("Expected session invalidation")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(model.historyState, .unavailable)
        XCTAssertTrue(model.messages.isEmpty)
        let requests = await repository.artifactRequestsReceived()
        XCTAssertEqual(requests.count, 1)
    }

    func testSuspendedSaveDoesNotOptimisticallyMutateAndFencesConcurrentOperations() async throws {
        let original = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Before")]
        )
        let sibling = message(
            id: "sibling",
            parent: "root",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Reply")]
        )
        let updated = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "After")]
        )
        let coordinate = MessageTextCoordinate(
            conversationID: conversationID,
            messageID: original.id,
            location: .primaryText
        )
        let result = MessageEditResult(
            coordinate: coordinate,
            resolution: .confirmedAfterResponse,
            authoritativeHistory: [updated, sibling]
        )
        let repository = MessageEditRepositoryDouble(messages: [original, sibling], behavior: .suspended)
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Next message"
        let selection = try XCTUnwrap(model.editableMessageTextSelections(for: original.id).first)
        XCTAssertTrue(model.canSend)

        let task = Task { try await model.saveMessageEdit(selection, text: "After") }
        await waitForEditCall(repository)

        XCTAssertTrue(model.isSavingMessageEdit)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canShareSelectedBranch)
        XCTAssertEqual(model.messages.first?.editableTextCatalog.first?.text, "Before")
        do {
            _ = try await model.saveMessageEdit(selection, text: "Again")
            XCTFail("Expected the exact edit operation fence")
        } catch let error as MessageEditPresentationError {
            XCTAssertEqual(error, .operationInProgress)
        }
        let callsWhileSuspended = await repository.editCallCount()
        XCTAssertEqual(callsWhileSuspended, 1)

        await repository.completeSuspendedEdit(with: result)
        let resolution = try await task.value
        XCTAssertEqual(resolution, .confirmedAfterResponse)
        XCTAssertFalse(model.isSavingMessageEdit)
        XCTAssertEqual(model.messages, [updated, sibling])
        XCTAssertEqual(model.messages[1].editableTextCatalog.first?.text, "Reply")
        let requests = await repository.requests()
        XCTAssertEqual(requests.first?.profileID, profileID)
        XCTAssertEqual(requests.first?.accountID, accountID)
    }

    func testAuthoritativeMismatchInstallsValidatedFullCacheButDoesNotRetry() async throws {
        let original = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Before")]
        )
        let authoritative = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Changed elsewhere")]
        )
        let sibling = message(
            id: "reply",
            parent: "root",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Preserved")]
        )
        let selectionCoordinate = MessageTextCoordinate(
            conversationID: conversationID,
            messageID: original.id,
            location: .primaryText
        )
        let ambiguity = RecoverableMessageEditAmbiguity(
            coordinate: selectionCoordinate,
            submittedText: "Submitted",
            authoritativeText: "Changed elsewhere",
            reason: .authoritativeMismatch
        )
        let repository = MessageEditRepositoryDouble(
            messages: [original, sibling],
            cachedMessages: [authoritative, sibling],
            behavior: .ambiguous(ambiguity)
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.editableMessageTextSelections(for: original.id).first)

        do {
            _ = try await model.saveMessageEdit(selection, text: "Submitted")
            XCTFail("Expected recoverable ambiguity")
        } catch let MessageEditError.ambiguous(received) {
            XCTAssertEqual(received, ambiguity)
        }

        let callsAfterAmbiguity = await repository.editCallCount()
        XCTAssertEqual(callsAfterAmbiguity, 1)
        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertEqual(model.messages, [authoritative, sibling])
        do {
            _ = try await model.saveMessageEdit(selection, text: "Submitted")
            XCTFail("A stale sheet must not overwrite refreshed text")
        } catch let error as MessageEditPresentationError {
            XCTAssertEqual(error, .stale)
        }
        let callsAfterStaleAttempt = await repository.editCallCount()
        XCTAssertEqual(callsAfterStaleAttempt, 1)
    }

    func testSuccessfulResponseWithInvalidHistoryGraphIsRejectedWithoutInstallation() async throws {
        let original = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Before")]
        )
        let invalidUpdated = message(
            id: "root",
            parent: "missing-parent",
            author: .user,
            catalog: [.init(location: .primaryText, text: "After")]
        )
        let coordinate = MessageTextCoordinate(
            conversationID: conversationID,
            messageID: original.id,
            location: .primaryText
        )
        let repository = MessageEditRepositoryDouble(
            messages: [original],
            behavior: .result(MessageEditResult(
                coordinate: coordinate,
                resolution: .confirmedAfterResponse,
                authoritativeHistory: [invalidUpdated]
            ))
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.editableMessageTextSelections(for: original.id).first)

        do {
            _ = try await model.saveMessageEdit(selection, text: "After")
            XCTFail("An invalid authoritative graph must not confirm the save")
        } catch let error as MessageEditPresentationError {
            XCTAssertEqual(error, .invalidAuthoritativeHistory)
        }

        XCTAssertEqual(model.messages, [original])
        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertTrue(model.hasValidMessageTree)
        let calls = await repository.editCallCount()
        XCTAssertEqual(calls, 1)
    }

    func testUnverifiedAmbiguityDisablesRemoteMutationUntilExplicitReload() async throws {
        let original = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Before")]
        )
        let coordinate = MessageTextCoordinate(
            conversationID: conversationID,
            messageID: original.id,
            location: .primaryText
        )
        let ambiguity = RecoverableMessageEditAmbiguity(
            coordinate: coordinate,
            submittedText: "Submitted",
            authoritativeText: nil,
            reason: .verificationUnavailable
        )
        let repository = MessageEditRepositoryDouble(
            messages: [original],
            behavior: .ambiguous(ambiguity)
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.editableMessageTextSelections(for: original.id).first)

        do {
            _ = try await model.saveMessageEdit(selection, text: "Submitted")
            XCTFail("Expected recoverable ambiguity")
        } catch let MessageEditError.ambiguous(received) {
            XCTAssertEqual(received.reason, .verificationUnavailable)
        }
        XCTAssertEqual(model.historyState, .notCurrent)
        XCTAssertTrue(model.editableMessageTextSelections(for: original.id).isEmpty)
        XCTAssertEqual(model.messages.first?.editableTextCatalog.first?.text, "Before")

        await model.reload()
        XCTAssertEqual(model.historyState, .authoritative)
        let callsAfterReload = await repository.editCallCount()
        XCTAssertEqual(callsAfterReload, 1)
    }

    func testUnauthorizedEditHidesHistoryAndInvokesSessionPolicy() async throws {
        let original = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Before")]
        )
        let repository = MessageEditRepositoryDouble(
            messages: [original],
            behavior: .protocolFailure(.unauthorized)
        )
        var unauthorizedCalls = 0
        let model = makeModel(repository: repository) { unauthorizedCalls += 1 }
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.editableMessageTextSelections(for: original.id).first)

        do {
            _ = try await model.saveMessageEdit(selection, text: "After")
            XCTFail("Expected unauthorized")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(unauthorizedCalls, 1)
        XCTAssertEqual(model.historyState, .unavailable)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testDefinitiveClientErrorsApplyHistoryFreshnessPolicyWithoutMutatingText() async throws {
        let original = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Before")]
        )

        for status in [400, 404] {
            let repository = MessageEditRepositoryDouble(
                messages: [original],
                behavior: .protocolFailure(.httpStatus(status, message: nil, retryAfter: nil))
            )
            let model = makeModel(repository: repository)
            await model.loadIfNeeded()
            let selection = try XCTUnwrap(model.editableMessageTextSelections(for: original.id).first)
            do {
                _ = try await model.saveMessageEdit(selection, text: "After")
                XCTFail("Expected HTTP \(status)")
            } catch let LibreChatProtocolError.httpStatus(received, _, _) {
                XCTAssertEqual(received, status)
            }
            XCTAssertEqual(model.historyState, .notCurrent)
            XCTAssertEqual(model.messages, [original])
        }

        let forbiddenRepository = MessageEditRepositoryDouble(
            messages: [original],
            behavior: .protocolFailure(.httpStatus(403, message: nil, retryAfter: nil))
        )
        let forbiddenModel = makeModel(repository: forbiddenRepository)
        await forbiddenModel.loadIfNeeded()
        let forbiddenSelection = try XCTUnwrap(
            forbiddenModel.editableMessageTextSelections(for: original.id).first
        )
        do {
            _ = try await forbiddenModel.saveMessageEdit(forbiddenSelection, text: "After")
            XCTFail("Expected HTTP 403")
        } catch let LibreChatProtocolError.httpStatus(status, _, _) {
            XCTAssertEqual(status, 403)
        }
        XCTAssertEqual(forbiddenModel.historyState, .authoritative)
        XCTAssertEqual(forbiddenModel.messages, [original])
    }

    func testDraftValidationRequiresChangedNonblankBoundedTextAndReviewClearance() {
        XCTAssertFalse(MessageEditDraftState(
            originalText: "Same", draft: "Same", isSaving: false, requiresReview: false
        ).canSave)
        XCTAssertFalse(MessageEditDraftState(
            originalText: "Before", draft: " \n ", isSaving: false, requiresReview: false
        ).canSave)
        XCTAssertFalse(MessageEditDraftState(
            originalText: "Before",
            draft: String(repeating: "x", count: MessageEditRequest.maximumTextUTF16Length + 1),
            isSaving: false,
            requiresReview: false
        ).canSave)
        XCTAssertFalse(MessageEditDraftState(
            originalText: "Before", draft: "After", isSaving: false, requiresReview: true
        ).canSave)
        XCTAssertTrue(MessageEditDraftState(
            originalText: "Before", draft: "After", isSaving: false, requiresReview: false
        ).canSave)
    }

    func testFeedbackEligibilityUsesOnlyTheVisibleFinishedAssistantResponse() async throws {
        let user = message(
            id: "user",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Question")]
        )
        let hidden = message(
            id: "hidden",
            parent: "user",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Older branch")]
        )
        let existing = MessageFeedback(tag: .clearWellWritten, text: "Useful")
        let selected = message(
            id: "selected",
            parent: "user",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Selected branch")],
            feedback: existing
        )
        let repository = MessageEditRepositoryDouble(messages: [user, hidden, selected])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertNil(model.messageFeedbackSelection(for: user.id, suggestedRating: .thumbsDown))
        XCTAssertNil(model.messageFeedbackSelection(for: hidden.id, suggestedRating: .thumbsDown))
        let selection = try XCTUnwrap(
            model.messageFeedbackSelection(for: selected.id, suggestedRating: .thumbsDown)
        )
        XCTAssertEqual(selection.currentFeedback, existing)
        XCTAssertEqual(selection.suggestedRating, .thumbsUp)
    }

    func testSuspendedFeedbackSaveDoesNotOptimisticallyMutateAndFencesOtherActions() async throws {
        let response = message(
            id: "response",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Answer")]
        )
        let submitted = MessageFeedback(tag: .accurateReliable, text: "Correct")
        let coordinate = MessageFeedbackCoordinate(
            conversationID: conversationID,
            messageID: response.id
        )
        let repository = MessageEditRepositoryDouble(
            messages: [response],
            feedbackBehavior: .suspended
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(
            model.messageFeedbackSelection(for: response.id, suggestedRating: .thumbsUp)
        )

        let task = Task { try await model.updateMessageFeedback(selection, feedback: submitted) }
        await waitForFeedbackCall(repository)

        XCTAssertTrue(model.isSavingMessageFeedback)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canShareSelectedBranch)
        XCTAssertNil(model.messages.first?.feedback)
        do {
            _ = try await model.updateMessageFeedback(selection, feedback: submitted)
            XCTFail("Expected the feedback operation fence")
        } catch let error as MessageFeedbackError {
            XCTAssertEqual(error, .unavailable)
        }
        let callsWhileSuspended = await repository.feedbackCallCount()
        XCTAssertEqual(callsWhileSuspended, 1)

        await repository.completeSuspendedFeedback(with: MessageFeedbackResult(
            coordinate: coordinate,
            feedback: submitted,
            resolution: .confirmedAfterResponse
        ))
        let resolution = try await task.value
        XCTAssertEqual(resolution, .confirmedAfterResponse)
        XCTAssertEqual(model.messages.first?.feedback, submitted)
        XCTAssertFalse(model.isSavingMessageFeedback)
    }

    func testAmbiguousFeedbackLocksTheExactResponseUntilAuthoritativeReload() async throws {
        let response = message(
            id: "response",
            author: .assistant(name: "Assistant"),
            catalog: [.init(location: .primaryText, text: "Answer")]
        )
        let submitted = MessageFeedback(tag: .notHelpful, text: "Missed the point")
        let coordinate = MessageFeedbackCoordinate(
            conversationID: conversationID,
            messageID: response.id
        )
        let ambiguity = RecoverableMessageFeedbackAmbiguity(
            coordinate: coordinate,
            submittedFeedback: submitted,
            authoritativeFeedback: nil,
            reason: .verificationUnavailable
        )
        let repository = MessageEditRepositoryDouble(
            messages: [response],
            feedbackBehavior: .ambiguous(ambiguity)
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(
            model.messageFeedbackSelection(for: response.id, suggestedRating: .thumbsDown)
        )

        do {
            _ = try await model.updateMessageFeedback(selection, feedback: submitted)
            XCTFail("Expected recoverable feedback ambiguity")
        } catch let MessageFeedbackError.ambiguous(received) {
            XCTAssertEqual(received, ambiguity)
        }

        XCTAssertNil(model.messages.first?.feedback)
        XCTAssertEqual(model.historyState, .notCurrent)
        XCTAssertNil(model.messageFeedbackSelection(for: response.id, suggestedRating: .thumbsDown))
        do {
            _ = try await model.updateMessageFeedback(selection, feedback: submitted)
            XCTFail("A delivery-uncertain mutation must not be repeated")
        } catch let error as MessageFeedbackError {
            XCTAssertEqual(error, .unavailable)
        }
        let callsBeforeReload = await repository.feedbackCallCount()
        XCTAssertEqual(callsBeforeReload, 1)

        await model.reload()
        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertNotNil(model.messageFeedbackSelection(for: response.id, suggestedRating: .thumbsDown))
    }

    private func makeModel(
        repository: MessageEditRepositoryDouble,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> ChatModel {
        ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Editing",
                target: ConversationTarget(endpoint: "openAI", model: "test-model")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: onUnauthorized,
            onConversationIdentityChanged: { _, _ in }
        )
    }

    private func message(
        id: String,
        parent: String? = nil,
        author: MessageAuthor,
        catalog: [EditableMessageText],
        feedback: MessageFeedback? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: conversationID,
            parentMessageID: parent.map(MessageID.init(rawValue:)),
            content: [.text(catalog.first?.text ?? "")],
            author: author,
            feedback: feedback,
            editableTextCatalog: catalog
        )
    }

    private func parsedArtifact(messageID: String, source: String) -> ParsedArtifact {
        let raw = """
        :::artifact{identifier="notes" type="text/plain" title="Notes"}
        \(source):::
        """
        return ParsedArtifact(
            identity: ArtifactIdentity(
                messageID: MessageID(rawValue: messageID),
                documentOrderIndex: 0
            ),
            identifier: "notes",
            mimeType: "text/plain",
            title: "Notes",
            sourceContent: source,
            rawContainer: raw,
            attributes: [
                "identifier": "notes",
                "type": "text/plain",
                "title": "Notes"
            ]
        )
    }

    private func artifactThread(
        source: String = "Before\n"
    ) -> (ChatMessage, ChatMessage, ParsedArtifact) {
        let root = message(
            id: "root",
            author: .user,
            catalog: [.init(location: .primaryText, text: "Build an artifact")]
        )
        let artifact = parsedArtifact(messageID: "assistant", source: source)
        let assistant = ChatMessage(
            id: artifact.identity.messageID,
            conversationID: conversationID,
            parentMessageID: root.id,
            content: [.text(artifact.rawContainer)],
            author: .assistant(name: "Assistant"),
            isUnfinished: false,
            artifactCatalog: [artifact]
        )
        return (root, assistant, artifact)
    }

    private func waitForEditCall(_ repository: MessageEditRepositoryDouble) async {
        for _ in 0..<500 {
            if await repository.editCallCount() > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for suspended edit")
    }

    private func waitForFeedbackCall(_ repository: MessageEditRepositoryDouble) async {
        for _ in 0..<500 {
            if await repository.feedbackCallCount() > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for suspended feedback")
    }
}

private actor MessageEditRepositoryDouble: ChatFeatureRepository {
    enum Behavior: Sendable {
        case result(MessageEditResult)
        case ambiguous(RecoverableMessageEditAmbiguity)
        case protocolFailure(LibreChatProtocolError)
        case suspended
    }

    enum FeedbackBehavior: Sendable {
        case result(MessageFeedbackResult)
        case ambiguous(RecoverableMessageFeedbackAmbiguity)
        case protocolFailure(LibreChatProtocolError)
        case suspended
    }

    enum ArtifactBehavior: Sendable {
        case result
        case protocolFailure(LibreChatProtocolError)
        case editFailure(ArtifactEditError)
    }

    private let messageValues: [ChatMessage]
    private let cachedMessageValues: [ChatMessage]
    private let behavior: Behavior
    private let feedbackBehavior: FeedbackBehavior
    private let artifactBehavior: ArtifactBehavior
    private let messagesError: LibreChatProtocolError?
    private var editRequests: [MessageEditRequest] = []
    private var feedbackRequests: [MessageFeedbackRequest] = []
    private var artifactRequests: [ArtifactEditRequest] = []
    private var suspendedEdit: CheckedContinuation<MessageEditResult, any Error>?
    private var suspendedFeedback: CheckedContinuation<MessageFeedbackResult, any Error>?
    private var drafts: [ConversationID: String] = [:]

    init(
        messages: [ChatMessage],
        cachedMessages: [ChatMessage]? = nil,
        messagesError: LibreChatProtocolError? = nil,
        behavior: Behavior = .protocolFailure(.unsupported("No edit fixture")),
        feedbackBehavior: FeedbackBehavior = .protocolFailure(.unsupported("No feedback fixture")),
        artifactBehavior: ArtifactBehavior = .result
    ) {
        messageValues = messages
        cachedMessageValues = cachedMessages ?? messages
        self.messagesError = messagesError
        self.behavior = behavior
        self.feedbackBehavior = feedbackBehavior
        self.artifactBehavior = artifactBehavior
    }

    func editCallCount() -> Int { editRequests.count }
    func requests() -> [MessageEditRequest] { editRequests }
    func feedbackCallCount() -> Int { feedbackRequests.count }
    func feedbackRequestsReceived() -> [MessageFeedbackRequest] { feedbackRequests }
    func artifactRequestsReceived() -> [ArtifactEditRequest] { artifactRequests }
    func completeSuspendedEdit(with result: MessageEditResult) {
        suspendedEdit?.resume(returning: result)
        suspendedEdit = nil
    }
    func completeSuspendedFeedback(with result: MessageFeedbackResult) {
        suspendedFeedback?.resume(returning: result)
        suspendedFeedback = nil
    }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) -> Conversation {
        Conversation(
            id: id,
            title: "Editing",
            target: ConversationTarget(endpoint: "openAI", model: "test-model")
        )
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
        throw LibreChatProtocolError.unsupported("Not used")
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

    func saveMessageEdit(_ request: MessageEditRequest) async throws -> MessageEditResult {
        editRequests.append(request)
        return switch behavior {
        case let .result(result): result
        case let .ambiguous(ambiguity): throw MessageEditError.ambiguous(ambiguity)
        case let .protocolFailure(error): throw error
        case .suspended:
            try await withCheckedThrowingContinuation { suspendedEdit = $0 }
        }
    }

    func updateMessageFeedback(
        _ request: MessageFeedbackRequest
    ) async throws -> MessageFeedbackResult {
        feedbackRequests.append(request)
        return switch feedbackBehavior {
        case let .result(result): result
        case let .ambiguous(ambiguity): throw MessageFeedbackError.ambiguous(ambiguity)
        case let .protocolFailure(error): throw error
        case .suspended:
            try await withCheckedThrowingContinuation { suspendedFeedback = $0 }
        }
    }

    func updateArtifact(_ request: ArtifactEditRequest) throws -> ChatMessage {
        artifactRequests.append(request)
        switch artifactBehavior {
        case .result:
            break
        case let .protocolFailure(error):
            throw error
        case let .editFailure(error):
            throw error
        }
        guard let message = messageValues.first(where: { $0.id == request.identity.messageID }) else {
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
    ) -> GenerationSnapshot { GenerationSnapshot(handle: handle, state: .streaming) }
    func recoverableGenerations() -> [GenerationSnapshot] { [] }
    func draft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) { drafts[conversationID] = text }
}

@MainActor
final class PromptResubmitPresentationTests: XCTestCase {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "conversation")

    func testEligibilityRequiresSelectedPersistedExactPrimaryPlainTextUserPrompt() async {
        let hidden = prompt(id: "hidden", text: "Hidden")
        let selected = prompt(id: "selected", text: "Original")
        let repository = PromptResubmitRepositoryDouble(messages: [hidden, selected])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertNil(model.promptResubmitSelection(for: hidden.id))
        let selection = model.promptResubmitSelection(for: selected.id)
        XCTAssertEqual(selection?.sourceMessageID, selected.id)
        XCTAssertNil(selection?.sourceParentMessageID)
        XCTAssertEqual(selection?.baselineText, "Original")
    }

    func testEligibilityRejectsRichMarkedAndInexactCatalogSources() async {
        let artifact = ":::artifact{identifier=\"partial\" type=\"text/plain\" title=\"Partial\"}\nunfinished"
        let fixtures: [ChatMessage] = [
            prompt(
                id: "multiple-text",
                text: "OneTwo",
                content: [.text("One"), .text("Two")]
            ),
            prompt(id: "missing-catalog", text: "Plain", catalog: []),
            prompt(
                id: "indexed-catalog",
                text: "Plain",
                catalog: [.init(location: .contentPart(index: 0, kind: .text), text: "Plain")]
            ),
            prompt(
                id: "mismatched-catalog",
                text: "Plain",
                catalog: [.init(location: .primaryText, text: "Different")]
            ),
            prompt(id: "artifact", text: artifact),
            prompt(id: "citation", text: "Cited \u{E202}turn0search0"),
            ChatMessage(
                id: MessageID(rawValue: "file"),
                conversationID: conversationID,
                content: [.text("Plain"), .file(UploadedFile(id: "file", filename: "file.txt"))],
                author: .user,
                editableTextCatalog: [.init(location: .primaryText, text: "Plain")]
            ),
            ChatMessage(
                id: MessageID(rawValue: "assistant"),
                conversationID: conversationID,
                content: [.text("Plain")],
                author: .assistant(name: "Assistant"),
                editableTextCatalog: [.init(location: .primaryText, text: "Plain")]
            )
        ]

        for fixture in fixtures {
            let repository = PromptResubmitRepositoryDouble(messages: [fixture])
            let model = makeModel(repository: repository)
            await model.loadIfNeeded()
            XCTAssertNil(
                model.promptResubmitSelection(for: fixture.id),
                "Unexpected eligibility for \(fixture.id.rawValue)"
            )
        }
    }

    func testSuspendedAdmissionHasNoOptimismThenStreamingUsesExactActionAndStableIDs() async throws {
        let ancestor = ChatMessage(
            id: MessageID(rawValue: "ancestor"),
            conversationID: conversationID,
            content: [.text("Prior response")],
            author: .assistant(name: "Assistant")
        )
        let source = prompt(id: "source", parent: ancestor.id, text: "Original")
        let repository = PromptResubmitRepositoryDouble(
            messages: [ancestor, source],
            behavior: .suspendedStreaming
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Main composer stays here"
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))

        let task = Task {
            try await model.editPromptAndResubmit(selection, text: "Edited branch prompt")
        }
        await waitForSendCall(repository)

        XCTAssertTrue(model.isResubmittingPrompt)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canShareSelectedBranch)
        XCTAssertEqual(model.messages, [ancestor, source])
        XCTAssertEqual(model.draft, "Main composer stays here")
        do {
            _ = try await model.editPromptAndResubmit(selection, text: "Duplicate")
            XCTFail("Expected the resubmit admission fence")
        } catch let error as PromptResubmitPresentationError {
            XCTAssertEqual(error, .operationInProgress)
        }

        await repository.completeSuspendedStreaming()
        let result = try await task.value
        XCTAssertEqual(result, .streaming)
        let requests = await repository.sentRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.profileID, profileID)
        XCTAssertEqual(request.accountID, accountID)
        XCTAssertEqual(request.parentMessageID, ancestor.id)
        XCTAssertEqual(request.text, "Edited branch prompt")
        XCTAssertEqual(request.attachments, [])
        XCTAssertEqual(request.action, .editPromptAndResubmit(sourceUserMessageID: source.id))
        XCTAssertEqual(model.generationSnapshot?.handle.clientRequestID, request.clientRequestID)
        XCTAssertEqual(model.draft, "Main composer stays here")
        XCTAssertTrue(model.messages.contains { message in
            message.id == request.clientMessageID
                && message.parentMessageID == ancestor.id
                && message.rawPlainText == "Edited branch prompt"
        })
        XCTAssertTrue(model.messages.contains { message in
            message.parentMessageID == request.clientMessageID
                && message.id.rawValue.hasPrefix("local-assistant-")
        })
        XCTAssertEqual(model.visibleMessages.dropFirst().first?.id, request.clientMessageID)
    }

    func testSettledAdmissionReloadsAuthoritativeHistoryAndFocusesAcceptedSibling() async throws {
        let source = prompt(id: "source", text: "Original")
        let repository = PromptResubmitRepositoryDouble(messages: [source], behavior: .settled)
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Composer draft"
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))

        let result = try await model.editPromptAndResubmit(selection, text: "Accepted terminal")

        XCTAssertEqual(result, .settled)
        let terminalRequests = await repository.sentRequests()
        let request = try XCTUnwrap(terminalRequests.first)
        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertEqual(model.visibleMessages.last?.id, request.clientMessageID)
        XCTAssertEqual(model.visibleMessages.last?.rawPlainText, "Accepted terminal")
        XCTAssertEqual(model.draft, "Composer draft")
    }

    func testFailedAdmissionReloadsWithoutRepostingAndSurfacesFailure() async throws {
        let source = prompt(id: "source", text: "Original")
        let failure = GenerationFailure(code: "failed", message: "Model failed", isRecoverable: false)
        let repository = PromptResubmitRepositoryDouble(
            messages: [source],
            behavior: .failed(failure)
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))

        let result = try await model.editPromptAndResubmit(selection, text: "Accepted then failed")

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(model.errorMessage, "Model failed")
        let failedSendCount = await repository.sendCount()
        XCTAssertEqual(failedSendCount, 1)
        XCTAssertEqual(model.historyState, .authoritative)
    }

    func testAmbiguousFailureDoesNotRetryOrMutateAndRequiresAuthoritativeRefresh() async throws {
        let source = prompt(id: "source", text: "Original")
        let repository = PromptResubmitRepositoryDouble(
            messages: [source],
            behavior: .protocolFailure(.transport("lost after write"))
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Composer"
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))

        do {
            _ = try await model.editPromptAndResubmit(selection, text: "Possibly accepted")
            XCTFail("Expected ambiguous transport failure")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .transport("lost after write"))
        }
        XCTAssertEqual(model.messages, [source])
        XCTAssertEqual(model.draft, "Composer")
        XCTAssertEqual(model.historyState, .notCurrent)
        do {
            _ = try await model.editPromptAndResubmit(selection, text: "Do not repost")
            XCTFail("History must refresh before another explicit action")
        } catch let error as PromptResubmitPresentationError {
            XCTAssertEqual(error, .unavailable)
        }
        let ambiguousSendCount = await repository.sendCount()
        XCTAssertEqual(ambiguousSendCount, 1)
    }

    func testHandoffNeverAttributesEditedPromptToWinner() async throws {
        let source = prompt(id: "source", text: "Original")
        let repository = PromptResubmitRepositoryDouble(messages: [source], behavior: .handoff)
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Composer"
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))

        do {
            _ = try await model.editPromptAndResubmit(selection, text: "Losing edited prompt")
            XCTFail("Handoff must keep the editor open")
        } catch let error as PromptResubmitPresentationError {
            XCTAssertEqual(error, .handoff)
        }

        let handoffRequests = await repository.sentRequests()
        let request = try XCTUnwrap(handoffRequests.first)
        XCTAssertFalse(model.messages.contains { $0.id == request.clientMessageID })
        XCTAssertEqual(model.messages, [source])
        XCTAssertEqual(model.draft, "Composer")
        XCTAssertNotEqual(model.generationSnapshot?.handle.clientRequestID, request.clientRequestID)
        let handoffSendCount = await repository.sendCount()
        XCTAssertEqual(handoffSendCount, 1)
    }

    func testUnauthorizedInvokesSessionPolicyAndHidesHistory() async throws {
        let source = prompt(id: "source", text: "Original")
        let repository = PromptResubmitRepositoryDouble(
            messages: [source],
            behavior: .protocolFailure(.unauthorized)
        )
        var unauthorizedCalls = 0
        let model = makeModel(repository: repository) { unauthorizedCalls += 1 }
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))

        do {
            _ = try await model.editPromptAndResubmit(selection, text: "Edited")
            XCTFail("Expected unauthorized")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(unauthorizedCalls, 1)
        XCTAssertEqual(model.historyState, .unavailable)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testRevisedSourceRejectsStaleEditorBeforeNetwork() async throws {
        let source = prompt(id: "source", text: "Original")
        let revised = prompt(id: "source", text: "Revised elsewhere")
        let repository = PromptResubmitRepositoryDouble(messages: [source])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.promptResubmitSelection(for: source.id))
        await repository.replaceMessages(with: [revised])
        await model.reload()

        do {
            _ = try await model.editPromptAndResubmit(selection, text: "Edited old baseline")
            XCTFail("Expected stale source rejection")
        } catch let error as PromptResubmitPresentationError {
            XCTAssertEqual(error, .stale)
        }
        let staleSendCount = await repository.sendCount()
        XCTAssertEqual(staleSendCount, 0)
        XCTAssertEqual(model.messages, [revised])
    }

    func testPromptDraftValidationLocksUnchangedInvalidBusyAndAmbiguousSubmissions() {
        XCTAssertFalse(PromptResubmitDraftState(
            baselineText: "Same", draft: "Same", isSubmitting: false, requiresReview: false
        ).canSubmit)
        XCTAssertFalse(PromptResubmitDraftState(
            baselineText: "Before", draft: "  ", isSubmitting: false, requiresReview: false
        ).canSubmit)
        XCTAssertFalse(PromptResubmitDraftState(
            baselineText: "Before", draft: "After", isSubmitting: true, requiresReview: false
        ).canSubmit)
        XCTAssertFalse(PromptResubmitDraftState(
            baselineText: "Before", draft: "After", isSubmitting: false, requiresReview: true
        ).canSubmit)
        XCTAssertTrue(PromptResubmitDraftState(
            baselineText: "Before", draft: "After", isSubmitting: false, requiresReview: false
        ).canSubmit)
    }

    private func makeModel(
        repository: PromptResubmitRepositoryDouble,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> ChatModel {
        ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Resubmit",
                target: ConversationTarget(endpoint: "openAI", model: "test-model")
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: onUnauthorized,
            onConversationIdentityChanged: { _, _ in }
        )
    }

    private func prompt(
        id: String,
        parent: MessageID? = nil,
        text: String,
        content: [MessageContent]? = nil,
        catalog: [EditableMessageText]? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: conversationID,
            parentMessageID: parent,
            content: content ?? [.text(text)],
            author: .user,
            editableTextCatalog: catalog ?? [.init(location: .primaryText, text: text)]
        )
    }

    private func waitForSendCall(_ repository: PromptResubmitRepositoryDouble) async {
        for _ in 0..<500 {
            if await repository.sendCount() > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for suspended prompt admission")
    }
}

private actor PromptResubmitRepositoryDouble: ChatFeatureRepository {
    enum Behavior: Sendable {
        case streaming
        case suspendedStreaming
        case settled
        case failed(GenerationFailure)
        case handoff
        case protocolFailure(LibreChatProtocolError)
    }

    private var messageValues: [ChatMessage]
    private let behavior: Behavior
    private var requests: [ChatRequest] = []
    private var suspendedSend: CheckedContinuation<ChatSendOutcome, any Error>?
    private var drafts: [ConversationID: String] = [:]

    init(messages: [ChatMessage], behavior: Behavior = .streaming) {
        messageValues = messages
        self.behavior = behavior
    }

    func sendCount() -> Int { requests.count }
    func sentRequests() -> [ChatRequest] { requests }
    func replaceMessages(with messages: [ChatMessage]) { messageValues = messages }
    func completeSuspendedStreaming() {
        guard let request = requests.first else { return }
        suspendedSend?.resume(returning: .streaming(handle(for: request)))
        suspendedSend = nil
    }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) -> Conversation {
        Conversation(
            id: id,
            title: "Resubmit",
            target: ConversationTarget(endpoint: "openAI", model: "test-model")
        )
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { messageValues }
    func messages(conversationID: ConversationID) -> [ChatMessage] {
        guard !requests.isEmpty else { return messageValues }
        switch behavior {
        case .settled, .failed:
            let request = requests[0]
            let accepted = ChatMessage(
                id: request.clientMessageID,
                conversationID: conversationID,
                parentMessageID: request.parentMessageID,
                content: [.text(request.text)],
                author: .user,
                editableTextCatalog: [.init(location: .primaryText, text: request.text)]
            )
            return messageValues + [accepted]
        default:
            return messageValues
        }
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

    func send(_ request: ChatRequest) async throws -> ChatSendOutcome {
        requests.append(request)
        return switch behavior {
        case .streaming:
            .streaming(handle(for: request))
        case .suspendedStreaming:
            try await withCheckedThrowingContinuation { suspendedSend = $0 }
        case .settled:
            .settled(conversationID: request.conversation.id)
        case let .failed(failure):
            .failed(conversationID: request.conversation.id, failure: failure)
        case .handoff:
            .handoff(GenerationHandle(
                profileID: request.profileID,
                accountID: request.accountID,
                clientRequestID: UUID(),
                streamID: "winner",
                conversationID: request.conversation.id,
                generationCreatedAt: 22,
                protocolVersion: 2
            ))
        case let .protocolFailure(error):
            throw error
        }
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
    func draft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) { drafts[conversationID] = text }

    private func handle(for request: ChatRequest) -> GenerationHandle {
        GenerationHandle(
            profileID: request.profileID,
            accountID: request.accountID,
            clientRequestID: request.clientRequestID,
            streamID: "accepted",
            conversationID: request.conversation.id,
            generationCreatedAt: 11,
            protocolVersion: 2
        )
    }
}

@MainActor
final class ResponseRegenerationPresentationTests: XCTestCase {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "conversation")

    func testEligibilityRequiresSelectedPersistedFinishedPlainTextAssistantAndExactUserParent() async throws {
        let source = user(id: "source", text: "Prompt")
        let hidden = assistant(id: "hidden", parent: source.id, text: "Older")
        let selected = assistant(id: "selected", parent: source.id, text: "Selected")
        let repository = ResponseRegenerationRepositoryDouble(messages: [source, hidden, selected])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()

        XCTAssertNil(model.responseRegenerationSelection(for: hidden.id))
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: selected.id))
        XCTAssertEqual(selection.conversationID, conversationID)
        XCTAssertEqual(selection.sourceUserMessageID, source.id)
        XCTAssertEqual(selection.targetAssistantMessageID, selected.id)
        XCTAssertEqual(selection.sourceUserMessage, source)
        XCTAssertEqual(selection.targetAssistantMessage, selected)
        XCTAssertEqual(selection.targetLabel, "Friendly target")
    }

    func testEligibilityRejectsRichReplayMetadataAndIncompatibleTargets() async {
        let sourceID = MessageID(rawValue: "source")
        let validSource = user(id: sourceID.rawValue, text: "Prompt")
        let richSourceFixtures: [ChatMessage] = [
            user(id: "source", text: "Prompt", content: [.text("Prompt"), .file(.init(id: "f", filename: "f.txt"))]),
            user(id: "source", text: "Prompt", manualSkills: ["skill"]),
            user(id: "source", text: "Prompt", quotes: ["quote"]),
            user(id: "source", text: ":::artifact{identifier=\"a\" type=\"text/plain\" title=\"A\"}\nBody"),
            user(id: "source", text: "Cited \u{E202}turn0search0"),
            user(id: "source", text: "Prompt", catalog: []),
            user(id: "source", text: "Prompt", endpoint: "different")
        ]
        let richAssistantFixtures: [ChatMessage] = [
            assistant(id: "target", parent: sourceID, content: [.toolReference("tool")]),
            assistant(id: "target", parent: sourceID, text: "Answer", manualSkills: ["skill"]),
            assistant(id: "target", parent: sourceID, text: "Answer", quotes: ["quote"]),
            assistant(id: "target", parent: sourceID, text: "Answer", citationAttachments: [
                CitationAttachment(
                    identity: CitationAttachmentIdentity(
                        messageID: MessageID(rawValue: "target"),
                        toolCallID: "tool",
                        name: "search"
                    ),
                    payload: .webSearch(WebSearchCitationData(
                        turn: 0,
                        organic: [],
                        raw: .object([:])
                    ))
                )
            ]),
            assistant(id: "target", parent: sourceID, text: "Answer", endpoint: "different"),
            assistant(id: "local-assistant-target", parent: sourceID, text: "Answer"),
            assistant(id: "target", parent: sourceID, text: "Answer", unfinished: true),
            assistant(id: "target", parent: sourceID, text: "Answer", finishReason: "error")
        ]

        for source in richSourceFixtures {
            let target = assistant(id: "target", parent: source.id, text: "Answer")
            let repository = ResponseRegenerationRepositoryDouble(messages: [source, target])
            let model = makeModel(repository: repository)
            await model.loadIfNeeded()
            XCTAssertNil(
                model.responseRegenerationSelection(for: target.id),
                "Unexpected source eligibility: \(source)"
            )
        }
        for target in richAssistantFixtures {
            let repository = ResponseRegenerationRepositoryDouble(messages: [validSource, target])
            let model = makeModel(repository: repository)
            await model.loadIfNeeded()
            XCTAssertNil(
                model.responseRegenerationSelection(for: target.id),
                "Unexpected assistant eligibility: \(target)"
            )
        }
    }

    func testSuspendedAdmissionHasNoOptimismAndStreamingCreatesOnlyAssistantSibling() async throws {
        let ancestor = assistant(id: "ancestor", parent: nil, text: "Prior")
        let source = user(id: "source", parent: ancestor.id, text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let repository = ResponseRegenerationRepositoryDouble(
            messages: [ancestor, source, target],
            behavior: .suspendedStreaming
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Main composer stays here"
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        let task = Task { try await model.regenerateResponse(selection) }
        await waitForSendCall(repository)

        XCTAssertTrue(model.isRegeneratingResponse)
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canShareSelectedBranch)
        XCTAssertEqual(model.messages, [ancestor, source, target])
        XCTAssertEqual(model.draft, "Main composer stays here")
        XCTAssertTrue(model.editableMessageTextSelections(for: source.id).isEmpty)
        XCTAssertNil(model.promptResubmitSelection(for: source.id))
        XCTAssertNil(model.responseRegenerationSelection(for: target.id))
        do {
            _ = try await model.regenerateResponse(selection)
            XCTFail("Expected the regeneration admission fence")
        } catch let error as ResponseRegenerationPresentationError {
            XCTAssertEqual(error, .operationInProgress)
        }

        await repository.completeSuspendedStreaming()
        let result = try await task.value
        XCTAssertEqual(result, .streaming)
        let requests = await repository.sentRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.profileID, profileID)
        XCTAssertEqual(request.accountID, accountID)
        XCTAssertEqual(request.parentMessageID, ancestor.id)
        XCTAssertEqual(request.text, "Prompt")
        XCTAssertEqual(request.attachments, [])
        XCTAssertEqual(
            request.action,
            .regenerateResponse(
                sourceUserMessageID: source.id,
                targetAssistantMessageID: target.id
            )
        )
        XCTAssertEqual(model.generationSnapshot?.handle.clientRequestID, request.clientRequestID)
        XCTAssertEqual(model.draft, "Main composer stays here")
        XCTAssertTrue(model.messages.contains(target))
        XCTAssertFalse(model.messages.contains { $0.id == request.clientMessageID })
        let newMessages = model.messages.filter { ![ancestor.id, source.id, target.id].contains($0.id) }
        XCTAssertEqual(newMessages.count, 1)
        XCTAssertEqual(newMessages.first?.parentMessageID, source.id)
        XCTAssertTrue(newMessages.first?.id.rawValue.hasPrefix("local-assistant-") == true)
        XCTAssertEqual(model.visibleMessages.last?.id, newMessages.first?.id)
    }

    func testSettledAdmissionPreservesExistingSubtreeAndFocusesOnlyNewAssistant() async throws {
        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let descendant = user(id: "descendant", parent: target.id, text: "Follow-up")
        let repository = ResponseRegenerationRepositoryDouble(
            messages: [source, target, descendant],
            behavior: .settled
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Composer draft"
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        let result = try await model.regenerateResponse(selection)
        XCTAssertEqual(result, .settled)

        XCTAssertEqual(model.historyState, .authoritative)
        XCTAssertTrue(model.messages.contains(target))
        XCTAssertTrue(model.messages.contains(descendant))
        XCTAssertEqual(model.visibleMessages.last?.id, MessageID(rawValue: "server-regenerated"))
        XCTAssertEqual(model.draft, "Composer draft")
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
    }

    func testFailedAdmissionReloadsExactAssistantAndSurfacesFailureWithoutRetry() async throws {
        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let failure = GenerationFailure(code: "failed", message: "Model failed", isRecoverable: false)
        let repository = ResponseRegenerationRepositoryDouble(
            messages: [source, target],
            behavior: .failed(failure)
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        let result = try await model.regenerateResponse(selection)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(model.errorMessage, "Model failed")
        XCTAssertEqual(model.visibleMessages.last?.id, MessageID(rawValue: "server-regenerated"))
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
    }

    func testTerminalAmbiguityDoesNotInstallOrRetry() async throws {
        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let repository = ResponseRegenerationRepositoryDouble(
            messages: [source, target],
            behavior: .terminalAmbiguous
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        do {
            _ = try await model.regenerateResponse(selection)
            XCTFail("Expected ambiguous terminal history")
        } catch let error as ResponseRegenerationPresentationError {
            XCTAssertEqual(error, .ambiguousAuthoritativeHistory)
        }
        XCTAssertEqual(model.messages, [source, target])
        XCTAssertEqual(model.historyState, .notCurrent)
        XCTAssertNil(model.responseRegenerationSelection(for: target.id))
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
    }

    func testHandoffAttachesOnlyExactWinnerWithoutAttributingRequestedRegeneration() async throws {
        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let repository = ResponseRegenerationRepositoryDouble(
            messages: [source, target],
            behavior: .handoff
        )
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        model.draft = "Composer"
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        do {
            _ = try await model.regenerateResponse(selection)
            XCTFail("Handoff must require explicit review")
        } catch let error as ResponseRegenerationPresentationError {
            XCTAssertEqual(error, .handoff)
        }

        let requests = await repository.sentRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertFalse(model.messages.contains { $0.id == request.clientMessageID })
        XCTAssertEqual(model.messages, [source, target])
        XCTAssertEqual(model.visibleMessages.last?.id, target.id)
        XCTAssertEqual(model.draft, "Composer")
        XCTAssertNotEqual(model.generationSnapshot?.handle.clientRequestID, request.clientRequestID)
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 1)
    }

    func testUnauthorizedHidesHistoryAndInvokesSessionPolicy() async throws {
        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let repository = ResponseRegenerationRepositoryDouble(
            messages: [source, target],
            behavior: .protocolFailure(.unauthorized)
        )
        var unauthorizedCalls = 0
        let model = makeModel(repository: repository) { unauthorizedCalls += 1 }
        await model.loadIfNeeded()
        let selection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        do {
            _ = try await model.regenerateResponse(selection)
            XCTFail("Expected unauthorized")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(unauthorizedCalls, 1)
        XCTAssertEqual(model.historyState, .unavailable)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testStaleResponseOrExactTargetChangeRejectsBeforeNetwork() async throws {
        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let repository = ResponseRegenerationRepositoryDouble(messages: [source, target])
        let model = makeModel(repository: repository)
        await model.loadIfNeeded()
        let staleSelection = try XCTUnwrap(model.responseRegenerationSelection(for: target.id))

        await repository.replaceMessages(with: [
            source,
            assistant(id: "target", parent: source.id, text: "Revised")
        ])
        await model.reload()
        do {
            _ = try await model.regenerateResponse(staleSelection)
            XCTFail("Expected stale response")
        } catch let error as ResponseRegenerationPresentationError {
            XCTAssertEqual(error, .stale)
        }

        await repository.replaceMessages(with: [source, target])
        await repository.replaceTarget(
            ConversationTarget(endpoint: "openAI", model: "other-model", spec: "Friendly target")
        )
        await model.reload()
        do {
            _ = try await model.regenerateResponse(staleSelection)
            XCTFail("Expected exact target fence")
        } catch let error as ResponseRegenerationPresentationError {
            XCTAssertEqual(error, .stale)
        }
        let sendCount = await repository.sendCount()
        XCTAssertEqual(sendCount, 0)
    }

    func testConfirmationValidationAndFullIdentityIncludeTargetPresentation() {
        XCTAssertTrue(ResponseRegenerationConfirmationState(
            isSubmitting: false,
            requiresReview: false
        ).canSubmit)
        XCTAssertFalse(ResponseRegenerationConfirmationState(
            isSubmitting: true,
            requiresReview: false
        ).canSubmit)
        XCTAssertFalse(ResponseRegenerationConfirmationState(
            isSubmitting: false,
            requiresReview: true
        ).canSubmit)

        let source = user(id: "source", text: "Prompt")
        let target = assistant(id: "target", parent: source.id, text: "Existing")
        let first = ResponseRegenerationSelection(
            conversationID: conversationID,
            sourceUserMessageID: source.id,
            targetAssistantMessageID: target.id,
            sourceUserMessage: source,
            targetAssistantMessage: target,
            conversationTarget: ConversationTarget(endpoint: "agents", agentID: "secret-one"),
            targetLabel: "Selected agent"
        )
        let second = ResponseRegenerationSelection(
            conversationID: conversationID,
            sourceUserMessageID: source.id,
            targetAssistantMessageID: target.id,
            sourceUserMessage: source,
            targetAssistantMessage: target,
            conversationTarget: ConversationTarget(endpoint: "agents", agentID: "secret-two"),
            targetLabel: "Selected agent"
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(first.targetLabel.contains("secret"))
    }

    private func makeModel(
        repository: ResponseRegenerationRepositoryDouble,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> ChatModel {
        ChatModel(
            conversation: Conversation(
                id: conversationID,
                title: "Regenerate",
                target: ConversationTarget(
                    endpoint: "openAI",
                    model: "test-model",
                    spec: "Friendly target"
                )
            ),
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            uploadManager: nil,
            canGenerate: { true },
            compatibilityWarning: { nil },
            onUnauthorized: onUnauthorized,
            onConversationIdentityChanged: { _, _ in }
        )
    }

    private func user(
        id: String,
        parent: MessageID? = nil,
        text: String,
        content: [MessageContent]? = nil,
        catalog: [EditableMessageText]? = nil,
        manualSkills: [String]? = nil,
        quotes: [String]? = nil,
        endpoint: String? = "openAI"
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: conversationID,
            parentMessageID: parent,
            content: content ?? [.text(text)],
            author: .user,
            model: "test-model",
            endpoint: endpoint,
            isUnfinished: false,
            manualSkills: manualSkills,
            quotes: quotes,
            editableTextCatalog: catalog ?? [.init(location: .primaryText, text: text)]
        )
    }

    private func assistant(
        id: String,
        parent: MessageID?,
        text: String = "",
        content: [MessageContent]? = nil,
        manualSkills: [String]? = nil,
        quotes: [String]? = nil,
        citationAttachments: [CitationAttachment] = [],
        endpoint: String? = "openAI",
        unfinished: Bool = false,
        finishReason: String? = "stop"
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: conversationID,
            parentMessageID: parent,
            content: content ?? [.text(text)],
            author: .assistant(name: "Assistant"),
            model: "test-model",
            endpoint: endpoint,
            isUnfinished: unfinished,
            finishReason: finishReason,
            manualSkills: manualSkills,
            quotes: quotes,
            citationAttachments: citationAttachments
        )
    }

    private func waitForSendCall(_ repository: ResponseRegenerationRepositoryDouble) async {
        for _ in 0..<500 {
            if await repository.sendCount() > 0 { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for suspended regeneration admission")
    }
}

private actor ResponseRegenerationRepositoryDouble: ChatFeatureRepository {
    enum Behavior: Sendable {
        case streaming
        case suspendedStreaming
        case settled
        case aborted
        case failed(GenerationFailure)
        case terminalAmbiguous
        case handoff
        case protocolFailure(LibreChatProtocolError)
    }

    private var messageValues: [ChatMessage]
    private var target = ConversationTarget(
        endpoint: "openAI",
        model: "test-model",
        spec: "Friendly target"
    )
    private let behavior: Behavior
    private var requests: [ChatRequest] = []
    private var suspendedSend: CheckedContinuation<ChatSendOutcome, any Error>?
    private var drafts: [ConversationID: String] = [:]

    init(messages: [ChatMessage], behavior: Behavior = .streaming) {
        messageValues = messages
        self.behavior = behavior
    }

    func sendCount() -> Int { requests.count }
    func sentRequests() -> [ChatRequest] { requests }
    func replaceMessages(with messages: [ChatMessage]) { messageValues = messages }
    func replaceTarget(_ target: ConversationTarget) { self.target = target }

    func completeSuspendedStreaming() {
        guard let request = requests.first else { return }
        suspendedSend?.resume(returning: .streaming(handle(for: request)))
        suspendedSend = nil
    }

    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) -> Conversation {
        Conversation(id: id, title: "Regenerate", target: target)
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { messageValues }
    func messages(conversationID: ConversationID) -> [ChatMessage] {
        guard !requests.isEmpty else { return messageValues }
        let request = requests[0]
        let accepted = ChatMessage(
            id: MessageID(rawValue: "server-regenerated"),
            conversationID: conversationID,
            parentMessageID: sourceMessageID(for: request),
            content: [.text("Regenerated")],
            author: .assistant(name: "Assistant"),
            model: "test-model",
            endpoint: "openAI",
            isUnfinished: false,
            finishReason: "stop"
        )
        switch behavior {
        case .settled, .aborted, .failed:
            return messageValues + [accepted]
        case .terminalAmbiguous:
            var second = accepted
            second = ChatMessage(
                id: MessageID(rawValue: "server-regenerated-two"),
                conversationID: conversationID,
                parentMessageID: sourceMessageID(for: request),
                content: [.text("Another regenerated response")],
                author: .assistant(name: "Assistant"),
                model: "test-model",
                endpoint: "openAI",
                isUnfinished: false,
                finishReason: "stop"
            )
            return messageValues + [accepted, second]
        default:
            return messageValues
        }
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

    func send(_ request: ChatRequest) async throws -> ChatSendOutcome {
        requests.append(request)
        return switch behavior {
        case .streaming:
            .streaming(handle(for: request))
        case .suspendedStreaming:
            try await withCheckedThrowingContinuation { suspendedSend = $0 }
        case .settled, .terminalAmbiguous:
            .settled(conversationID: request.conversation.id)
        case .aborted:
            .aborted(conversationID: request.conversation.id)
        case let .failed(failure):
            .failed(conversationID: request.conversation.id, failure: failure)
        case .handoff:
            .handoff(GenerationHandle(
                profileID: request.profileID,
                accountID: request.accountID,
                clientRequestID: UUID(),
                streamID: "winner",
                conversationID: request.conversation.id,
                generationCreatedAt: 22,
                protocolVersion: 2
            ))
        case let .protocolFailure(error):
            throw error
        }
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
    func draft(conversationID: ConversationID) -> String { drafts[conversationID] ?? "" }
    func saveDraft(_ text: String, conversationID: ConversationID) { drafts[conversationID] = text }

    private func handle(for request: ChatRequest) -> GenerationHandle {
        GenerationHandle(
            profileID: request.profileID,
            accountID: request.accountID,
            clientRequestID: request.clientRequestID,
            streamID: "accepted",
            conversationID: request.conversation.id,
            generationCreatedAt: 11,
            protocolVersion: 2
        )
    }

    private func sourceMessageID(for request: ChatRequest) -> MessageID? {
        guard case let .regenerateResponse(sourceUserMessageID, _) = request.action else {
            return nil
        }
        return sourceUserMessageID
    }
}
