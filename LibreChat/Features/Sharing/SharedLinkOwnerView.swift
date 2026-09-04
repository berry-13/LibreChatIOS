import LibreChatDomain
import SwiftUI

struct SharedLinkOwnerView: View {
    let targetMessageID: MessageID?
    let supportsFileSnapshots: Bool
    let baseURL: URL
    let snapshotRepository: any SharedSnapshotRepository
    let onUnauthorized: @MainActor () async -> Void
    let onForked: @MainActor (LibreChatDomain.Conversation) -> Void
    @State private var model: SharedLinkOwnerModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingRefresh = false
    @State private var isConfirmingRevoke = false
    @State private var includeAttachedFiles = false

    init(
        conversationID: ConversationID,
        targetMessageID: MessageID?,
        baseURL: URL,
        repository: any SharedLinkRepository & SharedSnapshotRepository,
        supportsFileSnapshots: Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onForked: @escaping @MainActor (LibreChatDomain.Conversation) -> Void
    ) {
        self.targetMessageID = targetMessageID
        self.supportsFileSnapshots = supportsFileSnapshots
        self.baseURL = baseURL
        snapshotRepository = repository
        self.onUnauthorized = onUnauthorized
        self.onForked = onForked
        _model = State(initialValue: SharedLinkOwnerModel(
            conversationID: conversationID,
            baseURL: baseURL,
            repository: repository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .loading:
                    SkeletonListView(
                        count: 5,
                        showsSubtitle: true,
                        accessibilityLabel: "Checking shared-link status"
                    )
                case .absent:
                    absentState
                case .available:
                    availableState
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Sharing unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.reload() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Share conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .onChange(of: model.link?.snapshotFiles) { _, snapshotFiles in
            includeAttachedFiles = supportsFileSnapshots && snapshotFiles == true
        }
        .confirmationDialog(
            "Refresh this shared snapshot?",
            isPresented: $isConfirmingRefresh,
            titleVisibility: .visible
        ) {
            Button("Refresh snapshot") {
                Task {
                    _ = await model.refresh(
                        targetMessageID: targetMessageID,
                        snapshotFiles: supportsFileSnapshots && includeAttachedFiles
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The same link will show the conversation through its current last message. "
                    + filePolicySummary
            )
        }
        .confirmationDialog(
            "Revoke this shared link?",
            isPresented: $isConfirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke link", role: .destructive) {
                Task { _ = await model.revoke() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("People using the link will no longer be able to open this snapshot.")
        }
    }

    private var absentState: some View {
        List {
            ContentUnavailableView {
                Label("Share a snapshot", systemImage: "square.and.arrow.up")
            } description: {
                Text(
                    "Create a server-managed, read-only snapshot through the current last message. "
                        + filePolicySummary
                )
            } actions: {
                Button("Create shared link") {
                    Task {
                        _ = await model.create(
                            targetMessageID: targetMessageID,
                            snapshotFiles: supportsFileSnapshots && includeAttachedFiles
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }

            fileSnapshotSection
        }
    }

    private var availableState: some View {
        List {
            Section {
                Label("Shared snapshot is active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let url = model.shareURL {
                    Text(url.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Shared link, \(url.absoluteString)")
                    ShareLink(item: url) {
                        Label("Share link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens the system share sheet.")
                }
                if let shareID = model.link?.shareID {
                    NavigationLink {
                        SharedSnapshotView(
                            shareID: shareID,
                            baseURL: baseURL,
                            repository: snapshotRepository,
                            canFork: true,
                            onUnauthorized: onUnauthorized,
                            onForked: onForked
                        )
                    } label: {
                        Label("Preview published snapshot", systemImage: "eye")
                    }
                }
            } footer: {
                Text("This is a stored snapshot, not a live mirror of future messages.")
            }

            fileSnapshotSection

            Section("Manage snapshot") {
                Button("Refresh through latest message", systemImage: "arrow.clockwise") {
                    isConfirmingRefresh = true
                }
                Button("Revoke shared link", systemImage: "link.badge.minus", role: .destructive) {
                    isConfirmingRevoke = true
                }
            }
            .disabled(model.isWorking)

            if let error = model.operationError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Sharing error: \(error)")
                }
            }
        }
        .overlay {
            if model.isWorking {
                ProgressView()
                    .padding(18)
                    .adaptiveSurface(in: Circle())
                    .accessibilityLabel("Updating shared link")
            }
        }
    }

    @ViewBuilder
    private var fileSnapshotSection: some View {
        Section {
            if supportsFileSnapshots {
                Toggle("Include attached files", isOn: $includeAttachedFiles)
                    .disabled(model.isWorking)
                    .accessibilityHint(
                        "When enabled, LibreChat may make files in this snapshot available through the shared link."
                    )
            } else {
                Label("Attached files will not be included", systemImage: "doc.badge.ellipsis")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Attachments")
        } footer: {
            Text("File sharing is off by default. Enable it only when every attached file is safe to share.")
        }
    }

    private var filePolicySummary: String {
        supportsFileSnapshots && includeAttachedFiles
            ? "Attached files will be included."
            : "Attached files will not be included."
    }
}
