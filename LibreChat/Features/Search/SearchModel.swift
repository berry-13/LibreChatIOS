import Foundation
import LibreChatDomain
import Observation

@MainActor
@Observable
final class SearchModel {
    enum Scope: String, CaseIterable, Identifiable {
        case conversations = "Chats"
        case messages = "Messages"

        var id: Self { self }
    }

    enum State: Equatable {
        case idle
        case searching
        case loaded
        case failed(String)
    }

    private let repository: any ConversationRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private let debounce: @Sendable () async throws -> Void
    private var searchTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0

    var query = ""
    var scope: Scope = .conversations
    private(set) var state: State = .idle
    private(set) var conversationResults: [LibreChatDomain.Conversation] = []
    private(set) var messageResults: [MessageSearchResult] = []
    private(set) var nextConversationCursor: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?

    init(
        repository: any ConversationRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        debounce: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(350))
        }
    ) {
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
        self.debounce = debounce
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool { !normalizedQuery.isEmpty }

    var resultsAreStale: Bool {
        guard state == .searching else { return false }
        return !conversationResults.isEmpty || !messageResults.isEmpty
    }

    func queryChanged() {
        searchTask?.cancel()
        requestGeneration &+= 1
        paginationError = nil
        guard isActive else {
            state = .idle
            conversationResults = []
            messageResults = []
            nextConversationCursor = nil
            return
        }

        state = .searching
        let expectedQuery = normalizedQuery
        let expectedScope = scope
        let expectedGeneration = requestGeneration
        searchTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.debounce()
                guard !Task.isCancelled else { return }
                await self.performSearch(
                    query: expectedQuery,
                    scope: expectedScope,
                    generation: expectedGeneration
                )
            } catch {
                // A newer query cancelled this debounce task.
            }
        }
    }

    func scopeChanged() {
        guard isActive else { return }
        searchTask?.cancel()
        requestGeneration &+= 1
        state = .searching
        let expectedQuery = normalizedQuery
        let expectedScope = scope
        let expectedGeneration = requestGeneration
        searchTask = Task { [weak self] in
            await self?.performSearch(
                query: expectedQuery,
                scope: expectedScope,
                generation: expectedGeneration
            )
        }
    }

    func retry() {
        guard isActive else { return }
        scopeChanged()
    }

    func loadMoreIfNeeded(after conversation: LibreChatDomain.Conversation) async {
        guard scope == .conversations,
              conversation.id == conversationResults.last?.id,
              let nextConversationCursor,
              !isLoadingMore,
              !isOffline(),
              isActive else { return }

        let expectedQuery = normalizedQuery
        let expectedGeneration = requestGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.searchConversations(
                query: expectedQuery,
                cursor: nextConversationCursor,
                limit: 25
            )
            guard expectedGeneration == requestGeneration,
                  expectedQuery == normalizedQuery,
                  scope == .conversations else { return }
            let existingIDs = Set(conversationResults.map(\.id))
            conversationResults.append(contentsOf: page.conversations.filter { !existingIDs.contains($0.id) })
            self.nextConversationCursor = page.nextCursor
            paginationError = nil
        } catch {
            // A superseded request's failure belongs to the result set the
            // user already replaced — never to the newer one.
            guard expectedGeneration == requestGeneration,
                  expectedQuery == normalizedQuery,
                  scope == .conversations else { return }
            if error.isUnauthorized { await onUnauthorized() }
            guard !(error is CancellationError) else { return }
            paginationError = error.userFacingMessage
        }
    }

    private func performSearch(query: String, scope: Scope, generation: UInt64) async {
        do {
            if isOffline() {
                guard scope == .conversations else {
                    throw OfflineSearchError.messagesUnavailable
                }
                let page = try await repository.cachedConversations(limit: 500)
                let candidates = page?.conversations ?? []
                let matches = candidates.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || ($0.model?.localizedCaseInsensitiveContains(query) == true)
                }
                guard generation == requestGeneration,
                      query == normalizedQuery,
                      scope == self.scope else { return }
                conversationResults = matches
                messageResults = []
                nextConversationCursor = nil
                state = .loaded
                return
            }

            switch scope {
            case .conversations:
                let page = try await repository.searchConversations(query: query, cursor: nil, limit: 25)
                guard generation == requestGeneration,
                      query == normalizedQuery,
                      scope == self.scope else { return }
                conversationResults = page.conversations
                messageResults = []
                nextConversationCursor = page.nextCursor
            case .messages:
                let page = try await repository.searchMessages(query: query)
                guard generation == requestGeneration,
                      query == normalizedQuery,
                      scope == self.scope else { return }
                conversationResults = []
                messageResults = page.results
                nextConversationCursor = nil
            }
            state = .loaded
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            guard !(error is CancellationError),
                  generation == requestGeneration,
                  query == normalizedQuery,
                  scope == self.scope else { return }
            state = .failed(error.userFacingMessage)
        }
    }
}

private enum OfflineSearchError: LocalizedError {
    case messagesUnavailable

    var errorDescription: String? {
        "Message search needs a connection. Saved chat titles remain searchable offline."
    }
}
