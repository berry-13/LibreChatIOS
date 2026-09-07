import Foundation
import SwiftUI

public enum GenerationActivityPhase: String, Equatable, Hashable, Sendable {
    case starting
    case working
    case needsAttention
    case stopping
    case reconnecting
    case reconciling
    case completed
    case stopped
    case failed
    case superseded

    public var label: String {
        switch self {
        case .starting: "Starting response"
        case .working: "Working"
        case .needsAttention: "Needs your input"
        case .stopping: "Stopping"
        case .reconnecting: "Continuing on server"
        case .reconciling: "Checking latest result"
        case .completed: "Response complete"
        case .stopped: "Response stopped"
        case .failed: "Response could not finish"
        case .superseded: "Continued elsewhere"
        }
    }

    public var detail: String {
        switch self {
        case .starting: "LibreChat is preparing the response."
        case .working: "Response activity is updating."
        case .needsAttention: "Review the requested action below."
        case .stopping: "LibreChat is confirming the stop request."
        case .reconnecting: "The response can continue while this app reconnects."
        case .reconciling: "The app is rebuilding authoritative server state."
        case .completed: "The server confirmed this response."
        case .stopped: "Partial work remains available in the conversation."
        case .failed: "Review the recovery action shown with the response."
        case .superseded: "A different generation now owns this conversation."
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .starting: "hourglass"
        case .working: "sparkles"
        case .needsAttention: "hand.raised.fill"
        case .stopping: "stop.circle"
        case .reconnecting: "arrow.clockwise"
        case .reconciling: "arrow.clockwise.circle"
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .superseded: "arrow.left.arrow.right"
        }
    }

    fileprivate var tone: GenerationActivityTone {
        switch self {
        case .starting, .working, .reconnecting, .reconciling: .active
        case .needsAttention, .stopping: .attention
        case .completed: .success
        case .stopped, .superseded: .neutral
        case .failed: .failure
        }
    }
}

public enum GenerationActivityItemState: String, Equatable, Hashable, Sendable {
    case pending
    case running
    case attention
    case completed
    case stopped
    case failed
    case informational

    public var label: String {
        switch self {
        case .pending: "Waiting"
        case .running: "In progress"
        case .attention: "Needs attention"
        case .completed: "Completed"
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .informational: "Update"
        }
    }

    fileprivate var systemImage: String {
        switch self {
        case .pending: "clock"
        case .running: "circle.dotted"
        case .attention: "exclamationmark.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .failed: "xmark.circle.fill"
        case .informational: "info.circle.fill"
        }
    }

    fileprivate var tone: GenerationActivityTone {
        switch self {
        case .pending: .neutral
        case .running: .active
        case .attention: .attention
        case .completed: .success
        case .stopped, .informational: .neutral
        case .failed: .failure
        }
    }
}

public struct GenerationActivityItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let state: GenerationActivityItemState
    public let progress: Double?
    public let duration: TimeInterval?

    public init?(
        id: String,
        title: String,
        detail: String? = nil,
        state: GenerationActivityItemState,
        progress: Double? = nil,
        duration: TimeInterval? = nil
    ) {
        guard let id = SemanticActivityText.cleaned(id, limit: 256),
              let title = SemanticActivityText.cleaned(title, limit: 160) else {
            return nil
        }
        self.id = id
        self.title = title
        self.detail = SemanticActivityText.cleaned(detail, limit: 320)
        self.state = state
        if let progress, progress.isFinite, (0...1).contains(progress) {
            self.progress = progress
        } else {
            self.progress = nil
        }
        if let duration, duration.isFinite, duration >= 0 {
            self.duration = duration
        } else {
            self.duration = nil
        }
    }

    public var durationLabel: String? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        if duration < 1 { return "Under 1 second" }
        // Clamp before conversion: absurd server durations must not trap.
        let seconds = min(Int(duration.rounded()), 86_400 * 365)
        if seconds < 60 { return seconds == 1 ? "1 second" : "\(seconds) seconds" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        let minuteLabel = minutes == 1 ? "1 minute" : "\(minutes) minutes"
        guard remainder != 0 else { return minuteLabel }
        let secondLabel = remainder == 1 ? "1 second" : "\(remainder) seconds"
        return "\(minuteLabel), \(secondLabel)"
    }
}

