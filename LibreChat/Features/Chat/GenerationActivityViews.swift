import DesignKit
import LibreChatDomain
import SwiftUI

struct GenerationActivitySignalSource: Equatable, Sendable {
    let id: String
    let label: String
    let state: GenerationActivityItemState
    let subagent: SubagentActivityMetadata?
}

struct GenerationActivityToolSource: Equatable, Sendable {
    let id: String
    let name: String
    let status: ToolCall.Status
    let summary: String?
    let duration: TimeInterval?
    let progress: Double?
    let requiresAuthentication: Bool
}

struct GenerationActivityDirectionSource: Equatable, Sendable {
    let id: String
    let title: String
    let text: String?
    let state: GenerationActivityItemState
}

struct GenerationActivitySource: Equatable, Sendable {
    let handle: GenerationHandle
    let state: GenerationState
    let hasReasoning: Bool
    let runSteps: [RunStep]
    let tools: [GenerationActivityToolSource]
    let activities: [GenerationActivitySignalSource]
    let pendingInteraction: PendingInteraction?
    let usage: TokenUsage?
    let contextUsage: ContextUsage?
    let directions: [GenerationActivityDirectionSource]

    init(snapshot: GenerationSnapshot) {
        handle = snapshot.handle
        state = snapshot.state
        hasReasoning = !snapshot.reasoning.isEmpty
        runSteps = snapshot.runSteps
        tools = snapshot.toolCalls.map { call in
            GenerationActivityToolSource(
                id: call.id,
                name: call.name,
                status: call.status,
                summary: call.summary,
                duration: call.duration,
                progress: call.progress,
                requiresAuthentication: call.authorizationURL != nil
            )
        }
        activities = snapshot.activities.map { activity in
            GenerationActivitySignalSource(
                id: activity.id,
                label: activity.label,
                state: Self.activityState(
                    isPending: activity.isPending,
                    status: activity.status
                ),
                subagent: activity.subagent
            )
        }
        pendingInteraction = snapshot.pendingInteraction
        usage = snapshot.usage
        contextUsage = snapshot.contextUsage
        directions = snapshot.appliedSteers.map { steer in
            GenerationActivityDirectionSource(
                id: "applied:\(steer.id)",
                title: "Direction applied",
                text: steer.text,
                state: .completed
            )
        } + snapshot.pendingSteers.map { steer in
            GenerationActivityDirectionSource(
                id: "pending:\(steer.id)",
                title: "Direction queued",
                text: steer.text,
                state: .pending
            )
        } + snapshot.recoverableSteers.map { steer in
            GenerationActivityDirectionSource(
                id: "recoverable:\(steer.id)",
                title: "Direction needs review",
                text: steer.text,
                state: .attention
            )
        }
    }

    private static func activityState(
        isPending: Bool,
        status: String?
    ) -> GenerationActivityItemState {
        if isPending { return .running }
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending", "queued", "waiting": return .pending
        case "running", "working", "in progress", "in_progress": return .running
        case "approval", "awaiting approval", "requires action", "requires_action": return .attention
        case "ok", "done", "success", "completed", "complete": return .completed
        case "failed", "failure", "error": return .failed
        case "stopped", "cancelled", "canceled", "aborted": return .stopped
        default: return .informational
        }
    }
}

struct GenerationActivityProjection: Equatable, Sendable {
    let presentation: GenerationActivityPresentation

    init(snapshot: GenerationSnapshot) {
        self.init(source: GenerationActivitySource(snapshot: snapshot))
    }

