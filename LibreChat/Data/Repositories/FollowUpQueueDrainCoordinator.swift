import Foundation
import LibreChatDomain
import LibreChatProtocol

/// The deliberately small repository surface needed by the durable follow-up
/// drain.  Keeping this separate from `LibreChatRepository` makes the
/// admission coordinator testable and prevents it from acquiring unrelated
/// browsing or UI responsibilities.
protocol FollowUpDrainRepository: Sendable {
    func conversation(id: ConversationID) async throws -> Conversation
    func messages(conversationID: ConversationID) async throws -> [ChatMessage]
    func send(_ request: ChatRequest) async throws -> ChatSendOutcome
    func followUpAdmissionProof(
        for attempt: FollowUpAdmissionAttempt
    ) async throws -> FollowUpAdmissionProof?
    func acknowledgeRecoverableSteers(
        handle: GenerationHandle,
        identities: Set<RecoverableSteerIdentity>
    ) async throws -> RecoverableSteerBatch?
}

/// Chat-facing durable queue ownership. Presentation can read and mutate only
/// untouched local rows; admission itself remains inside the drain actor.
protocol ChatFollowUpRepository: FollowUpDrainRepository, RecoverableSteerRepository, RecoverableSteerDiscardRepository {
    func followUpQueue(conversationID: ConversationID) async throws -> FollowUpQueueSnapshot
    func enqueueFollowUp(_ item: FollowUpQueueItem) async throws -> FollowUpQueueSnapshot
    func editQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID,
        text: String
    ) async throws -> FollowUpQueueSnapshot
    func removeQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID
    ) async throws -> FollowUpQueueSnapshot
    func drainFollowUp(after signal: FollowUpGenerationSignal) async throws -> FollowUpDrainResult
}

/// A retained status row is useful only when its resume metadata proves the
/// exact queued user-message identity. Jobless or mismatched status is
/// represented by `nil` and never converted into a manufactured handle.
enum FollowUpAdmissionProof: Equatable, Sendable {
    case active(GenerationHandle)
    case terminal(handle: GenerationHandle, terminal: FollowUpDeliveredTerminal)
}

enum FollowUpDrainResult: Equatable, Sendable {
    case noWork
    case admitted(FollowUpQueueItemID, GenerationHandle)
    case committed(FollowUpQueueItemID)
    case deliveredWithoutEpoch(FollowUpQueueItemID, responseMessageID: MessageID)
    case delivered(FollowUpQueueItemID, FollowUpDeliveredTerminal)
    case deliveryUncertain(FollowUpQueueItemID, FollowUpDeliveryUncertaintyReason)
    case blocked(FollowUpQueueItemID, FollowUpQueueBlockReason)
    /// The POST or terminal acknowledgement crossed a side-effect boundary,
    /// but no exact durable user row proved ownership. The reservation is
    /// intentionally retained and must not be reposted automatically.
    case ambiguous(FollowUpQueueItemID)
}

enum FollowUpDrainError: Error, Equatable, Sendable {
    case unauthorized
    case preflightUnavailable
    case persistence
}

private struct FollowUpDrainPreparation: Sendable {
    struct ObservedTerminal: Sendable {
        let itemID: FollowUpQueueItemID
        let terminal: FollowUpDeliveredTerminal
        let recoverableSource: FollowUpRecoverableSource?
    }

    let attempt: FollowUpAdmissionAttempt?
    let observedTerminal: ObservedTerminal?
}

