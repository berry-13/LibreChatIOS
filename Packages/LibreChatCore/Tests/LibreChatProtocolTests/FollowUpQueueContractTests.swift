import Foundation
import LibreChatDomain
import Testing

@Suite("Durable follow-up queue")
struct FollowUpQueueContractTests {
    @Test func durableOrderIsCanonicalAndDuplicateCoordinatesFailClosed() throws {
        let context = try Context()
        let third = try context.item(order: 30, text: "Third")
        let first = try context.item(order: 10, text: "First")
        let second = try context.item(order: 20, text: "Second")

        let snapshot = try FollowUpQueueSnapshot(
            namespace: context.namespace,
            items: [third, first, second]
        )

        #expect(snapshot.items.map(\.text) == ["First", "Second", "Third"])
        #expect(throws: FollowUpQueueError.duplicateItemID) {
            try FollowUpQueueSnapshot(namespace: context.namespace, items: [first, first])
        }
        #expect(throws: FollowUpQueueError.duplicateOrder) {
            try FollowUpQueueSnapshot(
                namespace: context.namespace,
                items: [
                    first,
                    context.item(
                        id: FollowUpQueueItemID(
                            UUID(uuidString: "00000000-0000-0000-0000-000000000999")!
                        ),
                        order: 10,
                        text: "Same slot"
                    )
                ]
            )
        }
    }

    @Test func reserveAndDefinitiveRestoreKeepTheSameStableSlot() throws {
        let context = try Context()
        let first = try context.item(order: 10, text: "First")
        let second = try context.item(order: 20, text: "Second")
        var reducer = try context.reducer(items: [second, first])

        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)

        #expect(attempt.fingerprint.itemID == first.id)
        #expect(attempt.slot.previousItemID == nil)
        #expect(attempt.slot.nextItemID == second.id)

        try reducer.restoreReserved(itemID: first.id, attemptID: attempt.id)

        #expect(reducer.snapshot.items.map(\.id) == [first.id, second.id])
        #expect(reducer.snapshot.items.allSatisfy { $0.state == .queued })

        let restoredAttemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000105")!,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000106")!,
            clientMessageID: MessageID(rawValue: "queued-user-2")
        )
        let restoredAttempt = try #require(restoredAttemptValue)
        #expect(restoredAttempt.fingerprint.itemID == first.id)
        #expect(restoredAttempt.slot.nextItemID == second.id)
    }

    @Test func queuedEditRemoveAndReorderPreserveIdentityAndDeterministicSlots() throws {
        let context = try Context()
        let first = try context.item(order: 10, text: "First")
        let second = try context.item(order: 20, text: "Second")
        let third = try context.item(order: 30, text: "Third")
        var reducer = try context.reducer(items: [first, second, third])

        try reducer.editQueued(itemID: second.id, text: "Edited second")
        let edited = try #require(reducer.snapshot.items.first(where: { $0.id == second.id }))
        #expect(edited.id == second.id)
        #expect(edited.order == second.order)
        #expect(edited.sourceAnchor == second.sourceAnchor)
        #expect(edited.target == second.target)
        #expect(edited.text == "Edited second")

        try reducer.reorderQueued(itemIDs: [third.id, first.id, second.id])
        #expect(reducer.snapshot.items.map(\.id) == [third.id, first.id, second.id])
        #expect(reducer.snapshot.items.map(\.order.rawValue) == [10, 20, 30])

        try reducer.removeQueued(itemID: first.id)
        #expect(reducer.snapshot.items.map(\.id) == [third.id, second.id])
        #expect(reducer.snapshot.items.map(\.order.rawValue) == [10, 30])
    }

    @Test func queuedMutationsRejectEveryAdmissionJournalStateWithoutMutation() throws {
        let context = try Context()

        for lockedState in LockedState.allCases {
            var reducer = try context.reducer(lockedState: lockedState)
            let before = reducer.snapshot
            let itemID = try #require(before.items.first?.id)

            #expect(throws: FollowUpQueueError.self) {
                try reducer.editQueued(itemID: itemID, text: "Must not change")
            }
            #expect(reducer.snapshot == before)
            #expect(throws: FollowUpQueueError.self) {
                try reducer.removeQueued(itemID: itemID)
            }
            #expect(reducer.snapshot == before)
            #expect(throws: FollowUpQueueError.self) {
                try reducer.reorderQueued(itemIDs: [itemID])
            }
            #expect(reducer.snapshot == before)
        }
    }

    @Test func blockedReviewItemCanBeRemovedButNotEditedOrReordered() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        try reducer.block(itemID: item.id, reason: .requiresUserReview)

        #expect(throws: FollowUpQueueError.self) {
            try reducer.editQueued(itemID: item.id, text: "Must not change")
        }
        #expect(throws: FollowUpQueueError.self) {
            try reducer.reorderQueued(itemIDs: [item.id])
        }

        try reducer.removeQueued(itemID: item.id)
        #expect(reducer.snapshot.items.isEmpty)
    }

    @Test func queuedMutationValidationAndIncompleteReordersAreAtomic() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2)
        var reducer = try context.reducer(items: [first, second])
        let before = reducer.snapshot

        #expect(throws: FollowUpQueueError.invalidText) {
            try reducer.editQueued(itemID: first.id, text: "  ")
        }
        #expect(reducer.snapshot == before)
        #expect(throws: FollowUpQueueError.invalidReorder) {
            try reducer.reorderQueued(itemIDs: [second.id])
        }
        #expect(reducer.snapshot == before)
        #expect(throws: FollowUpQueueError.invalidReorder) {
            try reducer.reorderQueued(itemIDs: [first.id, first.id])
        }
        #expect(reducer.snapshot == before)
        #expect(throws: FollowUpQueueError.itemNotFound) {
            try reducer.removeQueued(itemID: FollowUpQueueItemID())
        }
        #expect(reducer.snapshot == before)
    }

    @Test func queuedAttachmentsRoundTripAndFreezeIntoAdmissionFingerprint() throws {
        let context = try Context()
        let attachment = try FollowUpQueuedAttachment(
            uploadID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            file: UploadedFile(id: "file-1", filename: "notes.txt", mimeType: "text/plain")
        )
        let item = try FollowUpQueueItem(
            id: FollowUpQueueItemID(),
            namespace: context.namespace,
            order: FollowUpQueueOrder(rawValue: 1),
            text: "Queued with a file",
            attachments: [attachment],
            target: context.target,
            sourceAnchor: context.sourceAnchor
        )
        let snapshot = try FollowUpQueueSnapshot(namespace: context.namespace, items: [item])
        let decoded = try JSONDecoder().decode(
            FollowUpQueueSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(decoded == snapshot)

        var reducer = FollowUpQueueReducer(snapshot: decoded)
        let attempt = try #require(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        ))
        #expect(attempt.fingerprint.attachments == [attachment])
    }

    @Test func duplicateQueuedAttachmentCoordinatesFailClosedAndLegacyRowsDefaultEmpty() throws {
        let context = try Context()
        let uploadID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let first = try FollowUpQueuedAttachment(
            uploadID: uploadID,
            file: UploadedFile(id: "file-1", filename: "one.txt")
        )
        let duplicateLocal = try FollowUpQueuedAttachment(
            uploadID: uploadID,
            file: UploadedFile(id: "file-2", filename: "two.txt")
        )
        #expect(throws: FollowUpQueueError.duplicateAttachment) {
            _ = try FollowUpQueueItem(
                id: FollowUpQueueItemID(),
                namespace: context.namespace,
                order: FollowUpQueueOrder(rawValue: 1),
                text: "Unsafe duplicate",
                attachments: [first, duplicateLocal],
                target: context.target,
                sourceAnchor: context.sourceAnchor
            )
        }

        let encoded = try JSONEncoder().encode(context.item(order: 1))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "attachments")
        let legacy = try JSONDecoder().decode(
            FollowUpQueueItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.attachments.isEmpty)
    }

    @Test func onlyCleanCompletionCanReserveTheFIFOHead() throws {
        let context = try Context()
        let signals: [FollowUpGenerationSignal] = [
            .aborted(handle: context.sourceHandle),
            .failed(handle: context.sourceHandle),
            .superseded(handle: context.sourceHandle),
            .awaitingInteraction(handle: context.sourceHandle),
            .ambiguous(handle: context.sourceHandle)
        ]

        for (offset, signal) in signals.enumerated() {
            var reducer = try context.reducer(items: [context.item(order: 1)])
            let result = try reducer.reserveNext(
                after: signal,
                attemptID: UUID(),
                clientRequestID: UUID(),
                clientMessageID: MessageID(rawValue: "client-\(offset)")
            )
            #expect(result == nil)
            #expect(reducer.snapshot.items.first?.state == .queued)
        }

        var reducer = try context.reducer(items: [context.item(order: 1)])
        let completed = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        #expect(completed != nil)
    }

    @Test func admissionRebasesFollowersAndCleanCompletionDrainsExactlyOne() throws {
        let context = try Context()
        let first = try context.item(order: 1, text: "First")
        let second = try context.item(order: 2, text: "Second")
        let third = try context.item(order: 3, text: "Third")
        var reducer = try context.reducer(items: [first, second, third])
        let firstAttemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let firstAttempt = try #require(firstAttemptValue)
        let admittedHandle = context.handle(
            epoch: 200,
            clientRequestID: firstAttempt.clientRequestID,
            streamID: "conversation:200"
        )

        try reducer.markAdmitted(
            itemID: first.id,
            attemptID: firstAttempt.id,
            handle: admittedHandle
        )

        #expect(reducer.snapshot.items[1].sourceAnchor.handle == admittedHandle)
        #expect(reducer.snapshot.items[1].sourceAnchor.sourceUserMessageID == firstAttempt.clientMessageID)
        #expect(reducer.snapshot.items[2].sourceAnchor.handle == admittedHandle)
        #expect(try reducer.reserveNext(
            after: .completed(
                handle: admittedHandle,
                responseMessageID: MessageID(rawValue: "assistant-200")
            ),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "must-not-reserve-yet")
        ) == nil)

        let transitioned = try reducer.observeAdmittedTerminal(
            itemID: first.id,
            attemptID: firstAttempt.id,
            signal: .completed(
                handle: admittedHandle,
                responseMessageID: MessageID(rawValue: "assistant-200")
            )
        )
        #expect(transitioned)

        let secondAttemptValue = try reducer.reserveNext(
            after: .completed(
                handle: admittedHandle,
                responseMessageID: MessageID(rawValue: "assistant-200")
            ),
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!,
            clientMessageID: MessageID(rawValue: "queued-user-200")
        )
        let secondAttempt = try #require(secondAttemptValue)
        #expect(secondAttempt.fingerprint.itemID == second.id)
        #expect(secondAttempt.fingerprint.parentMessageID == MessageID(rawValue: "assistant-200"))
        #expect(reducer.snapshot.items.filter(\.state.isReserved).count == 1)
    }

    @Test func noncompletedAcceptedTerminalNeverReleasesFollowers() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2)

        for terminal in TerminalKind.allCases {
            var reducer = try context.reducer(items: [first, second])
            let attemptValue = try reducer.reserveNext(
                after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
                attemptID: context.attemptID,
                clientRequestID: context.clientRequestID,
                clientMessageID: context.clientMessageID
            )
            let attempt = try #require(attemptValue)
            let admitted = context.handle(
                epoch: 200,
                clientRequestID: attempt.clientRequestID,
                streamID: "admitted-\(terminal.rawValue)"
            )
            try reducer.markAdmitted(itemID: first.id, attemptID: attempt.id, handle: admitted)
            _ = try reducer.observeAdmittedTerminal(
                itemID: first.id,
                attemptID: attempt.id,
                signal: terminal.signal(handle: admitted)
            )

            let sameTerminalResult = try reducer.reserveNext(
                after: terminal.signal(handle: admitted),
                attemptID: UUID(),
                clientRequestID: UUID(),
                clientMessageID: MessageID(rawValue: "later")
            )
            #expect(sameTerminalResult == nil)

            let contradictoryCompletion = try reducer.reserveNext(
                after: .completed(
                    handle: admitted,
                    responseMessageID: MessageID(rawValue: "contradictory-response")
                ),
                attemptID: UUID(),
                clientRequestID: UUID(),
                clientMessageID: MessageID(rawValue: "later")
            )
            #expect(contradictoryCompletion == nil)
        }
    }

    @Test func hitlAndAmbiguousObservationsKeepAnAdmittedLaneOccupied() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)
        let admitted = context.handle(epoch: 200, clientRequestID: attempt.clientRequestID)
        try reducer.markAdmitted(itemID: item.id, attemptID: attempt.id, handle: admitted)

        let hitl = try reducer.observeAdmittedTerminal(
            itemID: item.id,
            attemptID: attempt.id,
            signal: .awaitingInteraction(handle: admitted)
        )
        let ambiguous = try reducer.observeAdmittedTerminal(
            itemID: item.id,
            attemptID: attempt.id,
            signal: .ambiguous(handle: admitted)
        )

        #expect(!hitl)
        #expect(!ambiguous)
        #expect(reducer.snapshot.items.first?.state.isAdmitted == true)
    }

    @Test func handoffRestoresSameItemAndRebasesEveryFollowerToExactWinner() throws {
        let context = try Context()
        let first = try context.item(order: 1, text: "First")
        let second = try context.item(order: 2, text: "Second")
        var reducer = try context.reducer(items: [first, second])
        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)
        let winner = context.handle(
            epoch: 250,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000250")!,
            streamID: "winner"
        )

        try reducer.restoreReserved(
            itemID: first.id,
            attemptID: attempt.id,
            handoff: FollowUpHandoffRebase(
                winnerHandle: winner,
                winnerUserMessageID: MessageID(rawValue: "winner-user")
            )
        )

        #expect(reducer.snapshot.items.map(\.id) == [first.id, second.id])
        #expect(reducer.snapshot.items.allSatisfy { $0.sourceAnchor.handle == winner })
        #expect(reducer.snapshot.items.allSatisfy {
            $0.sourceAnchor.sourceUserMessageID == MessageID(rawValue: "winner-user")
        })
        #expect(try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "old-source-must-not-drain")
        ) == nil)

        let rebasedValue = try reducer.reserveNext(
            after: .completed(
                handle: winner,
                responseMessageID: MessageID(rawValue: "winner-assistant")
            ),
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000251")!,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000252")!,
            clientMessageID: MessageID(rawValue: "rebased-client")
        )
        let rebased = try #require(rebasedValue)
        #expect(rebased.fingerprint.itemID == first.id)
        #expect(rebased.fingerprint.sourceAnchor.handle == winner)
    }

    @Test func invalidHandoffCannotMoveOrRetargetTheReservedItem() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)
        let before = reducer.snapshot
        let staleWinner = context.handle(epoch: 100, clientRequestID: UUID(), streamID: "stale")

        #expect(throws: FollowUpQueueError.invalidHandoff) {
            try reducer.restoreReserved(
                itemID: item.id,
                attemptID: attempt.id,
                handoff: FollowUpHandoffRebase(
                    winnerHandle: staleWinner,
                    winnerUserMessageID: MessageID(rawValue: "winner-user")
                )
            )
        }
        #expect(reducer.snapshot == before)
    }

    @Test func namespaceFullHandleAndEpochFencesNeverRetarget() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let foreign = context.handle(
            epoch: 100,
            profileID: ServerProfileID(rawValue: "other-profile")
        )
        #expect(throws: FollowUpQueueError.contextMismatch) {
            try reducer.reserveNext(
                after: .completed(handle: foreign, responseMessageID: context.responseMessageID),
                attemptID: UUID(),
                clientRequestID: UUID(),
                clientMessageID: MessageID(rawValue: "foreign")
            )
        }

        let replacement = context.handle(epoch: 101, streamID: "replacement")
        let replacementResult = try reducer.reserveNext(
            after: .completed(handle: replacement, responseMessageID: context.responseMessageID),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "replacement")
        )
        #expect(replacementResult == nil)

        let v1 = context.handle(epoch: 100, protocolVersion: 1)
        #expect(throws: FollowUpQueueError.invalidGenerationHandle) {
            try reducer.reserveNext(
                after: .completed(handle: v1, responseMessageID: context.responseMessageID),
                attemptID: UUID(),
                clientRequestID: UUID(),
                clientMessageID: MessageID(rawValue: "legacy")
            )
        }
        #expect(reducer.snapshot.items.first?.state == .queued)
    }

    @Test func deliveryUncertaintyKeepsStableAttemptAndBlocksAutomaticAdmission() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)

        try reducer.markDeliveryUncertain(
            itemID: item.id,
            attemptID: attempt.id,
            reason: .transport
        )

        let state = try #require(reducer.snapshot.items.first?.state)
        guard case let .deliveryUncertain(retained, .transport) = state else {
            Issue.record("Expected a transport-uncertain admission")
            return
        }
        #expect(retained == attempt)
        #expect(try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "must-not-remint")
        ) == nil)
        #expect(throws: FollowUpQueueError.invalidTransition) {
            try reducer.restoreReserved(itemID: item.id, attemptID: attempt.id)
        }
    }

    @Test func exactProofCanPromoteUncertainAttemptWithoutChangingItsIdentity() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)
        try reducer.markDeliveryUncertain(
            itemID: item.id,
            attemptID: attempt.id,
            reason: .server(status: 503)
        )
        let proven = context.handle(epoch: 300, clientRequestID: attempt.clientRequestID)

        try reducer.confirmUncertainAdmission(
            itemID: item.id,
            attemptID: attempt.id,
            handle: proven
        )

        guard case let .admitted(retained, handle) = reducer.snapshot.items[0].state else {
            Issue.record("Expected exact uncertain proof to admit the retained attempt")
            return
        }
        #expect(retained == attempt)
        #expect(handle == proven)
    }

    @Test func reservedPreflightBlockIsAtomicAndCannotBeReservedAgain() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let attemptValue = try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)

        try reducer.blockReserved(
            itemID: item.id,
            attemptID: attempt.id,
            reason: .targetChanged
        )

        #expect(reducer.snapshot.items.first?.state == .blocked(.targetChanged))
        #expect(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "must-not-reserve")
        ) == nil)
    }

    @Test func durableAdmissionProofKeepsLaneOccupiedWithoutSyntheticHandle() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2)
        var reducer = try context.reducer(items: [first, second])
        let attemptValue = try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)

        try reducer.confirmDurableAdmission(itemID: first.id, attemptID: attempt.id)

        #expect(reducer.snapshot.items.first?.state == .committed(attempt))
        #expect(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "follower-must-wait")
        ) == nil)
    }

    @Test func joblessCompletionDeliversHeadButBlocksFollowersWithoutInventingEpoch() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2, text: "Follower")
        var reducer = try context.reducer(items: [first, second])
        let attempt = try #require(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        ))
        try reducer.confirmDurableAdmission(itemID: first.id, attemptID: attempt.id)

        let responseID = MessageID(rawValue: "jobless-response")
        try reducer.confirmJoblessCompletion(
            itemID: first.id,
            attemptID: attempt.id,
            responseMessageID: responseID
        )

        #expect(
            reducer.snapshot.items[0].state
                == .deliveredWithoutEpoch(attempt: attempt, responseMessageID: responseID)
        )
        #expect(reducer.snapshot.items[1].state == .blocked(.predecessorUnverified))
        #expect(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "must-not-send")
        ) == nil)
    }

    @Test func crashRestoredAdmittedItemCanCloseOnlyWithJoblessHistoryProof() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2, text: "Follower")
        var reducer = try context.reducer(items: [first, second])
        let attempt = try #require(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        ))
        let admitted = context.handle(
            epoch: 200,
            clientRequestID: attempt.clientRequestID
        )
        try reducer.markAdmitted(
            itemID: first.id,
            attemptID: attempt.id,
            handle: admitted
        )

        let responseID = MessageID(rawValue: "jobless-restored-response")
        try reducer.confirmJoblessCompletion(
            itemID: first.id,
            attemptID: attempt.id,
            responseMessageID: responseID
        )

        #expect(
            reducer.snapshot.items[0].state
                == .deliveredWithoutEpoch(attempt: attempt, responseMessageID: responseID)
        )
        #expect(reducer.snapshot.items[1].state == .blocked(.predecessorUnverified))
    }

    @Test func joblessCompletionRejectsUnknownOrLocalResponseIdentity() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        var reducer = try context.reducer(items: [first])
        let attempt = try #require(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        ))

        #expect(throws: FollowUpQueueError.self) {
            try reducer.confirmJoblessCompletion(
                itemID: first.id,
                attemptID: UUID(),
                responseMessageID: MessageID(rawValue: "jobless-response")
            )
        }
        #expect(throws: FollowUpQueueError.self) {
            try reducer.confirmJoblessCompletion(
                itemID: first.id,
                attemptID: attempt.id,
                responseMessageID: MessageID(rawValue: "local-assistant-response")
            )
        }
    }

    @Test func exactStatusProofPromotesEveryOutstandingJournalStateWithoutChangingAttempt() throws {
        let context = try Context()

        for state in [LockedState.reserved, .deliveryUncertain, .committed] {
            let first = try context.item(order: 1)
            let second = try context.item(order: 2, text: "Follower")
            var reducer = try context.reducer(items: [first, second])
            let attempt = try #require(try reducer.reserveNext(
                after: .completed(
                    handle: context.sourceHandle,
                    responseMessageID: context.responseMessageID
                ),
                attemptID: context.attemptID,
                clientRequestID: context.clientRequestID,
                clientMessageID: context.clientMessageID
            ))
            if state == .deliveryUncertain {
                try reducer.markDeliveryUncertain(
                    itemID: first.id,
                    attemptID: attempt.id,
                    reason: .transport
                )
            } else if state == .committed {
                try reducer.confirmDurableAdmission(
                    itemID: first.id,
                    attemptID: attempt.id
                )
            }
            let proven = context.handle(
                epoch: 300,
                clientRequestID: attempt.clientRequestID,
                streamID: "conversation"
            )

            try reducer.confirmOutstandingAdmission(
                itemID: first.id,
                attemptID: attempt.id,
                handle: proven
            )

            guard case let .admitted(retained, handle) = reducer.snapshot.items[0].state else {
                Issue.record("Expected exact status proof to promote the outstanding admission")
                continue
            }
            #expect(retained == attempt)
            #expect(handle == proven)
            #expect(reducer.snapshot.items[1].sourceAnchor.handle == proven)
            #expect(
                reducer.snapshot.items[1].sourceAnchor.sourceUserMessageID
                    == attempt.clientMessageID
            )
        }
    }

    @Test func retainedTerminalProofAtomicallyDeliversAndReleasesOnlyCompletedFollower() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2, text: "Follower")
        var reducer = try context.reducer(items: [first, second])
        let attempt = try #require(try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        ))
        try reducer.markDeliveryUncertain(
            itemID: first.id,
            attemptID: attempt.id,
            reason: .invalidAcknowledgement
        )
        let proven = context.handle(
            epoch: 300,
            clientRequestID: attempt.clientRequestID,
            streamID: "conversation"
        )
        let response = MessageID(rawValue: "assistant-300")

        try reducer.confirmOutstandingTerminal(
            itemID: first.id,
            attemptID: attempt.id,
            handle: proven,
            terminal: .completed(responseMessageID: response)
        )

        #expect(
            reducer.snapshot.items[0].state
                == .delivered(
                    attempt: attempt,
                    handle: proven,
                    terminal: .completed(responseMessageID: response)
                )
        )
        #expect(reducer.snapshot.items[1].sourceAnchor.handle == proven)
        let next = try reducer.reserveNext(
            after: .completed(handle: proven, responseMessageID: response),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "next-user")
        )
        #expect(next?.fingerprint.itemID == second.id)
        #expect(next?.fingerprint.parentMessageID == response)
    }

    @Test func recoverableSteerRequiresExactServerDerivedClientMessageIdentity() throws {
        let context = try Context()
        let recovery = try FollowUpRecoverableSource(
            handle: context.sourceHandle,
            identity: RecoverableSteerIdentity(
                id: "server-steer-1",
                clientSteerID: "client-steer-1"
            )
        )
        let item = try context.item(order: 1, recoverableSource: recovery)
        var reducer = try context.reducer(items: [item])

        #expect(throws: FollowUpQueueError.recoverableClientMessageMismatch) {
            try reducer.reserveNext(
                after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
                attemptID: context.attemptID,
                clientRequestID: context.clientRequestID,
                clientMessageID: MessageID(rawValue: "unrelated-client-message")
            )
        }
        #expect(reducer.snapshot.items.first?.state == .queued)

        let attempt = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: MessageID(rawValue: recovery.identity.id)
        )
        #expect(attempt?.clientMessageID.rawValue == recovery.identity.id)
        #expect(attempt?.fingerprint.recoverableSource == recovery)
    }

    @Test func admissionMessageIdentityCannotCollideWithExistingGraphCoordinates() throws {
        let context = try Context()

        for collision in [
            context.sourceAnchor.sourceUserMessageID,
            context.responseMessageID
        ] {
            var reducer = try context.reducer(items: [context.item(order: 1)])
            #expect(throws: FollowUpQueueError.messageIdentityCollision) {
                try reducer.reserveNext(
                    after: .completed(
                        handle: context.sourceHandle,
                        responseMessageID: context.responseMessageID
                    ),
                    attemptID: context.attemptID,
                    clientRequestID: context.clientRequestID,
                    clientMessageID: collision
                )
            }
            #expect(reducer.snapshot.items.first?.state == .queued)
        }
    }

    @Test func recoverableSourceIsBlockedInsteadOfRetargetedAcrossHandoff() throws {
        let context = try Context()
        let recovery = try FollowUpRecoverableSource(
            handle: context.sourceHandle,
            identity: RecoverableSteerIdentity(
                id: "server-steer-1",
                clientSteerID: "client-steer-1"
            )
        )
        let recovered = try context.item(order: 1, recoverableSource: recovery)
        let ordinary = try context.item(order: 2, text: "Ordinary follower")
        var reducer = try context.reducer(items: [recovered, ordinary])
        let attemptValue = try reducer.reserveNext(
            after: .completed(
                handle: context.sourceHandle,
                responseMessageID: context.responseMessageID
            ),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: MessageID(rawValue: recovery.identity.id)
        )
        let attempt = try #require(attemptValue)
        let winner = context.handle(
            epoch: 250,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000250")!,
            streamID: "winner"
        )

        try reducer.restoreReserved(
            itemID: recovered.id,
            attemptID: attempt.id,
            handoff: FollowUpHandoffRebase(
                winnerHandle: winner,
                winnerUserMessageID: MessageID(rawValue: "winner-user")
            )
        )

        #expect(reducer.snapshot.items[0].state == .blocked(.sourceUnavailable))
        #expect(reducer.snapshot.items[0].sourceAnchor == context.sourceAnchor)
        #expect(reducer.snapshot.items[1].state == .queued)
        #expect(reducer.snapshot.items[1].sourceAnchor.handle == winner)
        #expect(try reducer.reserveNext(
            after: .completed(
                handle: winner,
                responseMessageID: MessageID(rawValue: "winner-assistant")
            ),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "must-not-leapfrog")
        ) == nil)
    }

    @Test func blockedFIFOHeadPreventsLeapfroggingUntilExplicitlyUnblocked() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2)
        var reducer = try context.reducer(items: [first, second])

        try reducer.block(itemID: first.id, reason: .targetChanged)
        #expect(try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: UUID(),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: "second-must-not-leapfrog")
        ) == nil)

        try reducer.unblock(itemID: first.id)
        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)
        #expect(attempt.fingerprint.itemID == first.id)
    }

    @Test func invalidTransitionsAndAcknowledgementsLeaveSnapshotUnchanged() throws {
        let context = try Context()
        let item = try context.item(order: 1)
        var reducer = try context.reducer(items: [item])
        let initial = reducer.snapshot

        #expect(throws: FollowUpQueueError.invalidTransition) {
            try reducer.markAdmitted(
                itemID: item.id,
                attemptID: context.attemptID,
                handle: context.handle(epoch: 200, clientRequestID: context.clientRequestID)
            )
        }
        #expect(reducer.snapshot == initial)

        let attemptValue = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let attempt = try #require(attemptValue)
        let reserved = reducer.snapshot
        let wrongRequestHandle = context.handle(epoch: 200, clientRequestID: UUID())
        #expect(throws: FollowUpQueueError.invalidAcceptedHandle) {
            try reducer.markAdmitted(
                itemID: item.id,
                attemptID: attempt.id,
                handle: wrongRequestHandle
            )
        }
        #expect(reducer.snapshot == reserved)
        #expect(throws: FollowUpQueueError.invalidUncertainty) {
            try reducer.markDeliveryUncertain(
                itemID: item.id,
                attemptID: attempt.id,
                reason: .server(status: 409)
            )
        }
        #expect(reducer.snapshot == reserved)
    }

    @Test func concurrentCompletionTriggersReserveAtMostOneAttempt() async throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2)
        let coordinator = try FollowUpQueueCoordinator(namespace: context.namespace)
        try await coordinator.enqueue(first)
        try await coordinator.enqueue(second)
        let signal = FollowUpGenerationSignal.completed(
            handle: context.sourceHandle,
            responseMessageID: context.responseMessageID
        )

        let admittedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let result = try? await coordinator.reserveNext(
                        after: signal,
                        attemptID: UUID(),
                        clientRequestID: UUID(),
                        clientMessageID: MessageID(rawValue: "concurrent-client-\(index)")
                    )
                    return result != nil
                }
            }
            var count = 0
            for await admitted in group where admitted {
                count += 1
            }
            return count
        }

        #expect(admittedCount == 1)
        let snapshot = await coordinator.currentSnapshot()
        #expect(snapshot.items.filter(\.state.isReserved).count == 1)
        #expect(snapshot.items.filter { $0.state == .queued }.count == 1)
    }

    @Test func coordinatorSerializesQueuedMutationsAndReturnsCanonicalSnapshot() async throws {
        let context = try Context()
        let first = try context.item(order: 1, text: "First")
        let second = try context.item(order: 2, text: "Second")
        let coordinator = try FollowUpQueueCoordinator(namespace: context.namespace)
        try await coordinator.enqueue(first)
        try await coordinator.enqueue(second)

        try await coordinator.editQueued(itemID: first.id, text: "Edited")
        try await coordinator.reorderQueued(itemIDs: [second.id, first.id])
        try await coordinator.removeQueued(itemID: second.id)

        let snapshot = await coordinator.currentSnapshot()
        #expect(snapshot.items.map(\.id) == [first.id])
        #expect(snapshot.items.first?.text == "Edited")
        #expect(snapshot.items.first?.order == FollowUpQueueOrder(rawValue: 2))
    }

    @Test func snapshotCodableRoundTripsAndCorruptionFailsClosed() throws {
        let context = try Context()
        let first = try context.item(order: 1)
        let second = try context.item(order: 2)
        var reducer = try context.reducer(items: [first, second])
        _ = try reducer.reserveNext(
            after: .completed(handle: context.sourceHandle, responseMessageID: context.responseMessageID),
            attemptID: context.attemptID,
            clientRequestID: context.clientRequestID,
            clientMessageID: context.clientMessageID
        )
        let data = try JSONEncoder().encode(reducer.snapshot)
        #expect(try JSONDecoder().decode(FollowUpQueueSnapshot.self, from: data) == reducer.snapshot)

        var mismatched = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var mismatchedItems = try #require(mismatched["items"] as? [[String: Any]])
        mismatchedItems[0]["text"] = "tampered outside frozen fingerprint"
        mismatched["items"] = mismatchedItems
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                FollowUpQueueSnapshot.self,
                from: JSONSerialization.data(withJSONObject: mismatched)
            )
        }

        var duplicated = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var duplicatedItems = try #require(duplicated["items"] as? [[String: Any]])
        duplicatedItems.append(duplicatedItems[0])
        duplicated["items"] = duplicatedItems
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                FollowUpQueueSnapshot.self,
                from: JSONSerialization.data(withJSONObject: duplicated)
            )
        }

        var localNamespace = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var namespace = try #require(localNamespace["namespace"] as? [String: Any])
        namespace["conversationID"] = "local-new-corrupt"
        localNamespace["namespace"] = namespace
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                FollowUpQueueSnapshot.self,
                from: JSONSerialization.data(withJSONObject: localNamespace)
            )
        }
    }

    @Test func textTargetAndRecoveryValidationAreFailClosed() throws {
        let context = try Context()
        #expect(throws: FollowUpQueueError.invalidNamespace) {
            try FollowUpQueueNamespace(
                profileID: ServerProfileID(rawValue: "profile|account"),
                accountID: AccountID(rawValue: "conversation"),
                conversationID: ConversationID(rawValue: "safe")
            )
        }
        #expect(throws: FollowUpQueueError.invalidConversation) {
            try FollowUpQueueNamespace(
                profileID: ServerProfileID(rawValue: "profile"),
                accountID: AccountID(rawValue: "account"),
                conversationID: ConversationID(rawValue: "conversation|other")
            )
        }
        #expect(throws: FollowUpQueueError.invalidText) {
            try context.item(order: 1, text: "  padded  ")
        }
        #expect(throws: FollowUpQueueError.invalidText) {
            try context.item(order: 1, text: "has\0nul")
        }
        #expect(throws: FollowUpQueueError.textTooLong(maximumUTF16Length: 16_000)) {
            try context.item(order: 1, text: String(repeating: "a", count: 16_001))
        }
        #expect(throws: FollowUpQueueError.invalidTarget) {
            try FollowUpTargetFingerprint(endpoint: "   ")
        }
        #expect(throws: FollowUpQueueError.invalidRecoverableSource) {
            try FollowUpRecoverableSource(
                handle: context.sourceHandle,
                identity: RecoverableSteerIdentity(id: "server-only", clientSteerID: nil)
            )
        }
        let validColonSource = try FollowUpRecoverableSource(
            handle: context.sourceHandle,
            identity: RecoverableSteerIdentity(
                id: "server:steer_1-2",
                clientSteerID: "client_steer-1"
            )
        )
        #expect(validColonSource.identity.id == "server:steer_1-2")
        #expect(throws: FollowUpQueueError.invalidRecoverableSource) {
            try FollowUpRecoverableSource(
                handle: context.sourceHandle,
                identity: RecoverableSteerIdentity(
                    id: "server steer",
                    clientSteerID: "client_steer"
                )
            )
        }
        #expect(throws: FollowUpQueueError.invalidRecoverableSource) {
            try FollowUpRecoverableSource(
                handle: context.sourceHandle,
                identity: RecoverableSteerIdentity(
                    id: String(repeating: "s", count: 129),
                    clientSteerID: "client_steer"
                )
            )
        }
        #expect(throws: FollowUpQueueError.invalidRecoverableSource) {
            try FollowUpRecoverableSource(
                handle: context.sourceHandle,
                identity: RecoverableSteerIdentity(
                    id: "server:steer",
                    clientSteerID: "client:colon-not-allowed"
                )
            )
        }
    }
}

