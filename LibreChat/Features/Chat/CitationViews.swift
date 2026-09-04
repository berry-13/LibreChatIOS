import LibreChatDomain
import SwiftUI

struct CitationSheetSelection: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let references: [CitationReference]
}

enum CitationURLValidator {
    static func validatedExternalURL(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}

struct CitationSourceCollection: Equatable, Sendable {
    let references: [CitationReference]

    init(message: ChatMessage) {
        let catalog = CitationSourceCatalog(attachments: message.citationAttachments)
        var references: [CitationReference] = []

        for content in message.content {
            guard case let .text(text) = content else { continue }
            let resolution = CitationMarkerResolver.resolve(text, sources: catalog)
            references.append(contentsOf: resolution.citations.map(\.reference))
        }

        for turn in catalog.webSearchByTurn.keys.sorted() {
            guard let data = catalog.webSearchByTurn[turn] else { continue }
            references.append(contentsOf: data.organic)
            references.append(contentsOf: data.topStories)
            references.append(contentsOf: data.images)
            references.append(contentsOf: data.videos)
            references.append(contentsOf: data.references)
        }

        for turn in catalog.fileSearchByTurn.keys.sorted() {
            references.append(contentsOf: catalog.displayFileSources(forTurn: turn))
        }

        self.references = Self.deduplicated(references)
    }

    var fileCount: Int {
        references.count { $0.type == .file }
    }

    func selection(messageID: MessageID) -> CitationSheetSelection? {
        guard !references.isEmpty else { return nil }
        return CitationSheetSelection(
            id: "\(messageID.rawValue):all-sources",
            title: "Sources",
            references: references
        )
    }

    static func deduplicated(_ references: [CitationReference]) -> [CitationReference] {
        var seen: Set<String> = []
        return references.filter { reference in
            let identity: String
            if let fileID = reference.fileID, !fileID.isEmpty {
                identity = "file:\(fileID)"
            } else if let url = CitationURLValidator.validatedExternalURL(reference.link) {
                identity = "url:\(url.absoluteString)"
            } else {
                identity = [
                    reference.type.rawValue,
                    reference.title ?? "",
                    reference.attribution ?? "",
                    reference.snippet ?? ""
                ].joined(separator: "|")
            }
            return seen.insert(identity).inserted
        }
    }
}

struct CitationTextView: View {
    let text: String
    let attachments: [CitationAttachment]
    let selectionIDPrefix: String
    let onSelect: (CitationSheetSelection) -> Void

    private var presentation: CitationTextPresentation {
        CitationTextPresentation(
            text: text,
            attachments: attachments,
            selectionIDPrefix: selectionIDPrefix
        )
    }

    var body: some View {
        let presentation = presentation
        Text(presentation.attributedText)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == CitationTextPresentation.selectionScheme {
                    guard let indexText = url.pathComponents.last,
                          let index = Int(indexText),
                          let selection = presentation.selections[index] else {
                        return .discarded
                    }
                    onSelect(selection)
                    return .handled
                }
                guard CitationURLValidator.validatedExternalURL(url) != nil else {
                    return .discarded
                }
                return .systemAction
            })
            .accessibilityLabel(presentation.cleanedText)
    }
}

struct MessageSourcesControl: View {
    let collection: CitationSourceCollection
    let messageID: MessageID
    let onSelect: (CitationSheetSelection) -> Void

