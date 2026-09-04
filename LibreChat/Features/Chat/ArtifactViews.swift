import DesignKit
import LibreChatDomain
import SwiftUI
import UIKit

struct ArtifactWorkspaceIdentity: Equatable, Hashable, Sendable {
    let conversationID: ConversationID
    let artifactIdentity: ArtifactIdentity
}

struct ArtifactWorkspaceSelection: Identifiable, Equatable, Hashable, Sendable {
    let conversationID: ConversationID
    let artifact: ParsedArtifact
    let citationAttachments: [CitationAttachment]
    let canEdit: Bool

    init(
        conversationID: ConversationID,
        artifact: ParsedArtifact,
        citationAttachments: [CitationAttachment],
        canEdit: Bool = false
    ) {
        self.conversationID = conversationID
        self.artifact = artifact
        self.citationAttachments = citationAttachments
        self.canEdit = canEdit
    }

    var id: ArtifactWorkspaceIdentity {
        ArtifactWorkspaceIdentity(
            conversationID: conversationID,
            artifactIdentity: artifact.identity
        )
    }
}

enum ArtifactNativePreviewPolicy: Equatable, Sendable {
    case markdown
    case plainText
    case sourceOnly(reason: String)

    init(mimeType: String) {
        switch mimeType.lowercased() {
        case "text/markdown", "text/md":
            self = .markdown
        case "text/plain":
            self = .plainText
        case "text/html":
            self = .sourceOnly(reason: "HTML preview is disabled until a sandboxed renderer is available.")
        case "image/svg+xml":
            self = .sourceOnly(reason: "SVG preview is disabled until a sanitized renderer is available.")
        case "application/vnd.mermaid":
            self = .sourceOnly(reason: "Diagram preview is not available in this build.")
        case "application/vnd.react":
            self = .sourceOnly(reason: "React code is never executed inside the native chat view.")
        default:
            self = .sourceOnly(reason: "This artifact type does not have a native preview yet.")
        }
    }

    var supportsPreview: Bool {
        switch self {
        case .markdown, .plainText: true
        case .sourceOnly: false
        }
    }
}

struct ArtifactDocumentView: View {
    let conversationID: ConversationID
    let messageID: MessageID
    let text: String
    let documentOrderOffset: Int
    let canEdit: Bool
    let citationAttachments: [CitationAttachment]
    let citationSelectionIDPrefix: String
    let onCitationSelected: (CitationSheetSelection) -> Void
    let onArtifactSelected: (ArtifactWorkspaceSelection) -> Void

    private var document: ParsedArtifactDocument {
        ArtifactParser.parse(
            messageID: messageID,
            text: text,
            startingDocumentOrderIndex: documentOrderOffset
        )
    }

    var body: some View {
        let document = document
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case let .text(value):
                    if !value.isEmpty {
                        CitationTextView(
                            text: value,
                            attachments: citationAttachments,
                            selectionIDPrefix: "\(citationSelectionIDPrefix):segment-\(index)",
                            onSelect: onCitationSelected
                        )
                    }
                case let .artifact(parsed):
                    ArtifactCardView(artifact: parsed) {
                        onArtifactSelected(ArtifactWorkspaceSelection(
                            conversationID: conversationID,
                            artifact: parsed,
                            citationAttachments: citationAttachments,
                            canEdit: canEdit
                        ))
                    }
                    .id("artifact-\(parsed.identity.documentOrderIndex)")
                }
            }
        }
    }
}

struct ArtifactCardView: View {
    let artifact: ParsedArtifact
    let action: () -> Void

