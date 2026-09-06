import DesignKit
import LibreChatDomain
import SwiftUI
import UIKit

/// One chat row. Value-input equality (below) lets SwiftUI skip unchanged
/// rows entirely during streaming ticks — LibreChat-web memoizes rows the
/// same way (`MemoizedMultiMessage` field comparators).
struct MessageRow: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let onCitationSelected: (CitationSheetSelection) -> Void
    let onArtifactSelected: (ArtifactWorkspaceSelection) -> Void
    let onGeneratedFileSelected: (GeneratedFileSheetSelection) -> Void
    let messageEditSelections: [MessageTextEditSelection]
    let onMessageEditSelected: (MessageTextEditSelection) -> Void
    let promptResubmitSelection: PromptResubmitSelection?
    let onPromptResubmitSelected: (PromptResubmitSelection) -> Void
    let responseRegenerationSelection: ResponseRegenerationSelection?
    let onResponseRegenerationSelected: (ResponseRegenerationSelection) -> Void
    let conversationForkSelection: ConversationForkSelection?
    let onConversationForkSelected: (ConversationForkSelection) -> Void
    let positiveFeedbackSelection: MessageFeedbackSelection?
    let negativeFeedbackSelection: MessageFeedbackSelection?
    let onMessageFeedbackSelected: (MessageFeedbackSelection) -> Void
    let readAloudAction: ReadAloudActionPresentation?
    let onReadAloud: () -> Void
    let onChooseReadAloudVoice: () -> Void
    let allowsArtifactEditing: Bool

    init(
        message: ChatMessage,
        isStreaming: Bool,
        onCitationSelected: @escaping (CitationSheetSelection) -> Void,
        onArtifactSelected: @escaping (ArtifactWorkspaceSelection) -> Void,
        onGeneratedFileSelected: @escaping (GeneratedFileSheetSelection) -> Void,
        messageEditSelections: [MessageTextEditSelection] = [],
        onMessageEditSelected: @escaping (MessageTextEditSelection) -> Void = { _ in },
        promptResubmitSelection: PromptResubmitSelection? = nil,
        onPromptResubmitSelected: @escaping (PromptResubmitSelection) -> Void = { _ in },
        responseRegenerationSelection: ResponseRegenerationSelection? = nil,
        onResponseRegenerationSelected: @escaping (ResponseRegenerationSelection) -> Void = { _ in },
        conversationForkSelection: ConversationForkSelection? = nil,
        onConversationForkSelected: @escaping (ConversationForkSelection) -> Void = { _ in },
        positiveFeedbackSelection: MessageFeedbackSelection? = nil,
        negativeFeedbackSelection: MessageFeedbackSelection? = nil,
        onMessageFeedbackSelected: @escaping (MessageFeedbackSelection) -> Void = { _ in },
        readAloudAction: ReadAloudActionPresentation? = nil,
        onReadAloud: @escaping () -> Void = {},
        onChooseReadAloudVoice: @escaping () -> Void = {},
        allowsArtifactEditing: Bool = true
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.onCitationSelected = onCitationSelected
        self.onArtifactSelected = onArtifactSelected
        self.onGeneratedFileSelected = onGeneratedFileSelected
        self.messageEditSelections = messageEditSelections
        self.onMessageEditSelected = onMessageEditSelected
        self.promptResubmitSelection = promptResubmitSelection
        self.onPromptResubmitSelected = onPromptResubmitSelected
        self.responseRegenerationSelection = responseRegenerationSelection
        self.onResponseRegenerationSelected = onResponseRegenerationSelected
        self.conversationForkSelection = conversationForkSelection
        self.onConversationForkSelected = onConversationForkSelected
        self.positiveFeedbackSelection = positiveFeedbackSelection
        self.negativeFeedbackSelection = negativeFeedbackSelection
        self.onMessageFeedbackSelected = onMessageFeedbackSelected
        self.readAloudAction = readAloudAction
        self.onReadAloud = onReadAloud
        self.onChooseReadAloudVoice = onChooseReadAloudVoice
        self.allowsArtifactEditing = allowsArtifactEditing
    }

    private var sourceCollection: CitationSourceCollection {
        CitationSourceCollection(message: message)
    }

    private var isUser: Bool {
        if case .user = message.author { return true }
        return false
    }

    private var canEditArtifacts: Bool {
        guard allowsArtifactEditing,
              !isStreaming,
              !message.id.rawValue.hasPrefix("local-") else { return false }
        if case .assistant = message.author { return true }
        return false
    }

    var body: some View {
        Group {
            if message.plainText.isEmpty,
               messageEditSelections.isEmpty,
               promptResubmitSelection == nil,
               responseRegenerationSelection == nil,
               conversationForkSelection == nil,
               positiveFeedbackSelection == nil,
               negativeFeedbackSelection == nil,
               readAloudAction == nil {
                messageBody
            } else {
                messageBody
                    .contextMenu { messageActions }
                    .accessibilityActions { messageActions }
            }
        }
    }

    private var messageBody: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 44) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser {
                    Text(message.author.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if message.plainText.isEmpty && isStreaming {
                    // LibreChat's three-dot thinking indicator.
                    TypingDots()
                        .padding(.horizontal, isUser ? 16 : 2)
                        .padding(.vertical, isUser ? 10 : 4)
                } else {
                    let scan = artifactScan
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(message.content.enumerated()), id: \.offset) { index, content in
                            MessageContentView(
                                conversationID: message.conversationID,
                                messageID: message.id,
                                content: content,
                                artifactDocumentOrderOffset: scan.offsets[index],
                                canEditArtifacts: canEditArtifacts,
                                citationAttachments: message.citationAttachments,
                                citationSelectionIDPrefix: "\(message.id.rawValue):\(index)",
                                onCitationSelected: onCitationSelected,
                                onArtifactSelected: onArtifactSelected,
                                onGeneratedFileSelected: onGeneratedFileSelected
                            )
                        }
                        ForEach(
                            message.artifactCatalog.filter { !scan.visibleIdentities.contains($0.identity) },
                            id: \.identity
                        ) { artifact in
                            ArtifactCardView(artifact: artifact) {
                                onArtifactSelected(ArtifactWorkspaceSelection(
                                    conversationID: message.conversationID,
                                    artifact: artifact,
                                    citationAttachments: message.citationAttachments,
                                    canEdit: canEditArtifacts
                                ))
                            }
                        }
                        MessageSourcesControl(
                            collection: sourceCollection,
                            messageID: message.id,
                            onSelect: onCitationSelected
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let feedback = message.feedback {
                            Label(
                                feedback.rating == .thumbsUp ? "Marked helpful" : "Marked for improvement",
                                systemImage: feedback.rating == .thumbsUp
                                    ? "hand.thumbsup.fill"
                                    : "hand.thumbsdown.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                feedback.rating == .thumbsUp
                                    ? "Feedback: helpful"
                                    : "Feedback: needs improvement"
                            )
                        }
                    }
                    .padding(.horizontal, isUser ? 16 : 2)
                    .padding(.vertical, isUser ? 10 : 2)
                }
            }
            .foregroundStyle(Color.primary)
            // ChatGPT thread pattern: user prompts sit in a neutral gray
            // bubble with a tight tail corner; responses render as plain
            // editorial text with only a small provenance caption, since
            // LibreChat threads can mix many models and agents.
            .background {
                if isUser {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 20,
                        bottomLeadingRadius: 20,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 20,
                        style: .continuous
                    )
                    .fill(Color(uiColor: .secondarySystemFill))
                }
            }
            .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-\(message.id.rawValue)")
    }

    @ViewBuilder
    private var messageActions: some View {
        if !message.plainText.isEmpty {
            Button {
                UIPasteboard.general.string = message.plainText
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Message copied"
                )
            } label: {
                Label("Copy message", systemImage: "doc.on.doc")
            }
            .accessibilityHint("Copies the visible message text without hidden protocol metadata.")
            .accessibilityIdentifier("copy-message-\(message.id.rawValue)")
        }
        if let readAloudAction {
            Button(action: onReadAloud) {
                Label(readAloudAction.title, systemImage: readAloudAction.systemImage)
            }
            .accessibilityHint(readAloudAction.accessibilityHint)
            .accessibilityIdentifier("read-aloud-action-\(message.id.rawValue)")

            Button(action: onChooseReadAloudVoice) {
                Label("Choose reading voice", systemImage: "waveform.and.person.filled")
            }
            .accessibilityHint("Selects a server-provided voice for future read aloud requests.")
            .accessibilityIdentifier("read-aloud-voice-action-\(message.id.rawValue)")
        }
        ForEach(Array(messageEditSelections.enumerated()), id: \.element.id) { index, selection in
            Button {
                onMessageEditSelected(selection)
            } label: {
                Label(selection.title, systemImage: "pencil")
            }
            .accessibilityHint("Changes saved history without generating a response.")
            .accessibilityIdentifier(
                "message-edit-action-\(message.id.rawValue)-\(index)"
            )
        }
        if let promptResubmitSelection {
            Button {
                onPromptResubmitSelected(promptResubmitSelection)
            } label: {
                Label("Edit and send as new branch", systemImage: "arrow.triangle.branch")
            }
            .accessibilityHint("Keeps the original prompt and replies unchanged.")
            .accessibilityIdentifier(
                "prompt-resubmit-action-\(message.id.rawValue)"
            )
        }
        if let responseRegenerationSelection {
            Button {
                onResponseRegenerationSelected(responseRegenerationSelection)
            } label: {
                Label("Regenerate response", systemImage: "arrow.clockwise")
            }
            .accessibilityHint(
                "Keeps the existing response and creates a new branch using the current chat target."
            )
            .accessibilityIdentifier(
                "response-regeneration-action-\(message.id.rawValue)"
            )
        }
        if let conversationForkSelection {
            Button {
                onConversationForkSelected(conversationForkSelection)
            } label: {
                Label("Branch in new chat", systemImage: "arrow.triangle.branch")
            }
            .accessibilityHint(
                "Creates a separate conversation from the selected path and leaves this conversation unchanged."
            )
            .accessibilityIdentifier(
                "conversation-fork-action-\(message.id.rawValue)"
            )
        }
        if message.feedback != nil {
            if let selection = (message.feedback?.rating == .thumbsUp
                ? positiveFeedbackSelection
                : negativeFeedbackSelection) {
                Button {
                    onMessageFeedbackSelected(selection)
                } label: {
                    Label(
                        "Edit feedback",
                        systemImage: message.feedback?.rating == .thumbsUp
                            ? "hand.thumbsup.fill"
                            : "hand.thumbsdown.fill"
                    )
                }
                .accessibilityHint("Reviews or clears feedback saved for this response.")
                .accessibilityIdentifier("message-feedback-edit-\(message.id.rawValue)")
            }
        } else {
            if let positiveFeedbackSelection {
                Button {
                    onMessageFeedbackSelected(positiveFeedbackSelection)
                } label: {
                    Label("Mark as helpful", systemImage: "hand.thumbsup")
                }
                .accessibilityHint("Opens a review before saving positive feedback.")
                .accessibilityIdentifier("message-feedback-positive-\(message.id.rawValue)")
            }
            if let negativeFeedbackSelection {
                Button {
                    onMessageFeedbackSelected(negativeFeedbackSelection)
                } label: {
                    Label("Needs improvement", systemImage: "hand.thumbsdown")
                }
                .accessibilityHint("Opens a review before saving negative feedback.")
                .accessibilityIdentifier("message-feedback-negative-\(message.id.rawValue)")
            }
        }
    }

    /// One linear pass over the message's text segments producing, for each
    /// content index, the artifact document-order offset that starts there,
    /// plus every identity already rendered by structured content. The old
    /// per-index re-parsing was quadratic per row per render.
    private var artifactScan: (offsets: [Int], visibleIdentities: Set<ArtifactIdentity>) {
        var offsets = [Int]()
        offsets.reserveCapacity(message.content.count)
        var visibleIdentities = Set<ArtifactIdentity>()
        var nextDocumentOrderIndex = 0
        for content in message.content {
            offsets.append(nextDocumentOrderIndex)
            guard case let .text(text) = content else { continue }
            let document = ArtifactParser.parse(
                messageID: message.id,
                text: text,
                startingDocumentOrderIndex: nextDocumentOrderIndex
            )
            visibleIdentities.formUnion(document.artifacts.map(\.identity))
            nextDocumentOrderIndex = document.nextDocumentOrderIndex
        }
        return (offsets, visibleIdentities)
    }
}

