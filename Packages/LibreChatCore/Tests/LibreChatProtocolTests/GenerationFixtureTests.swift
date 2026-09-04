import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

struct GenerationFixtureTests {
    private let decoder = LibreChatGenerationDecoder()

    @Test func normalGenerationReachesAuthoritativeCompletion() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(#"{"event":"on_message_delta","data":{"delta":{"content":"Hel"}}}"#, id: "1", to: &reducer)
        apply(#"{"event":"on_message_delta","data":{"delta":{"content":"lo"}}}"#, id: "2", to: &reducer)
        apply(#"{"final":true,"responseMessage":{"text":"Hello"}}"#, id: "3", to: &reducer)
        #expect(reducer.snapshot.response?.plainText == "Hello")
        #expect(reducer.snapshot.state == .completed)
    }

    @Test func resumeSyncMergesStructuredStateAndDeduplicatesReplay() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        let sync = """
        {"sync":true,"resumeState":{"aggregatedContent":"Recovered","runSteps":[{"id":"step","label":"Searching","completed":true}],"toolCalls":[{"id":"tool","name":"Search","status":"completed","output":"Done"}],"pendingAction":{"actionId":"approval","payload":{"type":"tool_approval","action_requests":[{"name":"Write","arguments":{},"tool_call_id":"write-1"}],"review_configs":[{"action_name":"Write","tool_call_id":"write-1","allowed_decisions":["approve","reject"]}]}},"usage":{"prompt_tokens":4,"completion_tokens":6},"pendingSteers":[{"steerId":"steer","clientSteerId":"client-steer","text":"Be concise","createdAt":1720000000000,"preempt":false,"preemptRevision":1}]}}
        """
        apply(sync, id: "sync", to: &reducer)
        apply(sync, id: "sync", to: &reducer)
        #expect(reducer.snapshot.response?.plainText == "Recovered")
        #expect(reducer.snapshot.runSteps.count == 1)
        #expect(reducer.snapshot.toolCalls.count == 1)
        #expect(reducer.snapshot.usage == TokenUsage(inputTokens: 4, outputTokens: 6))
        #expect(reducer.snapshot.appliedSteers.isEmpty)
        #expect(reducer.snapshot.pendingSteers.first?.text == "Be concise")
        guard case .awaitingApproval = reducer.snapshot.state else {
            Issue.record("Expected a durable approval state")
            return
        }
    }

    @Test func lifecycleFramesCoverResumeReplacementMismatchAndSettlement() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(#"{"status":"resumed"}"#, id: "1", to: &reducer)
        #expect(reducer.snapshot.state == .streaming)
        apply(#"{"status":"replaced"}"#, id: "2", to: &reducer)
        #expect(reducer.snapshot.state == .superseded)
        apply(#"{"status":"predecessor_mismatch"}"#, id: "3", to: &reducer)
        #expect(reducer.snapshot.state == .reconciling)
        apply(#"{"status":"settled"}"#, id: "4", to: &reducer)
        #expect(reducer.snapshot.state == .completed)
    }

    @Test func winnerHandoffIsNeverClassifiedAsOriginalStreamingSuccess() {
        let outcome = ChatSendOutcome.handoff(LibreChatFixtures.handle)
        #expect(outcome.streamingHandle == nil)
        #expect(outcome.handoffHandle == LibreChatFixtures.handle)
        #expect(outcome.conversationID == LibreChatFixtures.handle.conversationID)
    }

    @Test func toolQuestionAndServerFailureDecodeWhileUnknownOAuthFailsClosed() {
        let conversation = LibreChatFixtures.handle.conversationID
        let approval = decoder.decode(.init(data: #"{"pendingAction":{"actionId":"a","payload":{"type":"tool_approval","action_requests":[{"name":"Shell","arguments":{},"tool_call_id":"shell-1"}],"review_configs":[{"action_name":"Shell","tool_call_id":"shell-1","allowed_decisions":["approve","reject"]}]}}}"#), conversationID: conversation)
        let question = decoder.decode(.init(data: #"{"pendingAction":{"actionId":"q","payload":{"type":"ask_user_question","question":{"question":"Choose","options":[{"label":"A","value":"a"},{"label":"B","value":"b"}]}}}}"#), conversationID: conversation)
        let oauth = decoder.decode(.init(data: #"{"pendingAction":{"actionId":"o","payload":{"type":"oauth","service":"GitHub","authorizationURL":"https://example.com/auth"}}}"#), conversationID: conversation)
        let failure = decoder.decode(.init(event: "error", data: #"{"message":"failed"}"#), conversationID: conversation)
        #expect(approval.contains { if case .pendingInteraction(.toolApproval(_)) = $0.event { true } else { false } })
        #expect(question.contains { if case .pendingInteraction(.userQuestion(_)) = $0.event { true } else { false } })
        #expect(!oauth.contains { if case .pendingInteraction = $0.event { true } else { false } })
        #expect(failure.contains { if case .failed = $0.event { true } else { false } })
    }

    @Test func unknownExternalAuthenticationActionsAreNeverActionable() {
        let conversation = LibreChatFixtures.handle.conversationID
        let fixtures = [
            "https://identity.example.com/authorize?state=opaque",
            "http://localhost:9100/authorize",
            "http://127.0.0.1:9100/authorize",
            "http://[::1]:9100/authorize",
            "javascript:alert(1)",
            "file:///private/etc/hosts",
            "custom://authorize",
            "http://identity.example.com/authorize",
            "https://user:password@identity.example.com/authorize",
            "https://identity.example.com/authorize#token"
        ]
        for rawURL in fixtures {
            let json = #"{"pendingAction":{"actionId":"oauth","payload":{"type":"oauth","service":"Provider","authorizationURL":"\#(rawURL)"}}}"#
            let events = decoder.decode(.init(data: json), conversationID: conversation)
            #expect(!events.contains {
                if case .pendingInteraction(.externalAuthentication(_)) = $0.event { true } else { false }
            }, Comment(rawValue: rawURL))
        }
    }

    private func apply(_ json: String, id: String, to reducer: inout GenerationReducer) {
        for event in decoder.decode(.init(id: id, data: json), conversationID: reducer.snapshot.handle.conversationID) {
            reducer.apply(event)
        }
    }
}