    init(source: GenerationActivitySource) {
        let phase = Self.phase(for: source.state)
        var groups: [GenerationActivityGroup] = []

        Self.appendGroup(
            id: "activities",
            title: "Activity",
            items: source.activities.filter { $0.subagent == nil }.compactMap(Self.activityItem),
            to: &groups
        )
        Self.appendGroup(
            id: "agents",
            title: "Agents",
            items: source.activities.compactMap(Self.subagentItem),
            to: &groups
        )
        // Server run-steps ("Agent step" rows) are intentionally not
        // projected: the response text is the surface; tools and agent
        // phases carry the meaningful progress.
        Self.appendGroup(
            id: "tools",
            title: "Tools",
            items: source.tools.compactMap(Self.toolItem),
            to: &groups
        )

        let directions = source.directions.compactMap { direction in
            GenerationActivityItem(
                id: "direction:\(direction.id)",
                title: direction.title,
                detail: direction.text,
                state: direction.state
            )
        }
        Self.appendGroup(
            id: "directions",
            title: "Directions",
            items: directions,
            to: &groups
        )

        if source.hasReasoning,
           let reasoning = GenerationActivityItem(
                id: "reasoning",
                title: "Reasoning",
                detail: "Detailed model reasoning is not displayed.",
                state: Self.reasoningState(for: phase)
           ) {
            Self.appendGroup(
                id: "reasoning",
                title: "Reasoning",
                items: [reasoning],
                to: &groups
            )
        }

        presentation = GenerationActivityPresentation(
            phase: phase,
            groups: groups,
            tokenSummary: Self.tokenSummary(source.usage),
            contextSummary: Self.contextSummary(source.contextUsage)
        )
    }

    private static func appendGroup(
        id: String,
        title: String,
        items: [GenerationActivityItem],
        to groups: inout [GenerationActivityGroup]
    ) {
        guard let group = GenerationActivityGroup(id: id, title: title, items: items) else {
            return
        }
        groups.append(group)
    }

    private static func phase(for state: GenerationState) -> GenerationActivityPhase {
        switch state {
        case .starting: .starting
        case .streaming: .working
        case .awaitingApproval: .needsAttention
        case .stopping: .stopping
        case .reconnecting: .reconnecting
        case .reconciling: .reconciling
        case .superseded: .superseded
        case .completed: .completed
        case .aborted: .stopped
        case .failed: .failed
        }
    }

    private static func activityItem(_ activity: GenerationActivitySignalSource) -> GenerationActivityItem? {
        GenerationActivityItem(
            id: "activity:\(activity.id)",
            title: activity.label,
            state: activity.state
        )
    }

    private static func subagentItem(
        _ activity: GenerationActivitySignalSource
    ) -> GenerationActivityItem? {
        guard let subagent = activity.subagent else { return nil }
        let title: String
        let state: GenerationActivityItemState
        switch subagent.phase {
        case .started:
            title = "Agent started"
            state = .running
        case .runningStep, .updatingStep:
            title = "Agent working"
            state = .running
        case .completedStep:
            title = "Agent completed a step"
            state = .running
        case .writing:
            title = "Agent preparing a response"
            state = .running
        case .reasoning:
            title = "Agent planning"
            state = .running
        case .completed:
            title = "Agent finished"
            state = .completed
        case .failed:
            title = "Agent failed"
            state = .failed
        case .unknown:
            title = "Agent activity"
            state = activity.state
        }

        let visibleTools = Array(subagent.toolNames.prefix(3))
        let remaining = subagent.toolNames.count - visibleTools.count
        let toolDetail: String? = if visibleTools.isEmpty {
            nil
        } else if remaining > 0 {
            "Tools: \(visibleTools.joined(separator: ", ")) and \(remaining) more"
        } else {
            "Tools: \(visibleTools.joined(separator: ", "))"
        }
        return GenerationActivityItem(
            id: "agent:\(activity.id)",
            title: title,
            detail: toolDetail,
            state: state
        )
    }