private extension FollowUpQueueContractTests {
    enum TerminalKind: String, CaseIterable {
        case aborted
        case failed
        case superseded

        func signal(handle: GenerationHandle) -> FollowUpGenerationSignal {
            switch self {
            case .aborted: .aborted(handle: handle)
            case .failed: .failed(handle: handle)
            case .superseded: .superseded(handle: handle)
            }
        }
    }

    enum LockedState: CaseIterable {
        case reserved
        case admitted
        case deliveryUncertain
        case committed
        case delivered
    }

    struct Context {
        let namespace: FollowUpQueueNamespace
        let sourceHandle: GenerationHandle
        let sourceAnchor: FollowUpSourceAnchor
        let target: FollowUpTargetFingerprint
        let responseMessageID = MessageID(rawValue: "assistant-100")
        let attemptID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let clientRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let clientMessageID = MessageID(rawValue: "queued-user-100")

        init() throws {
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
            sourceAnchor = try FollowUpSourceAnchor(
                handle: sourceHandle,
                sourceUserMessageID: MessageID(rawValue: "source-user")
            )
            target = try FollowUpTargetFingerprint(
                target: ConversationTarget(
                    endpoint: "agents",
                    model: "model-a",
                    agentID: "agent-a",
                    spec: "spec-a"
                )
            )
        }

