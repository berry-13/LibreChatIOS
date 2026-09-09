import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI

@MainActor
@Observable
final class SharedSnapshotModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let shareID: SharedLinkID
    private let repository: any SharedSnapshotRepository
    private let onUnauthorized: @MainActor () async -> Void

    private(set) var state: State = .idle
    private(set) var snapshot: SharedConversationSnapshot?
    private(set) var isForking = false
    private(set) var operationError: String?
    private(set) var forkUnavailableReason: String?
    private(set) var forkOutcomeMayBeAmbiguous = false
    private var loadEpoch = 0

    var canForkSnapshot: Bool {
        state == .loaded
            && snapshot?.revision != nil
            && !forkOutcomeMayBeAmbiguous
            && forkUnavailableReason == nil
    }

    init(
        shareID: SharedLinkID,
        repository: any SharedSnapshotRepository,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.shareID = shareID
        self.repository = repository
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard !isForking else { return }
        loadEpoch &+= 1
        let epoch = loadEpoch
        state = .loading
        operationError = nil
        do {
            let loadedSnapshot = try await repository.sharedSnapshot(for: shareID)
            guard epoch == loadEpoch else { return }
            install(loadedSnapshot)
        } catch {
            guard !(error is CancellationError) else { return }
            guard epoch == loadEpoch else { return }
            // The snapshot endpoint is anonymous (.none authorization): a
            // 401 says the share is unavailable or restricted, NOT that the
            // signed-in viewer's session expired — never clear the session.
            // RESTClient.validate folds every 401 into `.unauthorized`, even
            // for anonymous requests, so both spellings map here.
            if Self.isShareAccessRejection(error) {
                snapshot = nil
                state = .failed("This shared snapshot is unavailable or requires authentication on the web.")
                return
            }
            if error.isUnauthorized { await onUnauthorized() }
            snapshot = nil
            forkUnavailableReason = nil
            if let protocolError = error as? LibreChatProtocolError,
               case .httpStatus(404, _, _) = protocolError {
                state = .failed("This shared snapshot is no longer available.")
            } else {
                state = .failed(error.userFacingMessage)
            }
        }
    }

    func fork() async -> SharedConversationForkResult? {
        guard !isForking,
              state == .loaded,
              let currentSnapshot = snapshot else { return nil }
        guard let revision = currentSnapshot.revision else {
            forkUnavailableReason = "This server did not provide a snapshot revision, so the app cannot safely create a copy."
            return nil
        }
        guard !forkOutcomeMayBeAmbiguous, forkUnavailableReason == nil else { return nil }

        loadEpoch &+= 1
        isForking = true
        operationError = nil
        defer { isForking = false }
        do {
            return try await repository.forkSharedConversation(.init(
                shareID: shareID,
                targetMessageIndex: currentSnapshot.messages.indices.last,
                shareRevision: revision
            ))
        } catch let error as LibreChatProtocolError {
            switch error {
            case .httpStatus(409, _, _):
                let conflictMessage = "This shared snapshot changed before it could be copied. Review the refreshed version, then try again."
                do {
                    let refreshedSnapshot = try await repository.sharedSnapshot(for: shareID)
                    install(refreshedSnapshot)
                    operationError = conflictMessage
                } catch let refreshError as LibreChatProtocolError {
                    await handleForkRefreshFailure(refreshError, prefix: conflictMessage)
                } catch {
                    operationError = "\(conflictMessage) The refreshed snapshot could not be loaded."
                }
                return nil
            case .httpStatus(404, _, _):
                snapshot = nil
                forkUnavailableReason = nil
                state = .failed("This shared snapshot is no longer available.")
                return nil
            case .httpStatus(403, _, _):
                forkUnavailableReason = "Your account is not allowed to copy this shared snapshot. You can still read it here."
                return nil
            case .transport:
                forkOutcomeMayBeAmbiguous = true
                forkUnavailableReason = "The connection ended before LibreChat confirmed the copy. It may already exist, so refresh your chat list before trying again."
                return nil
            case .serverNotReady, .decoding, .invalidResponse:
                // A committed copy can hide behind any post-dispatch failure;
                // retry stays locked until the chat list is reconciled.
                forkOutcomeMayBeAmbiguous = true
                forkUnavailableReason = "LibreChat's response was lost or unreadable. The copy may already exist, so refresh your chat list before trying again."
                return nil
            case let .httpStatus(status, _, _) where (500...599).contains(status):
                forkOutcomeMayBeAmbiguous = true
                forkUnavailableReason = "LibreChat failed after accepting the copy request. It may already exist, so refresh your chat list before trying again."
                return nil
            default:
                if error.isUnauthorized { await onUnauthorized() }
                operationError = error.userFacingMessage
                return nil
            }
        } catch {
            // A cancellation after the non-retried POST reached the server
            // leaves the outcome unknown: the copy may already exist, so a
            // retry is locked out until the user reconciles via refresh.
            guard !(error is CancellationError) else {
                forkOutcomeMayBeAmbiguous = true
                forkUnavailableReason = "The copy request was interrupted. It may already exist, so refresh your chat list before trying again."
                return nil
            }
            // A malformed success body is equally ambiguous.
            if error is DTOMapperError {
                forkOutcomeMayBeAmbiguous = true
                forkUnavailableReason = "LibreChat's response was unreadable. The copy may already exist, so refresh your chat list before trying again."
                return nil
            }
            operationError = error.userFacingMessage
            return nil
        }
    }

    private func install(_ loadedSnapshot: SharedConversationSnapshot) {
        snapshot = loadedSnapshot
        state = .loaded
        if forkOutcomeMayBeAmbiguous {
            forkUnavailableReason = "The previous copy request may have succeeded. Refresh your chat list before trying again."
        } else if loadedSnapshot.revision == nil {
            forkUnavailableReason = "This server did not provide a snapshot revision, so the app cannot safely create a copy."
        } else {
            forkUnavailableReason = nil
        }
    }

    /// The share endpoint makes no authenticated request of its own, so both
    /// the raw 401 status and validate's folded `.unauthorized` mean the
    /// share itself rejected the anonymous read.
    private static func isShareAccessRejection(_ error: Error) -> Bool {
        guard let protocolError = error as? LibreChatProtocolError else { return false }
        switch protocolError {
        case .httpStatus(401, _, _), .unauthorized:
            return true
        default:
            return false
        }
    }

    private func handleForkRefreshFailure(
        _ error: LibreChatProtocolError,
        prefix: String
    ) async {
        switch error {
        case .httpStatus(404, _, _):
            snapshot = nil
            forkUnavailableReason = nil
            state = .failed("This shared snapshot is no longer available.")
        case .httpStatus(403, _, _):
            forkUnavailableReason = "Your account is no longer allowed to access this shared snapshot."
            operationError = prefix
        default:
            // The refreshed load is anonymous too: its 401s are share-access
            // failures and must never clear the signed-in viewer's session.
            if Self.isShareAccessRejection(error) {
                snapshot = nil
                forkUnavailableReason = nil
                state = .failed("This shared snapshot is unavailable or requires authentication on the web.")
                return
            }
            if error.isUnauthorized { await onUnauthorized() }
            operationError = "\(prefix) The refreshed snapshot could not be loaded."
        }
    }
}

