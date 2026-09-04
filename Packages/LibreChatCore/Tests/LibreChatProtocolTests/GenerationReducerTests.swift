import Foundation
import Testing
import LibreChatDomain
import LibreChatTestSupport
@testable import LibreChatProtocol

struct GenerationReducerTests {
    @Test func stopRequestMovesAnActiveGenerationToStopping() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        _ = reducer.apply(.init(event: .textDelta("partial")))
        let snapshot = reducer.apply(.init(event: .stopRequested))

        #expect(snapshot.state == .stopping)
    }

    @Test func unfinishedFinalAfterStopBecomesAborted() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        _ = reducer.apply(.init(event: .stopRequested))
        let snapshot = reducer.apply(.init(event: .terminal(.unfinished)))

        #expect(snapshot.state == .aborted)
    }

    @Test func reconnectDoesNotForgetThatStopWasRequested() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        _ = reducer.apply(.init(event: .stopRequested))
        _ = reducer.apply(.init(event: .reconnecting(attempt: 1)))
        let snapshot = reducer.apply(.init(event: .terminal(.unfinished)))

        #expect(snapshot.state == .aborted)
    }

    @Test func unfinishedFinalWithoutStopRequiresReconciliation() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        _ = reducer.apply(.init(event: .textDelta("partial")))
        let snapshot = reducer.apply(.init(event: .terminal(.unfinished)))

        #expect(snapshot.state == .reconciling)
    }

    @Test func reconciliationFinalNeverCompletesGeneration() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        let snapshot = reducer.apply(
            .init(event: .terminal(.reconciliationRequired(reason: "terminal_payload_missing")))
        )

        #expect(snapshot.state == .reconciling)
        #expect(!snapshot.state.isTerminal)
    }

    @Test func deduplicatesReplayAndUsesSyncAsAuthoritative() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        _ = reducer.apply(.init(id: "1", event: .textDelta("Hel")), at: Date(timeIntervalSince1970: 1))
        _ = reducer.apply(.init(id: "1", event: .textDelta("Hel")), at: Date(timeIntervalSince1970: 2))
        #expect(reducer.snapshot.response?.plainText == "Hel")

        let snapshot = reducer.apply(
            .init(id: "sync", event: .synchronization(GenerationSync(
                aggregatedContent: [.text("Hello authoritative")],
                isComplete: false
            ))),
            at: Date(timeIntervalSince1970: 3)
        )
        #expect(snapshot.response?.plainText == "Hello authoritative")
        #expect(snapshot.state == .streaming)
    }

    @Test func pendingAndPredecessorMismatchAreRealStates() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        let interaction = PendingInteraction.toolApproval(.init(id: "approval", toolName: "Search"))
        #expect(reducer.apply(.init(event: .pendingInteraction(interaction))).state == .awaitingApproval(interaction))
        #expect(reducer.apply(.init(event: .lifecycle(.predecessorMismatch))).state == .reconciling)
    }

    @Test(arguments: [
        GenerationEvent.lifecycle(.settled),
        .lifecycle(.replaced),
        .terminal(.completed),
        .completed,
        .aborted,
        .failed(.init(code: "failed", message: "failed", isRecoverable: false)),
    ])
    func terminalOutcomesRemovePendingInteraction(_ terminalEvent: GenerationEvent) {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        let interaction = PendingInteraction.toolApproval(.init(id: "approval", toolName: "Search"))
        _ = reducer.apply(.init(event: .pendingInteraction(interaction)))

        let snapshot = reducer.apply(.init(event: terminalEvent))

        #expect(snapshot.pendingInteraction == nil)
    }

    @Test func completedSynchronizationRemovesPendingInteraction() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        let interaction = PendingInteraction.toolApproval(.init(id: "approval", toolName: "Search"))
        _ = reducer.apply(.init(event: .pendingInteraction(interaction)))

        let snapshot = reducer.apply(.init(event: .synchronization(.init(isComplete: true))))

        #expect(snapshot.state == .completed)
        #expect(snapshot.pendingInteraction == nil)
    }
}
