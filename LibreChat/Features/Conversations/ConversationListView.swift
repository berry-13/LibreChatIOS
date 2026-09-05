import LibreChatDomain
import SwiftUI

struct ConversationListView: View {
    @Bindable var model: ConversationListModel
    @Bindable var searchModel: SearchModel
    let appModel: AppModel
    @Binding var selectedConversationID: ConversationID?
    let selectConversation: (ConversationID) -> Void
    let selectMessage: (MessageID, ConversationID) -> Void
    @State private var isShowingSettings = false
    @State private var isShowingProjects = false
    @State private var conversationToDelete: LibreChatDomain.Conversation?
    @State private var projectBeingRenamed: ChatProject?
    @State private var projectNameDraft = ""
    @State private var projectPendingDeletion: ChatProject?
    @State private var conversationToRename: LibreChatDomain.Conversation?
    @State private var conversationToDuplicate: LibreChatDomain.Conversation?
    @State private var renameTitle = ""
    /// Inline context-menu directories, preloaded so the submenus are filled
    /// the moment a long-press presents them (menus cannot load async content
    /// after presentation).
    @State private var menuDirectories = ConversationMenuDirectories()
    @State private var expandedProjectIDs: Set<ProjectID> = []
    /// Folders fetch their own chats from the project endpoint; the flat
    /// list sync cannot be relied on to carry project membership on every
    /// LibreChat version.
    @State private var loadingProjectChats: Set<ProjectID> = []

