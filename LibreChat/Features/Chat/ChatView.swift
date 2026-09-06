import CoreTransferable
import DesignKit
import LibreChatDomain
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Identity for the pending-action editor. The full authoritative payload is
/// part of identity so a reused action ID cannot retain stale @State, while an
/// unchanged action preserves the user's in-progress selections.
struct PendingInteractionIdentity: Hashable {
    let handle: GenerationHandle
    let interaction: PendingInteraction
}

struct ChatTargetSwitchContext: Identifiable, Hashable {
    let conversation: LibreChatDomain.Conversation

    var id: ConversationID { conversation.id }
}

private struct GeneratedFilePreviewPollingViewID: Hashable {
    let files: [ChatModel.GeneratedFilePreviewPollingSignature]
    let isActive: Bool
}

private struct PromptLibraryPresentation: Identifiable {
    let id = UUID()
}

private struct SkillPickerPresentation: Identifiable {
    let id = UUID()
}

/// Photos-library providers advertise image content, not raw URL
/// transferables, so the picker loads through an image FileRepresentation
/// that hands back a bounded, deletable file copy.
struct PhotoAssetFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { asset in
            SentTransferredFile(asset.url)
        } importing: { received in
            let extensionSuffix = received.file.pathExtension.isEmpty
                ? "img" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appending(path: "photo-import-\(UUID().uuidString).\(extensionSuffix)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

struct ChatView: View {
    /// Hard ceiling for whole-file imports: server limits produce their own
    /// precise rejections, but nothing may materialize an unbounded file.
    static let maximumImportedFileBytes = 200 * 1_048_576

    /// Decodes a photo asset through a pixel-limited CGImageSource so huge
    /// ProRAW/panorama sources never allocate their full decompressed size.
    private static func isMultiFrame(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    private static func boundedDownsampledImageData(
        at url: URL,
        limit: Int,
        maxPixel: Int
    ) throws -> Data {
        struct PhotoTooLarge: LocalizedError {
            let limit: Int
            var errorDescription: String? {
                "That photo is too large to attach (over \(limit / 1_048_576) MB)."
            }
        }
        let data = try boundedFileData(at: url, limit: limit)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CameraCaptureFailure.encodingFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92) else {
            throw CameraCaptureFailure.encodingFailed
        }
        return jpeg
    }

    /// Copies the security-scoped file to a staging file in bounded chunks,
    /// abandoning the copy as soon as the ceiling is exceeded.
    private static func boundedStagedCopy(of url: URL, limit: Int) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatImports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = staging.appending(path: UUID().uuidString)
        try Data().write(to: destination)
        let source = try FileHandle(forReadingFrom: url)
        let output = try FileHandle(forWritingTo: destination)
        do {
            var written = 0
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                written += chunk.count
                if written > limit {
                    throw ImportedFileTooLarge(limit: limit)
                }
            }
            try output.close()
            try source.close()
        } catch {
            try? output.close()
            try? source.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    /// Reads the security-scoped file in bounded chunks, abandoning the
    /// buffer as soon as the ceiling is exceeded.
    private struct ImportedFileTooLarge: LocalizedError {
        let limit: Int
        var errorDescription: String? {
            "That file is too large to attach (over \(limit / 1_048_576) MB)."
        }
    }

    private static func boundedFileData(at url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(1_048_576)
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit {
                throw ImportedFileTooLarge(limit: limit)
            }
        }
        return data
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ChatModel
    @State private var photoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var cameraPresentation: CameraCapturePresentation?
    @State private var cameraAccessIssue: CameraCaptureAccessIssue?
    @State private var scrollFollowController = ChatScrollFollowController()
    /// Flip-only mirror of the controller's follow state. The scroll
    /// telemetry itself updates at frame rate and must never be readable from
    /// `body`, or every frame of scrolling would re-evaluate this whole view
    /// (including the full history ForEach diff) and stutter long chats.
    @State private var isJumpToLatestVisible = false
    @State private var initialPositioningState = ChatInitialPositioningState()
    @State private var scrollBottomJumpToken = 0
    /// Live height of the message viewport (composer and keyboard already
    /// excluded). The anchored dropdown cards read it to cap their fixed
    /// height to the space actually visible above the composer.
    @State private var chatViewportHeight: CGFloat = 0
    @State private var isShowingShare = false
    @State private var citationSelection: CitationSheetSelection?
    @State private var artifactSelection: ArtifactWorkspaceSelection?
    @State private var generatedFileSelection: GeneratedFileSheetSelection?
    @State private var messageEditSelection: MessageTextEditSelection?
    @State private var promptResubmitSelection: PromptResubmitSelection?
    @State private var responseRegenerationSelection: ResponseRegenerationSelection?
    @State private var generationSteerSelection: GenerationSteerSelection?
    @State private var conversationForkSelection: ConversationForkSelection?
    @State private var messageFeedbackSelection: MessageFeedbackSelection?
    @State private var pendingForkedConversation: LibreChatDomain.Conversation?
    @State private var isShowingTargetDropdown = false
    @State private var targetDropdownProvider: TargetProviderGroup?
    /// Snapshot taken when the dropdown opens so a background target refresh
    /// cannot rebuild the list mid-animation.
    @State private var targetDropdownProviders: [TargetProviderGroup] = []
    @State private var isShowingPresetDropdown = false
    @State private var isShowingAttachmentMenu = false
    @State private var isShowingSendActionsMenu = false
    /// Guards the button action from firing on release after the hold that
    /// opened the send-actions menu.
    @State private var isHoldingForSendActions = false
    @Namespace private var targetDropdownGlassNamespace
    @State private var presetCreationSelection: ChatPresetCreationSelection?
    @State private var promptLibraryPresentation: PromptLibraryPresentation?
    @State private var skillPickerPresentation: SkillPickerPresentation?
    @State private var dictationPresentation: VoiceDictationPresentation?
    @State private var readAloudVoicePresentation: ReadAloudVoicePickerPresentation?
    @State private var readAloudModel: MessageReadAloudModel
    @State private var errorAnnouncementState = AccessibilityAnnouncementState()
    @State private var menuDirectories = ConversationMenuDirectories()
    @State private var conversationToRename: LibreChatDomain.Conversation?
    @State private var renameTitle = ""
    @State private var conversationToDelete: LibreChatDomain.Conversation?
    @FocusState private var isComposerFocused: Bool
    private let serverBaseURL: URL
    private let repository: LibreChatRepository
    private let conversationListModel: ConversationListModel
    private let generationRecoverySignal: GenerationRecoverySignal?
    private let messageFocusRequest: ConversationMessageFocusRequest?
    private let profileID: ServerProfileID
    private let accountID: AccountID
    private let canShare: @MainActor () -> Bool
    private let canSnapshotSharedFiles: @MainActor () -> Bool
    private let canUsePrompts: @MainActor () -> Bool
    private let canUseSkills: @MainActor () -> Bool
    private let canUseVoiceDictation: @MainActor () -> Bool
    private let canUseReadAloud: @MainActor () -> Bool
    private let canUseBookmarks: @MainActor () -> Bool
    private let canUseProjects: @MainActor () -> Bool
    private let isOffline: @MainActor () -> Bool
    private let promptUserName: String?
    private let temporaryChatPolicy: TemporaryChatPolicy?
    private let onUnauthorized: @MainActor () async -> Void
    private let onConversationForked: @MainActor (LibreChatDomain.Conversation) -> Void
    private let onConversationDismissed: @MainActor (ConversationID) -> Void
    private let onOpenSidebar: @MainActor () -> Void

    init(
        conversation: LibreChatDomain.Conversation,
        profileID: ServerProfileID,
        accountID: AccountID,
        serverBaseURL: URL,
        repository: LibreChatRepository,
        conversationListModel: ConversationListModel,
        uploadManager: UploadManager?,
        generationRecoverySignal: GenerationRecoverySignal?,
        messageFocusRequest: ConversationMessageFocusRequest?,
        canGenerate: @escaping @MainActor () -> Bool,
        canShare: @escaping @MainActor () -> Bool,
        canSnapshotSharedFiles: @escaping @MainActor () -> Bool,
        canUsePrompts: @escaping @MainActor () -> Bool,
        canUseSkills: @escaping @MainActor () -> Bool,
        canUseVoiceDictation: @escaping @MainActor () -> Bool,
        canUseReadAloud: @escaping @MainActor () -> Bool,
        canUseBookmarks: @escaping @MainActor () -> Bool = { false },
        canUseProjects: @escaping @MainActor () -> Bool = { false },
        isOffline: @escaping @MainActor () -> Bool,
        promptUserName: String?,
        temporaryChatPolicy: TemporaryChatPolicy? = nil,
        compatibilityWarning: @escaping @MainActor () -> String?,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onConversationForked: @escaping @MainActor (LibreChatDomain.Conversation) -> Void,
        onConversationDismissed: @escaping @MainActor (ConversationID) -> Void = { _ in },
        onOpenSidebar: @escaping @MainActor () -> Void = {},
        onConversationIdentityChanged: @escaping @MainActor (ConversationID, LibreChatDomain.Conversation) -> Void
    ) {
        self.serverBaseURL = serverBaseURL
        self.repository = repository
        self.conversationListModel = conversationListModel
        self.generationRecoverySignal = generationRecoverySignal
        self.messageFocusRequest = messageFocusRequest
        self.profileID = profileID
        self.accountID = accountID
        self.temporaryChatPolicy = temporaryChatPolicy
        self.canShare = canShare
        self.canSnapshotSharedFiles = canSnapshotSharedFiles
        self.canUsePrompts = canUsePrompts
        self.canUseSkills = canUseSkills
        self.canUseVoiceDictation = canUseVoiceDictation
        self.canUseReadAloud = canUseReadAloud
        self.canUseBookmarks = canUseBookmarks
        self.canUseProjects = canUseProjects
        self.isOffline = isOffline
        self.promptUserName = promptUserName
        self.onUnauthorized = onUnauthorized
        self.onConversationForked = onConversationForked
        self.onConversationDismissed = onConversationDismissed
        self.onOpenSidebar = onOpenSidebar
        _model = State(
            initialValue: ChatModel(
                conversation: conversation,
                profileID: profileID,
                accountID: accountID,
                repository: repository,
                uploadManager: uploadManager,
                canGenerate: canGenerate,
                canUseSkills: canUseSkills,
                compatibilityWarning: compatibilityWarning,
                onUnauthorized: onUnauthorized,
                onConversationIdentityChanged: onConversationIdentityChanged
            )
        )
        _readAloudModel = State(initialValue: MessageReadAloudModel(
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        ScrollViewReader { proxy in
            chatStateContent
            .overlay(alignment: .bottomTrailing) {
                // There is nothing to jump to on a blank canvas — and any
                // swipe there flips the follow controller — so the button
                // only exists once a thread exists.
                if !model.messages.isEmpty, isJumpToLatestVisible {
                    Button {
                        scrollToBottom(using: proxy, animated: !reduceMotion)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .adaptiveInteractiveGlass(in: Circle())
                    .accessibilityLabel("Jump to latest message")
                    .accessibilityIdentifier("jump-to-latest")
                    .padding(.trailing, 16)
                    .padding(.bottom, 12)
                }
            }
            .onChange(of: model.renderProjection.lastVisiblePlainTextRevision) {
                guard scrollFollowController.shouldFollowContent else { return }
                // Streaming updates can arrive faster than a short animation can
                // settle. Moving immediately avoids competing with user scrolling.
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: model.renderProjection.visibleMessageCount) {
                guard scrollFollowController.shouldFollowContent else { return }
                scrollToBottom(using: proxy, animated: false)
            }
            .onChange(of: model.generationSnapshot?.state.isTerminal) { _, isTerminal in
                if isTerminal == true {
                    UIAccessibility.post(notification: .announcement, argument: "LibreChat response complete")
                }
            }
            .onChange(of: model.isStreaming) { _, streaming in
                if !streaming, isShowingSendActionsMenu {
                    closeSendActionsMenu()
                }
            }
            .onChange(of: model.draft) { _, newDraft in
                if newDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   isShowingSendActionsMenu {
                    closeSendActionsMenu()
                }
            }
            .onChange(of: model.errorMessage) { _, message in
                if let announcement = errorAnnouncementState.announcement(for: message) {
                    UIAccessibility.post(notification: .announcement, argument: announcement)
                }
            }
            .task(id: messageFocusRequest) {
                if messageFocusRequest != nil {
                    scrollFollowController.suspendFollowing()
                }
                await model.loadIfNeeded()
                guard !Task.isCancelled else { return }

                if let messageFocusRequest {
                    initialPositioningState.recordExplicitFocus()
                    switch model.focusSearchResult(messageFocusRequest) {
                    case let .focused(messageID):
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if reduceMotion {
                            proxy.scrollTo(messageID, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(messageID, anchor: .center)
                            }
                        }
                        if model.renderProjection.lastVisibleMessageID == messageID {
                            scrollFollowController.requestFollowBottom()
                        }
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Search result"
                        )
                    case .unavailable:
                        scrollToBottom(using: proxy, animated: false)
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Search result unavailable"
                        )
                    }
                    return
                }

                // Initial positioning is owned by `.defaultScrollAnchor(.bottom)`
                // on the scroll view: it lands on the bottom edge from the lazy
                // list's estimates. A programmatic marker scroll here would
                // materialize every row of a long conversation before drawing.
            }
        }
        .onAppear {
            // The jump-to-latest button re-acts only when following flips;
            // frame-rate scroll telemetry never reaches the view's body.
            scrollFollowController.onFollowStateChanged = { following in
                guard isJumpToLatestVisible == following else { return }
                isJumpToLatestVisible = !following
            }
        }
        .background(Color(uiColor: .systemBackground))
        // A blank canvas has no title, like ChatGPT's new-chat screen; the
        // wordmark is the header until the first message names the thread.
        .navigationTitle(model.messages.isEmpty ? "" : model.conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // ChatGPT-style model selector in the middle of the top bar
                // on every chat screen; the conversation title remains
                // available in the sidebar and for accessibility.
                    let executionPresentation = ComposerExecutionSummaryPresentation(
                        targetSpec: model.executionTargetSpec,
                        model: executionRoutesToNamedAgent ? nil : model.executionTargetModel,
                        selectedAgentOrAssistant: executionAgentOrAssistantLabel,
                        endpoint: model.executionTargetEndpoint,
                        attachmentCount: model.uploads.count,
                        attachmentState: model.executionAttachmentState,
                        serverHost: serverBaseURL.host,
                        executionCapabilities: model.executionCapabilities
                    )
                    Button {
                        // The trigger is a true toggle: tapping the pill while
                        // the dropdown is open closes it without refetching
                        // or reinitializing anything.
                        if isShowingTargetDropdown {
                            dismissDropdowns()
                            return
                        }
                        targetDropdownProviders = TargetProviderGroup.build(
                            from: conversationListModel.availableTargets
                        )
                        targetDropdownProvider = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                            isShowingPresetDropdown = false
                            isShowingTargetDropdown = true
                        }
                        // The cached catalog renders instantly; the network is
                        // only consulted when nothing usable has been loaded
                        // yet (first open, or a prior failure).
                        if conversationListModel.targetCatalog == nil {
                            Task {
                                await conversationListModel.loadTargets(forceRefresh: true)
                                refreshTargetDropdownSnapshot()
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            // The web header leads with the resolved brand
                            // mark — the spec's image, the agent's avatar, or
                            // the endpoint glyph — never a generic symbol.
                            EndpointBrandIcon(
                                endpoint: currentCanvasOption?.target.endpoint
                                    ?? model.conversation.target?.endpoint,
                                model: currentCanvasOption?.target.model
                                    ?? model.conversation.model,
                                iconURL: currentCanvasOption?.iconURL,
                                iconEndpoint: currentCanvasOption?.iconEndpoint,
                                size: 18
                            )
                            Text(executionPresentation.target)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .adaptiveInteractiveGlass(in: Capsule())
                        .contentShape(Capsule())
                        .glassIdentity(
                            "target-dropdown",
                            in: targetDropdownGlassNamespace,
                            active: !isShowingTargetDropdown
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canStartNewChatWithAnotherTarget)
                    .accessibilityLabel("Message setup")
                    .accessibilityValue(executionPresentation.accessibilityValue)
                    .accessibilityHint(
                        model.targetSwitchDisabledReason
                            ?? "Opens the model and provider catalog. The current conversation stays unchanged."
                    )
                    .accessibilityIdentifier("execution-envelope")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show conversations")
                .accessibilityHint("Opens the chat list sidebar.")
                .accessibilityIdentifier("open-sidebar-button")
            }
            if model.messages.isEmpty {
                // A fresh canvas owns the pre-send controls: presets define
                // its setup and the clock sets its privacy before anything is
                // sent. Both retire once the conversation exists.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            // The dropdown cards and the preset card are
                            // mutually exclusive with each other and with the
                            // attachment menu.
                            isShowingTargetDropdown = false
                            isShowingAttachmentMenu = false
                            isShowingPresetDropdown = true
                        }
                        Task {
                            async let presets: Void = conversationListModel.loadPresets(forceRefresh: true)
                            async let targets: Void = conversationListModel.loadTargets()
                            _ = await (presets, targets)
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.up")
                    }
                    .disabled(isOffline() || !conversationListModel.canUsePresets)
                    .accessibilityLabel("Presets")
                    .accessibilityHint("Applies a saved preset to a new chat, or saves the current setup.")
                    .accessibilityIdentifier("preset-picker-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let isTemporary = model.conversation.isTemporaryConversation
                    Button {
                        Task { await toggleTemporaryChat() }
                    } label: {
                        Image(systemName: isTemporary ? "clock.arrow.circlepath" : "clock")
                            .foregroundStyle(isTemporary ? Color(uiColor: .systemBackground) : Color.primary)
                            .frame(width: 28, height: 28)
                            .background(
                                isTemporary ? Color.primary : Color.clear,
                                in: Circle()
                            )
                    }
                    .disabled(isOffline() || temporaryChatPolicy?.isAvailable != true)
                    .accessibilityLabel(isTemporary ? "Disable temporary chat" : "Enable temporary chat")
                    .accessibilityHint(
                        temporaryChatPolicy.map { temporaryChatExplanation($0) }
                            ?? "Starts a fresh chat that expires and is never saved to history."
                    )
                    .accessibilityIdentifier("temporary-chat-button")
                }
            } else if !model.conversation.id.isLocalDraft {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await startNewChatFromChat() }
                    } label: {
                        Image(systemName: "square.pencil")
                            // Theme-monochrome glyph, matching the hamburger
                            // and 3-dots instead of the system accent tint.
                            .foregroundStyle(.primary)
                    }
                    .disabled(isOffline())
                    .accessibilityLabel("New chat")
                    .accessibilityHint("Starts a fresh chat with the most recently used model or agent.")
                    .accessibilityIdentifier("chat-new-chat-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Conversation actions", systemImage: "ellipsis.circle") {
                        if conversationListModel.canUsePresets {
                            Button {
                                Task { await conversationListModel.loadPresets(forceRefresh: true) }
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    isShowingTargetDropdown = false
                                    isShowingAttachmentMenu = false
                                    isShowingPresetDropdown = true
                                }
                            } label: {
                                Label("Presets", systemImage: "square.stack.3d.up")
                            }
                            .disabled(isOffline())
                            .accessibilityHint("Applies a saved preset to a new chat.")
                            .accessibilityIdentifier("preset-picker-button")
                            Divider()
                        }
                        if canShare() {
                            Button {
                                isShowingShare = true
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .disabled(!model.canShareSelectedBranch)
                            .accessibilityHint("Creates or manages this conversation's shared link.")
                        }
                        conversationCommandSections
                    }
                    .accessibilityHint("Share, organize, archive, or delete this conversation.")
                    .accessibilityIdentifier("conversation-actions")
                }
            }
        }
        .overlay(alignment: .top) { dropdownLayer }
        .overlay(alignment: .bottomLeading) {
            if isShowingAttachmentMenu {
                attachmentMenuCard
                    .padding(.leading, 12)
                    // Anchored low: the card's bottom edge tucks just under
                    // the composer's control row so the + sits beneath the
                    // menu, while every row (prompts included) stays clear of
                    // the keyboard.
                    .padding(.bottom, 0)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomLeading))
                    )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isShowingSendActionsMenu {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { closeSendActionsMenu() }
                    .accessibilityLabel("Close menu")

                sendActionsMenuCard
                    .padding(.trailing, 12)
                    .padding(.bottom, 0)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
                    )
            }
        }
        .overlay(alignment: .bottom) {
            // Transient notices (file-size rejections after compaction, …):
            // a self-dismissing toast capsule. These never become persistent
            // inline error strips with dismiss buttons.
            if let toastMessage = model.transientNotice {
                ChatTransientToast(message: toastMessage) {
                    model.transientNotice = nil
                }
                .task {
                    try? await Task.sleep(for: .seconds(3.6))
                    guard !Task.isCancelled else { return }
                    model.transientNotice = nil
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .modifier(ChatRenameAndDeletePresentations(
            conversationToRename: $conversationToRename,
            renameTitle: $renameTitle,
            conversationToDelete: $conversationToDelete,
            rename: { conversation, title in
                Task { await conversationListModel.rename(conversation, title: title) }
            },
            delete: { conversation in
                Task {
                    await conversationListModel.delete(conversation)
                    onConversationDismissed(conversation.id)
                }
            }
        ))
        .task(id: conversationMenuLoadKey) {
            await menuDirectories.load(
                repository: repository,
                isOffline: isOffline(),
                canUseBookmarks: canUseBookmarks(),
                canUseProjects: canUseProjects(),
                onUnauthorized: onUnauthorized
            )
        }
        .sheet(isPresented: $isShowingShare) {
            SharedLinkOwnerView(
                conversationID: model.conversation.id,
                targetMessageID: model.shareTargetMessageID,
                baseURL: serverBaseURL,
                repository: repository,
                supportsFileSnapshots: canSnapshotSharedFiles(),
                onUnauthorized: onUnauthorized,
                onForked: onConversationForked
            )
        }
        .sheet(item: $citationSelection) { selection in
            CitationSourceSheet(selection: selection)
        }
        .sheet(item: $readAloudVoicePresentation) { _ in
            ReadAloudVoiceSheet(model: readAloudModel)
        }
        .sheet(item: $skillPickerPresentation) { _ in
            SkillPickerSheet(
                model: model,
                initialSelection: model.selectedSkillNames
            )
        }
        .modifier(ArtifactWorkspacePresentationModifier(
            selection: $artifactSelection,
            mode: ArtifactWorkspacePresentationMode(
                isPhone: UIDevice.current.userInterfaceIdiom == .phone
            )
        ) { selection, showsCloseAction in
            ArtifactWorkspaceView(
                selection: selection,
                showsCloseAction: showsCloseAction,
                canEditNow: {
                    selection.conversationID == model.conversation.id
                        && model.canEditArtifacts(in: selection.artifact.identity.messageID)
                }
            ) { artifact, updatedContent in
                try await model.editArtifact(artifact, updatedContent: updatedContent)
            }
        })
        .sheet(item: $generatedFileSelection) { selection in
            generatedFileSheet(for: selection)
        }
        .sheet(item: $messageEditSelection) { selection in
            MessageTextEditSheet(
                selection: selection,
                save: { selection, text in
                    try await model.saveMessageEdit(selection, text: text)
                },
                refresh: { await model.reload() }
            )
        }
        .sheet(item: $messageFeedbackSelection) { selection in
            MessageFeedbackSheet(
                selection: selection,
                save: { selection, feedback in
                    try await model.updateMessageFeedback(selection, feedback: feedback)
                },
                refresh: { await model.reload() }
            )
        }
        .sheet(item: $promptResubmitSelection) { selection in
            PromptResubmitSheet(
                selection: selection,
                submit: { selection, text in
                    try await model.editPromptAndResubmit(selection, text: text)
                },
                refresh: { await model.reload() }
            )
        }
        .sheet(item: $responseRegenerationSelection) { selection in
            ResponseRegenerationSheet(
                selection: selection,
                submit: { selection in
                    try await model.regenerateResponse(selection)
                },
                refresh: { await model.reload() }
            )
        }
        .sheet(item: $generationSteerSelection) { selection in
            GenerationSteerSheet(
                selection: selection,
                submit: { selection, text, preempt in
                    try await model.submitSteer(selection, text: text, preempt: preempt)
                }
            )
        }
        .sheet(item: $conversationForkSelection, onDismiss: {
            guard let conversation = pendingForkedConversation else { return }
            pendingForkedConversation = nil
            onConversationForked(conversation)
        }) { selection in
            ConversationForkSheet(
                selection: selection,
                submit: { selection in
                    try await model.forkConversation(selection)
                },
                completed: { result in
                    pendingForkedConversation = result.conversation
                }
            )
        }
        .sheet(item: $dictationPresentation) { _ in
            VoiceDictationSheet(
                profileID: profileID,
                accountID: accountID,
                serverHost: serverBaseURL.host ?? "",
                repository: repository,
                onUnauthorized: onUnauthorized,
                onTranscript: { transcript in
                    if model.insertPromptIntoDraft(transcript) {
                        isComposerFocused = true
                    }
                }
            )
        }
        .sheet(item: $presetCreationSelection) { selection in
            PresetCreationView(
                target: selection.target,
                save: { title, promptPrefix in
                    try await conversationListModel.createPreset(
                        title: title,
                        promptPrefix: promptPrefix,
                        reviewedTarget: selection.target
                    )
                },
                saved: { _ in
                    Task { await conversationListModel.loadPresets(forceRefresh: true) }
                },
                refreshAfterUnknown: {
                    Task { await conversationListModel.loadPresets(forceRefresh: true) }
                }
            )
        }
        .sheet(item: $promptLibraryPresentation) { _ in
            PromptLibraryView(
                repository: repository,
                userName: promptUserName,
                isOffline: isOffline,
                onUnauthorized: onUnauthorized,
                insert: { text in
                    if model.insertPromptIntoDraft(text) {
                        isComposerFocused = true
                    }
                }
            )
        }
        .fullScreenCover(item: $cameraPresentation) { _ in
            CameraCaptureSheet { result in
                switch result {
                case let .success(photo):
                    Task {
                        await model.attach(
                            data: photo.data,
                            filename: photo.filename,
                            mimeType: photo.mimeType
                        )
                    }
                case let .failure(error):
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .alert(item: $cameraAccessIssue) { issue in
            if issue.offersSettings {
                return Alert(
                    title: Text(issue.title),
                    message: Text(issue.message),
                    primaryButton: .default(Text("Open Settings")) {
                        openApplicationSettings()
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.data, .image, .pdf, .plainText]) { result in
            guard case let .success(url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let values = try url.resourceValues(forKeys: [.contentTypeKey, .nameKey, .fileSizeKey])
                    // Security-scoped files are materialized incrementally:
                    // providers can omit fileSize or grow after the metadata
                    // read, so nothing may buffer an unbounded file.
                    if let fileSize = values.fileSize, fileSize > Self.maximumImportedFileBytes {
                        model.errorMessage = "That file is too large to attach (over \(Self.maximumImportedFileBytes / 1_048_576) MB)."
                        return
                    }
                    // Copy through bounded chunks into a file-backed
                    // staging copy and hand the uploader a memory-mapped
                    // view, so near-ceiling imports never buffer fully in
                    // RAM.
                    let stagedCopy = try Self.boundedStagedCopy(
                        of: url,
                        limit: Self.maximumImportedFileBytes
                    )
                    defer { try? FileManager.default.removeItem(at: stagedCopy) }
                    let data = try Data(
                        contentsOf: stagedCopy,
                        options: [.mappedIfSafe]
                    )
                    try await model.attach(
                        data: data,
                        filename: values.name ?? url.lastPathComponent,
                        mimeType: values.contentType?.preferredMIMEType
                    )
                } catch { model.errorMessage = error.userFacingMessage }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    // Provider-backed assets can be enormous: load the
                    // file-backed copy, bound its bytes, and decode through
                    // a pixel-limited CGImageSource instead of
                    // materializing the complete asset as raw data.
                    guard let asset = try await item.loadTransferable(type: PhotoAssetFile.self) else { return }
                    defer { try? FileManager.default.removeItem(at: asset.url) }
                    // Animated (multi-frame) sources stage their original
                    // bounded bytes so UploadManager's multi-frame
                    // preservation path sees them intact.
                    if Self.isMultiFrame(at: asset.url) {
                        let data = try Self.boundedFileData(at: asset.url, limit: Self.maximumImportedFileBytes)
                        try await model.attach(
                            data: data,
                            filename: asset.url.lastPathComponent,
                            mimeType: nil
                        )
                        return
                    }
                    let data = try Self.boundedDownsampledImageData(
                        at: asset.url,
                        limit: Self.maximumImportedFileBytes,
                        maxPixel: 4096
                    )
                    guard let image = UIImage(data: data) else {
                        throw CameraCaptureFailure.encodingFailed
                    }
                    let photo = try CameraPhotoEncoder.encode(image)
                    await model.attach(
                        data: photo.data,
                        filename: photo.filename.replacingOccurrences(of: "camera-", with: "photo-"),
                        mimeType: photo.mimeType
                    )
                } catch { model.errorMessage = error.userFacingMessage }
                photoItem = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task {
                await readAloudModel.applicationBecameInactive()
                await model.checkpointDraft()
            }
        }
        .onChange(of: readAloudSelectionIdentities) { _, identities in
            Task {
                await readAloudModel.reconcile(available: Set(identities))
            }
        }
        .task(id: generationRecoverySignal?.sequence) {
            guard let generationRecoverySignal else { return }
            await model.loadIfNeeded()
            await model.applyForegroundGenerationRecovery(generationRecoverySignal)
        }
        .task(id: generatedFilePreviewPollingViewID) {
            await model.synchronizeGeneratedFilePreviewPolling(isActive: scenePhase == .active)
        }
        .onDisappear {
            Task {
                await model.stopGeneratedFilePreviewPolling()
                await readAloudModel.stop()
                await model.checkpointDraft()
            }
        }
    }

    @ViewBuilder
    private var chatStateContent: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Loading messages…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message) where model.messages.isEmpty:
            ContentUnavailableView {
                Label("Couldn’t load messages", systemImage: "exclamationmark.bubble")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
            }
        default:
            messageList
        }
    }

    private var generatedFilePreviewPollingViewID: GeneratedFilePreviewPollingViewID {
        GeneratedFilePreviewPollingViewID(
            files: model.pendingGeneratedFilePreviewSignature,
            isActive: scenePhase == .active
        )
    }

    private func generatedFileSheet(
        for selection: GeneratedFileSheetSelection
    ) -> some View {
        let currentFile = model.generatedFile(matching: selection.file.identity)
            ?? selection.file
        return GeneratedFileSheetView(
            selection: selection,
            currentFile: currentFile,
            refresh: { try await model.refreshGeneratedFile($0) },
            download: { try await model.downloadGeneratedFile($0) }
        )
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                if model.isShowingCache {
                    Label("Showing saved messages", systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.messages.isEmpty {
                    // The blank canvas brands itself with the selected
                    // provider's or agent's own icon and greets with the
                    // classic LibreChat-web schedule phrases — the model
                    // name stays in the pill where it belongs. A temporary
                    // canvas names its mode instead, so the privacy state is
                    // legible without the removed banner.
                    VStack(spacing: 18) {
                        if model.conversation.isTemporaryConversation {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 44, weight: .medium))
                                .foregroundStyle(.primary)
                                .accessibilityHidden(true)
                            Text("Temporary chat")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("This chat won't appear in your history and will be deleted automatically.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        } else if let option = currentCanvasOption {
                            canvasBrandIcon(for: option)
                            Text(LibreChatGreeting.resolved(userName: promptUserName))
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        } else {
                            BrandIconSkeleton()
                            Text(LibreChatGreeting.resolved(userName: promptUserName))
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    // The branding floats in the middle of the visible
                    // canvas, like ChatGPT, instead of hugging the top.
                    .containerRelativeFrame(.vertical)
                    .accessibilityElement(children: .combine)
                } else if !model.renderProjection.isStructurallyValid {
                    ContentUnavailableView(
                        "Conversation branches unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(
                            "LibreChat returned an inconsistent message tree. Refresh before continuing this conversation."
                        )
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(model.renderProjection.visibleEntries) { entry in
                        VStack(spacing: 6) {
                            MessageRow(
                                message: entry.message,
                                isStreaming: model.isStreaming
                                    && entry.message.id.rawValue.hasPrefix("local-assistant-"),
                                onCitationSelected: { citationSelection = $0 },
                                onArtifactSelected: { artifactSelection = $0 },
                                onGeneratedFileSelected: { generatedFileSelection = $0 },
                                messageEditSelections: model.editableMessageTextSelections(
                                    for: entry.message.id
                                ),
                                onMessageEditSelected: { messageEditSelection = $0 },
                                promptResubmitSelection: model.promptResubmitSelection(
                                    for: entry.message.id
                                ),
                                onPromptResubmitSelected: { promptResubmitSelection = $0 },
                                responseRegenerationSelection: model.responseRegenerationSelection(
                                    for: entry.message.id
                                ),
                                onResponseRegenerationSelected: {
                                    responseRegenerationSelection = $0
                                },
                                conversationForkSelection: model.conversationForkSelection(
                                    for: entry.message.id
                                ),
                                onConversationForkSelected: {
                                    conversationForkSelection = $0
                                },
                                positiveFeedbackSelection: model.messageFeedbackSelection(
                                    for: entry.message.id,
                                    suggestedRating: .thumbsUp
                                ),
                                negativeFeedbackSelection: model.messageFeedbackSelection(
                                    for: entry.message.id,
                                    suggestedRating: .thumbsDown
                                ),
                                onMessageFeedbackSelected: {
                                    messageFeedbackSelection = $0
                                },
                                readAloudAction: readAloudAction(for: entry.message),
                                onReadAloud: {
                                    guard let selection = readAloudSelection(
                                        for: entry.message
                                    ) else { return }
                                    Task { await readAloudModel.perform(selection) }
                                },
                                onChooseReadAloudVoice: {
                                    readAloudVoicePresentation = ReadAloudVoicePickerPresentation()
                                },
                                allowsArtifactEditing: model.canEditArtifacts(
                                    in: entry.message.id
                                )
                            )
                            .equatable()

                            if entry.siblings.count > 1 {
                                BranchSiblingControl(entry: entry) { messageID in
                                    model.selectSibling(messageID, under: entry.parent)
                                }
                            }
                        }
                        .id(entry.message.id)
                    }
                }

                if let snapshot = model.generationSnapshot {
                    GenerationActivityView(
                        snapshot: snapshot,
                        isResponding: model.isRespondingToInteraction
                    ) { toolResolutions, answer, batchAnswers in
                        model.respondToInteraction(
                            toolResolutions: toolResolutions,
                            answer: answer,
                            batchAnswers: batchAnswers
                        )
                    }
                    .equatable()
                }

                // The invisible scroll anchor only matters once there is a
                // thread to scroll: on a blank canvas it would add rows and
                // spacing on top of the full-height branding, making the
                // view scrollable despite fitting the viewport.
                if !model.messages.isEmpty {
                    Color.clear
                        .frame(height: 1)
                        .id(ChatScrollAnchor.bottom)
                        .modifier(ChatBottomOffsetPreferenceEmitter())
                }
            }
            .padding(.horizontal, 16)
            // A blank canvas must exactly fill the viewport — no vertical
            // padding, so the centered branding leaves nothing to scroll.
            .padding(.top, model.messages.isEmpty ? 0 : 18)
            .padding(.bottom, model.messages.isEmpty ? 0 : 12)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("chat-view-\(model.conversation.id.rawValue)")
        .defaultScrollAnchor(.bottom)
        .modifier(ChatBottomEdgeJumpGate(token: scrollBottomJumpToken))
        .scrollDismissesKeyboard(.interactively)
        // Tapping the conversation body resigns the composer's focus. The
        // gesture is simultaneous, so buttons, links, text selection, message
        // actions, and scrolling all behave exactly as before — only the
        // keyboard closes. The composer and header live outside this scroll
        // view and are unaffected.
        .simultaneousGesture(
            TapGesture().onEnded {
                if isComposerFocused {
                    isComposerFocused = false
                }
            }
        )
        // The empty canvas fits its viewport exactly, so it never rubber-bands.
        .scrollBounceBehavior(model.messages.isEmpty ? .basedOnSize : .automatic)
        .modifier(ChatScrollInteractionModifier(
            began: { scrollFollowController.beginUserInteraction() },
            ended: { scrollFollowController.endUserInteraction() }
        ))
        .modifier(ChatScrollGeometryModifier { distanceFromBottom in
            scrollFollowController.updateDistanceFromBottom(distanceFromBottom)
        })
        .coordinateSpace(name: ChatScrollAnchor.coordinateSpace)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChatViewportHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        }
        .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { height in
            if chatViewportHeight != height {
                chatViewportHeight = height
            }
            scrollFollowController.updateViewportHeight(height)
        }
        .onPreferenceChange(ChatBottomOffsetPreferenceKey.self) { offset in
            if #unavailable(iOS 18.0) {
                scrollFollowController.updateBottomOffset(offset)
            }
        }
    }

    // MARK: - Composer

    /// The segmented composer surface: attachment and Skills chips ride in
    /// their own glass segments above the input row; the "+" opens the
    /// bottom-left anchored attachment card instead of an inline menu.
    private var composer: some View {
        VStack(spacing: 8) {
            ReadAloudBar(
                model: readAloudModel,
                onChooseVoice: {
                    readAloudVoicePresentation = ReadAloudVoicePickerPresentation()
                }
            )

            if let disabledReason = model.generationDisabledReason {
                Label(disabledReason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("generation-compatibility-warning")
            }

            if let uploadStatusMessage = model.uploadStatusMessage {
                Label(uploadStatusMessage, systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("attachment-status")
            }

            if let errorMessage = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage).frame(maxWidth: .infinity, alignment: .leading)
                    if model.generationSnapshot?.state.isTerminal == false, !model.isStreaming {
                        Button("Resume") { model.retryRecovery() }
                    }
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss error")
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
            }

            if let snapshot = model.generationSnapshot {
                PendingSteerStrip(
                    steers: snapshot.pendingSteers,
                    isBusy: model.isSteeringMutationInProgress,
                    cancel: { model.cancelPendingSteer($0) },
                    arm: { model.armPendingSteer($0) }
                )
            }

            RecoverableSteerStrip(
                batches: model.recoverableSteerBatches,
                isBusy: model.isFollowUpMutationInProgress,
                canQueue: { model.canQueueRecoverableSteer($0, from: $1) },
                queue: { model.queueRecoverableSteer($0, from: $1) },
                discard: { model.discardRecoverableSteer($0, from: $1) }
            )

            // The queued message hugs the composer: the strip is the last
            // chrome above the pill so a waiting message reads as part of
            // the send surface, with its X cancel sitting in the send slot.
            FollowUpQueueStrip(
                items: model.activeFollowUpItems,
                isBusy: model.isFollowUpMutationInProgress,
                canRetry: { model.canRetryQueuedFollowUp($0) },
                retry: { model.retryQueuedFollowUp($0) },
                remove: { model.removeQueuedFollowUp($0) }
            )

            VStack(spacing: 8) {
                if !model.uploads.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(model.uploads) { upload in
                                UploadChip(
                                    upload: upload,
                                    cancel: { model.cancelUpload(upload) },
                                    retry: { model.retryUpload(upload) },
                                    reconcile: { model.reconcileUpload(upload) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .composerChrome(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Attachments")
                }

                if !model.selectedSkillNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.selectedSkillNames, id: \.self) { name in
                                Button {
                                    model.removeSelectedSkill(named: name)
                                } label: {
                                    Label(name, systemImage: "xmark")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .frame(minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("Remove \(name) Skill")
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .composerChrome(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityLabel("Selected Skills")
                    .accessibilityIdentifier("selected-skills")
                }

                // ChatGPT-native two-row composer: the draft sits on its own
                // row, and the control row (plus, dictation, send/stop) runs
                // underneath inside the same rounded field.
                VStack(alignment: .leading, spacing: 0) {
                    let skillsAvailable = canUseSkills() || !model.selectedSkillNames.isEmpty
                    let promptsAvailable = canUsePrompts()

                    TextField("Message", text: $model.draft, axis: .vertical)
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .focused($isComposerFocused)
                        .onChange(of: model.draft) { model.draftChanged() }
                        .disabled(!model.canEditDraft)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                        .accessibilityIdentifier("composer-draft")

                    HStack(alignment: .center, spacing: 2) {
                        Button {
                            // A short spring reads as a subtle, responsive pop
                            // on open and settles quickly on close. Opening
                            // the attachment menu closes the model/preset
                            // dropdowns — the two surfaces never stay open
                            // together.
                            if !isShowingAttachmentMenu {
                                withAnimation(.easeIn(duration: 0.14)) {
                                    isShowingTargetDropdown = false
                                    isShowingPresetDropdown = false
                                    targetDropdownProvider = nil
                                }
                            }
                            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                                isShowingAttachmentMenu.toggle()
                            }
                            isShowingSendActionsMenu = false
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 23, weight: .regular))
                                .foregroundStyle(.primary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(
                            !(model.canStageAttachments
                                || (skillsAvailable && model.canPresentSkills)
                                || (promptsAvailable && model.canEditDraft))
                        )
                        .accessibilityLabel("Add to your message")
                        .accessibilityHint(
                            "Attach a photo or file, choose Skills, or open the prompt library."
                        )
                        .accessibilityIdentifier("attachment-menu")

                        Spacer()

                        if canUseVoiceDictation() {
                            composerDictationButton
                        }

                        ZStack {
                            switch composerTrailingState {
                            case .stop:
                                composerStopButton
                            case .send:
                                composerSendButton
                            case .cancelQueued:
                                composerCancelQueuedButton
                            }
                        }
                        .frame(width: 44, height: 44)
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.18),
                            value: composerTrailingState
                        )
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.35)
                                .onEnded { _ in showSendActionsMenu() }
                        )
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
                }
                .composerChrome(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        // Queue churn (a message queued, drained, or cancelled) animates as
        // one motion so the composer never jumps; the send-slot symbol swap
        // is animated by the control's own scoped animation.
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: model.activeFollowUpItems.map(\.id)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - Composer trailing state

    /// The right-hand filled circle is always present at a fixed 44pt slot:
    /// solid gray while a send isn't possible yet (empty draft, routing not
    /// ready), pure black/white when ready, stop while generating, and an X
    /// while a message waits in the follow-up queue — so normal, queued, and
    /// generating states swap symbols in place without resizing the control
    /// row.
    private enum ComposerTrailingState: Equatable {
        case stop
        case send
        case cancelQueued
    }

    private var composerTrailingState: ComposerTrailingState {
        if model.isStreaming || model.isStopping { return .stop }
        if nextQueuedFollowUpItem != nil { return .cancelQueued }
        return .send
    }

    /// The front of the queue: the queued message the X control cancels.
    private var nextQueuedFollowUpItem: FollowUpQueueItem? {
        model.activeFollowUpItems.first { item in
            if case .queued = item.state { return true }
            return false
        }
    }

    private var composerSendButton: some View {
        let canSubmit = model.canSend && !model.isSteeringMutationInProgress
        // Enabled is pure black/white (never a tinted or translucent fill);
        // the not-ready state is a solid gray circle that stays clearly
        // visible in both appearances.
        let sendFill = colorScheme == .dark ? Color.white : Color.black
        let sendGlyph = colorScheme == .dark ? Color.black : Color.white
        return Button {
            if isHoldingForSendActions {
                isHoldingForSendActions = false
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(canSubmit ? sendGlyph : Color(uiColor: .systemBackground))
                .frame(width: 38, height: 38)
                .background(
                    canSubmit ? sendFill : Color.secondary,
                    in: Circle()
                )
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(SendButtonStyle(reduceMotion: reduceMotion))
        .disabled(!canSubmit)
        .accessibilityLabel("Send message")
        .accessibilityHint(model.generationDisabledReason ?? "Send the message and its attachments.")
        .accessibilityIdentifier("composer-send")
        .transition(reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .center).combined(with: .opacity))
    }

    private var composerStopButton: some View {
        Button {
            if isHoldingForSendActions {
                isHoldingForSendActions = false
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.stop()
        } label: {
            Image(systemName: model.isStopping ? "hourglass" : "stop.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .frame(width: 38, height: 38)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(SendButtonStyle(reduceMotion: reduceMotion))
        .disabled(model.isStopping || model.isSteeringMutationInProgress)
        .accessibilityLabel(model.isStopping ? "Stopping response" : "Stop response")
        .accessibilityHint("Stop the current response.")
        .accessibilityIdentifier("composer-send")
        .transition(reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .center).combined(with: .opacity))
    }

    /// Cancels the queued message from the send slot, like ChatGPT's X while
    /// a next message waits. Same filled-circle visual language as stop.
    private var composerCancelQueuedButton: some View {
        Button {
            guard let item = nextQueuedFollowUpItem else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.removeQueuedFollowUp(item)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                .frame(width: 38, height: 38)
                .background(colorScheme == .dark ? Color.white : Color.black, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(SendButtonStyle(reduceMotion: reduceMotion))
        .disabled(model.isFollowUpMutationInProgress)
        .accessibilityLabel("Cancel next queued message")
        .accessibilityHint("Removes the message waiting at the front of the queue.")
        .accessibilityIdentifier("composer-cancel-queued")
        .transition(reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .center).combined(with: .opacity))
    }

    private var composerDictationButton: some View {
        Button {
            Task {
                await readAloudModel.stop()
                dictationPresentation = VoiceDictationPresentation()
            }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditDraft)
        .accessibilityLabel("Dictate message")
        .accessibilityHint("Records temporary audio for this LibreChat server to transcribe into an editable draft.")
        .accessibilityIdentifier("voice-dictation-button")
    }

    /// Bottom-left anchored card with every pre-send affordance, opened by
    /// the composer's "+".
    private func closeSendActionsMenu() {
        isHoldingForSendActions = false
        withAnimation(.snappy(duration: 0.16)) {
            isShowingSendActionsMenu = false
        }
    }

    /// Hold-to-send menu: the two send modes over a running response
    /// (guide it now, or queue the draft for after it finishes) appear only
    /// while the composer has text, matching ChatGPT's hold-the-send menu.
    private func showSendActionsMenu() {
        let hasDraft = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasDraft, model.canGuideCurrentResponse || model.isStreaming else { return }
        // The button under this gesture fires on release; flag the guard in
        // the send/stop actions so opening the menu never also stops or sends.
        isHoldingForSendActions = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isShowingAttachmentMenu = false
        withAnimation(.snappy(duration: 0.2)) {
            isShowingSendActionsMenu = true
        }
    }

    /// ChatGPT-style hold-the-send card: right-anchored rows with trailing
    /// dot indicators and a close circle underneath.
    private var sendActionsMenuCard: some View {
        VStack(alignment: .trailing, spacing: 14) {
            VStack(alignment: .trailing, spacing: 0) {
                if model.canGuideCurrentResponse {
                    Button {
                        closeSendActionsMenu()
                        generationSteerSelection = model.generationSteerSelection()
                    } label: {
                        sendActionsMenuRow("Guide current response")
                    }
                    .accessibilityHint("Adds a direction to the exact response currently being generated")
                    .accessibilityIdentifier("guide-current-response")

                    if model.canQueueFollowUp {
                        Divider()
                            .padding(.leading, 18)
                    }
                }

                if model.isStreaming {
                    Button {
                        closeSendActionsMenu()
                        model.queueDraftFollowUp()
                    } label: {
                        sendActionsMenuRow("Queue as next message")
                    }
                    .disabled(!model.canQueueFollowUp)
                    .accessibilityHint(
                        model.followUpQueueDisabledReason
                            ?? "Saves this text locally and sends it once after the current response completes cleanly"
                    )
                    .accessibilityIdentifier("queue-follow-up")
                }
            }
            .background(
                Color(uiColor: .systemBackground).opacity(0.94),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .adaptiveInteractiveGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 22, y: 8)

            Button {
                closeSendActionsMenu()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .background(Color.secondary.opacity(0.24), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("Close menu")
            .accessibilityIdentifier("close-send-actions")
        }
    }

    private func sendActionsMenuRow(_ title: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
            Circle()
                .fill(Color.secondary)
                .frame(width: 9, height: 9)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private var attachmentMenuCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Self.composerMenuRow("photo", "Photos")
            }
            .accessibilityLabel("Attach photo")
            .accessibilityHint("Choose a photo to include with your next request.")
            .accessibilityIdentifier("attach-photo")

            composerMenuDivider

            Button {
                requestCameraCapture()
            } label: {
                Self.composerMenuRow("camera", "Camera")
            }
            .accessibilityHint("Take a new photo and prepare it for this chat.")
            .accessibilityIdentifier("attach-camera")

            composerMenuDivider

            Button {
                isImportingFile = true
            } label: {
                Self.composerMenuRow("paperclip", "Files")
            }
            .accessibilityHint("Choose a file to include with your next request.")
            .accessibilityIdentifier("attach-file")

            if canUseSkills() || !model.selectedSkillNames.isEmpty {
                composerMenuDivider
                Button {
                    skillPickerPresentation = SkillPickerPresentation()
                } label: {
                    Self.composerMenuRow("sparkles", "Skills")
                }
                .disabled(!model.canPresentSkills)
                .accessibilityLabel("Choose Skills")
                .accessibilityValue(
                    model.selectedSkillNames.isEmpty
                        ? "None selected"
                        : "\(model.selectedSkillNames.count) selected"
                )
                .accessibilityHint(
                    model.canPresentSkills
                        ? "Choose up to 10 account and model-authorized Skills for this message."
                        : model.skillSelectionDisabledReason
                            ?? "Skills are unavailable until this chat is ready to send."
                )
                .accessibilityIdentifier("skill-picker-button")
            }

            if canUsePrompts() {
                composerMenuDivider
                Button {
                    promptLibraryPresentation = PromptLibraryPresentation()
                } label: {
                    Self.composerMenuRow("text.quote", "Prompt Library")
                }
                .disabled(!model.canEditDraft)
                .accessibilityLabel("Open prompt library")
                .accessibilityHint("Choose and review a prompt to insert into your editable draft.")
                .accessibilityIdentifier("prompt-library-button")
            }
        }
        .padding(8)
        .frame(minWidth: 248, alignment: .leading)
        .background(
            Color(uiColor: .systemBackground).opacity(0.94),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .adaptiveInteractiveGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
    }

    /// ChatGPT-style + menu row: a circular filled icon chip next to a plain
    /// label.
    private nonisolated static func composerMenuRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.24), in: Circle())
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.leading, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @MainActor
    private var composerMenuDivider: some View {
        Divider().padding(.leading, 50)
    }

    // MARK: - Conversation menu

    @ViewBuilder
    private var conversationCommandSections: some View {
        let organizer = ConversationOrganizerCommands(
            conversation: model.conversation,
            directories: menuDirectories,
            repository: repository,
            listModel: conversationListModel,
            isOffline: isOffline(),
            canUseBookmarks: canUseBookmarks(),
            onUnauthorized: onUnauthorized
        )

        Button {
            conversationToRename = model.conversation
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(isOffline() || model.conversation.id.isLocalDraft)

        Button {
            Task {
                await conversationListModel.setPinned(
                    model.conversation,
                    pinned: model.conversation.pinned != true
                )
            }
        } label: {
            Label(
                model.conversation.pinned == true ? "Unpin" : "Pin",
                systemImage: model.conversation.pinned == true ? "pin.slash" : "pin"
            )
        }
        .disabled(isOffline() || model.conversation.id.isLocalDraft)

        organizer.moveToProjectSection
        organizer.bookmarksSection

        Button {
            Task { await conversationListModel.archive(model.conversation) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .disabled(isOffline() || model.conversation.id.isLocalDraft)

        Button(role: .destructive) {
            conversationToDelete = model.conversation
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var conversationMenuLoadKey: String {
        "\(model.conversation.id.rawValue)|\(canUseBookmarks())|\(isOffline())"
    }

    // MARK: - Read aloud

    private func readAloudSelection(for message: ChatMessage) -> ReadAloudSelection? {
        guard canUseReadAloud(), !isOffline() else { return nil }
        // The projector enforces the finished-assistant-prose boundary;
        // message.plainText would also send reasoning, code, and tool
        // output to the server's TTS provider.
        return readAloudModel.selection(for: message)
    }

    private func readAloudAction(for message: ChatMessage) -> ReadAloudActionPresentation? {
        guard let selection = readAloudSelection(for: message) else { return nil }
        return readAloudModel.action(for: selection)
    }

    private var readAloudSelectionIdentities: [ReadAloudSelectionIdentity] {
        model.renderProjection.visibleEntries.compactMap { entry in
            readAloudSelection(for: entry.message)?.identity
        }
    }

    // MARK: - Scrolling

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        scrollFollowController.requestFollowBottom()
        if #available(iOS 18.0, *) {
            // Edge jump: the scroll view moves to the content's bottom edge
            // from the lazy list's estimates, never materializing the rows in
            // between. A proxy scroll to the bottom marker would lay out the
            // entire history on a long conversation.
            scrollBottomJumpToken &+= 1
        } else if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
        }
    }

    // MARK: - Camera

    private func requestCameraCapture() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraAccessIssue = CameraCaptureAccessIssue(kind: .unavailable)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPresentation = CameraCapturePresentation()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        cameraPresentation = CameraCapturePresentation()
                    } else {
                        cameraAccessIssue = CameraCaptureAccessIssue(kind: .denied)
                    }
                }
            }
        case .denied:
            cameraAccessIssue = CameraCaptureAccessIssue(kind: .denied)
        case .restricted:
            cameraAccessIssue = CameraCaptureAccessIssue(kind: .restricted)
        @unknown default:
            cameraAccessIssue = CameraCaptureAccessIssue(kind: .restricted)
        }
    }

    private func openApplicationSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    // MARK: - New chat and temporary mode

    private func startNewChatFromChat() async {
        guard !isOffline() else { return }
        await conversationListModel.loadTargets()
        // The resolved recent-target default, not blindly the first catalog
        // entry: a New Chat keeps the model or agent the user actually last
        // chose instead of resetting the selection.
        guard let option = conversationListModel.targetCatalog?.effectiveDefaultOption
            ?? conversationListModel.targetCatalog?.options.first,
            let draft = await conversationListModel.createConversation(
                  title: "New Chat",
                  target: option,
                  projectID: model.conversation.projectID
        ) else { return }
        onConversationForked(draft)
    }

    private func toggleTemporaryChat() async {
        guard !isOffline() else { return }
        await conversationListModel.loadTargets()
        let option = currentCanvasOption ?? conversationListModel.targetCatalog?.options.first
        guard let option,
              let draft = await conversationListModel.createConversation(
                  title: "New Chat",
                  target: option,
                  projectID: model.conversation.projectID,
                  isTemporary: !model.conversation.isTemporaryConversation
              ) else { return }
        if model.messages.isEmpty {
            model.replaceUnsentDraft(with: draft)
        } else {
            onConversationForked(draft)
        }
    }

    private func temporaryChatExplanation(_ policy: TemporaryChatPolicy) -> String {
        let retention = policy.retentionHours.map { " Messages expire after \($0) hours." } ?? ""
        return "Starts a fresh chat that is never saved to history.\(retention)"
    }

    // MARK: - Target dropdown

    /// The option matching the canvas' current routing, for checkmarks,
    /// brand marks, and preset saving. Identity fields (agent/assistant/spec)
    /// match first: LibreChat stores an agent conversation's underlying model
    /// and steering extras on the conversation target, so a full target
    /// fingerprint never equals the catalog's bare option.
    private var currentCanvasOption: ChatTargetOption? {
        guard let target = model.conversation.target else { return nil }
        let options = conversationListModel.availableTargets
        if let agentID = target.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agentID.isEmpty,
           let match = options.first(where: { $0.target.agentID == agentID }) {
            return match
        }
        if let assistantID = target.assistantID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !assistantID.isEmpty,
           let match = options.first(where: { $0.target.assistantID == assistantID }) {
            return match
        }
        if let spec = target.spec?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spec.isEmpty,
           let match = options.first(where: { $0.target.spec == spec }) {
            return match
        }
        guard let fingerprint = try? FollowUpTargetFingerprint(target: target) else { return nil }
        return options.first { (try? FollowUpTargetFingerprint(target: $0.target)) == fingerprint }
    }

    /// The pill names the selected agent or assistant by its real name —
    /// resolved from the same catalog that supplies its brand mark — and
    /// falls back to the model's generic label only while the catalog has no
    /// matching entry (offline, or the entity was deleted server-side).
    private var executionRoutesToNamedAgent: Bool {
        model.executionSelectedAgentOrAssistant != nil
    }

    private var executionAgentOrAssistantLabel: String? {
        guard executionRoutesToNamedAgent else { return nil }
        if let option = currentCanvasOption,
           option.target.agentID != nil || option.target.assistantID != nil {
            return option.label
        }
        return model.executionSelectedAgentOrAssistant
    }

    /// Large brand mark for the blank canvas.
    @ViewBuilder
    private func canvasBrandIcon(for option: ChatTargetOption) -> some View {
        EndpointBrandIcon(
            endpoint: option.target.endpoint,
            model: option.target.model,
            iconURL: option.iconURL,
            iconEndpoint: option.iconEndpoint,
            size: 96
        )
        .accessibilityHidden(true)
    }

    /// Starts a new chat with the chosen target, leaving this conversation
    /// unchanged.
    private func startChat(with option: ChatTargetOption) {
        Task {
            guard let draft = await conversationListModel.createConversation(
                title: "New Chat",
                target: option,
                projectID: model.conversation.projectID,
                isTemporary: model.conversation.isTemporaryConversation
            ) else { return }
            if model.messages.isEmpty {
                model.replaceUnsentDraft(with: draft)
            } else {
                onConversationForked(draft)
            }
        }
    }

    /// Anchored dropdown layer: a scrim plus the provider/preset cards that
    /// hang directly under the top bar like real dropdown menus.
    @ViewBuilder
    private var dropdownLayer: some View {
        ZStack(alignment: .top) {
            if isShowingTargetDropdown || isShowingPresetDropdown {
                // Invisible tap-outside catcher: no background dim, matching
                // ChatGPT, which leaves the page untouched behind its menus.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { dismissDropdowns() }
                    .accessibilityLabel("Close menu")
                    .accessibilityAddTraits(.isButton)
            }

            if isShowingTargetDropdown {
                TargetDropdownCard(
                    providers: targetDropdownProviders,
                    selectedProvider: $targetDropdownProvider,
                    currentOptionID: currentCanvasOption?.id,
                    isLoading: conversationListModel.isLoadingTargets,
                    errorMessage: conversationListModel.targetError,
                    maximumHeight: dropdownMaximumHeight,
                    retry: { Task { await conversationListModel.loadTargets(forceRefresh: true) } },
                    start: { option in
                        dismissDropdowns()
                        isShowingAttachmentMenu = false
                        startChat(with: option)
                    }
                )
                .transition(reduceMotion ? .opacity : dropdownCardTransition)
                .offset(y: 6)
            }

            if isShowingPresetDropdown {
                PresetDropdownCard(
                    presets: conversationListModel.availablePresets,
                    isLoading: conversationListModel.isLoadingPresets,
                    canSave: conversationListModel.canCreatePresets && currentCanvasOption != nil,
                    maximumHeight: dropdownMaximumHeight,
                    apply: { preset in
                        dismissDropdowns()
                        Task {
                            guard let conversation = await conversationListModel.createConversation(
                                title: preset.title,
                                preset: preset
                            ) else { return }
                            // The include-and-replace path keeps list
                            // reconciliation consistent with the pencil flow.
                            onConversationForked(conversation)
                        }
                    },
                    saveCurrent: {
                        dismissDropdowns()
                        if let option = currentCanvasOption {
                            presetCreationSelection = ChatPresetCreationSelection(target: option)
                        }
                    }
                )
                .transition(reduceMotion ? .opacity : dropdownCardTransition)
                .offset(y: 6)
            }
        }
    }

    private func refreshTargetDropdownSnapshot() {
        guard isShowingTargetDropdown, targetDropdownProvider == nil else { return }
        targetDropdownProviders = TargetProviderGroup.build(
            from: conversationListModel.availableTargets
        )
    }

    /// Screen-aware ceiling for the anchored dropdown cards. The message
    /// viewport already excludes the composer and the keyboard, so the cards
    /// shrink (and their lists scroll) on reduced viewports instead of
    /// overflowing past the composer.
    private var dropdownMaximumHeight: CGFloat {
        if chatViewportHeight > 0 {
            return max(180, chatViewportHeight - 16)
        }
        // Before the first viewport measurement (loading states), fall back
        // to a conservative fraction of the screen.
        return min(320, UIScreen.main.bounds.height * 0.34)
    }

    private var dropdownCardTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
    }

    private func dismissDropdowns() {
        withAnimation(.easeIn(duration: 0.14)) {
            isShowingTargetDropdown = false
            isShowingPresetDropdown = false
            targetDropdownProvider = nil
        }
    }
}

private struct UploadChip: View {
    let upload: PendingUpload
    let cancel: () -> Void
    let retry: () -> Void
    let reconcile: () -> Void

    @State private var thumbnail: UIImage?

    /// Human-readable size when the server reported one, keeping the card's
    /// second line informative without another layout pass.
    private var sizeLine: String? {
        guard let bytes = upload.remoteFile?.bytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 34, height: 34)
                .background(thumbnail == nil ? Color.secondary.opacity(0.16) : Color.clear, in: Circle())
                .task(id: upload.localURL) {
                    guard thumbnail == nil,
                          upload.width != nil, upload.height != nil else { return }
                    // A highly compressed staged image can decompress to
                    // hundreds of MB at full resolution; the chip renders at
                    // ~34pt, so decode a pixel-limited thumbnail instead.
                    guard let source = CGImageSourceCreateWithURL(upload.localURL as CFURL, nil) else { return }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 240,
                    ]
                    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
                    thumbnail = UIImage(cgImage: cgImage)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(upload.filename)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            trailingControl
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 210, maxWidth: 300)
        .background(
            Color(uiColor: .systemBackground).opacity(0.94),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .composerChrome(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attachment \(upload.filename)")
        .accessibilityValue(statusLine)
    }

    private var statusLine: String {
        switch upload.state {
        case .staged:
            return "Preparing…"
        case .uploading:
            if let sizeLine {
                return "\(sizeLine) · Uploading…"
            }
            return "Uploading…"
        case .completed:
            return sizeLine ?? "Attached"
        case .failed:
            return "Upload failed"
        case .deliveryUncertain:
            return "Delivery uncertain"
        case .attached, .queued, .cancelled:
            return sizeLine ?? "Attached"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
                .overlay {
                    if upload.state == .uploading {
                        // The determinate ring stays readable over the image.
                        ZStack {
                            Circle().fill(Color(uiColor: .systemBackground).opacity(0.6))
                            ProgressView(value: max(0.02, upload.progress))
                                .progressViewStyle(.circular)
                                .tint(.primary)
                        }
                    }
                }
                .accessibilityHidden(true)
        } else {
            glyphStatusIcon
        }
    }

    @ViewBuilder
    private var glyphStatusIcon: some View {
        switch upload.state {
        case .uploading:
            // Real progress: a determinate ring driven by the transport's
            // byte counts — not a looping placeholder spinner.
            ProgressView(value: max(0.02, upload.progress))
                .progressViewStyle(.circular)
                .tint(.primary)
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        case .deliveryUncertain:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .staged:
            Image(systemName: "doc")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        case .attached, .queued, .cancelled:
            Image(systemName: "doc")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch upload.state {
        case .failed:
            Button("Retry", action: retry)
                .font(.caption.weight(.medium))
        case .deliveryUncertain:
            Button("Check", action: reconcile)
                .font(.caption.weight(.medium))
                .accessibilityHint("Checks LibreChat for the original upload without sending the file again.")
        case .staged, .uploading, .completed, .attached, .queued, .cancelled:
            if upload.state == .staged || upload.state == .uploading
                || upload.state == .deliveryUncertain {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(
                    upload.state == .deliveryUncertain
                        ? "Remove uncertain \(upload.filename) attachment"
                        : "Cancel \(upload.filename) upload"
                )
            }
        }
    }
}

/// A self-dismissing notice capsule floating above the composer. Used for
/// transient rejections only — persistent errors keep their own strip.
struct ChatTransientToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            Color(uiColor: .systemBackground).opacity(0.94),
            in: Capsule()
        )
        .adaptiveInteractiveGlass(in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityIdentifier("chat-transient-toast")
    }
}

struct PendingInteractionView: View {
    let interaction: PendingInteraction
    let isResponding: Bool
    let respond: ([ToolApprovalResolution]?, String?, [String: String]?) -> Void
    @State private var answer = ""
    @State private var singleSelections: Set<String> = []
    @State private var batchAnswers: [String: String] = [:]
    @State private var batchSelections: [String: Set<String>] = [:]
    @State private var toolDecisions: [String: ToolApprovalDecision] = [:]
    @State private var editedArguments: [String: String] = [:]
    @State private var responseTexts: [String: String] = [:]
    @State private var rejectionReasons: [String: String] = [:]

    var body: some View {
        Group {
            switch interaction {
            case let .toolApproval(request):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Approval required: \(request.toolName)", systemImage: "hand.raised")
                        .font(.headline)
                    if request.isExpired() {
                        Text("This approval has expired. Resume the generation to check its current status.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Check status") { respond(nil, nil, nil) }
                            .buttonStyle(.bordered)
                    } else if let items = request.items,
                              !items.isEmpty,
                              items.allSatisfy({ $0.arguments != nil && !$0.allowedDecisions.isEmpty }) {
                        ForEach(items) { item in
                            toolApprovalItem(item)
                        }
                        Button(items.count == 1 ? "Submit decision" : "Submit \(items.count) decisions") {
                            respond(resolutions(for: items), nil, nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(resolutions(for: items) == nil)
                        .accessibilityHint("Submits one decision for every disclosed tool call")
                    } else {
                        Text("This approval does not disclose enough information for a safe native decision. Open this conversation in LibreChat’s web client.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            case let .userQuestion(question):
                VStack(alignment: .leading, spacing: 8) {
                    if question.isExpired() {
                        Text("This question has expired. Check LibreChat before answering again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Check status") { respond(nil, nil, nil) }
                            .buttonStyle(.bordered)
                    } else if let items = question.items, !items.isEmpty {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                if let header = item.header {
                                    Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                                Text(item.prompt).font(.headline)
                                if let detail = item.detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                                if item.options.isEmpty {
                                    TextField("Answer", text: batchAnswerBinding(for: item), axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Answer \(item.prompt)")
                                } else {
                                    ForEach(item.options, id: \.self) { option in
                                        Button {
                                            select(option, for: item)
                                        } label: {
                                            Label(
                                                option,
                                                systemImage: isSelected(option, for: item)
                                                    ? "checkmark.circle.fill"
                                                    : "circle"
                                            )
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityValue(isSelected(option, for: item) ? "Selected" : "Not selected")
                                        .accessibilityAddTraits(isSelected(option, for: item) ? .isSelected : [])
                                    }
                                    TextField("Or type an answer", text: batchAnswerBinding(for: item), axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("Custom answer for \(item.prompt)")
                                }
                            }
                        }
                        Button("Submit answers") { respond(nil, nil, resolvedBatchAnswers(for: items)) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!batchIsComplete(items))
                    } else {
                        Text(question.prompt).font(.headline)
                        if let detail = question.detail {
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(question.options, id: \.self) { option in
                            Button {
                                select(option, for: question)
                            } label: {
                                Label(
                                    option,
                                    systemImage: singleSelections.contains(option)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                            }
                            .buttonStyle(.bordered)
                            .accessibilityValue(singleSelections.contains(option) ? "Selected" : "Not selected")
                            .accessibilityAddTraits(singleSelections.contains(option) ? .isSelected : [])
                        }
                        TextField(question.options.isEmpty ? "Answer" : "Or type an answer", text: $answer, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Answer \(question.prompt)")
                            .onChange(of: answer) { _, value in
                                if question.allowsMultipleSelection != true,
                                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    singleSelections = []
                                }
                            }
                        Button("Submit") { respond(nil, resolvedAnswer(for: question), nil) }
                            .buttonStyle(.borderedProminent)
                            .disabled(resolvedAnswer(for: question).isEmpty)
                    }
                }
            case let .externalAuthentication(request):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Connect \(request.serviceName)", systemImage: "person.badge.key")
                        .font(.headline)
                    Text("This server action does not provide a profile-bound native authentication flow. Continue from the LibreChat web client.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(isResponding)
        .overlay {
            if isResponding {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Submitting response")
            }
        }
    }

    @ViewBuilder
    private func toolApprovalItem(_ item: ToolApprovalItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name).font(.headline)
            if let summary = item.summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            if let arguments = item.arguments {
                DisclosureGroup("Arguments") {
                    Text(arguments)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    ForEach(item.allowedDecisions, id: \.self) { decision in
                        toolDecisionButton(decision, item: item)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.allowedDecisions, id: \.self) { decision in
                        toolDecisionButton(decision, item: item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tool-decision-controls-\(item.id)")
            switch toolDecisions[item.id] {
            case .edit:
                TextField("Edited arguments as a JSON object", text: dictionaryBinding($editedArguments, key: item.id), axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            case .respond:
                TextField("Tool response", text: dictionaryBinding($responseTexts, key: item.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            case .reject:
                TextField("Reason (optional)", text: dictionaryBinding($rejectionReasons, key: item.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            default:
                EmptyView()
            }
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool call \(item.name)")
    }

    private func dictionaryBinding(
        _ dictionary: Binding<[String: String]>,
        key: String
    ) -> Binding<String> {
        Binding(
            get: { dictionary.wrappedValue[key] ?? "" },
            set: { dictionary.wrappedValue[key] = $0 }
        )
    }

    @ViewBuilder
    private func toolDecisionButton(
        _ decision: ToolApprovalDecision,
        item: ToolApprovalItem
    ) -> some View {
        Button(decisionLabel(decision)) {
            toolDecisions[item.id] = toolDecisions[item.id] == decision ? nil : decision
            if decision == .edit, editedArguments[item.id] == nil {
                editedArguments[item.id] = item.arguments ?? "{}"
            }
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityValue(toolDecisions[item.id] == decision ? "Selected" : "Not selected")
        .accessibilityAddTraits(toolDecisions[item.id] == decision ? .isSelected : [])
    }

    private func decisionLabel(_ decision: ToolApprovalDecision) -> String {
        switch decision {
        case .approve: "Approve"
        case .reject: "Reject"
        case .edit: "Edit arguments"
        case .respond: "Respond"
        }
    }

    private func resolutions(for items: [ToolApprovalItem]) -> [ToolApprovalResolution]? {
        let values = items.compactMap { item -> ToolApprovalResolution? in
            guard let decision = toolDecisions[item.id],
                  item.allowedDecisions.contains(decision) else { return nil }
            switch decision {
            case .approve:
                return ToolApprovalResolution(toolCallID: item.id, decision: .approve)
            case .reject:
                return ToolApprovalResolution(
                    toolCallID: item.id,
                    decision: .reject,
                    reason: nonEmpty(rejectionReasons[item.id])
                )
            case .respond:
                guard let response = nonEmpty(responseTexts[item.id]) else { return nil }
                return ToolApprovalResolution(
                    toolCallID: item.id,
                    decision: .respond,
                    responseText: response
                )
            case .edit:
                guard let raw = nonEmpty(editedArguments[item.id]),
                      let data = raw.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data),
                      value is [String: Any] else { return nil }
                return ToolApprovalResolution(
                    toolCallID: item.id,
                    decision: .edit,
                    editedArgumentsJSON: raw
                )
            }
        }
        return values.count == items.count ? values : nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func batchAnswerBinding(for item: UserQuestionItem) -> Binding<String> {
        Binding(
            get: { batchAnswers[item.id] ?? "" },
            set: { value in
                batchAnswers[item.id] = value
                if !item.allowsMultipleSelection,
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    batchSelections[item.id] = []
                }
            }
        )
    }

    private func select(_ option: String, for item: UserQuestionItem) {
        if item.allowsMultipleSelection {
            var selected = batchSelections[item.id] ?? []
            if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
            batchSelections[item.id] = selected
        } else {
            batchSelections[item.id] = [option]
            batchAnswers[item.id] = ""
        }
    }

    private func isSelected(_ option: String, for item: UserQuestionItem) -> Bool {
        if item.allowsMultipleSelection {
            return batchSelections[item.id]?.contains(option) == true
        }
        return batchSelections[item.id]?.contains(option) == true
    }

    private func resolvedBatchAnswers(for items: [UserQuestionItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            if item.allowsMultipleSelection {
                var values = item.options
                    .filter { batchSelections[item.id]?.contains($0) == true }
                    .map { item.optionValues[$0] ?? $0 }
                let text = batchAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { values.append(text) }
                return (item.id, values.joined(separator: ", "))
            }
            let text = batchAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return (item.id, text) }
            guard let option = item.options.first(where: {
                batchSelections[item.id]?.contains($0) == true
            }) else { return (item.id, "") }
            return (item.id, item.optionValues[option] ?? option)
        })
    }

    private func batchIsComplete(_ items: [UserQuestionItem]) -> Bool {
        resolvedBatchAnswers(for: items).values.allSatisfy { !$0.isEmpty }
    }

    private func select(_ option: String, for question: UserQuestion) {
        if question.allowsMultipleSelection == true {
            if singleSelections.contains(option) {
                singleSelections.remove(option)
            } else {
                singleSelections.insert(option)
            }
        } else {
            singleSelections = [option]
            answer = ""
        }
    }

    private func resolvedAnswer(for question: UserQuestion) -> String {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.allowsMultipleSelection == true {
            var values = question.options
                .filter(singleSelections.contains)
                .map { question.optionValues[$0] ?? $0 }
            if !text.isEmpty { values.append(text) }
            return values.joined(separator: ", ")
        }
        if !text.isEmpty { return text }
        guard let option = question.options.first(where: singleSelections.contains) else { return "" }
        return question.optionValues[option] ?? option
    }
}

private struct SkillPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatModel
    @State private var query = ""
    @State private var selection: [String]

    init(model: ChatModel, initialSelection: [String]) {
        self.model = model
        _selection = State(initialValue: initialSelection)
    }

    private var filteredSkills: [ChatSkillSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.availableSkills }
        return model.availableSkills.filter { skill in
            skill.displayTitle.lowercased().contains(needle)
                || skill.name.lowercased().contains(needle)
                || skill.description.lowercased().contains(needle)
                || skill.category?.lowercased().contains(needle) == true
        }
    }

    private var selectionIsValid: Bool {
        guard !model.isLoadingSkills else { return false }
        guard let catalog = model.skillCatalog, catalog.isComplete else {
            return selection.isEmpty
        }
        return (try? catalog.validatedSelection(selection)) != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoadingSkills && model.availableSkills.isEmpty {
                    ProgressView("Checking Skills access…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.skillCatalogError,
                          model.availableSkills.isEmpty {
                    ContentUnavailableView {
                        Label("Skills unavailable", systemImage: "wand.and.stars")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await model.refreshSkillCatalog() }
                        }
                    }
                } else if filteredSkills.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        if let error = model.skillCatalogError {
                            Section {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("skill-catalog-warning")
                            }
                        }

                        Section {
                            ForEach(filteredSkills) { skill in
                                let isSelected = selection.contains(skill.name)
                                SkillPickerRow(
                                    skill: skill,
                                    isSelected: isSelected,
                                    isAtLimit: selection.count >= 10
                                ) {
                                    if let index = selection.firstIndex(of: skill.name) {
                                        selection.remove(at: index)
                                    } else if selection.count < 10 {
                                        selection.append(skill.name)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search Skills")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if model.replaceSelectedSkills(selection) { dismiss() }
                    }
                    .disabled(!selectionIsValid)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("\(selection.count) of 10 selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("skill-selection-count")
            }
            .task { await model.refreshSkillCatalog() }
        }
        .accessibilityIdentifier("skill-picker-sheet")
    }
}

private struct SkillPickerRow: View {
    let skill: ChatSkillSummary
    let isSelected: Bool
    let isAtLimit: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .frame(width: 28)
                    .frame(minHeight: 44, alignment: .top)
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.displayTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(skill.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    metadata
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!SkillPickerInteractionPolicy.canToggle(
            isSelected: isSelected,
            isSelectable: skill.availability.isSelectable,
            isAtLimit: isAtLimit
        ))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("skill-option-\(skill.name)")
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(skill.name).monospaced()
            if skill.alwaysApply { Text("Always applied") }
            if let reason = skill.availability.explanation { Text(reason) }
        }
        .font(.caption)
        .foregroundStyle(skill.availability.isSelectable ? Color.secondary : .orange)
    }

    private var accessibilityHint: String {
        if isSelected {
            if let explanation = skill.availability.explanation {
                return "Removes this Skill from the message. \(explanation)."
            }
            return "Removes this Skill from the message"
        }
        return skill.availability.explanation ?? "Adds this Skill to the message"
    }
}

struct SkillPickerInteractionPolicy {
    static func canToggle(
        isSelected: Bool,
        isSelectable: Bool,
        isAtLimit: Bool
    ) -> Bool {
        isSelected || (isSelectable && !isAtLimit)
    }
}

enum ArtifactWorkspacePresentationMode: Equatable {
    case navigation
    case inspector

    init(isPhone: Bool) {
        self = isPhone ? .navigation : .inspector
    }
}

private struct ArtifactWorkspacePresentationModifier<Workspace: View>: ViewModifier {
    @Binding var selection: ArtifactWorkspaceSelection?
    let mode: ArtifactWorkspacePresentationMode
    private let workspace: (ArtifactWorkspaceSelection, Bool) -> Workspace

    init(
        selection: Binding<ArtifactWorkspaceSelection?>,
        mode: ArtifactWorkspacePresentationMode,
        @ViewBuilder workspace: @escaping (ArtifactWorkspaceSelection, Bool) -> Workspace
    ) {
        _selection = selection
        self.mode = mode
        self.workspace = workspace
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if mode == .navigation {
            content.navigationDestination(item: $selection) { selection in
                workspace(selection, false)
                    .id(selection.id)
            }
        } else {
            content.inspector(isPresented: inspectorIsPresented) {
                if let selection {
                    NavigationStack {
                        workspace(selection, true)
                            .id(selection.id)
                    }
                    .inspectorColumnWidth(min: 340, ideal: 460, max: 640)
                }
            }
        }
    }

    private var inspectorIsPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { isPresented in
                if !isPresented { selection = nil }
            }
        )
    }
}

private struct BranchSiblingControl: View {
    let entry: MessageTree.BranchEntry
    let select: (MessageID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                select(entry.siblings[entry.selectedIndex - 1].id)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(entry.selectedIndex == 0)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Previous branch")

            Text("\(entry.selectedIndex + 1) / \(entry.siblings.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Branch \(entry.selectedIndex + 1) of \(entry.siblings.count)"
                )

            Button {
                select(entry.siblings[entry.selectedIndex + 1].id)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(entry.selectedIndex == entry.siblings.count - 1)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Next branch")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom"
    static let coordinateSpace = "chat-scroll-space"
}

/// Owns the scroll-follow policy off the view's observation graph. Scroll
/// geometry callbacks fire at frame rate; `ChatScrollFollowState` is a plain
/// value so mutating it through this controller never invalidates the view.
/// Only a genuine flip of "following bottom" is surfaced, through
/// `onFollowStateChanged`, for UI that must react (the jump-to-latest button).
@MainActor
final class ChatScrollFollowController {
    private(set) var state = ChatScrollFollowState()
    var onFollowStateChanged: ((Bool) -> Void)?
    private var lastReportedFollowing: Bool

    init() {
        lastReportedFollowing = state.isFollowingBottom
    }

    var shouldFollowContent: Bool {
        state.shouldFollowContent
    }

    func beginUserInteraction() {
        mutate { $0.beginUserInteraction() }
    }

    func endUserInteraction() {
        mutate { $0.endUserInteraction() }
    }

    func requestFollowBottom() {
        mutate { $0.requestFollowBottom() }
    }

    func suspendFollowing() {
        mutate { $0.suspendFollowing() }
    }

    func updateViewportHeight(_ height: CGFloat) {
        mutate { $0.updateViewportHeight(height) }
    }

    func updateBottomOffset(_ offset: CGFloat) {
        mutate { $0.updateBottomOffset(offset) }
    }

    func updateDistanceFromBottom(_ distance: CGFloat) {
        mutate { $0.updateDistanceFromBottom(distance) }
    }

    private func mutate(_ change: (inout ChatScrollFollowState) -> Void) {
        change(&state)
        if state.isFollowingBottom != lastReportedFollowing {
            lastReportedFollowing = state.isFollowingBottom
            onFollowStateChanged?(state.isFollowingBottom)
        }
    }
}

/// Pure follow/suspend policy for a streaming chat scroll view.
///
/// Automatic content growth gets a generous tolerance so a newly wrapped line
/// does not detach the view. Once the user interacts, following stops
/// immediately and resumes only when they deliberately return to the bottom.
struct ChatInitialPositioningState: Equatable {
    private(set) var hasPositioned = false

    mutating func beginInitialPositioningIfNeeded() -> Bool {
        guard !hasPositioned else { return false }
        hasPositioned = true
        return true
    }

    mutating func recordExplicitFocus() {
        hasPositioned = true
    }
}

struct ChatScrollFollowState: Equatable {
    private static let automaticTolerance: CGFloat = 96
    private static let userResumeTolerance: CGFloat = 12

    private(set) var isFollowingBottom = true
    private(set) var isUserInteracting = false
    private var isExternalFocusSuspended = false
    private var viewportHeight: CGFloat = 0
    private var bottomOffset: CGFloat = 0

    var shouldFollowContent: Bool {
        isFollowingBottom && !isUserInteracting
    }

    mutating func updateViewportHeight(_ height: CGFloat) {
        viewportHeight = height
        reconcileGeometry()
    }

    mutating func updateBottomOffset(_ offset: CGFloat) {
        bottomOffset = offset
        reconcileGeometry()
    }

    mutating func updateDistanceFromBottom(_ distance: CGFloat) {
        bottomOffset = viewportHeight + max(0, distance)
        reconcileGeometry()
    }

    mutating func beginUserInteraction() {
        isExternalFocusSuspended = false
        isUserInteracting = true
        isFollowingBottom = false
    }

    mutating func endUserInteraction() {
        guard isUserInteracting else { return }
        isUserInteracting = false
        isFollowingBottom = distanceFromBottom <= Self.userResumeTolerance
    }

    mutating func requestFollowBottom() {
        isExternalFocusSuspended = false
        isUserInteracting = false
        isFollowingBottom = true
    }

    mutating func suspendFollowing() {
        isExternalFocusSuspended = true
        isUserInteracting = false
        isFollowingBottom = false
    }

    private var distanceFromBottom: CGFloat {
        max(0, bottomOffset - viewportHeight)
    }

    private mutating func reconcileGeometry() {
        guard viewportHeight > 0,
              !isUserInteracting,
              !isExternalFocusSuspended else { return }
        if isFollowingBottom {
            isFollowingBottom = distanceFromBottom <= Self.automaticTolerance
        } else if distanceFromBottom <= Self.userResumeTolerance {
            isFollowingBottom = true
        }
    }
}

private struct ChatScrollGeometryModifier: ViewModifier {
    let changed: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { _, distanceFromBottom in
                changed(distanceFromBottom)
            }
        } else {
            content
        }
    }
}

/// iOS 18+ bottom jumps request the scroll view's bottom edge through a
/// `ScrollPosition`, which positions from the lazy list's estimates instead of
/// resolving a row identity (a `ScrollViewReader` marker scroll would
/// materialize every row between the viewport and the marker). Bumping `token`
/// requests a jump; the position state lives inside the modifier so call sites
/// don't need the iOS 18 type. iOS 17 keeps the marker fallback.
@available(iOS 18.0, *)
private struct ChatBottomEdgeJumpModifier: ViewModifier {
    let token: Int
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: token) {
                position.scrollTo(edge: .bottom)
            }
    }
}

private struct ChatBottomEdgeJumpGate: ViewModifier {
    let token: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(ChatBottomEdgeJumpModifier(token: token))
        } else {
            content
        }
    }
}

/// Emits the bottom-marker offset for the iOS 17 follow fallback only. On
/// iOS 18+ the distance-from-bottom comes from `onScrollGeometryChange`, and
/// skipping the per-layout preference emission keeps scroll frames free of
/// preference reduction work.
private struct ChatBottomOffsetPreferenceEmitter: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #unavailable(iOS 18.0) {
            content.background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatBottomOffsetPreferenceKey.self,
                        value: geometry.frame(in: .named(ChatScrollAnchor.coordinateSpace)).maxY
                    )
                }
            }
        } else {
            content
        }
    }
}

private struct ChatScrollInteractionModifier: ViewModifier {
    let began: () -> Void
    let ended: () -> Void
    @State private var fallbackInteractionIsActive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            dragAware(content)
                .onScrollPhaseChange { _, phase in
                    switch phase {
                    case .tracking, .interacting, .decelerating:
                        beginInteractionIfNeeded()
                    case .idle:
                        endInteractionIfNeeded()
                    case .animating:
                        break
                    @unknown default:
                        break
                    }
                }
        } else {
            dragAware(content)
        }
    }

    private func dragAware(_ content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { _ in beginInteractionIfNeeded() }
                .onEnded { _ in endInteractionIfNeeded() }
        )
    }

    private func beginInteractionIfNeeded() {
        guard !fallbackInteractionIsActive else { return }
        fallbackInteractionIsActive = true
        began()
    }

    private func endInteractionIfNeeded() {
        guard fallbackInteractionIsActive else { return }
        fallbackInteractionIsActive = false
        ended()
    }
}

private struct ChatBottomOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Selection payload for saving the current canvas setup as a preset.
struct ChatPresetCreationSelection: Identifiable {
    let id = UUID()
    let target: ChatTargetOption
}

/// A real dropdown card anchored under the top bar: page one is a quiet list
/// of providers (configured specs, Agents, endpoints); selecting one slides
/// — inside the same card — to page two with that provider's models only.
struct TargetDropdownCard: View {
    let providers: [TargetProviderGroup]
    @Binding var selectedProvider: TargetProviderGroup?
    @State private var isBackingOut = false
    let currentOptionID: ChatTargetOption.ID?
    let isLoading: Bool
    let errorMessage: String?
    /// Screen-aware ceiling supplied by the presenting surface: never taller
    /// than the visible viewport above the composer (keyboard included), so
    /// the card scrolls internally instead of overflowing.
    var maximumHeight: CGFloat = 320
    let retry: () -> Void
    var isPinned: @MainActor (ChatTargetOption) -> Bool = { _ in false }
    var togglePin: @MainActor (ChatTargetOption) -> Void = { _ in }
    let start: @MainActor (ChatTargetOption) -> Void

    var body: some View {
        ZStack {
            if let provider = selectedProvider {
                providerPage(provider)
                    // Slides in from the trailing edge going deeper and slides
                    // back out the same way, mirroring a navigation pop.
                    .transition(
                        .move(edge: .trailing)
                            .combined(with: .opacity)
                    )
            } else {
                providerListPage
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: selectedProvider)
        .frame(width: 348)
        .frame(height: cardHeight)
        .background(
            Color(uiColor: .systemBackground).opacity(0.94),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .adaptiveInteractiveGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .accessibilityIdentifier("target-dropdown")
        // Mobile back gesture, one-way only: a horizontal left→right drag on
        // a nested provider page pops back to the provider list. The reverse
        // direction is deliberately not a gesture, and vertical scrolling and
        // row taps are untouched (the drag must be horizontal-dominant and
        // travel a real distance before it is recognized).
        .simultaneousGesture(swipeBackGesture)
    }

    private var swipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                // Inert on the provider list page; the guard keeps the
                // gesture harmless on page one.
                guard selectedProvider != nil else { return }
                guard abs(value.translation.width) > abs(value.translation.height),
                      value.translation.width > 56 else { return }
                guard !isBackingOut else { return }
                isBackingOut = true
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    selectedProvider = nil
                } completion: {
                    isBackingOut = false
                }
            }
    }

    /// Hugs the provider/model list: 42pt rows plus padding, floored so an
    /// empty or loading card keeps its shape, and capped by the live
    /// viewport height so long catalogs scroll inside the card.
    private var cardHeight: CGFloat {
        let rowHeight: CGFloat = 42
        let listPadding: CGFloat = 16
        let pageHeader: CGFloat = 52
        if isLoading && providers.isEmpty {
            return min(6 * rowHeight + listPadding, maximumHeight)
        }
        if let provider = selectedProvider {
            let listHeight = min(
                CGFloat(provider.options.count) * rowHeight + listPadding,
                maximumHeight - pageHeader
            )
            return listHeight + pageHeader
        }
        return min(max(CGFloat(providers.count) * rowHeight + listPadding, 112), maximumHeight)
    }

    @ViewBuilder
    private var providerListPage: some View {
        if isLoading && providers.isEmpty {
            SkeletonListView(
                count: 6,
                rowHeight: 42,
                horizontalPadding: 18,
                accessibilityLabel: "Loading models and agents"
            )
        } else if let errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again", action: retry)
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 14)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(providers) { provider in
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                selectedProvider = provider
                            }
                        } label: {
                            ProviderRow(provider: provider)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 42, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(DropdownRowButtonStyle())
                        .accessibilityIdentifier("target-provider-\(provider.id)")
                        .accessibilityHint("Shows the models for \(provider.name).")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private func providerPage(_ provider: TargetProviderGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    guard !isBackingOut else { return }
                    isBackingOut = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        selectedProvider = nil
                    } completion: {
                        isBackingOut = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.fill.quaternary, in: Circle())
                        .opacity(isBackingOut ? 0 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to providers")
                .accessibilityIdentifier("target-dropdown-back")
                // The provider page carries its own branding in the header —
                // the same icon chain as the provider row, at row scale.
                providerHeaderIcon(provider)
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
            Divider()
                .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(provider.options) { option in
                        Button {
                            start(option)
                        } label: {
                            ChatTargetOptionRow(
                                option: option,
                                category: provider.category,
                                isSelected: option.id == currentOptionID
                            )
                            .padding(.horizontal, 12)
                            .frame(minHeight: 42, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DropdownRowButtonStyle())
                        .contextMenu {
                            Button {
                                togglePin(option)
                            } label: {
                                Label(
                                    isPinned(option) ? "Unpin" : "Pin to top of chats",
                                    systemImage: isPinned(option) ? "pin.slash" : "pin"
                                )
                            }
                        }
                        .accessibilityIdentifier("target-option-\(option.id)")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The provider's own mark (image URL / endpoint glyph chain) in the
    /// nested page header; a rounded system glyph stands in when the group
    /// has no resolvable brand (the Agents library, for instance).
    @ViewBuilder
    private func providerHeaderIcon(_ provider: TargetProviderGroup) -> some View {
        if provider.iconURL != nil || provider.iconEndpoint != nil {
            EndpointBrandIcon(
                endpoint: nil,
                model: nil,
                iconURL: provider.iconURL,
                iconEndpoint: provider.iconEndpoint,
                size: 20
            )
        } else {
            Image(systemName: provider.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.55), in: Circle())
        }
    }
}

/// Shared pressed-row highlight for dropdown rows: a quiet fill instead of
/// SwiftUI's default opacity flash.
struct DropdownRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
            )
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

/// Compact preset dropdown: apply a saved preset to a new chat, or save the
/// current setup as one.
struct PresetDropdownCard: View {
    let presets: [ChatPreset]
    let isLoading: Bool
    let canSave: Bool
    /// Screen-aware ceiling, matching the target dropdown card.
    var maximumHeight: CGFloat = 328
    let apply: @MainActor (ChatPreset) -> Void
    let saveCurrent: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Presets")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(presets.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            Group {
                if isLoading && presets.isEmpty {
                    SkeletonListView(
                        count: 5,
                        rowHeight: 44,
                        horizontalPadding: 14,
                        accessibilityLabel: "Loading presets"
                    )
                } else if presets.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .foregroundStyle(.secondary)
                        Text("No saved presets")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(presets) { preset in
                                Button {
                                    apply(preset)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(preset.title)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if let target = preset.target, let model = target.model, !model.isEmpty {
                                                Text(model)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8)
                                    .frame(minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("preset-option-\(preset.id.rawValue)")
                                .accessibilityHint("Starts a new chat with this preset.")
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                }
            }
            Divider()
            Button(action: saveCurrent) {
                Label("Save this setup as a preset", systemImage: "bookmark.badge.plus")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("preset-save-current")
            .accessibilityHint("Saves the current model or agent and instructions as a new preset.")
        }
        .frame(width: 312)
        .frame(minHeight: 200, maxHeight: maximumHeight)
        .background(
            Color(uiColor: .systemBackground).opacity(0.94),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .adaptiveInteractiveGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .accessibilityIdentifier("preset-dropdown")
    }
}

/// Rename alert and delete confirmation for the chat screen's conversation
/// commands, kept out of the main body so its expression stays type-checkable.
private struct ChatRenameAndDeletePresentations: ViewModifier {
    @Binding var conversationToRename: LibreChatDomain.Conversation?
    @Binding var renameTitle: String
    @Binding var conversationToDelete: LibreChatDomain.Conversation?
    let rename: @MainActor (LibreChatDomain.Conversation, String) -> Void
    let delete: @MainActor (LibreChatDomain.Conversation) -> Void

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", isPresented: Binding(
                get: { conversationToRename != nil },
                set: { if !$0 { conversationToRename = nil } }
            )) {
                TextField("Title", text: $renameTitle)
                Button("Cancel", role: .cancel) { conversationToRename = nil }
                Button("Save") {
                    guard let conversation = conversationToRename else { return }
                    conversationToRename = nil
                    rename(conversation, renameTitle)
                }
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("The new title will be saved to this LibreChat server.")
            }
            .confirmationDialog(
                "Delete this conversation?",
                isPresented: Binding(
                    get: { conversationToDelete != nil },
                    set: { if !$0 { conversationToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete chat", role: .destructive) {
                    guard let conversation = conversationToDelete else { return }
                    conversationToDelete = nil
                    delete(conversation)
                }
                Button("Cancel", role: .cancel) { conversationToDelete = nil }
            } message: {
                Text("The conversation and its messages are removed from the server.")
            }
    }
}

/// One quiet row of the composer's anchored "+" card.
private struct AttachmentMenuRow: View {
    let title: String
    let systemImage: String
    let identifier: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityIdentifier(identifier)
    }
}

/// The composer's send/stop control. One 36pt circle that fills with the
/// theme's primary color the moment it becomes usable, swaps its symbol with
/// a gentle transition, and presses with a small scale — monochrome in both
/// appearances like ChatGPT's composer action.
struct SendButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isStreaming: Bool
    let isStopping: Bool
    let isActive: Bool
    let isBlocked: Bool
    let send: @MainActor () -> Void
    let stop: @MainActor () -> Void

    private var isEnabled: Bool {
        !isStopping && !isBlocked && (isStreaming || isActive)
    }

    var body: some View {
        Button(action: handleTap) {
            ZStack {
                Circle()
                    .fill(fillColor)
                symbol
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(symbolColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 36, height: 36)
            .shadow(
                color: .black.opacity(isEnabled ? 0.18 : 0),
                radius: isEnabled ? 5 : 0,
                y: 2
            )
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(SendButtonStyle(reduceMotion: reduceMotion))
        .animation(.smooth(duration: 0.2), value: isEnabled)
        .animation(.smooth(duration: 0.2), value: isStreaming)
    }

    private func handleTap() {
        isStreaming ? stop() : send()
    }

    private var fillColor: Color {
        isEnabled ? .primary : Color.secondary.opacity(0.28)
    }

    // The idle state must stay legible on the glass composer: a subdued but
    // clearly readable primary-tinted glyph instead of secondary-on-gray.
    private var symbolColor: Color {
        isEnabled ? Color(uiColor: .systemBackground) : Color.primary.opacity(0.55)
    }

    @ViewBuilder
    private var symbol: some View {
        if isStopping {
            Image(systemName: "hourglass")
                .symbolEffect(.pulse, isActive: !reduceMotion)
        } else if isStreaming {
            Image(systemName: "stop.fill")
        } else {
            Image(systemName: "arrow.up")
        }
    }
}

/// Tags one end of a matched-geometry Liquid Glass morph. Only one end may
/// own the identity at a time; handing it over (pill closes its identity as
/// the dropdown opens) makes the glass visibly grow out of the control.
private struct GlassIdentityModifier: ViewModifier {    let id: String
    let namespace: Namespace.ID
    let active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if active {
                content.glassEffectID(id, in: namespace)
            } else {
                content
            }
        } else {
            content
        }
    }
}

private extension View {
    func glassIdentity(
        _ id: String,
        in namespace: Namespace.ID,
        active: Bool
    ) -> some View {
        modifier(GlassIdentityModifier(id: id, namespace: namespace, active: active))
    }
}

/// Quiet press feedback for the send control: a small scale dip instead of
/// SwiftUI's default opacity flash.
private struct SendButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed && !reduceMotion ? 0.88 : 1
            )
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.16),
                value: configuration.isPressed
            )
    }
}

