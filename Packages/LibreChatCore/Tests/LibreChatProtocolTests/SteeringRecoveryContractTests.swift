import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

struct SteeringRecoveryContractTests {
    private let decoder = LibreChatGenerationDecoder()

    @Test func syncUsesPendingSteersAndAppliedContentAsSeparateServerTruth() {
        let json = #"{"sync":true,"resumeState":{"conversationId":"conversation","responseMessageId":"response-1","aggregatedContent":[{"type":"text","text":"Before"},{"type":"steer","steerId":"applied-1","clientSteerId":"client-applied","steer":"Use a table","createdAt":1720000000001}],"pendingSteers":[{"steerId":"applied-1","clientSteerId":"client-applied","text":"Use a table","createdAt":1720000000001},{"steerId":"queued-1","clientSteerId":"client-queued","text":"Keep it short","createdAt":1720000000002,"preempt":false,"preemptRevision":2}],"steers":[{"id":"legacy-must-not-be-treated-as-applied","text":"Ambiguous legacy field"}]}}"#
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        apply(json, id: "sync", to: &reducer)

        #expect(reducer.snapshot.appliedSteers.map(\.id) == ["applied-1"])
        #expect(reducer.snapshot.appliedSteers.first?.text == "Use a table")
        #expect(reducer.snapshot.appliedSteers.first?.contentIndex == 1)
        #expect(reducer.snapshot.appliedSteers.first?.targetMessageID == MessageID(rawValue: "response-1"))
        #expect(reducer.snapshot.pendingSteers.map(\.id) == ["queued-1"])
        #expect(reducer.snapshot.pendingSteers.first?.preemptRevision == 2)
    }

    @Test func nestedAppliedEventPreservesCoordinatesAndRemovesPendingIdentity() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(
            #"{"sync":true,"resumeState":{"pendingSteers":[{"steerId":"server-1","clientSteerId":"client-1","text":"Show sources","createdAt":1720000000010}]}}"#,
            id: "sync",
            to: &reducer
        )

        apply(
            #"{"event":"on_steer_applied","data":{"steerId":"server-1","clientSteerId":"client-1","index":3,"part":{"type":"steer","steer":"Show sources","steerId":"server-1","clientSteerId":"client-1","createdAt":1720000000010,"files":[{"file_id":"file-1","filename":"brief.pdf","type":"application/pdf"}]},"responseMessageId":"response-9","conversationId":"conversation"}}"#,
            id: "applied",
            to: &reducer
        )