        func handle(
            epoch: Int64,
            profileID: ServerProfileID? = nil,
            accountID: AccountID? = nil,
            conversationID: ConversationID? = nil,
            clientRequestID: UUID? = nil,
            streamID: String? = nil,
            protocolVersion: Int = 2
        ) -> GenerationHandle {
            GenerationHandle(
                profileID: profileID ?? namespace.profileID,
                accountID: accountID ?? namespace.accountID,
                clientRequestID: clientRequestID
                    ?? UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
                streamID: streamID ?? "conversation:\(epoch)",
                conversationID: conversationID ?? namespace.conversationID,
                generationCreatedAt: epoch,
                protocolVersion: protocolVersion
            )
        }

        func item(
            id: FollowUpQueueItemID? = nil,
            order: UInt64,
            text: String = "Queued follow-up",
            recoverableSource: FollowUpRecoverableSource? = nil
        ) throws -> FollowUpQueueItem {
            try FollowUpQueueItem(
                id: id ?? FollowUpQueueItemID(UUID(
                    uuid: (
                        0, 0, 0, 0,
                        0, 0,
                        0, 0,
                        0, 0,
                        0, 0, 0, 0, UInt8(order >> 8), UInt8(order & 0xFF)
                    )
                )),
                namespace: namespace,
                order: FollowUpQueueOrder(rawValue: order),
                text: text,
                target: target,
                sourceAnchor: sourceAnchor,
                recoverableSource: recoverableSource
            )
        }