    private static func toolItem(_ call: GenerationActivityToolSource) -> GenerationActivityItem? {
        let authenticationDetail = !call.requiresAuthentication
            ? nil
            : "Authentication is required in the LibreChat web client."
        let detail = [call.summary, authenticationDetail]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " ")
        return GenerationActivityItem(
            id: "tool:\(call.id)",
            title: call.name,
            detail: detail.isEmpty ? nil : detail,
            state: toolState(call.status),
            progress: call.progress,
            duration: call.duration
        )
    }

    private static func toolState(_ status: ToolCall.Status) -> GenerationActivityItemState {
        switch status {
        case .pending: .pending
        case .running: .running
        case .awaitingApproval: .attention
        case .completed: .completed
        case .failed: .failed
        }
    }

    private static func reasoningState(
        for phase: GenerationActivityPhase
    ) -> GenerationActivityItemState {
        switch phase {
        case .completed: .completed
        case .stopped, .superseded: .stopped
        case .failed: .failed
        case .needsAttention: .pending
        default: .running
        }
    }

    private static func tokenSummary(_ usage: TokenUsage?) -> String? {
        guard let usage else { return nil }
        let input = validCount(usage.inputTokens)
        let output = validCount(usage.outputTokens)
        switch (input, output) {
        case let (.some(input), .some(output)):
            return "\(input) input · \(output) output tokens"
        case let (.some(input), nil):
            return "\(input) input tokens"
        case let (nil, .some(output)):
            return "\(output) output tokens"
        case (nil, nil):
            return nil
        }
    }

    private static func contextSummary(_ usage: ContextUsage?) -> String? {
        guard let usage else { return nil }
        var values: [String] = []
        if let messageTokens = validCount(usage.messageTokens) {
            values.append("\(messageTokens) message tokens")
        }
        if let instructionTokens = validCount(usage.instructionTokens) {
            values.append("\(instructionTokens) instruction tokens")
        }
        if let remainingTokens = validCount(usage.remainingTokens) {
            values.append("\(remainingTokens) remaining")
        }
        if let maximumTokens = validCount(usage.maximumTokens) {
            values.append("\(maximumTokens) maximum")
        }
        if let toolCount = validCount(usage.toolCount) {
            values.append("\(toolCount) tools")
        }
        if let messageCount = validCount(usage.messageCount) {
            values.append("\(messageCount) messages")
        }
        return values.isEmpty ? nil : "Context: " + values.joined(separator: " · ")
    }

    private static func validCount(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

}

struct GenerationActivityView: View, @MainActor Equatable {
    let source: GenerationActivitySource
    let isResponding: Bool
    let respond: ([ToolApprovalResolution]?, String?, [String: String]?) -> Void
    @State private var lastAnnouncedInteraction: PendingInteractionIdentity?
    @AccessibilityFocusState private var isPendingInteractionFocused: Bool

