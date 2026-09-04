import LibreChatDomain
import SwiftUI

struct GenerationSteerSelection: Identifiable, Equatable, Hashable, Sendable {
    let handle: GenerationHandle
    let clientSteerID: String

    var id: String {
        [
            handle.profileID.rawValue,
            handle.accountID.rawValue,
            handle.conversationID.rawValue,
            handle.streamID,
            String(handle.generationCreatedAt ?? -1),
            clientSteerID
        ].joined(separator: "|")
    }
}

struct GenerationSteerDraftState: Equatable, Sendable {
    static let maximumUTF16Length = 16_000

    let normalizedText: String
    let utf16Count: Int

    init(draft: String) {
        normalizedText = draft
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        utf16Count = normalizedText.utf16.count
    }

    var canSubmit: Bool {
        (1...Self.maximumUTF16Length).contains(utf16Count)
    }

    var validationMessage: String? {
        if normalizedText.isEmpty {
            return "Write how you want the current response to change."
        }
        if utf16Count > Self.maximumUTF16Length {
            return "Shorten this direction to 16,000 characters or fewer."
        }
        return nil
    }
}

enum GenerationSteeringPresentationError: LocalizedError, Equatable, Sendable {
    case invalidText
    case generationChanged
    case staleAcknowledgement
    case unavailable
    case rejected
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidText:
            "Write a valid response direction before submitting."
        case .generationChanged:
            "This response changed before the direction could be submitted. Close and review the current response."
        case .staleAcknowledgement:
            "LibreChat replied after this response changed. The direction will not be submitted again; review the current response."
        case .unavailable:
            "Response guidance is not available for this generation."
        case .rejected:
            "LibreChat rejected this direction. It was not submitted again."
        case .sessionExpired:
            "Your LibreChat session expired. Sign in again before guiding a response."
        }
    }

    static func from(_ error: Error) -> Self {
        if let presentation = error as? Self { return presentation }
        if error.isUnauthorized { return .sessionExpired }
        if let steeringError = error as? GenerationSteeringError {
            return switch steeringError {
            case .emptyText, .textTooLong: .invalidText
            case .contextMismatch, .invalidConversation, .invalidGenerationEpoch,
                 .protocolMismatch, .inactiveGeneration, .invalidClientSteerID,
                 .invalidSteerID:
                .generationChanged
            }
        }
        return .rejected
    }
}

struct GenerationSteerSheet: View {
    private enum SubmissionState: Equatable {
        case editing
        case submitting
        case completed(title: String, message: String)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    let selection: GenerationSteerSelection
    let submit: @MainActor (
        GenerationSteerSelection,
        String,
        Bool
    ) async throws -> GenerationSteerSubmissionOutcome

    @State private var draft = ""
    @State private var applySooner = false
    @State private var submissionState: SubmissionState = .editing