/// Value-input equality excluding action closures: they only route sheet
/// presentations, so equal value inputs render identically and the body can
/// be skipped even though the caller recreates its closures every render.
extension MessageRow {
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.isStreaming == rhs.isStreaming
            && lhs.messageEditSelections == rhs.messageEditSelections
            && lhs.promptResubmitSelection == rhs.promptResubmitSelection
            && lhs.responseRegenerationSelection == rhs.responseRegenerationSelection
            && lhs.conversationForkSelection == rhs.conversationForkSelection
            && lhs.positiveFeedbackSelection == rhs.positiveFeedbackSelection
            && lhs.negativeFeedbackSelection == rhs.negativeFeedbackSelection
            && lhs.readAloudAction == rhs.readAloudAction
            && lhs.allowsArtifactEditing == rhs.allowsArtifactEditing
    }
}

/// LibreChat's animated three-dot "thinking" indicator. Reduce Motion gets
/// static dots.
private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(isAnimating ? 0.35 : 1)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.18),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }
}

struct MessageContentView: View {
    let conversationID: ConversationID
    let messageID: MessageID
    let content: MessageContent
    let artifactDocumentOrderOffset: Int
    let canEditArtifacts: Bool
    let citationAttachments: [CitationAttachment]
    let citationSelectionIDPrefix: String
    let onCitationSelected: (CitationSheetSelection) -> Void
    let onArtifactSelected: (ArtifactWorkspaceSelection) -> Void
    let onGeneratedFileSelected: (GeneratedFileSheetSelection) -> Void

