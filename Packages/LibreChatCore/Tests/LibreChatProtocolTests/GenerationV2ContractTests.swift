import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

/// Wire-level regression tests for the deployed Agents generation protocol v2.
/// These fixtures deliberately use the nested server shapes instead of the
/// flattened convenience shapes used by the legacy web protocol.
struct GenerationV2ContractTests {
    private let decoder = LibreChatGenerationDecoder()

    @Test func chatRequestActionAndIdRoundTripWithoutChangingLegacyDefaults() throws {
        let conversation = Conversation(
            id: ConversationID(rawValue: "conversation"),
            title: "Test",
            target: ConversationTarget(endpoint: "agents", agentID: "agent-1")
        )
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let request = ChatRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            conversation: conversation,
            text: "Revised",
            clientRequestID: requestID,
            action: .editPromptAndResubmit(sourceUserMessageID: MessageID(rawValue: "source-user"))
        )
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatRequest.self, from: encoded)

        #expect(decoded == request)
        #expect(decoded.clientRequestID == requestID)
        #expect(decoded.action == .editPromptAndResubmit(
            sourceUserMessageID: MessageID(rawValue: "source-user")
        ))

        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "action")
        legacy.removeValue(forKey: "clientRequestID")
        legacy.removeValue(forKey: "clientMessageID")
        let legacyDecoded = try JSONDecoder().decode(
            ChatRequest.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(legacyDecoded.action == .send)

        let regenerate = ChatRequest(
            profileID: request.profileID,
            accountID: request.accountID,
            conversation: conversation,
            text: "Original",
            clientRequestID: requestID,
            action: .regenerateResponse(
                sourceUserMessageID: MessageID(rawValue: "source-user"),
                targetAssistantMessageID: MessageID(rawValue: "target-assistant_")
            )
        )
        let regenerateDecoded = try JSONDecoder().decode(
            ChatRequest.self,
            from: JSONEncoder().encode(regenerate)
        )
        #expect(regenerateDecoded == regenerate)
    }

    @Test func derivesTheServerNewConversationIdempotencyID() {
        let identifier = LibreChatGenerationIdentity.newConversationID(
            userID: "account",
            clientRequestID: "00000000-0000-0000-0000-000000000001"
        )

        #expect(identifier == "8ec37ad2-089b-56a0-8c7c-c4f24cf10a54")
    }

    @Test func reconciliationFinalIsNotSuccessfulCompletion() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(#"{"final":true,"reconcile":true,"reconcileReason":"terminal_payload_missing"}"#, id: "reconcile", to: &reducer)

        #expect(reducer.snapshot.state == .reconciling)
        #expect(reducer.snapshot.state != .completed)
    }

    @Test func unfinishedFinalDoesNotBecomeCompleted() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(#"{"final":true,"responseMessage":{"text":"partial","unfinished":true}}"#, id: "unfinished", to: &reducer)

        #expect(reducer.snapshot.state != .completed)
    }

    @Test func normalFinalContentCompletes() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(#"{"final":true,"responseMessage":{"text":"complete"}}"#, id: "final", to: &reducer)

        #expect(reducer.snapshot.response?.plainText == "complete")
        #expect(reducer.snapshot.state == .completed)
    }

    @Test func finalStringErrorFailsInsteadOfCompleting() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(#"{"final":true,"responseMessage":{"text":"partial","error":"Provider failed"}}"#, id: "error", to: &reducer)

        guard case let .failed(failure) = reducer.snapshot.state else {
            Issue.record("Expected a failed terminal state")
            return
        }
        #expect(failure.message == "Provider failed")
    }

    @Test func synchronizationInstallsAuthoritativeContentBeforePendingEvents() {
        let json = #"{"sync":true,"resumeState":{"aggregatedContent":"authoritative"},"pendingEvents":[{"event":"on_message_delta","data":{"delta":{"content":" + pending"}}}]}"#
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        for event in decoder.decode(.init(id: "sync", data: json), conversationID: LibreChatFixtures.handle.conversationID) {
            reducer.apply(event)
        }

        #expect(reducer.snapshot.response?.plainText == "authoritative + pending")
        #expect(reducer.snapshot.state == .streaming)
    }

    @Test func synchronizationPreservesStructuredAggregatedContent() {
        let json = #"{"sync":true,"resumeState":{"aggregatedContent":[{"type":"text","text":"Visible"},{"type":"think","think":"Private reasoning"},{"type":"image_url","image_url":{"url":"https://example.com/image.png"}},{"type":"tool_call","tool_call":{"id":"call-7","name":"search"}},{"type":"future_part","payload":{"value":1}}]}}"#
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        for event in decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID) {
            reducer.apply(event)
        }

        #expect(reducer.snapshot.response?.content == [
            .text("Visible"),
            .reasoning("Private reasoning"),
            .image(URL(string: "https://example.com/image.png")!, alternativeText: nil),
            .tool(ToolCall(id: "call-7", name: "search", status: .running)),
            .unsupported(kind: "future_part")
        ])
    }

    @Test func activityAttachmentTitleAndUsageEventsRemainRecoverableState() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        let fixtures = [
            #"{"event":"on_activity_label","data":{"index":1,"part":{"type":"activity_label","activity_label":"Searched release notes","status":"ok","pending":false,"agent_id":"agent-1"}}}"#,
            #"{"event":"on_agent_update","data":{"runId":"run-2","message":"Researcher is thinking..."}}"#,
            #"{"event":"attachment","data":{"file_id":"file-1","filename":"report.pdf","filepath":"/uploads/report.pdf","source":"local","embedded":false,"type":"application/pdf"}}"#,
            #"{"event":"title","data":{"title":"Native protocol research"}}"#,
            #"{"event":"on_token_usage","data":{"input_tokens":120,"output_tokens":45}}"#,
            #"{"event":"on_context_usage","data":{"breakdown":{"maxContextTokens":200000,"instructionTokens":1500,"messageTokens":9000,"toolCount":3,"messageCount":4},"remainingContextTokens":179500}}"#
        ]

        for (index, fixture) in fixtures.enumerated() {
            apply(fixture, id: "event-\(index)", to: &reducer)
        }

        #expect(reducer.snapshot.activities.map(\.label) == [
            "Searched release notes",
            "Researcher is thinking..."
        ])
        #expect(reducer.snapshot.response?.content.contains(.file(UploadedFile(
            id: "file-1",
            filename: "report.pdf",
            filepath: "/uploads/report.pdf",
            mimeType: "application/pdf",
            source: "local",
            embedded: false
        ))) == true)
        #expect(reducer.snapshot.title == "Native protocol research")
        #expect(reducer.snapshot.usage == TokenUsage(inputTokens: 120, outputTokens: 45))
        #expect(reducer.snapshot.contextUsage == ContextUsage(
            maximumTokens: 200000,
            messageTokens: 9000,
            instructionTokens: 1500,
            remainingTokens: 179500,
            toolCount: 3,
            messageCount: 4
        ))
    }

    @Test func toolApprovalPreservesActionIDAllToolCallIDsAndAllowedDecisions() {
        let json = #"{"pendingAction":{"actionId":"action-42","streamId":"stream-42","conversationId":"conversation-42","runId":"run-42","interruptId":"interrupt-42","createdAt":1720000000000,"expiresAt":1720000060000,"payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":"{\"command\":\"ls\"}","tool_call_id":"call-1"},{"name":"search","arguments":{"query":"native"},"description":"Search the indexed files","tool_call_id":"call-2"}],"review_configs":[{"action_name":"shell","tool_call_id":"call-1","allowed_decisions":["approve","reject"]},{"action_name":"search","tool_call_id":"call-2","allowed_decisions":["approve","edit","respond"]}]}}}"#
        let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)

        guard let envelope = events.first(where: {
            if case .pendingInteraction(.toolApproval) = $0.event { true } else { false }
        }), case let .pendingInteraction(.toolApproval(approval)) = envelope.event else {
            Issue.record("Expected a typed tool-approval interaction")
            return
        }
        #expect(approval.id == "action-42")
        #expect(approval.toolCallIDs == ["call-1", "call-2"])
        #expect(approval.allowedDecisions["call-1"] == ["approve", "reject"])
        #expect(approval.allowedDecisions["call-2"] == ["approve", "edit", "respond"])
        #expect(approval.items?.map(\.name) == ["shell", "search"])
        #expect(approval.items?.first?.arguments == #"{"command":"ls"}"#)
        #expect(approval.items?.last?.arguments == #"{"query":"native"}"#)
        #expect(approval.items?.last?.summary == "Search the indexed files")
        #expect(approval.createdAt == Date(timeIntervalSince1970: 1_720_000_000))
        #expect(approval.expiresAt == Date(timeIntervalSince1970: 1_720_000_060))
        #expect(approval.streamID == "stream-42")
        #expect(approval.conversationID == ConversationID(rawValue: "conversation-42"))
        #expect(approval.runID == "run-42")
        #expect(approval.interruptID == "interrupt-42")
    }

    @Test func incompleteOrMismatchedToolApprovalBatchIsNotActionable() {
        let fixtures = [
            #"{"pendingAction":{"actionId":"missing-arguments","payload":{"type":"tool_approval","action_requests":[{"name":"shell","tool_call_id":"call-1"}],"review_configs":[{"action_name":"shell","tool_call_id":"call-1","allowed_decisions":["approve"]}]}}}"#,
            #"{"pendingAction":{"actionId":"missing-review","payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":{},"tool_call_id":"call-1"}],"review_configs":[]}}}"#,
            #"{"pendingAction":{"actionId":"wrong-review","payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":{},"tool_call_id":"call-1"}],"review_configs":[{"action_name":"shell","tool_call_id":"other","allowed_decisions":["approve"]}]}}}"#,
            #"{"pendingAction":{"actionId":"unknown-decision","payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":{},"tool_call_id":"call-1"}],"review_configs":[{"action_name":"shell","tool_call_id":"call-1","allowed_decisions":["approve_forever"]}]}}}"#,
        ]

        for json in fixtures {
            let events = decoder.decode(
                .init(data: json),
                conversationID: LibreChatFixtures.handle.conversationID
            )
            #expect(!events.contains { if case .pendingInteraction = $0.event { true } else { false } })
        }
    }

    @Test func missingToolApprovalActionIDDoesNotInventActionableInteraction() {
        let json = #"{"pendingAction":{"payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":{},"tool_call_id":"call-1"}],"review_configs":[{"action_name":"shell","tool_call_id":"call-1","allowed_decisions":["approve"]}]}}}"#
        let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)

        #expect(!events.contains {
            if case .pendingInteraction = $0.event { true } else { false }
        })
    }

    @Test func singleAskUserQuestionPreservesLabelsAndValues() {
        let json = #"{"pendingAction":{"actionId":"question-7","payload":{"type":"ask_user_question","question":{"question":"Choose a format","description":"This controls the exported response.","options":[{"label":"Brief","value":"brief"},{"label":"Detailed","value":"detailed"}]}}}}"#
        let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)

        guard let envelope = events.first(where: {
            if case .pendingInteraction(.userQuestion) = $0.event { true } else { false }
        }), case let .pendingInteraction(.userQuestion(question)) = envelope.event else {
            Issue.record("Expected a typed user-question interaction")
            return
        }
        #expect(question.id == "question-7")
        #expect(question.prompt == "Choose a format")
        #expect(question.detail == "This controls the exported response.")
        #expect(question.options == ["Brief", "Detailed"])
        #expect(question.optionValues == ["Brief": "brief", "Detailed": "detailed"])
    }

    @Test func singleAskUserQuestionPreservesMultiSelect() {
        let json = #"{"pendingAction":{"actionId":"question-multi","payload":{"type":"ask_user_question","question":{"question":"Choose formats","multiSelect":true,"options":[{"label":"PDF","value":"pdf"},{"label":"Markdown","value":"md"}]}}}}"#
        let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)

        guard let envelope = events.first(where: {
            if case .pendingInteraction(.userQuestion) = $0.event { true } else { false }
        }), case let .pendingInteraction(.userQuestion(question)) = envelope.event else {
            Issue.record("Expected a typed multi-select question")
            return
        }
        #expect(question.allowsMultipleSelection == true)
    }

    @Test func batchedAskUserQuestionPreservesEveryQuestionAndWireValue() {
        let json = #"{"pendingAction":{"actionId":"question-batch","payload":{"type":"ask_user_question","question":{"question":"Fallback"},"questions":[{"id":"environment","header":"Environment","question":"Where should this run?","description":"Choose the deployment target.","options":[{"label":"Staging","value":"staging"},{"label":"Production","value":"production"}]},{"id":"formats","header":"Output","question":"Which formats?","multiSelect":true,"options":[{"label":"PDF","value":"pdf"},{"label":"Markdown","value":"md"}]}]}}}"#
        let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)

        guard let envelope = events.first(where: {
            if case .pendingInteraction(.userQuestion) = $0.event { true } else { false }
        }), case let .pendingInteraction(.userQuestion(question)) = envelope.event else {
            Issue.record("Expected a typed batched question")
            return
        }
        #expect(question.questionIDs == ["environment", "formats"])
        #expect(question.items?.count == 2)
        #expect(question.items?.first?.header == "Environment")
        #expect(question.items?.first?.detail == "Choose the deployment target.")
        #expect(question.items?.first?.optionValues["Staging"] == "staging")
        #expect(question.items?.last?.allowsMultipleSelection == true)
        #expect(question.items?.last?.optionValues["Markdown"] == "md")
    }

    @Test func malformedBatchedQuestionWithDuplicateIDsIsNotActionable() {
        let json = #"{"pendingAction":{"actionId":"question-batch","payload":{"type":"ask_user_question","questions":[{"id":"same","question":"First"},{"id":"same","question":"Second"}]}}}"#
        let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)

        #expect(!events.contains {
            if case .pendingInteraction = $0.event { true } else { false }
        })
    }

    @Test func malformedBatchShapesAndCountsAreNotActionable() {
        let fixtures = [
            #"{"pendingAction":{"actionId":"empty","payload":{"type":"ask_user_question","question":{"question":"Fallback"},"questions":[]}}}"#,
            #"{"pendingAction":{"actionId":"scalar","payload":{"type":"ask_user_question","question":{"question":"Fallback"},"questions":"invalid"}}}"#,
            #"{"pendingAction":{"actionId":"mixed","payload":{"type":"ask_user_question","questions":[{"id":"valid","question":"One"},"invalid"]}}}"#,
            #"{"pendingAction":{"actionId":"many","payload":{"type":"ask_user_question","questions":[{"id":"one","question":"1"},{"id":"two","question":"2"},{"id":"three","question":"3"},{"id":"four","question":"4"},{"id":"five","question":"5"}]}}}"#,
            #"{"pendingAction":{"actionId":"id","payload":{"type":"ask_user_question","questions":[{"id":"1-invalid","question":"One"}]}}}"#
        ]

        for json in fixtures {
            let events = decoder.decode(.init(data: json), conversationID: LibreChatFixtures.handle.conversationID)
            #expect(!events.contains {
                if case .pendingInteraction = $0.event { true } else { false }
            })
        }
    }

    private func apply(_ json: String, id: String, to reducer: inout GenerationReducer) {
        for event in decoder.decode(.init(id: id, data: json), conversationID: reducer.snapshot.handle.conversationID) {
            reducer.apply(event)
        }
    }
}