    private var draftState: GenerationSteerDraftState {
        GenerationSteerDraftState(draft: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Describe how the response should change",
                        text: $draft,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                    .disabled(submissionState != .editing)
                    .accessibilityLabel("Response direction")
                    .accessibilityIdentifier("steer-direction")

                    HStack {
                        Text(draftState.validationMessage ?? "Guides this response without creating a new message.")
                        Spacer()
                        Text("\(draftState.utf16Count) / \(GenerationSteerDraftState.maximumUTF16Length)")
                    }
                    .font(.caption)
                    .foregroundStyle(draftState.validationMessage == nil ? Color.secondary : Color.red)
                } header: {
                    Text("Guide current response")
                } footer: {
                    Text("This applies only to the exact response currently being generated.")
                }

                Section {
                    Toggle("Try to apply sooner", isOn: $applySooner)
                        .disabled(submissionState != .editing)
                        .accessibilityHint(
                            "LibreChat may fall back to the next normal boundary when this run cannot apply the direction sooner."
                        )
                } footer: {
                    Text("The server decides whether this run can safely apply the direction sooner.")
                }

                switch submissionState {
                case .editing:
                    EmptyView()
                case .submitting:
                    Section {
                        HStack {
                            ProgressView()
                            Text("Submitting once…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                case let .completed(title, message):
                    Section {
                        Label(title, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(message).foregroundStyle(.secondary)
                        Button("Close") { dismiss() }
                    }
                case let .failed(message):
                    Section {
                        Label("Direction not submitted", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message).foregroundStyle(.secondary)
                        Button("Close and review response") { dismiss() }
                    }
                }
            }
            .navigationTitle("Guide Response")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(submissionState == .submitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(submissionState == .submitting)
                }
                if submissionState == .editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit") {
                            Task { await submitOnce() }
                        }
                        .disabled(!draftState.canSubmit)
                        .accessibilityHint("Submits this direction once to the current generation")
                        .accessibilityIdentifier("submit-steer")
                    }
                }
            }
        }
        .accessibilityIdentifier("steer-sheet")
    }

    @MainActor
    private func submitOnce() async {
        guard submissionState == .editing, draftState.canSubmit else { return }
        submissionState = .submitting
        do {
            let outcome = try await submit(selection, draftState.normalizedText, applySooner)
            switch outcome {
            case let .queued(receipt):
                if applySooner, !receipt.preempt {
                    submissionState = .completed(
                        title: "Direction queued",
                        message: "This run will apply it at the next normal response boundary."
                    )
                } else {
                    dismiss()
                }
            case .replayed:
                submissionState = .completed(
                    title: "Direction already queued",
                    message: "LibreChat recognized the original submission. It was not sent twice."
                )
            case .settled:
                submissionState = .completed(
                    title: "Direction already processed",
                    message: "The response state is being refreshed from LibreChat."
                )
            case .leftover:
                submissionState = .completed(
                    title: "Direction saved for recovery",
                    message: "The response ended before applying it. The words will not be sent as a new message without an explicit choice."
                )
            case .deliveryUncertain:
                submissionState = .failed(
                    "Syncing your direction…"
                )
            }
        } catch is CancellationError {
            submissionState = .failed("Submission was interrupted. Review the current response before trying another direction.")
        } catch {
            submissionState = .failed(
                GenerationSteeringPresentationError.from(error).localizedDescription
            )
        }
    }
}

struct PendingSteerStrip: View {
    let steers: [PendingSteer]
    let isBusy: Bool
    let cancel: (PendingSteer) -> Void
    let arm: (PendingSteer) -> Void

    var body: some View {
        if !steers.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(steers) { steer in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                steer.preempt == true ? "Applying sooner" : "Waiting direction",
                                systemImage: steer.preempt == true
                                    ? "bolt.horizontal.circle.fill"
                                    : "arrow.triangle.turn.up.right.diamond"
                            )
                            .font(.caption.weight(.semibold))

                            Text(steer.text)
                                .font(.caption)
                                .lineLimit(2)
                                .frame(maxWidth: 240, alignment: .leading)

                            if steer.clientSteerID != nil {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) { controls(for: steer) }
                                    VStack(alignment: .leading, spacing: 6) { controls(for: steer) }
                                }
                            } else {
                                Text("Syncing…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            .accessibilityLabel("Queued response directions")
            .accessibilityIdentifier("pending-steers")
        }
    }

    @ViewBuilder
    private func controls(for steer: PendingSteer) -> some View {
        if steer.preempt != true {
            Button("Apply sooner") { arm(steer) }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityHint("Requests the next safe response boundary without resending the direction")
        }
        Button("Cancel", role: .destructive) { cancel(steer) }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityHint("Requests removal of this exact queued direction")
    }
}

