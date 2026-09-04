import LibreChatDomain
import SwiftUI
import UIKit

/// Presentation identity for one exact server-owned text slot.
///
/// `originalText` is intentionally retained so `ChatModel` can reject a
/// stale editor instead of overwriting a value refreshed while the sheet was
/// open. The server route has no compare-and-swap precondition.
struct MessageTextEditSelection: Identifiable, Equatable, Hashable, Sendable {
    let coordinate: MessageTextCoordinate
    let originalText: String
    let title: String
    let hasDescendants: Bool

    var id: MessageTextCoordinate { coordinate }
}

enum MessageEditPresentationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case stale
    case operationInProgress
    case invalidAuthoritativeHistory

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This saved message cannot be edited right now."
        case .stale:
            "This message changed after the editor opened. Close it and review the latest version."
        case .operationInProgress:
            "Another message edit is already being saved."
        case .invalidAuthoritativeHistory:
            "LibreChat returned history that could not safely confirm this edit. Refresh the conversation."
        }
    }
}

/// Pure validation shared by the sheet and presentation tests.
struct MessageEditDraftState: Equatable, Sendable {
    let originalText: String
    let draft: String
    let isSaving: Bool
    let requiresReview: Bool

    var isChanged: Bool { draft != originalText }
    var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var isOverLimit: Bool {
        draft.utf16.count > MessageEditRequest.maximumTextUTF16Length
    }
    var canSave: Bool {
        isChanged && !isBlank && !isOverLimit && !isSaving && !requiresReview
    }
}

