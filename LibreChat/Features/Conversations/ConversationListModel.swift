import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation

protocol ConversationListFeatureRepository: ConversationRepository, TargetCatalogRepository, ConversationManagementRepository, ConversationDuplicationRepository {
    func archivedConversations(cursor: String?, limit: Int) async throws -> ConversationPage
    func newChatTargetCatalog() async throws -> TargetCatalogSnapshot
    func rememberRecentChatTargetOptionID(
        _ optionID: String,
        profileID: ServerProfileID,
        accountID: AccountID
    ) async
    /// Reads one saved composer draft; backs the sidebar's unsent-draft rows.
    func draft(conversationID: ConversationID) async -> String
    func saveDraft(_ text: String, conversationID: ConversationID) async
}

extension ConversationListFeatureRepository {
    /// Favorites are an optional surface; doubles without live pins read an
    /// empty directory and never mutate.
    func chatFavorites() async throws -> [ChatFavorite] { [] }
    func replaceChatFavorites(_ favorites: [ChatFavorite]) async throws -> [ChatFavorite] { favorites }
    func draft(conversationID: ConversationID) async -> String { "" }
    func saveDraft(_ text: String, conversationID: ConversationID) async {}
}
extension LibreChatRepository: ConversationListFeatureRepository {}

@MainActor
@Observable
final class ConversationListModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let repository: any ConversationListFeatureRepository
    private let presetRepository: (any PresetRepository)?
    private let presetCreationRepository: (any PresetCreationRepository)?
    private let isOffline: @MainActor () -> Bool
    private let presetsEnabled: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    /// True when an unsent canvas carries real local content (saved draft
    /// text or in-flight attachments); drives the sidebar's draft rows.
    private let draftCanvasProbe: (@MainActor (ConversationID) async -> Bool)?
    private(set) var state: State = .idle
    private(set) var conversations: [LibreChatDomain.Conversation] = []
    /// Unsent canvases by identity. They are deliberately absent from
    /// `conversations` (no sidebar row until the server assigns one), but
    /// navigation must still resolve them to present the chat page.
    private(set) var unsentCanvases: [ConversationID: LibreChatDomain.Conversation] = [:]
    /// The subset of unsent canvases that hold draft text or attachments.
    /// These render as clearly-local "New Chat" rows: selecting one restores
    /// its composer state, and the row merges into the real conversation the
    /// moment the server assigns an identity.
    private(set) var draftCanvases: [LibreChatDomain.Conversation] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?
    private(set) var freshness: Date?
    private(set) var isShowingCache = false
    /// Set once a live server refresh lands during loadIfNeeded; the racing
    /// cache read must not overwrite it afterwards.
    private var liveRefreshArrived = false
    /// Mutations (delete, rename, pin, archive, duplicate) advance this so an
    /// in-flight listing request that captured older state can never install
    /// a stale page over the confirmed local edit.
    private var listingRevision = 0
    /// Whole-list favorite replacements run strictly one at a time.
    private var favoritesMutationChain: Task<[ChatFavorite], Error>?
    /// The last list the server confirmed; optimistic edits roll back to it.
    private var confirmedFavorites: [ChatFavorite] = []
    /// Invoked when a draft canvas is discarded so its staged attachments
    /// (and any confirmed remote temp files) are torn down with it.
    var onDiscardUploads: (@MainActor (ConversationID) async -> Void)?
    private(set) var targetCatalog: TargetCatalogSnapshot?
    private(set) var isLoadingTargets = false
    private(set) var targetError: String?
    private(set) var creationError: String?
    private(set) var isCreating = false
    private(set) var activeOperationID: ConversationID?
    private(set) var duplicationUncertainIDs: Set<ConversationID> = []
    private(set) var favorites: [ChatFavorite] = []
    private(set) var presetLibrary: PresetLibrarySnapshot?
    private(set) var isLoadingPresets = false
    private(set) var presetError: String?
    private(set) var isSavingPreset = false
    private(set) var presetCreationRequiresRefresh = false

    var availableTargets: [ChatTargetOption] { targetCatalog?.options ?? [] }

    /// Pinned targets resolved against the live catalog: favorites whose
    /// model or agent is no longer authorized stay hidden until the catalog
    /// offers them again.
    var favoriteOptions: [ChatTargetOption] {
        let options = availableTargets
        return favorites.compactMap { favorite in
            switch favorite {
            case let .agent(id):
                return options.first { $0.target.agentID == id }
            case let .spec(name):
                return options.first { $0.target.spec == name }
            case let .model(endpoint, model):
                return options.first {
                    $0.target.endpoint == endpoint && $0.target.model == model
                }
            }
        }
    }

    func isFavorite(_ option: ChatTargetOption) -> Bool {
        favoriteIdentity(of: option).map { favorites.contains($0) } == true
    }
    var availablePresets: [ChatPreset] { presetLibrary?.presets ?? [] }
    var canUsePresets: Bool {
        presetsEnabled() && presetRepository != nil
    }
    var canCreatePresets: Bool {
        canUsePresets
            && presetCreationRepository != nil
            && presetLibrary != nil
            && presetError == nil
            && !presetCreationRequiresRefresh
    }
    var presetLibraryNotices: [String] {
        guard let presetLibrary else { return [] }
        var notices: [String] = []
        for warning in presetLibrary.warnings {
            let notice: String
            switch warning {
            case .invalidPresetCount:
                notice = "Some invalid server presets were hidden."
            case .duplicatePresetID:
                notice = "Duplicate preset identifiers were hidden."
            }
            if !notices.contains(notice) { notices.append(notice) }
        }
        return notices
    }
    var listedConversations: [LibreChatDomain.Conversation] {
        conversations.filter { !$0.isTemporaryConversation }
    }

    var effectiveDefaultTargetID: ChatTargetOption.ID? {
        targetCatalog?.effectiveDefaultOptionID
    }

    var targetCompatibilityNotices: [String] {
        guard let targetCatalog else { return [] }
        var notices: [String] = []
        func appendOnce(_ notice: String) {
            if !notices.contains(notice) { notices.append(notice) }
        }
        for warning in targetCatalog.warnings {
            switch warning {
            case .agentPermissionDenied:
                appendOnce("Agent choices are hidden because this account does not have permission to use them.")
            case .agentDiscoveryUnavailable:
                appendOnce("Agent choices could not be verified and are hidden for now.")
            case .unsupportedTargetKind:
                appendOnce("Some server target types are not supported by this native client yet.")
            case .userKeyRequired, .userKeyExpired, .userKeyStatusUnavailable:
                appendOnce("Some providers are hidden until their account credentials can be verified.")
            case .invalidModelSpec:
                appendOnce("Some invalid server model entries were hidden.")
            }
        }
        return notices
    }

    init(
        repository: any ConversationListFeatureRepository,
        presetRepository: (any PresetRepository)? = nil,
        presetCreationRepository: (any PresetCreationRepository)? = nil,
        isOffline: @escaping @MainActor () -> Bool,
        presetsEnabled: @escaping @MainActor () -> Bool = { false },
        onUnauthorized: @escaping @MainActor () async -> Void,
        draftCanvasProbe: (@MainActor (ConversationID) async -> Bool)? = nil,
        onDiscardUploads: (@MainActor (ConversationID) async -> Void)? = nil
    ) {
        self.repository = repository
        self.presetRepository = presetRepository
        self.presetCreationRepository = presetCreationRepository
        self.isOffline = isOffline
        self.presetsEnabled = presetsEnabled
        self.onUnauthorized = onUnauthorized
        self.draftCanvasProbe = draftCanvasProbe
        self.onDiscardUploads = onDiscardUploads
    }

    /// Recomputes which unsent canvases carry local content and belong in
    /// the sidebar's draft section. Cheap: one draft-store read plus an
    /// in-memory upload probe per canvas.
    func refreshDraftCanvases() async {
        guard let draftCanvasProbe else { return }
        var rows: [LibreChatDomain.Conversation] = []
        for canvas in unsentCanvases.values where !canvas.isTemporaryConversation {
            if await draftCanvasProbe(canvas.id) {
                rows.append(canvas)
            }
        }
        rows.sort {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        if draftCanvases != rows {
            draftCanvases = rows
        }
    }

    /// Discards an unsent draft canvas and clears its saved composer state.
    /// No server request: the conversation does not exist yet.
    func discardDraftCanvas(_ id: ConversationID) async {
        unregisterUnsentCanvas(id)
        await onDiscardUploads?(id)
        await repository.saveDraft("", conversationID: id)
        await refreshDraftCanvases()
    }

    enum PresetApplicationResolution: Equatable {
        case ready(ChatTargetOption)
        case unsupportedSettings([String])
        case targetUnavailable
        case ambiguousTarget
        case staleOrForeign

        var blockingMessage: String? {
            switch self {
            case .ready:
                nil
            case let .unsupportedSettings(settings):
                "This preset uses settings the native client cannot reproduce yet: \(settings.joined(separator: ", "))."
            case .targetUnavailable:
                "This preset’s model or agent is not currently authorized for this account."
            case .ambiguousTarget:
                "This preset does not identify one exact authorized model. Choose the model manually instead."
            case .staleOrForeign:
                "This preset is no longer part of the current account’s live preset library. Refresh and choose again."
            }
        }
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        restoreUnsentCanvasManifests()
        // Cache and network read concurrently: the cached page renders as
        // soon as it lands while the server refresh is already in flight.
        liveRefreshArrived = false
        async let networkRefresh: Void = reload()
        await loadCache()
        await networkRefresh
    }

    func reload() async {
        guard state != .loading || conversations.isEmpty else { return }
        if conversations.isEmpty { state = .loading }
        if isOffline() {
            state = conversations.isEmpty ? .failed("No cached conversations are available offline.") : .loaded
            return
        }
        listingRevision &+= 1
        let revision = listingRevision

        do {
            let page = try await repository.conversations(cursor: nil, limit: 25)
            guard revision == listingRevision else { return }
            let refreshedIDs = Set(page.conversations.map(\.id))
            liveRefreshArrived = true
            if page.nextCursor == nil {
                // The final page makes the server listing authoritative:
                // conversations deleted or archived by another client must
                // leave the list instead of being preserved by the merge.
                let serverIDs = refreshedIDs
                let localDrafts = conversations.filter { $0.id.isLocalDraft && !serverIDs.contains($0.id) }
                conversations = page.conversations + localDrafts
            } else {
                conversations = page.conversations + conversations.filter { !refreshedIDs.contains($0.id) }
            }
            nextCursor = page.nextCursor
            freshness = page.fetchedAt
            isShowingCache = false
            duplicationUncertainIDs.removeAll()
            state = .loaded
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            guard !(error is CancellationError) else { return }
            guard revision == listingRevision else { return }
            state = conversations.isEmpty ? .failed(error.userFacingMessage) : .loaded
            paginationError = conversations.isEmpty ? nil : "Couldn’t refresh. Showing saved conversations."
            isShowingCache = !conversations.isEmpty
        }
    }

    func loadMoreIfNeeded(after conversation: LibreChatDomain.Conversation) async {
        guard conversation.id == conversations.last?.id,
              let nextCursor,
              !isLoadingMore,
              !isOffline() else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // A pagination result only belongs to the listing that produced its
        // cursor; a refresh that lands first invalidates it entirely.
        let revision = listingRevision

        do {
            let page = try await repository.conversations(cursor: nextCursor, limit: 25)
            guard revision == listingRevision else { return }
            let existingIDs = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.conversations.filter { !existingIDs.contains($0.id) })
            self.nextCursor = page.nextCursor
            freshness = page.fetchedAt
            paginationError = nil
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            guard !(error is CancellationError) else { return }
            guard revision == listingRevision else { return }
            paginationError = error.userFacingMessage
        }
    }

    func delete(_ conversation: LibreChatDomain.Conversation) async {
        unregisterUnsentCanvas(conversation.id)
        guard activeOperationID == nil else { return }
        guard !isOffline() || conversation.id.isLocalDraft else {
            paginationError = "Deleting conversations is unavailable offline."
            return
        }
        activeOperationID = conversation.id
        defer { activeOperationID = nil }
        listingRevision &+= 1
        do {
            try await repository.delete(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            paginationError = error.userFacingMessage
        }
    }

    func rename(_ conversation: LibreChatDomain.Conversation, title: String) async {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, activeOperationID == nil, !isOffline() else { return }
        activeOperationID = conversation.id
        defer { activeOperationID = nil }
        listingRevision &+= 1
        do {
            includeConversation(try await repository.rename(id: conversation.id, title: normalizedTitle))
            paginationError = nil
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            paginationError = error.userFacingMessage
        }
    }

    func setPinned(_ conversation: LibreChatDomain.Conversation, pinned: Bool) async {
        guard activeOperationID == nil, !isOffline() else { return }
        activeOperationID = conversation.id
        defer { activeOperationID = nil }
        listingRevision &+= 1
        do {
            includeConversation(try await repository.pin(id: conversation.id, pinned: pinned))
            paginationError = nil
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            paginationError = error.userFacingMessage
        }
    }

    func archive(_ conversation: LibreChatDomain.Conversation) async {
        guard activeOperationID == nil, !isOffline() else { return }
        activeOperationID = conversation.id
        defer { activeOperationID = nil }
        listingRevision &+= 1
        do {
            _ = try await repository.archive(id: conversation.id, isArchived: true)
            conversations.removeAll { $0.id == conversation.id }
            paginationError = nil
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            paginationError = error.userFacingMessage
        }
    }

    func duplicate(
        _ conversation: LibreChatDomain.Conversation,
        profileID: ServerProfileID,
        accountID: AccountID
    ) async -> LibreChatDomain.Conversation? {
        guard activeOperationID == nil,
              !isOffline(),
              !conversation.id.isLocalDraft,
              !duplicationUncertainIDs.contains(conversation.id) else { return nil }
        activeOperationID = conversation.id
        defer { activeOperationID = nil }
        listingRevision &+= 1
        do {
            let result = try await repository.duplicate(ConversationDuplicationRequest(
                profileID: profileID,
                accountID: accountID,
                conversationID: conversation.id
            ))
            includeConversation(result.conversation)
            paginationError = nil
            return result.conversation
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            if error as? ConversationDuplicationError == .ambiguous {
                duplicationUncertainIDs.insert(conversation.id)
            }
            paginationError = error.userFacingMessage
            return nil
        }
    }

    func isDuplicationLocked(_ conversation: LibreChatDomain.Conversation) -> Bool {
        duplicationUncertainIDs.contains(conversation.id)
    }

    func loadTargets(forceRefresh: Bool = false) async {
        guard !isLoadingTargets else { return }
        guard !isOffline() else {
            targetCatalog = nil
            creationError = nil
            targetError = "Chat targets are unavailable offline."
            return
        }
        if !forceRefresh, targetCatalog != nil { return }
        isLoadingTargets = true
        targetError = nil
        creationError = nil
        // Keep the prior catalog mounted while refreshing: clearing it here
        // made every pill label, avatar, and checkmark collapse to a generic
        // fallback for the length of the round-trip (the "Selected agent"
        // flicker). The stale catalog is presentation state only — creation
        // re-validates the chosen option against this catalog, and a FAILED
        // refresh revokes it below so stale evidence can never enable Create.
        defer { isLoadingTargets = false }
        do {
            targetCatalog = try await repository.newChatTargetCatalog()
            await loadFavorites()
        }
        catch {
            targetCatalog = nil
            if error.isUnauthorized { await onUnauthorized() }
            targetError = error.userFacingMessage
        }
    }

    func loadPresets(forceRefresh: Bool = false) async {
        guard !isLoadingPresets else { return }
        guard canUsePresets else {
            presetLibrary = nil
            presetError = nil
            return
        }
        guard !isOffline() else {
            presetLibrary = nil
            presetError = "Presets are unavailable offline."
            return
        }
        if !forceRefresh, presetLibrary != nil { return }
        guard let presetRepository else {
            presetLibrary = nil
            presetError = "Presets are unavailable in this build."
            return
        }
        isLoadingPresets = true
        presetError = nil
        presetLibrary = nil
        defer { isLoadingPresets = false }
        do {
            presetLibrary = try await presetRepository.presets()
            presetCreationRequiresRefresh = false
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            guard !(error is CancellationError) else { return }
            presetError = error.userFacingMessage
        }
    }

    /// Creates only the small, native-safe preset shape. The selected target
    /// is captured here, then the repository independently re-fetches the
    /// account's live target catalog and compares the exact routing fingerprint
    /// before sending anything to LibreChat.
    func createPreset(
        title: String,
        promptPrefix: String?,
        reviewedTarget: ChatTargetOption
    ) async throws -> PresetCreationOutcome {
        guard !isSavingPreset else {
            throw LibreChatProtocolError.unsupported("A preset is already being saved.")
        }
        guard canCreatePresets else {
            throw LibreChatProtocolError.unsupported(
                canUsePresets
                    ? "Refresh saved presets before creating a new one."
                    : "Presets are disabled by this LibreChat server."
            )
        }
        guard !presetCreationRequiresRefresh else {
            throw LibreChatProtocolError.unsupported(
                "Refresh saved presets before attempting another create."
            )
        }
        guard !isOffline() else {
            throw LibreChatProtocolError.unsupported("Presets cannot be saved offline.")
        }
        guard let presetCreationRepository else {
            throw LibreChatProtocolError.unsupported("Preset creation is unavailable in this build.")
        }
        guard let catalog = targetCatalog,
              let currentTarget = catalog.options.first(where: { $0.id == reviewedTarget.id }),
              currentTarget == reviewedTarget else {
            throw PresetCreationError.reviewedTargetChanged
        }

        let request = PresetCreationRequest(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            presetID: PresetID(rawValue: UUID().uuidString),
            title: title,
            reviewedTarget: try PresetTargetReview(option: currentTarget),
            promptPrefix: promptPrefix
        )

        isSavingPreset = true
        defer { isSavingPreset = false }
        do {
            let outcome = try await presetCreationRepository.createPreset(request)
            switch outcome {
            case let .confirmed(preset):
                presetCreationRequiresRefresh = false
                // Confirmation proves the owner-scoped preset row, not that
                // its model or agent remains authorized after the mutation.
                // Clear and re-fetch routing evidence before the sheet can
                // select this preset for the pending New Chat.
                await loadTargets(forceRefresh: true)
                installCreatedPreset(
                    preset,
                    profileID: catalog.profileID,
                    accountID: catalog.accountID
                )
            case .outcomeUnknown:
                // The repository already performed the one safe reconciliation
                // read. Force the next user refresh to obtain a new live view;
                // never leave this possibly-created ID looking safe to resubmit.
                presetLibrary = nil
                presetCreationRequiresRefresh = true
            }
            return outcome
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            throw error
        }
    }

    func presetResolution(_ preset: ChatPreset) -> PresetApplicationResolution {
        guard let presetLibrary,
              let targetCatalog,
              presetLibrary.profileID == targetCatalog.profileID,
              presetLibrary.accountID == targetCatalog.accountID,
              let currentPreset = presetLibrary.presets.first(where: { $0.id == preset.id }),
              currentPreset == preset else {
            return .staleOrForeign
        }
        guard preset.unsupportedSettings.isEmpty else {
            return .unsupportedSettings(preset.unsupportedSettings)
        }
        guard let presetTarget = preset.target else { return .targetUnavailable }

        let matches = targetCatalog.options.filter { option in
            Self.matchesPresetTarget(presetTarget, authorizedTarget: option.target)
        }
        if matches.count == 1, let match = matches.first { return .ready(match) }
        return matches.isEmpty ? .targetUnavailable : .ambiguousTarget
    }

    func createConversation(
        title: String,
        preset: ChatPreset,
        isTemporary: Bool = false
    ) async -> LibreChatDomain.Conversation? {
        guard !isCreating else { return nil }
        guard !isOffline() else {
            creationError = "New chats are unavailable offline."
            return nil
        }
        creationError = nil
        guard case let .ready(option) = presetResolution(preset),
              let presetTarget = preset.target else {
            creationError = presetResolution(preset).blockingMessage
                ?? "This preset cannot be applied safely."
            return nil
        }

        var executionTarget = option.target
        if let promptPrefix = presetTarget.promptPrefix {
            executionTarget.promptPrefix = promptPrefix
        }
        return await createUnsentCanvas(
            title: title,
            target: executionTarget,
            rememberOptionID: option.id,
            isTemporary: isTemporary
        )
    }

    func createConversation(
        title: String,
        target: ChatTargetOption,
        projectID: ProjectID? = nil,
        isTemporary: Bool = false
    ) async -> LibreChatDomain.Conversation? {
        guard !isCreating else { return nil }
        guard !isOffline() else {
            creationError = "New chats are unavailable offline."
            return nil
        }
        creationError = nil
        guard let currentCatalog = targetCatalog,
              let currentTarget = currentCatalog.options.first(where: { $0.id == target.id }),
              currentTarget == target else {
            let message = "That model or agent is no longer available. Refresh and choose again."
            targetError = message
            creationError = message
            return nil
        }
        return await createUnsentCanvas(
            title: title,
            target: currentTarget.target,
            rememberOptionID: currentTarget.id,
            projectID: projectID,
            isTemporary: isTemporary
        )
    }

    /// LibreChat's contract: a new chat is not a conversation until the server
    /// assigns one. The unsent canvas returned here is ephemeral UI state —
    /// it never inserts a sidebar row. The server's start receipt supplies the
    /// real conversation identity, and `replaceConversation` inserts that row
    /// at the moment of assignment.
    private func createUnsentCanvas(
        title: String,
        target: ConversationTarget,
        rememberOptionID: ChatTargetOption.ID,
        projectID: ProjectID? = nil,
        isTemporary: Bool = false
    ) async -> LibreChatDomain.Conversation? {
        isCreating = true
        defer { isCreating = false }
        do {
            var canvas = try await repository.createConversation(
                title: title,
                target: target,
                isTemporary: isTemporary
            )
            canvas.projectID = projectID
            registerUnsentCanvas(canvas)
            if canvas.id.isLocalDraft, let catalog = targetCatalog {
                await repository.rememberRecentChatTargetOptionID(
                    rememberOptionID,
                    profileID: catalog.profileID,
                    accountID: catalog.accountID
                )
            }
            return canvas
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            creationError = error.userFacingMessage
            return nil
        }
    }

    func replaceConversation(
        id: ConversationID,
        with conversation: LibreChatDomain.Conversation
    ) {
        unregisterUnsentCanvas(id)
        conversations.removeAll { $0.id == conversation.id && $0.id != id }
        if let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        Task { await refreshDraftCanvases() }
    }

    func includeConversation(_ conversation: LibreChatDomain.Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }

    private func loadFavorites() async {
        guard !isOffline() else { return }
        do {
            let loaded = try await repository.chatFavorites()
            favorites = loaded
            confirmedFavorites = loaded
        } catch is CancellationError {
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            favorites = []
            confirmedFavorites = []
        }
    }

    /// Optimistically pins/unpins a target, then replaces the whole server
    /// list once; failures roll the optimistic change back.
    func toggleFavorite(_ option: ChatTargetOption) async {
        guard let identity = favoriteIdentity(of: option) else { return }
        // Queued mutations are always based on the last confirmed list, so a
        // chain failure rolls every optimistic edit back coherently.
        let previous = confirmedFavorites.isEmpty ? favorites : confirmedFavorites
        var updated = previous
        if let index = updated.firstIndex(of: identity) {
            updated.remove(at: index)
        } else {
            guard updated.count < LibreChatFavoritesAPI.maximumCount else {
                reportOperationError(
                    "LibreChat allows at most \(LibreChatFavoritesAPI.maximumCount) pinned models and agents."
                )
                return
            }
            updated.append(identity)
        }
        favorites = updated
        // Whole-list replacements are serialized: two overlapping POSTs can
        // apply out of order on the server and resurrect a removed chip.
        let previousChain = favoritesMutationChain
        let repository = self.repository
        let replacement = Task<[ChatFavorite], Error> {
            _ = try? await previousChain?.value
            return try await repository.replaceChatFavorites(updated)
        }
        favoritesMutationChain = replacement
        do {
            let confirmed = try await replacement.value
            confirmedFavorites = confirmed
            favorites = confirmed
        } catch is CancellationError {
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            favorites = previous
            confirmedFavorites = previous
            reportOperationError(error.userFacingMessage)
        }
    }

    private func favoriteIdentity(of option: ChatTargetOption) -> ChatFavorite? {
        if let agentID = option.target.agentID, !agentID.isEmpty {
            return .agent(id: agentID)
        }
        if let spec = option.target.spec, !spec.isEmpty {
            return .spec(name: spec)
        }
        let endpoint = option.target.endpoint
        guard let model = option.target.model,
              !endpoint.isEmpty, !model.isEmpty else { return nil }
        return .model(endpoint: endpoint, model: model)
    }

    /// Resolves a conversation by id across persisted rows and live unsent
    /// canvases, so navigation can present a brand-new chat immediately.
    func conversation(withID id: ConversationID) -> LibreChatDomain.Conversation? {
        if let conversation = conversations.first(where: { $0.id == id }) {
            return conversation
        }
        return unsentCanvases[id]
    }

    func registerUnsentCanvas(_ canvas: LibreChatDomain.Conversation) {
        unsentCanvases[canvas.id] = canvas
        if canvas.id.isLocalDraft, !canvas.isTemporaryConversation {
            UnsentCanvasManifestStore.save(canvas)
        }
        Task { await refreshDraftCanvases() }
    }

    func unregisterUnsentCanvas(_ id: ConversationID) {
        unsentCanvases.removeValue(forKey: id)
        UnsentCanvasManifestStore.remove(id)
    }

    /// Restores persisted canvases at launch; refreshDraftCanvases later
    /// surfaces only those whose saved draft text still exists in this
    /// profile's scope.
    private func restoreUnsentCanvasManifests() {
        for canvas in UnsentCanvasManifestStore.restoreAll() where unsentCanvases[canvas.id] == nil {
            unsentCanvases[canvas.id] = canvas
        }
    }

    /// Surfaces a failed row-level operation (inline menu actions) on the
    /// list's existing transient error banner.
    func reportOperationError(_ message: String?) {
        paginationError = message
    }

    private func loadCache() async {
        do {
            guard let page = try await repository.cachedConversations(limit: 25) else { return }
            // A live refresh that completed while this cache read was in
            // flight wins; writing the stale page over it would leave the
            // list cache-backed until the next manual reload.
            guard !liveRefreshArrived else { return }
            conversations = page.conversations
            freshness = page.fetchedAt
            isShowingCache = true
            state = .loaded
        } catch {
            AppLog.persistence.error("Conversation cache read failed.")
        }
    }

    private static func matchesPresetTarget(
        _ preset: ConversationTarget,
        authorizedTarget: ConversationTarget
    ) -> Bool {
        guard preset.endpoint == authorizedTarget.endpoint else { return false }
        let coordinates: [(String?, String?)] = [
            (preset.endpointType, authorizedTarget.endpointType),
            (preset.model, authorizedTarget.model),
            (preset.agentID, authorizedTarget.agentID),
            (preset.assistantID, authorizedTarget.assistantID),
            (preset.spec, authorizedTarget.spec)
        ]
        return coordinates.allSatisfy { required, actual in
            guard let required else { return true }
            return required == actual
        }
    }

    private func installCreatedPreset(
        _ preset: ChatPreset,
        profileID: ServerProfileID,
        accountID: AccountID
    ) {
        var snapshot = presetLibrary.flatMap {
            $0.profileID == profileID && $0.accountID == accountID ? $0 : nil
        } ?? PresetLibrarySnapshot(
            profileID: profileID,
            accountID: accountID,
            presets: []
        )
        snapshot.presets.removeAll { $0.id == preset.id }
        snapshot.presets.insert(preset, at: 0)
        snapshot.fetchedAt = Date()
        presetLibrary = snapshot
        presetError = nil
    }
}