/// Compact queued-message chips that sit directly above the composer pill:
/// status icon, one-line preview, and only the controls each state needs.
/// The primary cancel lives in the composer's send slot (the X), so these
/// rows stay a single compact line tall.
struct FollowUpQueueStrip: View {
    let items: [FollowUpQueueItem]
    let isBusy: Bool
    let canRetry: (FollowUpQueueItem) -> Bool
    let retry: (FollowUpQueueItem) -> Void
    let remove: (FollowUpQueueItem) -> Void

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.id) { item in
                        HStack(spacing: 8) {
                            Image(systemName: statusIcon(for: item.state))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusTint(for: item.state))
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(statusTitle(for: item.state))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.text)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 190, alignment: .leading)
                            }

                            if !item.attachments.isEmpty {
                                Label(
                                    "\(item.attachments.count)",
                                    systemImage: "paperclip"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            if case .queued = item.state, canRetry(item) {
                                Button("Retry") { retry(item) }
                                    .font(.caption2.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isBusy)
                                    .accessibilityHint(
                                        "Retries admission after verifying the exact completed response"
                                    )
                            }

                            if showsRemove(for: item) {
                                Button {
                                    remove(item)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isBusy)
                                .accessibilityLabel(accessibilityRemoveLabel(for: item))
                                .accessibilityHint(
                                    isBlocked(item)
                                        ? "Removes this definitively rejected local follow-up"
                                        : "Removes this unsent local follow-up"
                                )
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                        .padding(.vertical, 7)
                        .frame(minHeight: 40)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground).opacity(0.92),
                            in: Capsule()
                        )
                        .adaptiveGlass(in: Capsule())
                        .accessibilityElement(children: .contain)
                        .accessibilityHint(accessibilityHint(for: item.state) ?? "")
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityLabel("Next messages")
            .accessibilityIdentifier("follow-up-queue")
        }
    }

    private func showsRemove(for item: FollowUpQueueItem) -> Bool {
        switch item.state {
        case .queued, .blocked:
            true
        default:
            false
        }
    }

    private func isBlocked(_ item: FollowUpQueueItem) -> Bool {
        if case .blocked = item.state { return true }
        return false
    }

    private func statusTint(for state: FollowUpQueueItemState) -> Color {
        switch state {
        case .blocked, .deliveryUncertain:
            .orange
        case .committed, .delivered, .deliveredWithoutEpoch:
            .green
        default:
            .secondary
        }
    }

    private func accessibilityRemoveLabel(for item: FollowUpQueueItem) -> String {
        isBlocked(item)
            ? "Remove rejected next message"
            : "Remove next message"
    }

    private func accessibilityHint(for state: FollowUpQueueItemState) -> String? {
        switch state {
        case .queued, .deliveredWithoutEpoch, .delivered:
            nil
        case .reserved:
            "LibreChat admission is being prepared without retries."
        case .admitted:
            "LibreChat accepted this exact message."
        case .blocked:
            "Review is required before another send."
        case .deliveryUncertain:
            "This message will not be posted again until its status is proven."
        case .committed:
            "The user message exists; generation status is still being reconciled."
        }
    }

    private func statusTitle(for state: FollowUpQueueItemState) -> String {
        switch state {
        case .queued: "Next message"
        case .reserved: "Preparing once"
        case .admitted: "Sending next"
        case .blocked: "Needs review"
        case .deliveryUncertain: "Checking delivery"
        case .committed: "Message saved"
        case .deliveredWithoutEpoch: "Delivered"
        case .delivered: "Delivered"
        }
    }

    private func statusIcon(for state: FollowUpQueueItemState) -> String {
        switch state {
        case .queued: "text.badge.plus"
        case .reserved: "hourglass"
        case .admitted: "arrow.up.circle.fill"
        case .blocked: "exclamationmark.triangle"
        case .deliveryUncertain: "questionmark.circle"
        case .committed: "checkmark.circle"
        case .deliveredWithoutEpoch: "checkmark.circle.fill"
        case .delivered: "checkmark.circle.fill"
        }
    }
}

struct RecoverableSteerStrip: View {
    let batches: [RecoverableSteerBatch]
    let isBusy: Bool
    let canQueue: (PendingSteer, RecoverableSteerBatch) -> Bool
    let queue: (PendingSteer, RecoverableSteerBatch) -> Void
    let discard: (PendingSteer, RecoverableSteerBatch) -> Void

    var body: some View {
        if !batches.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Saved response directions", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))

                ForEach(batches, id: \.handle) { batch in
                    ForEach(batch.steers, id: \.recoveryIdentity) { steer in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(steer.text)
                                .font(.callout)
                                .lineLimit(4)
                                .textSelection(.enabled)

                            if !steer.files.isEmpty {
                                Label(
                                    "This direction includes files. Keep or dismiss it here; file-safe next-turn recovery is not enabled yet.",
                                    systemImage: "paperclip"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { controls(steer: steer, batch: batch) }
                                VStack(alignment: .leading, spacing: 8) {
                                    controls(steer: steer, batch: batch)
                                }
                            }
                        }
                        .padding(10)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recoverable-directions")
        }
    }

    @ViewBuilder
    private func controls(steer: PendingSteer, batch: RecoverableSteerBatch) -> some View {
        Button("Send as next message") { queue(steer, batch) }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || !canQueue(steer, batch))
            .accessibilityHint(
                canQueue(steer, batch)
                    ? "Queues this exact saved text after its completed response"
                    : "Keep this direction until its completed response coordinates can be proven"
            )
        Button("Dismiss", role: .destructive) { discard(steer, batch) }
            .buttonStyle(.bordered)
            .disabled(isBusy || steer.clientSteerID == nil)
            .accessibilityHint("Requests one exact server-confirmed discard; uncertain results are not repeated")
    }
}