struct MessageTextEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: MessageTextEditSelection
    let save: @MainActor (MessageTextEditSelection, String) async throws -> MessageEditResolution
    let refresh: @MainActor () async -> Void

    @State private var draft: String
    @State private var isSaving = false
    @State private var failureMessage: String?
    @State private var requiresReview = false

    init(
        selection: MessageTextEditSelection,
        save: @escaping @MainActor (MessageTextEditSelection, String) async throws -> MessageEditResolution,
        refresh: @escaping @MainActor () async -> Void
    ) {
        self.selection = selection
        self.save = save
        self.refresh = refresh
        _draft = State(initialValue: selection.originalText)
    }

    private var draftState: MessageEditDraftState {
        MessageEditDraftState(
            originalText: selection.originalText,
            draft: draft,
            isSaving: isSaving,
            requiresReview: requiresReview
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 180)
                        .accessibilityLabel(selection.title)
                        .accessibilityIdentifier("message-edit-text")

                    Text("\(draft.utf16.count) / \(MessageEditRequest.maximumTextUTF16Length)")
                        .font(.caption)
                        .foregroundStyle(draftState.isOverLimit ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel(
                            "\(draft.utf16.count) of \(MessageEditRequest.maximumTextUTF16Length) characters"
                        )
                } header: {
                    Text(selection.title)
                } footer: {
                    Text("This changes saved history only. It does not generate a new response.")
                }

                if selection.hasDescendants {
                    Section {
                        Label("Existing replies will not change.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                if let failureMessage {
                    Section("Not saved") {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        if requiresReview {
                            Button("Close and refresh conversation") {
                                Task { @MainActor in
                                    await refresh()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit saved text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { performSave() }
                        .disabled(!draftState.canSave)
                        .accessibilityHint("Saves this text without generating a response.")
                        .accessibilityIdentifier("message-edit-save")
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("Saving message edit…")
                        .padding()
                        .adaptiveSurface(in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("message-edit-progress")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .accessibilityIdentifier("message-edit-sheet")
        }
    }

    private func performSave() {
        guard draftState.canSave else { return }
        isSaving = true
        failureMessage = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                _ = try await save(selection, draft)
                UIAccessibility.post(notification: .announcement, argument: "Message edit saved")
                dismiss()
            } catch let MessageEditError.ambiguous(ambiguity) {
                requiresReview = true
                failureMessage = switch ambiguity.reason {
                case .authoritativeMismatch:
                    "LibreChat contains a different version. The conversation was refreshed. Review it before editing again."
                case .verificationUnavailable:
                    "LibreChat may have saved this edit, but its current value could not be verified. Refresh before trying again."
                }
            } catch is CancellationError {
                failureMessage = "Saving was cancelled."
            } catch {
                failureMessage = error.userFacingMessage
            }
        }
    }
}

/// Exact source coordinates for a branch-producing prompt edit. This is
/// intentionally distinct from `MessageTextEditSelection`, which mutates
/// persisted history without generating a response.
struct PromptResubmitSelection: Identifiable, Equatable, Hashable, Sendable {
    let conversationID: ConversationID
    let sourceMessageID: MessageID
    let sourceParentMessageID: MessageID?
    let baselineText: String

    var id: MessageID { sourceMessageID }
}

enum PromptResubmitAdmissionResult: Equatable, Sendable {
    case streaming
    case settled
    case aborted
    case failed
}

enum PromptResubmitPresentationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case stale
    case operationInProgress
    case blankText
    case textTooLong
    case invalidAdmission
    case handoff

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This prompt cannot be edited and sent right now. Close and refresh the conversation."
        case .stale:
            "The source prompt or its branch changed. Close and review the refreshed conversation."
        case .operationInProgress:
            "Another edited prompt is already being submitted."
        case .blankText:
            "The edited prompt cannot be blank."
        case .textTooLong:
            "The edited prompt exceeds the native client’s safety limit."
        case .invalidAdmission:
            "LibreChat did not return safe generation ownership for this edited prompt."
        case .handoff:
            "A different response won generation admission. Your edited prompt was not sent."
        }
    }
}

struct PromptResubmitDraftState: Equatable, Sendable {
    let baselineText: String
    let draft: String
    let isSubmitting: Bool
    let requiresReview: Bool

    var canSubmit: Bool {
        draft != baselineText
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.utf16.count <= MessageEditRequest.maximumTextUTF16Length
            && !isSubmitting
            && !requiresReview
    }
}

struct PromptResubmitSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: PromptResubmitSelection
    let submit: @MainActor (
        PromptResubmitSelection,
        String
    ) async throws -> PromptResubmitAdmissionResult
    let refresh: @MainActor () async -> Void

    @State private var draft: String
    @State private var isSubmitting = false
    @State private var failureMessage: String?
    @State private var requiresReview = false

    init(
        selection: PromptResubmitSelection,
        submit: @escaping @MainActor (
            PromptResubmitSelection,
            String
        ) async throws -> PromptResubmitAdmissionResult,
        refresh: @escaping @MainActor () async -> Void
    ) {
        self.selection = selection
        self.submit = submit
        self.refresh = refresh
        _draft = State(initialValue: selection.baselineText)
    }

    private var draftState: PromptResubmitDraftState {
        PromptResubmitDraftState(
            baselineText: selection.baselineText,
            draft: draft,
            isSubmitting: isSubmitting,
            requiresReview: requiresReview
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Edited prompt for new branch")
                        .accessibilityIdentifier("prompt-resubmit-text")

                    Text("\(draft.utf16.count) / \(MessageEditRequest.maximumTextUTF16Length)")
                        .font(.caption)
                        .foregroundStyle(
                            draft.utf16.count > MessageEditRequest.maximumTextUTF16Length
                                ? .red : .secondary
                        )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    Text("Edit prompt")
                } footer: {
                    Text(
                        "Your original prompt and its replies stay unchanged. This sends the edited text as a new conversation branch."
                    )
                }

                if let failureMessage {
                    Section("Prompt not sent") {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        if requiresReview {
                            Button("Close and refresh conversation") {
                                Task { @MainActor in
                                    await refresh()
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit and send as new branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send as new branch") { performSubmit() }
                        .disabled(!draftState.canSubmit)
                        .accessibilityHint(
                            "Keeps the original prompt and replies, then generates a new branch."
                        )
                        .accessibilityIdentifier("prompt-resubmit-send")
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Submitting edited prompt…")
                        .padding()
                        .adaptiveSurface(in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("prompt-resubmit-progress")
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .accessibilityIdentifier("prompt-resubmit-sheet")
        }
    }

    private func performSubmit() {
        guard draftState.canSubmit else { return }
        isSubmitting = true
        failureMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await submit(selection, draft)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Edited prompt sent as a new branch"
                )
                dismiss()
            } catch is CancellationError {
                failureMessage = "Submission was cancelled."
            } catch {
                // A generation-start failure can be ambiguous. Never offer a
                // second POST from this sheet; refresh and reopen explicitly.
                requiresReview = true
                failureMessage = error.userFacingMessage
            }
        }
    }
}

/// Exact coordinates for regenerating one selected, persisted assistant
/// response. Regeneration creates a sibling response; it never replaces the
/// selected response or any of its descendants.
struct ResponseRegenerationSelection: Identifiable, Equatable, Hashable, Sendable {
    struct ID: Equatable, Hashable, Sendable {
        let conversationID: ConversationID
        let sourceUserMessage: ChatMessage
        let targetAssistantMessage: ChatMessage
        let conversationTarget: ConversationTarget
        let targetLabel: String
    }

    let conversationID: ConversationID
    let sourceUserMessageID: MessageID
    let targetAssistantMessageID: MessageID
    let sourceUserMessage: ChatMessage
    let targetAssistantMessage: ChatMessage
    let conversationTarget: ConversationTarget
    let targetLabel: String

    var id: ID {
        ID(
            conversationID: conversationID,
            sourceUserMessage: sourceUserMessage,
            targetAssistantMessage: targetAssistantMessage,
            conversationTarget: conversationTarget,
            targetLabel: targetLabel
        )
    }
}

enum ResponseRegenerationAdmissionResult: Equatable, Sendable {
    case streaming
    case settled
    case aborted
    case failed
}

enum ResponseRegenerationPresentationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case stale
    case operationInProgress
    case invalidAdmission
    case ambiguousAuthoritativeHistory
    case handoff

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This response cannot be regenerated right now. Close and refresh the conversation."
        case .stale:
            "The selected prompt or response changed. Close and review the refreshed conversation."
        case .operationInProgress:
            "Another response regeneration is already being submitted."
        case .invalidAdmission:
            "LibreChat did not return safe generation ownership for this regeneration."
        case .ambiguousAuthoritativeHistory:
            "LibreChat returned history that could not safely identify the regenerated response. Close and refresh the conversation."
        case .handoff:
            "A different response won generation admission. The requested regeneration was not started."
        }
    }
}