/// Drains exactly one text-only queued follow-up after a clean, authoritative
/// generation completion. Reservation is persisted before the POST. Every
/// non-streaming result is fail-closed so a crash or relaunch cannot turn an
/// ambiguous POST into a duplicate user message.
actor FollowUpQueueDrainCoordinator {
    private let cache: CacheCoordinator
    private let repository: any FollowUpDrainRepository
    private let namespace: FollowUpQueueNamespace

    init(
        cache: CacheCoordinator,
        repository: any FollowUpDrainRepository,
        namespace: FollowUpQueueNamespace
    ) {
        self.cache = cache
        self.repository = repository
        self.namespace = namespace
    }

    /// Records an exact admitted terminal and, only after a clean completion,
    /// reserves the next FIFO item in the same atomic cache mutation.
    func drain(after signal: FollowUpGenerationSignal) async throws -> FollowUpDrainResult {
        let handle = signal.handle
        guard handle.profileID == namespace.profileID,
              handle.accountID == namespace.accountID,
              handle.conversationID == namespace.conversationID,
              handle.protocolVersion == 2,
              handle.generationCreatedAt != nil
        else {
            return .noWork
        }

        let preparation: FollowUpDrainPreparation
        do {
            let result = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                var observedTerminal: FollowUpDrainPreparation.ObservedTerminal?
                if let admitted = reducer.snapshot.items.first(where: { item in
                    guard case let .admitted(_, admittedHandle) = item.state else { return false }
                    return admittedHandle == signal.handle
                }), case let .admitted(admittedAttempt, _) = admitted.state,
                   let terminal = signal.deliveredTerminal,
                   try reducer.observeAdmittedTerminal(
                       itemID: admitted.id,
                       attemptID: admittedAttempt.id,
                       signal: signal
                   ) {
                    observedTerminal = .init(
                        itemID: admitted.id,
                        terminal: terminal,
                        recoverableSource: admitted.recoverableSource
                    )
                }

                guard case .completed = signal else {
                    if observedTerminal != nil {
                        let followers = reducer.snapshot.items.filter { item in
                            guard case .queued = item.state else { return false }
                            return item.sourceAnchor.handle == signal.handle
                        }
                        for follower in followers {
                            try reducer.block(
                                itemID: follower.id,
                                reason: .requiresUserReview
                            )
                        }
                    }
                    return FollowUpDrainPreparation(
                        attempt: nil,
                        observedTerminal: observedTerminal
                    )
                }
                let clientMessageID = reducer.snapshot.items.first(where: { item in
                    if case .delivered = item.state { return false }
                    if case .deliveredWithoutEpoch = item.state { return false }
                    return true
                })?.recoverableSource.map {
                    MessageID(rawValue: $0.identity.id)
                } ?? MessageID(rawValue: UUID().uuidString)
                let attempt = try reducer.reserveNext(
                    after: signal,
                    attemptID: UUID(),
                    clientRequestID: UUID(),
                    clientMessageID: clientMessageID
                )
                return FollowUpDrainPreparation(
                    attempt: attempt,
                    observedTerminal: observedTerminal
                )
            }
            preparation = result.result
        } catch {
            throw FollowUpDrainError.persistence
        }

        if let recovery = preparation.observedTerminal?.recoverableSource {
            // Exact admitted terminal proof is also durable user-row proof for
            // the recovered start. Local acknowledgement is cleanup only and
            // must never reopen or repost the already-delivered queue item.
            _ = try? await repository.acknowledgeRecoverableSteers(
                handle: recovery.handle,
                identities: Set([recovery.identity])
            )
        }

        guard let attempt = preparation.attempt else {
            if let observed = preparation.observedTerminal {
                return .delivered(observed.itemID, observed.terminal)
            }
            return .noWork
        }
        let itemID = attempt.fingerprint.itemID

        let conversation: Conversation
        let history: [ChatMessage]
        do {
            async let authoritativeConversation = repository.conversation(id: namespace.conversationID)
            async let authoritativeHistory = repository.messages(conversationID: namespace.conversationID)
            conversation = try await authoritativeConversation
            history = try await authoritativeHistory
        } catch LibreChatProtocolError.unauthorized {
            // Both operations above are read-only and the generation POST has
            // not been reached. Restore the same queue slot before app-level
            // auth handling hides the namespace. A failed restoration remains
            // safely reserved and still cannot repost.
            _ = try? await restoreDefinitePreflightNonAdmission(
                itemID: itemID,
                attemptID: attempt.id
            )
            throw FollowUpDrainError.unauthorized
        } catch {
            // The failure occurred before any mutation request. Restore the
            // original queue slot so the user can remove it or explicitly
            // retry against the same exact completed predecessor later.
            do {
                try await restoreDefinitePreflightNonAdmission(
                    itemID: itemID,
                    attemptID: attempt.id
                )
            } catch {
                throw FollowUpDrainError.persistence
            }
            throw FollowUpDrainError.preflightUnavailable
        }

        guard conversation.id == namespace.conversationID,
              let currentTarget = conversation.target,
              let currentFingerprint = try? FollowUpTargetFingerprint(target: currentTarget),
              currentFingerprint == attempt.fingerprint.target
        else {
            return try await block(
                itemID: itemID,
                attemptID: attempt.id,
                reason: .targetChanged
            )
        }

        let tree = MessageTree(messages: history)
        guard tree.isStructurallyValid,
              let responseMessageID = signal.responseMessageID,
              let source = exactMessage(
                id: attempt.fingerprint.sourceAnchor.sourceUserMessageID,
                in: history,
                conversationID: namespace.conversationID
              ),
              source.author == .user,
              let response = exactMessage(
                id: responseMessageID,
                in: history,
                conversationID: namespace.conversationID
              ),
              isCleanCompletedResponse(response, parent: source.id)
        else {
            return try await block(
                itemID: itemID,
                attemptID: attempt.id,
                reason: .sourceUnavailable
            )
        }

        let request = ChatRequest(
            profileID: namespace.profileID,
            accountID: namespace.accountID,
            conversation: conversation,
            parentMessageID: attempt.fingerprint.parentMessageID,
            text: attempt.fingerprint.text,
            attachments: attempt.fingerprint.attachments.map(\.file),
            expectedPredecessorCreatedAt: attempt.fingerprint.sourceAnchor.handle.generationCreatedAt,
            recoverySteerID: attempt.fingerprint.recoverableSource?.identity.id,
            clientRequestID: attempt.clientRequestID,
            clientMessageID: attempt.clientMessageID,
            action: .send
        )

        do {
            let outcome = try await repository.send(request)
            switch outcome {
            case let .streaming(handle):
                do {
                    _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                        try reducer.markAdmitted(
                            itemID: itemID,
                            attemptID: attempt.id,
                            handle: handle
                        )
                    }
                    return .admitted(itemID, handle)
                } catch {
                    // The server accepted the request, but local admission
                    // journaling failed. Never repost.
                    return .ambiguous(itemID)
                }

            case .handoff:
                // This request lost admission to a different generation. The
                // current receipt contains no exact winner user-message
                // coordinate, so the queued text cannot be rebased safely.
                return try await block(
                    itemID: itemID,
                    attemptID: attempt.id,
                    reason: .requiresUserReview
                )

            case .settled, .aborted, .failed:
                return try await handleTerminalOutcome(
                    itemID: itemID,
                    attempt: attempt,
                    request: request,
                    outcome: outcome
                )
            }
        } catch LibreChatProtocolError.unauthorized {
            throw FollowUpDrainError.unauthorized
        } catch let error as LibreChatProtocolError {
            return try await classify(error, itemID: itemID, attemptID: attempt.id)
        } catch {
            return try await uncertain(
                itemID: itemID,
                attemptID: attempt.id,
                reason: .transport
            )
        }
    }

    /// Reconciles one crash-restored reservation/uncertain/committed attempt
    /// without resending it. Exact v2 status metadata can promote the retained
    /// request to its real generation handle; terminal promotion additionally
    /// requires authoritative durable message rows.
    func reconcileOutstandingAdmission() async throws -> FollowUpDrainResult {
        let snapshot: FollowUpQueueSnapshot
        do {
            snapshot = try await cache.followUpQueue(namespace: namespace)
        } catch {
            throw FollowUpDrainError.persistence
        }
        guard let item = snapshot.items.first(where: { item in
            switch item.state {
            case .reserved, .deliveryUncertain, .committed, .admitted:
                true
            case .queued, .blocked, .deliveredWithoutEpoch, .delivered:
                false
            }
        }) else {
            return .noWork
        }
        let attempt: FollowUpAdmissionAttempt
        let admittedHandle: GenerationHandle?
        switch item.state {
        case let .reserved(value),
             let .deliveryUncertain(value, _),
             let .committed(value):
            attempt = value
            admittedHandle = nil
        case let .admitted(value, handle):
            attempt = value
            admittedHandle = handle
        default:
            return .noWork
        }

        let proof: FollowUpAdmissionProof?
        do {
            proof = try await repository.followUpAdmissionProof(for: attempt)
        } catch LibreChatProtocolError.unauthorized {
            throw FollowUpDrainError.unauthorized
        } catch {
            throw FollowUpDrainError.preflightUnavailable
        }

        switch proof {
        case let .active(handle):
            if let admittedHandle {
                guard admittedHandle == handle else { return .ambiguous(item.id) }
                return .admitted(item.id, handle)
            }
            do {
                _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                    try reducer.confirmOutstandingAdmission(
                        itemID: item.id,
                        attemptID: attempt.id,
                        handle: handle
                    )
                }
                return .admitted(item.id, handle)
            } catch {
                return .ambiguous(item.id)
            }

        case let .terminal(handle, terminal):
            if let admittedHandle, admittedHandle != handle {
                return .ambiguous(item.id)
            }
            let history = try await authoritativeHistoryForReconciliation()
            guard hasExactDurableUserRow(
                id: attempt.clientMessageID,
                parent: attempt.fingerprint.parentMessageID,
                text: attempt.fingerprint.text,
                attachments: attempt.fingerprint.attachments,
                in: history
            ) else {
                return .ambiguous(item.id)
            }
            guard terminalIsProven(terminal, attempt: attempt, history: history) else {
                return try await commitDurableRowIfPresent(
                    item: item,
                    attempt: attempt,
                    history: history,
                    allowJoblessCompletion: false
                )
            }
            do {
                _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                    if admittedHandle != nil {
                        _ = try reducer.observeAdmittedTerminal(
                            itemID: item.id,
                            attemptID: attempt.id,
                            signal: terminal.generationSignal(handle: handle)
                        )
                    } else {
                        try reducer.confirmOutstandingTerminal(
                            itemID: item.id,
                            attemptID: attempt.id,
                            handle: handle,
                            terminal: terminal
                        )
                    }
                }
            } catch {
                return .ambiguous(item.id)
            }
            await acknowledgeRecoveryIfCommitted(attempt)
            return .delivered(item.id, terminal)

        case nil:
            let history = try await authoritativeHistoryForReconciliation()
            return try await commitDurableRowIfPresent(
                item: item,
                attempt: attempt,
                history: history
            )
        }
    }

    private func handleTerminalOutcome(
        itemID: FollowUpQueueItemID,
        attempt: FollowUpAdmissionAttempt,
        request: ChatRequest,
        outcome: ChatSendOutcome
    ) async throws -> FollowUpDrainResult {
        guard outcome.conversationID == namespace.conversationID else {
            return .ambiguous(itemID)
        }
        do {
            let history = try await repository.messages(conversationID: namespace.conversationID)
            guard MessageTree(messages: history).isStructurallyValid,
                  hasExactDurableUserRow(
                id: attempt.clientMessageID,
                parent: request.parentMessageID,
                text: request.text,
                attachments: attempt.fingerprint.attachments,
                in: history
            ) else {
                return .ambiguous(itemID)
            }
        } catch LibreChatProtocolError.unauthorized {
            throw FollowUpDrainError.unauthorized
        } catch {
            return .ambiguous(itemID)
        }

        do {
            _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                try reducer.confirmDurableAdmission(
                    itemID: itemID,
                    attemptID: attempt.id
                )
            }
        } catch {
            return .ambiguous(itemID)
        }

        if let recovery = attempt.fingerprint.recoverableSource {
            // Durable user-row proof is the server's commit boundary for a
            // recovered steer. Local acknowledgement is cleanup only; a
            // failure never reopens or reposts the committed queue item.
            _ = try? await repository.acknowledgeRecoverableSteers(
                handle: recovery.handle,
                identities: Set([recovery.identity])
            )
        }
        return .committed(itemID)
    }

    private func authoritativeHistoryForReconciliation() async throws -> [ChatMessage] {
        do {
            let history = try await repository.messages(conversationID: namespace.conversationID)
            guard MessageTree(messages: history).isStructurallyValid else {
                throw FollowUpDrainError.preflightUnavailable
            }
            return history
        } catch LibreChatProtocolError.unauthorized {
            throw FollowUpDrainError.unauthorized
        } catch let error as FollowUpDrainError {
            throw error
        } catch {
            throw FollowUpDrainError.preflightUnavailable
        }
    }

    private func commitDurableRowIfPresent(
        item: FollowUpQueueItem,
        attempt: FollowUpAdmissionAttempt,
        history: [ChatMessage],
        allowJoblessCompletion: Bool = true
    ) async throws -> FollowUpDrainResult {
        guard hasExactDurableUserRow(
            id: attempt.clientMessageID,
            parent: attempt.fingerprint.parentMessageID,
            text: attempt.fingerprint.text,
            attachments: attempt.fingerprint.attachments,
            in: history
        ) else {
            return .ambiguous(item.id)
        }
        if allowJoblessCompletion,
           let responseMessageID = exactCleanResponseMessageID(
            parent: attempt.clientMessageID,
            in: history
        ) {
            do {
                _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                    try reducer.confirmJoblessCompletion(
                        itemID: item.id,
                        attemptID: attempt.id,
                        responseMessageID: responseMessageID
                    )
                }
            } catch {
                return .ambiguous(item.id)
            }
            await acknowledgeRecoveryIfCommitted(attempt)
            return .deliveredWithoutEpoch(item.id, responseMessageID: responseMessageID)
        }
        if case .committed = item.state {
            await acknowledgeRecoveryIfCommitted(attempt)
            return .committed(item.id)
        }
        if case .admitted = item.state {
            // A retained local handle with no matching server epoch or clean
            // terminal proof remains locked for review. Downgrading it to a
            // jobless commit would erase coordinates needed for later proof.
            return .ambiguous(item.id)
        }
        do {
            _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                try reducer.confirmDurableAdmission(
                    itemID: item.id,
                    attemptID: attempt.id
                )
            }
        } catch {
            return .ambiguous(item.id)
        }
        await acknowledgeRecoveryIfCommitted(attempt)
        return .committed(item.id)
    }

    private func acknowledgeRecoveryIfCommitted(_ attempt: FollowUpAdmissionAttempt) async {
        guard let recovery = attempt.fingerprint.recoverableSource else { return }
        _ = try? await repository.acknowledgeRecoverableSteers(
            handle: recovery.handle,
            identities: Set([recovery.identity])
        )
    }

    private func terminalIsProven(
        _ terminal: FollowUpDeliveredTerminal,
        attempt: FollowUpAdmissionAttempt,
        history: [ChatMessage]
    ) -> Bool {
        switch terminal {
        case let .completed(responseMessageID):
            guard let response = exactMessage(
                id: responseMessageID,
                in: history,
                conversationID: namespace.conversationID
            ) else { return false }
            return isCleanCompletedResponse(response, parent: attempt.clientMessageID)
        case .aborted, .failed, .superseded:
            return true
        }
    }

    private func classify(
        _ error: LibreChatProtocolError,
        itemID: FollowUpQueueItemID,
        attemptID: UUID
    ) async throws -> FollowUpDrainResult {
        switch error {
        case .unauthorized:
            throw FollowUpDrainError.unauthorized
        case let .httpStatus(status, _, _):
            guard !(200...299).contains(status) else {
                return try await uncertain(
                    itemID: itemID,
                    attemptID: attemptID,
                    reason: .invalidAcknowledgement
                )
            }
            if status == 429 {
                return try await block(
                    itemID: itemID,
                    attemptID: attemptID,
                    reason: .requiresUserReview
                )
            }
            if status == 409 {
                return try await block(
                    itemID: itemID,
                    attemptID: attemptID,
                    reason: .requiresUserReview
                )
            }
            if (400...499).contains(status) {
                return try await block(
                    itemID: itemID,
                    attemptID: attemptID,
                    reason: .requiresUserReview
                )
            }
            if (500...599).contains(status) {
                return try await uncertain(
                    itemID: itemID,
                    attemptID: attemptID,
                    reason: .server(status: status)
                )
            }
            return try await uncertain(
                itemID: itemID,
                attemptID: attemptID,
                reason: .invalidAcknowledgement
            )
        case .serverNotReady:
            return try await uncertain(itemID: itemID, attemptID: attemptID, reason: .transport)
        case .generationConflict:
            return try await block(
                itemID: itemID,
                attemptID: attemptID,
                reason: .requiresUserReview
            )
        case .invalidResponse, .decoding, .responseTooLarge:
            return try await uncertain(itemID: itemID, attemptID: attemptID, reason: .invalidAcknowledgement)
        case .transport, .encoding, .unsupported, .keychain:
            return try await uncertain(itemID: itemID, attemptID: attemptID, reason: .transport)
        }
    }

    private func uncertain(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        reason: FollowUpDeliveryUncertaintyReason
    ) async throws -> FollowUpDrainResult {
        do {
            _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                try reducer.markDeliveryUncertain(itemID: itemID, attemptID: attemptID, reason: reason)
            }
            return .deliveryUncertain(itemID, reason)
        } catch {
            return .ambiguous(itemID)
        }
    }

    private func block(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        reason: FollowUpQueueBlockReason
    ) async throws -> FollowUpDrainResult {
        do {
            _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
                try reducer.blockReserved(
                    itemID: itemID,
                    attemptID: attemptID,
                    reason: reason
                )
            }
            return .blocked(itemID, reason)
        } catch {
            return .ambiguous(itemID)
        }
    }

    private func restoreDefinitePreflightNonAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID
    ) async throws {
        _ = try await cache.mutateFollowUpQueue(namespace: namespace) { reducer in
            try reducer.restoreReserved(
                itemID: itemID,
                attemptID: attemptID
            )
        }
    }

    private func exactMessage(
        id: MessageID,
        in history: [ChatMessage],
        conversationID: ConversationID
    ) -> ChatMessage? {
        let matches = history.filter { $0.id == id && $0.conversationID == conversationID }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isCleanCompletedResponse(_ message: ChatMessage, parent: MessageID) -> Bool {
        guard message.author.isAssistant,
              message.parentMessageID == parent,
              message.isUnfinished != true,
              !message.content.contains(where: { content in
                  if case .error = content { return true }
                  return false
              })
        else { return false }

        if let finishReason = message.finishReason?.lowercased(),
           ["error", "failed", "aborted", "cancelled", "canceled"].contains(finishReason) {
            return false
        }
        return true
    }

    private func hasExactDurableUserRow(
        id: MessageID,
        parent: MessageID?,
        text: String,
        attachments: [FollowUpQueuedAttachment],
        in history: [ChatMessage]
    ) -> Bool {
        let expectedFileIDs = attachments.map { $0.file.id }
        return history.filter { message in
            guard message.id == id
                && message.author == .user
                && message.parentMessageID == parent
                && message.rawPlainText == text
                && message.isUnfinished != true
            else { return false }
            var observedFileIDs: [String] = []
            for content in message.content {
                switch content {
                case .text:
                    continue
                case let .file(file):
                    observedFileIDs.append(file.id)
                default:
                    return false
                }
            }
            return observedFileIDs.count == expectedFileIDs.count
                && Set(observedFileIDs).count == observedFileIDs.count
                && Set(observedFileIDs) == Set(expectedFileIDs)
        }.count == 1
    }

    private func exactCleanResponseMessageID(
        parent: MessageID,
        in history: [ChatMessage]
    ) -> MessageID? {
        let matches = history.filter { message in
            message.conversationID == namespace.conversationID
                && isCleanCompletedResponse(message, parent: parent)
        }
        guard matches.count == 1 else { return nil }
        return matches[0].id
    }
}

private extension MessageAuthor {
    var isAssistant: Bool {
        if case .assistant = self { return true }
        return false
    }
}

private extension FollowUpGenerationSignal {
    var deliveredTerminal: FollowUpDeliveredTerminal? {
        switch self {
        case let .completed(_, responseMessageID):
            .completed(responseMessageID: responseMessageID)
        case .aborted:
            .aborted
        case .failed:
            .failed
        case .superseded:
            .superseded
        case .awaitingInteraction, .ambiguous:
            nil
        }
    }

    var responseMessageID: MessageID? {
        guard case let .completed(_, responseMessageID) = self else { return nil }
        return responseMessageID
    }
}

private extension FollowUpDeliveredTerminal {
    func generationSignal(handle: GenerationHandle) -> FollowUpGenerationSignal {
        switch self {
        case let .completed(responseMessageID):
            .completed(handle: handle, responseMessageID: responseMessageID)
        case .aborted:
            .aborted(handle: handle)
        case .failed:
            .failed(handle: handle)
        case .superseded:
            .superseded(handle: handle)
        }
    }
}
