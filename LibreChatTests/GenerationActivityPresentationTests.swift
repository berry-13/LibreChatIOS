import DesignKit
import LibreChatDomain
import XCTest
@testable import LibreChat

final class GenerationActivityProjectionTests: XCTestCase {
    func testAccessibilityAnnouncementStateDeduplicatesUntilCleared() {
        var state = AccessibilityAnnouncementState()

        XCTAssertEqual(state.announcement(for: "Connection failed"), "Connection failed")
        XCTAssertNil(state.announcement(for: "Connection failed"))
        XCTAssertEqual(state.announcement(for: "A different error"), "A different error")
        XCTAssertNil(state.announcement(for: nil))
        XCTAssertEqual(state.announcement(for: "Connection failed"), "Connection failed")
    }

    func testPendingInteractionAccessibilityProjectionIsPrivacyBoundedAndPayloadSensitive() {
        let first = PendingInteraction.userQuestion(UserQuestion(
            id: "question",
            prompt: "Private prompt one",
            options: []
        ))
        let changed = PendingInteraction.userQuestion(UserQuestion(
            id: "question",
            prompt: "Private prompt two",
            options: []
        ))

        let firstPresentation = PendingInteractionAccessibilityPresentation(
            handle: handle,
            interaction: first
        )
        let unchangedPresentation = PendingInteractionAccessibilityPresentation(
            handle: handle,
            interaction: first
        )
        let changedPresentation = PendingInteractionAccessibilityPresentation(
            handle: handle,
            interaction: changed
        )

        XCTAssertEqual(firstPresentation.identity, unchangedPresentation.identity)
        XCTAssertNotEqual(firstPresentation.identity, changedPresentation.identity)
        XCTAssertEqual(
            firstPresentation.announcement,
            "LibreChat needs your answer. Review the question."
        )
        XCTAssertFalse(firstPresentation.announcement.contains("Private prompt"))
    }

