import LibreChatDomain
import SwiftUI
import UIKit

struct MessageFeedbackSelection: Identifiable, Hashable {
    let profileID: ServerProfileID
    let accountID: AccountID
    let coordinate: MessageFeedbackCoordinate
    let currentFeedback: MessageFeedback?
    let suggestedRating: MessageFeedbackRating

    var id: Self { self }
}

@MainActor
struct MessageFeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selection: MessageFeedbackSelection
    let save: @MainActor (
        MessageFeedbackSelection,
        MessageFeedback?
    ) async throws -> MessageFeedbackResolution
    let refresh: @MainActor () async -> Void

    @State private var rating: MessageFeedbackRating
    @State private var tag: MessageFeedbackTag?
    @State private var details: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var requiresRefresh = false

    init(
        selection: MessageFeedbackSelection,
        save: @escaping @MainActor (
            MessageFeedbackSelection,
            MessageFeedback?
        ) async throws -> MessageFeedbackResolution,
        refresh: @escaping @MainActor () async -> Void
    ) {
        self.selection = selection
        self.save = save
        self.refresh = refresh
        _rating = State(initialValue: selection.currentFeedback?.rating ?? selection.suggestedRating)
        _tag = State(initialValue: selection.currentFeedback?.tag)
        _details = State(initialValue: selection.currentFeedback?.text ?? "")
    }

    private var availableTags: [MessageFeedbackTag] {
        MessageFeedbackTag.tags(for: rating)
    }

    private var isOtherExplanationMissing: Bool {
        tag == .other && details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        tag != nil
            && !isOtherExplanationMissing
            && details.utf16.count <= MessageFeedbackRequest.maximumTextUTF16Length
            && !isSaving
            && !requiresRefresh
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Rating", selection: $rating) {
                        Label("Helpful", systemImage: "hand.thumbsup").tag(MessageFeedbackRating.thumbsUp)
                        Label("Needs work", systemImage: "hand.thumbsdown").tag(MessageFeedbackRating.thumbsDown)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSaving || requiresRefresh)
                    .onChange(of: rating) { previous, current in
                        guard previous != current else { return }
                        tag = nil
                    }
                } footer: {
                    Text("Feedback is saved to this LibreChat message and may be sent to the server owner’s configured observability service.")
                }

                Section("What stood out?") {
                    ForEach(availableTags, id: \.self) { option in
                        Button {
                            tag = option
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if tag == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving || requiresRefresh)
                        .accessibilityAddTraits(tag == option ? .isSelected : [])
                    }
                }

                Section {
                    TextField(
                        tag == .other ? "Explain what happened" : "Add details (optional)",
                        text: $details,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .disabled(isSaving || requiresRefresh)

                    HStack {
                        if isOtherExplanationMissing {
                            Text("A short explanation is required for Something else.")
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Text("\(details.utf16.count)/\(MessageFeedbackRequest.maximumTextUTF16Length)")
                            .monospacedDigit()
                            .foregroundStyle(
                                details.utf16.count > MessageFeedbackRequest.maximumTextUTF16Length
                                    ? Color.red
                                    : Color.secondary
                            )
                    }
                    .font(.caption)
                } header: {
                    Text("Details")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if requiresRefresh {
                            Button("Close and refresh conversation") {
                                Task { await closeAndRefresh() }
                            }
                            .disabled(isSaving)
                        }
                    }
                }

                if selection.currentFeedback != nil {
                    Section {
                        Button("Clear feedback", role: .destructive) {
                            Task { await submit(nil) }
                        }
                        .disabled(isSaving || requiresRefresh)
                    }
                }
            }
            .navigationTitle(selection.currentFeedback == nil ? "Response feedback" : "Edit feedback")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task {
                            guard let tag else { return }
                            let text = details.isEmpty ? nil : details
                            await submit(MessageFeedback(tag: tag, text: text))
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .accessibilityIdentifier("message-feedback-sheet")
    }

    private func submit(_ feedback: MessageFeedback?) async {
        guard !isSaving, !requiresRefresh else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await save(selection, feedback)
            UIAccessibility.post(
                notification: .announcement,
                argument: feedback == nil ? "Feedback cleared" : "Feedback saved"
            )
            dismiss()
        } catch is CancellationError {
            return
        } catch MessageFeedbackError.ambiguous(_) {
            requiresRefresh = true
            errorMessage = "LibreChat may have saved different feedback. Refresh before another change."
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func closeAndRefresh() async {
        guard !isSaving else { return }
        isSaving = true
        await refresh()
        isSaving = false
        dismiss()
    }
}
