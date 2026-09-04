import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class PromptManagementModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case offline
        case unauthorized
        case failed(String)
    }

    private let directory: any PromptRepository
    private let management: any PromptManagementRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private var revision: UInt = 0

    private(set) var state: State = .idle
    private(set) var groups: [PromptTemplateGroup] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?
    var query = ""

    init(
        directory: any PromptRepository,
        management: any PromptManagementRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.directory = directory
        self.management = management
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    func searchAfterDebounce() async {
        if state != .idle {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        await reload()
    }

    func reload() async {
        revision &+= 1
        let requestRevision = revision
        guard !isOffline() else {
            groups = []
            nextCursor = nil
            state = .offline
            return
        }
        state = .loading
        paginationError = nil
        do {
            let page = try await directory.promptGroups(PromptTemplateQuery(
                search: query,
                category: LibreChatPromptsAPI.myPromptsCategory,
                limit: 30
            ))
            guard requestRevision == revision, !Task.isCancelled else { return }
            groups = page.groups
            nextCursor = page.nextCursor
            state = .loaded
        } catch {
            guard requestRevision == revision, !Task.isCancelled else { return }
            await handle(error)
        }
    }

    func loadMoreIfNeeded(after group: PromptTemplateGroup) async {
        guard groups.last?.id == group.id,
              state == .loaded,
              !isLoadingMore,
              !isOffline(),
              let cursor = nextCursor else { return }
        isLoadingMore = true
        paginationError = nil
        let requestRevision = revision
        defer { if requestRevision == revision { isLoadingMore = false } }
        do {
            let page = try await directory.promptGroups(PromptTemplateQuery(
                search: query,
                category: LibreChatPromptsAPI.myPromptsCategory,
                cursor: cursor,
                limit: 30
            ))
            guard requestRevision == revision, !Task.isCancelled else { return }
            var seen = Set(groups.map(\.id))
            groups.append(contentsOf: page.groups.filter { seen.insert($0.id).inserted })
            nextCursor = page.nextCursor
        } catch {
            guard requestRevision == revision, !Task.isCancelled else { return }
            if error.isUnauthorized {
                groups = []
                nextCursor = nil
                state = .unauthorized
                await onUnauthorized()
            } else {
                paginationError = "More templates could not be loaded. Current results are unchanged."
            }
        }
    }

    func create(_ input: CreatePromptGroupInput) async throws -> PromptManagementDetail {
        guard !isOffline() else { throw PromptManagementError.unavailable }
        do {
            return try await management.createPromptGroup(input)
        } catch {
            if error.isUnauthorized {
                groups = []
                state = .unauthorized
                await onUnauthorized()
            }
            throw error
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

struct PromptManagementView: View {
    @State private var model: PromptManagementModel
    @State private var isCreating = false
    private let repository: any PromptRepository & PromptManagementRepository
    private let onUnauthorized: @MainActor () async -> Void

    init(
        repository: any PromptRepository & PromptManagementRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.onUnauthorized = onUnauthorized
        _model = State(initialValue: PromptManagementModel(
            directory: repository,
            management: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Loading your prompts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .offline:
                ContentUnavailableView(
                    "Prompts need a connection",
                    systemImage: "wifi.slash",
                    description: Text("Reconnect to LibreChat to browse your prompts.")
                )
            case .unauthorized:
                ContentUnavailableView(
                    "Session expired",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            case let .failed(message) where model.groups.isEmpty:
                ContentUnavailableView {
                    Label("Prompts unavailable", systemImage: "text.badge.star")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.reload() } }
                }
            default:
                templateList
            }
        }
        .navigationTitle("Prompts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "Search by name")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Prompt", systemImage: "plus") { isCreating = true }
                    .disabled(model.state == .offline || model.state == .unauthorized)
                    .accessibilityIdentifier("prompt-management-create")
            }
        }
        .task(id: model.query) { await model.searchAfterDebounce() }
        .sheet(isPresented: $isCreating, onDismiss: {
            Task { await model.reload() }
        }) {
            PromptCreateView(repository: repository) { input in try await model.create(input) }
        }
        .accessibilityIdentifier("prompt-management")
    }

    private var templateList: some View {
        List {
            if model.groups.isEmpty {
                ContentUnavailableView(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No prompts yet"
                        : "No matching prompts",
                    systemImage: "text.badge.star",
                    description: Text(
                        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Create a prompt to reuse your best requests."
                            : "Try a different name."
                    )
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(model.groups) { group in
                    NavigationLink {
                        PromptManagementDetailView(
                            repository: repository,
                            groupID: group.id,
                            onUnauthorized: onUnauthorized
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.name).font(.body.weight(.semibold))
                            if let summary = group.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let category = group.category, !category.isEmpty {
                                Text(category).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .task { await model.loadMoreIfNeeded(after: group) }
                }
            }

            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let paginationError = model.paginationError {
                Section {
                    Label(paginationError, systemImage: "exclamationmark.triangle")
                    Button("Retry more results") {
                        guard let last = model.groups.last else { return }
                        Task { await model.loadMoreIfNeeded(after: last) }
                    }
                }
            }
        }
        .refreshable { await model.reload() }
    }
}

private struct PromptManagementDetailView: View {
    let repository: any PromptRepository & PromptManagementRepository
    let groupID: PromptGroupID
    let onUnauthorized: @MainActor () async -> Void

    @State private var detail: PromptManagementDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isEditingMetadata = false
    @State private var isAddingVersion = false
    @State private var promotingVersionID: PromptVersionID?
    @State private var ambiguousPromotionVersionID: PromptVersionID?
    @State private var announcementState = AccessibilityAnnouncementState()

    var body: some View {
        Group {
            if isLoading, detail == nil {
                ProgressView("Loading prompt…")
            } else if let detail {
                List {
                    Section("Details") {
                        LabeledContent("Name", value: detail.group.name)
                        if !detail.group.summary.isEmpty {
                            LabeledContent("Description", value: detail.group.summary)
                        }
                        if !detail.group.category.isEmpty {
                            LabeledContent("Category", value: detail.group.category)
                        }
                        if let command = detail.group.command {
                            LabeledContent("Command", value: command)
                        }
                    }

                    Section {
                        ForEach(detail.versions) { version in
                            NavigationLink {
                                PromptVersionView(
                                    version: version,
                                    isProduction: version.id == detail.group.productionVersionID,
                                    isPromoting: promotingVersionID == version.id,
                                    isOutcomeUnknown: ambiguousPromotionVersionID == version.id,
                                    promote: { await promote(version.id) }
                                )
                            } label: {
                                PromptVersionRow(
                                    version: version,
                                    isProduction: version.id == detail.group.productionVersionID
                                )
                            }
                        }
                    } header: {
                        Text("Versions")
                    } footer: {
                        Text("New versions are private and are not used until you explicitly make one production.")
                    }

                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .refreshable { await load() }
            } else {
                ContentUnavailableView {
                    Label("Prompt unavailable", systemImage: "text.badge.xmark")
                } description: {
                    Text(errorMessage ?? "Refresh to load this prompt from LibreChat.")
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            }
        }
        .navigationTitle(detail?.group.name ?? "Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if detail != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Edit details", systemImage: "pencil") { isEditingMetadata = true }
                    Button("New version", systemImage: "plus") { isAddingVersion = true }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $isEditingMetadata) {
            if let group = detail?.group {
                PromptMetadataEditView(repository: repository, group: group) { input in
                    try await repository.updatePromptGroup(input)
                }
            }
        }
        .sheet(isPresented: $isAddingVersion) {
            PromptAddVersionView(groupID: groupID) { input in
                try await repository.addPromptVersion(input)
            }
        }
        .onChange(of: isEditingMetadata) { wasPresented, isPresented in
            if wasPresented, !isPresented { Task { await load() } }
        }
        .onChange(of: isAddingVersion) { wasPresented, isPresented in
            if wasPresented, !isPresented { Task { await load() } }
        }
        .onChange(of: errorMessage) { _, value in
            if let announcement = announcementState.announcement(for: value) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await repository.promptManagementDetail(groupID: groupID)
            errorMessage = nil
        } catch {
            if error.isUnauthorized {
                detail = nil
                await onUnauthorized()
            } else {
                errorMessage = error.userFacingMessage
            }
        }
    }

    private func promote(_ versionID: PromptVersionID) async {
        guard promotingVersionID == nil else { return }
        promotingVersionID = versionID
        defer { promotingVersionID = nil }
        do {
            _ = try await repository.promotePromptVersion(
                groupID: groupID,
                versionID: versionID
            )
            await load()
            UIAccessibility.post(notification: .announcement, argument: "Production version updated")
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            if (error as? PromptManagementError) == .outcomeUnknown {
                ambiguousPromotionVersionID = versionID
            }
            errorMessage = error.userFacingMessage
        }
    }
}

private struct PromptVersionRow: View {
    let version: ManagedPromptVersion
    let isProduction: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(version.kind == .chat ? "Chat prompt" : "Text prompt")
                Spacer()
                if isProduction {
                    Label("Production", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Text(version.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let date = version.createdAt {
                Text(date, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct PromptVersionView: View {
    let version: ManagedPromptVersion
    let isProduction: Bool
    let isPromoting: Bool
    let isOutcomeUnknown: Bool
    let promote: @MainActor () async -> Void
    @State private var confirmsPromotion = false

    var body: some View {
        Form {
            Section("Prompt") {
                Text(version.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Version") {
                LabeledContent("Type", value: version.kind == .chat ? "Chat" : "Text")
                LabeledContent("Status", value: isProduction ? "Production" : "Draft version")
            }
            if !isProduction {
                Section {
                    Button("Make production") { confirmsPromotion = true }
                        .disabled(isPromoting || isOutcomeUnknown)
                } footer: {
                    if isOutcomeUnknown {
                        Text("LibreChat may have applied this change. Close this screen and refresh the template before trying again.")
                    } else {
                        Text("Future Prompt Library insertions use the production version. Existing drafts are unchanged.")
                    }
                }
            }
        }
        .navigationTitle("Prompt version")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Make this the production version?",
            isPresented: $confirmsPromotion,
            titleVisibility: .visible
        ) {
            Button("Make production") { Task { await promote() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes which version LibreChat offers for future insertions.")
        }
    }
}

private struct PromptCreateView: View {
    let repository: any PromptRepository & PromptManagementRepository
    let create: @MainActor (CreatePromptGroupInput) async throws -> PromptManagementDetail
    @Environment(\.dismiss) private var dismiss
    @State private var directory = CategoryDirectoryModel()
    @State private var draft = PromptEditorDraft()
    @State private var isSaving = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            PromptEditorForm(draft: $draft, directory: directory, includesMetadata: true, errorMessage: errorMessage)
                .navigationTitle("New Prompt")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create Prompt") { save() }
                            .disabled(isSaving || isOutcomeUnknown || !draft.canCreate)
                    }
                }
        }
        .interactiveDismissDisabled(isSaving)
        .task {
            await directory.loadIfNeeded {
                try await repository.promptCategories()
            }
        }
    }

    private func save() {
        guard !isSaving, !isOutcomeUnknown else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await create(draft.createInput)
                isSaving = false
                dismiss()
            } catch PromptManagementError.outcomeUnknown {
                isSaving = false
                isOutcomeUnknown = true
                errorMessage = PromptManagementError.outcomeUnknown.errorDescription
            } catch {
                isSaving = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct PromptAddVersionView: View {
    let groupID: PromptGroupID
    let add: @MainActor (AddPromptVersionInput) async throws -> ManagedPromptVersion
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kind: PromptTemplateKind = .text
    @State private var isSaving = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Prompt") {
                    TextEditor(text: $text).frame(minHeight: 220)
                    Picker("Type", selection: $kind) {
                        Text("Text").tag(PromptTemplateKind.text)
                        Text("Chat").tag(PromptTemplateKind.chat)
                    }
                }
                Section {
                    Text("The new version is not promoted automatically. Review it after saving, then make it production explicitly.")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("New version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || isOutcomeUnknown || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard !isSaving, !isOutcomeUnknown else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await add(AddPromptVersionInput(groupID: groupID, text: text, kind: kind))
                isSaving = false
                dismiss()
            } catch PromptManagementError.outcomeUnknown {
                isSaving = false
                isOutcomeUnknown = true
                errorMessage = PromptManagementError.outcomeUnknown.errorDescription
            } catch {
                isSaving = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

private struct PromptMetadataEditView: View {
    let repository: any PromptRepository
    let group: ManagedPromptGroup
    let update: @MainActor (UpdatePromptGroupInput) async throws -> ManagedPromptGroup
    @Environment(\.dismiss) private var dismiss
    @State private var directory = CategoryDirectoryModel()
    @State private var draft: PromptEditorDraft
    @State private var isSaving = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?

    init(
        repository: any PromptRepository,
        group: ManagedPromptGroup,
        update: @escaping @MainActor (UpdatePromptGroupInput) async throws -> ManagedPromptGroup
    ) {
        self.repository = repository
        self.group = group
        self.update = update
        _draft = State(initialValue: PromptEditorDraft(group: group))
    }

    var body: some View {
        NavigationStack {
            PromptEditorForm(
                draft: $draft,
                directory: directory,
                includesMetadata: true,
                includesPrompt: false,
                errorMessage: errorMessage
            )
            .navigationTitle("Edit prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || isOutcomeUnknown || !draft.canSaveMetadata)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .task {
            await directory.loadIfNeeded {
                try await repository.promptCategories()
            }
        }
    }

    private func save() {
        guard !isSaving, !isOutcomeUnknown else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await update(draft.updateInput(groupID: group.id))
                isSaving = false
                dismiss()
            } catch PromptManagementError.outcomeUnknown {
                isSaving = false
                isOutcomeUnknown = true
                errorMessage = PromptManagementError.outcomeUnknown.errorDescription
            } catch {
                isSaving = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

/// The prompt editor, ordered the way a user thinks: what the prompt is and
/// what it says come first; rarely-used metadata (category, the slash
/// command) hides behind an Advanced disclosure. Internal terminology stays
/// out of the primary fields.
private struct PromptEditorForm: View {
    @Binding var draft: PromptEditorDraft
    var directory: CategoryDirectoryModel
    var includesMetadata = false
    var includesPrompt = true
    var errorMessage: String?
    @State private var isShowingAdvanced = false

    var body: some View {
        Form {
            if includesPrompt {
                Section("Prompt") {
                    TextField("Name", text: $draft.name)
                    TextEditor(text: $draft.text)
                        .frame(minHeight: 180)
                        .accessibilityLabel("Prompt text")
                    Picker("Type", selection: $draft.kind) {
                        Text("Text").tag(PromptTemplateKind.text)
                        Text("Chat").tag(PromptTemplateKind.chat)
                    }
                }
            } else {
                Section("Details") {
                    TextField("Name", text: $draft.name)
                }
            }

            if includesMetadata {
                Section {
                    TextField("Description", text: $draft.summary, axis: .vertical)
                        .accessibilityHint("A short summary shown under the prompt's name.")
                    CategorySelectorField(directory: directory, selection: $draft.category)
                } header: {
                    Text("Details")
                } footer: {
                    Text("Optional. The description helps you recognize the prompt later.")
                }

                Section {
                    DisclosureGroup(isExpanded: $isShowingAdvanced) {
                        TextField("Command", text: $draft.command)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityHint("A short slash-style shortcut. Lowercase letters, numbers, and hyphens only.")
                    } label: {
                        Label("Advanced", systemImage: "gearshape")
                    }
                }
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
}

/// Shared, in-memory cached loader for the server's prompt category
/// directory. One fetch serves every editor surface (prompts, agent builder)
/// for the stale interval; a failed fetch stays empty and retries on the
/// next open — mirroring the web client's stale-while-idle category query.
@MainActor
@Observable
final class CategoryDirectoryModel {
    static let staleInterval: TimeInterval = 15 * 60
    private static var cachedCategories: [String] = []
    private static var fetchedAt: Date = .distantPast
    private static var inFlight: Task<Void, Never>?

    private(set) var categories: [String] = []

    /// Locally added categories ride along until the next server refresh, so
    /// a freshly created name stays selectable in the open editor.
    private var localAdditions: [String] = []

    func loadIfNeeded(
        fetch: @escaping @MainActor () async throws -> [String]
    ) async {
        let cacheIsFresh = Date().timeIntervalSince(Self.fetchedAt) < Self.staleInterval
        if cacheIsFresh, !Self.cachedCategories.isEmpty {
            install(Self.cachedCategories)
            return
        }
        if Self.inFlight == nil {
            Self.inFlight = Task { [weak self] in
                do {
                    let fetched = try await fetch()
                    Self.cachedCategories = fetched
                    Self.fetchedAt = Date()
                    self?.install(fetched)
                } catch {
                    // The editor falls back to free entry; a later open retries.
                    self?.install(Self.cachedCategories)
                }
                Self.inFlight = nil
            }
        }
        await Self.inFlight?.value
    }

    func addCustom(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !localAdditions.contains(trimmed) {
            localAdditions.append(trimmed)
        }
        if !Self.cachedCategories.contains(trimmed) {
            Self.cachedCategories.append(trimmed)
        }
        install(Self.cachedCategories)
    }

    private func install(_ values: [String]) {
        var seen = Set<String>()
        categories = (values + localAdditions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The category dropdown used by both the prompt editor and the agent
/// builder: existing server categories, "None", and a clean "New category…"
/// entry — no raw text field for a concept the server already enumerates.
struct CategorySelectorField: View {
    var directory: CategoryDirectoryModel
    @Binding var selection: String
    @State private var isAddingNew = false
    @State private var newCategory = ""

    var body: some View {
        Menu {
            Button {
                selection = ""
            } label: {
                if selection.isEmpty {
                    Label("None", systemImage: "checkmark")
                } else {
                    Text("None")
                }
            }
            ForEach(directory.categories, id: \.self) { category in
                Button {
                    selection = category
                } label: {
                    if category == selection {
                        Label(category, systemImage: "checkmark")
                    } else {
                        Text(category)
                    }
                }
            }
            Divider()
            Button("New category…") {
                newCategory = ""
                isAddingNew = true
            }
        } label: {
            HStack {
                Text(selection.isEmpty ? "Category" : selection)
                    .foregroundStyle(selection.isEmpty ? .secondary : .primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Category")
        .accessibilityValue(selection.isEmpty ? "None" : selection)
        .accessibilityIdentifier("category-selector")
        .alert("New category", isPresented: $isAddingNew) {
            TextField("Name", text: $newCategory)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                directory.addCustom(newCategory)
                selection = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The category is saved with this prompt and becomes available everywhere categories are offered.")
        }
    }
}

private struct PromptEditorDraft {
    var name = ""
    var summary = ""
    var category = ""
    var command = ""
    var text = ""
    var kind: PromptTemplateKind = .text

    init() {}

    init(group: ManagedPromptGroup) {
        name = group.name
        summary = group.summary
        category = group.category
        command = group.command ?? ""
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSaveMetadata: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var createInput: CreatePromptGroupInput {
        CreatePromptGroupInput(
            name: name,
            summary: summary,
            category: category,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
            text: text,
            kind: kind
        )
    }

    func updateInput(groupID: PromptGroupID) -> UpdatePromptGroupInput {
        UpdatePromptGroupInput(
            groupID: groupID,
            name: name,
            summary: summary,
            category: category,
            command: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command
        )
    }
}
