import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class FollowUpQueueDrainCoordinatorTests: XCTestCase {
    func testExactCompletionPersistsAdmissionBeforeAllowingOnlyOneSend() async throws {
        let fixture = try await Fixture(mode: .streaming)

        async let first = fixture.coordinator.drain(after: fixture.completedSignal)
        async let second = fixture.coordinator.drain(after: fixture.completedSignal)
        let pair = try await (first, second)
        let results = [pair.0, pair.1]

        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.profileID, fixture.namespace.profileID)
        XCTAssertEqual(request.accountID, fixture.namespace.accountID)
        XCTAssertEqual(request.conversation.id, fixture.namespace.conversationID)
        XCTAssertEqual(request.parentMessageID, fixture.responseMessage.id)
        XCTAssertEqual(request.text, "Queued follow-up")
        XCTAssertTrue(request.attachments.isEmpty)
        XCTAssertEqual(request.expectedPredecessorCreatedAt, 100)
        XCTAssertNil(request.recoverySteerID)
        XCTAssertEqual(results.filter {
            if case .admitted = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(results.filter { $0 == .noWork }.count, 1)

        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .admitted(attempt, handle) = persisted.items.first?.state else {
            XCTFail("Expected a durable admitted queue item")
            return
        }
        XCTAssertEqual(attempt.clientRequestID, request.clientRequestID)
        XCTAssertEqual(attempt.clientMessageID, request.clientMessageID)
        XCTAssertEqual(handle.clientRequestID, request.clientRequestID)
    }

    func testAdmittedCompletionAtomicallyDeliversAndDrainsExactlyOneFollower() async throws {
        let fixture = try await Fixture(mode: .streaming, itemCount: 2)

        let firstResult = try await fixture.coordinator.drain(after: fixture.completedSignal)
        guard case let .admitted(_, firstHandle) = firstResult else {
            return XCTFail("Expected the queue head to be admitted")
        }

        let secondResult = try await fixture.coordinator.drain(after: .completed(
            handle: firstHandle,
            responseMessageID: MessageID(rawValue: "assistant-200")
        ))
        guard case let .admitted(secondItemID, secondHandle) = secondResult else {
            return XCTFail("Expected clean completion to release exactly one follower")
        }

        XCTAssertNotEqual(secondItemID, fixture.itemID)
        XCTAssertEqual(secondHandle.generationCreatedAt, 300)
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].parentMessageID, MessageID(rawValue: "assistant-200"))

        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .delivered(_, deliveredHandle, terminal) = persisted.items[0].state else {
            return XCTFail("The first queued turn should be durably terminal")
        }
        XCTAssertEqual(deliveredHandle, firstHandle)
        XCTAssertEqual(
            terminal,
            .completed(responseMessageID: MessageID(rawValue: "assistant-200"))
        )
        guard case let .admitted(_, admittedHandle) = persisted.items[1].state else {
            return XCTFail("The second queued turn should own the lane")
        }
        XCTAssertEqual(admittedHandle, secondHandle)
    }

    func testAdmittedAbortDeliversHeadAndBlocksFollowerWithoutAnotherPost() async throws {
        let fixture = try await Fixture(mode: .streaming, itemCount: 2)
        let firstResult = try await fixture.coordinator.drain(after: fixture.completedSignal)
        guard case let .admitted(_, firstHandle) = firstResult else {
            return XCTFail("Expected the queue head to be admitted")
        }

        let result = try await fixture.coordinator.drain(after: .aborted(handle: firstHandle))

        XCTAssertEqual(result, .delivered(fixture.itemID, .aborted))
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .delivered(_, deliveredHandle, .aborted) = persisted.items[0].state else {
            return XCTFail("The admitted item should retain its aborted terminal")
        }
        XCTAssertEqual(deliveredHandle, firstHandle)
        XCTAssertEqual(persisted.items[1].state, .blocked(.requiresUserReview))
    }

    func testTargetMismatchBlocksAtomicallyWithoutPosting() async throws {
        let fixture = try await Fixture(
            mode: .streaming,
            authoritativeTarget: ConversationTarget(endpoint: "agents", agentID: "changed-agent")
        )

        let result = try await fixture.coordinator.drain(after: fixture.completedSignal)

        XCTAssertEqual(result, .blocked(fixture.itemID, .targetChanged))
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(persisted.items.first?.state, .blocked(.targetChanged))
    }

    func testRecoveredSettledAdmissionUsesSourceIdentityAndCommitsOnlyAfterDurableRowProof() async throws {
        let fixture = try await Fixture(mode: .settledWithDurableUserRow, recoverable: true)

        let result = try await fixture.coordinator.drain(after: fixture.completedSignal)

        XCTAssertEqual(result, .committed(fixture.itemID))
        let requests = await fixture.repository.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.clientMessageID.rawValue, "server-steer-1")
        XCTAssertEqual(request.recoverySteerID, "server-steer-1")
        let acknowledgements = await fixture.repository.acknowledgements()
        XCTAssertEqual(acknowledgements.count, 1)
        XCTAssertEqual(acknowledgements.first?.handle, fixture.sourceHandle)
        XCTAssertEqual(
            acknowledgements.first?.identities,
            Set([RecoverableSteerIdentity(id: "server-steer-1", clientSteerID: "client-steer-1")])
        )

        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .committed(attempt) = persisted.items.first?.state else {
            XCTFail("Expected exact durable user-row proof to commit the journal")
            return
        }
        XCTAssertEqual(attempt.clientMessageID.rawValue, "server-steer-1")

        let repeated = try await fixture.coordinator.drain(after: fixture.completedSignal)
        XCTAssertEqual(repeated, .noWork)
        let finalRequestCount = await fixture.repository.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
    }

    func testQueuedAttachmentsUseExactRequestFilesAndDurableHistoryProof() async throws {
        let attachment = try FollowUpQueuedAttachment(
            uploadID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            file: UploadedFile(
                id: "file-queued-1",
                filename: "queued.txt",
                mimeType: "text/plain"
            )
        )
        let fixture = try await Fixture(
            mode: .settledWithDurableUserRow,
            attachments: [attachment]
        )

        let result = try await fixture.coordinator.drain(after: fixture.completedSignal)

        XCTAssertEqual(result, .committed(fixture.itemID))
        let requests = await fixture.repository.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.attachments, [attachment.file])
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .committed(attempt) = persisted.items.first?.state else {
            return XCTFail("Expected the file-bearing request to commit")
        }
        XCTAssertEqual(attempt.fingerprint.attachments, [attachment])
    }

    func testLostResponseBecomesDeliveryUncertainAndNeverReposts() async throws {
        let fixture = try await Fixture(mode: .transportFailure)

        let first = try await fixture.coordinator.drain(after: fixture.completedSignal)
        guard case let .deliveryUncertain(itemID, .transport) = first else {
            XCTFail("Expected transport uncertainty")
            return
        }
        XCTAssertEqual(itemID, fixture.itemID)

        let relaunched = FollowUpQueueDrainCoordinator(
            cache: fixture.cache,
            repository: fixture.repository,
            namespace: fixture.namespace
        )
        let repeated = try await relaunched.drain(after: fixture.completedSignal)
        XCTAssertEqual(repeated, .noWork)
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 1)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case .deliveryUncertain = persisted.items.first?.state else {
            XCTFail("Expected the exact attempt to remain locked")
            return
        }
    }

    func testExplicitRateLimitAndWinnerHandoffRequireReviewWithoutAutomaticRetry() async throws {
        for mode in [RepositoryDouble.Mode.httpStatus(429), .handoff] {
            let fixture = try await Fixture(mode: mode)

            let result = try await fixture.coordinator.drain(after: fixture.completedSignal)
            XCTAssertEqual(result, .blocked(fixture.itemID, .requiresUserReview))
            let repeated = try await fixture.coordinator.drain(after: fixture.completedSignal)
            XCTAssertEqual(repeated, .noWork)
            let requestCount = await fixture.repository.requestCount()
            XCTAssertEqual(requestCount, 1)
            let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
            XCTAssertEqual(persisted.items.first?.state, .blocked(.requiresUserReview))
        }
    }

    func testUnauthorizedPreflightRestoresQueuedSlotAndPerformsNoPost() async throws {
        let fixture = try await Fixture(mode: .preflightUnauthorized)

        do {
            _ = try await fixture.coordinator.drain(after: fixture.completedSignal)
            XCTFail("Expected unauthorized preflight")
        } catch let error as FollowUpDrainError {
            XCTAssertEqual(error, .unauthorized)
        }

        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(persisted.items.first?.state, .queued)
    }

    func testTransportPreflightRestoresQueuedSlotAndPerformsNoPost() async throws {
        let fixture = try await Fixture(mode: .preflightTransport)

        do {
            _ = try await fixture.coordinator.drain(after: fixture.completedSignal)
            XCTFail("Expected unavailable preflight")
        } catch let error as FollowUpDrainError {
            XCTAssertEqual(error, .preflightUnavailable)
        }

        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(persisted.items.first?.state, .queued)
    }

    func testMalformedHistoryBlocksBeforePostAndTerminalWithoutDurableProofStaysReserved() async throws {
        let malformed = try await Fixture(mode: .invalidHistory)
        let malformedResult = try await malformed.coordinator.drain(after: malformed.completedSignal)
        XCTAssertEqual(malformedResult, .blocked(malformed.itemID, .sourceUnavailable))
        let malformedRequestCount = await malformed.repository.requestCount()
        XCTAssertEqual(malformedRequestCount, 0)

        let missingProof = try await Fixture(mode: .settledWithoutDurableUserRow)
        let missingProofResult = try await missingProof.coordinator.drain(
            after: missingProof.completedSignal
        )
        XCTAssertEqual(missingProofResult, .ambiguous(missingProof.itemID))
        let persisted = try await missingProof.cache.followUpQueue(namespace: missingProof.namespace)
        guard case .reserved = persisted.items.first?.state else {
            XCTFail("A terminal receipt without durable user-row proof must remain reserved")
            return
        }
    }

    func testServerFailureAndInvalidAcknowledgementRetainExactUncertainAttempt() async throws {
        let cases: [(RepositoryDouble.Mode, FollowUpDeliveryUncertaintyReason)] = [
            (.httpStatus(503), .server(status: 503)),
            (.invalidAcknowledgement, .invalidAcknowledgement)
        ]

        for (mode, expectedReason) in cases {
            let fixture = try await Fixture(mode: mode)
            let result = try await fixture.coordinator.drain(after: fixture.completedSignal)
            XCTAssertEqual(
                result,
                .deliveryUncertain(fixture.itemID, expectedReason)
            )
            let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
            guard case let .deliveryUncertain(_, reason) = persisted.items.first?.state else {
                XCTFail("Expected delivery uncertainty to remain durable")
                return
            }
            XCTAssertEqual(reason, expectedReason)
        }
    }

    func testOutstandingActiveProofPromotesUncertainAttemptWithoutReposting() async throws {
        let fixture = try await Fixture(mode: .transportThenReconcileActive)
        let first = try await fixture.coordinator.drain(after: fixture.completedSignal)
        guard case .deliveryUncertain = first else {
            XCTFail("Expected the first admission to remain uncertain")
            return
        }

        let reconciled = try await fixture.coordinator.reconcileOutstandingAdmission()
        guard case let .admitted(itemID, handle) = reconciled else {
            XCTFail("Expected exact status metadata to recover the admission")
            return
        }
        XCTAssertEqual(itemID, fixture.itemID)
        XCTAssertEqual(handle.generationCreatedAt, 200)
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1, "Reconciliation must never replay the generation POST")
        XCTAssertEqual(handle.clientRequestID, requests.first?.clientRequestID)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .admitted(attempt, savedHandle) = persisted.items.first?.state else {
            XCTFail("Expected a durable admitted state")
            return
        }
        XCTAssertEqual(attempt.clientRequestID, handle.clientRequestID)
        XCTAssertEqual(savedHandle, handle)
    }

    func testRelaunchedAdmittedActiveProofKeepsExactHandleWithoutReposting() async throws {
        let fixture = try await Fixture(mode: .streamingThenReconcileActive)
        let admitted = try await fixture.coordinator.drain(after: fixture.completedSignal)
        guard case let .admitted(_, originalHandle) = admitted else {
            return XCTFail("Expected the first drain to persist an admitted handle")
        }

        let relaunched = FollowUpQueueDrainCoordinator(
            cache: fixture.cache,
            repository: fixture.repository,
            namespace: fixture.namespace
        )
        let reconciled = try await relaunched.reconcileOutstandingAdmission()

        XCTAssertEqual(reconciled, .admitted(fixture.itemID, originalHandle))
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1, "Relaunch reconciliation must not replay the POST")
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .admitted(_, savedHandle) = persisted.items.first?.state else {
            return XCTFail("Expected the admitted journal coordinates to remain intact")
        }
        XCTAssertEqual(savedHandle, originalHandle)
    }

    func testRelaunchedAdmittedTerminalProofDeliversWithoutReposting() async throws {
        let fixture = try await Fixture(mode: .streamingThenReconcileCompleted)
        _ = try await fixture.coordinator.drain(after: fixture.completedSignal)

        let result = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(
            result,
            .delivered(
                fixture.itemID,
                .completed(responseMessageID: MessageID(rawValue: "assistant-200"))
            )
        )
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .delivered(_, handle, terminal) = persisted.items.first?.state else {
            return XCTFail("Expected the restored admitted item to become terminal")
        }
        XCTAssertEqual(handle.generationCreatedAt, 200)
        XCTAssertEqual(
            terminal,
            .completed(responseMessageID: MessageID(rawValue: "assistant-200"))
        )
    }

    func testRelaunchedAdmittedJoblessHistoryProofCompletesWithoutInventingEpoch() async throws {
        let fixture = try await Fixture(mode: .streamingThenReconcileJobless, itemCount: 2)
        _ = try await fixture.coordinator.drain(after: fixture.completedSignal)

        let result = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(
            result,
            .deliveredWithoutEpoch(
                fixture.itemID,
                responseMessageID: MessageID(rawValue: "assistant-200")
            )
        )
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case .deliveredWithoutEpoch = persisted.items[0].state else {
            return XCTFail("Expected exact jobless history proof to close the admitted item")
        }
        XCTAssertEqual(persisted.items[1].state, .blocked(.predecessorUnverified))
    }

    func testRelaunchedAdmittedDifferentEpochStaysLockedWithoutRetargeting() async throws {
        let fixture = try await Fixture(mode: .streamingThenReconcileDifferentEpoch)
        let admitted = try await fixture.coordinator.drain(after: fixture.completedSignal)
        guard case let .admitted(_, originalHandle) = admitted else {
            return XCTFail("Expected an admitted handle")
        }

        let result = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(result, .ambiguous(fixture.itemID))
        let requests = await fixture.repository.requests()
        XCTAssertEqual(requests.count, 1)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .admitted(_, savedHandle) = persisted.items.first?.state else {
            return XCTFail("Expected the original handle to remain locked")
        }
        XCTAssertEqual(savedHandle, originalHandle)
    }

    func testRetainedCompletedProofRequiresDurableRowsAndAtomicallyDelivers() async throws {
        let fixture = try await Fixture(mode: .reconcileCompleted)
        let attempt = try await fixture.reserveWithoutPosting()

        let reconciled = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(
            reconciled,
            .delivered(
                fixture.itemID,
                .completed(responseMessageID: MessageID(rawValue: "assistant-reconciled"))
            )
        )
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        guard case let .delivered(savedAttempt, handle, terminal) = persisted.items.first?.state else {
            XCTFail("Expected a durable terminal admission")
            return
        }
        XCTAssertEqual(savedAttempt, attempt)
        XCTAssertEqual(handle.clientRequestID, attempt.clientRequestID)
        XCTAssertEqual(terminal, .completed(responseMessageID: MessageID(rawValue: "assistant-reconciled")))
    }

    func testJoblessDurableRowCommitsWithoutManufacturingHandle() async throws {
        let fixture = try await Fixture(mode: .reconcileJoblessDurable)
        let attempt = try await fixture.reserveWithoutPosting()

        let reconciled = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(reconciled, .committed(fixture.itemID))
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(persisted.items.first?.state, .committed(attempt))
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testJoblessCleanResponseDeliversWithoutEpochAndBlocksFollower() async throws {
        let fixture = try await Fixture(mode: .reconcileJoblessCompleted, itemCount: 2)
        let attempt = try await fixture.reserveWithoutPosting()

        let reconciled = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(
            reconciled,
            .deliveredWithoutEpoch(
                fixture.itemID,
                responseMessageID: MessageID(rawValue: "assistant-jobless")
            )
        )
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(
            persisted.items[0].state,
            .deliveredWithoutEpoch(
                attempt: attempt,
                responseMessageID: MessageID(rawValue: "assistant-jobless")
            )
        )
        XCTAssertEqual(persisted.items[1].state, .blocked(.predecessorUnverified))
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0, "A missing epoch must never trigger a follower POST")
    }

    func testJoblessMultipleAssistantChildrenStayCommittedAndNeverGuessBranch() async throws {
        let fixture = try await Fixture(mode: .reconcileJoblessAmbiguousResponses, itemCount: 2)
        let attempt = try await fixture.reserveWithoutPosting()

        let reconciled = try await fixture.coordinator.reconcileOutstandingAdmission()

        XCTAssertEqual(reconciled, .committed(fixture.itemID))
        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(persisted.items[0].state, .committed(attempt))
        XCTAssertEqual(persisted.items[1].state, .queued)
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testReconciliationUnauthorizedKeepsExactReservation() async throws {
        let fixture = try await Fixture(mode: .reconcileUnauthorized)
        let attempt = try await fixture.reserveWithoutPosting()

        do {
            _ = try await fixture.coordinator.reconcileOutstandingAdmission()
            XCTFail("Expected unauthorized reconciliation")
        } catch let error as FollowUpDrainError {
            XCTAssertEqual(error, .unauthorized)
        }

        let persisted = try await fixture.cache.followUpQueue(namespace: fixture.namespace)
        XCTAssertEqual(persisted.items.first?.state, .reserved(attempt))
        let requestCount = await fixture.repository.requestCount()
        XCTAssertEqual(requestCount, 0)
    }
}

