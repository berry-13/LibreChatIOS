import LibreChatDomain
import SwiftUI

struct PromptLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PromptLibraryModel
    @State private var selectedGroup: PromptTemplateGroup?
    private let userName: String?
    private let insert: @MainActor (String) -> Void

    init(
        repository: any PromptRepository,
        userName: String?,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        insert: @escaping @MainActor (String) -> Void
    ) {
        self.userName = userName
        self.insert = insert
        _model = State(initialValue: PromptLibraryModel(
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
                    ProgressView("Loading prompts…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .offline:
                    ContentUnavailableView(
                        "Prompts need a connection",
                        systemImage: "wifi.slash",
                        description: Text("Prompt content is loaded live and is not stored for offline browsing.")
                    )
                case .unauthorized:
                    ContentUnavailableView(
                        "Session expired",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Sign in again to browse prompts.")
                    )
                case let .failed(message) where model.groups.isEmpty:
                    ContentUnavailableView {
                        Label("Prompts unavailable", systemImage: "text.quote")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.reload() } }
                    }
                default:
                    promptList
                }
            }
            .navigationTitle("Prompt library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: "Search prompts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: model.query) { await model.searchAfterDebounce() }
            .sheet(item: $selectedGroup) { group in
                PromptInsertionSheet(group: group, userName: userName) { text in
                    insert(text)
                    Task { await model.recordUsage(for: group.id) }
                }
            }
            .accessibilityIdentifier("prompt-library")
        }
    }

    private var promptList: some View {
        List {
            if model.groups.isEmpty {
                ContentUnavailableView(
                    model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "No prompts available"
                        : "No matching prompts",
                    systemImage: "text.quote",
                    description: Text(
                        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Your current role has no viewable production prompts."
                            : "Try another name."
                    )
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(model.groups) { group in
                    Button {
                        selectedGroup = group
                    } label: {
                        PromptGroupRow(group: group)
                    }
                    .buttonStyle(.plain)
                    .disabled(!group.isInsertable)
                    .accessibilityHint(
                        group.isInsertable
                            ? "Reviews this prompt before inserting it into your draft."
                            : "This group has no production prompt available."
                    )
                    .task { await model.loadMoreIfNeeded(after: group) }
                }
            }

            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
            } else if let message = model.paginationError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                    Button("Retry more results") {
                        guard let group = model.groups.last else { return }
                        Task { await model.loadMoreIfNeeded(after: group) }
                    }
                }
            }
        }
        .refreshable { await model.reload() }
    }
}

private struct PromptGroupRow: View {
    let group: PromptTemplateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if group.isPublic {
                    Label("Public", systemImage: "globe")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Public prompt")
                }
            }
            if let summary = group.summary ?? group.productionText {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if let category = group.category {
                    Text(category)
                }
                if let authorName = group.authorName {
                    Text("By \(authorName)")
                }
                if !group.isInsertable {
                    Text("No production version")
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

private struct PromptInsertionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: PromptTemplateGroup
    let userName: String?
    let insert: @MainActor (String) -> Void
    @State private var values: [PromptVariableID: String] = [:]
    @State private var failureMessage: String?
    private let variables: [PromptVariable]
    private let templateIsValid: Bool

    init(
        group: PromptTemplateGroup,
        userName: String?,
        insert: @escaping @MainActor (String) -> Void
    ) {
        self.group = group
        self.userName = userName
        self.insert = insert
        if let text = group.productionText,
           let parsed = try? PromptTemplateExpander.variables(in: text) {
            variables = parsed
            templateIsValid = true
        } else {
            variables = []
            templateIsValid = false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    Text(group.productionText ?? "")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !variables.isEmpty {
                    Section {
                        ForEach(variables) { variable in
                            VStack(alignment: .leading, spacing: 6) {
                                TextField(variable.name, text: binding(for: variable.id), axis: .vertical)
                                if !variable.options.isEmpty {
                                    Menu("Choose a suggestion") {
                                        ForEach(variable.options, id: \.self) { option in
                                            Button(option) { values[variable.id] = option }
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                            .accessibilityElement(children: .contain)
                        }
                    } header: {
                        Text("Prompt fields")
                    } footer: {
                        Text("These values are inserted locally. Review the completed draft before sending.")
                    }
                }

                if !templateIsValid {
                    Section {
                        Label("This production prompt cannot be expanded safely.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } else if let failureMessage {
                    Section {
                        Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") { insertPrompt() }
                        .disabled(!canInsert)
                        .accessibilityHint("Adds the completed prompt to your editable draft without sending it.")
                        .accessibilityIdentifier("prompt-insert")
                }
            }
            .accessibilityIdentifier("prompt-insertion")
        }
    }

    private var canInsert: Bool {
        templateIsValid && variables.allSatisfy {
            values[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    private func binding(for id: PromptVariableID) -> Binding<String> {
        Binding(
            get: { values[id] ?? "" },
            set: { values[id] = $0 }
        )
    }

    private func insertPrompt() {
        guard let text = group.productionText else { return }
        do {
            let expanded = try PromptTemplateExpander.expand(
                text,
                values: values,
                userName: userName
            )
            insert(expanded)
            dismiss()
        } catch {
            failureMessage = error.userFacingMessage
        }
    }
}