    init(
        snapshot: GenerationSnapshot,
        isResponding: Bool,
        respond: @escaping ([ToolApprovalResolution]?, String?, [String: String]?) -> Void
    ) {
        source = GenerationActivitySource(snapshot: snapshot)
        self.isResponding = isResponding
        self.respond = respond
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ChatGPT-style presence: a single pulsing dot while the response
            // is being prepared or resumed. Once tokens flow, the streamed
            // text itself is the surface, and the old activity card is gone.
            if showsThinkingDot {
                GenerationPulsingDot()
            }

            if let interaction = source.pendingInteraction,
               source.state == .awaitingApproval(interaction) {
                let accessibility = PendingInteractionAccessibilityPresentation(
                    handle: source.handle,
                    interaction: interaction
                )
                PendingInteractionView(
                    interaction: interaction,
                    isResponding: isResponding,
                    respond: respond
                )
                .id(PendingInteractionIdentity(
                    handle: source.handle,
                    interaction: interaction
                ))
                .accessibilityFocused($isPendingInteractionFocused)
                .task(id: accessibility.identity) {
                    guard lastAnnouncedInteraction != accessibility.identity else { return }
                    lastAnnouncedInteraction = accessibility.identity
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    isPendingInteractionFocused = true
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: accessibility.announcement
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Phases where nothing is rendered yet and the dot is the only sign of
    /// life. Streaming hands presence to the response text; approvals hand
    /// it to the interaction card.
    private var showsThinkingDot: Bool {
        switch source.state {
        case .starting, .reconnecting, .reconciling: true
        default: false
        }
    }

    static func == (lhs: GenerationActivityView, rhs: GenerationActivityView) -> Bool {
        lhs.source == rhs.source && lhs.isResponding == rhs.isResponding
    }
}

/// A privacy-bounded accessibility projection for an actionable generation
/// pause. It intentionally does not repeat prompts, tool arguments, service
/// URLs, or server identifiers in the system announcement.
struct PendingInteractionAccessibilityPresentation: Equatable {
    let identity: PendingInteractionIdentity
    let announcement: String

    init(handle: GenerationHandle, interaction: PendingInteraction) {
        identity = PendingInteractionIdentity(handle: handle, interaction: interaction)
        announcement = switch interaction {
        case .toolApproval:
            "LibreChat needs your approval. Review the requested tool action."
        case .userQuestion:
            "LibreChat needs your answer. Review the question."
        case .externalAuthentication:
            "LibreChat needs external authentication. Review the request."
        }
    }
}

struct SubagentTracePresentation: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case queued = "Queued"
        case working = "In progress"
        case needsAttention = "Needs attention"
        case completed = "Completed"
        case failed = "Failed"
    }

    let title: String
    let state: State
    let toolNames: [String]
    let omittedToolCount: Int
    let hasResponseText: Bool
    let hasReasoning: Bool

    init?(call: ToolCall) {
        guard let trace = call.subagentTrace else { return nil }
        state = Self.state(for: call)
        title = "Agent task"

        var seen: Set<String> = []
        let sanitized = trace.toolNames.compactMap(Self.cleanedToolName).filter {
            seen.insert($0).inserted
        }
        toolNames = Array(sanitized.prefix(8))
        omittedToolCount = max(0, sanitized.count - toolNames.count)
        hasResponseText = trace.hasResponseText
        hasReasoning = trace.hasReasoning
    }

    var accessibilityValue: String {
        var values = [state.rawValue]
        if hasResponseText { values.append("Produced a response") }
        if hasReasoning { values.append("Reasoning details hidden") }
        let count = toolNames.count + omittedToolCount
        if count > 0 { values.append("\(count) \(count == 1 ? "tool" : "tools")") }
        return values.joined(separator: ", ")
    }

    private static func state(for call: ToolCall) -> State {
        switch call.status {
        case .failed: return .failed
        case .awaitingApproval: return .needsAttention
        case .completed: return .completed
        case .pending: return .queued
        case .running:
            if let progress = call.progress, progress.isFinite, progress >= 1 {
                return .completed
            }
            return .working
        }
    }

    private static func cleanedToolName(_ value: String) -> String? {
        let withoutControls = value.components(separatedBy: .controlCharacters).joined(separator: " ")
        let compact = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        guard compact.count > 80 else { return compact }
        return String(compact.prefix(79)) + "…"
    }
}

struct SubagentTraceCard: View {
    let presentation: SubagentTracePresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: presentation.state == .failed
                        ? "exclamationmark.triangle"
                        : "person.2")
                        .foregroundStyle(presentation.state == .failed ? Color.red : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .foregroundStyle(.primary)
                        Text(presentation.state.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent task")
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint(isExpanded
                ? "Collapse recorded activity details"
                : "Expand for recorded activity details")
            .accessibilityIdentifier("subagent-trace")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if presentation.hasResponseText {
                        Label("Produced a response", systemImage: "text.bubble")
                    }
                    if presentation.hasReasoning {
                        Label("Detailed reasoning is not displayed", systemImage: "lightbulb.min")
                    }
                    ForEach(presentation.toolNames, id: \.self) { name in
                        Label(name, systemImage: "wrench.and.screwdriver")
                    }
                    if presentation.omittedToolCount > 0 {
                        Text("\(presentation.omittedToolCount) more tools")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// ChatGPT-style "thinking" presence: a single monochrome dot that breathes
/// while a response is being prepared. Replaces the old activity card stack.
struct GenerationPulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.primary)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 0.72 : 1)
            .opacity(isPulsing ? 0.4 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .padding(.leading, 4)
            .accessibilityLabel("Generating response")
            .accessibilityAddTraits(.updatesFrequently)
    }
}
