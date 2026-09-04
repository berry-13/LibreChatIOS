import Foundation
import LibreChatDomain
import Observation
import SwiftUI

protocol BookmarkFeatureRepository: ConversationTagRepository {
    func bookmarkedConversations(
        tag: String,
        cursor: String?,
        limit: Int
    ) async throws -> ConversationPage
}

extension LibreChatRepository: BookmarkFeatureRepository {}

@MainActor
@Observable
final class BookmarksModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let repository: any BookmarkFeatureRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private(set) var state: State = .idle
    private(set) var tags: [ConversationTag] = []
    private(set) var operationName: String?
    private(set) var errorMessage: String?

    init(
        repository: any BookmarkFeatureRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        guard operationName == nil else { return }
        if tags.isEmpty { state = .loading }
        errorMessage = nil
        do {
            tags = try await repository.conversationTags().sorted(by: Self.order)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            state = tags.isEmpty ? .failed(error.userFacingMessage) : .loaded
            errorMessage = tags.isEmpty ? nil : error.userFacingMessage
        }
    }

    func create(name: String, description: String) async -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, operationName == nil, !isOffline() else { return false }
        operationName = normalized
        errorMessage = nil
        defer { operationName = nil }
        do {
            let created = try await repository.createConversationTag(
                CreateConversationTagInput(
                    tag: normalized,
                    description: description.isEmpty ? nil : description
                )
            )
            upsert(created)
            return true
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            errorMessage = error.userFacingMessage
            return false
        }
    }

    func update(
        _ existing: ConversationTag,
        name: String,
        description: String
    ) async -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, operationName == nil, !isOffline() else { return false }
        operationName = existing.tag
        errorMessage = nil
        defer { operationName = nil }
        do {
            let updated = try await repository.updateConversationTag(
                named: existing.tag,
                input: UpdateConversationTagInput(
                    tag: normalized == existing.tag ? nil : normalized,
                    description: description
                )
            )
            tags.removeAll { $0.id == existing.id || $0.tag == existing.tag }
            upsert(updated)
            return true
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            errorMessage = error.userFacingMessage
            return false
        }
    }

    func delete(_ tag: ConversationTag) async {
        guard operationName == nil, !isOffline() else { return }
        operationName = tag.tag
        errorMessage = nil
        defer { operationName = nil }
        do {
            let deleted = try await repository.deleteConversationTag(named: tag.tag)
            tags.removeAll { $0.id == deleted.id || $0.tag == deleted.tag }
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            errorMessage = error.userFacingMessage
        }
    }

    private func upsert(_ tag: ConversationTag) {
        tags.removeAll { $0.id == tag.id || $0.tag == tag.tag }
        tags.append(tag)
        tags.sort(by: Self.order)
    }

    private static func order(_ lhs: ConversationTag, _ rhs: ConversationTag) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
    }
}

@MainActor
@Observable
final class BookmarkAssignmentModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let repository: any BookmarkFeatureRepository
    private let conversation: LibreChatDomain.Conversation
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void
    private let originalNames: [String]
    private(set) var state: State = .idle
    private(set) var tags: [ConversationTag] = []
    private(set) var selectedNames: Set<String>
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    init(
        conversation: LibreChatDomain.Conversation,
        repository: any BookmarkFeatureRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.conversation = conversation
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
        originalNames = conversation.tags ?? []
        selectedNames = Set(conversation.tags ?? [])
    }

    var unavailableSelectedNames: [String] {
        let known = Set(tags.map(\.tag))
        return originalNames.filter { selectedNames.contains($0) && !known.contains($0) }
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        state = .loading
        do {
            tags = try await repository.conversationTags().sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending
            }
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            state = .failed(error.userFacingMessage)
        }
    }

    func toggle(_ name: String) {
        if selectedNames.contains(name) {
            selectedNames.remove(name)
        } else {
            selectedNames.insert(name)
        }
    }

    func save() async -> LibreChatDomain.Conversation? {
        guard !isSaving, !isOffline() else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let knownNames = Set(tags.map(\.tag))
        let orderedKnown = tags.map(\.tag).filter(selectedNames.contains)
        let retainedUnknown = originalNames.filter {
            selectedNames.contains($0) && !knownNames.contains($0)
        }
        do {
            let finalNames = try await repository.replaceConversationTags(
                conversationID: conversation.id,
                tags: orderedKnown + retainedUnknown
            )
            var updated = conversation
            updated.tags = finalNames
            return updated
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            errorMessage = error.userFacingMessage
            return nil
        }
    }
}

