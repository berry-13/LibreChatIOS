import Foundation
import LibreChatDomain

public struct GenerationReducer: Sendable {
    public private(set) var snapshot: GenerationSnapshot
    private var seenEventIDs: Set<String> = []

    public init(handle: GenerationHandle, snapshot: GenerationSnapshot? = nil) {
        self.snapshot = snapshot ?? GenerationSnapshot(handle: handle)
    }

    @discardableResult
    public mutating func apply(_ envelope: SequencedGenerationEvent, at date: Date = Date()) -> GenerationSnapshot {
        if let id = envelope.id {
            guard seenEventIDs.insert(id).inserted else { return snapshot }
            snapshot.lastEventID = id
        }

        switch envelope.event {
        case let .created(message):
            if let message, message.author != .user { snapshot.response = message }
            snapshot.state = .streaming

        case let .textDelta(delta):
            ensureResponse()
            append(delta, kind: .text)
            snapshot.state = .streaming

        case let .reasoningDelta(delta):
            snapshot.reasoning += delta
            snapshot.state = .streaming

        case let .replaceContent(content):
            ensureResponse()
            snapshot.response?.content = content
            snapshot.state = .streaming

        case let .runStep(step):
            upsert(step, in: &snapshot.runSteps)

        case let .toolCall(call):
            upsert(call, in: &snapshot.toolCalls)

        case let .activity(activity):
            upsertActivity(activity)

        case let .attachment(content):
            ensureResponse()
            if case let .generatedFile(incoming) = content {
                guard var response = snapshot.response else { break }
                var generated = GeneratedFileReducer(files: response.content.compactMap { content in
                    guard case let .generatedFile(file) = content else { return nil }
                    return file
                })
                _ = generated.upsert(incoming)
                response.content.removeAll { content in
                    if case .generatedFile = content { return true }
                    return false
                }
                response.content.append(contentsOf: generated.files.map(MessageContent.generatedFile))
                snapshot.response = response
            } else if snapshot.response?.content.contains(content) == false {
                snapshot.response?.content.append(content)
            }

        case let .citationAttachment(attachment):
            ensureResponse()
            guard var response = snapshot.response else { break }
            var attachments = CitationAttachmentReducer(attachments: response.citationAttachments)
            response.citationAttachments = attachments.upsert(attachment)
            snapshot.response = response

        case let .title(title):
            snapshot.title = title

        case let .pendingInteraction(interaction):
            snapshot.pendingInteraction = interaction
            snapshot.state = .awaitingApproval(interaction)

        case let .usage(usage):
            snapshot.usage = usage

        case let .contextUsage(usage):
            snapshot.contextUsage = usage

        case let .steer(steer):
            upsert(steer, in: &snapshot.appliedSteers)
            Self.removeMatching(steer, from: &snapshot.pendingSteers)
            // An applied event/content part wins a race with terminal recovery.
            // Do not leave a second copy eligible for a later follow-up send.
            Self.removeMatching(steer, from: &snapshot.recoverableSteers)

        case let .pendingSteerUpdate(update):
            apply(update)

        case let .recoverableSteers(steers):
            snapshot.recoverableSteers = []
            for steer in steers where !matchesApplied(steer) {
                Self.removeMatching(steer, from: &snapshot.pendingSteers)
                Self.upsertRecoverable(steer, in: &snapshot.recoverableSteers)
            }

        case let .synchronization(sync):
            ensureResponse()
            snapshot.response?.content = sync.aggregatedContent
            snapshot.runSteps = sync.runSteps
            snapshot.toolCalls = sync.toolCalls
            snapshot.activities = sync.activities
            snapshot.pendingInteraction = sync.pendingInteraction
            snapshot.usage = sync.usage
            snapshot.contextUsage = sync.contextUsage
            snapshot.appliedSteers = sync.appliedSteers
            snapshot.pendingSteers = sync.pendingSteers.filter { pending in
                !sync.appliedSteers.contains(where: { Self.identitiesOverlap(pending, $0) })
            }
            for applied in sync.appliedSteers {
                Self.removeMatching(applied, from: &snapshot.recoverableSteers)
            }
            for steer in sync.recoverableSteers where !matchesApplied(steer) {
                Self.removeMatching(steer, from: &snapshot.pendingSteers)
                Self.upsertRecoverable(steer, in: &snapshot.recoverableSteers)
            }
            snapshot.title = sync.title
            if sync.isComplete {
                snapshot.pendingInteraction = nil
                snapshot.state = .completed
            } else if let interaction = sync.pendingInteraction {
                snapshot.state = .awaitingApproval(interaction)
            } else {
                snapshot.state = .streaming
            }

        case let .lifecycle(lifecycle):
            switch lifecycle {
            case .resumed:
                snapshot.pendingInteraction = nil
                snapshot.state = .streaming
            case .replaced:
                snapshot.pendingInteraction = nil
                snapshot.state = .superseded
            case .settled:
                snapshot.pendingInteraction = nil
                snapshot.state = .completed
            case .predecessorMismatch:
                snapshot.state = .reconciling
            }

        case let .reconnecting(attempt):
            snapshot.state = .reconnecting(attempt: attempt)

        case .stopRequested:
            snapshot.stopRequestedAt = date
            snapshot.state = .stopping

        case let .terminal(terminal):
            snapshot.pendingInteraction = nil
            switch terminal {
            case .completed:
                snapshot.state = .completed
            case .unfinished:
                snapshot.state = snapshot.stopRequestedAt == nil ? .reconciling : .aborted
            case .reconciliationRequired:
                snapshot.state = .reconciling
            }

        case .completed:
            snapshot.pendingInteraction = nil
            snapshot.state = .completed

        case .aborted:
            snapshot.pendingInteraction = nil
            snapshot.state = .aborted

        case let .failed(failure):
            snapshot.pendingInteraction = nil
            snapshot.state = .failed(failure)

        case .unsupported:
            break
        }
        snapshot.updatedAt = date
        return snapshot
    }