    init(
        conversationID: ConversationID = ConversationID(rawValue: "presentation-conversation"),
        messageID: MessageID = MessageID(rawValue: "presentation-message"),
        content: MessageContent,
        artifactDocumentOrderOffset: Int = 0,
        canEditArtifacts: Bool = false,
        citationAttachments: [CitationAttachment] = [],
        citationSelectionIDPrefix: String = "message-content",
        onCitationSelected: @escaping (CitationSheetSelection) -> Void = { _ in },
        onArtifactSelected: @escaping (ArtifactWorkspaceSelection) -> Void = { _ in },
        onGeneratedFileSelected: @escaping (GeneratedFileSheetSelection) -> Void = { _ in }
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.content = content
        self.artifactDocumentOrderOffset = artifactDocumentOrderOffset
        self.canEditArtifacts = canEditArtifacts
        self.citationAttachments = citationAttachments
        self.citationSelectionIDPrefix = citationSelectionIDPrefix
        self.onCitationSelected = onCitationSelected
        self.onArtifactSelected = onArtifactSelected
        self.onGeneratedFileSelected = onGeneratedFileSelected
    }

    var body: some View {
        switch content {
        case let .text(text):
            ArtifactDocumentView(
                conversationID: conversationID,
                messageID: messageID,
                text: text,
                documentOrderOffset: artifactDocumentOrderOffset,
                canEdit: canEditArtifacts,
                citationAttachments: citationAttachments,
                citationSelectionIDPrefix: citationSelectionIDPrefix,
                onCitationSelected: onCitationSelected,
                onArtifactSelected: onArtifactSelected
            )
        case let .reasoning(text):
            DisclosureGroup("Reasoning") {
                Text(markdown(text)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case let .summary(summary):
            DisclosureGroup(summary.isInProgress ? "Summarizing…" : "Summary") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown(summary.text)).textSelection(.enabled)
                    let details = [summary.provider, summary.model].compactMap { $0 }.joined(separator: " · ")
                    if !details.isEmpty || summary.tokenCount != nil {
                        Text([details, summary.tokenCount.map { "\($0) tokens" }]
                            .compactMap { $0?.isEmpty == false ? $0 : nil }
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case let .code(code):
            CodeBlock(language: code.language, code: code.code)
        case let .image(url, alternativeText):
            BoundedMessageImage(url: url, alternativeText: alternativeText)
        case let .video(url, alternativeText):
            Link(destination: url) {
                Label(alternativeText ?? "Open video", systemImage: "play.rectangle.fill")
            }
            .accessibilityLabel(alternativeText ?? "Open attached video")
        case let .audio(url, transcript):
            VStack(alignment: .leading, spacing: 4) {
                Link(destination: url) {
                    Label("Open audio", systemImage: "waveform")
                }
                if let transcript, !transcript.isEmpty {
                    Text(transcript).font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .file(file):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename).lineLimit(2)
                    if let bytes = file.bytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "doc.fill")
            }
            .accessibilityLabel("Attached file \(file.filename)")
        case let .generatedFile(file):
            GeneratedFileCardView(file: file) {
                onGeneratedFileSelected(GeneratedFileSheetSelection(file: file))
            }
        case let .tool(call):
            if let presentation = SubagentTracePresentation(call: call) {
                SubagentTraceCard(presentation: presentation)
            } else {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        if let summary = call.summary, !summary.isEmpty {
                            Text(summary).textSelection(.enabled)
                        }
                        if let input = call.input, !input.isEmpty {
                            Text("Input").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(input).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let output = call.output, !output.isEmpty, output != call.summary {
                            Text("Output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if let authorizationURL = call.authorizationURL {
                            Link("Authenticate", destination: authorizationURL)
                        }
                    }
                } label: {
                    Label(call.name, systemImage: call.status == .failed
                        ? "exclamationmark.triangle"
                        : "wrench.and.screwdriver")
                }
                .accessibilityLabel("Tool \(call.name), \(call.status.rawValue)")
            }
        case let .activity(activity):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.label)
                    if let status = activity.status, !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                if activity.isPending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal.circle")
                }
            }
            .accessibilityLabel("Activity: \(activity.label)")
        case let .error(error):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.message)
                    if error.isRecoverable {
                        Text("This may be recoverable.").font(.caption)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(error.message)")
        case let .toolReference(reference):
            Label(reference, systemImage: "wrench.and.screwdriver")
                .font(.callout)
        case let .unsupported(kind):
            Label("Unsupported content: \(kind)", systemImage: "questionmark.square.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Parsed markdown is cached per source string: scrolling back through a
    /// long conversation re-renders rows whose AttributedString would
    /// otherwise be rebuilt from scratch every time.
    private nonisolated(unsafe) static let markdownCache: NSCache<NSString, CachedMarkdown> = {
        let cache = NSCache<NSString, CachedMarkdown>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    private func markdown(_ source: String) -> AttributedString {
        if let box = Self.markdownCache.object(forKey: source as NSString) {
            return box.value
        }
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(source)
        Self.markdownCache.setObject(
            CachedMarkdown(value: parsed),
            forKey: source as NSString,
            cost: source.utf16.count
        )
        return parsed
    }
}

/// NSCache requires class values.
private final class CachedMarkdown {
    let value: AttributedString
    init(value: AttributedString) { self.value = value }
}


/// A message image that loads through the app's bounded fetch: declared-
/// length and streaming byte caps, then a pixel-limited decode — an
/// unbounded `AsyncImage` could exhaust bandwidth or memory on a hostile
/// or oversized source.
private struct BoundedMessageImage: View {
    let url: URL
    let alternativeText: String?

    @Environment(\.fetchServerImage) private var fetchServerImage
    @State private var image: UIImage?

    private static let maximumBytes = 25 * 1_048_576
    private static let maximumPixel = 2_048

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .frame(minWidth: 120, minHeight: 80)
            }
        }
        .accessibilityLabel(alternativeText ?? "Attached image")
        .task(id: url) {
            // All content rides the app's authenticated, bounded pipeline:
            // relative and same-origin URLs use the profile transport, and
            // cross-origin URLs use the bounded external branch. A direct
            // URLSession fallback would drop cookies/UA and can trip the
            // server's non-browser policy.
            if let data = try? await fetchServerImage(url) {
                image = Self.downsampled(data)
            }
        }
    }

    private static func downsampled(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func load(from url: URL) async -> UIImage? {
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: URLRequest(url: url)) else {
            return nil
        }
        if let http = response as? HTTPURLResponse,
           http.expectedContentLength > maximumBytes {
            return nil
        }
        var data = Data()
        data.reserveCapacity(256 * 1_024)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maximumBytes { return nil }
            }
        } catch {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}