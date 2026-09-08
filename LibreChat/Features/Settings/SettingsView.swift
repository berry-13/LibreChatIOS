import LibreChatDomain
import LibreChatProtocol
import PhotosUI
import SwiftUI
import UIKit

struct SettingsView: View {
    let appModel: AppModel
    /// The signed-in conversation list, when Settings is presented from the
    /// sidebar surface. Powers the Agents page's ability to start chats.
    var conversationListModel: ConversationListModel? = nil
    /// Opens a conversation in the main surface (used by the Agents,
    /// Projects, Archived, and Bookmarks pages) and closes Settings.
    var openConversation: ((LibreChatDomain.Conversation) -> Void)? = nil
    /// Pulls a conversation into the sidebar list without navigating to it
    /// (used when an archived chat is unarchived from Settings).
    var includeConversation: ((LibreChatDomain.Conversation) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if appModel.user != nil {
                    Section("Account") {
                        NavigationLink {
                            AccountProfileView(appModel: appModel)
                        } label: {
                            Label("Profile and account", systemImage: "person.crop.circle")
                        }
                        .accessibilityHint(
                            "Review the current LibreChat account, change its profile image, or delete it when the server permits."
                        )
                        NavigationLink {
                            SecuritySettingsPage(appModel: appModel)
                        } label: {
                            Label("Sign-in and security", systemImage: "lock.shield")
                        }
                        .accessibilityHint(
                            "Two-factor authentication controls for this account."
                        )
                    }
                }

                chatsAndContentSection

                aiFeaturesSection

                // Privacy and device controls before rarely-used plumbing.
                Section("Privacy & device") {
                    Toggle("Require device authentication", isOn: appLockBinding)
                    Text("Face ID, Touch ID, or the device passcode protects local app access. Server authentication remains separate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        DataStorageSettingsPage(appModel: appModel)
                    } label: {
                        Label("Local data", systemImage: "externaldrive")
                    }
                    .accessibilityHint(
                        "Inspect local cache health and delete saved data for the active server account."
                    )
                }

                Section("Server") {
                    NavigationLink {
                        ServersSettingsPage(appModel: appModel, dismissing: { dismiss() })
                    } label: {
                        Label("Change server", systemImage: "server.rack")
                    }
                    .accessibilityHint(
                        "Review saved LibreChat servers, add another one, or switch the active connection."
                    )
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await appModel.signOut() }
                    }
                    .disabled(appModel.phase != .signedIn)
                    .accessibilityIdentifier("settings-sign-out")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onChange(of: appModel.phase) { _, phase in
            if phase != .signedIn { dismiss() }
        }
    }

    /// The conversation-library destinations that used to live in the
    /// sidebar's account dropdown, gathered under Settings.
    @ViewBuilder
    private var chatsAndContentSection: some View {
        if let repository = appModel.repository {
            Section("Chats and content") {
                if appModel.canBrowseAgents, let listModel = conversationListModel {
                    NavigationLink {
                        AgentsView(
                            appModel: appModel,
                            repository: repository,
                            conversationListModel: listModel,
                            openConversation: { conversation in
                                openConversation?(conversation)
                                dismiss()
                            }
                        )
                    } label: {
                        Label("Agents", systemImage: "person.crop.circle")
                    }
                    .accessibilityHint("Browse saved agents and start chats with them.")
                }

                NavigationLink {
                    ProjectsView(appModel: appModel, repository: repository) { conversation in
                        openConversation?(conversation)
                        dismiss()
                    }
                } label: {
                    Label("Projects", systemImage: "folder")
                }
                .disabled(appModel.isOffline || !appModel.canUseProjects)

                NavigationLink {
                    FileLibraryView(appModel: appModel, repository: repository)
                } label: {
                    Label("Files", systemImage: "doc.on.doc")
                }
                .disabled(appModel.isOffline)
                .accessibilityHint("Opens the live file catalog for this LibreChat account.")

                NavigationLink {
                    ArchivedConversationsView(
                        repository: repository,
                        onUnauthorized: appModel.expireSessionCallback(),
                        onUnarchived: { conversation in
                            includeConversation?(conversation)
                        },
                        onOpen: { conversation in
                            openConversation?(conversation)
                            dismiss()
                        }
                    )
                } label: {
                    Label("Archived chats", systemImage: "archivebox")
                }
                .disabled(appModel.isOffline)

                if appModel.canUseBookmarks {
                    NavigationLink {
                        BookmarksView(
                            repository: repository,
                            isOffline: { appModel.isOffline },
                            onUnauthorized: appModel.expireSessionCallback(),
                            onSelectConversation: { conversation in
                                openConversation?(conversation)
                                dismiss()
                            }
                        )
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark")
                    }
                }

            }
        }
    }

    /// Model/tool configuration: credentials, Skills, MCP, Memory — grouped
    /// by what they configure rather than scattered as "chat features".
    @ViewBuilder
    private var aiFeaturesSection: some View {
        if appModel.authenticatedServerPolicyUnavailable {
            Section {
                Label(
                    "Account features are hidden until LibreChat's authenticated policy can be verified.",
                    systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Button("Retry server feature check", systemImage: "arrow.clockwise") {
                    Task { await appModel.refreshAuthenticatedServerPolicy() }
                }
                .disabled(appModel.isRefreshingServerPolicy)
                .accessibilityHint(
                    "Reloads account-specific feature and permission settings without signing out."
                )
                .accessibilityIdentifier("retry-authenticated-server-policy")
            }
        }

        if let repository = appModel.repository {
            Section("Models & AI") {
                NavigationLink {
                    UserKeysView(appModel: appModel, repository: repository)
                } label: {
                    Label("Provider credentials", systemImage: "key.horizontal")
                }
                .accessibilityHint(
                    "Manage account-scoped provider credentials requested by this LibreChat server."
                )

                if appModel.selectedServer?.capabilities?.supportsMemories == true {
                    if appModel.canBrowseMemories,
                       let permissions = appModel.memoryPermissions {
                        NavigationLink {
                            MemoriesView(
                                appModel: appModel,
                                repository: repository,
                                permissions: permissions
                            )
                        } label: {
                            Label("Memory", systemImage: "brain.head.profile")
                        }
                        .accessibilityHint("Review and manage facts LibreChat may use in future responses.")
                    } else {
                        Label("Memory is unavailable for this account", systemImage: "brain.head.profile")
                            .foregroundStyle(.secondary)
                    }
                }

                if appModel.selectedServer?.capabilities?.supportsMCP == true {
                    if appModel.canBrowseMCPConnections {
                        NavigationLink {
                            MCPConnectionsView(appModel: appModel, repository: repository)
                        } label: {
                            Label("MCP connections", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .accessibilityHint("Shows live connection and authorization status reported by LibreChat.")
                    } else {
                        Label(
                            "MCP connections are unavailable for this account",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if appModel.selectedServer?.capabilities?.supportsSkills == true {
                    if appModel.canUseSkills {
                        NavigationLink {
                            SkillsManagementView(appModel: appModel, repository: repository)
                        } label: {
                            Label("Account Skills", systemImage: "wand.and.stars")
                        }
                        .accessibilityHint(
                            "Review live Skills and change which ones are active for this LibreChat account."
                        )
                        .accessibilityIdentifier("settings-skills-management")
                    } else {
                        Label("Skills are unavailable for this account", systemImage: "wand.and.stars")
                            .foregroundStyle(.secondary)
                    }
                }

            }
        }
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { appModel.isAppLockEnabled },
            set: { newValue in Task { await appModel.setAppLockEnabled(newValue) } }
        )
    }
}

/// Two-factor authentication controls, moved behind the settings hub.
private struct SecuritySettingsPage: View {
    let appModel: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var twoFactorSetup: TwoFactorSetup?
    @State private var verificationCode = ""
    @State private var accountProof = ""
    @State private var usesBackupCode = false
    @State private var backupCodes: [String] = []
    @State private var isRegeneratingBackupCodes = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if appModel.selectedServer?.capabilities?.supportsTwoFactorAuth != false {
                twoFactorSection
            }
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .navigationTitle("Sign-in and security")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Backup codes are deliberately scoped to this presentation only.
            backupCodes.removeAll(keepingCapacity: false)
            twoFactorSetup = nil
            accountProof = ""
            verificationCode = ""
        }
    }

    private var twoFactorSection: some View {
        Section("Two-factor authentication") {
            if let setup = twoFactorSetup {
                if let secret = setup.secret {
                    LabeledContent("Setup key", value: secret).textSelection(.enabled)
                }
                TextField("Authenticator code", text: $verificationCode)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                Button("Verify and enable") {
                    perform {
                        try await appModel.confirmTwoFactorSetup(code: verificationCode)
                        twoFactorSetup = nil
                        verificationCode = ""
                    }
                }
                .disabled(verificationCode.isEmpty)
            } else {
                // An absent optional twoFactorEnabled means unknown: only
                // "Set up authenticator" is offered, never the mutually
                // contradictory regenerate/disable controls.
                Button("Set up authenticator") {
                    perform {
                        let setup = try await appModel.beginTwoFactorSetup()
                        twoFactorSetup = setup
                        backupCodes = setup.backupCodes
                    }
                }
            }

            // Regeneration and disabling are only meaningful when the server
            // has explicitly confirmed 2FA is enabled.
            if appModel.user?.twoFactorEnabled == true {
                Picker("Verification method", selection: $usesBackupCode) {
                    Text("Authenticator").tag(false)
                    Text("Backup code").tag(true)
                }
                .pickerStyle(.segmented)

                SecureField(usesBackupCode ? "Backup code" : "Authenticator code", text: $accountProof)
                    .textContentType(.oneTimeCode)
                    .keyboardType(usesBackupCode ? .asciiCapable : .numberPad)

                Button("Regenerate backup codes") {
                    guard !isRegeneratingBackupCodes else { return }
                    isRegeneratingBackupCodes = true
                    Task {
                        // The flag must span the actual network request, not
                        // just the scheduling of it.
                        defer { isRegeneratingBackupCodes = false }
                        errorMessage = nil
                        do {
                            backupCodes = try await appModel.regenerateBackupCodes(proof: selectedProof)
                        } catch {
                            errorMessage = error.userFacingMessage
                        }
                    }
                }
                .disabled(accountProof.isEmpty || isRegeneratingBackupCodes)
                .onChange(of: scenePhase) { _, phase in
                    // The setup key and backup codes are plain-text secrets:
                    // clear them when the scene backgrounds so the app-switcher
                    // snapshot and resume never expose them.
                    if phase != .active {
                        twoFactorSetup = nil
                        backupCodes = []
                        accountProof = ""
                    }
                }
                Button("Disable two-factor authentication", role: .destructive) {
                    perform {
                        try await appModel.disableTwoFactor(proof: selectedProof)
                        accountProof = ""
                    }
                }
                .disabled(accountProof.isEmpty)
            }

            if !backupCodes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save these codes now. They will disappear when you leave this page.").font(.caption)
                    ForEach(backupCodes, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                }
                .textSelection(.enabled)
                .accessibilityLabel("New backup codes")
            }
        }
    }

    private var selectedProof: TwoFactorProof {
        usesBackupCode ? .backupCode(accountProof) : .authenticatorCode(accountProof)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        Task {
            do { try await operation() }
            catch { errorMessage = error.userFacingMessage }
        }
    }
}

/// Saved-server management behind the settings hub: switch, add, remove.
private struct ServersSettingsPage: View {
    let appModel: AppModel
    let dismissing: @MainActor () -> Void

    var body: some View {
        Form {
            if let profile = appModel.selectedServer {
                Section("Active server") {
                    LabeledContent("Server", value: profile.displayName)
                    LabeledContent("Address", value: profile.baseURL.absoluteString)
                    if let user = appModel.user { LabeledContent("Account", value: user.displayName) }
                }
            }

            Section("Saved servers") {
                ForEach(appModel.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.displayName)
                            Text(profile.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id == appModel.selectedServer?.id { Image(systemName: "checkmark") }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard profile.id != appModel.selectedServer?.id else { return }
                        Task { await appModel.select(profile: profile); dismissing() }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { Task { await appModel.removeProfile(profile) } }
                    }
                }
                Button("Add server", systemImage: "plus") {
                    Task { await appModel.chooseAnotherServer(); dismissing() }
                }
            }
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Local cache health and destructive cache deletion.
private struct DataStorageSettingsPage: View {
    let appModel: AppModel

    var body: some View {
        Form {
            Section {
                Button("Clear local cache", role: .destructive) {
                    Task { await appModel.clearCache() }
                }
                .disabled(!appModel.cacheHealth.allowsUserInitiatedClear)
                .accessibilityHint(
                    appModel.cacheHealth.allowsUserInitiatedClear
                        ? "Deletes saved data for the active server account."
                        : "Unavailable because the persistent cache could not be opened."
                )
                .accessibilityIdentifier("settings-clear-cache")
            } footer: {
                Text("Removes saved conversations, messages, and drafts for the active account from this device. Server data is untouched.")
            }

            if let repairNotice = appModel.cacheRepairNotice {
                Section("Storage health") {
                    Label(repairNotice, systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings-cache-repair-notice")
                }
            }
        }
        .navigationTitle("Local data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountProfileView: View {
    let appModel: AppModel

    @Environment(\.fetchServerImage) private var fetchServerImage
    @State private var loadedAvatar: UIImage?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isRefreshing = false
    @State private var isUploadingAvatar = false
    @State private var isShowingDeletion = false
    @State private var errorMessage: String?
    @State private var announcementState = AccessibilityAnnouncementState()

    var body: some View {
        Form {
            profileHeader

            if let user = appModel.user {
                Section("Account details") {
                    profileValue("Name", user.name)
                    profileValue("Username", user.username)
                    profileValue("Email", user.email)
                    profileValue("Role", user.role)
                }

                Section("Security") {
                    LabeledContent(
                        "Two-factor authentication",
                        value: user.twoFactorEnabled == true ? "Enabled" : "Not enabled"
                    )
                }
            }

            Section("Delete account") {
                if appModel.canDeleteAccount {
                    Button("Delete LibreChat account", role: .destructive) {
                        isShowingDeletion = true
                    }
                    .accessibilityHint(
                        "Opens a final confirmation. This permanently deletes server data and cannot be undone."
                    )
                } else if appModel.authenticatedServerPolicyUnavailable {
                    Label(
                        "Deletion is unavailable until account policy can be verified.",
                        systemImage: "exclamationmark.shield"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "This server does not allow account deletion here.",
                        systemImage: "hand.raised"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account-profile-error")
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refreshProfile() }
        .task {
            await refreshProfile()
            await loadAvatar()
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
        .onChange(of: appModel.user?.avatarURL) { _, _ in
            Task { await loadAvatar() }
        }
        .onChange(of: errorMessage) { _, value in
            if let announcement = announcementState.announcement(for: value) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
        .sheet(isPresented: $isShowingDeletion) {
            AccountDeletionView(appModel: appModel)
        }
    }

    private var profileHeader: some View {
        Section {
            VStack(spacing: 14) {
                accountAvatar
                    .frame(width: 92, height: 92)

                VStack(spacing: 3) {
                    Text(appModel.user?.displayName ?? "LibreChat account")
                        .font(.title3.weight(.semibold))
                    if let email = appModel.user?.email, !email.isEmpty {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if isUploadingAvatar {
                    ProgressView("Uploading profile image…")
                } else {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Change profile image", systemImage: "photo")
                    }
                    .disabled(appModel.isOffline)
                    .accessibilityHint(
                        appModel.isOffline
                            ? "Reconnect to LibreChat before changing the profile image."
                            : "Choose a PNG or JPEG image. The server's profile-image size limit applies."
                    )
                    .accessibilityIdentifier("account-avatar-picker")
                }

                if isRefreshing { ProgressView("Refreshing account…") }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var accountAvatar: some View {
        if let loadedAvatar {
            Image(uiImage: loadedAvatar)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1) }
                .accessibilityLabel("Profile image")
        } else if appModel.user?.avatarURL != nil {
            // Avatar URL exists but the bytes are still in flight.
            ProgressView()
                .accessibilityLabel("Loading profile image")
        } else {
            avatarPlaceholder
        }
    }

    /// LibreChat-web's default avatar: dicebear initials on its fixed
    /// 14-color palette, seeded by the account name.
    private var avatarPlaceholder: some View {
        InitialsAvatar(seed: appModel.user?.displayName ?? "", size: 92)
            .accessibilityLabel("Default profile image")
    }

    /// Server avatars sit behind secure image links: they load through the
    /// profile's authenticated transport, never a bare AsyncImage.
    private func loadAvatar() async {
        guard let url = appModel.user?.avatarURL else {
            loadedAvatar = nil
            return
        }
        if let cached = ServerEntityImageStore.cachedImage(for: url) {
            loadedAvatar = cached
            return
        }
        let sessionGeneration = ServerEntityImageStore.currentSessionGeneration()
        guard let data = await fetchServerImage(url),
              let decoded = ServerEntityImageStore.downsampledImage(from: data) else { return }
        ServerEntityImageStore.store(decoded, for: url, sessionGeneration: sessionGeneration)
        loadedAvatar = decoded
    }

    @ViewBuilder
    private func profileValue(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }

    private func refreshProfile() async {
        guard !isRefreshing, !appModel.isOffline else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            _ = try await appModel.refreshAccountProfile()
            errorMessage = nil
        } catch LibreChatProtocolError.unauthorized {
            await appModel.expireSession()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        defer {
            isUploadingAvatar = false
            selectedPhoto = nil
        }
        do {
            var data = try await item.loadTransferable(type: Data.self)
            // Library photos commonly arrive as HEIC/HEIF; the upload
            // contract accepts PNG and JPEG, so transcode those sources to
            // JPEG (pixel-limited) before the format validation.
            if data != nil, Self.avatarMIMEType(data!) == nil {
                data = try Self.jpegTranscoded(data!)
            }
            guard let data, let mimeType = Self.avatarMIMEType(data) else {
                throw AccountProfileError.unsupportedAvatarFormat
            }
            _ = try await appModel.uploadAccountAvatar(
                AccountAvatarUpload(data: data, mimeType: mimeType)
            )
            errorMessage = nil
            UIAccessibility.post(notification: .announcement, argument: "Profile image updated")
        } catch LibreChatProtocolError.unauthorized {
            await appModel.expireSession()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Re-encodes unsupported source formats (HEIC/HEIF) as JPEG through a
    /// pixel-limited ImageIO decode.
    private static func jpegTranscoded(_ data: Data, maxPixel: Int = 4_096) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  ] as CFDictionary
              ) else {
            throw AccountProfileError.unsupportedAvatarFormat
        }
        let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
        guard let jpeg, !jpeg.isEmpty else {
            throw AccountProfileError.unsupportedAvatarFormat
        }
        return jpeg
    }

    private static func avatarMIMEType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return nil
    }
}

private struct AccountDeletionView: View {
    let appModel: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var verification = ""
    @State private var usesBackupCode = false
    @State private var isDeleting = false
    @State private var isOutcomeUnknown = false
    @State private var errorMessage: String?
    @State private var announcementState = AccessibilityAnnouncementState()

    private var requiresTwoFactor: Bool { appModel.user?.twoFactorEnabled == true }
    private var canSubmit: Bool {
        confirmation == "DELETE"
            && (!requiresTwoFactor || !verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !isDeleting
            && !isOutcomeUnknown
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("This permanently deletes the account from this LibreChat server.", systemImage: "trash.slash")
                        .font(.headline)
                    Text("Conversations, messages, files, agents, prompts, memories, connections, sessions, and other server-owned account data are removed. This cannot be undone.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Confirm") {
                    TextField("Type DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("delete-account-confirmation")

                    if requiresTwoFactor {
                        Picker("Verification method", selection: $usesBackupCode) {
                            Text("Authenticator").tag(false)
                            Text("Backup code").tag(true)
                        }
                        .pickerStyle(.segmented)

                        SecureField(
                            usesBackupCode ? "Backup code" : "Authenticator code",
                            text: $verification
                        )
                        .textContentType(.oneTimeCode)
                        .keyboardType(usesBackupCode ? .asciiCapable : .numberPad)
                        .accessibilityIdentifier("delete-account-proof")
                    }
                }

                if isOutcomeUnknown {
                    Section {
                        Label(
                            "The server may have completed deletion. This screen will not send the request again. Close Settings and sign in to check the account state.",
                            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("delete-account-uncertain")
                    }
                } else if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        deleteAccount()
                    } label: {
                        if isDeleting {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("Delete account").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityHint(
                        isOutcomeUnknown
                            ? "Disabled because the previous request may already have deleted the account."
                            : "Permanently deletes the current server account."
                    )
                    .accessibilityIdentifier("delete-account-submit")
                }
            }
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isDeleting)
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
        .onChange(of: errorMessage) { _, value in
            if let announcement = announcementState.announcement(for: value) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
        .onDisappear {
            verification = ""
            confirmation = ""
        }
    }

    private func deleteAccount() {
        guard canSubmit else { return }
        isDeleting = true
        errorMessage = nil
        let normalized = verification.trimmingCharacters(in: .whitespacesAndNewlines)
        let proof: TwoFactorProof? = requiresTwoFactor
            ? (usesBackupCode ? .backupCode(normalized) : .authenticatorCode(normalized))
            : nil
        Task {
            do {
                try await appModel.deleteCurrentAccount(proof: proof)
                verification = ""
                confirmation = ""
                isDeleting = false
                dismiss()
            } catch AccountDeletionError.outcomeUnknown {
                verification = ""
                isDeleting = false
                isOutcomeUnknown = true
                errorMessage = AccountDeletionError.outcomeUnknown.errorDescription
            } catch LibreChatProtocolError.unauthorized {
                verification = ""
                isDeleting = false
                await appModel.expireSession()
                dismiss()
            } catch {
                verification = ""
                isDeleting = false
                errorMessage = error.userFacingMessage
            }
        }
    }
}

struct AppLockView: View {
    let appModel: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 52)).foregroundStyle(.tint)
            Text("LibreChat is locked").font(.title.bold())
            Button("Unlock") { Task { await appModel.unlockApp() } }
                .adaptiveProminentButtonStyle()
        }
        .padding(32)
        .adaptiveSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding()
    }
}