        #expect(reducer.snapshot.pendingSteers.isEmpty)
        #expect(reducer.snapshot.appliedSteers.count == 1)
        #expect(reducer.snapshot.appliedSteers.first == SteerEvent(
            id: "server-1",
            clientSteerID: "client-1",
            targetMessageID: MessageID(rawValue: "response-9"),
            conversationID: ConversationID(rawValue: "conversation"),
            contentIndex: 3,
            text: "Show sources",
            createdAt: 1_720_000_000_010,
            files: [UploadedFile(id: "file-1", filename: "brief.pdf", mimeType: "application/pdf")]
        ))
    }

    @Test func replayAppliedEventsSettlePendingAfterAuthoritativeSync() {
        let json = #"{"sync":true,"resumeState":{"aggregatedContent":[],"pendingSteers":[{"steerId":"queued-1","text":"Recovered in gap"}],"replayEvents":[{"event":"on_steer_applied","data":{"steerId":"queued-1","index":0,"part":{"type":"steer","steerId":"queued-1","steer":"Recovered in gap"},"conversationId":"conversation","responseMessageId":"response"}}]}}"#
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        apply(json, id: "sync", to: &reducer)

        #expect(reducer.snapshot.pendingSteers.isEmpty)
        #expect(reducer.snapshot.appliedSteers.map(\.id) == ["queued-1"])
    }

    @Test func authoritativeSyncReplacesPendingListIncludingWithEmptyList() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(
            #"{"sync":true,"resumeState":{"pendingSteers":[{"steerId":"stale","text":"Old"}]}}"#,
            id: "sync-1",
            to: &reducer
        )
        #expect(reducer.snapshot.pendingSteers.map(\.id) == ["stale"])

        apply(
            #"{"sync":true,"resumeState":{"aggregatedContent":[],"pendingSteers":[]}}"#,
            id: "sync-2",
            to: &reducer
        )
        #expect(reducer.snapshot.pendingSteers.isEmpty)
    }

    @Test func steerUpdatesUseMonotonicPreemptRevision() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(
            #"{"sync":true,"resumeState":{"pendingSteers":[{"steerId":"server-1","clientSteerId":"client-1","text":"Interrupt","preempt":false,"preemptRevision":1}]}}"#,
            id: "sync",
            to: &reducer
        )
        apply(
            #"{"event":"on_steer_updated","data":{"conversationId":"conversation","steers":[{"steerId":"server-1","clientSteerId":"client-1","preempt":true,"preemptRevision":3}]}}"#,
            id: "revision-3",
            to: &reducer
        )
        apply(
            #"{"event":"on_steer_updated","data":{"conversationId":"conversation","steers":[{"steerId":"server-1","clientSteerId":"client-1","preempt":false,"preemptRevision":2}]}}"#,
            id: "revision-2",
            to: &reducer
        )

        #expect(reducer.snapshot.pendingSteers.first?.preempt == true)
        #expect(reducer.snapshot.pendingSteers.first?.preemptRevision == 3)
    }

    @Test func finalLeftoversAreTypedDeduplicatedAndRemovedIfLaterProvenApplied() {
        let final = #"{"final":true,"aborted":true,"pendingSteers":[{"steerId":"leftover-1","clientSteerId":"client-1","text":"Do not lose this","createdAt":1720000000020}],"responseMessage":{"text":"Partial","unfinished":true}}"#
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        apply(final, id: "final-1", to: &reducer)
        apply(final, id: "final-2", to: &reducer)
        #expect(reducer.snapshot.recoverableSteers.map(\.id) == ["leftover-1"])

        apply(
            #"{"event":"on_steer_applied","data":{"steerId":"leftover-1","clientSteerId":"client-1","index":1,"part":{"type":"steer","steerId":"leftover-1","clientSteerId":"client-1","steer":"Do not lose this"}}}"#,
            id: "late-proof",
            to: &reducer
        )
        #expect(reducer.snapshot.recoverableSteers.isEmpty)
        #expect(reducer.snapshot.appliedSteers.map(\.id) == ["leftover-1"])
    }

    @Test func authoritativeContentClearsClientCorrelatedRecoveryCopy() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        reducer.apply(SequencedGenerationEvent(event: .recoverableSteers([
            PendingSteer(id: "client-1", text: "Recovered optimistically")
        ])))
        reducer.apply(SequencedGenerationEvent(event: .recoverableSteers([
            PendingSteer(id: "server-1", clientSteerID: "client-1", text: "Recovered authoritatively")
        ])))
        #expect(reducer.snapshot.recoverableSteers.map(\.id) == ["server-1"])

        apply(
            #"{"sync":true,"resumeState":{"aggregatedContent":[{"type":"steer","steerId":"server-1","clientSteerId":"client-1","steer":"Recovered authoritatively"}],"pendingSteers":[]}}"#,
            id: "authoritative-content",
            to: &reducer
        )

        #expect(reducer.snapshot.recoverableSteers.isEmpty)
        #expect(reducer.snapshot.appliedSteers.map(\.id) == ["server-1"])
    }

    @Test func statusAndAbortRecoveryProjectionsProduceOneTypedLeftover() throws {
        let data = Data(#"{"active":false,"streamId":"conversation","status":"aborted","generationProtocolVersion":2,"unrecoveredSteers":[{"steerId":"parked-1","text":"Try this next","preempt":true,"preemptRevision":4}]}"#.utf8)
        let status = try JSONDecoder().decode(GenerationStatusDTO.self, from: data)
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        let statusEvent = try #require(decoder.synchronizationEvent(from: status))
        reducer.apply(statusEvent)
        reducer.apply(statusEvent)
        #expect(reducer.snapshot.recoverableSteers.count == 1)
        #expect(reducer.snapshot.recoverableSteers.first?.preemptRevision == 4)

        let abortEvent = try #require(decoder.recoverableSteersEvent(from: status.unrecoveredSteers))
        reducer.apply(abortEvent)
        #expect(reducer.snapshot.recoverableSteers.map(\.id) == ["parked-1"])
    }

    @Test func missingAndExplicitEmptyTerminalProjectionsHaveDifferentOwnershipSemantics() throws {
        let parked = PendingSteer(id: "parked", text: "Do not lose this")
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        reducer.apply(SequencedGenerationEvent(event: .recoverableSteers([parked])))

        let missingStatus = try JSONDecoder().decode(
            GenerationStatusDTO.self,
            from: Data(#"{"active":false,"status":"aborted"}"#.utf8)
        )
        #expect(decoder.recoverableSteersEvent(from: missingStatus.unrecoveredSteers) == nil)
        #expect(reducer.snapshot.recoverableSteers == [parked])

        let emptyStatus = try JSONDecoder().decode(
            GenerationStatusDTO.self,
            from: Data(#"{"active":false,"status":"aborted","unrecoveredSteers":[]}"#.utf8)
        )
        reducer.apply(try #require(decoder.recoverableSteersEvent(from: emptyStatus.unrecoveredSteers)))
        #expect(reducer.snapshot.recoverableSteers.isEmpty)

        reducer.apply(SequencedGenerationEvent(event: .recoverableSteers([parked])))
        apply(#"{"final":true,"responseMessage":{"text":"Done"}}"#, id: "final-omitted", to: &reducer)
        #expect(reducer.snapshot.recoverableSteers == [parked])

        apply(#"{"final":true,"pendingSteers":[],"responseMessage":{"text":"Done"}}"#, id: "final-empty", to: &reducer)
        #expect(reducer.snapshot.recoverableSteers.isEmpty)
    }

    @Test func legacyCachedSnapshotDecodesSteersAndDefaultsNewOwnershipArrays() throws {
        let original = GenerationSnapshot(
            handle: LibreChatFixtures.handle,
            appliedSteers: [SteerEvent(id: "legacy-applied", text: "Already used")]
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var legacySteers = try #require(object.removeValue(forKey: "appliedSteers") as? [[String: Any]])
        legacySteers[0].removeValue(forKey: "files")
        object["steers"] = legacySteers
        object.removeValue(forKey: "pendingSteers")
        object.removeValue(forKey: "recoverableSteers")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GenerationSnapshot.self, from: legacyData)

        #expect(decoded.appliedSteers.map(\.id) == ["legacy-applied"])
        #expect(decoded.appliedSteers.first?.files.isEmpty == true)
        #expect(decoded.pendingSteers.isEmpty)
        #expect(decoded.recoverableSteers.isEmpty)
    }

    @Test func legacyCachedSynchronizationDefaultsNewOwnershipArrays() throws {
        let original = GenerationSync(
            aggregatedContent: [.text("Saved")],
            appliedSteers: [SteerEvent(id: "legacy-sync", text: "Applied")]
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var legacySteers = try #require(object.removeValue(forKey: "appliedSteers") as? [[String: Any]])
        legacySteers[0].removeValue(forKey: "files")
        object["steers"] = legacySteers
        object.removeValue(forKey: "pendingSteers")
        object.removeValue(forKey: "recoverableSteers")

        let decoded = try JSONDecoder().decode(
            GenerationSync.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.appliedSteers.map(\.id) == ["legacy-sync"])
        #expect(decoded.pendingSteers.isEmpty)
        #expect(decoded.recoverableSteers.isEmpty)
    }

    @Test func recoveredStartCoordinatesRoundTripWithoutChangingLegacyRequests() throws {
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Recovery",
            target: ConversationTarget(endpoint: "agents", agentID: "agent")
        )
        let recovered = ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            parentMessageID: MessageID(rawValue: "finished-assistant"),
            text: "Use a table",
            expectedPredecessorCreatedAt: 1_720_000_000_000,
            recoverySteerID: "server-steer:1",
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!,
            clientMessageID: MessageID(rawValue: "server-steer:1")
        )

        let decoded = try JSONDecoder().decode(
            ChatRequest.self,
            from: JSONEncoder().encode(recovered)
        )
        #expect(decoded == recovered)

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "profileID": "profile",
            "accountID": "account",
            "conversation": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(conversation)
            ),
            "parentMessageID": "finished-assistant",
            "text": "Next",
            "attachments": []
        ])
        let legacy = try JSONDecoder().decode(ChatRequest.self, from: legacyData)
        #expect(legacy.recoverySteerID == nil)
    }

    private func apply(_ json: String, id: String, to reducer: inout GenerationReducer) {
        for event in decoder.decode(
            .init(id: id, data: json),
            conversationID: reducer.snapshot.handle.conversationID
        ) {
            reducer.apply(event)
        }
    }
}
