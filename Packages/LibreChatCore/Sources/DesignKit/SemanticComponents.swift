import SwiftUI

public struct ServerBadge: View {
    private let name: String
    private let isSecure: Bool

    public init(name: String, isSecure: Bool = true) {
        self.name = name
        self.isSecure = isSecure
    }

    public var body: some View {
        Label(name, systemImage: isSecure ? "lock.fill" : "hammer.fill")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Server: \(name)")
    }
}

public struct CodeBlock: View {
    private let language: String?
    private let code: String

    public init(language: String? = nil, code: String) {
        self.language = language
        self.code = code
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Code\(language.map { " in \($0)" } ?? "")")
    }
}

public struct LoadingIndicator: View {
    private let label: String

    public init(_ label: String) { self.label = label }

    public var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

public struct SemanticEmptyState: View {
    private let title: String
    private let systemImage: String
    private let description: String

    public init(_ title: String, systemImage: String, description: String) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    public var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
    }
}

/// A compact, read-only description of the request that the composer will
/// submit. The initializer deliberately accepts only presentation primitives:
/// domain targets, uploads, credentials, and server URLs stay outside
/// DesignKit.
public struct ComposerExecutionSummaryPresentation: Equatable, Sendable {
    public let target: String
    public let attachments: String
    public let attachmentCount: Int
    public let serverHost: String
    public let executionCapabilities: [String]?

    public init(
        targetSpec: String?,
        model: String?,
        selectedAgentOrAssistant: String?,
        endpoint: String?,
        attachmentCount: Int,
        attachmentState: String?,
        serverHost: String?,
        executionCapabilities: [String]? = nil
    ) {
        target = Self.firstMeaningful(
            targetSpec,
            model,
            selectedAgentOrAssistant,
            endpoint
        ) ?? "Target unavailable"

        let count = max(0, attachmentCount)
        self.attachmentCount = count
        let state = Self.firstMeaningful(attachmentState)
        switch count {
        case 0:
            attachments = "No attachments"
        case 1:
            attachments = state.map { "1 attachment, \($0)" } ?? "1 attachment"
        default:
            attachments = state.map { "\(count) attachments, \($0)" } ?? "\(count) attachments"
        }

        self.serverHost = Self.firstMeaningful(serverHost) ?? "Server unavailable"
        if let executionCapabilities {
            var seen = Set<String>()
            self.executionCapabilities = executionCapabilities.compactMap { capability in
                guard let value = Self.firstMeaningful(capability),
                      seen.insert(value).inserted else { return nil }
                return value
            }
        } else {
            self.executionCapabilities = nil
        }
    }

    public var displayText: String {
        if attachmentCount == 0 {
            "\(target) · \(serverHost)"
        } else {
            "\(target) · \(attachments) · \(serverHost)"
        }
    }

    public var executionScopeDisplayText: String? {
        guard let executionCapabilities else { return nil }
        guard !executionCapabilities.isEmpty else { return "Tools: None" }
        return "Tools: \(executionCapabilities.joined(separator: " · "))"
    }

    public var supportingText: String {
        var parts: [String] = []
        if attachmentCount > 0 {
            parts.append(attachments)
        }
        if let executionScopeDisplayText {
            parts.append(executionScopeDisplayText)
        }
        parts.append(serverHost)
        return parts.joined(separator: " · ")
    }

    public var accessibilityLabel: String { "Message setup" }

    public var accessibilityValue: String {
        let base = "Target: \(target). Attachments: \(attachments). Server: \(serverHost)."
        guard let executionCapabilities else { return base }
        guard !executionCapabilities.isEmpty else { return "\(base) Tools: None." }
        return "\(base) Tools: \(executionCapabilities.joined(separator: ", "))."
    }

    private static func firstMeaningful(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}

/// A semantic composer affordance rather than a general-purpose visual card.
/// It intentionally conveys execution context without adding controls or
/// initiating any work.
public struct ComposerExecutionSummary: View {
    private let presentation: ComposerExecutionSummaryPresentation

    public init(
        targetSpec: String?,
        model: String?,
        selectedAgentOrAssistant: String?,
        endpoint: String?,
        attachmentCount: Int,
        attachmentState: String?,
        serverHost: String?,
        executionCapabilities: [String]? = nil
    ) {
        presentation = ComposerExecutionSummaryPresentation(
            targetSpec: targetSpec,
            model: model,
            selectedAgentOrAssistant: selectedAgentOrAssistant,
            endpoint: endpoint,
            attachmentCount: attachmentCount,
            attachmentState: attachmentState,
            serverHost: serverHost,
            executionCapabilities: executionCapabilities
        )
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .imageScale(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.displayText)
                if let executionScope = presentation.executionScopeDisplayText {
                    Text(executionScope)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityIdentifier("execution-envelope")
    }
}

/// The execution envelope as a first-class composer control. The whole
/// truthful summary is interactive so state and action are not split between
/// a label and a separate, ambiguous icon button.
public struct ComposerExecutionControl: View {
    private let presentation: ComposerExecutionSummaryPresentation
    private let hint: String
    private let action: () -> Void

    public init(
        targetSpec: String?,
        model: String?,
        selectedAgentOrAssistant: String?,
        endpoint: String?,
        attachmentCount: Int,
        attachmentState: String?,
        serverHost: String?,
        executionCapabilities: [String]? = nil,
        hint: String,
        action: @escaping () -> Void
    ) {
        presentation = ComposerExecutionSummaryPresentation(
            targetSpec: targetSpec,
            model: model,
            selectedAgentOrAssistant: selectedAgentOrAssistant,
            endpoint: endpoint,
            attachmentCount: attachmentCount,
            attachmentState: attachmentState,
            serverHost: serverHost,
            executionCapabilities: executionCapabilities
        )
        self.hint = hint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.forward.app")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.target)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(presentation.supportingText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                .secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(hint)
        .accessibilityIdentifier("execution-envelope")
    }
}

private struct ComposerChromeModifier<SurfaceShape: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: SurfaceShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: shape)
                .overlay { shape.stroke(.primary.opacity(0.18), lineWidth: 1) }
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            // ChatGPT-style neutral field rather than a translucent blur.
            content
                .background(.fill.quaternary, in: shape)
                .overlay { shape.stroke(.primary.opacity(0.08), lineWidth: 0.5) }
        }
    }
}

public extension View {
    func composerChrome<S: Shape>(in shape: S) -> some View {
        modifier(ComposerChromeModifier(shape: shape))
    }
}