public struct GenerationActivityGroup: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let items: [GenerationActivityItem]

    public init?(id: String, title: String, items: [GenerationActivityItem]) {
        guard let id = SemanticActivityText.cleaned(id, limit: 80),
              let title = SemanticActivityText.cleaned(title, limit: 80),
              !items.isEmpty else {
            return nil
        }
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct GenerationActivityPresentation: Equatable, Hashable, Sendable {
    public let phase: GenerationActivityPhase
    public let groups: [GenerationActivityGroup]
    public let tokenSummary: String?
    public let contextSummary: String?

    public init(
        phase: GenerationActivityPhase,
        groups: [GenerationActivityGroup],
        tokenSummary: String? = nil,
        contextSummary: String? = nil
    ) {
        self.phase = phase
        self.groups = groups
        self.tokenSummary = SemanticActivityText.cleaned(tokenSummary, limit: 200)
        self.contextSummary = SemanticActivityText.cleaned(contextSummary, limit: 240)
    }

    public var items: [GenerationActivityItem] {
        groups.flatMap(\.items)
    }

    public var isExpandable: Bool {
        !groups.isEmpty || tokenSummary != nil || contextSummary != nil
    }

    public var headerDetail: String {
        if let priority = items.reversed().first(where: {
            $0.state == .attention || $0.state == .failed
        }) {
            return "\(priority.title) · \(priority.state.label)"
        }
        if let active = items.reversed().first(where: {
            $0.state == .running || $0.state == .pending
        }) {
            return "\(active.title) · \(active.state.label)"
        }
        let tracked = items.filter { $0.state != .informational }
        if !tracked.isEmpty {
            let completed = tracked.filter { $0.state == .completed }.count
            return "\(completed) of \(tracked.count) steps completed"
        }
        return phase.detail
    }

    public var accessibilityLabel: String { "Response activity" }

    public var accessibilityValue: String {
        var values = [phase.label, headerDetail]
        if !items.isEmpty {
            values.append("\(items.count) activity items")
        }
        if let tokenSummary { values.append(tokenSummary) }
        if let contextSummary { values.append(contextSummary) }
        return values.joined(separator: ". ") + "."
    }
}

public struct GenerationActivityCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let presentation: GenerationActivityPresentation
    @State private var isExpanded = false

    public init(presentation: GenerationActivityPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.isExpandable {
                Button(action: toggleExpansion) {
                    GenerationActivityHeader(
                        presentation: presentation,
                        isExpanded: isExpanded
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)
                .accessibilityHint(isExpanded ? "Hides work details." : "Shows work details.")
            } else {
                GenerationActivityHeader(
                    presentation: presentation,
                    isExpanded: false,
                    showsDisclosure: false
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)
            }

            if isExpanded, presentation.isExpandable {
                Divider()
                    .padding(.horizontal, 14)
                GenerationActivityDetails(presentation: presentation)
                    .padding(14)
            }
        }
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.secondary.opacity(0.14), lineWidth: 0.5)
        }
        .accessibilityIdentifier("generation-activity")
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        }
    }
}

private struct GenerationActivityHeader: View {
    let presentation: GenerationActivityPresentation
    let isExpanded: Bool
    var showsDisclosure = true

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: presentation.phase.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(presentation.phase.tone.color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.phase.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(presentation.headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if showsDisclosure {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

private struct GenerationActivityDetails: View {
    let presentation: GenerationActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(presentation.groups) { group in
                VStack(alignment: .leading, spacing: 9) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(group.items) { item in
                        GenerationActivityItemRow(item: item)
                    }
                }
            }

            if presentation.tokenSummary != nil || presentation.contextSummary != nil {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    if let tokenSummary = presentation.tokenSummary {
                        Label(tokenSummary, systemImage: "number.circle")
                    }
                    if let contextSummary = presentation.contextSummary {
                        Label(contextSummary, systemImage: "gauge.with.dots.needle.50percent")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GenerationActivityItemRow: View {
    let item: GenerationActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.state.systemImage)
                .font(.subheadline)
                .foregroundStyle(item.state.tone.color)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(item.state.label)
                    if let duration = item.durationLabel {
                        Text("·")
                        Text(duration)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let progress = item.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Progress")
                        .accessibilityValue(
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                        )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(itemAccessibilityValue)
    }

    private var itemAccessibilityValue: String {
        [item.state.label, item.detail, item.durationLabel]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}

fileprivate enum GenerationActivityTone {
    case active
    case attention
    case success
    case failure
    case neutral

    var color: Color {
        switch self {
        case .active: .accentColor
        case .attention: .orange
        case .success: .green
        case .failure: .red
        case .neutral: .secondary
        }
    }
}

private enum SemanticActivityText {
    static func cleaned(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let scalars = value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                return " "
            }
            return Character(String(scalar))
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(max(1, limit - 1))) + "…"
    }
}