/// Neutral shimmering placeholder that holds the canvas brand slot while the
/// target's avatar loads (or before any target resolves).
struct BrandIconSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.secondary.opacity(0.14))
            .frame(width: 96, height: 96)
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.7)
                    .offset(x: reduceMotion ? 0 : phase * geometry.size.width * 1.6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            )
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

/// The classic LibreChat-web landing greeting: a slot schedule (time of day,
/// weekday variants) with a per-calendar-day rotation, and a personalized
/// variant when the account name is known. Mirrors web's
/// `greeting.ts` + `useGreeting` so the phrases and their selection behavior
/// match the reference client exactly.
enum LibreChatGreeting {
    struct Option {
        let plain: String
        let named: String
    }

    private static let lateNight: [Option] = [
        Option(plain: "Up late?", named: "Up late, %@?"),
        Option(plain: "Still up?", named: "Still up, %@?"),
        Option(plain: "What shall we think through?", named: "What shall we think through, %@?"),
    ]
    private static let dawn: [Option] = [
        Option(plain: "Early bird or night owl?", named: "Early bird or night owl, %@?"),
        Option(plain: "Still up, or up already?", named: "Still up, or up already, %@?"),
        Option(plain: "Up before the sun", named: "Up before the sun, %@?"),
        Option(plain: "Hey, early bird", named: "Up early, %@?"),
    ]
    private static let morning: [Option] = [
        Option(plain: "Good morning", named: "Good morning, %@"),
        Option(plain: "What's the first move?", named: "What's the first move, %@?"),
        Option(plain: "Ready when you are", named: "Ready when you are, %@"),
    ]
    private static let afternoon: [Option] = [
        Option(plain: "Good afternoon", named: "Good afternoon, %@"),
        Option(plain: "How's the day going?", named: "How's the day going, %@?"),
        Option(plain: "What are we working on?", named: "What are we working on, %@?"),
    ]
    private static let evening: [Option] = [
        Option(plain: "Good evening", named: "Good evening, %@"),
        Option(plain: "Winding down?", named: "Winding down, %@?"),
        Option(plain: "What's left on the list?", named: "What's left on the list, %@?"),
    ]

