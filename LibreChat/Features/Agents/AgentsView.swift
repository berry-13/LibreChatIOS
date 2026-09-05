import LibreChatDomain
import SwiftUI

struct AgentManagementAvailability: Equatable {
    var hasRolePermission: Bool
    var rowCanEdit: Bool
    var resourcePermissions: AgentResourcePermissions?

    var canEditOrDuplicate: Bool { hasRolePermission && rowCanEdit }
    var canDelete: Bool { hasRolePermission && resourcePermissions?.canDelete == true }
    var showsMenu: Bool { canEditOrDuplicate || canDelete }
}

struct AgentsView: View {
    let appModel: AppModel
    let repository: LibreChatRepository
    @Bindable var conversationListModel: ConversationListModel
    let openConversation: (LibreChatDomain.Conversation) -> Void

    @State private var model: AgentDirectoryModel
    @State private var creationContext: BasicAgentCreationContext?
    @State private var isPreparingCreation = false
    @State private var creationPreparationError: String?

    init(
        appModel: AppModel,
        repository: LibreChatRepository,
        conversationListModel: ConversationListModel,
        openConversation: @escaping (LibreChatDomain.Conversation) -> Void
    ) {
        let originatingProfileID = appModel.selectedServer?.id
        self.appModel = appModel
        self.repository = repository
        self.conversationListModel = conversationListModel
        self.openConversation = openConversation
        _model = State(initialValue: AgentDirectoryModel(
            repository: repository,
            creationRepository: repository,
            isOffline: { appModel.isOffline },
            creationEnabled: { appModel.canCreateAgents },
            onUnauthorized: { await appModel.expireSession(for: originatingProfileID) }
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                switch model.state {
                case .idle where model.agents.isEmpty,
                     .loading where model.agents.isEmpty:
                    HStack { Spacer(); ProgressView("Loading agents…"); Spacer() }
                        .listRowSeparator(.hidden)
                case .offline:
                    ContentUnavailableView(
                        "Agents need a connection",
                        systemImage: "wifi.slash",
                        description: Text("Saved conversations remain available offline.")
                    )
                    .listRowSeparator(.hidden)
                case .unauthorized:
                    ContentUnavailableView(
                        "Session expired",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Sign in again to browse agents.")
                    )
                    .listRowSeparator(.hidden)
                case let .failed(message) where model.agents.isEmpty:
                    ContentUnavailableView {
                        Label("Couldn’t load agents", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.reload() } }
                    }
                    .listRowSeparator(.hidden)
                default:
                    if model.agents.isEmpty {
                        ContentUnavailableView(
                            model.normalizedQuery.isEmpty ? "No agents available" : "No matching agents",
                            systemImage: "person.crop.circle",
                            description: Text(
                                model.normalizedQuery.isEmpty
                                    ? "This account does not currently have access to a saved agent."
                                    : "Try another name or description."
                            )
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(model.agents) { agent in
                            NavigationLink {
                                AgentDetailView(
                                    summary: agent,
                                    appModel: appModel,
                                    repository: repository,
                                    conversationListModel: conversationListModel,
                                    openConversation: openConversation,
                                    onDirectoryChanged: { await model.reload() }
                                )
                            } label: {
                                AgentRow(agent: agent)
                            }
                            .task { await model.loadMoreIfNeeded(after: agent) }
                        }
                        if model.isLoadingMore {
                            HStack { Spacer(); ProgressView(); Spacer() }
                                .listRowSeparator(.hidden)
                        }
                    }
                }

                if let pageError = model.pageError {
                    Label(pageError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let creationPreparationError {
                    Label(creationPreparationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("agent-create-preparation-error")
                }
            }
            .navigationTitle("Agents")
            .searchable(text: $model.query, prompt: "Search agents")
            .onChange(of: model.query) { _, _ in model.queryChanged() }
            .refreshable { await model.reload() }
            .toolbar {
                if appModel.canCreateAgents {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("New agent", systemImage: "plus") {
                            Task { await prepareCreation() }
                        }
                        .disabled(!model.canCreateAgent || isPreparingCreation)
                        .accessibilityIdentifier("agent-create")
                        .accessibilityHint(
                            model.creationRequiresRefresh
                                ? "Refresh the agent directory before creating another agent."
                                : "Reviews a model and creates a private basic saved agent."
                        )
                    }
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .sheet(item: $creationContext, onDismiss: {
            guard model.creationRequiresRefresh else { return }
            Task { await model.reload() }
        }) { context in
            BasicAgentCreationView(context: context, repository: repository) { request in
                try await model.createBasicAgent(request)
            }
        }
        .accessibilityIdentifier("agents-library")
    }

    private func prepareCreation() async {
        guard model.canCreateAgent, !isPreparingCreation else { return }
        isPreparingCreation = true
        creationPreparationError = nil
        defer { isPreparingCreation = false }

        await conversationListModel.loadTargets(forceRefresh: true)
        guard let catalog = conversationListModel.targetCatalog else {
            creationPreparationError = conversationListModel.targetError
                ?? "Models could not be verified for agent creation."
            return
        }
        let choices = BasicAgentCreationChoice.choices(from: catalog)
        guard !choices.isEmpty else {
            creationPreparationError = "No authorized model is available for basic agent creation."
            return
        }
        creationContext = BasicAgentCreationContext(
            profileID: catalog.profileID,
            accountID: catalog.accountID,
            choices: choices
        )
    }
}

struct BasicAgentCreationContext: Identifiable, Equatable {
    let profileID: ServerProfileID
    let accountID: AccountID
    let choices: [BasicAgentCreationChoice]

    var id: String { "\(profileID.rawValue):\(accountID.rawValue)" }
}

struct BasicAgentCreationChoice: Identifiable, Equatable {
    let id: String
    let label: String
    let review: BasicAgentModelReview

    static func choices(from catalog: TargetCatalogSnapshot) -> [Self] {
        var seen = Set<BasicAgentModelReview>()
        return catalog.options.compactMap { option in
            let target = option.target
            guard target.agentID == nil,
                  target.assistantID == nil,
                  target.spec == nil,
                  let model = target.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else { return nil }
            let provider = target.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !provider.isEmpty else { return nil }
            let review = BasicAgentModelReview(provider: provider, model: model)
            guard seen.insert(review).inserted else { return nil }
            return Self(id: "\(provider):\(model)", label: option.label, review: review)
        }
    }
}

struct BasicAgentCreationDraft: Equatable {
    var name = ""
    var description = ""
    var instructions = ""
    var category = ""

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedDescription: String? { normalizedOptional(description) }
    var normalizedInstructions: String? { normalizedOptional(instructions) }
    var normalizedCategory: String? { normalizedOptional(category) }

    var validationMessage: String? {
        if normalizedName.isEmpty { return "Enter an agent name." }
        if normalizedName.utf16.count > 1_000 || hasDisallowedSingleLineControl(normalizedName) {
            return "Keep the name under 1,000 characters and on one line."
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 10_000
            || hasDisallowedTextControl(description) {
            return "Keep the description under 10,000 characters."
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 32_000
            || hasDisallowedTextControl(instructions) {
            return "Keep the instructions under 32,000 characters."
        }
        if category.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 200
            || hasDisallowedSingleLineControl(category) {
            return "Keep the category under 200 characters and on one line."
        }
        return nil
    }

    var canCreate: Bool { validationMessage == nil }

    func request(
        context: BasicAgentCreationContext,
        choice: BasicAgentCreationChoice
    ) -> BasicAgentCreationRequest {
        BasicAgentCreationRequest(
            profileID: context.profileID,
            accountID: context.accountID,
            name: normalizedName,
            description: normalizedDescription,
            instructions: normalizedInstructions,
            category: normalizedCategory,
            reviewedModel: choice.review
        )
    }

    private func normalizedOptional(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func hasDisallowedSingleLineControl(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func hasDisallowedTextControl(_ value: String) -> Bool {
        let allowed: Set<Unicode.Scalar> = ["\t", "\n", "\r"]
        return value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && !allowed.contains($0)
        }
    }
}

private struct BasicAgentCreationView: View {
    let context: BasicAgentCreationContext
    let repository: LibreChatRepository
    let create: @MainActor (BasicAgentCreationRequest) async throws -> BasicAgentCreationOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var draft = BasicAgentCreationDraft()
    @State private var isShowingModelDropdown = false
    /// No default model: a brand-new agent starts unselected and the user
    /// must choose one — the Create action stays disabled until then.
    @State private var selectedReview: BasicAgentModelReview?
    @State private var categoryDirectory = CategoryDirectoryModel()
    @State private var isCreating = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?
    @State private var announcementState = AccessibilityAnnouncementState()

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                        .textContentType(.name)
                        .accessibilityIdentifier("agent-create-name")
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("agent-create-description")
                    CategorySelectorField(directory: categoryDirectory, selection: $draft.category)
                }

                Section {
                    Button {
                        // Trigger-as-toggle, matching the chat header's
                        // selector; the dropdown presents as an anchored
                        // popover, not a bottom drawer.
                        isShowingModelDropdown.toggle()
                    } label: {
                        HStack {
                            Text(selectedChoice?.label ?? "Choose a model")
                                .foregroundStyle(selectedChoice == nil ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Model")
                    .accessibilityValue(selectedChoice?.label ?? "None selected")
                    .accessibilityIdentifier("agent-create-model")
                    .popover(isPresented: $isShowingModelDropdown, arrowEdge: .bottom) {
                        agentModelDropdown
                            .presentationCompactAdaptation(.popover)
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text(selectedChoice == nil
                        ? "Pick the provider and model this agent runs on."
                        : "The app verifies this provider and model again with LibreChat immediately before creating the agent.")
                }

                Section {
                    TextEditor(text: $draft.instructions)
                        .frame(minHeight: 170)
                        .accessibilityIdentifier("agent-create-instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("These instructions are stored on your LibreChat server. Review them before saving.")
                }

                Section {
                    Label("Creates a private basic agent with no tools, actions, files, MCP servers, skills, subagents, or credentials.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Safe scope")
                }

                if let validationMessage = draft.validationMessage,
                   !draft.name.isEmpty || !draft.description.isEmpty
                    || !draft.instructions.isEmpty || !draft.category.isEmpty {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("agent-create-error")
                        if isOutcomeUnknown {
                            Text("Close this sheet and let the directory refresh before creating another agent.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if isCreating {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Creating agent…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("agent-create-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOutcomeUnknown ? "Close" : "Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .disabled(isCreating || isOutcomeUnknown || !draft.canCreate || selectedChoice == nil)
                        .accessibilityIdentifier("agent-create-confirm")
                }
            }
        }
        .interactiveDismissDisabled(isCreating || isOutcomeUnknown)
        .onChange(of: errorMessage) { _, value in
            if let announcement = announcementState.announcement(for: value) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
        .task {
            await categoryDirectory.loadIfNeeded {
                try await repository.promptCategories()
            }
        }
    }

    /// The chat header's unified provider/model dropdown, presented as an
    /// anchored popover over the form. Same two-page navigation, same row
    /// language, no Agent-Builder-specific bottom sheet.
    private var agentModelDropdown: some View {
        TargetDropdownCard(
            providers: TargetProviderGroup.build(from: choicesAsOptions),
            selectedProvider: $dropdownProvider,
            currentOptionID: selectedOptionID,
            isLoading: false,
            errorMessage: nil,
            maximumHeight: 380,
            retry: {},
            start: { option in
                if let match = context.choices.first(
                    where: {
                        $0.review.provider == option.target.endpoint
                            && $0.review.model == option.target.model
                    }
                ) {
                    selectedReview = match.review
                }
                isShowingModelDropdown = false
            }
        )
        .frame(width: 348, height: 380)
    }

    @State private var dropdownProvider: TargetProviderGroup?

    private var choicesAsOptions: [ChatTargetOption] {
        context.choices.map { choice in
            ChatTargetOption(
                id: choice.id,
                label: choice.label,
                target: ConversationTarget(
                    endpoint: choice.review.provider,
                    model: choice.review.model
                )
            )
        }
    }

    private var selectedOptionID: String? {
        guard let selectedReview else { return nil }
        return choicesAsOptions.first {
            $0.target.endpoint == selectedReview.provider && $0.target.model == selectedReview.model
        }?.id
    }

    private var selectedChoice: BasicAgentCreationChoice? {
        guard let selectedReview else { return nil }
        return context.choices.first { $0.review == selectedReview }
    }

    private func submit() {
        guard !isCreating,
              !isOutcomeUnknown,
              draft.canCreate,
              let selectedChoice else { return }
        isCreating = true
        errorMessage = nil
        let request = draft.request(context: context, choice: selectedChoice)
        Task {
            do {
                let outcome = try await create(request)
                isCreating = false
                switch outcome {
                case .confirmed:
                    dismiss()
                case .outcomeUnknown:
                    isOutcomeUnknown = true
                    errorMessage = "LibreChat may have created this agent, but the result could not be attributed safely."
                }
            } catch {
                isCreating = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct AgentRow: View {
    let agent: ChatAgentSummary

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatarIcon(agent: agent, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let description = agent.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let category = agent.category { Text(category) }
                    if agent.isPublic { Text("Shared") }
                    if agent.canEdit { Text("Editable") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.name)
        .accessibilityValue(agent.description ?? "")
        .accessibilityHint("Opens agent details.")
    }
}

/// The agent's own avatar whenever the server provides a valid one — the
/// same image chain LibreChat-web's `renderAgentAvatar` uses — with the
/// generic person glyph only as the no-avatar fallback. The image loads
/// through the environment's authenticated fetcher: secure image links
/// reject plain AsyncImage requests without the session cookie.
struct AgentAvatarIcon: View {
    let agent: ChatAgentSummary
    var size: CGFloat = 34

    @Environment(\.fetchServerImage) private var fetchServerImage
    @State private var loadedImage: UIImage?

    var body: some View {
        Group {
            if let avatarURL = agent.avatarURL {
                avatarImage(url: avatarURL)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func avatarImage(url: URL) -> some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            if let cached = ServerEntityImageStore.cachedImage(for: url) {
                loadedImage = cached
                return
            }
            loadedImage = nil
            guard let data = await fetchServerImage(url),
                  let decoded = ServerEntityImageStore.downsampledImage(from: data) else { return }
            ServerEntityImageStore.store(decoded, for: url)
            loadedImage = decoded
        }
    }

    private var fallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: size * 0.62))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AgentDetailView: View {
    let summary: ChatAgentSummary
    let appModel: AppModel
    let repository: LibreChatRepository
    @Bindable var conversationListModel: ConversationListModel
    let openConversation: (LibreChatDomain.Conversation) -> Void
    let onDirectoryChanged: @MainActor () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var model: AgentDetailModel
    @State private var isStartingChat = false
    @State private var startError: String?
    @State private var managementSelection: AgentManagementSelection?
    @State private var isPreparingManagement = false
    @State private var managementError: String?
    @State private var duplicateNotice: String?
    @State private var wasDeleted = false

    init(
        summary: ChatAgentSummary,
        appModel: AppModel,
        repository: LibreChatRepository,
        conversationListModel: ConversationListModel,
        openConversation: @escaping (LibreChatDomain.Conversation) -> Void,
        onDirectoryChanged: @escaping @MainActor () async -> Void
    ) {
        let originatingProfileID = appModel.selectedServer?.id
        self.summary = summary
        self.appModel = appModel
        self.repository = repository
        self.conversationListModel = conversationListModel
        self.openConversation = openConversation
        self.onDirectoryChanged = onDirectoryChanged
        _model = State(initialValue: AgentDetailModel(
            id: summary.id,
            repository: repository,
            managementRepository: repository,
            onUnauthorized: { await appModel.expireSession(for: originatingProfileID) }
        ))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        AgentAvatarIcon(agent: summary, size: 40)
                        Text(summary.name)
                            .font(.title2.bold())
                    }
                    if let description = model.detail?.description ?? summary.description {
                        Text(description)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            switch model.state {
            case .idle, .loading:
                HStack { Spacer(); ProgressView("Loading details…"); Spacer() }
            case .unauthorized:
                Label("Sign in again to view this agent.", systemImage: "person.crop.circle.badge.exclamationmark")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Agent details unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.reload() } }
                }
            case .loaded:
                if let detail = model.detail {
                    if detail.provider != nil || detail.model != nil || detail.version != nil {
                        Section("Configuration") {
                            if let provider = detail.provider { LabeledContent("Provider", value: provider) }
                            if let modelName = detail.model { LabeledContent("Model", value: modelName) }
                            if let version = detail.version { LabeledContent("Version", value: String(version)) }
                            LabeledContent("Visibility", value: detail.isPublic ? "Shared" : "Private")
                        }
                    }
                    if !detail.conversationStarters.isEmpty {
                        Section {
                            ForEach(Array(detail.conversationStarters.enumerated()), id: \.offset) { _, starter in
                                Text(starter)
                                    .textSelection(.enabled)
                            }
                        } header: {
                            Text("Conversation starters")
                        } footer: {
                            Text("Start a chat, then use one of these prompts as inspiration.")
                        }
                    }
                }
            }

            if let startError {
                Label(startError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agent-start-error")
            }
            if let managementError {
                Label(managementError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agent-management-error")
            }
            if let duplicateNotice {
                Label(duplicateNotice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("agent-duplicate-notice")
            }
        }
        .navigationTitle(model.detail?.name ?? summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsManagementMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Manage", systemImage: "ellipsis.circle") {
                        if canEditOrDuplicate {
                            Button("Edit details", systemImage: "pencil") {
                                Task { await prepareMetadataEdit() }
                            }
                            Button("Version history", systemImage: "clock.arrow.circlepath") {
                                managementError = nil
                                duplicateNotice = nil
                                managementSelection = .versions(
                                    id: summary.id,
                                    name: model.detail?.name ?? summary.name
                                )
                            }
                            Button("Duplicate agent", systemImage: "plus.square.on.square") {
                                managementError = nil
                                duplicateNotice = nil
                                managementSelection = .duplicate(
                                    id: summary.id,
                                    name: model.detail?.name ?? summary.name
                                )
                            }
                        }
                        if managementAvailability.canDelete {
                            Divider()
                            Button("Delete agent", systemImage: "trash", role: .destructive) {
                                managementError = nil
                                duplicateNotice = nil
                                managementSelection = .delete(
                                    id: summary.id,
                                    name: model.detail?.name ?? summary.name
                                )
                            }
                        }
                    }
                    .disabled(!canManage || isPreparingManagement)
                    .accessibilityIdentifier("agent-manage-menu")
                    .accessibilityHint(
                        appModel.isOffline
                            ? "Agent management is unavailable offline."
                            : "Edits safe details, reviews server versions, creates a copy, or deletes when permitted."
                    )
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isStartingChat ? "Starting…" : "Start chat") {
                    Task { await startChat() }
                }
                .disabled(isStartingChat || appModel.isOffline || model.detail == nil)
                .accessibilityIdentifier("agent-start-chat")
                .accessibilityHint(
                    appModel.isOffline
                        ? "Starting a chat is unavailable offline."
                        : "Creates a new chat using current server policy."
                )
            }
        }
        .task {
            await model.loadIfNeeded()
            if hasManagementRolePermission { await model.loadResourcePermissions() }
        }
        .sheet(item: $managementSelection, onDismiss: {
            guard wasDeleted else { return }
            wasDeleted = false
            Task {
                await onDirectoryChanged()
                dismiss()
            }
        }) { selection in
            Group {
                switch selection {
                case let .edit(metadata):
                    AgentMetadataEditView(metadata: metadata) { input in
                        let updated = try await model.updateMetadata(input)
                        await onDirectoryChanged()
                        return updated
                    }
                case let .duplicate(_, name):
                    AgentDuplicateView(agentName: name) {
                        let copy = try await model.duplicate()
                        await onDirectoryChanged()
                        duplicateNotice = "Created \(copy.name)."
                        return copy
                    }
                case let .versions(_, name):
                    AgentVersionHistoryView(
                        agentName: name,
                        loadHistory: { try await model.versions() },
                        restore: { version in
                            let metadata = try await model.revert(version)
                            await onDirectoryChanged()
                            return metadata
                        }
                    )
                case let .delete(_, name):
                    AgentDeleteView(agentName: name) {
                        try await model.delete()
                        wasDeleted = true
                    }
                }
            }
        }
    }

    private var hasManagementRolePermission: Bool {
        appModel.agentPermissions?.canManageMetadata == true
    }

    private var managementAvailability: AgentManagementAvailability {
        AgentManagementAvailability(
            hasRolePermission: hasManagementRolePermission,
            rowCanEdit: summary.canEdit,
            resourcePermissions: model.resourcePermissions
        )
    }

    private var canEditOrDuplicate: Bool {
        managementAvailability.canEditOrDuplicate
    }

    private var showsManagementMenu: Bool {
        managementAvailability.showsMenu
    }

    private var canManage: Bool {
        showsManagementMenu && !appModel.isOffline && model.state == .loaded
    }

    private func prepareMetadataEdit() async {
        guard canManage, !isPreparingManagement else { return }
        isPreparingManagement = true
        managementError = nil
        duplicateNotice = nil
        defer { isPreparingManagement = false }
        do {
            managementSelection = .edit(try await model.managementDetail())
        } catch is CancellationError {
            return
        } catch {
            managementError = error.userFacingMessage
        }
    }

    private func startChat() async {
        guard !isStartingChat, !appModel.isOffline else { return }
        isStartingChat = true
        startError = nil
        defer { isStartingChat = false }

        await conversationListModel.loadTargets(forceRefresh: true)
        switch AgentStartTargetResolver.resolve(
            agentID: summary.id,
            options: conversationListModel.availableTargets
        ) {
        case let .available(target):
            if let conversation = await conversationListModel.createConversation(
                title: "New chat",
                target: target
            ) {
                openConversation(conversation)
            } else {
                startError = conversationListModel.creationError
                    ?? "This agent could not start a new chat."
            }
        case .unavailable:
            startError = conversationListModel.targetError
                ?? "This agent is no longer available for new chats. Refresh the server and try again."
        case .ambiguous:
            startError = "This agent has multiple configured chat choices. Open New Chat and choose the intended configuration."
        }
    }
}

private enum AgentManagementSelection: Identifiable {
    case edit(ManagedAgentMetadata)
    case duplicate(id: AgentID, name: String)
    case versions(id: AgentID, name: String)
    case delete(id: AgentID, name: String)

    var id: String {
        switch self {
        case let .edit(metadata): "edit:\(metadata.id.rawValue)"
        case let .duplicate(id, _): "duplicate:\(id.rawValue)"
        case let .versions(id, _): "versions:\(id.rawValue)"
        case let .delete(id, _): "delete:\(id.rawValue)"
        }
    }
}

private struct AgentMetadataEditView: View {
    let metadata: ManagedAgentMetadata
    let update: @MainActor (AgentMetadataUpdateInput) async throws -> ManagedAgentMetadata

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentMetadataDraft
    @State private var isSaving = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    init(
        metadata: ManagedAgentMetadata,
        update: @escaping @MainActor (AgentMetadataUpdateInput) async throws -> ManagedAgentMetadata
    ) {
        self.metadata = metadata
        self.update = update
        _draft = State(initialValue: AgentMetadataDraft(metadata: metadata))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .textContentType(.name)
                    TextField("Description", text: $draft.description, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Category", text: $draft.category)
                } header: {
                    Text("Details")
                } footer: {
                    Text("Only these details are changed. Instructions, tools, actions, files, and model settings remain server-owned and untouched.")
                }

                if let validationMessage = draft.validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } footer: {
                        if isOutcomeUnknown {
                            Text("Close and refresh this agent before trying another edit.")
                        }
                    }
                }
            }
            .navigationTitle("Edit agent details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOutcomeUnknown ? "Close" : "Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(isSaving || isOutcomeUnknown || !draft.canSave(comparedWith: metadata))
                        .accessibilityIdentifier("agent-metadata-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .accessibilityIdentifier("agent-metadata-editor")
    }

    private func save() {
        guard !isSaving,
              !isOutcomeUnknown,
              draft.canSave(comparedWith: metadata) else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await update(draft.input(agentID: metadata.id))
                isSaving = false
                dismiss()
            } catch AgentManagementError.outcomeUnknown {
                isSaving = false
                isOutcomeUnknown = true
                errorMessage = AgentManagementError.outcomeUnknown.errorDescription
            } catch {
                isSaving = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct AgentDuplicateView: View {
    let agentName: String
    let duplicate: @MainActor () async throws -> ChatAgentSummary

    @Environment(\.dismiss) private var dismiss
    @State private var isDuplicating = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Create a private copy of \(agentName)?")
                        .font(.headline)
                    Text("LibreChat copies the agent on the server, rechecks referenced tools and agents, and removes action credentials that cannot be carried into the copy. The original is unchanged.")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } footer: {
                        if isOutcomeUnknown {
                            Text("The copy may exist. Close this sheet and refresh the agent list before trying again.")
                        }
                    }
                }
            }
            .navigationTitle("Duplicate agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOutcomeUnknown ? "Close" : "Cancel") { dismiss() }
                        .disabled(isDuplicating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isDuplicating ? "Duplicating…" : "Duplicate") { run() }
                        .disabled(isDuplicating || isOutcomeUnknown)
                        .accessibilityIdentifier("agent-duplicate-confirm")
                }
            }
        }
        .interactiveDismissDisabled(isDuplicating)
        .accessibilityIdentifier("agent-duplicate-sheet")
    }

    private func run() {
        guard !isDuplicating, !isOutcomeUnknown else { return }
        isDuplicating = true
        errorMessage = nil
        Task {
            do {
                _ = try await duplicate()
                isDuplicating = false
                dismiss()
            } catch AgentManagementError.outcomeUnknown {
                isDuplicating = false
                isOutcomeUnknown = true
                errorMessage = AgentManagementError.outcomeUnknown.errorDescription
            } catch {
                isDuplicating = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct AgentVersionHistoryView: View {
    let agentName: String
    let loadHistory: @MainActor () async throws -> AgentVersionHistory
    let restore: @MainActor (AgentVersionSummary) async throws -> ManagedAgentMetadata

    @Environment(\.dismiss) private var dismiss
    @State private var history: AgentVersionHistory?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var restoreNotice: String?
    @State private var selectedVersion: AgentVersionSummary?

    var body: some View {
        NavigationStack {
            List {
                if isLoading, history == nil {
                    HStack { Spacer(); ProgressView("Loading versions…"); Spacer() }
                        .listRowSeparator(.hidden)
                } else if let errorMessage, history == nil {
                    ContentUnavailableView {
                        Label("Version history unavailable", systemImage: "clock.badge.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                    .listRowSeparator(.hidden)
                } else if let history, history.versions.isEmpty {
                    ContentUnavailableView(
                        "No saved versions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("LibreChat has not stored an earlier version of this agent.")
                    )
                    .listRowSeparator(.hidden)
                } else if let history {
                    if let restoreNotice {
                        Section {
                            Label(restoreNotice, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Section {
                        ForEach(history.versions.sorted {
                            $0.coordinate.serverIndex > $1.coordinate.serverIndex
                        }) { version in
                            AgentVersionRow(version: version) {
                                selectedVersion = version
                            }
                        }
                    } header: {
                        Text("Server history")
                    } footer: {
                        Text("Versions are numbered by LibreChat's original history order. The app shows only safe metadata and does not download instructions, tools, actions, files, or model parameters.")
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .navigationTitle("Version history")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
        .sheet(item: $selectedVersion, onDismiss: {
            guard restoreNotice != nil else { return }
            Task { await load(preservingNotice: true) }
        }) { version in
            AgentVersionRestoreView(
                agentName: agentName,
                version: version,
                restore: {
                    let metadata = try await restore(version)
                    restoreNotice = "Restored \(metadata.name) from server version \(version.coordinate.serverIndex + 1)."
                    return metadata
                }
            )
        }
        .interactiveDismissDisabled(isLoading)
        .accessibilityIdentifier("agent-version-history")
    }

    private func load(preservingNotice: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        if !preservingNotice { restoreNotice = nil }
        defer { isLoading = false }
        do {
            history = try await loadHistory()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}

private struct AgentVersionRow: View {
    let version: AgentVersionSummary
    let select: () -> Void

    var body: some View {
        Group {
            if version.isRestorable {
                Button(action: select) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Reviews this server version before restoring it.")
            } else {
                content
                    .accessibilityHint("This server entry cannot be restored because its safe metadata is unavailable.")
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("agent-version-\(version.coordinate.serverIndex)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Server version \(version.coordinate.serverIndex + 1)")
                    .font(.headline)
                Spacer(minLength: 12)
                if !version.isRestorable {
                    Text("Unavailable")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let name = version.name {
                Text(name)
                    .foregroundStyle(.primary)
            } else {
                Text("Version details unavailable")
                    .foregroundStyle(.secondary)
            }
            if let description = version.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if let category = version.category { Text(category) }
                if let date = version.updatedAt ?? version.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AgentVersionRestoreView: View {
    let agentName: String
    let version: AgentVersionSummary
    let restore: @MainActor () async throws -> ManagedAgentMetadata

    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        "Restore server version \(version.coordinate.serverIndex + 1)?",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.headline)
                    if let name = version.name {
                        LabeledContent("Saved name", value: name)
                    }
                    Text("LibreChat will restore the complete server-owned configuration for \(agentName), including hidden instructions, tools, files, and model settings. The server rechecks access before applying it.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Label("This creates a new server-side change. Existing conversations are not rewritten.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } footer: {
                        if isOutcomeUnknown {
                            Text("The server may already have restored this version. Close and refresh the agent before taking another management action.")
                        }
                    }
                }
            }
            .navigationTitle("Restore version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOutcomeUnknown ? "Close" : "Cancel") { dismiss() }
                        .disabled(isRestoring)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isRestoring ? "Restoring…" : "Restore") { run() }
                        .disabled(isRestoring || isOutcomeUnknown || !version.isRestorable)
                        .accessibilityIdentifier("agent-version-restore-confirm")
                }
            }
        }
        .interactiveDismissDisabled(isRestoring)
        .accessibilityIdentifier("agent-version-restore-sheet")
    }

    private func run() {
        guard !isRestoring, !isOutcomeUnknown, version.isRestorable else { return }
        isRestoring = true
        errorMessage = nil
        Task {
            do {
                _ = try await restore()
                isRestoring = false
                dismiss()
            } catch AgentManagementError.outcomeUnknown {
                isRestoring = false
                isOutcomeUnknown = true
                errorMessage = AgentManagementError.outcomeUnknown.errorDescription
            } catch {
                isRestoring = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct AgentDeleteView: View {
    let agentName: String
    let delete: @MainActor () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isDeleting = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Delete \(agentName)?", systemImage: "trash")
                        .font(.headline)
                    Text("This permanently removes the saved agent from LibreChat. Existing conversations are not deleted, but they may no longer be able to use this agent configuration.")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } footer: {
                        if isOutcomeUnknown {
                            Text("Deletion could not be verified. Close and refresh the agent list before trying again.")
                        }
                    }
                }
            }
            .navigationTitle("Delete agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOutcomeUnknown ? "Close" : "Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isDeleting ? "Deleting…" : "Delete", role: .destructive) { run() }
                        .disabled(isDeleting || isOutcomeUnknown)
                        .accessibilityIdentifier("agent-delete-confirm")
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .accessibilityIdentifier("agent-delete-sheet")
    }

    private func run() {
        guard !isDeleting, !isOutcomeUnknown else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await delete()
                isDeleting = false
                dismiss()
            } catch AgentManagementError.outcomeUnknown {
                isDeleting = false
                isOutcomeUnknown = true
                errorMessage = AgentManagementError.outcomeUnknown.errorDescription
            } catch {
                isDeleting = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct AgentMetadataDraft {
    var name: String
    var description: String
    var category: String

    init(metadata: ManagedAgentMetadata) {
        name = metadata.name
        description = metadata.description ?? ""
        category = metadata.category ?? ""
    }

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedCategory: String { category.trimmingCharacters(in: .whitespacesAndNewlines) }

    var validationMessage: String? {
        if normalizedName.isEmpty { return "Enter an agent name." }
        if normalizedName.utf16.count > 1_000 { return "Keep the agent name under 1,000 characters." }
        if normalizedDescription.utf16.count > 10_000 { return "Keep the description under 10,000 characters." }
        if normalizedCategory.utf16.count > 200 { return "Keep the category under 200 characters." }
        return nil
    }

    func canSave(comparedWith metadata: ManagedAgentMetadata) -> Bool {
        guard validationMessage == nil else { return false }
        return normalizedName != metadata.name
            || normalizedDescription != (metadata.description ?? "")
            || normalizedCategory != (metadata.category ?? "")
    }

    func input(agentID: AgentID) -> AgentMetadataUpdateInput {
        AgentMetadataUpdateInput(
            agentID: agentID,
            name: normalizedName,
            description: normalizedDescription,
            category: normalizedCategory
        )
    }
}
