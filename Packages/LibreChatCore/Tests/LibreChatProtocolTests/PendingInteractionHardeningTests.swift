import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

struct PendingInteractionHardeningTests {
    private let decoder = LibreChatGenerationDecoder()

    @Test func approvalDecoderPreservesEachDisclosedToolAndItsArguments() throws {
        let json = #"{"pendingAction":{"actionId":"action-42","createdAt":1720000000000,"expiresAt":1720000060000,"payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":"{\"command\":\"ls\"}","tool_call_id":"call-1","description":"List files"},{"name":"search","arguments":{"query":"swift","limit":2},"tool_call_id":"call-2","description":"Search documentation"}],"review_configs":[{"action_name":"shell","tool_call_id":"call-1","allowed_decisions":["approve","reject"]},{"action_name":"search","tool_call_id":"call-2","allowed_decisions":["edit","respond"]}]}}}"#

        let interaction = try #require(pendingInteraction(in: json))
        guard case let .toolApproval(approval) = interaction else {
            Issue.record("Expected a tool approval")
            return
        }

        #expect(approval.id == "action-42")
        #expect(approval.createdAt == Date(timeIntervalSince1970: 1_720_000_000))
        #expect(approval.expiresAt == Date(timeIntervalSince1970: 1_720_000_060))
        #expect(approval.items?.map(\.id) == ["call-1", "call-2"])
        #expect(approval.items?.map(\.name) == ["shell", "search"])
        #expect(approval.items?.compactMap(\.summary) == ["List files", "Search documentation"])
        #expect(approval.items?.first?.arguments == #"{"command":"ls"}"#)
        #expect(approval.items?.last?.arguments == #"{"limit":2,"query":"swift"}"#)
        #expect(approval.items?.first?.allowedDecisions == [.approve, .reject])
        #expect(approval.items?.last?.allowedDecisions == [.edit, .respond])
    }

    @Test(arguments: [
        #"{"pendingAction":{"actionId":"missing-arguments","payload":{"type":"tool_approval","action_requests":[{"name":"shell","tool_call_id":"call-1"}],"review_configs":[{"tool_call_id":"call-1","allowed_decisions":["approve"]}]}}}"#,
        #"{"pendingAction":{"actionId":"unknown-decision","payload":{"type":"tool_approval","action_requests":[{"name":"shell","arguments":{},"tool_call_id":"call-1"}],"review_configs":[{"tool_call_id":"call-1","allowed_decisions":["approve_forever"]}]}}}"#,
        #"{"pendingAction":{"actionId":"duplicate-call","payload":{"type":"tool_approval","action_requests":[{"name":"first","arguments":{},"tool_call_id":"same"},{"name":"second","arguments":{},"tool_call_id":"same"}],"review_configs":[{"tool_call_id":"same","allowed_decisions":["approve"]},{"tool_call_id":"other","allowed_decisions":["reject"]}]}}}"#,
        #"{"pendingAction":{"actionId":"missing-review","payload":{"type":"tool_approval","action_requests":[{"name":"first","arguments":{},"tool_call_id":"call-1"},{"name":"second","arguments":{},"tool_call_id":"call-2"}],"review_configs":[{"tool_call_id":"call-1","allowed_decisions":["approve"]}]}}}"#,
        #"{"pendingAction":{"actionId":"duplicate-review","payload":{"type":"tool_approval","action_requests":[{"name":"first","arguments":{},"tool_call_id":"call-1"},{"name":"second","arguments":{},"tool_call_id":"call-2"}],"review_configs":[{"tool_call_id":"call-1","allowed_decisions":["approve"]},{"tool_call_id":"call-1","allowed_decisions":["reject"]}]}}}"#,
    ])
    func malformedApprovalDoesNotBecomeActionable(_ json: String) {
        #expect(pendingInteraction(in: json) == nil)
    }

    @Test func unsupportedBrowserActionDoesNotBecomeActionable() {
        let json = #"{"pendingAction":{"actionId":"oauth","payload":{"type":"oauth","service":"Example","authorizationURL":"https://example.com/authorize"}}}"#

        #expect(pendingInteraction(in: json) == nil)
    }

    @Test func interactionExpiryUsesAnInclusiveBoundary() {
        let boundary = Date(timeIntervalSince1970: 1_720_000_060)
        let approval = ToolApprovalRequest(
            id: "approval",
            items: [
                ToolApprovalItem(
                    id: "call",
                    name: "shell",
                    arguments: "{}",
                    allowedDecisions: [.approve]
                )
            ],
            expiresAt: boundary
        )
        let question = UserQuestion(id: "question", prompt: "Continue?", expiresAt: boundary)

        #expect(!approval.isExpired(at: boundary.addingTimeInterval(-0.001)))
        #expect(approval.isExpired(at: boundary))
        #expect(!question.isExpired(at: boundary.addingTimeInterval(-0.001)))
        #expect(question.isExpired(at: boundary))
    }

    @Test(arguments: [
        GenerationEvent.lifecycle(.settled),
        .lifecycle(.replaced),
        .terminal(.completed),
        .completed,
        .aborted,
        .failed(.init(code: "failed", message: "Failed", isRecoverable: false)),
    ])
    func terminalOutcomesCannotRetainAnActionableInteraction(_ event: GenerationEvent) {
        let interaction = PendingInteraction.userQuestion(
            UserQuestion(id: "question", prompt: "Continue?")
        )
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        _ = reducer.apply(.init(event: .pendingInteraction(interaction)))

        let terminal = reducer.apply(.init(event: event))

        #expect(terminal.state.isTerminal)
        #expect(terminal.pendingInteraction == nil)
    }

    private func pendingInteraction(in json: String) -> PendingInteraction? {
        let envelopes = decoder.decode(
            .init(data: json),
            conversationID: LibreChatFixtures.handle.conversationID
        )
        for envelope in envelopes {
            if case let .pendingInteraction(interaction) = envelope.event {
                return interaction
            }
        }
        return nil
    }
}