struct SharedSnapshotView: View {
    let baseURL: URL
    let canFork: Bool
    let onForked: @MainActor (LibreChatDomain.Conversation) -> Void
    @State private var model: SharedSnapshotModel
    @State private var isConfirmingFork = false
    @State private var forkedConversation: LibreChatDomain.Conversation?

    init(
        shareID: SharedLinkID,
        baseURL: URL,
        repository: any SharedSnapshotRepository,
        canFork: Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onForked: @escaping @MainActor (LibreChatDomain.Conversation) -> Void
    ) {
        self.baseURL = baseURL
        self.canFork = canFork
        self.onForked = onForked
        _model = State(initialValue: SharedSnapshotModel(
            shareID: shareID,
            repository: repository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                SkeletonConversationView(accessibilityLabel: "Loading shared snapshot")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Shared snapshot unavailable", systemImage: "link.badge.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.reload() } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded:
                snapshotContent
            }
        }
        .navigationTitle(model.snapshot?.title?.nonEmpty ?? "Shared conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canFork, model.snapshot != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Continue as new chat", systemImage: "arrow.triangle.branch") {
                        isConfirmingFork = true
                    }
                    .disabled(model.isForking || !model.canForkSnapshot)
                    .accessibilityHint("Copies this snapshot into your LibreChat account.")
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .confirmationDialog(
            "Continue from this snapshot?",
            isPresented: $isConfirmingFork,
            titleVisibility: .visible
        ) {
            Button("Create new chat") {
                Task {
                    guard let result = await model.fork() else { return }
                    forkedConversation = result.conversation
                    onForked(result.conversation)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LibreChat will create a private copy in your account. The published snapshot will not be changed.")
        }
        .alert("New chat created", isPresented: Binding(
            get: { forkedConversation != nil },
            set: { if !$0 { forkedConversation = nil } }
        )) {
            Button("OK") { forkedConversation = nil }
        } message: {
            Text("The copied conversation is ready in your chat list.")
        }
    }

    @ViewBuilder
    private var snapshotContent: some View {
        if let snapshot = model.snapshot {
            ScrollView {
                LazyVStack(spacing: 18) {
                    Label(
                        "Published snapshot · read only",
                        systemImage: "camera.viewfinder"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if snapshot.messages.isEmpty {
                        ContentUnavailableView(
                            "No shared messages",
                            systemImage: "bubble.left",
                            description: Text("This snapshot does not currently contain any messages.")
                        )
                        .padding(.top, 60)
                    } else {
                        ForEach(snapshot.messages) { message in
                            SharedSnapshotMessageRow(message: message, baseURL: baseURL)
                        }
                    }

                    if let error = model.operationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if canFork, let reason = model.forkUnavailableReason {
                        Label(reason, systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if model.isForking {
                    ProgressView("Creating private copy…")
                        .padding(18)
                        .adaptiveSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }
}

struct SharedLinkEntryView: View {
    let baseURL: URL
    let repository: any SharedSnapshotRepository
    let canFork: Bool
    let onUnauthorized: @MainActor () async -> Void
    let onForked: @MainActor (LibreChatDomain.Conversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var errorMessage: String?
    @State private var path: [SharedLinkID] = []
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField("Shared link or share ID", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isInputFocused)
                        .submitLabel(.go)
                        .onSubmit(open)

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button("Open shared snapshot", action: open)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Only links from \(baseURL.host ?? baseURL.absoluteString) can be opened while this server is selected.")
                }
            }
            .navigationTitle("Open shared link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SharedLinkID.self) { shareID in
                SharedSnapshotView(
                    shareID: shareID,
                    baseURL: baseURL,
                    repository: repository,
                    canFork: canFork,
                    onUnauthorized: onUnauthorized,
                    onForked: onForked
                )
            }
            .onAppear { isInputFocused = true }
        }
    }

    private func open() {
        do {
            let shareID = try SharedLinkAddress.parse(input, serverBaseURL: baseURL)
            errorMessage = nil
            if path.last != shareID { path.append(shareID) }
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}

private struct SharedSnapshotMessageRow: View {
    let message: SharedSnapshotMessage
    let baseURL: URL

    private var isUser: Bool {
        if case .user = message.author { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 44) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                Text(message.author.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(message.content.enumerated()), id: \.offset) { _, content in
                        MessageContentView(content: resolvedContent(content))
                    }
                    ForEach(message.files) { file in
                        if let fileURL = resolvedURL(file.access.path) {
                            Link(destination: fileURL) {
                                Label("Open \(file.filename)", systemImage: "doc")
                            }
                            .accessibilityHint("Opens the share-authorized file.")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .background(
                isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .frame(maxWidth: 680, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func resolvedContent(_ content: MessageContent) -> MessageContent {
        switch content {
        case let .image(url, alternativeText):
            return .image(resolvedURL(url) ?? url, alternativeText: alternativeText)
        case let .video(url, alternativeText):
            return .video(resolvedURL(url) ?? url, alternativeText: alternativeText)
        case let .audio(url, transcript):
            return .audio(resolvedURL(url) ?? url, transcript: transcript)
        default:
            return content
        }
    }

    private func resolvedURL(_ url: URL) -> URL? {
        guard url.scheme == nil else { return url }
        return resolvedURL(url.path)
    }

    private func resolvedURL(_ path: String) -> URL? {
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let directoryBaseURL = baseURL.absoluteString.hasSuffix("/")
            ? baseURL
            : baseURL.appendingPathComponent("", isDirectory: true)
        return URL(string: relativePath, relativeTo: directoryBaseURL)?.absoluteURL
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