private extension FollowUpQueueDrainCoordinatorTests {
    struct Fixture {
        let cache: CacheCoordinator
        let repository: RepositoryDouble
        let coordinator: FollowUpQueueDrainCoordinator
        let namespace: FollowUpQueueNamespace
        let sourceHandle: GenerationHandle
        let sourceMessage: ChatMessage
        let responseMessage: ChatMessage
        let itemID: FollowUpQueueItemID

        var completedSignal: FollowUpGenerationSignal {
            .completed(handle: sourceHandle, responseMessageID: responseMessage.id)
        }

        func reserveWithoutPosting() async throws -> FollowUpAdmissionAttempt {
            let result = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                try reducer.reserveNext(
                    after: completedSignal,
                    attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
                    clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
                    clientMessageID: MessageID(rawValue: "queued-user-reconciled")
                )
            }
            return try XCTUnwrap(result.result)
        }

        @MainActor
        init(
            mode: RepositoryDouble.Mode,
            authoritativeTarget: ConversationTarget? = nil,
            recoverable: Bool = false,
            itemCount: Int = 1,
            attachments: [FollowUpQueuedAttachment] = []
        ) async throws {
            let dependencies = try AppDependencies(inMemory: true)
            cache = dependencies.cache
            namespace = try FollowUpQueueNamespace(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversationID: ConversationID(rawValue: "conversation")
            )
            sourceHandle = GenerationHandle(
                profileID: namespace.profileID,
                accountID: namespace.accountID,
                clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
                streamID: "conversation:100",
                conversationID: namespace.conversationID,
                generationCreatedAt: 100,
                protocolVersion: 2
            )
            sourceMessage = ChatMessage(
                id: MessageID(rawValue: "source-user"),
                conversationID: namespace.conversationID,
                content: [.text("Source prompt")],
                author: .user
            )
            responseMessage = ChatMessage(
                id: MessageID(rawValue: "assistant-100"),
                conversationID: namespace.conversationID,
                parentMessageID: sourceMessage.id,
                content: [.text("Completed response")],
                author: .assistant(name: "Assistant"),
                isUnfinished: false,
                finishReason: "stop"
            )
            let target = ConversationTarget(
                endpoint: "agents",
                model: "model-a",
                agentID: "agent-a",
                spec: "spec-a"
            )
            let recovery: FollowUpRecoverableSource? = if recoverable {
                try FollowUpRecoverableSource(
                    handle: sourceHandle,
                    identity: RecoverableSteerIdentity(
                        id: "server-steer-1",
                        clientSteerID: "client-steer-1"
                    )
                )
            } else {
                nil
            }
            itemID = FollowUpQueueItemID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            )
            let targetFingerprint = try FollowUpTargetFingerprint(target: target)
            let sourceAnchor = try FollowUpSourceAnchor(
                handle: sourceHandle,
                sourceUserMessageID: sourceMessage.id
            )
            var items: [FollowUpQueueItem] = []
            for index in 0..<itemCount {
                let queuedItemID = index == 0 ? itemID : FollowUpQueueItemID()
                let queuedText = index == 0
                    ? "Queued follow-up"
                    : "Queued follow-up \(index + 1)"
                let queuedRecovery = index == 0 ? recovery : nil
                let queuedItem = try FollowUpQueueItem(
                    id: queuedItemID,
                    namespace: namespace,
                    order: FollowUpQueueOrder(rawValue: UInt64(index + 1)),
                    text: queuedText,
                    attachments: index == 0 ? attachments : [],
                    target: targetFingerprint,
                    sourceAnchor: sourceAnchor,
                    recoverableSource: queuedRecovery
                )
                items.append(queuedItem)
            }
            try await cache.saveFollowUpQueue(
                FollowUpQueueSnapshot(namespace: namespace, items: items)
            )
            repository = RepositoryDouble(
                conversation: Conversation(
                    id: namespace.conversationID,
                    title: "Conversation",
                    target: authoritativeTarget ?? target
                ),
                baseHistory: [sourceMessage, responseMessage],
                sourceHandle: sourceHandle,
                mode: mode
            )
            coordinator = FollowUpQueueDrainCoordinator(
                cache: cache,
                repository: repository,
                namespace: namespace
            )
        }
    }

    actor RepositoryDouble: FollowUpDrainRepository {
        enum Mode: Equatable, Sendable {
            case streaming
            case settledWithDurableUserRow
            case settledWithoutDurableUserRow
            case transportFailure
            case httpStatus(Int)
            case handoff
            case preflightUnauthorized
            case preflightTransport
            case invalidHistory
            case invalidAcknowledgement
            case transportThenReconcileActive
            case streamingThenReconcileActive
            case streamingThenReconcileCompleted
            case streamingThenReconcileJobless
            case streamingThenReconcileDifferentEpoch
            case reconcileCompleted
            case reconcileJoblessDurable
            case reconcileJoblessCompleted
            case reconcileJoblessAmbiguousResponses
            case reconcileUnauthorized
        }

        struct Acknowledgement: Equatable, Sendable {
            let handle: GenerationHandle
            let identities: Set<RecoverableSteerIdentity>
        }

        private let conversationValue: Conversation
        private let baseHistory: [ChatMessage]
        private let sourceHandle: GenerationHandle
        private let mode: Mode
        private var capturedRequests: [ChatRequest] = []
        private var capturedAcknowledgements: [Acknowledgement] = []
        private var reconciledAttempt: FollowUpAdmissionAttempt?

        init(
            conversation: Conversation,
            baseHistory: [ChatMessage],
            sourceHandle: GenerationHandle,
            mode: Mode
        ) {
            conversationValue = conversation
            self.baseHistory = baseHistory
            self.sourceHandle = sourceHandle
            self.mode = mode
        }

        func conversation(id: ConversationID) async throws -> Conversation {
            if mode == .preflightUnauthorized {
                throw LibreChatProtocolError.unauthorized
            }
            if mode == .preflightTransport {
                throw LibreChatProtocolError.transport("fixture")
            }
            return conversationValue
        }

        func messages(conversationID: ConversationID) async throws -> [ChatMessage] {
            if mode == .invalidHistory {
                return baseHistory + [baseHistory[0]]
            }
            if mode == .reconcileCompleted
                || mode == .reconcileJoblessDurable
                || mode == .reconcileJoblessCompleted
                || mode == .reconcileJoblessAmbiguousResponses,
               let attempt = reconciledAttempt {
                let user = ChatMessage(
                    id: attempt.clientMessageID,
                    conversationID: conversationID,
                    parentMessageID: attempt.fingerprint.parentMessageID,
                    content: [.text(attempt.fingerprint.text)],
                    author: .user,
                    isUnfinished: false
                )
                guard mode != .reconcileJoblessDurable else {
                    return baseHistory + [user]
                }
                let responseID = mode == .reconcileCompleted
                    ? "assistant-reconciled"
                    : "assistant-jobless"
                var history = baseHistory + [user, ChatMessage(
                    id: MessageID(rawValue: responseID),
                    conversationID: conversationID,
                    parentMessageID: user.id,
                    content: [.text("Reconciled response")],
                    author: .assistant(name: "Assistant"),
                    isUnfinished: false,
                    finishReason: "stop"
                )]
                if mode == .reconcileJoblessAmbiguousResponses {
                    history.append(ChatMessage(
                        id: MessageID(rawValue: "assistant-jobless-sibling"),
                        conversationID: conversationID,
                        parentMessageID: user.id,
                        content: [.text("Competing response")],
                        author: .assistant(name: "Assistant"),
                        isUnfinished: false,
                        finishReason: "stop"
                    ))
                }
                return history
            }
            if [
                .streaming,
                .streamingThenReconcileActive,
                .streamingThenReconcileCompleted,
                .streamingThenReconcileJobless,
                .streamingThenReconcileDifferentEpoch
            ].contains(mode), !capturedRequests.isEmpty {
                return capturedRequests.enumerated().reduce(into: baseHistory) { history, pair in
                    let (index, request) = pair
                    let epoch = (sourceHandle.generationCreatedAt ?? 0) + Int64(index + 1) * 100
                    let user = ChatMessage(
                        id: request.clientMessageID,
                        conversationID: conversationID,
                        parentMessageID: request.parentMessageID,
                        content: [.text(request.text)],
                        author: .user,
                        isUnfinished: false
                    )
                    history.append(user)
                    history.append(ChatMessage(
                        id: MessageID(rawValue: "assistant-\(epoch)"),
                        conversationID: conversationID,
                        parentMessageID: user.id,
                        content: [.text("Completed queued response")],
                        author: .assistant(name: "Assistant"),
                        isUnfinished: false,
                        finishReason: "stop"
                    ))
                }
            }
            guard mode == .settledWithDurableUserRow,
                  let request = capturedRequests.last else {
                return baseHistory
            }
            return baseHistory + [ChatMessage(
                id: request.clientMessageID,
                conversationID: conversationID,
                parentMessageID: request.parentMessageID,
                content: [.text(request.text)] + request.attachments.map(MessageContent.file),
                author: .user,
                isUnfinished: false
            )]
        }

        func send(_ request: ChatRequest) async throws -> ChatSendOutcome {
            capturedRequests.append(request)
            switch mode {
            case .streaming,
                 .streamingThenReconcileActive,
                 .streamingThenReconcileCompleted,
                 .streamingThenReconcileJobless,
                 .streamingThenReconcileDifferentEpoch:
                let epoch = (sourceHandle.generationCreatedAt ?? 0)
                    + Int64(capturedRequests.count) * 100
                return .streaming(GenerationHandle(
                    profileID: request.profileID,
                    accountID: request.accountID,
                    clientRequestID: request.clientRequestID,
                    streamID: "conversation:\(epoch)",
                    conversationID: request.conversation.id,
                    generationCreatedAt: epoch,
                    protocolVersion: 2
                ))
            case .settledWithDurableUserRow, .settledWithoutDurableUserRow:
                return .settled(conversationID: request.conversation.id)
            case .transportFailure:
                throw LibreChatProtocolError.transport("fixture")
            case .transportThenReconcileActive:
                throw LibreChatProtocolError.transport("fixture")
            case let .httpStatus(status):
                throw LibreChatProtocolError.httpStatus(status, message: nil, retryAfter: 1)
            case .handoff:
                return .handoff(GenerationHandle(
                    profileID: request.profileID,
                    accountID: request.accountID,
                    clientRequestID: UUID(),
                    streamID: "conversation:winner",
                    conversationID: request.conversation.id,
                    generationCreatedAt: (sourceHandle.generationCreatedAt ?? 0) + 100,
                    protocolVersion: 2
                ))
            case .preflightUnauthorized, .preflightTransport, .invalidHistory,
                 .reconcileCompleted, .reconcileJoblessDurable,
                 .reconcileJoblessCompleted, .reconcileJoblessAmbiguousResponses,
                 .reconcileUnauthorized:
                XCTFail("Preflight failure must not dispatch a generation request")
                throw LibreChatProtocolError.invalidResponse
            case .invalidAcknowledgement:
                throw LibreChatProtocolError.invalidResponse
            }
        }

        func followUpAdmissionProof(
            for attempt: FollowUpAdmissionAttempt
        ) async throws -> FollowUpAdmissionProof? {
            reconciledAttempt = attempt
            if mode == .reconcileUnauthorized {
                throw LibreChatProtocolError.unauthorized
            }
            let proofEpoch: Int64 = mode == .streamingThenReconcileDifferentEpoch ? 300 : 200
            let handle = GenerationHandle(
                profileID: attempt.fingerprint.namespace.profileID,
                accountID: attempt.fingerprint.namespace.accountID,
                clientRequestID: attempt.clientRequestID,
                // The status proof must carry the same exact stream coordinate
                // returned by the generation-start receipt. A conversation ID
                // alone is not an interchangeable stream identity.
                streamID: "\(attempt.fingerprint.namespace.conversationID.rawValue):\(proofEpoch)",
                conversationID: attempt.fingerprint.namespace.conversationID,
                generationCreatedAt: proofEpoch,
                protocolVersion: 2
            )
            switch mode {
            case .transportThenReconcileActive, .streamingThenReconcileActive,
                 .streamingThenReconcileDifferentEpoch:
                return .active(handle)
            case .reconcileCompleted, .streamingThenReconcileCompleted:
                return .terminal(
                    handle: handle,
                    terminal: .completed(
                        responseMessageID: MessageID(rawValue: mode == .reconcileCompleted
                            ? "assistant-reconciled"
                            : "assistant-200")
                    )
                )
            case .reconcileJoblessDurable,
                 .reconcileJoblessCompleted,
                 .reconcileJoblessAmbiguousResponses,
                 .streamingThenReconcileJobless:
                return nil
            default:
                return nil
            }
        }

        func acknowledgeRecoverableSteers(
            handle: GenerationHandle,
            identities: Set<RecoverableSteerIdentity>
        ) async throws -> RecoverableSteerBatch? {
            capturedAcknowledgements.append(Acknowledgement(
                handle: handle,
                identities: identities
            ))
            return nil
        }

        func requests() -> [ChatRequest] { capturedRequests }
        func requestCount() -> Int { capturedRequests.count }
        func acknowledgements() -> [Acknowledgement] { capturedAcknowledgements }
    }
}