    func testProjectionIsGroupedStableAndDoesNotExposeRawReasoningOrToolPayloads() throws {
        let snapshot = GenerationSnapshot(
            handle: handle,
            state: .streaming,
            reasoning: "private chain of thought",
            runSteps: [
                RunStep(id: "shared", label: "Plan response", isComplete: true)
            ],
            toolCalls: [
                ToolCall(
                    id: "shared",
                    name: "Search workspace",
                    status: .running,
                    summary: "Reviewing matching files",
                    duration: 1.6,
                    input: "secret tool input",
                    output: "secret tool output",
                    progress: 0.5
                )
            ],
            activities: [
                MessageActivityContent(
                    id: "shared",
                    label: "Researcher is working",
                    status: "running",
                    isPending: true
                )
            ],
            usage: TokenUsage(inputTokens: 120, outputTokens: nil),
            contextUsage: ContextUsage(remainingTokens: 9_000)
        )

        let presentation = GenerationActivityProjection(snapshot: snapshot).presentation
        let items = presentation.items

        XCTAssertEqual(presentation.phase, .working)
        // Server run-steps are deliberately not projected; the response text
        // is the surface and tools/agent phases carry progress.
        XCTAssertEqual(presentation.groups.map(\.title), ["Activity", "Tools", "Reasoning"])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertTrue(items.contains(where: { $0.id == "activity:shared" }))
        XCTAssertFalse(items.contains(where: { $0.id.hasPrefix("step:") }))
        XCTAssertTrue(items.contains(where: { $0.id == "tool:shared" }))
        XCTAssertEqual(presentation.tokenSummary, "120 input tokens")
        XCTAssertEqual(presentation.contextSummary, "Context: 9000 remaining")

        let visibleText = items
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: " ")
        XCTAssertFalse(visibleText.contains("private chain of thought"))
        XCTAssertFalse(visibleText.contains("secret tool input"))
        XCTAssertFalse(visibleText.contains("secret tool output"))
        XCTAssertTrue(visibleText.contains("Detailed model reasoning is not displayed"))
    }

    func testToolAndActivityStatesMapToFiniteUserFacingVocabulary() throws {
        let snapshot = GenerationSnapshot(
            handle: handle,
            state: .completed,
            toolCalls: [
                ToolCall(id: "approval", name: "Publish", status: .awaitingApproval),
                ToolCall(id: "failed", name: "Fetch", status: .failed, progress: .nan)
            ],
            activities: [
                MessageActivityContent(
                    id: "opaque",
                    label: "Agent update",
                    status: "provider_internal_73",
                    isPending: false
                )
            ]
        )

        let items = GenerationActivityProjection(snapshot: snapshot).presentation.items

        XCTAssertEqual(items.first(where: { $0.id == "tool:approval" })?.state, .attention)
        XCTAssertEqual(items.first(where: { $0.id == "tool:failed" })?.state, .failed)
        XCTAssertNil(items.first(where: { $0.id == "tool:failed" })?.progress)
        XCTAssertEqual(items.first(where: { $0.id == "activity:opaque" })?.state, .informational)
        XCTAssertFalse(items.compactMap(\.detail).contains("provider_internal_73"))
    }

    func testDirectionsRetainOwnershipStateWithoutExposingIdentifiers() throws {
        let applied = SteerEvent(id: "server-applied", text: "Use the release branch")
        let pending = PendingSteer(
            id: "server-pending",
            clientSteerID: "client-pending",
            text: "Check tests"
        )
        let recoverable = PendingSteer(
            id: "server-recoverable",
            clientSteerID: "client-recoverable",
            text: "Include migration notes"
        )
        let snapshot = GenerationSnapshot(
            handle: handle,
            state: .reconciling,
            appliedSteers: [applied],
            pendingSteers: [pending],
            recoverableSteers: [recoverable]
        )

        let presentation = GenerationActivityProjection(snapshot: snapshot).presentation
        let directions = try XCTUnwrap(presentation.groups.first(where: { $0.id == "directions" }))

        XCTAssertEqual(directions.items.map(\.state), [.completed, .pending, .attention])
        XCTAssertEqual(
            directions.items.map(\.title),
            ["Direction applied", "Direction queued", "Direction needs review"]
        )
        let rendered = directions.items
            .flatMap { [$0.title, $0.detail ?? ""] }
            .joined(separator: " ")
        XCTAssertFalse(rendered.contains("server-applied"))
        XCTAssertFalse(rendered.contains("client-pending"))
    }

    func testGenerationStatesHaveTruthfulSemanticPhases() {
        let interaction = PendingInteraction.userQuestion(UserQuestion(
            id: "question",
            prompt: "Continue?",
            options: []
        ))
        let states: [(GenerationState, GenerationActivityPhase)] = [
            (.starting, .starting),
            (.streaming, .working),
            (.awaitingApproval(interaction), .needsAttention),
            (.stopping, .stopping),
            (.reconnecting(attempt: 2), .reconnecting),
            (.reconciling, .reconciling),
            (.superseded, .superseded),
            (.completed, .completed),
            (.aborted, .stopped),
            (.failed(GenerationFailure(code: "failed", message: "Failed", isRecoverable: true)), .failed)
        ]

        for (state, expected) in states {
            let snapshot = GenerationSnapshot(handle: handle, state: state)
            XCTAssertEqual(GenerationActivityProjection(snapshot: snapshot).presentation.phase, expected)
        }
    }

    func testStreamingTextAndHiddenPayloadChurnDoNotInvalidateActivitySubtree() {
        let first = GenerationSnapshot(
            handle: handle,
            state: .streaming,
            response: ChatMessage(
                id: MessageID(rawValue: "assistant"),
                conversationID: handle.conversationID,
                content: [.text("First token")],
                author: .assistant(name: "Assistant")
            ),
            reasoning: "first private delta",
            toolCalls: [
                ToolCall(
                    id: "tool",
                    name: "Search",
                    status: .running,
                    summary: "Searching",
                    input: "first private input",
                    output: "first private output"
                )
            ]
        )
        let second = GenerationSnapshot(
            handle: handle,
            state: .streaming,
            response: ChatMessage(
                id: MessageID(rawValue: "assistant"),
                conversationID: handle.conversationID,
                content: [.text("A much longer streamed answer")],
                author: .assistant(name: "Assistant")
            ),
            reasoning: "different private delta",
            toolCalls: [
                ToolCall(
                    id: "tool",
                    name: "Search",
                    status: .running,
                    summary: "Searching",
                    input: "different private input",
                    output: "different private output"
                )
            ]
        )

        XCTAssertEqual(
            GenerationActivitySource(snapshot: first),
            GenerationActivitySource(snapshot: second)
        )
    }

    func testSubagentWorkUsesDedicatedSemanticGroupWithoutIdentifiersOrPayloads() throws {
        let snapshot = GenerationSnapshot(
            handle: handle,
            state: .streaming,
            activities: [
                MessageActivityContent(
                    id: "subagent:private-tool-call",
                    label: "Private provider label",
                    status: "run_step",
                    isPending: true,
                    agentID: "private-agent-id",
                    subagent: SubagentActivityMetadata(
                        phase: .runningStep,
                        typeLabel: "private-agent-type",
                        toolNames: ["Search", "Calculator", "Files", "Fourth tool"],
                        hasProducedText: true,
                        hasProducedReasoning: true
                    )
                )
            ]
        )

        let presentation = GenerationActivityProjection(snapshot: snapshot).presentation
        let agents = try XCTUnwrap(presentation.groups.first(where: { $0.id == "agents" }))
        let item = try XCTUnwrap(agents.items.first)

        XCTAssertNil(presentation.groups.first(where: { $0.id == "activities" }))
        XCTAssertEqual(agents.title, "Agents")
        XCTAssertEqual(item.title, "Agent working")
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(item.detail, "Tools: Search, Calculator, Files and 1 more")
        let visible = [item.title, item.detail ?? ""].joined(separator: " ")
        XCTAssertFalse(visible.contains("private-tool-call"))
        XCTAssertFalse(visible.contains("private-agent-id"))
        XCTAssertFalse(visible.contains("private-agent-type"))
        XCTAssertFalse(visible.contains("Private provider label"))
    }

    func testSubagentPhasesUseFiniteTruthfulPresentationStates() {
        let cases: [(SubagentActivityPhase, String, GenerationActivityItemState)] = [
            (.started, "Agent started", .running),
            (.runningStep, "Agent working", .running),
            (.updatingStep, "Agent working", .running),
            (.completedStep, "Agent completed a step", .running),
            (.writing, "Agent preparing a response", .running),
            (.reasoning, "Agent planning", .running),
            (.completed, "Agent finished", .completed),
            (.failed, "Agent failed", .failed),
            (.unknown, "Agent activity", .informational)
        ]

        for (phase, title, state) in cases {
            let snapshot = GenerationSnapshot(
                handle: handle,
                state: .streaming,
                activities: [
                    MessageActivityContent(
                        id: "subagent:one",
                        label: "Ignored raw label",
                        status: "provider-private",
                        subagent: SubagentActivityMetadata(phase: phase)
                    )
                ]
            )
            let item = GenerationActivityProjection(snapshot: snapshot).presentation.items.first
            XCTAssertEqual(item?.title, title)
            XCTAssertEqual(item?.state, state)
        }
    }

    func testPersistedSubagentTracePresentationExcludesPrivateToolPayloadsAndIdentifiers() throws {
        let call = ToolCall(
            id: "private-server-tool-call-id",
            name: "private raw subagent tool name",
            status: .completed,
            summary: "private nested transcript",
            input: "private nested arguments",
            output: "private nested output",
            authorizationURL: URL(string: "https://private.invalid/authorize?secret=value"),
            subagentTrace: SubagentTraceSummary(
                toolNames: ["Search", "Files"],
                hasResponseText: true,
                hasReasoning: true
            )
        )

        let presentation = try XCTUnwrap(SubagentTracePresentation(call: call))

        XCTAssertEqual(presentation.title, "Agent task")
        XCTAssertEqual(presentation.state, .completed)
        XCTAssertEqual(presentation.toolNames, ["Search", "Files"])
        XCTAssertEqual(
            presentation.accessibilityValue,
            "Completed, Produced a response, Reasoning details hidden, 2 tools"
        )
        let exposed = ([presentation.title, presentation.accessibilityValue] + presentation.toolNames)
            .joined(separator: " ")
        for secret in [
            call.id,
            call.name,
            call.summary,
            call.input,
            call.output,
            call.authorizationURL?.absoluteString
        ].compactMap({ $0 }) {
            XCTAssertFalse(exposed.contains(secret))
        }
    }

    func testPersistedSubagentTraceStatesAreFiniteAndProgressCanProveCompletion() throws {
        let cases: [(ToolCall.Status, Double?, SubagentTracePresentation.State)] = [
            (.pending, nil, .queued),
            (.running, nil, .working),
            (.running, 0.99, .working),
            (.running, 1, .completed),
            (.running, .infinity, .working),
            (.awaitingApproval, nil, .needsAttention),
            (.completed, nil, .completed),
            (.failed, nil, .failed)
        ]

        for (status, progress, expected) in cases {
            let presentation = try XCTUnwrap(SubagentTracePresentation(call: ToolCall(
                id: "ignored",
                name: "ignored",
                status: status,
                progress: progress,
                subagentTrace: SubagentTraceSummary()
            )))
            XCTAssertEqual(presentation.state, expected)
        }
    }

    func testPersistedSubagentToolNamesAreSanitizedDeduplicatedAndBounded() throws {
        let longName = String(repeating: "x", count: 90)
        let presentation = try XCTUnwrap(SubagentTracePresentation(call: ToolCall(
            id: "ignored",
            name: "ignored",
            status: .completed,
            subagentTrace: SubagentTraceSummary(
                toolNames: [
                    "  Search\nworkspace\u{0000}  ",
                    "Search workspace",
                    longName,
                    "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"
                ]
            )
        )))

        XCTAssertEqual(presentation.toolNames.count, 8)
        XCTAssertEqual(presentation.toolNames.first, "Search workspace")
        XCTAssertEqual(presentation.toolNames[1].count, 80)
        XCTAssertTrue(presentation.toolNames[1].hasSuffix("…"))
        XCTAssertEqual(presentation.omittedToolCount, 2)
        XCTAssertEqual(presentation.accessibilityValue, "Completed, 10 tools")
        XCTAssertFalse(presentation.toolNames.joined().contains("\n"))
        XCTAssertFalse(presentation.toolNames.joined().contains("\u{0000}"))
    }

    func testOrdinaryToolCallDoesNotUseSubagentTracePresentation() {
        XCTAssertNil(SubagentTracePresentation(call: ToolCall(
            id: "tool",
            name: "Search",
            status: .completed,
            summary: "Normal tool summary"
        )))
    }

    private var handle: GenerationHandle {
        GenerationHandle(
            profileID: ServerProfileID(rawValue: "11111111-1111-1111-1111-111111111111"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            streamID: "stream",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 1_720_000_000_000,
            protocolVersion: 2
        )
    }
}
