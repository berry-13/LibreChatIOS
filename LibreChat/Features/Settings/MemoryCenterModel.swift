import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation

@MainActor
@Observable
final class MemoryCenterModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    enum PartitionFilter: Hashable {
        case all
        case personal
        case agent(AgentID)
    }

    enum MutationKind: Hashable {
        case create
        case update(UserMemoryID)
        case delete(UserMemoryID)
        case preference
    }

    private let repository: any MemoryRepository
    private let permissions: MemoryPermissions
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private let onPreferenceChanged: @MainActor (Bool) async -> Void
    /// Advances on every confirmed mutation so a reload that captured
    /// pre-mutation state can never install over the newer snapshot.
    private var reloadRevision = 0

    private(set) var state: State = .idle
    private(set) var snapshot: MemorySnapshot?
    private(set) var activeMutation: MutationKind?
    private(set) var operationError: String?
    private(set) var memoriesEnabled: Bool
    var query = ""
    var partition: PartitionFilter = .all

    init(
        repository: any MemoryRepository,
        permissions: MemoryPermissions,
        memoriesEnabled: Bool,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onPreferenceChanged: @escaping @MainActor (Bool) async -> Void
    ) {
        self.repository = repository
        self.permissions = permissions
        self.memoriesEnabled = memoriesEnabled
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
        self.onPreferenceChanged = onPreferenceChanged
    }

    var canCreate: Bool {
        permissions.canCreate && !isOffline() && state == .loaded && activeMutation == nil
    }

    var canChangePreference: Bool {
        permissions.canChangePreference && !isOffline() && state == .loaded && activeMutation == nil
    }

    var characterLimit: Int { snapshot?.characterLimit ?? 10_000 }

    var partitionOptions: [(filter: PartitionFilter, label: String)] {
        var result: [(PartitionFilter, String)] = [(.all, "All"), (.personal, "Personal")]
        var seen = Set<AgentID>()
        for memory in snapshot?.memories ?? [] {
            guard let agentID = memory.agentID, seen.insert(agentID).inserted else { continue }
            result.append((.agent(agentID), memory.agentName ?? "Agent-specific"))
        }
        return result
    }

    var visibleMemories: [UserMemory] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (snapshot?.memories ?? []).filter { memory in
            let matchesPartition: Bool = switch partition {
            case .all: true
            case .personal: memory.agentID == nil
            case let .agent(id): memory.agentID == id
            }
            guard matchesPartition else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return memory.key.localizedCaseInsensitiveContains(normalizedQuery)
                || memory.value.localizedCaseInsensitiveContains(normalizedQuery)
                || (memory.agentName?.localizedCaseInsensitiveContains(normalizedQuery) == true)
        }
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard permissions.canRead else {
            snapshot = nil
            state = .failed("Your current role does not allow reading memories.")
            return
        }
        guard !isOffline() else {
            snapshot = nil
            state = .offline
            return
        }
        if snapshot == nil { state = .loading }
        // A reload that captured pre-mutation state must never install over a
        // confirmed mutation's newer snapshot.
        reloadRevision &+= 1
        let revision = reloadRevision
        do {
            let fresh = try await repository.memories()
            guard revision == reloadRevision else { return }
            snapshot = fresh
            normalizePartition()
            operationError = nil
            state = .loaded
        } catch {
            guard revision == reloadRevision else { return }
            await handle(error, clearPrivateState: true)
        }
    }

    func create(key: String, value: String) async -> Bool {
        guard canCreate else { return false }
        activeMutation = .create
        operationError = nil
        defer { activeMutation = nil }
        do {
            let memory = try await repository.createMemory(
                CreateMemoryInput(key: key, value: value)
            )
            install(memory)
            await refreshAfterConfirmedMutation()
            return true
        } catch {
            await handle(error, clearPrivateState: error.isUnauthorized)
            return false
        }
    }

    func update(_ memory: UserMemory, key: String, value: String) async -> Bool {
        guard permissions.canUpdate,
              !isOffline(),
              state == .loaded,
              activeMutation == nil else { return false }
        activeMutation = .update(memory.id)
        operationError = nil
        defer { activeMutation = nil }
        do {
            let updated = try await repository.updateMemory(UpdateMemoryInput(
                originalKey: memory.key,
                key: key,
                value: value,
                agentID: memory.agentID
            ))
            snapshot?.memories.removeAll { $0.id == memory.id }
            install(updated)
            await refreshAfterConfirmedMutation()
            return true
        } catch {
            await handle(error, clearPrivateState: error.isUnauthorized)
            return false
        }
    }

    func delete(_ memory: UserMemory) async -> Bool {
        guard permissions.canDelete,
              !isOffline(),
              state == .loaded,
              activeMutation == nil else { return false }
        activeMutation = .delete(memory.id)
        operationError = nil
        defer { activeMutation = nil }
        do {
            try await repository.deleteMemory(
                DeleteMemoryInput(key: memory.key, agentID: memory.agentID)
            )
            snapshot?.memories.removeAll { $0.id == memory.id }
            normalizePartition()
            await refreshAfterConfirmedMutation()
            return true
        } catch {
            await handle(error, clearPrivateState: error.isUnauthorized)
            return false
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard canChangePreference else { return }
        activeMutation = .preference
        operationError = nil
        defer { activeMutation = nil }
        do {
            let authoritative = try await repository.setMemoriesEnabled(enabled)
            memoriesEnabled = authoritative
            await onPreferenceChanged(authoritative)
        } catch {
            await handle(error, clearPrivateState: error.isUnauthorized)
        }
    }

    func canEdit(_ memory: UserMemory) -> Bool {
        permissions.canUpdate && !isOffline() && state == .loaded
            && (activeMutation == nil || activeMutation == .update(memory.id))
    }

    private func install(_ memory: UserMemory) {
        guard var snapshot else { return }
        snapshot.memories.removeAll { $0.id == memory.id }
        snapshot.memories.insert(memory, at: 0)
        self.snapshot = snapshot
    }

    private func refreshAfterConfirmedMutation() async {
        // Supersedes any reload that was still in flight with pre-mutation
        // data.
        reloadRevision &+= 1
        do {
            snapshot = try await repository.memories()
            normalizePartition()
            state = .loaded
        } catch {
            if error.isUnauthorized {
                await handle(error, clearPrivateState: true)
            } else {
                state = .loaded
                operationError = "The change was saved, but usage details could not be refreshed."
            }
        }
    }

    private func normalizePartition() {
        guard case let .agent(selected) = partition else { return }
        if snapshot?.memories.contains(where: { $0.agentID == selected }) != true {
            partition = .all
        }
    }

    private func handle(_ error: Error, clearPrivateState: Bool) async {
        guard !(error is CancellationError) else { return }
        if clearPrivateState { snapshot = nil }
        if error.isUnauthorized {
            state = .unauthorized
            operationError = "Your session expired."
            await onUnauthorized()
            return
        }
        if case LibreChatProtocolError.httpStatus(403, _, _) = error {
            operationError = "Your current role does not allow that memory action."
        } else {
            operationError = error.userFacingMessage
        }
        if snapshot == nil { state = .failed(operationError ?? "Memories are unavailable.") }
    }
}