        func reducer(items: [FollowUpQueueItem]) throws -> FollowUpQueueReducer {
            FollowUpQueueReducer(
                snapshot: try FollowUpQueueSnapshot(namespace: namespace, items: items)
            )
        }

        func reducer(lockedState: LockedState) throws -> FollowUpQueueReducer {
            let item = try self.item(order: 1)
            var reducer = try self.reducer(items: [item])
            let optionalAttempt = try reducer.reserveNext(
                after: .completed(handle: sourceHandle, responseMessageID: responseMessageID),
                attemptID: attemptID,
                clientRequestID: clientRequestID,
                clientMessageID: clientMessageID
            )
            let attempt = try #require(optionalAttempt)
            if lockedState == .reserved { return reducer }
            if lockedState == .deliveryUncertain {
                try reducer.markDeliveryUncertain(
                    itemID: item.id,
                    attemptID: attempt.id,
                    reason: .transport
                )
                return reducer
            }
            if lockedState == .committed {
                try reducer.confirmDurableAdmission(
                    itemID: item.id,
                    attemptID: attempt.id
                )
                return reducer
            }
            let accepted = handle(epoch: 200, clientRequestID: attempt.clientRequestID)
            try reducer.markAdmitted(itemID: item.id, attemptID: attempt.id, handle: accepted)
            if lockedState == .admitted { return reducer }
            _ = try reducer.observeAdmittedTerminal(
                itemID: item.id,
                attemptID: attempt.id,
                signal: .completed(
                    handle: accepted,
                    responseMessageID: MessageID(rawValue: "accepted-response")
                )
            )
            return reducer
        }
    }
}

private extension FollowUpQueueItemState {
    var isReserved: Bool {
        if case .reserved = self { return true }
        return false
    }

    var isAdmitted: Bool {
        if case .admitted = self { return true }
        return false
    }
}
