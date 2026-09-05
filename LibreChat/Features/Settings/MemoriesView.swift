import LibreChatDomain
import SwiftUI

struct MemoriesView: View {
    let appModel: AppModel
    @State private var model: MemoryCenterModel
    @State private var editor: MemoryEditorSelection?
    @State private var pendingDeletion: UserMemory?

    init(
        appModel: AppModel,
        repository: any MemoryRepository,
        permissions: MemoryPermissions
    ) {
        self.appModel = appModel
        _model = State(initialValue: MemoryCenterModel(
            repository: repository,
            permissions: permissions,
            memoriesEnabled: appModel.user?.memoriesEnabled ?? true,
            isOffline: { appModel.isOffline },
            onUnauthorized: appModel.expireSessionCallback(),
            onPreferenceChanged: { await appModel.recordMemoriesEnabled($0) }
        ))
    }

    var body: some View {
        List {
            content
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: "Search memories")
        .refreshable { await model.reload() }
        .toolbar {
            if model.canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add memory", systemImage: "plus") {
                        editor = .create(UUID())
                    }
                    .accessibilityIdentifier("memory-create")
                }
            }
        }
        .sheet(item: $editor) { selection in
            MemoryEditorView(
                selection: selection,
                characterLimit: model.characterLimit,
                canEdit: selection.memory.map(model.canEdit) ?? model.canCreate,
                save: { key, value in
                    switch selection {
                    case .create:
                        return await model.create(key: key, value: value)
                            ? nil
                            : (model.operationError ?? "The memory could not be saved.")
                    case let .edit(memory):
                        return await model.update(memory, key: key, value: value)
                            ? nil
                            : (model.operationError ?? "The memory could not be saved.")
                    }
                }
            )
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let memory = pendingDeletion {
                Button("Delete memory", role: .destructive) {
                    pendingDeletion = nil
                    Task { _ = await model.delete(memory) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("LibreChat will stop using this saved fact. This cannot be undone.")
        }
        .task { await model.loadIfNeeded() }
        .accessibilityIdentifier("memory-center")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonListView(count: 6, horizontalPadding: 0, accessibilityLabel: "Loading memories…")
                .listRowSeparator(.hidden)
        case .offline:
            ContentUnavailableView(
                "Memory needs a connection",
                systemImage: "wifi.slash",
                description: Text("For privacy, saved memories are not stored for offline browsing.")
            )
            .listRowSeparator(.hidden)
        case .unauthorized:
            ContentUnavailableView(
                "Session expired",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in again to view saved memories.")
            )
            .listRowSeparator(.hidden)
        case let .failed(message) where model.snapshot == nil:
            ContentUnavailableView {
                Label("Memories unavailable", systemImage: "brain.head.profile")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.reload() } }
            }
            .listRowSeparator(.hidden)
        default:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let snapshot = model.snapshot {
            Section("Memory controls") {
                if model.canChangePreference {
                    Toggle(
                        "Use saved memories",
                        isOn: Binding(
                            get: { model.memoriesEnabled },
                            set: { enabled in Task { await model.setEnabled(enabled) } }
                        )
                    )
                    .disabled(model.activeMutation != nil)
                    .accessibilityHint("Controls whether LibreChat may reference saved memories in future responses.")
                }
                if let tokenLimit = snapshot.tokenLimit {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Personal memory usage")
                            Spacer()
                            Text("\(snapshot.totalTokens) of \(tokenLimit) tokens")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(
                            value: Double(min(snapshot.totalTokens, tokenLimit)),
                            total: Double(tokenLimit)
                        )
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if model.partitionOptions.count > 2 {
                Section {
                    Picker("Memory group", selection: $model.partition) {
                        ForEach(model.partitionOptions, id: \.filter) { option in
                            Text(option.label).tag(option.filter)
                        }
                    }
                }
            }

            Section("Saved memories") {
                if model.visibleMemories.isEmpty {
                    ContentUnavailableView(
                        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No saved memories"
                            : "No matching memories",
                        systemImage: "brain.head.profile",
                        description: Text(
                            model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "LibreChat has not saved anything in this memory group."
                                : "Try a different word or memory group."
                        )
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(model.visibleMemories) { memory in
                        Button {
                            editor = .edit(memory)
                        } label: {
                            MemoryRow(memory: memory)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(model.canEdit(memory) ? "Opens this memory for editing." : "Opens this memory read-only.")
                        .swipeActions {
                            if model.canEdit(memory) {
                                Button("Delete", role: .destructive) {
                                    pendingDeletion = memory
                                }
                            }
                        }
                    }
                }
            }
        }

        if let operationError = model.operationError {
            Section {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum MemoryEditorSelection: Identifiable {
    case create(UUID)
    case edit(UserMemory)

    var id: String {
        switch self {
        case let .create(id): "create-\(id.uuidString)"
        case let .edit(memory): "edit-\(memory.agentID?.rawValue ?? "personal")-\(memory.key)"
        }
    }

    var memory: UserMemory? {
        if case let .edit(memory) = self { return memory }
        return nil
    }
}

private struct MemoryRow: View {
    let memory: UserMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(memory.key)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if let tokenCount = memory.tokenCount {
                    Text("\(tokenCount) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(memory.value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if memory.agentID != nil {
                Label(memory.agentName ?? "Agent-specific", systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct MemoryEditorView: View {
    let selection: MemoryEditorSelection
    let characterLimit: Int
    let canEdit: Bool
    let save: (String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var value: String
    @State private var isSaving = false
    @State private var failureMessage: String?

    init(
        selection: MemoryEditorSelection,
        characterLimit: Int,
        canEdit: Bool,
        save: @escaping (String, String) async -> String?
    ) {
        self.selection = selection
        self.characterLimit = characterLimit
        self.canEdit = canEdit
        self.save = save
        _key = State(initialValue: selection.memory?.key ?? "")
        _value = State(initialValue: selection.memory?.value ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let memory = selection.memory, memory.agentID != nil {
                    Section {
                        Label(memory.agentName ?? "Agent-specific memory", systemImage: "person.crop.circle")
                    } footer: {
                        Text("This memory remains isolated to its existing agent partition.")
                    }
                }
                Section("What should LibreChat remember?") {
                    TextField("Short label", text: $key, axis: .vertical)
                        .disabled(!canEdit)
                    TextEditor(text: $value)
                        .frame(minHeight: 160)
                        .disabled(!canEdit)
                    HStack {
                        Spacer()
                        Text("\(value.utf16.count) of \(characterLimit) characters")
                            .font(.caption)
                            .foregroundStyle(value.utf16.count > characterLimit ? .red : .secondary)
                    }
                }
                if !canEdit {
                    Section {
                        Label("Your current role allows viewing this memory but not changing it.", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }
                if let failureMessage {
                    Section {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle(selection.memory == nil ? "New memory" : "Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                if canEdit {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            guard !isSaving else { return }
                            isSaving = true
                            failureMessage = nil
                            Task {
                                if let message = await save(key, value) {
                                    failureMessage = message
                                } else {
                                    dismiss()
                                }
                                isSaving = false
                            }
                        }
                        .disabled(!isValid || isSaving)
                        .accessibilityIdentifier("memory-save")
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var isValid: Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && key.utf16.count <= 1_000
            && !value.isEmpty && value.utf16.count <= characterLimit
    }
}