@MainActor
@Observable
private final class BookmarkedConversationListModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let repository: any BookmarkFeatureRepository
    private let tag: String
    private let onUnauthorized: @MainActor () async -> Void
    private(set) var state: State = .idle
    private(set) var conversations: [LibreChatDomain.Conversation] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var paginationError: String?

    init(
        tag: String,
        repository: any BookmarkFeatureRepository,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.tag = tag
        self.repository = repository
        self.onUnauthorized = onUnauthorized
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        if conversations.isEmpty { state = .loading }
        do {
            let page = try await repository.bookmarkedConversations(tag: tag, cursor: nil, limit: 25)
            conversations = page.conversations
            nextCursor = page.nextCursor
            state = .loaded
            paginationError = nil
        } catch is CancellationError {
            return
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            state = conversations.isEmpty ? .failed(error.userFacingMessage) : .loaded
            paginationError = conversations.isEmpty ? nil : error.userFacingMessage
        }
    }

    func loadMoreIfNeeded(after conversation: LibreChatDomain.Conversation) async {
        guard conversation.id == conversations.last?.id,
              let nextCursor,
              !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.bookmarkedConversations(
                tag: tag,
                cursor: nextCursor,
                limit: 25
            )
            let known = Set(conversations.map(\.id))
            conversations.append(contentsOf: page.conversations.filter { !known.contains($0.id) })
            self.nextCursor = page.nextCursor
            paginationError = nil
        } catch is CancellationError {
            return
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            paginationError = error.userFacingMessage
        }
    }
}

private struct BookmarkEditorDestination: Identifiable {
    let id: String
    let existing: ConversationTag?

    static let create = BookmarkEditorDestination(id: "create", existing: nil)

    static func edit(_ tag: ConversationTag) -> BookmarkEditorDestination {
        BookmarkEditorDestination(id: "edit-\(tag.id.rawValue)", existing: tag)
    }
}

struct BookmarksView: View {
    @State private var model: BookmarksModel
    @State private var editor: BookmarkEditorDestination?
    @State private var tagToDelete: ConversationTag?
    private let repository: any BookmarkFeatureRepository
    private let onUnauthorized: @MainActor () async -> Void
    private let onSelectConversation: @MainActor (LibreChatDomain.Conversation) -> Void

    init(
        repository: any BookmarkFeatureRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onSelectConversation: @escaping @MainActor (LibreChatDomain.Conversation) -> Void
    ) {
        self.repository = repository
        self.onUnauthorized = onUnauthorized
        self.onSelectConversation = onSelectConversation
        _model = State(initialValue: BookmarksModel(
            repository: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .loading:
                    SkeletonListView(count: 9, accessibilityLabel: "Loading bookmarks")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Bookmarks unavailable", systemImage: "bookmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.reload() } }
                    }
                case .loaded where model.tags.isEmpty:
                    ContentUnavailableView {
                        Label("No bookmarks", systemImage: "bookmark")
                    } description: {
                        Text("Create a bookmark, then assign it to conversations from the chat list.")
                    } actions: {
                        Button("New bookmark") { editor = .create }
                            .buttonStyle(.borderedProminent)
                    }
                case .loaded:
                    List(model.tags) { tag in
                        NavigationLink {
                            BookmarkedConversationsView(
                                tag: tag.tag,
                                repository: repository,
                                onUnauthorized: onUnauthorized,
                                onSelect: onSelectConversation
                            )
                        } label: {
                            BookmarkDirectoryRow(tag: tag)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editor = .edit(tag) }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                tagToDelete = tag
                            }
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                tagToDelete = tag
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Edit", systemImage: "pencil") { editor = .edit(tag) }
                                .tint(.blue)
                        }
                        .disabled(model.operationName == tag.tag)
                    }
                    .refreshable { await model.reload() }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New bookmark", systemImage: "plus") { editor = .create }
                }
            }
            .task { await model.loadIfNeeded() }
            .overlay(alignment: .bottom) {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .adaptiveSurface(in: Capsule())
                        .padding()
                }
            }
            .sheet(item: $editor) { destination in
                BookmarkEditorSheet(model: model, existing: destination.existing)
            }
            .confirmationDialog(
                "Delete this bookmark?",
                isPresented: Binding(
                    get: { tagToDelete != nil },
                    set: { if !$0 { tagToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let tag = tagToDelete else { return }
                    tagToDelete = nil
                    Task { await model.delete(tag) }
                }
                Button("Cancel", role: .cancel) { tagToDelete = nil }
            } message: {
                Text("The bookmark will be removed from every conversation that uses it.")
            }
        }
    }
}