    var body: some View {
        if let selection = collection.selection(messageID: messageID) {
            Button {
                onSelect(selection)
            } label: {
                HStack(spacing: 5) {
                    Label("Sources", systemImage: "link")
                    Text("\(collection.references.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if collection.fileCount > 0 {
                        Text("· \(collection.fileCount) \(collection.fileCount == 1 ? "file" : "files")")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens source details")
            .accessibilityIdentifier("message-sources")
        }
    }

    private var accessibilityLabel: String {
        let sourceLabel = "\(collection.references.count) \(collection.references.count == 1 ? "source" : "sources")"
        guard collection.fileCount > 0 else { return "Sources, \(sourceLabel)" }
        let fileLabel = "\(collection.fileCount) \(collection.fileCount == 1 ? "file source" : "file sources")"
        return "Sources, \(sourceLabel), including \(fileLabel)"
    }
}

struct CitationSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: CitationSheetSelection

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(selection.references.enumerated()), id: \.offset) { index, reference in
                    CitationSourceRow(reference: reference, number: index + 1)
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct CitationSourceRow: View {
    let reference: CitationReference
    let number: Int

    private var title: String {
        reference.fileName
            ?? reference.title
            ?? reference.attribution
            ?? (reference.type == .file ? "File source" : "Source")
    }

    private var domain: String? {
        guard let host = CitationURLValidator.validatedExternalURL(reference.link)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: reference.type == .file ? "doc.text" : "link")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let attribution = reference.attribution, attribution != title {
                Text(attribution)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let domain, domain != title {
                Text(domain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if reference.type == .file {
                FileSourceMetadata(reference: reference)
            }

            if let snippet = reference.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if reference.type != .file,
               let url = CitationURLValidator.validatedExternalURL(reference.link) {
                Link(destination: url) {
                    Label("Open source", systemImage: "arrow.up.right.square")
                }
                .accessibilityHint("Opens in your default browser")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source \(number): \(title)")
    }
}

private struct FileSourceMetadata: View {
    let reference: CitationReference

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let pages = reference.pages, !pages.isEmpty {
                Text("Pages \(pages.map(String.init).joined(separator: ", "))")
            }
            if let relevance = reference.relevance, relevance > 0 {
                Text("Relevance \(relevance, format: .percent.precision(.fractionLength(0)))")
            }
            Text("Preview is not available without an authorized file route.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct CitationTextPresentation {
    static let selectionScheme = "librechat-citation"

    let attributedText: AttributedString
    let cleanedText: String
    let selections: [Int: CitationSheetSelection]

    init(text: String, attachments: [CitationAttachment], selectionIDPrefix: String) {
        let resolution = CitationMarkerResolver.resolve(
            text,
            sources: CitationSourceCatalog(attachments: attachments)
        )
        var markdownSource = ""
        var fallbackText = AttributedString()
        var selections: [Int: CitationSheetSelection] = [:]
        var selectionIndex = 0
        var sourceNumber = 1

        for segment in resolution.renderSegments {
            switch segment {
            case let .text(value):
                markdownSource.append(value)
                fallbackText.append(AttributedString(value))
            case let .citation(token):
                let references = CitationSourceCollection.deduplicated(token.anchors.map(\.reference))
                guard !references.isEmpty else { continue }
                let numbers = Array(sourceNumber..<(sourceNumber + references.count))
                sourceNumber += references.count
                let numberText = numbers.map(String.init).joined(separator: ",")
                let label = "[\(numberText)]"
                let selectionURL = URL(string: "\(Self.selectionScheme)://select/\(selectionIndex)")!
                markdownSource.append("\u{202F}[\\[\(numberText)\\]](\(selectionURL.absoluteString))")
                var tokenText = AttributedString("\u{202F}\(label)")
                tokenText.link = selectionURL
                fallbackText.append(tokenText)
                selections[selectionIndex] = CitationSheetSelection(
                    id: "\(selectionIDPrefix):\(selectionIndex)",
                    title: references.count == 1 ? "Source" : "Sources",
                    references: references
                )
                selectionIndex += 1
            }
        }

        attributedText = (try? AttributedString(
            markdown: markdownSource,
            options: .init(interpretedSyntax: .full)
        )) ?? fallbackText
        cleanedText = Self.accessibilityText(from: resolution.cleanedText)
        self.selections = selections
    }

    private static func accessibilityText(from markdown: String) -> String {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) else { return markdown }
        return String(attributed.characters)
    }
}