    private enum AppendedKind { case text }

    private mutating func ensureResponse() {
        guard snapshot.response == nil else { return }
        snapshot.response = ChatMessage(
            id: MessageID(rawValue: "stream-\(snapshot.handle.streamID)"),
            conversationID: snapshot.handle.conversationID,
            content: [.text("")],
            author: .assistant(name: "Assistant")
        )
    }

    private mutating func append(_ delta: String, kind: AppendedKind) {
        guard var response = snapshot.response else { return }
        switch kind {
        case .text:
            if let index = response.content.indices.last,
               case let .text(existing) = response.content[index] {
                response.content[index] = .text(existing + delta)
            } else {
                response.content.append(.text(delta))
            }
        }
        snapshot.response = response
    }

    private func upsert<Element: Identifiable & Equatable>(_ element: Element, in collection: inout [Element])
    where Element.ID: Equatable {
        if let index = collection.firstIndex(where: { $0.id == element.id }) {
            collection[index] = element
        } else {
            collection.append(element)
        }
    }

    /// Child-agent envelopes describe one logical run across many phases.
    /// Merge their privacy-bounded semantic fields instead of replacing the
    /// entire row on every delta. Generic activities retain normal last-write
    /// replacement semantics.
    private mutating func upsertActivity(_ activity: MessageActivityContent) {
        guard let index = snapshot.activities.firstIndex(where: { $0.id == activity.id }) else {
            snapshot.activities.append(activity)
            return
        }
        guard var incoming = activity.subagent,
              let previous = snapshot.activities[index].subagent else {
            snapshot.activities[index] = activity
            return
        }

        var seen = Set(previous.toolNames)
        incoming.toolNames = previous.toolNames + incoming.toolNames.filter { seen.insert($0).inserted }
        incoming.hasProducedText = previous.hasProducedText || incoming.hasProducedText
        incoming.hasProducedReasoning = previous.hasProducedReasoning || incoming.hasProducedReasoning
        if incoming.typeLabel == nil {
            incoming.typeLabel = previous.typeLabel
        }

        var merged = activity
        merged.agentID = activity.agentID ?? snapshot.activities[index].agentID
        merged.subagent = incoming
        snapshot.activities[index] = merged
    }

    private mutating func apply(_ update: PendingSteerUpdate) {
        guard let index = snapshot.pendingSteers.firstIndex(where: { pending in
            pending.id == update.id
                || pending.id == update.clientSteerID
                || pending.clientSteerID == update.id
                || (pending.clientSteerID != nil && pending.clientSteerID == update.clientSteerID)
        }) else { return }

        var pending = snapshot.pendingSteers[index]
        if let currentRevision = pending.preemptRevision,
           update.preemptRevision < currentRevision {
            return
        }
        if pending.id != update.id, pending.id == update.clientSteerID {
            pending = PendingSteer(
                id: update.id,
                clientSteerID: update.clientSteerID,
                text: pending.text,
                createdAt: pending.createdAt,
                files: pending.files,
                preempt: update.preempt,
                preemptRevision: update.preemptRevision
            )
        } else {
            pending.clientSteerID = update.clientSteerID ?? pending.clientSteerID
            pending.preempt = update.preempt
            pending.preemptRevision = update.preemptRevision
        }
        snapshot.pendingSteers[index] = pending
    }

    private func matchesApplied(_ pending: PendingSteer) -> Bool {
        snapshot.appliedSteers.contains { Self.identitiesOverlap(pending, $0) }
    }

    private static func identitiesOverlap(_ pending: PendingSteer, _ applied: SteerEvent) -> Bool {
        let pendingIDs = Set([pending.id, pending.clientSteerID].compactMap { $0 })
        let appliedIDs = Set([applied.id, applied.clientSteerID].compactMap { $0 })
        return !pendingIDs.isDisjoint(with: appliedIDs)
    }

    private static func removeMatching(_ applied: SteerEvent, from collection: inout [PendingSteer]) {
        collection.removeAll { identitiesOverlap($0, applied) }
    }

    private static func removeMatching(_ pending: PendingSteer, from collection: inout [PendingSteer]) {
        let ids = Set([pending.id, pending.clientSteerID].compactMap { $0 })
        collection.removeAll { candidate in
            !ids.isDisjoint(with: Set([candidate.id, candidate.clientSteerID].compactMap { $0 }))
        }
    }

    private static func upsertRecoverable(_ pending: PendingSteer, in collection: inout [PendingSteer]) {
        let ids = Set([pending.id, pending.clientSteerID].compactMap { $0 })
        if let index = collection.firstIndex(where: { candidate in
            !ids.isDisjoint(with: Set([candidate.id, candidate.clientSteerID].compactMap { $0 }))
        }) {
            collection[index] = pending
        } else {
            collection.append(pending)
        }
    }
}