    private static let cooking = Option(plain: "What's cooking?", named: "What's cooking, %@?")
    private static let welcomeBack = Option(plain: "Welcome back!", named: "Welcome back, %@!")
    private static let newWeek = Option(plain: "New week, fresh page", named: "New week, fresh page, %@")
    private static let backAtIt = Option(plain: "Back at it", named: "Back at it, %@")
    private static let eveningShift = Option(plain: "The evening shift begins", named: "Evening shift, %@?")
    private static let happyThursday = Option(plain: "Happy Thursday", named: "Happy Thursday, %@")
    private static let coffee = Option(plain: "Coffee and a plan?", named: "Coffee and a plan, %@?")
    private static let tackle = Option(plain: "What are we tackling?", named: "What are we tackling, %@?")

    /// One slot: options apply strictly before this hour of day.
    private struct Slot {
        let until: Int
        let options: [Option]
    }

    private static let defaultSlots: [Slot] = [
        Slot(until: 4, options: lateNight),
        Slot(until: 7, options: dawn),
        Slot(until: 12, options: morning),
        Slot(until: 17, options: afternoon),
        Slot(until: 22, options: evening),
        Slot(until: 24, options: lateNight),
    ]

    private static func slots(forWeekday weekday: Int) -> [Slot] {
        switch weekday {
        case 1: // Sunday
            [
                Slot(until: 4, options: lateNight),
                Slot(until: 7, options: dawn),
                Slot(until: 12, options: morning + [cooking]),
                Slot(until: 17, options: afternoon),
                Slot(until: 22, options: evening + [welcomeBack]),
                Slot(until: 24, options: lateNight),
            ]
        case 2: // Monday
            [
                Slot(until: 4, options: lateNight),
                Slot(until: 7, options: dawn),
                Slot(until: 12, options: morning + [newWeek]),
                Slot(until: 17, options: afternoon + [backAtIt]),
                Slot(until: 22, options: evening + [eveningShift]),
                Slot(until: 24, options: lateNight),
            ]
        case 4: // Wednesday
            [
                Slot(until: 4, options: lateNight),
                Slot(until: 7, options: dawn),
                Slot(until: 12, options: morning),
                Slot(until: 17, options: afternoon),
                Slot(until: 22, options: evening + [welcomeBack]),
                Slot(until: 24, options: lateNight),
            ]
        case 5: // Thursday
            [
                Slot(until: 4, options: lateNight),
                Slot(until: 7, options: dawn),
                Slot(until: 12, options: morning + [happyThursday]),
                Slot(until: 17, options: afternoon),
                Slot(until: 22, options: evening),
                Slot(until: 24, options: lateNight),
            ]
        case 6: // Friday
            [
                Slot(until: 4, options: lateNight),
                Slot(until: 7, options: dawn),
                Slot(until: 12, options: morning),
                Slot(until: 17, options: afternoon),
                Slot(until: 22, options: evening + [eveningShift]),
                Slot(until: 24, options: lateNight),
            ]
        case 7: // Saturday
            [
                Slot(until: 4, options: lateNight),
                Slot(until: 7, options: dawn),
                Slot(until: 12, options: morning + [coffee]),
                Slot(until: 17, options: afternoon + [tackle]),
                Slot(until: 22, options: evening),
                Slot(until: 24, options: lateNight),
            ]
        default: // Tuesday and any fallback
            defaultSlots
        }
    }

    static func resolved(userName: String?, date: Date = Date()) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.weekday, .hour, .day], from: date)
        let slots = slots(forWeekday: components.weekday ?? 3)
        let hour = components.hour ?? 12
        let slotIndex = slots.firstIndex { hour < $0.until } ?? slots.count - 1
        let options = slots[slotIndex].options
        // Variant rotates by calendar day so it holds steady within a slot
        // but differs across days — the web's exact selection behavior.
        let dayNumber = components.day ?? 1
        let option = options[(dayNumber + slotIndex) % options.count]
        if let userName, !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(format: option.named, userName)
        }
        return option.plain
    }
}