    private var presentation: ArtifactPresentation {
        ArtifactPresentation(artifact: artifact)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: presentation.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(presentation.typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(minHeight: 56)
            .background(
                Color(uiColor: .tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Artifact, \(artifact.title), \(presentation.typeLabel)")
        .accessibilityHint("Opens the artifact workspace")
        .accessibilityIdentifier("message-artifact-\(artifact.identity.documentOrderIndex)")
    }
}

struct ArtifactWorkspaceView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case preview = "Preview"
        case source = "Source"

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    let selection: ArtifactWorkspaceSelection
    let showsCloseAction: Bool
    private let editAvailability: @MainActor () -> Bool
    let onSave: (ParsedArtifact, String) async throws -> Void
    @State private var mode: Mode
    @State private var citationSelection: CitationSheetSelection?
    @State private var sourceContent: String
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var saveError: String?

    private var artifact: ParsedArtifact { selection.artifact }
    private var policy: ArtifactNativePreviewPolicy {
        ArtifactNativePreviewPolicy(mimeType: artifact.mimeType)
    }
    /// Read at render/save time rather than captured when the workspace opens.
    /// Generation recovery and pending human actions can begin while the
    /// workspace is visible, and that must immediately make the editor read-only.
    private var canEditNow: Bool { selection.canEdit && editAvailability() }

    init(
        selection: ArtifactWorkspaceSelection,
        showsCloseAction: Bool = false,
        canEditNow: @escaping @MainActor () -> Bool,
        onSave: @escaping (ParsedArtifact, String) async throws -> Void = { _, _ in
            throw ArtifactEditError.unavailable
        }
    ) {
        self.selection = selection
        self.showsCloseAction = showsCloseAction
        editAvailability = canEditNow
        self.onSave = onSave
        let policy = ArtifactNativePreviewPolicy(mimeType: selection.artifact.mimeType)
        _mode = State(initialValue: policy.supportsPreview ? .preview : .source)
        _sourceContent = State(initialValue: selection.artifact.sourceContent)
    }

    var body: some View {
        Group {
            if mode == .preview, policy.supportsPreview {
                preview
            } else {
                source
            }
        }
        .navigationTitle(artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                provenanceHeader
                if policy.supportsPreview {
                    Picker("Artifact view", selection: $mode) {
                        ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .disabled(isSaving)
                }
            }
            .background(.bar)
        }
        .toolbar { toolbarContent }
        .sheet(item: $citationSelection) { selection in
            CitationSourceSheet(selection: selection)
        }
        .alert("Couldn’t save artifact", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The edit could not be saved.")
        }
        .accessibilityIdentifier("artifact-workspace")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ShareLink(item: sourceContent) {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share artifact source")
            .disabled(isSaving)

            Button {
                UIPasteboard.general.string = sourceContent
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy artifact source")
            .disabled(isSaving)

            if selection.canEdit {
                if isEditing {
                    Button("Cancel") {
                        sourceContent = artifact.sourceContent
                        isEditing = false
                    }
                    .disabled(isSaving)

                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(
                            isSaving
                                || !canEditNow
                                || sourceContent == artifact.sourceContent
                        )
                        .accessibilityHint(
                            canEditNow
                                ? "Saves this artifact source to LibreChat."
                                : "Finish or recover the current generation before saving."
                        )
                } else {
                    Button("Edit") {
                        mode = .source
                        isEditing = true
                    }
                    .disabled(!canEditNow)
                    .accessibilityHint(
                        canEditNow
                            ? "Edits this artifact source."
                            : "Finish or recover the current generation before editing."
                    )
                }
            }

            if showsCloseAction {
                Button("Close") { dismiss() }
                    .disabled(isSaving)
            }
        }
    }

    private var provenanceHeader: some View {
        HStack(spacing: 12) {
            Label(
                ArtifactPresentation(artifact: artifact).typeLabel,
                systemImage: ArtifactPresentation(artifact: artifact).systemImage
            )
            Spacer(minLength: 12)
            Label("From this conversation", systemImage: "bubble.left")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("artifact-workspace-provenance")
    }

    @ViewBuilder
    private var preview: some View {
        ScrollView {
            Group {
                switch policy {
                case .markdown:
                    CitationTextView(
                        text: sourceContent,
                        attachments: selection.citationAttachments,
                        selectionIDPrefix: "artifact:\(selection.id)",
                        onSelect: { citationSelection = $0 }
                    )
                case .plainText:
                    Text(sourceContent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .sourceOnly:
                    EmptyView()
                }
            }
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var source: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case let .sourceOnly(reason) = policy {
                    Label(reason, systemImage: "shield.lefthalf.filled")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }

                if isEditing {
                    TextEditor(text: $sourceContent)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 420)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Edit artifact source")
                } else {
                    Text(sourceContent)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel("Artifact source")
                        .accessibilityValue(sourceContent)
                }
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func save() {
        guard selection.canEdit,
              canEditNow,
              !isSaving,
              sourceContent != artifact.sourceContent else { return }
        isSaving = true
        saveError = nil
        let updated = sourceContent
        Task { @MainActor in
            do {
                try await onSave(artifact, updated)
                isSaving = false
                isEditing = false
                dismiss()
            } catch {
                isSaving = false
                saveError = error.userFacingMessage
            }
        }
    }
}

struct ArtifactPresentation: Equatable, Sendable {
    let typeLabel: String
    let systemImage: String

    init(artifact: ParsedArtifact) {
        switch artifact.mimeType.lowercased() {
        case "text/markdown", "text/md":
            typeLabel = "Markdown"
            systemImage = "text.document"
        case "text/plain":
            typeLabel = "Plain text"
            systemImage = "doc.plaintext"
        case "text/html":
            typeLabel = "HTML · source only"
            systemImage = "chevron.left.forwardslash.chevron.right"
        case "image/svg+xml":
            typeLabel = "SVG · source only"
            systemImage = "scribble.variable"
        case "application/vnd.mermaid":
            typeLabel = "Diagram · source only"
            systemImage = "point.3.connected.trianglepath.dotted"
        case "application/vnd.react":
            typeLabel = "React · source only"
            systemImage = "curlybraces.square"
        default:
            typeLabel = artifact.mimeType.isEmpty ? "Artifact" : artifact.mimeType
            systemImage = "doc.richtext"
        }
    }
}
