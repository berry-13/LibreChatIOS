import LibreChatDomain
import LibreChatProtocol
import SwiftUI

struct ConversationForkSelection: Identifiable, Equatable, Hashable, Sendable {
    let profileID: ServerProfileID
    let accountID: AccountID
    let sourceConversationID: ConversationID
    let targetMessage: ChatMessage

    var id: String {
        [
            profileID.rawValue,
            accountID.rawValue,
            sourceConversationID.rawValue,
            targetMessage.id.rawValue
        ].joined(separator: "|")
    }
}

enum ConversationForkPresentationError: LocalizedError, Equatable, Sendable {
    case stale
    case invalidResult
    case preflightUnavailable
    case deliveryUncertain
    case rejected
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .stale:
            "The selected conversation path changed. Close and choose the message again."
        case .invalidResult:
            "LibreChat returned an incomplete branched conversation. Refresh the conversation list before trying anything else."
        case .preflightUnavailable:
            "The source conversation could not be verified, so no fork request was sent. You can try again."
        case .deliveryUncertain:
            "LibreChat may have created the branched conversation. This request will not be repeated; close and refresh the conversation list."
        case .rejected:
            "LibreChat did not create this branched conversation."
        case .sessionExpired:
            "Your LibreChat session expired. Sign in again before creating a branched conversation."
        }
    }

    static func from(_ error: Error) -> Self {
        if let presentation = error as? Self { return presentation }
        if error.isUnauthorized { return .sessionExpired }
        if let forkError = error as? ConversationForkError {
            return switch forkError {
            case .ambiguous: .deliveryUncertain
            case .preflightReadFailed: .preflightUnavailable
            case .profileMismatch, .accountMismatch, .preflightValidation: .stale
            }
        }
        if error is ConversationForkValidationError { return .invalidResult }
        if let protocolError = error as? LibreChatProtocolError {
            return switch protocolError {
            case .transport, .invalidResponse, .decoding, .serverNotReady:
                .deliveryUncertain
            case let .httpStatus(status, _, _) where (500..<600).contains(status):
                .deliveryUncertain
            default:
                .rejected
            }
        }
        return .rejected
    }
}

struct ConversationForkSheet: View {
    private enum SubmissionState: Equatable {
        case ready
        case submitting
        case failed(message: String, allowsRetry: Bool)
    }

    @Environment(\.dismiss) private var dismiss
    let selection: ConversationForkSelection
    let submit: @MainActor (ConversationForkSelection) async throws -> ConversationForkResult
    let completed: @MainActor (ConversationForkResult) -> Void
    @State private var submissionState: SubmissionState = .ready

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Original conversation stays unchanged", systemImage: "checkmark.shield")
                    Label("Copies the selected path through this message", systemImage: "arrow.triangle.branch")
                    Label("Creates fresh conversation and message identities", systemImage: "sparkles")
                } header: {
                    Text("Create branched chat")
                } footer: {
                    Text("LibreChat does not provide an idempotency key for this operation. The app submits it once and never retries an uncertain result automatically.")
                }

                switch submissionState {
                case .ready:
                    Section {
                        Button {
                            Task { await submitOnce() }
                        } label: {
                            Label("Create branched chat", systemImage: "arrow.triangle.branch")
                        }
                        .accessibilityHint("Creates one new conversation from the selected message path")
                        .accessibilityIdentifier("submit-conversation-fork")
                    }
                case .submitting:
                    Section {
                        HStack {
                            ProgressView()
                            Text("Creating once…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                case let .failed(message, allowsRetry):
                    Section {
                        Label("Branched chat not confirmed", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message).foregroundStyle(.secondary)
                        if allowsRetry {
                            Button("Try again") { submissionState = .ready }
                                .accessibilityHint("Retries only the source verification that did not send a fork request")
                        }
                        Button("Close and refresh conversations") { dismiss() }
                    }
                }
            }
            .navigationTitle("Branch in New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(submissionState == .submitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(submissionState == .submitting)
                }
            }
        }
        .accessibilityIdentifier("conversation-fork-sheet")
    }

    @MainActor
    private func submitOnce() async {
        guard submissionState == .ready else { return }
        submissionState = .submitting
        do {
            let result = try await submit(selection)
            completed(result)
            dismiss()
        } catch is CancellationError {
            submissionState = .failed(
                message: ConversationForkPresentationError.deliveryUncertain.localizedDescription,
                allowsRetry: false
            )
        } catch {
            let presentation = ConversationForkPresentationError.from(error)
            submissionState = .failed(
                message: presentation.localizedDescription,
                allowsRetry: presentation == .preflightUnavailable
            )
        }
    }
}
