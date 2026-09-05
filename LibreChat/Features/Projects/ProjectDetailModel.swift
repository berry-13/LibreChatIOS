import Foundation
import LibreChatDomain
import Observation

/// UI-facing state for one project's conversation collection.
@MainActor
@Observable
final class ProjectDetailModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    private let projectRepository: any ProjectRepository
    private let conversationRepository: any ConversationRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void

    private(set) var project: ChatProject
    private(set) var conversations: [Conversation] = []
    private(set) var nextCursor: String?
    private(set) var state: State = .idle
    private(set) var isLoadingMore = false
    private(set) var isRefreshing = false
    private(set) var availableTargets: [ChatTargetOption] = []
    private(set) var isLoadingTargets = false
    private(set) var errorMessage: String?
    private(set) var targetError: String?

    private var requestRevision: UInt64 = 0

    init(
        project: ChatProject,
        projectRepository: any ProjectRepository,
        conversationRepository: any ConversationRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.project = project
        self.projectRepository = projectRepository
        self.conversationRepository = conversationRepository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    var canMutate: Bool { !isOffline() && state != .unauthorized }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        requestRevision &+= 1
        let revision = requestRevision
        guard !isOffline() else {
            state = .offline
            return
        }

        isRefreshing = !conversations.isEmpty
        if conversations.isEmpty { state = .loading }
        defer { isRefreshing = false }

        do {
            async let projectResult = projectRepository.project(id: project.id)
            async let conversationResult = projectRepository.projectConversations(
                projectID: project.id,
                cursor: nil,
                limit: 25
            )
            let (freshProject, page) = try await (projectResult, conversationResult)
            guard revision == requestRevision else { return }
            project = freshProject
            // Unsent project-scoped drafts exist only on device; a refresh
            // must carry them forward or the user's unsent work becomes
            // unreachable.
            let refreshedIDs = Set(page.conversations.map(\.id))
            let carriedDrafts = conversations.filter { $0.id.isLocalDraft && !refreshedIDs.contains($0.id) }
            conversations = page.conversations + carriedDrafts
            nextCursor = page.nextCursor
            errorMessage = nil
            state = .loaded
        } catch {
            guard revision == requestRevision else { return }
            await handle(error)
        }
    }

    func loadMoreIfNeeded(after conversation: Conversation) async {
        guard conversation.id == conversations.last?.id,
              let nextCursor,
              !isLoadingMore,
              !isOffline(),
              state != .unauthorized else { return }

        let revision = requestRevision
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await projectRepository.projectConversations(
                projectID: project.id,
                cursor: nextCursor,
                limit: 25
            )
            guard revision == requestRevision else { return }
            let existingIDs = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.conversations.filter { !existingIDs.contains($0.id) })
            self.nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            guard revision == requestRevision else { return }
            await handle(error)
        }
    }

    func loadTargets(forceRefresh: Bool = false) async {
        guard !isLoadingTargets else { return }
        guard !isOffline() else {
            availableTargets = []
            targetError = "Chat targets are unavailable offline."
            state = .offline
            return
        }
        if !forceRefresh, !availableTargets.isEmpty { return }

        isLoadingTargets = true
        availableTargets = []
        targetError = nil
        defer { isLoadingTargets = false }
        do {
            availableTargets = try await conversationRepository.availableChatTargets()
        } catch {
            if error.isUnauthorized {
                state = .unauthorized
                await onUnauthorized()
            }
            guard !(error is CancellationError) else { return }
            targetError = error.userFacingMessage
        }
    }

    /// Creates a client-only conversation identity for the composer. The
    /// server still receives `new` when the first message is sent, while the
    /// UUID keeps multiple unsent chats distinct in navigation and drafts.
    @discardableResult
    func createLocalDraft(
        title: String = "New chat",
        target: ChatTargetOption
    ) -> Conversation {
        createLocalDraft(title: title, target: target.target)
    }

    @discardableResult
    func createLocalDraft(
        title: String = "New chat",
        target: ConversationTarget? = nil
    ) -> Conversation {
        let conversation = Conversation(
            id: ConversationID(localDraftID: UUID()),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title,
            model: target?.model,
            target: target,
            projectID: project.id
        )
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
        return conversation
    }

    /// Alias useful to navigation coordinators that describe the action as a
    /// new conversation rather than a local draft.
    @discardableResult
    func newConversation(target: ChatTargetOption, title: String = "New chat") -> Conversation {
        createLocalDraft(title: title, target: target)
    }

    func retry() {
        Task { [weak self] in await self?.reload() }
    }

    private func handle(_ error: Error) async {
        guard !(error is CancellationError) else { return }
        if error.isUnauthorized {
            state = .unauthorized
            await onUnauthorized()
        } else {
            state = .failed(error.userFacingMessage)
        }
        errorMessage = error.userFacingMessage
    }
}
