import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation

@MainActor
@Observable
final class AgentDirectoryModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    private let repository: any AgentRepository
    private let creationRepository: (any BasicAgentCreationRepository)?
    private let isOffline: @MainActor () -> Bool
    private let creationEnabled: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private let debounce: @Sendable () async throws -> Void
    private var searchTask: Task<Void, Never>?
    private var revision: UInt64 = 0

    var query = ""
    private(set) var state: State = .idle
    private(set) var agents: [ChatAgentSummary] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var pageError: String?
    private(set) var isCreatingAgent = false
    private(set) var creationRequiresRefresh = false
    /// Name submitted by the outcome-unknown create; reloads reconcile the
    /// outcome with an authoritative name lookup before unlocking retry.
    private var attemptedCreationName: String?

    init(
        repository: any AgentRepository,
        creationRepository: (any BasicAgentCreationRepository)? = nil,
        isOffline: @escaping @MainActor () -> Bool,
        creationEnabled: @escaping @MainActor () -> Bool = { false },
        onUnauthorized: @escaping @MainActor () async -> Void,
        debounce: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(350))
        }
    ) {
        self.repository = repository
        self.creationRepository = creationRepository
        self.isOffline = isOffline
        self.creationEnabled = creationEnabled
        self.onUnauthorized = onUnauthorized
        self.debounce = debounce
    }

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canCreateAgent: Bool {
        creationEnabled()
            && creationRepository != nil
            && !isOffline()
            && state == .loaded
            && !isCreatingAgent
            && !creationRequiresRefresh
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        searchTask?.cancel()
        revision &+= 1
        await loadFirstPage(revision: revision)
    }

    func queryChanged() {
        searchTask?.cancel()
        revision &+= 1
        pageError = nil
        let expectedRevision = revision
        state = agents.isEmpty ? .loading : .loaded
        searchTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await self.debounce()
                guard !Task.isCancelled else { return }
                await self.loadFirstPage(revision: expectedRevision)
            } catch {
                // A newer query cancelled this debounce.
            }
        }
    }

    func loadMoreIfNeeded(after agent: ChatAgentSummary) async {
        guard agent.id == agents.last?.id,
              let nextCursor,
              !isLoadingMore,
              !isOffline(),
              state != .unauthorized else { return }

        let expectedRevision = revision
        let expectedQuery = normalizedQuery
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.agents(
                search: expectedQuery.isEmpty ? nil : expectedQuery,
                cursor: nextCursor,
                limit: 25
            )
            guard expectedRevision == revision, expectedQuery == normalizedQuery else { return }
            let existingIDs = Set(agents.map(\.id))
            agents.append(contentsOf: page.agents.filter { !existingIDs.contains($0.id) })
            self.nextCursor = page.nextCursor
            pageError = nil
        } catch {
            guard expectedRevision == revision else { return }
            await handle(error)
        }
    }

    func createBasicAgent(
        _ request: BasicAgentCreationRequest
    ) async throws -> BasicAgentCreationOutcome {
        guard canCreateAgent, let creationRepository else {
            throw LibreChatProtocolError.unsupported(
                creationRequiresRefresh
                    ? "Refresh agents before attempting another create."
                    : "Agent creation is unavailable for this account."
            )
        }
        isCreatingAgent = true
        defer { isCreatingAgent = false }
        do {
            let outcome = try await creationRepository.createBasicAgent(request)
            switch outcome {
            case .confirmed:
                await reload()
            case .outcomeUnknown:
                creationRequiresRefresh = true
                attemptedCreationName = request.name
            }
            return outcome
        } catch {
            if error.isUnauthorized {
                agents = []
                nextCursor = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    private func loadFirstPage(revision expectedRevision: UInt64) async {
        guard !isOffline() else {
            agents = []
            nextCursor = nil
            state = .offline
            return
        }
        if agents.isEmpty { state = .loading }
        pageError = nil
        let expectedQuery = normalizedQuery
        do {
            let page = try await repository.agents(
                search: expectedQuery.isEmpty ? nil : expectedQuery,
                cursor: nil,
                limit: 25
            )
            guard expectedRevision == revision, expectedQuery == normalizedQuery else { return }
            agents = page.agents
            nextCursor = page.nextCursor
            await reconcileCreationOutcome()
            state = .loaded
        } catch {
            guard expectedRevision == revision else { return }
            await handle(error)
        }
    }

    /// The post-create refresh can miss the created agent (search filter or
    /// later page), so retry stays locked until an exact-name lookup either
    /// observes it or authoritatively rules it out.
    private func reconcileCreationOutcome() async {
        guard creationRequiresRefresh else { return }
        guard let attempted = attemptedCreationName else {
            creationRequiresRefresh = false
            return
        }
        do {
            let lookup = try await repository.agents(
                search: attempted,
                cursor: nil,
                limit: 25
            )
            creationRequiresRefresh = false
            attemptedCreationName = nil
            if let created = lookup.agents.first(where: { $0.name == attempted }),
               !agents.contains(where: { $0.id == created.id }) {
                agents.insert(created, at: 0)
            }
        } catch {
            // Reconciliation itself failed; keep retry locked.
        }
    }

    private func handle(_ error: Error) async {
        if error.isUnauthorized {
            agents = []
            nextCursor = nil
            state = .unauthorized
            await onUnauthorized()
            return
        }
        guard !(error is CancellationError) else { return }
        if agents.isEmpty {
            state = .failed(error.userFacingMessage)
        } else {
            state = .loaded
            pageError = error.userFacingMessage
        }
    }
}

@MainActor
@Observable
final class AgentDetailModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case unauthorized
        case failed(String)
    }

    private let id: AgentID
    private let repository: any AgentRepository
    private let managementRepository: any AgentManagementRepository
    private let onUnauthorized: @MainActor () async -> Void
    private(set) var state: State = .idle
    private(set) var detail: ChatAgentDetail?
    private(set) var resourcePermissions: AgentResourcePermissions?

    init(
        id: AgentID,
        repository: any AgentRepository,
        managementRepository: any AgentManagementRepository,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.id = id
        self.repository = repository
        self.managementRepository = managementRepository
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        state = .loading
        resourcePermissions = nil
        do {
            detail = try await repository.agent(id: id)
            state = .loaded
        } catch {
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            } else if !(error is CancellationError) {
                state = .failed(error.userFacingMessage)
            }
        }
    }

    func managementDetail() async throws -> ManagedAgentMetadata {
        do {
            let metadata = try await managementRepository.agentManagementDetail(id: id)
            guard metadata.id == id else { throw AgentManagementError.invalidResponse }
            return metadata
        } catch {
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    func loadResourcePermissions() async {
        do {
            resourcePermissions = try await managementRepository.agentResourcePermissions(id: id)
        } catch {
            resourcePermissions = nil
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            }
        }
    }

    func updateMetadata(
        _ input: AgentMetadataUpdateInput
    ) async throws -> ManagedAgentMetadata {
        guard input.agentID == id else { throw AgentManagementError.invalidInput("This edit belongs to another agent.") }
        do {
            let metadata = try await managementRepository.updateAgentMetadata(input)
            guard metadata.id == id else { throw AgentManagementError.invalidResponse }
            apply(metadata)
            return metadata
        } catch {
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    func duplicate() async throws -> ChatAgentSummary {
        do {
            let copy = try await managementRepository.duplicateAgent(id: id)
            guard copy.id != id else { throw AgentManagementError.invalidResponse }
            return copy
        } catch {
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    func versions() async throws -> AgentVersionHistory {
        do {
            let history = try await managementRepository.agentVersions(id: id)
            guard history.agentID == id,
                  history.versions.allSatisfy({ $0.coordinate.agentID == id }) else {
                throw AgentManagementError.invalidResponse
            }
            return history
        } catch {
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    func revert(
        _ version: AgentVersionSummary
    ) async throws -> ManagedAgentMetadata {
        guard version.coordinate.agentID == id else {
            throw AgentManagementError.invalidInput("This version belongs to another agent.")
        }
        do {
            let metadata = try await managementRepository.revertAgentVersion(version)
            guard metadata.id == id else { throw AgentManagementError.outcomeUnknown }
            apply(metadata)
            return metadata
        } catch {
            if error.isUnauthorized {
                detail = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    func delete() async throws {
        do {
            try await managementRepository.deleteAgent(id: id)
            detail = nil
            resourcePermissions = nil
            state = .idle
        } catch {
            if error.isUnauthorized {
                detail = nil
                resourcePermissions = nil
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
        }
    }

    private func apply(_ metadata: ManagedAgentMetadata) {
        guard var detail else { return }
        detail.name = metadata.name
        detail.description = metadata.description
        detail.isPublic = metadata.isPublic
        detail.version = metadata.version
        self.detail = detail
        state = .loaded
    }
}

enum AgentStartTargetResolution: Equatable {
    case available(ChatTargetOption)
    case unavailable
    case ambiguous
}

struct AgentStartTargetResolver {
    static func resolve(
        agentID: AgentID,
        options: [ChatTargetOption]
    ) -> AgentStartTargetResolution {
        if let direct = options.first(where: {
            $0.id == "agent:\(agentID.rawValue)" && $0.target.agentID == agentID.rawValue
        }) {
            return .available(direct)
        }
        let candidates = options.filter { $0.target.agentID == agentID.rawValue }
        switch candidates.count {
        case 0: return .unavailable
        case 1: return .available(candidates[0])
        default: return .ambiguous
        }
    }
}
