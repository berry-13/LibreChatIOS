import LibreChatDomain
import SwiftUI

struct ProjectsView: View {
    let appModel: AppModel
    let repository: LibreChatRepository
    let openConversation: (LibreChatDomain.Conversation) -> Void

    @State private var model: ProjectListModel
    @State private var isShowingEditor = false
    @State private var editingProject: ChatProject?
    @State private var projectPendingDeletion: ChatProject?

    init(
        appModel: AppModel,
        repository: LibreChatRepository,
        openConversation: @escaping (LibreChatDomain.Conversation) -> Void
    ) {
        self.appModel = appModel
        self.repository = repository
        self.openConversation = openConversation
        _model = State(initialValue: ProjectListModel(
            repository: repository,
            isOffline: { appModel.isOffline },
            onUnauthorized: appModel.expireSessionCallback()
        ))
    }

    var body: some View {
        // No NavigationStack of its own: ProjectsView is presented inside a
        // host stack (the Settings hub, or the sheet wrapper at its call
        // site). A nested stack broke value-based navigation here — tapping
        // a project appended to the OUTER path where no destination was
        // registered, so the section collapsed instead of pushing the
        // project page.
        projectList
            .navigationTitle("Projects")
            .searchable(text: $model.searchQuery, prompt: "Search projects")
            .onChange(of: model.searchQuery) { _, _ in model.searchChanged() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { sortMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New project", systemImage: "plus") {
                        editingProject = nil
                        isShowingEditor = true
                    }
                    .disabled(!model.canMutate)
                }
            }
            .navigationDestination(for: ChatProject.self) { project in
                ProjectDetailView(
                    project: project,
                    appModel: appModel,
                    repository: repository,
                    openConversation: openConversation
                )
            }
        .task { await model.loadIfNeeded() }
        .sheet(isPresented: $isShowingEditor) {
            ProjectEditorSheet(model: model, project: editingProject)
        }
        .confirmationDialog(
            "Delete \(projectPendingDeletion?.name ?? "project")?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            presenting: projectPendingDeletion
        ) { project in
            Button("Delete project", role: .destructive) {
                Task {
                    _ = await model.delete(id: project.id)
                    projectPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
        } message: { project in
            Text("Its conversations remain in LibreChat and become unassigned.")
        }
    }

    private var projectList: some View {
        List {
            if model.isRefreshing {
                Label("Refreshing projects…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch model.state {
            case .idle where model.projects.isEmpty,
                 .loading where model.projects.isEmpty:
                SkeletonListView(count: 7, horizontalPadding: 0, accessibilityLabel: "Loading projects")
                    .listRowSeparator(.hidden)
            case .offline:
                ContentUnavailableView(
                    "Projects need a connection",
                    systemImage: "wifi.slash",
                    description: Text("Saved chats remain available from the conversation list.")
                )
                .listRowSeparator(.hidden)
            case .unauthorized:
                ContentUnavailableView(
                    "Session expired",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Sign in again to browse projects.")
                )
                .listRowSeparator(.hidden)
            case let .failed(message) where model.projects.isEmpty:
                ContentUnavailableView {
                    Label("Couldn’t load projects", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.retry() }
                }
                .listRowSeparator(.hidden)
            default:
                if model.projects.isEmpty {
                    ContentUnavailableView(
                        model.normalizedSearchQuery.isEmpty ? "No projects yet" : "No matching projects",
                        systemImage: "folder",
                        description: Text(
                            model.normalizedSearchQuery.isEmpty
                                ? "Create a project to organize related conversations."
                                : "Try a different project name."
                        )
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(model.projects) { project in
                        NavigationLink(value: project) {
                            ProjectRow(project: project)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                                )
                        }
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowBackground(Color.clear)
                        .task { await model.loadMoreIfNeeded(after: project) }
                        .swipeActions {
                            Button("Delete", role: .destructive) { projectPendingDeletion = project }
                                .disabled(!model.canMutate)
                            Button("Edit") {
                                editingProject = project
                                isShowingEditor = true
                            }
                            .tint(.blue)
                            .disabled(!model.canMutate)
                        }
                        .contextMenu {
                            Button("Edit project", systemImage: "pencil") {
                                editingProject = project
                                isShowingEditor = true
                            }
                            .disabled(!model.canMutate)
                            Button("Delete project", systemImage: "trash", role: .destructive) {
                                projectPendingDeletion = project
                            }
                            .disabled(!model.canMutate)
                        }
                    }
                    if model.isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowSeparator(.hidden)
                    }
                }
            }

            if let error = model.operationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .refreshable { await model.reload() }
    }

    private var sortMenu: some View {
        Menu("Sort projects", systemImage: "arrow.up.arrow.down") {
            Picker("Sort by", selection: $model.sortBy) {
                Text("Recent activity").tag(ChatProjectSortBy.lastConversationAt)
                Text("Name").tag(ChatProjectSortBy.name)
                Text("Date created").tag(ChatProjectSortBy.createdAt)
            }
            Picker("Direction", selection: $model.sortDirection) {
                Text("Descending").tag(ChatProjectSortDirection.descending)
                Text("Ascending").tag(ChatProjectSortDirection.ascending)
            }
        }
        .onChange(of: model.sortBy) { _, _ in model.sortChanged() }
        .onChange(of: model.sortDirection) { _, _ in model.sortChanged() }
    }
}

private struct ProjectRow: View {
    let project: ChatProject

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let description = project.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(project.conversationCount) \(project.conversationCount == 1 ? "chat" : "chats")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(project.name), \(project.conversationCount) \(project.conversationCount == 1 ? "chat" : "chats")"
        )
    }
}

