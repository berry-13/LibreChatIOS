import Foundation
import LibreChatDomain
import LibreChatTestSupport
import Testing
@testable import LibreChatProtocol

@Suite("Subagent activity contract")
struct SubagentActivityContractTests {
    private let decoder = LibreChatGenerationDecoder()

    @Test func exactEnvelopeMapsToStablePrivacyBoundedActivity() throws {
        let json = #"{"event":"on_subagent_update","data":{"runId":"parent-private","subagentRunId":"child-private","parentToolCallId":"call-private","subagentType":"researcher","subagentAgentId":"agent-private","phase":"run_step","label":"Searching sources","data":{"stepDetails":{"type":"tool_calls","tool_calls":[{"id":"inner-private","name":"web_search","args":{"secret":"do not retain"}},{"id":"inner-2","name":"calculator","args":"private"}]}}}}"#

        let events = decoder.decode(
            .init(id: "1", data: json),
            conversationID: LibreChatFixtures.handle.conversationID
        )
        let activity = try #require(events.compactMap { envelope -> MessageActivityContent? in
            guard case let .activity(value) = envelope.event else { return nil }
            return value
        }.first)

        #expect(activity.id.hasPrefix("subagent:"))
        #expect(!activity.id.contains("call-private"))
        #expect(activity.label == "Searching sources")
        #expect(activity.isPending)
        #expect(activity.agentID == nil)
        #expect(activity.subagent == SubagentActivityMetadata(
            phase: .runningStep,
            typeLabel: "researcher",
            toolNames: ["web_search", "calculator"]
        ))

        let encoded = try JSONEncoder().encode(activity)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        #expect(!encodedText.contains("parent-private"))
        #expect(!encodedText.contains("child-private"))
        #expect(!encodedText.contains("agent-private"))
        #expect(!encodedText.contains("call-private"))
        #expect(!encodedText.contains("inner-private"))
        #expect(!encodedText.contains("do not retain"))
    }

    @Test func phasesMergeIntoOneRunWithoutLosingSemanticHistory() throws {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(phase: "start", nestedData: "{}", id: "1", to: &reducer)
        apply(
            phase: "run_step",
            nestedData: #"{"stepDetails":{"type":"tool_calls","tool_calls":[{"id":"one","name":"search","args":{"private":true}}]}}"#,
            id: "2",
            to: &reducer
        )
        apply(
            phase: "message_delta",
            nestedData: #"{"delta":{"content":[{"type":"text","text":"private child answer"}]}}"#,
            id: "3",
            to: &reducer
        )
        apply(
            phase: "reasoning_delta",
            nestedData: #"{"delta":{"content":[{"type":"think","think":"private reasoning"}]}}"#,
            id: "4",
            to: &reducer
        )
        apply(phase: "stop", nestedData: "{}", id: "5", to: &reducer)

        let activity = try #require(reducer.snapshot.activities.first)
        let subagent = try #require(activity.subagent)
        #expect(reducer.snapshot.activities.count == 1)
        #expect(activity.id.hasPrefix("subagent:"))
        #expect(!activity.id.contains("call-1"))
        #expect(activity.isPending == false)
        #expect(subagent.phase == .completed)
        #expect(subagent.toolNames == ["search"])
        #expect(subagent.hasProducedText)
        #expect(subagent.hasProducedReasoning)
        #expect(!String(describing: activity).contains("private child answer"))
        #expect(!String(describing: activity).contains("private reasoning"))
    }

    @Test func concurrentChildrenRemainSeparatedByParentToolCall() {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(phase: "start", nestedData: "{}", id: "1", toolCallID: "call-a", runID: "child-a", to: &reducer)
        apply(phase: "start", nestedData: "{}", id: "2", toolCallID: "call-b", runID: "child-b", to: &reducer)

        let ids = reducer.snapshot.activities.map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.allSatisfy { $0.hasPrefix("subagent:") })
        #expect(ids.allSatisfy { !$0.contains("call-") && !$0.contains("child-") })
    }

    @Test func missingChildRunIdentityFailsClosed() {
        let json = #"{"event":"on_subagent_update","data":{"phase":"start","label":"Agent started"}}"#
        let events = decoder.decode(
            .init(data: json),
            conversationID: LibreChatFixtures.handle.conversationID
        )
        #expect(!events.contains { if case .activity = $0.event { true } else { false } })
    }

    @Test func unknownPhaseStaysInformationalAndNonterminal() throws {
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        apply(phase: "future_phase", nestedData: "{}", id: "1", to: &reducer)
        let activity = try #require(reducer.snapshot.activities.first)
        #expect(activity.status == "future_phase")
        #expect(activity.isPending)
        #expect(activity.subagent?.phase == .unknown)
    }

    @Test func legacyCachedActivityDecodesWithoutTypedMetadata() throws {
        let data = Data(#"{"id":"legacy","label":"Working","status":"running","isPending":true}"#.utf8)
        let activity = try JSONDecoder().decode(MessageActivityContent.self, from: data)
        #expect(activity.subagent == nil)
    }

    @Test func persistedChildTraceRetainsOnlySemanticPresenceAndToolNames() throws {
        let raw: JSONValue = .object([
            "type": .string("tool_call"),
            "tool_call": .object([
                "id": .string("parent-call"),
                "name": .string("subagent"),
                "progress": .number(1),
                "subagent_content": .array([
                    .object(["type": .string("think"), "think": .string("private reasoning")]),
                    .object(["type": .string("text"), "text": .string("private result")]),
                    .object([
                        "type": .string("tool_call"),
                        "tool_call": .object([
                            "id": .string("inner-private"),
                            "name": .string("web_search"),
                            "args": .object(["secret": .string("private")]),
                            "output": .string("private output")
                        ])
                    ])
                ])
            ])
        ])

        let content = LibreChatMessageDTO.domainContent(from: [raw])
        guard case let .tool(call) = try #require(content.first) else {
            Issue.record("Expected a tool call")
            return
        }
        #expect(call.subagentTrace == SubagentTraceSummary(
            toolNames: ["web_search"],
            hasResponseText: true,
            hasReasoning: true
        ))
        let encoded = String(decoding: try JSONEncoder().encode(call.subagentTrace), as: UTF8.self)
        #expect(!encoded.contains("private reasoning"))
        #expect(!encoded.contains("private result"))
        #expect(!encoded.contains("private output"))
        #expect(!encoded.contains("inner-private"))
    }

    @Test func authoritativeSyncRebuildsCompletedSubagentSemantics() throws {
        let json = #"{"sync":true,"resumeState":{"aggregatedContent":[{"type":"tool_call","tool_call":{"id":"parent-call","name":"subagent","progress":1,"subagent_content":[{"type":"text","text":"private result"},{"type":"tool_call","tool_call":{"id":"inner","name":"files","args":{"secret":true},"output":"private"}}]}}]}}"#
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)
        for event in decoder.decode(
            .init(id: "sync", data: json),
            conversationID: reducer.snapshot.handle.conversationID
        ) {
            reducer.apply(event)
        }

        let activity = try #require(reducer.snapshot.activities.first)
        #expect(activity.subagent == SubagentActivityMetadata(
            phase: .completed,
            toolNames: ["files"],
            hasProducedText: true,
            hasProducedReasoning: false
        ))
        #expect(activity.isPending == false)
        #expect(!activity.id.contains("parent-call"))
    }

    private func apply(
        phase: String,
        nestedData: String,
        id: String,
        toolCallID: String = "call-1",
        runID: String = "child-1",
        to reducer: inout GenerationReducer
    ) {
        guard let nestedBytes = nestedData.data(using: .utf8),
              let nested = try? JSONSerialization.jsonObject(with: nestedBytes),
              JSONSerialization.isValidJSONObject(nested) else {
            Issue.record("Invalid nested subagent fixture")
            return
        }
        let envelope: [String: Any] = [
            "event": "on_subagent_update",
            "data": [
                "runId": "parent",
                "subagentRunId": runID,
                "parentToolCallId": toolCallID,
                "subagentType": "self",
                "subagentAgentId": "private-agent",
                "phase": phase,
                "data": nested
            ]
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: bytes, encoding: .utf8) else {
            Issue.record("Could not encode subagent fixture")
            return
        }
        for event in decoder.decode(
            .init(id: id, data: json),
            conversationID: reducer.snapshot.handle.conversationID
        ) {
            reducer.apply(event)
        }
    }
}