    private func loadProjectChats(for project: ChatProject) async {
        guard let repository = appModel.repository, !appModel.isOffline else { return }
        loadingProjectChats.insert(project.id)
        defer { loadingProjectChats.remove(project.id) }
        guard let page = try? await repository.projectConversations(
            projectID: project.id,
            limit: 25
        ) else { return }
        let known = Set(model.listedConversations.filter { $0.projectID == project.id }.map(\.id))
        for conversation in page.conversations where !known.contains(conversation.id) {
            withAnimation(.snappy(duration: 0.2)) {
                model.includeConversation(conversation)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            pinnedSearchBar
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)

            stateContent
        }
        .overlay(alignment: .bottomLeading) {
            NewChatFloatingButton {
                Task { await startNewChatFromList() }
            }
            .padding(.leading, 20)
            .padding(.bottom, 24)
        }
        .overlay(alignment: .bottomTrailing) {
            AccountFloatingButton(appModel: appModel) {
                isShowingSettings = true
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        // The panel carries no wordmark of its own; the list, search, and
        // floating controls fill it edge to edge. (The navigation bar is
        // never hidden via toolbar modifiers here — hiding it desyncs List
        // row hit-testing while the drawer animates.)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: searchModel.query) { _, _ in searchModel.queryChanged() }
        .onChange(of: searchModel.scope) { _, _ in searchModel.scopeChanged() }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                appModel: appModel,
                conversationListModel: model,
                openConversation: { conversation in
                    isShowingSettings = false
                    model.includeConversation(conversation)
                    selectConversation(conversation.id)
                },
                includeConversation: { conversation in
                    model.includeConversation(conversation)
                }
            )
        }
        .sheet(isPresented: $isShowingProjects) {
            if let repository = appModel.repository {
                NavigationStack {
                    ProjectsView(appModel: appModel, repository: repository) { conversation in
                        model.includeConversation(conversation)
                        isShowingProjects = false
                        selectConversation(conversation.id)
                    }
                }
            }
        }
        .alert("Rename chat", isPresented: Binding(
            get: { conversationToRename != nil },
            set: { if !$0 { conversationToRename = nil } }
        )) {
            TextField("Title", text: $renameTitle)
            Button("Cancel", role: .cancel) { conversationToRename = nil }
            Button("Save") {
                guard let conversation = conversationToRename else { return }
                conversationToRename = nil
                Task { await model.rename(conversation, title: renameTitle) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new title will be saved to this LibreChat server.")
        }
        .confirmationDialog(
            conversationToDelete?.id.isLocalDraft == true ? "Delete this draft?" : "Delete this conversation?",
            isPresented: Binding(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let conversation = conversationToDelete else { return }
                conversationToDelete = nil
                Task { await model.delete(conversation) }
            }
            Button("Cancel", role: .cancel) { conversationToDelete = nil }
        } message: {
            Text(
                conversationToDelete?.id.isLocalDraft == true
                    ? "This removes the unsent draft from this device."
                    : "This removes the conversation and its server history. This action cannot be undone."
            )
        }
        .confirmationDialog(
            "Duplicate this conversation?",
            isPresented: Binding(
                get: { conversationToDuplicate != nil },
                set: { if !$0 { conversationToDuplicate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Duplicate") {
                guard let conversation = conversationToDuplicate,
                      let profileID = appModel.selectedServer?.id,
                      let accountID = appModel.user?.id else { return }
                conversationToDuplicate = nil
                Task {
                    if let copy = await model.duplicate(
                        conversation,
                        profileID: profileID,
                        accountID: accountID
                    ) {
                        selectConversation(copy.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) { conversationToDuplicate = nil }
        } message: {
            Text("This creates one server-side copy with fresh message identities. If the connection drops after submission, refresh conversations before trying again.")
        }
        .alert("Rename project", isPresented: Binding(
            get: { projectBeingRenamed != nil },
            set: { if !$0 { projectBeingRenamed = nil } }
        )) {
            TextField("Name", text: $projectNameDraft)
            Button("Cancel", role: .cancel) { projectBeingRenamed = nil }
            Button("Save") {
                guard let project = projectBeingRenamed else { return }
                projectBeingRenamed = nil
                Task { await renameProject(project, to: projectNameDraft) }
            }
            .disabled(projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new name is saved to this LibreChat server.")
        }
        .confirmationDialog(
            "Delete \(projectPendingDeletion?.name ?? "project")?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete project", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                Task { await deleteProject(project) }
            }
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
        } message: {
            Text("Its conversations remain in LibreChat and become unassigned.")
        }
    }

    private func renameProject(_ project: ChatProject, to name: String) async {
        guard let repository = appModel.repository, !appModel.isOffline else { return }
        let originatingProfileID = appModel.selectedServer?.id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await repository.updateProject(
                id: project.id,
                input: UpdateChatProjectInput(name: trimmed)
            )
        } catch is CancellationError {
            return
        } catch {
            if error.isUnauthorized { await appModel.expireSession(for: originatingProfileID) }
        }
        await menuDirectories.load(
            repository: appModel.repository,
            isOffline: appModel.isOffline,
            canUseBookmarks: appModel.canUseBookmarks,
            onUnauthorized: appModel.expireSessionCallback()
        )
    }

    private func deleteProject(_ project: ChatProject) async {
        guard let repository = appModel.repository, !appModel.isOffline else { return }
        let originatingProfileID = appModel.selectedServer?.id
        do {
            _ = try await repository.deleteProject(id: project.id)
            expandedProjectIDs.remove(project.id)
        } catch is CancellationError {
            return
        } catch {
            if error.isUnauthorized { await appModel.expireSession(for: originatingProfileID) }
        }
        // The dropped project's chats are unassigned server-side; refresh
        // both the directory and the list so its rows and nested chats leave.
        await menuDirectories.load(
            repository: appModel.repository,
            isOffline: appModel.isOffline,
            canUseBookmarks: appModel.canUseBookmarks,
            onUnauthorized: appModel.expireSessionCallback()
        )
        await model.reload()
    }

    private struct ConversationSection: Identifiable {
        let title: String
        var conversations: [LibreChatDomain.Conversation]
        var id: String { title }
    }

    /// Pinned conversations feed the unified Pinned section the view renders
    /// alongside the pinned model/agent chips; dated buckets follow.
    private var pinnedConversations: [LibreChatDomain.Conversation] {
        model.listedConversations.filter { $0.pinned == true && $0.projectID == nil }
    }

    /// The catalog option matching a conversation's routing, so sidebar rows
    /// can show the agent's or spec's own avatar (web parity with `Convo`).
    /// Plain model rows fall back to their endpoint brand mark inside the row.
    private func sidebarIconOption(for conversation: LibreChatDomain.Conversation) -> ChatTargetOption? {
        guard let target = conversation.target else { return nil }
        return model.availableTargets.first { option in
            if let agentID = target.agentID, option.target.agentID == agentID { return true }
            if let spec = target.spec, !spec.isEmpty, option.target.spec == spec { return true }
            return false
        }
    }

    private var conversationSections: [ConversationSection] {
        var sections: [ConversationSection] = []
        for conversation in model.listedConversations
        where conversation.pinned != true && conversation.projectID == nil {
            let title = sidebarSectionTitle(for: conversation.updatedAt)
            if var last = sections.last, last.title == title {
                last.conversations.append(conversation)
                sections[sections.count - 1] = last
            } else {
                sections.append(ConversationSection(title: title, conversations: [conversation]))
            }
        }
        return sections
    }

    private func sidebarSectionTitle(for date: Date?) -> String {
        guard let date else { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? .max
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: date)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonListView(count: 10, rowHeight: 38, accessibilityLabel: "Loading conversations")
        case let .failed(message) where model.conversations.isEmpty:
            ContentUnavailableView {
                Label("Couldn’t load chats", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await model.reload() }
                }
                .buttonStyle(.borderedProminent)
            }
        default:
            conversationList
        }
    }

    /// Search pinned directly under the navigation header, always visible —
    /// not inside the collapsible system search placement.
    private var pinnedSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Search chats and messages", text: $searchModel.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("conversation-search-field")
            if !searchModel.query.isEmpty {
                Button {
                    searchModel.query = ""
                    searchModel.queryChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("conversation-search-clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Section headers get a solid backing so conversation titles scrolling
    /// beneath them never bleed through the label. The label sits slightly
    /// further left than conversation rows to build the visual hierarchy.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .background(Color(uiColor: .systemBackground))
            .listSectionSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }

    private var conversationList: some View {
        List {
            if appModel.isOffline {
                Label("Offline — saved conversations are read-only", systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else if model.isShowingCache {
                Label("Refreshing saved conversations…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if searchModel.isActive {
                searchResults
            } else if model.listedConversations.isEmpty {
                VStack(spacing: 14) {
                    Image("LogoMark")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "plus.bubble",
                        description: Text("Start a native chat with any model or agent available on this server.")
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                if !model.draftCanvases.isEmpty {
                    Section {
                        sectionHeader("Drafts")
                    }
                    .listSectionSeparator(.hidden)

                    Section {
                        ForEach(model.draftCanvases) { canvas in
                            draftCanvasRow(canvas)
                        }
                    }
                }

                projectsSection

                if !model.favoriteOptions.isEmpty || !pinnedConversations.isEmpty {
                    Section {
                        sectionHeader("Pinned")
                    }
                    .listSectionSeparator(.hidden)

                    Section {
                        if !model.favoriteOptions.isEmpty {
                            favoriteChipsRow
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 6, trailing: 12))
                                .listRowSeparator(.hidden)
                        }
                        ForEach(pinnedConversations) { conversation in
                            pinnedConversationRow(conversation)
                        }
                    }
                    }

                    ForEach(conversationSections) { section in
                        Section {
                            sectionHeader(section.title)
                        }
                        .listSectionSeparator(.hidden)

                        Section {
                            ForEach(section.conversations) { conversation in
                                datedConversationRow(conversation)
                            }
                        }
                    }
                }

                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .contentMargins(.bottom, 88, for: .scrollContent)
        .refreshable {
            await model.reload()
        }
        .task(id: menuDirectoryLoadKey) {
            await menuDirectories.load(
                repository: appModel.repository,
                isOffline: appModel.isOffline,
                canUseBookmarks: appModel.canUseBookmarks,
                onUnauthorized: appModel.expireSessionCallback()
            )
        }
        .overlay(alignment: .bottom) {
            if let message = model.paginationError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .adaptiveGlass(in: Capsule())
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        Picker("Search in", selection: $searchModel.scope) {
            ForEach(SearchModel.Scope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("search-scope-picker")
        .listRowBackground(Color.clear)
        .accessibilityHint("Choose whether to search conversation titles or message content.")

        if case .searching = searchModel.state {
            HStack(spacing: 10) {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }

        switch searchModel.state {
        case .idle:
            EmptyView()
        case let .failed(message) where visibleSearchResultCount == 0:
            ContentUnavailableView {
                Label("Search unavailable", systemImage: "magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { searchModel.retry() }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        case .loaded where visibleSearchResultCount == 0:
            ContentUnavailableView.search(text: searchModel.normalizedQuery)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        default:
            if searchModel.scope == .conversations {
                ForEach(searchModel.conversationResults) { conversation in
                    Button {
                        openSearchConversation(conversation)
                    } label: {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(searchModel.resultsAreStale)
                    .opacity(searchModel.resultsAreStale ? 0.55 : 1)
                    .task { await searchModel.loadMoreIfNeeded(after: conversation) }
                    .accessibilityIdentifier("search-conversation-\(conversation.id.rawValue)")
                }
                if searchModel.isLoadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(searchModel.messageResults) { result in
                    Button {
                        openMessageSearchResult(result)
                    } label: {
                        MessageSearchRow(result: result)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .disabled(searchModel.resultsAreStale)
                    .opacity(searchModel.resultsAreStale ? 0.55 : 1)
                    .accessibilityIdentifier("search-message-\(result.id.rawValue)")
                }
            }
        }

        if let message = searchModel.paginationError {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }

    private var visibleSearchResultCount: Int {
        switch searchModel.scope {
        case .conversations: searchModel.conversationResults.count
        case .messages: searchModel.messageResults.count
        }
    }

    @ViewBuilder
    private func conversationActions(
        for conversation: LibreChatDomain.Conversation
    ) -> some View {
        Button(conversation.pinned == true ? "Unpin" : "Pin", systemImage: "pin") {
            Task {
                await model.setPinned(conversation, pinned: conversation.pinned != true)
            }
        }
        .disabled(appModel.isOffline || conversation.id.isLocalDraft)

        Button("Rename", systemImage: "pencil") {
            renameTitle = conversation.title
            conversationToRename = conversation
        }
        .disabled(appModel.isOffline || conversation.id.isLocalDraft)

        Button("Duplicate", systemImage: "square.on.square") {
            conversationToDuplicate = conversation
        }
        .disabled(
            appModel.isOffline
                || conversation.id.isLocalDraft
                || model.isDuplicationLocked(conversation)
        )
        .accessibilityHint(
            model.isDuplicationLocked(conversation)
                ? "Refresh conversations before trying again because the previous copy result was uncertain."
                : "Creates a new server conversation with copied history."
        )

        // Each organizer is its own submenu so the action completes inline
        // instead of presenting an assignment dialog.
        let organizer = ConversationOrganizerCommands(
            conversation: conversation,
            directories: menuDirectories,
            repository: appModel.repository,
            listModel: model,
            isOffline: appModel.isOffline,
            canUseBookmarks: appModel.canUseBookmarks,
            onUnauthorized: appModel.expireSessionCallback()
        )
        organizer.moveToProjectSection
        organizer.bookmarksSection

        Button("Archive", systemImage: "archivebox") {
            Task { await model.archive(conversation) }
        }
        .disabled(appModel.isOffline || conversation.id.isLocalDraft)

        Divider()

        Button(role: .destructive) {
            conversationToDelete = conversation
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(appModel.isOffline && !conversation.id.isLocalDraft)
    }

    /// LibreChat-web's sidebar Projects section: collapsible folder rows
    /// with inline conversations, above pinned chats. New Project lives in
    /// the compact "+" beside the section label.
    @ViewBuilder
    private var projectsSection: some View {
        Section {
            projectsSectionHeader
        }
        .listSectionSeparator(.hidden)

        Section {
            ForEach(menuDirectories.projects) { project in
                projectRow(project)
            }
        }
    }

    private var projectsSectionHeader: some View {
        HStack {
            Text("Projects")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                isShowingProjects = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(.fill.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New project")
            .accessibilityHint("Opens the project browser to create and manage projects.")
            .accessibilityIdentifier("projects-new-project")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private func projectRow(_ project: ChatProject) -> some View {
        let isExpanded = expandedProjectIDs.contains(project.id)
        return Group {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                    if isExpanded {
                        expandedProjectIDs.remove(project.id)
                    } else {
                        expandedProjectIDs.insert(project.id)
                        Task { await loadProjectChats(for: project) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "folder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(project.name)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Open project", systemImage: "folder") {
                    isShowingProjects = true
                }
                Button("New chat in project", systemImage: "square.pencil") {
                    Task { await startNewChatInProject(project) }
                }
                Divider()
                Button("Rename project", systemImage: "pencil") {
                    projectNameDraft = project.name
                    projectBeingRenamed = project
                }
                .disabled(appModel.isOffline)
                Button("Delete project", systemImage: "trash", role: .destructive) {
                    projectPendingDeletion = project
                }
                .disabled(appModel.isOffline)
            }
            .accessibilityLabel(project.name)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows this project's recent conversations.")
            .accessibilityIdentifier("project-row-\(project.id.rawValue)")
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            // Collapsed or expanded, the folder row never shows a dangling
            // bottom separator — the expanded children carry their own hidden
            // separators, so the row's default one would render as a stray
            // line under collapsed projects only.
            .listRowSeparator(.hidden)

            if isExpanded {
                projectConversations(for: project)
            }
        }
    }

    @ViewBuilder
    private func projectConversations(for project: ChatProject) -> some View {
        let conversations = model.listedConversations.filter { $0.projectID == project.id }
        if conversations.isEmpty && loadingProjectChats.contains(project.id) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading chats…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.leading, 26)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else if conversations.isEmpty {
            Text("No chats in this project yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.leading, 26)
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        ForEach(conversations.prefix(8)) { conversation in
            Button {
                selectConversation(conversation.id)
            } label: {
                ConversationRow(conversation: conversation, targetOption: sidebarIconOption(for: conversation))
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        selectedConversationID == conversation.id
                            ? Color.primary.opacity(0.09)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("conversation-\(conversation.id.rawValue)")
            .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(
                selectedConversationID == conversation.id
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear
            )
        }
        if conversations.isEmpty {
            Text("No project chats yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
                .listRowInsets(EdgeInsets(top: 0, leading: 26, bottom: 0, trailing: 12))
        }
        if conversations.count > 8 {
            Button {
                isShowingProjects = true
            } label: {
                Text("Show all")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 26, bottom: 0, trailing: 12))
        }
    }

    /// A clearly-local row for a New Chat that carries unsent content (draft
    /// text or attachments). Selecting it restores the composer state; the
    /// row disappears and the real conversation takes its place the moment
    /// the server assigns an identity on first send.
    private func draftCanvasRow(_ canvas: LibreChatDomain.Conversation) -> some View {
        Button {
            selectConversation(canvas.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "pencil.line")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.fill.quaternary, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(canvas.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text("Draft — not sent yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                selectedConversationID == canvas.id
                    ? Color.primary.opacity(0.09)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("conversation-\(canvas.id.rawValue)")
        .accessibilityLabel("\(canvas.title), draft")
        .accessibilityHint("Restores this unsent draft.")
        .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button(role: .destructive) {
                Task { await model.discardDraftCanvas(canvas.id) }
            } label: {
                Label("Delete draft", systemImage: "trash")
            }
        }
    }

    private func startNewChatInProject(_ project: ChatProject) async {
        guard !appModel.isOffline else { return }
        await model.loadTargets()
        guard let option = model.targetCatalog?.effectiveDefaultOption
            ?? model.targetCatalog?.options.first else { return }
        guard let canvas = await model.createConversation(
            title: "New Chat",
            target: option,
            projectID: project.id
        ) else { return }
        selectConversation(canvas.id)
    }

    private func datedConversationRow(_ conversation: LibreChatDomain.Conversation) -> some View {
        Button {
            selectConversation(conversation.id)
        } label: {
            ConversationRow(conversation: conversation, targetOption: sidebarIconOption(for: conversation))
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    selectedConversationID == conversation.id
                        ? Color.primary.opacity(0.09)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("conversation-\(conversation.id.rawValue)")
        .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .task {
            await model.loadMoreIfNeeded(after: conversation)
        }
        .contextMenu {
            conversationActions(for: conversation)
        }
        .disabled(model.activeOperationID == conversation.id)
    }

    @ViewBuilder
    private func pinnedConversationRow(_ conversation: LibreChatDomain.Conversation) -> some View {
        Button {
            selectConversation(conversation.id)
        } label: {
            ConversationRow(conversation: conversation, targetOption: sidebarIconOption(for: conversation))
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    selectedConversationID == conversation.id
                        ? Color.primary.opacity(0.09)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("conversation-\(conversation.id.rawValue)")
        .listRowInsets(EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            conversationActions(for: conversation)
        }
        .disabled(model.activeOperationID == conversation.id)
    }

    /// LibreChat-style pinned targets above the chat list: one chip per
    /// pinned model, agent, or spec; tap starts a chat, long-press unpins.
    private var favoriteChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.favoriteOptions) { option in
                    Button {
                        Task { await startChat(fromList: option) }
                    } label: {
                        HStack(spacing: 6) {
                            EndpointBrandIcon(
                                endpoint: option.target.endpoint,
                                model: option.target.model,
                                iconURL: option.iconURL,
                                iconEndpoint: option.iconEndpoint,
                                size: 20
                            )
                            Text(option.label)
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.fill.quaternary, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Unpin", systemImage: "pin.slash") {
                            Task { await model.toggleFavorite(option) }
                        }
                    }
                    .accessibilityLabel("Pinned \(option.label)")
                    .accessibilityHint("Starts a new chat with this model or agent.")
                    .accessibilityIdentifier("favorite-chip-\(option.id)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Starts a fresh chat from the list using the recent-target default.
    private func startNewChatFromList() async {
        guard !appModel.isOffline else { return }
        await model.loadTargets()
        guard let option = model.targetCatalog?.effectiveDefaultOption
            ?? model.targetCatalog?.options.first else { return }
        await startChat(fromList: option)
    }

    private func startChat(fromList option: ChatTargetOption) async {
        guard let canvas = await model.createConversation(title: "New Chat", target: option) else { return }
        selectConversation(canvas.id)
    }

    /// Menus cannot load content after presentation; the directories reload
    /// whenever the session, connectivity, or bookmark capability changes.
    private var menuDirectoryLoadKey: String {
        "\(appModel.repository == nil)-\(appModel.isOffline)-\(appModel.canUseBookmarks)"
    }

    private func openSearchConversation(_ conversation: LibreChatDomain.Conversation) {
        model.includeConversation(conversation)
        selectConversation(conversation.id)
    }

    private func openMessageSearchResult(_ result: MessageSearchResult) {
        let conversation = LibreChatDomain.Conversation(
            id: result.message.conversationID,
            title: result.conversationTitle,
            model: result.model,
            updatedAt: result.message.createdAt,
            target: result.endpoint.map { ConversationTarget(endpoint: $0, model: result.model) }
        )
        model.includeConversation(conversation)
        selectMessage(result.message.id, conversation.id)
    }

}

private struct PresetCreationSelection: Identifiable {
    let id = UUID()
    let target: ChatTargetOption
}

struct PresetCreationView: View {
    let target: ChatTargetOption
    let save: @MainActor (String, String?) async throws -> PresetCreationOutcome
    let saved: @MainActor (ChatPreset) -> Void
    let refreshAfterUnknown: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = PresetCreationDraft()
    @State private var isSaving = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?
    @State private var announcementState = AccessibilityAnnouncementState()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.title)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("preset-create-title")
                    LabeledContent("Model or agent", value: target.label)
                } header: {
                    Text("Preset")
                } footer: {
                    Text("Only this reviewed model or agent is saved. Files, tools, sampling controls, and hidden provider settings are not copied.")
                }

                Section {
                    TextEditor(text: $draft.promptPrefix)
                        .frame(minHeight: 150)
                        .accessibilityIdentifier("preset-create-instructions")
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Optional instructions are stored privately on this LibreChat server and applied when you start a chat from the preset.")
                }

                if (!draft.title.isEmpty || !draft.promptPrefix.isEmpty),
                   let validationMessage = draft.validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("preset-create-error")
                        if isOutcomeUnknown {
                            Button("Close and refresh saved presets") {
                                refreshAfterUnknown()
                                dismiss()
                            }
                            .accessibilityIdentifier("preset-create-refresh-after-unknown")
                        }
                    }
                }

                if isSaving {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Saving preset…")
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Save preset")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("preset-create-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isOutcomeUnknown ? "Close" : "Cancel") {
                        if isOutcomeUnknown { refreshAfterUnknown() }
                        dismiss()
                    }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .disabled(isSaving || isOutcomeUnknown || !draft.canSave)
                        .accessibilityIdentifier("preset-create-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving || isOutcomeUnknown)
        .onChange(of: errorMessage) { _, value in
            if let announcement = announcementState.announcement(for: value) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    private func submit() {
        guard !isSaving, !isOutcomeUnknown, draft.canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let outcome = try await save(draft.normalizedTitle, draft.normalizedPromptPrefix)
                isSaving = false
                switch outcome {
                case let .confirmed(preset):
                    saved(preset)
                    dismiss()
                case .outcomeUnknown:
                    isOutcomeUnknown = true
                    errorMessage = "LibreChat may have saved this preset. Refresh the preset list before trying again."
                }
            } catch {
                isSaving = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

struct PresetCreationDraft: Equatable {
    static let maximumTitleUTF16Length = 200
    static let maximumPromptPrefixUTF16Length = 32_000

    var title = ""
    var promptPrefix = ""

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedPromptPrefix: String? {
        promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : promptPrefix
    }

    var canSave: Bool { validationMessage == nil }

    var validationMessage: String? {
        if normalizedTitle.isEmpty {
            return "Enter a preset name."
        }
        if normalizedTitle.utf16.count > Self.maximumTitleUTF16Length {
            return "Preset names can contain at most 200 characters."
        }
        if normalizedTitle.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Preset names cannot contain line breaks or control characters."
        }
        if let normalizedPromptPrefix,
           normalizedPromptPrefix.utf16.count > Self.maximumPromptPrefixUTF16Length {
            return "Instructions are too long for a native preset."
        }
        if let normalizedPromptPrefix,
           normalizedPromptPrefix.unicodeScalars.contains(where: { $0.value == 0 }) {
            return "Instructions contain an unsupported control character."
        }
        return nil
    }
}

private struct PresetPickerView: View {
    @Bindable var model: ConversationListModel
    let selectedPresetID: PresetID?
    let selected: (ChatPreset) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        Group {
            if matchingPresets.isEmpty {
                ContentUnavailableView.search(text: normalizedQuery)
            } else {
                List(matchingPresets) { preset in
                    Button {
                        selected(preset)
                        dismiss()
                    } label: {
                        PresetPickerRow(
                            preset: preset,
                            resolution: model.presetResolution(preset),
                            isSelected: preset.id == selectedPresetID
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("preset-option-\(preset.id.rawValue)")
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Choose preset")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search presets")
        .accessibilityIdentifier("preset-picker")
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingPresets: [ChatPreset] {
        let terms = normalizedQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        guard !terms.isEmpty else { return model.availablePresets }
        return model.availablePresets.filter { preset in
            let searchable = [
                preset.title,
                preset.modelLabel,
                preset.target?.model,
                preset.target?.endpoint,
                preset.target?.spec
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy(searchable.contains)
        }
    }
}

private struct PresetPickerRow: View {
    let preset: ChatPreset
    let resolution: ConversationListModel.PresetApplicationResolution
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: preset.isDefault ? "star.circle.fill" : "slider.horizontal.3")
                .font(.title3)
                .foregroundStyle(preset.isDefault ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
            if resolution.blockingMessage != nil {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects this preset for review before creating a new chat.")
    }

    private var subtitle: String {
        let target = preset.modelLabel
            ?? preset.target?.model
            ?? preset.target?.spec
            ?? preset.target?.endpoint
            ?? "Missing target"
        return resolution.blockingMessage == nil ? target : "Review required · \(target)"
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isSelected { values.append("Selected") }
        if preset.isDefault { values.append("Default preset") }
        if let blockingMessage = resolution.blockingMessage { values.append(blockingMessage) }
        return values.joined(separator: ", ")
    }
}

/// A stable, presentation-only index over an already-authorized target
/// catalog. It never changes server order or manufactures target choices.
struct ChatTargetPickerIndex: Equatable {
    enum Category: Int, CaseIterable, Identifiable, Sendable {
        case configured
        case agents
        case models

        var id: Self { self }

        var title: String {
            switch self {
            case .configured: "Configured"
            case .agents: "Agents"
            case .models: "Models"
            }
        }

        var systemImage: String {
            switch self {
            case .configured: "slider.horizontal.3"
            case .agents: "person.crop.circle"
            case .models: "sparkles"
            }
        }
    }

    struct Group: Equatable, Identifiable, Sendable {
        let category: Category
        let options: [ChatTargetOption]

        var id: Category { category }
    }

    let groups: [Group]

    init(options: [ChatTargetOption]) {
        var buckets: [Category: [ChatTargetOption]] = [:]
        for option in options {
            buckets[Self.category(for: option), default: []].append(option)
        }
        groups = Category.allCases.compactMap { category in
            guard let options = buckets[category], !options.isEmpty else { return nil }
            return Group(category: category, options: options)
        }
    }

    func matching(_ query: String) -> [Group] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map {
                String($0).folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
            }
        guard !terms.isEmpty else { return groups }

        return groups.compactMap { group in
            let matches = group.options.filter { option in
                let searchable = [
                    option.label,
                    option.subtitle,
                    option.target.model,
                    option.target.endpoint,
                    option.target.spec
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return terms.allSatisfy(searchable.contains)
            }
            guard !matches.isEmpty else { return nil }
            return Group(category: group.category, options: matches)
        }
    }

    private static func category(for option: ChatTargetOption) -> Category {
        if option.id.hasPrefix("spec:") || option.target.spec != nil { return .configured }
        if option.target.agentID != nil { return .agents }
        return .models
    }
}

struct ChatTargetPickerView: View {
    private let index: ChatTargetPickerIndex
    @Binding var selectedTargetID: ChatTargetOption.ID?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var visibleGroups: [ChatTargetPickerIndex.Group] { index.matching(query) }

    init(
        options: [ChatTargetOption],
        selectedTargetID: Binding<ChatTargetOption.ID?>
    ) {
        index = ChatTargetPickerIndex(options: options)
        _selectedTargetID = selectedTargetID
    }

    var body: some View {
        Group {
            if visibleGroups.isEmpty {
                ContentUnavailableView.search(text: normalizedQuery)
            } else {
                List {
                    ForEach(visibleGroups) { group in
                        Section {
                            ForEach(group.options) { option in
                                Button {
                                    selectedTargetID = option.id
                                    dismiss()
                                } label: {
                                    ChatTargetOptionRow(
                                        option: option,
                                        category: group.category,
                                        isSelected: option.id == selectedTargetID
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("target-option-\(option.id)")
                            }
                        } header: {
                            Label(group.category.title, systemImage: group.category.systemImage)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Choose model or agent")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search models and agents")
        .accessibilityIdentifier("chat-target-picker")
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ChatTargetOptionRow: View {
    let option: ChatTargetOption
    let category: ChatTargetPickerIndex.Category
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // LibreChat-web's model rows draw an icon only for agents and
            // configured specs (the entity's own avatar or image); plain
            // endpoint models stay text-only.
            if showsIcon {
                EndpointBrandIcon(
                    endpoint: option.target.endpoint,
                    model: option.target.model,
                    iconURL: option.iconURL,
                    iconEndpoint: option.iconEndpoint
                )
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = option.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Starts a new chat with this target.")
    }

    private var categoryGlyph: some View {
        Image(systemName: category.systemImage)
            .frame(width: 28, height: 28)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// Web parity (`EndpointModelItem`): only rows that resolve to an
    /// entity image or an endpoint glyph for agents/specs show an icon.
    private var showsIcon: Bool {
        option.target.agentID != nil
            || option.target.endpoint == "agents"
            || option.id.hasPrefix("spec:")
            || option.target.spec != nil
    }
}

/// One selectable provider in the first page of the two-page target dropdown:
/// a configured spec, the Agents library, or a bare endpoint with its models.
struct TargetProviderGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let iconURL: URL?
    let iconEndpoint: String?
    let systemImage: String
    let options: [ChatTargetOption]

    var category: ChatTargetPickerIndex.Category {
        if id == "agents" { return .agents }
        if id.hasPrefix("spec:") { return .configured }
        return .models
    }

    static func build(from options: [ChatTargetOption]) -> [TargetProviderGroup] {
        var groups: [TargetProviderGroup] = []
        var agentOptions: [ChatTargetOption] = []
        var endpointBuckets: [String: [ChatTargetOption]] = [:]
        var endpointOrder: [String] = []
        // Web parity: the Agents group sits exactly where the first agent
        // option appears in the catalog's order, not pinned to the end.
        var agentGroupIndex: Int?

        for option in options {
            if option.target.agentID != nil || option.target.endpoint == "agents" {
                if agentOptions.isEmpty { agentGroupIndex = groups.count }
                agentOptions.append(option)
            } else if option.id.hasPrefix("spec:") || option.target.spec != nil {
                groups.append(TargetProviderGroup(
                    id: option.id,
                    name: option.label,
                    iconURL: option.iconURL,
                    iconEndpoint: option.iconEndpoint,
                    systemImage: "slider.horizontal.3",
                    options: [option]
                ))
            } else {
                let endpoint = option.target.endpoint
                if endpointBuckets[endpoint] == nil {
                    endpointOrder.append(endpoint)
                }
                endpointBuckets[endpoint, default: []].append(option)
            }
        }

        if !agentOptions.isEmpty, let index = agentGroupIndex {
            // The provider row shows the agents quill glyph; each agent's
            // own avatar appears on the provider's model page.
            groups.insert(
                TargetProviderGroup(
                    id: "agents",
                    name: "My Agents",
                    iconURL: nil,
                    iconEndpoint: nil,
                    systemImage: "person.crop.circle",
                    options: agentOptions
                ),
                at: index
            )
        }
        for endpoint in endpointOrder {
            guard let endpointOptions = endpointBuckets[endpoint],
                  let first = endpointOptions.first else { continue }
            groups.append(TargetProviderGroup(
                id: "endpoint:\(endpoint)",
                name: endpointDisplayName(for: first),
                iconURL: first.iconURL,
                iconEndpoint: first.iconEndpoint,
                systemImage: endpointSymbol(for: endpoint),
                options: endpointOptions
            ))
        }
        return groups
    }

    /// LibreChat-web labels endpoint menu rows through its `alternateName`
    /// table before falling back to the configured display label.
    private static let alternateNames: [String: String] = [
        "openai": "OpenAI",
        "azureopenai": "Azure OpenAI",
        "google": "Google",
        "anthropic": "Anthropic",
        "bedrock": "AWS Bedrock",
        "agents": "My Agents",
        "ollama": "Ollama",
        "deepseek": "DeepSeek",
        "moonshot": "Moonshot",
        "xai": "xAI",
        "helicone": "Helicone",
    ]

    /// Endpoint model labels are "endpointLabel · model"; the provider takes
    /// the endpoint portion.
    private static func endpointDisplayName(for option: ChatTargetOption) -> String {
        if let alternate = alternateNames[option.target.endpoint.lowercased()] {
            return alternate
        }
        if let range = option.label.range(of: " · ") {
            return String(option.label[..<range.lowerBound])
        }
        return option.target.endpoint
    }

    private static func endpointSymbol(for endpoint: String) -> String {
        switch endpoint.lowercased() {
        case "openai": "sparkles"
        case "anthropic": "brain"
        case "google": "circle.hexagongrid"
        default: "server.rack"
        }
    }
}

/// LibreChat's selector resets most non-modular target changes to a new
/// conversation. The native client does not yet implement modular multi-chat,
/// so this sheet makes that boundary explicit and never rewrites the routing
/// of an existing history in place. The dropdown has two pages: providers
/// first, then a smooth in-place push to the selected provider's models.



/// The known-endpoint logo library, mirroring LibreChat-web's
/// `UnknownIcon`: custom providers whose logo ships with the web client
/// (ollama, deepseek, groq, …) render that bundled mark, keyed by the
/// endpoint name — plus the xAI and Moonshot component marks. The web ships
/// these in its own bundle, so the native client bundles them too.
enum KnownEndpointIconLibrary {
    static let imagesByEndpoint: [String: String] = [
        "anyscale": "EndpointAnyscale",
        "apipie": "EndpointApipie",
        "cohere": "EndpointCohere",
        "deepseek": "EndpointDeepseek",
        "fireworks": "EndpointFireworks",
        "groq": "EndpointGroq",
        "helicone": "EndpointHelicone",
        "huggingface": "EndpointHuggingface",
        "mistral": "EndpointMistral",
        "mlx": "EndpointMlx",
        "ollama": "EndpointOllama",
        "openrouter": "EndpointOpenrouter",
        "perplexity": "EndpointPerplexity",
        "qwen": "EndpointQwen",
        "shuttleai": "EndpointShuttleai",
        "together.ai": "EndpointTogether",
        "unify": "EndpointUnify",
        "xai": "EndpointXai",
        "moonshot": "EndpointMoonshot",
    ]

    static func imageName(for endpoint: String?) -> String? {
        endpoint.flatMap { imagesByEndpoint[$0.lowercased()] }
    }
}

/// LibreChat's endpoint branding, mirrored from the web client: white marks
/// on brand chips (OpenAI's chip color follows the model generation), the
/// agents quill and assistants sparkles, a bundled logo for the known
/// custom providers, and the generic custom-endpoint bot glyph last. An
/// explicit image — the agent avatar, a spec's iconURL, or a custom
/// endpoint's configured logo — always wins, falling back to the mark if
/// the image fails to load.
/// Authenticated fetcher for server-hosted entity images, injected through
/// the environment. Servers with secure image links reject plain image
/// requests without the session's refresh cookie, so views can never load
/// these with a bare AsyncImage — the fetcher rides the profile's transport.
struct ServerImageFetchAction {
    var fetch: @MainActor (URL) async -> Data?

    @MainActor
    func callAsFunction(_ url: URL) async -> Data? { await fetch(url) }
}

private struct ServerImageFetchKey: EnvironmentKey {
    static let defaultValue = ServerImageFetchAction { _ in nil }
}

extension EnvironmentValues {
    var fetchServerImage: ServerImageFetchAction {
        get { self[ServerImageFetchKey.self] }
        set { self[ServerImageFetchKey.self] = newValue }
    }
}

/// Shared memory cache for fetched entity images, keyed by absolute URL.
enum ServerEntityImageStore {
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    static func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    static func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }

    /// Authenticated imagery is session-scoped: every account or profile
    /// transition clears the cache so one session can never render another
    /// session's avatars or icons.
    static func removeAllCachedImages() {
        cache.removeAllObjects()
    }

    /// Entity images render at avatar/icon sizes; decoding a highly
    /// compressed source at full resolution can consume hundreds of
    /// megabytes, so the cached image is pixel-limited.
    static func downsampledImage(from data: Data, maxPixel: CGFloat = 512) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// LibreChat's endpoint branding, mirrored from the web client: white marks
/// on brand chips (OpenAI's chip color follows the model generation), the
/// agents quill and assistants sparkles, a bundled logo for the known
/// custom providers, and the generic custom-endpoint bot glyph last. An
/// explicit image — the agent avatar, a spec's iconURL, or a custom
/// endpoint's configured logo — always wins, falling back to the mark if
/// the image fails to load. Images load through the environment's
/// authenticated fetcher (AsyncImage cannot carry the session cookie).
struct EndpointBrandIcon: View {
    let endpoint: String?
    let model: String?
    var iconURL: URL?
    /// A bare icon value naming a built-in endpoint glyph
    /// (librechat.yaml `iconURL: openAI`), which overrides `endpoint` for
    /// the mark, like the web's `getIconKey`.
    var iconEndpoint: String? = nil
    var size: CGFloat = 26

    @Environment(\.fetchServerImage) private var fetchServerImage
    @State private var loadedImage: UIImage?
    @State private var loadFailed = false

    var body: some View {
        if let iconURL {
            imageState(for: iconURL)
        } else {
            mark
        }
    }

    @ViewBuilder
    private func imageState(for url: URL) -> some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                mark
                    .opacity(loadFailed ? 1 : 0.35)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            if let cached = ServerEntityImageStore.cachedImage(for: url) {
                loadedImage = cached
                loadFailed = false
                return
            }
            loadedImage = nil
            loadFailed = false
            guard let data = await fetchServerImage(url),
                  let decoded = ServerEntityImageStore.downsampledImage(from: data) else {
                loadFailed = true
                return
            }
            ServerEntityImageStore.store(decoded, for: url)
            loadedImage = decoded
        }
    }

    /// The bundled mark: the known-endpoint logo for custom providers,
    /// else the built-in endpoint glyph. Always bounded to `size` — the
    /// raw logo image has no intrinsic size a row or pill could rely on.
    /// Bundled logos sit on a strongly-rounded tile (app-icon silhouette)
    /// so every provider surface reads as one rounded icon family: circle
    /// server images, rounded-tile bundled marks.
    @ViewBuilder
    private var mark: some View {
        Group {
            if let asset = KnownEndpointIconLibrary.imageName(for: glyphKey) {
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.1)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            } else {
                glyph
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var glyph: some View {
        switch glyphKey {
        case "openai":
            brandChip(imageName: "BrandOpenAI", background: openAIChipColor)
        case "azureopenai", "azure":
            Image("BrandAzure")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.92, height: size * 0.92)
                .foregroundStyle(.primary)
        case "anthropic":
            Image("BrandAnthropic")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.85, height: size * 0.85)
                .foregroundStyle(.primary)
        case "bedrock":
            Image("BrandBedrock")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.85, height: size * 0.85)
                .foregroundStyle(.primary)
        case "google":
            Image("BrandGoogleG")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.85, height: size * 0.85)
                .foregroundStyle(.primary)
        case "agents":
            FeatherShape()
                .fill(.primary)
                .frame(width: size * 0.85, height: size * 0.85)
                .accessibilityHidden(true)
        case "assistants", "azureassistants":
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.72, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        default:
            // The web client's generic custom-endpoint mark (lucide's bot).
            BotGlyph()
                .frame(width: size * 0.85, height: size * 0.85)
                .accessibilityHidden(true)
        }
    }

    private func brandChip(
        imageName: String,
        background: Color
    ) -> some View {
        Image(imageName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .padding(size * 0.19)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(background)
            }
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }

    /// LibreChat's `getOpenAIColor`: black for o*/gpt-5+, purple for gpt-4,
    /// green otherwise.
    private var openAIChipColor: Color {
        let lowered = model?.lowercased() ?? ""
        if lowered.range(of: #"\bo\d\b"#, options: .regularExpression) != nil
            || lowered.range(of: #"\bgpt-[5-9](\.\d+)?\b"#, options: .regularExpression) != nil {
            return .black
        }
        if lowered.contains("gpt-4") { return Color(red: 0.671, green: 0.408, blue: 1.0) }
        return Color(red: 0.098, green: 0.765, blue: 0.49)
    }

    private var glyphKey: String {
        (iconEndpoint ?? endpoint ?? "").lowercased()
    }
}

/// LibreChat-web's generic custom-endpoint mark: lucide's stroke-drawn
/// "bot" (antenna, rounded head, side arms, two eyes) on a 24-unit grid.
struct BotGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 24
            let scaled = BotGlyphPath()
                .path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
                .applying(CGAffineTransform(scaleX: unit, y: unit))
            context.stroke(
                scaled,
                with: .color(.primary),
                style: StrokeStyle(lineWidth: 2 * unit, lineCap: .round, lineJoin: .round)
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private struct BotGlyphPath: Shape {
        func path(in rect: CGRect) -> Path {
            let unit = min(rect.width, rect.height) / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
            }
            var path = Path()
            // Antenna: up from the head, then left.
            path.move(to: point(12, 8))
            path.addLine(to: point(12, 4))
            path.addLine(to: point(8, 4))
            // Side arms.
            path.move(to: point(2, 14))
            path.addLine(to: point(4, 14))
            path.move(to: point(20, 14))
            path.addLine(to: point(22, 14))
            // Eyes.
            path.move(to: point(9, 13))
            path.addLine(to: point(9, 15))
            path.move(to: point(15, 13))
            path.addLine(to: point(15, 15))
            path.addPath(Path(roundedRect: CGRect(
                origin: point(4, 8),
                size: CGSize(width: 16 * unit, height: 12 * unit)
            ), cornerRadius: 2 * unit))
            return path
        }
    }
}

/// LibreChat-web's default agents glyph is lucide's quill "Feather". The
/// lucide original is stroke-drawn (unsupported by the asset compiler), so
/// this is its filled silhouette.
struct FeatherShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY
        var path = Path()
        // Quill body: from the stem base sweeping up to the rounded tip.
        path.move(to: CGPoint(x: x + 0.20 * w, y: y + 0.82 * h))
        path.addCurve(
            to: CGPoint(x: x + 0.22 * w, y: y + 0.40 * h),
            control1: CGPoint(x: x + 0.26 * w, y: y + 0.72 * h),
            control2: CGPoint(x: x + 0.13 * w, y: y + 0.55 * h)
        )
        path.addCurve(
            to: CGPoint(x: x + 0.70 * w, y: y + 0.06 * h),
            control1: CGPoint(x: x + 0.32 * w, y: y + 0.22 * h),
            control2: CGPoint(x: x + 0.50 * w, y: y + 0.06 * h)
        )
        path.addArc(
            center: CGPoint(x: x + 0.76 * w, y: y + 0.12 * h),
            radius: 0.085 * min(w, h),
            startAngle: .degrees(-75),
            endAngle: .degrees(80),
            clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: x + 0.40 * w, y: y + 0.60 * h),
            control1: CGPoint(x: x + 0.92 * w, y: y + 0.32 * h),
            control2: CGPoint(x: x + 0.62 * w, y: y + 0.48 * h)
        )
        // Two barb notches along the lower edge, as in the feather original.
        path.addLine(to: CGPoint(x: x + 0.48 * w, y: y + 0.56 * h))
        path.addLine(to: CGPoint(x: x + 0.38 * w, y: y + 0.60 * h))
        path.addLine(to: CGPoint(x: x + 0.36 * w, y: y + 0.48 * h))
        path.addLine(to: CGPoint(x: x + 0.30 * w, y: y + 0.54 * h))
        path.addLine(to: CGPoint(x: x + 0.28 * w, y: y + 0.42 * h))
        path.addCurve(
            to: CGPoint(x: x + 0.20 * w, y: y + 0.82 * h),
            control1: CGPoint(x: x + 0.26 * w, y: y + 0.50 * h),
            control2: CGPoint(x: x + 0.28 * w, y: y + 0.68 * h)
        )
        path.closeSubpath()
        // Bare stem continuing past the body to the lower-left corner.
        path.move(to: CGPoint(x: x + 0.20 * w, y: y + 0.80 * h))
        path.addLine(to: CGPoint(x: x + 0.07 * w, y: y + 0.93 * h))
        path.addLine(to: CGPoint(x: x + 0.12 * w, y: y + 0.99 * h))
        path.addLine(to: CGPoint(x: x + 0.25 * w, y: y + 0.87 * h))
        path.closeSubpath()
        return path
    }
}

/// First page row: provider icon, name, and model count.
struct ProviderRow: View {
    let provider: TargetProviderGroup

    var body: some View {
        HStack(spacing: 12) {
            EndpointBrandIcon(
                endpoint: providerEndpointKey,
                model: provider.options.first?.target.model,
                iconURL: provider.iconURL,
                iconEndpoint: provider.iconEndpoint,
                size: 28
            )

            Text(provider.name)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(provider.name)
    }

    private var providerEndpointKey: String? {
        if provider.id == "agents" { return "agents" }
        if provider.id.hasPrefix("endpoint:") {
            return String(provider.id.dropFirst("endpoint:".count))
        }
        // A model spec without its own image falls back to its endpoint's
        // brand mark, matching LibreChat-web's spec icon chain.
        return provider.options.first?.target.endpoint
    }
}

/// Second page: the selected provider's models only, with a back affordance
/// supplied by the enclosing NavigationStack push.
private struct ProviderModelList: View {
    let provider: TargetProviderGroup
    let currentOptionID: ChatTargetOption.ID?
    let isCreating: Bool
    let start: @MainActor (ChatTargetOption) -> Void

    var body: some View {
        List {
            Section {
                ForEach(provider.options) { option in
                    Button {
                        start(option)
                    } label: {
                        ChatTargetOptionRow(
                            option: option,
                            category: provider.category,
                            isSelected: option.id == currentOptionID
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isCreating)
                    .accessibilityIdentifier("target-option-\(option.id)")
                }
            } footer: {
                Text("Choosing a model or agent starts a new chat. This conversation stays unchanged.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("provider-model-list")
    }
}

struct ArchivedConversationsView: View {
    @State private var model: ArchivedConversationListModel
    @State private var conversationToDelete: LibreChatDomain.Conversation?
    let onUnarchived: @MainActor (LibreChatDomain.Conversation) -> Void
    let onOpen: @MainActor (LibreChatDomain.Conversation) -> Void

    init(
        repository: any ConversationListFeatureRepository,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onUnarchived: @escaping @MainActor (LibreChatDomain.Conversation) -> Void,
        onOpen: @escaping @MainActor (LibreChatDomain.Conversation) -> Void
    ) {
        _model = State(initialValue: ArchivedConversationListModel(
            repository: repository,
            onUnauthorized: onUnauthorized
        ))
        self.onUnarchived = onUnarchived
        self.onOpen = onOpen
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .idle, .loading:
                    SkeletonListView(count: 9, accessibilityLabel: "Loading archived chats")
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Archived chats unavailable", systemImage: "archivebox")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await model.reload() } }
                    }
                case .loaded where model.conversations.isEmpty:
                    ContentUnavailableView(
                        "No archived chats",
                        systemImage: "archivebox",
                        description: Text("Chats you archive will appear here.")
                    )
                case .loaded:
                    List(model.conversations) { conversation in
                        Button {
                            onOpen(conversation)
                        } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the archived conversation for reading.")
                        .accessibilityIdentifier("archived-conversation-\(conversation.id.rawValue)")
                        .task { await model.loadMoreIfNeeded(after: conversation) }
                            .swipeActions(edge: .leading) {
                                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                                    Task {
                                        guard let restored = await model.unarchive(conversation) else { return }
                                        onUnarchived(restored)
                                    }
                                }
                                .tint(.blue)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    conversationToDelete = conversation
                                }
                            }
                            .disabled(model.operationID == conversation.id)
                    }
                    .refreshable { await model.reload() }
                }
            }
            .navigationTitle("Archived chats")
            .navigationBarTitleDisplayMode(.inline)
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
            .task { await model.loadIfNeeded() }
            .confirmationDialog(
                "Delete this archived conversation?",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let conversation = conversationToDelete else { return }
                    conversationToDelete = nil
                    Task { await model.delete(conversation) }
                }
                Button("Cancel", role: .cancel) { conversationToDelete = nil }
            } message: {
                Text("This removes the conversation and its server history. This action cannot be undone.")
            }
        }
    }
}

/// LibreChat-web's sidebar conversation row (`Convo`): the conversation's
/// own endpoint/entity icon at 18pt, then a quiet single-line title with a
/// pin glyph; date context comes from the surrounding section headers.
private struct ConversationRow: View {
    let conversation: LibreChatDomain.Conversation
    /// Resolved catalog option for the row's routing, when the list can
    /// supply one — it carries the agent/spec's own avatar or image.
    var targetOption: ChatTargetOption?

    var body: some View {
        HStack(spacing: 8) {
            EndpointBrandIcon(
                endpoint: targetOption?.target.endpoint ?? conversation.target?.endpoint,
                model: targetOption?.target.model ?? conversation.model,
                iconURL: targetOption?.iconURL,
                iconEndpoint: targetOption?.iconEndpoint,
                size: 18
            )
            .accessibilityHidden(true)

            Text(conversation.title)
                .font(.callout)
                .lineLimit(1)
            if conversation.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityValue(conversation.pinned == true ? "Pinned" : "")
        .contentShape(Rectangle())
    }
}

private struct MessageSearchRow: View {
    let result: MessageSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.conversationTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let createdAt = result.message.createdAt {
                    Text(createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(result.message.author.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(result.message.plainText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(result.conversationTitle). \(result.message.author.displayName). \(result.message.plainText)"
        )
        .accessibilityHint("Opens this conversation and focuses the matched message.")
    }
}

/// Preloaded project/bookmark directories shared by every surface that shows
/// conversation command menus (the list's context menu and the chat screen's
/// actions menu). SwiftUI menus cannot fill content asynchronously after
/// presentation, so each owner preloads via `.task` once a session exists.
@MainActor
@Observable
final class ConversationMenuDirectories {
    private(set) var projects: [ChatProject] = []
    private(set) var tags: [ConversationTag] = []

    func load(
        repository: LibreChatRepository?,
        isOffline: Bool,
        canUseBookmarks: Bool,
        onUnauthorized: @MainActor () async -> Void
    ) async {
        guard let repository, !isOffline else { return }
        async let projectsPage = repository.projects(options: ChatProjectListOptions(
            cursor: nil,
            limit: 100,
            sortBy: .name,
            sortDirection: .ascending,
            search: nil
        ))
        async let loadedTags = canUseBookmarks
            ? repository.conversationTags().sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending
            }
            : []

        do {
            let page = try await projectsPage
            projects = page.projects.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch is CancellationError {
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            projects = []
        }
        do {
            tags = try await loadedTags
        } catch is CancellationError {
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            tags = []
        }
    }
}

/// The organizer submenus ("Move to project", "Bookmarks") and their inline
/// mutations, shared verbatim between the conversation list's context menu
/// and an existing chat's actions menu.
@MainActor
struct ConversationOrganizerCommands {
    let conversation: LibreChatDomain.Conversation
    let directories: ConversationMenuDirectories
    let repository: LibreChatRepository?
    let listModel: ConversationListModel
    let isOffline: Bool
    let canUseBookmarks: Bool
    let onUnauthorized: @MainActor () async -> Void

    @ViewBuilder
    var moveToProjectSection: some View {
        Menu {
            Button {
                move(toProject: nil)
            } label: {
                Label("No project", systemImage: "tray")
            }
            ForEach(directories.projects) { project in
                Button {
                    move(toProject: project.id)
                } label: {
                    Label(
                        project.name,
                        systemImage: conversation.projectID == project.id ? "checkmark" : "folder"
                    )
                }
            }
            if directories.projects.isEmpty {
                Text("No projects yet")
            }
        } label: {
            Label("Move to project", systemImage: "folder")
        }
        .disabled(isOffline || conversation.id.isLocalDraft)
    }

    @ViewBuilder
    var bookmarksSection: some View {
        if canUseBookmarks {
            Menu {
                ForEach(directories.tags) { tag in
                    Button {
                        toggleBookmark(tag.tag)
                    } label: {
                        Label(
                            tag.tag,
                            systemImage: (conversation.tags ?? []).contains(tag.tag)
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                }
                if directories.tags.isEmpty {
                    Text("No bookmarks yet")
                }
            } label: {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .disabled(isOffline || conversation.id.isLocalDraft)
        }
    }

    private func move(toProject projectID: ProjectID?) {
        guard let repository else { return }
        Task {
            do {
                let assignment = try await repository.assignConversation(
                    id: conversation.id,
                    to: projectID
                )
                listModel.includeConversation(assignment.conversation)
            } catch is CancellationError {
            } catch {
                if error.isUnauthorized { await onUnauthorized() }
                listModel.reportOperationError(error.userFacingMessage)
            }
        }
    }

    private func toggleBookmark(_ name: String) {
        guard let repository else { return }
        var updatedNames = conversation.tags ?? []
        if let index = updatedNames.firstIndex(of: name) {
            updatedNames.remove(at: index)
        } else {
            updatedNames.append(name)
        }
        Task {
            do {
                let finalNames = try await repository.replaceConversationTags(
                    conversationID: conversation.id,
                    tags: updatedNames
                )
                var updated = conversation
                updated.tags = finalNames
                listModel.includeConversation(updated)
            } catch is CancellationError {
            } catch {
                if error.isUnauthorized { await onUnauthorized() }
                listModel.reportOperationError(error.userFacingMessage)
            }
        }
    }
}


/// Liquid-glass floating account button, anchored bottom-trailing on the
/// conversation list. Shows the account avatar when the server provides one
/// (monogram fallback) and opens Settings directly — the quick-destinations
/// dropdown (Agents, Projects, Files, Archived, Bookmarks) now lives under
/// Settings, alongside the session actions.
struct AccountFloatingButton: View {
    let appModel: AppModel
    let action: @MainActor () -> Void

    @Environment(\.fetchServerImage) private var fetchServerImage
    @State private var loadedAvatar: UIImage?

    var body: some View {
        Button(action: action) {
            accountIcon
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .adaptiveInteractiveGlass(in: Circle())
        .accessibilityLabel("Account and settings")
        .accessibilityHint("Opens Settings.")
        .accessibilityIdentifier("account-menu-button")
        .task(id: appModel.user?.avatarURL) {
            guard let url = appModel.user?.avatarURL else {
                loadedAvatar = nil
                return
            }
            if let cached = ServerEntityImageStore.cachedImage(for: url) {
                loadedAvatar = cached
                return
            }
            guard let data = await fetchServerImage(url),
                  let decoded = ServerEntityImageStore.downsampledImage(from: data) else { return }
            ServerEntityImageStore.store(decoded, for: url)
            loadedAvatar = decoded
        }
    }

    @ViewBuilder
    private var accountIcon: some View {
        if let loadedAvatar {
            Image(uiImage: loadedAvatar)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
        } else {
            monogram
        }
    }

    /// LibreChat-web's default avatar: dicebear initials on its fixed
    /// 14-color palette, seeded by the account name.
    private var monogram: some View {
        InitialsAvatar(seed: appModel.user?.displayName ?? "", size: 30)
    }
}

/// Larger floating new-chat pill with icon and label, anchored
/// bottom-leading on the conversation list. Both the fill and the content
/// invert with the theme tokens (primary / systemBackground), so the pill
/// stays fully legible in light and dark mode; a quiet press-scale gives the
/// same tactile feedback as the composer controls.
struct NewChatFloatingButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                Text("New chat")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Color.primary, in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(PressingScaleButtonStyle())
        .accessibilityLabel("New chat")
        .accessibilityHint("Starts a fresh chat with the most recently used model or agent.")
        .accessibilityIdentifier("new-chat-button")
    }
}

/// Quiet press feedback shared by floating controls: a small scale dip
/// instead of SwiftUI's default opacity flash, disabled under Reduce Motion.
struct PressingScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: configuration.isPressed)
    }
}