private struct ProjectDetailView: View {
    let appModel: AppModel
    let repository: LibreChatRepository
    let openConversation: (LibreChatDomain.Conversation) -> Void
    @State private var model: ProjectDetailModel
    @State private var isCreatingConversation = false
    @State private var isRenamingProject = false
    @State private var projectNameDraft = ""
    @State private var isConfirmingDeletion = false
    @State private var manageError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        project: ChatProject,
        appModel: AppModel,
        repository: LibreChatRepository,
        openConversation: @escaping (LibreChatDomain.Conversation) -> Void
    ) {
        self.appModel = appModel
        self.repository = repository
        self.openConversation = openConversation
        _model = State(initialValue: ProjectDetailModel(
            project: project,
            projectRepository: repository,
            conversationRepository: repository,
            isOffline: { appModel.isOffline },
            onUnauthorized: appModel.expireSessionCallback()
        ))
    }

    var body: some View {
        List {
            if let description = model.project.description, !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
            }
            switch model.state {
            case .idle where model.conversations.isEmpty,
                 .loading where model.conversations.isEmpty:
                SkeletonListView(count: 7, horizontalPadding: 0, accessibilityLabel: "Loading conversations")
                    .listRowSeparator(.hidden)
            case .offline:
                ContentUnavailableView(
                    "Project unavailable offline",
                    systemImage: "wifi.slash",
                    description: Text("Open saved chats from the main conversation list.")
                )
                .listRowSeparator(.hidden)
            case .unauthorized:
                ContentUnavailableView(
                    "Session expired",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Sign in again to open this project.")
                )
                .listRowSeparator(.hidden)
            case let .failed(message) where model.conversations.isEmpty:
                ContentUnavailableView {
                    Label("Couldn’t load this project", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.retry() }
                }
                .listRowSeparator(.hidden)
            default:
                if model.conversations.isEmpty {
                    ContentUnavailableView(
                        "No conversations",
                        systemImage: "text.bubble",
                        description: Text("Start a chat here or move an existing chat into this project.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(model.conversations) { conversation in
                        Button {
                            openConversation(conversation)
                        } label: {
                            ConversationProjectRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .task { await model.loadMoreIfNeeded(after: conversation) }
                    }
                    if model.isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowSeparator(.hidden)
                    }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let manageError {
                Label(manageError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(model.project.name)
        .refreshable { await model.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", systemImage: "square.and.pencil") {
                    isCreatingConversation = true
                }
                .disabled(!model.canMutate)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Manage project", systemImage: "ellipsis.circle") {
                    Button("Rename project", systemImage: "pencil") {
                        projectNameDraft = model.project.name
                        isRenamingProject = true
                    }
                    .disabled(!model.canMutate)
                    Button("Delete project", systemImage: "trash", role: .destructive) {
                        isConfirmingDeletion = true
                    }
                    .disabled(!model.canMutate)
                }
                .accessibilityIdentifier("project-manage-menu")
            }
        }
        .task { await model.loadIfNeeded() }
        .sheet(isPresented: $isCreatingConversation) {
            ProjectNewChatSheet(model: model) { conversation in
                isCreatingConversation = false
                openConversation(conversation)
            }
        }
        .alert("Rename project", isPresented: $isRenamingProject) {
            TextField("Name", text: $projectNameDraft)
            Button("Cancel", role: .cancel) { isRenamingProject = false }
            Button("Save") {
                Task {
                    let trimmed = projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    do {
                        _ = try await repository.updateProject(
                            id: model.project.id,
                            input: UpdateChatProjectInput(name: trimmed)
                        )
                        await model.reload()
                    } catch {
                        await handleManageError(error)
                    }
                }
            }
            .disabled(projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new name is saved to this LibreChat server.")
        }
        .confirmationDialog(
            "Delete \(model.project.name)?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete project", role: .destructive) {
                Task {
                    do {
                        _ = try await repository.deleteProject(id: model.project.id)
                        dismissDetail()
                    } catch {
                        await handleManageError(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { isConfirmingDeletion = false }
        } message: {
            Text("Its conversations remain in LibreChat and become unassigned.")
        }
    }

    private func handleManageError(_ error: Error) async {
        guard !(error is CancellationError) else { return }
        if error.isUnauthorized {
            await appModel.expireSession()
        } else {
            manageError = error.userFacingMessage
        }
    }

    private func dismissDetail() {
        // The deleted project's detail page pops back to the list, which
        // refreshes itself on reappear through its own load pipeline.
        dismiss()
    }
}

private struct ConversationProjectRow: View {
    let conversation: LibreChatDomain.Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            if let model = conversation.model, !model.isEmpty {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this conversation.")
    }
}

private struct ProjectEditorSheet: View {
    @Bindable var model: ProjectListModel
    let project: ChatProject?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String

    init(model: ProjectListModel, project: ChatProject?) {
        self.model = model
        self.project = project
        _name = State(initialValue: project?.name ?? "")
        _description = State(initialValue: project?.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...8)
                if let error = model.operationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(project == nil ? "New project" : "Edit project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let saved = if let project {
                                await model.update(id: project.id, name: name, description: description)
                            } else {
                                await model.create(name: name, description: description)
                            }
                            if saved != nil { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ProjectNewChatSheet: View {
    @Bindable var model: ProjectDetailModel
    let created: (LibreChatDomain.Conversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selectedTargetID: ChatTargetOption.ID?

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    TextField("Title", text: $title)
                    if model.isLoadingTargets {
                        SkeletonListView(
                            count: 4,
                            rowHeight: 40,
                            horizontalPadding: 0,
                            accessibilityLabel: "Loading models and agents"
                        )
                    } else if let targetError = model.targetError {
                        ContentUnavailableView {
                            Label("Models unavailable", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(targetError)
                        } actions: {
                            Button("Try again") { Task { await model.loadTargets(forceRefresh: true) } }
                        }
                    } else {
                        NavigationLink {
                            ChatTargetPickerView(
                                options: model.availableTargets,
                                selectedTargetID: $selectedTargetID
                            )
                        } label: {
                            LabeledContent("Model or agent") {
                                Text(selectedTarget?.label ?? "Choose…")
                                    .foregroundStyle(selectedTarget == nil ? Color.secondary : Color.primary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("project-new-chat-target")
                    }
                }
            }
            .navigationTitle("New project chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let target = model.availableTargets.first(where: { $0.id == selectedTargetID }) else { return }
                        created(model.createLocalDraft(title: title, target: target))
                    }
                    .disabled(selectedTargetID == nil)
                }
            }
            .task {
                await model.loadTargets(forceRefresh: true)
                selectedTargetID = selectedTargetID ?? model.availableTargets.first?.id
            }
        }
    }

    private var selectedTarget: ChatTargetOption? {
        model.availableTargets.first { $0.id == selectedTargetID }
    }
}

struct ProjectAssignmentSheet: View {
    let conversation: LibreChatDomain.Conversation
    let appModel: AppModel
    let repository: LibreChatRepository
    let assigned: (ConversationProjectAssignment) -> Void

    @State private var model: ProjectListModel
    @Environment(\.dismiss) private var dismiss

    init(
        conversation: LibreChatDomain.Conversation,
        appModel: AppModel,
        repository: LibreChatRepository,
        assigned: @escaping (ConversationProjectAssignment) -> Void
    ) {
        self.conversation = conversation
        self.appModel = appModel
        self.repository = repository
        self.assigned = assigned
        _model = State(initialValue: ProjectListModel(
            repository: repository,
            isOffline: { appModel.isOffline },
            onUnauthorized: appModel.expireSessionCallback()
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                assignmentButton(name: "No project", projectID: nil, systemImage: "tray")
                ForEach(model.projects) { project in
                    assignmentButton(name: project.name, projectID: project.id, systemImage: "folder")
                        .task { await model.loadMoreIfNeeded(after: project) }
                }
                if model.isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let error = model.operationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Move to project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await model.loadIfNeeded() }
        }
    }

    private func assignmentButton(
        name: String,
        projectID: ProjectID?,
        systemImage: String
    ) -> some View {
        Button {
            Task {
                if let result = await model.assignConversation(conversation, to: projectID) {
                    assigned(result)
                    dismiss()
                }
            }
        } label: {
            Label(name, systemImage: systemImage)
            if conversation.projectID == projectID {
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .disabled(model.isAssigning || !model.canMutate)
    }
}