/// Pure button state used by the confirmation surface and presentation tests.
struct ResponseRegenerationConfirmationState: Equatable, Sendable {
    let isSubmitting: Bool
    let requiresReview: Bool

    var canSubmit: Bool { !isSubmitting && !requiresReview }
}

struct ResponseRegenerationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: ResponseRegenerationSelection
    let submit: @MainActor (
        ResponseRegenerationSelection
    ) async throws -> ResponseRegenerationAdmissionResult
    let refresh: @MainActor () async -> Void

    @State private var isSubmitting = false
    @State private var failureMessage: String?
    @State private var requiresReview = false

    private var confirmationState: ResponseRegenerationConfirmationState {
        ResponseRegenerationConfirmationState(
            isSubmitting: isSubmitting,
            requiresReview: requiresReview
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "The existing response and its replies stay unchanged.",
                        systemImage: "arrow.triangle.branch"
                    )
                    Text(
                        "A new response branch will be generated using the current chat target: \(selection.targetLabel)."
                    )
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Create another response")
                }

                if let failureMessage {
                    Section("Response not regenerated") {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)

                        if requiresReview {
                            Button("Close and refresh conversation") {
                                Task { @MainActor in
                                    await refresh()
                                    dismiss()
                                }
                            }
                            .accessibilityIdentifier("response-regeneration-refresh")
                        }
                    }
                }
            }
            .navigationTitle("Regenerate response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Regenerate") { performSubmit() }
                        .disabled(!confirmationState.canSubmit)
                        .accessibilityHint(
                            "Keeps the existing response and creates a new response branch using the current chat target."
                        )
                        .accessibilityIdentifier("response-regeneration-submit")
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Starting regeneration…")
                        .padding()
                        .adaptiveSurface(in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("response-regeneration-progress")
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .accessibilityIdentifier("response-regeneration-sheet")
        }
    }

    private func performSubmit() {
        guard confirmationState.canSubmit else { return }
        isSubmitting = true
        failureMessage = nil
        Task { @MainActor in
            defer { isSubmitting = false }
            do {
                _ = try await submit(selection)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Response regeneration started as a new branch"
                )
                dismiss()
            } catch is CancellationError {
                requiresReview = true
                failureMessage = "Regeneration was cancelled. Refresh before trying again."
            } catch {
                // Admission can be ambiguous. This surface never repeats the
                // generation POST; refresh and explicitly reopen the action.
                requiresReview = true
                failureMessage = error.userFacingMessage
            }
        }
    }
}
