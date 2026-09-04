import Foundation
import LibreChatDomain
import Observation

/// UI-facing state for the project browser.
///
/// Project data remains owned by the repository. This model only owns the
/// current page, transient query/sort state, and the operation state needed by
/// SwiftUI. Every request is revision fenced so an older search or pagination
/// response cannot overwrite a newer result.
@MainActor
@Observable
final class ProjectListModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    private let repository: any ProjectRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private let debounce: @Sendable () async throws -> Void

    private var searchTask: Task<Void, Never>?
    private var requestRevision: UInt64 = 0

    private(set) var state: State = .idle
    private(set) var projects: [ChatProject] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var isRefreshing = false
    private(set) var isCreating = false
    private(set) var isAssigning = false
    private(set) var updatingIDs: Set<ProjectID> = []
    private(set) var deletingIDs: Set<ProjectID> = []
    private(set) var operationError: String?

    var searchQuery = ""
    var sortBy: ChatProjectSortBy = .lastConversationAt
    var sortDirection: ChatProjectSortDirection = .descending

    init(
        repository: any ProjectRepository,
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

    var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canMutate: Bool { !isOffline() && state != .unauthorized }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    /// Refreshes the first page using the current query and ordering.
    func reload() async {
        searchTask?.cancel()
        requestRevision &+= 1
        let revision = requestRevision
        await loadFirstPage(revision: revision)
    }

    /// Call from a SwiftUI `.onChange(of: searchQuery)` handler.
    func searchChanged() {
        searchTask?.cancel()
        requestRevision &+= 1
        operationError = nil

        guard !normalizedSearchQuery.isEmpty else {
            Task { [weak self] in await self?.reload() }
            return
        }

        let revision = requestRevision
        state = projects.isEmpty ? .loading : .loaded
        searchTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.debounce()
                guard !Task.isCancelled else { return }
                await self.loadFirstPage(revision: revision)
            } catch is CancellationError {
                // A newer query superseded this debounce.
            } catch {
                // Debounce implementations are allowed to throw; the query
                // itself is still valid and can be retried by the user.
            }
        }
    }

    /// Reorders immediately; unlike search this does not need a debounce.
    func sortChanged() {
        searchTask?.cancel()
        requestRevision &+= 1
        let revision = requestRevision
        Task { [weak self] in await self?.loadFirstPage(revision: revision) }
    }

    func retry() {
        Task { [weak self] in await self?.reload() }
    }

    func loadMoreIfNeeded(after project: ChatProject) async {
        guard project.id == projects.last?.id,
              let nextCursor,
              !isLoadingMore,
              !isOffline(),
              state != .unauthorized else { return }

        let revision = requestRevision
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await repository.projects(options: options(cursor: nextCursor))
            guard revision == requestRevision else { return }
            let existingIDs = Set(projects.map(\.id))
            projects.append(contentsOf: page.projects.filter { !existingIDs.contains($0.id) })
            projects = sorted(projects)
            self.nextCursor = page.nextCursor
            operationError = nil
        } catch {
            guard revision == requestRevision else { return }
            await handle(error)
        }
    }

    func createProject(name: String, description: String? = nil) async -> ChatProject? {
        guard canMutate, !isCreating else {
            operationError = isOffline() ? "Creating projects is unavailable offline." : operationError
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            operationError = "A project name is required."
            return nil
        }

        isCreating = true
        operationError = nil
        defer { isCreating = false }
        do {
            let project = try await repository.createProject(
                CreateChatProjectInput(name: trimmedName, description: normalizedDescription(description))
            )
            if matchesSearch(project) {
                projects.removeAll { $0.id == project.id }
                projects.append(project)
                projects = sorted(projects)
            }
            state = .loaded
            return project
        } catch {
            await handle(error)
            return nil
        }
    }

    func updateProject(
        id: ProjectID,
        name: String? = nil,
        description: String? = nil
    ) async -> ChatProject? {
        guard canMutate else {
            operationError = isOffline() ? "Updating projects is unavailable offline." : operationError
            return nil
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, trimmedName.isEmpty {
            operationError = "A project name is required."
            return nil
        }
        guard trimmedName != nil || description != nil else {
            operationError = "There are no project changes to save."
            return nil
        }

        updatingIDs.insert(id)
        operationError = nil
        defer { updatingIDs.remove(id) }
        do {
            let project = try await repository.updateProject(
                id: id,
                input: UpdateChatProjectInput(
                    name: trimmedName,
                    // An empty string is meaningful on LibreChat's PATCH
                    // contract: it clears an existing description. Nil alone
                    // means "leave this field unchanged."
                    description: description.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                )
            )
            projects.removeAll { $0.id == id }
            if matchesSearch(project) {
                projects.append(project)
                projects = sorted(projects)
            }
            return project
        } catch {
            await handle(error)
            return nil
        }
    }

    func deleteProject(id: ProjectID) async -> Bool {
        guard canMutate else {
            operationError = isOffline() ? "Deleting projects is unavailable offline." : operationError
            return false
        }
        guard !deletingIDs.contains(id) else { return false }

        deletingIDs.insert(id)
        operationError = nil
        defer { deletingIDs.remove(id) }
        do {
            _ = try await repository.deleteProject(id: id)
            projects.removeAll { $0.id == id }
            return true
        } catch {
            await handle(error)
            return false
        }
    }

    func assignConversation(
        _ conversation: Conversation,
        to projectID: ProjectID?
    ) async -> ConversationProjectAssignment? {
        guard canMutate, !isAssigning else {
            operationError = isOffline() ? "Moving conversations is unavailable offline." : operationError
            return nil
        }
        isAssigning = true
        operationError = nil
        defer { isAssigning = false }
        do {
            return try await repository.assignConversation(id: conversation.id, to: projectID)
        } catch {
            await handle(error)
            return nil
        }
    }

    // Short aliases keep call sites expressive without coupling views to the
    // repository's method names.
    func create(name: String, description: String? = nil) async -> ChatProject? {
        await createProject(name: name, description: description)
    }

    func update(id: ProjectID, name: String? = nil, description: String? = nil) async -> ChatProject? {
        await updateProject(id: id, name: name, description: description)
    }

    func delete(id: ProjectID) async -> Bool {
        await deleteProject(id: id)
    }

    private func loadFirstPage(revision: UInt64) async {
        guard revision == requestRevision else { return }
        if isOffline() {
            state = .offline
            return
        }

        isRefreshing = !projects.isEmpty
        if projects.isEmpty { state = .loading }
        defer { isRefreshing = false }
        do {
            let page = try await repository.projects(options: options(cursor: nil))
            guard revision == requestRevision else { return }
            projects = sorted(page.projects)
            nextCursor = page.nextCursor
            operationError = nil
            state = .loaded
        } catch {
            guard revision == requestRevision else { return }
            await handle(error)
        }
    }

    private func options(cursor: String?) -> ChatProjectListOptions {
        ChatProjectListOptions(
            cursor: cursor,
            limit: 25,
            sortBy: sortBy,
            sortDirection: sortDirection,
            search: normalizedSearchQuery.isEmpty ? nil : normalizedSearchQuery
        )
    }

    private func matchesSearch(_ project: ChatProject) -> Bool {
        guard !normalizedSearchQuery.isEmpty else { return true }
        return project.name.localizedCaseInsensitiveContains(normalizedSearchQuery)
    }

    private func sorted(_ projects: [ChatProject]) -> [ChatProject] {
        projects.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortBy {
            case .name:
                comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .createdAt:
                comparison = compare(lhs.createdAt, rhs.createdAt)
            case .lastConversationAt:
                comparison = compare(lhs.lastConversationAt, rhs.lastConversationAt)
            }
            return sortDirection == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        }
    }

    private func normalizedDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handle(_ error: Error) async {
        guard !(error is CancellationError) else { return }
        if error.isUnauthorized {
            state = .unauthorized
            await onUnauthorized()
        } else {
            state = .failed(error.userFacingMessage)
        }
        operationError = error.userFacingMessage
    }
}
