import Foundation
import LibreChatDomain
import Observation

@MainActor
@Observable
final class PromptLibraryModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    private let repository: any PromptRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private var requestRevision: UInt = 0

    private(set) var groups: [PromptTemplateGroup] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?
    private(set) var state: State = .idle
    var query = ""

    init(
        repository: any PromptRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    var canLoadMore: Bool {
        nextCursor != nil && !isLoadingMore && state == .loaded && !isOffline()
    }

    func searchAfterDebounce() async {
        if state != .idle {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        await reload()
    }

    func reload() async {
        requestRevision &+= 1
        let revision = requestRevision
        guard !isOffline() else {
            groups = []
            nextCursor = nil
            state = .offline
            return
        }

        groups = []
        nextCursor = nil
        paginationError = nil
        state = .loading
        do {
            let page = try await repository.promptGroups(PromptTemplateQuery(
                search: query,
                limit: 25
            ))
            guard revision == requestRevision, !Task.isCancelled else { return }
            groups = page.groups
            nextCursor = page.nextCursor
            state = .loaded
        } catch {
            guard revision == requestRevision, !Task.isCancelled else { return }
            await handle(error)
        }
    }

    func loadMoreIfNeeded(after group: PromptTemplateGroup) async {
        guard groups.last?.id == group.id, canLoadMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        paginationError = nil
        let revision = requestRevision
        defer { if revision == requestRevision { isLoadingMore = false } }
        do {
            let page = try await repository.promptGroups(PromptTemplateQuery(
                search: query,
                cursor: cursor,
                limit: 25
            ))
            guard revision == requestRevision, !Task.isCancelled else { return }
            var seen = Set(groups.map(\.id))
            groups.append(contentsOf: page.groups.filter { seen.insert($0.id).inserted })
            nextCursor = page.nextCursor
        } catch {
            guard revision == requestRevision, !Task.isCancelled else { return }
            if error.isUnauthorized {
                groups = []
                nextCursor = nil
                state = .unauthorized
                await onUnauthorized()
            } else {
                paginationError = "More prompts could not be loaded. Your current results are unchanged."
            }
        }
    }

    func recordUsage(for groupID: PromptGroupID) async {
        do {
            let count = try await repository.recordPromptUsage(groupID: groupID)
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].usageCount = count
        } catch {
            if error.isUnauthorized {
                groups = []
                nextCursor = nil
                state = .unauthorized
                await onUnauthorized()
            }
            // Usage telemetry is advisory. A failed counter must never undo a
            // prompt already inserted into the user's local draft.
        }
    }

    private func handle(_ error: Error) async {
        if error.isUnauthorized {
            groups = []
            nextCursor = nil
            state = .unauthorized
            await onUnauthorized()
        } else if isOffline() {
            groups = []
            nextCursor = nil
            state = .offline
        } else {
            state = .failed(error.userFacingMessage)
        }
    }
}