@MainActor
@Observable
final class ArchivedConversationListModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let repository: any ConversationListFeatureRepository
    private let onUnauthorized: @MainActor () async -> Void
    private(set) var state: State = .idle
    private(set) var conversations: [LibreChatDomain.Conversation] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var operationID: ConversationID?
    private(set) var errorMessage: String?

    init(
        repository: any ConversationListFeatureRepository,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    /// Mutations (unarchive, delete) advance this so an in-flight listing
    /// that captured pre-mutation state can never resurrect a removed row.
    private var listingRevision = 0

    func reload() async {
        guard operationID == nil else { return }
        if conversations.isEmpty { state = .loading }
        errorMessage = nil
        listingRevision &+= 1
        let revision = listingRevision
        do {
            let page = try await repository.archivedConversations(cursor: nil, limit: 25)
            guard revision == listingRevision else { return }
            conversations = page.conversations
            nextCursor = page.nextCursor
            state = .loaded
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            guard revision == listingRevision else { return }
            state = conversations.isEmpty ? .failed(error.userFacingMessage) : .loaded
            errorMessage = conversations.isEmpty ? nil : error.userFacingMessage
        }
    }

    func loadMoreIfNeeded(after conversation: LibreChatDomain.Conversation) async {
        guard conversation.id == conversations.last?.id,
              let nextCursor,
              !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let revision = listingRevision
        do {
            let page = try await repository.archivedConversations(cursor: nextCursor, limit: 25)
            guard revision == listingRevision else { return }
            let existingIDs = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.conversations.filter { !existingIDs.contains($0.id) })
            self.nextCursor = page.nextCursor
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            guard revision == listingRevision else { return }
            errorMessage = error.userFacingMessage
        }
    }

    func unarchive(_ conversation: LibreChatDomain.Conversation) async -> LibreChatDomain.Conversation? {
        guard operationID == nil else { return nil }
        operationID = conversation.id
        defer { operationID = nil }
        listingRevision &+= 1
        do {
            let restored = try await repository.archive(id: conversation.id, isArchived: false)
            conversations.removeAll { $0.id == conversation.id }
            errorMessage = nil
            return restored
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            errorMessage = error.userFacingMessage
            return nil
        }
    }

    func delete(_ conversation: LibreChatDomain.Conversation) async {
        guard operationID == nil else { return }
        operationID = conversation.id
        defer { operationID = nil }
        listingRevision &+= 1
        do {
            try await repository.delete(id: conversation.id)
            conversations.removeAll { $0.id == conversation.id }
            errorMessage = nil
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            errorMessage = error.userFacingMessage
        }
    }
}


/// Durable metadata for unsent draft canvases. The draft text lives in
/// SwiftData, but the canvas (its local id, target, and project) previously
/// existed only in memory, so a process termination between typing and the
/// first send made the saved text permanently unreachable.
enum UnsentCanvasManifestStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LibreChatUnsentCanvases", directoryHint: .isDirectory)
    }

    static func url(for id: ConversationID) -> URL {
        let safe = String(id.rawValue.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_"
        })
        return directory.appending(path: safe + ".json")
    }

    static func save(_ canvas: LibreChatDomain.Conversation) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(canvas)
            try data.write(to: url(for: canvas.id), options: .atomic)
        } catch {
            AppLog.persistence.error("Unsent canvas metadata could not be persisted.")
        }
    }

    static func remove(_ id: ConversationID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    static func restoreAll() -> [LibreChatDomain.Conversation] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.compactMap { fileURL in
            guard fileURL.pathExtension == "json" else { return nil }
            return try? JSONDecoder().decode(LibreChatDomain.Conversation.self, from: Data(contentsOf: fileURL))
        }
    }
}