private struct BookmarkDirectoryRow: View {
    let tag: ConversationTag

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(tag.tag)
                    .font(.body.weight(.medium))
                if let description = tag.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(tag.conversationCount, format: .number)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(tag.conversationCount) conversations")
        }
        .padding(.vertical, 3)
    }
}

private struct BookmarkEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BookmarksModel
    let existing: ConversationTag?
    @State private var name: String
    @State private var description: String

    init(model: BookmarksModel, existing: ConversationTag?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.tag ?? "")
        _description = State(initialValue: existing?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bookmark") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.sentences)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(existing == nil ? "New bookmark" : "Edit bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let saved: Bool
                            if let existing {
                                saved = await model.update(
                                    existing,
                                    name: name,
                                    description: description
                                )
                            } else {
                                saved = await model.create(name: name, description: description)
                            }
                            if saved { dismiss() }
                        }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.operationName != nil
                    )
                }
            }
        }
    }
}

struct BookmarkAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: BookmarkAssignmentModel
    let onSaved: @MainActor (LibreChatDomain.Conversation) -> Void

    init(
        conversation: LibreChatDomain.Conversation,
        repository: any BookmarkFeatureRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onSaved: @escaping @MainActor (LibreChatDomain.Conversation) -> Void
    ) {
        _model = State(initialValue: BookmarkAssignmentModel(
            conversation: conversation,
            repository: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .loading:
                    SkeletonListView(count: 9, accessibilityLabel: "Loading bookmarks")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Bookmarks unavailable", systemImage: "bookmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.loadIfNeeded() } }
                    }
                case .loaded where model.tags.isEmpty:
                    ContentUnavailableView(
                        "No bookmarks",
                        systemImage: "bookmark",
                        description: Text("Create bookmarks from the account menu before assigning them.")
                    )
                case .loaded:
                    List {
                        Section {
                            ForEach(model.tags) { tag in
                                BookmarkSelectionRow(
                                    name: tag.tag,
                                    isSelected: model.selectedNames.contains(tag.tag)
                                ) {
                                    model.toggle(tag.tag)
                                }
                            }
                        }
                        if !model.unavailableSelectedNames.isEmpty {
                            Section {
                                ForEach(model.unavailableSelectedNames, id: \.self) { name in
                                    BookmarkSelectionRow(name: name, isSelected: true) {
                                        model.toggle(name)
                                    }
                                }
                            } header: {
                                Text("Unavailable on the server")
                            } footer: {
                                Text("These names are still assigned to this conversation but are missing from the bookmark directory.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Conversation bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSaving ? "Saving…" : "Save") {
                        Task {
                            guard let conversation = await model.save() else { return }
                            onSaved(conversation)
                            dismiss()
                        }
                    }
                    .disabled(model.isSaving || model.state != .loaded)
                }
            }
            .task { await model.loadIfNeeded() }
            .overlay(alignment: .bottom) {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .adaptiveSurface(in: Capsule())
                        .padding()
                }
            }
        }
    }
}

private struct BookmarkSelectionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct BookmarkedConversationsView: View {
    @State private var model: BookmarkedConversationListModel
    let onSelect: @MainActor (LibreChatDomain.Conversation) -> Void

    init(
        tag: String,
        repository: any BookmarkFeatureRepository,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onSelect: @escaping @MainActor (LibreChatDomain.Conversation) -> Void
    ) {
        _model = State(initialValue: BookmarkedConversationListModel(
            tag: tag,
            repository: repository,
            onUnauthorized: onUnauthorized
        ))
        self.onSelect = onSelect
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                SkeletonListView(count: 9, accessibilityLabel: "Loading conversations")
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn’t load conversations", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await model.reload() } }
                }
            case .loaded where model.conversations.isEmpty:
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "bookmark",
                    description: Text("Assign this bookmark from a conversation’s menu.")
                )
            case .loaded:
                List(model.conversations) { conversation in
                    Button {
                        onSelect(conversation)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if let model = conversation.model, !model.isEmpty {
                                    Text(model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .task { await model.loadMoreIfNeeded(after: conversation) }
                }
                .refreshable { await model.reload() }
            }
        }
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let paginationError = model.paginationError {
                Label(paginationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .adaptiveSurface(in: Capsule())
                    .padding()
            }
        }
        .task { await model.loadIfNeeded() }
    }
}
