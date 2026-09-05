import LibreChatDomain
import SwiftUI
import UIKit

struct SignedInRootView: View {
    let appModel: AppModel

    @State private var model: ConversationListModel
    @State private var searchModel: SearchModel
    @State private var navigation = ConversationNavigationState()
    /// Live drawer drag progress (0…1) while a gesture is active; nil when
    /// resting so the spring animation owns the motion.
    @State private var sidebarDragProgress: CGFloat?
    /// ChatGPT lands on a blank new-chat canvas. There is no separate
    /// "choose a conversation" screen: whenever navigation has no active
    /// conversation — launch, returning to the chat section, deleting or
    /// archiving the open chat — a fresh New Chat canvas is mounted.
    @State private var isPreparingLandingCanvas = false
    /// ChatGPT-style sidebar on iPhone: the conversation list is mounted as
    /// the base layer, and the chat page (or new-chat canvas) slides right —
    /// scaled, rounded, floating — to reveal it. The page always moves back
    /// over the list when a row is picked or the sliver is tapped.
    @State private var isSidebarOpen = false
    /// Until this instant, conversation selection from the drawer is
    /// swallowed. A closing swipe passes over the rows; the gesture itself
    /// must never activate the conversation under the finger. Intentional
    /// taps (no preceding drag) are never suppressed.
    @State private var suppressConversationSelectionUntil = Date.distantPast

    init(appModel: AppModel) {
        self.appModel = appModel
        guard let repository = appModel.repository else {
            preconditionFailure("A signed-in AppModel must expose an active repository.")
        }
        _model = State(
            initialValue: ConversationListModel(
                repository: repository,
                presetRepository: repository,
                presetCreationRepository: repository,
                isOffline: { appModel.isOffline },
                presetsEnabled: { appModel.canUsePresets },
                onUnauthorized: appModel.expireSessionCallback(),
                draftCanvasProbe: { conversationID in
                    // Local content check for the sidebar's draft rows: saved
                    // composer text, else in-flight attachments.
                    let text = await repository.draft(conversationID: conversationID)
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                    let uploads = await appModel.uploadManager?.pendingUploads(
                        conversationID: conversationID
                    ) ?? []
                    return !uploads.isEmpty
                }
            )
        )
        _searchModel = State(
            initialValue: SearchModel(
                repository: repository,
                isOffline: { appModel.isOffline },
                onUnauthorized: appModel.expireSessionCallback()
            )
        )
    }

    var body: some View {
        Group {
            if isPhone {
                phoneNavigation
            } else {
                tabletNavigation
            }
        }
        .accessibilityIdentifier("signed-in-root")
        .task {
            await model.loadIfNeeded()
            navigation.reconcile(
                availableConversationIDs: model.conversations.map(\.id),
                isPhone: isPhone
            )
            await openLandingCanvasIfPossible()
        }
        .onChange(of: model.conversations.map(\.id)) { _, conversationIDs in
            navigation.reconcile(
                availableConversationIDs: conversationIDs,
                isPhone: isPhone
            )
        }
        .onChange(of: navigation.selectedConversationID) { _, selectedID in
            // Any navigation state that used to fall back to "choose a
            // conversation" (deleted or archived the open chat, returned with
            // no selection) mounts a fresh New Chat canvas instead.
            if selectedID == nil {
                Task { await openLandingCanvasIfPossible() }
            }
        }
    }

    /// ChatGPT-style sidebar on iPhone: the drawer and the page move
    /// TOGETHER like one attached surface — the list slides in from the left
    /// while the chat page slides right, rounds, and dims. The motion stays
    /// on a flat 2D plane: no scaling, so header elements keep their exact
    /// size and position relative to the page and nothing reads as depth.
    /// Dragging the page (or its left edge) drives the motion continuously;
    /// while the drawer is open, only the page side is covered by the close
    /// affordance, so the list itself stays fully interactive.
    private var phoneNavigation: some View {
        GeometryReader { geometry in
            let sidebarWidth = geometry.size.width * 0.8
            let reveal = sidebarReveal
            ZStack(alignment: .leading) {
                sidebarLayer
                    .compositingGroup()
                    .frame(width: sidebarWidth)
                    .clipShape(.rect(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 28,
                        topTrailingRadius: 28,
                        style: .continuous
                    ))
                    .background(.background)
                    .offset(x: -sidebarWidth * (1 - reveal))
                    .zIndex(0)

                phoneChatLayer
                    .compositingGroup()
                    .background(.background)
                    // The dim and the close affordance live INSIDE the
                    // transform chain: they clip, slide with the page, and
                    // keep the drawer underneath bright and fully
                    // interactive. An overlay applied after the transforms
                    // would keep its untransformed full-screen hit area and
                    // swallow every sidebar touch.
                    .overlay {
                        ZStack {
                            Color.black
                                .opacity(0.38 * reveal)
                                .allowsHitTesting(false)
                            if isSidebarOpen {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { closeSidebar() }
                                    .gesture(closeDragGesture(sidebarWidth: sidebarWidth))
                                    .accessibilityLabel("Close sidebar")
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 34 * reveal,
                            style: .continuous
                        )
                    )
                    .offset(x: sidebarWidth * reveal)
                    // Directional shadow spills right, away from the drawer,
                    // so the panel itself never reads as dimmed. The shadow is
                    // the only depth cue — the page itself never scales.
                    .shadow(color: .black.opacity(0.25 * reveal), radius: 20, x: 12)
                    .zIndex(1)
                    // A left→right swipe anywhere on the page opens the
                    // drawer with finger-following motion. The gesture ignores
                    // vertical drags (scrolling) and drags that start in the
                    // composer zone, where the chip rows scroll horizontally.
                    .simultaneousGesture(
                        openDragGesture(sidebarWidth: sidebarWidth, pageHeight: geometry.size.height)
                    )
            }
            .animation(
                sidebarDragProgress == nil
                    ? .spring(response: 0.26, dampingFraction: 0.85)
                    : nil,
                value: isSidebarOpen
            )
        }
        .environment(\.openSidebar, OpenSidebarAction(action: { openSidebar() }))
    }

    /// 0 = closed, 1 = open. A live drag drives the in-between values so the
    /// two layers stay attached to the finger.
    private var sidebarReveal: CGFloat {
        if let sidebarDragProgress {
            return min(1, max(0, sidebarDragProgress))
        }
        return isSidebarOpen ? 1 : 0
    }

    /// Pull-right-to-open. Only horizontal, left→right drags that start
    /// above the composer zone drive the drawer; everything else (vertical
    /// scrolling, the composer's horizontal chip rows) is left untouched.
    /// If a recognized drag drifts vertical and ends off-gate, the drawer
    /// springs back closed instead of freezing mid-travel.
    private func openDragGesture(sidebarWidth: CGFloat, pageHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isSidebarOpen,
                      Self.isOpenSwipe(value, pageHeight: pageHeight) else { return }
                sidebarDragProgress = min(1, max(0, value.translation.width / sidebarWidth))
            }
            .onEnded { value in
                guard !isSidebarOpen else { return }
                guard Self.isOpenSwipe(value, pageHeight: pageHeight) else {
                    if sidebarDragProgress != nil {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                            sidebarDragProgress = nil
                        }
                    }
                    return
                }
                settleDrag(
                    progress: value.translation.width / sidebarWidth,
                    velocity: value.velocity.width,
                    fromOpen: false
                )
            }
    }

    private static func isOpenSwipe(_ value: DragGesture.Value, pageHeight: CGFloat) -> Bool {
        value.startLocation.y < pageHeight - 240
            && abs(value.translation.width) > abs(value.translation.height)
            && value.translation.width > 0
    }

    private func closeDragGesture(sidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard isSidebarOpen else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // The swipe travels over the rows: keep selection suppressed
                // while it is in flight and briefly after it settles.
                suppressConversationSelectionUntil = Date().addingTimeInterval(0.45)
                sidebarDragProgress = min(1, 1 + value.translation.width / sidebarWidth)
            }
            .onEnded { value in
                settleDrag(
                    progress: 1 + value.translation.width / sidebarWidth,
                    velocity: value.velocity.width,
                    fromOpen: true
                )
            }
    }

    /// Snaps the drawer open or closed after a drag, honoring flick velocity.
    private func settleDrag(progress: CGFloat, velocity: CGFloat, fromOpen: Bool) {
        let predicted = progress + velocity / sidebarWidthVelocityDivisor
        let shouldOpen = fromOpen ? predicted > 0.35 : predicted > 0.45
        withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
            isSidebarOpen = shouldOpen
            sidebarDragProgress = nil
        }
        if shouldOpen { dismissKeyboard() }
        if !shouldOpen {
            // A gesture just passed over the drawer/page: swallow row taps
            // for a beat so closing can never activate a conversation.
            suppressConversationSelectionUntil = Date().addingTimeInterval(0.35)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private var sidebarWidthVelocityDivisor: CGFloat { 1_400 }

    /// The overlay drawer. No NavigationStack wraps the list — every
    /// destination is a sheet, and a bare List keeps row hit-testing stable
    /// while the drawer slides (a hidden navigation bar desynced taps).
    private var sidebarLayer: some View {
        ConversationListView(
            model: model,
            searchModel: searchModel,
            appModel: appModel,
            selectedConversationID: $navigation.selectedConversationID,
            selectConversation: { id in
                guard Date() >= suppressConversationSelectionUntil else { return }
                // One page: picking a row swaps the mounted chat for the
                // selected one, and the page slides back over the list.
                withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                    navigation.replaceCurrentChat(with: id, isPhone: true)
                }
                closeSidebar()
            },
            selectMessage: { messageID, conversationID in
                guard Date() >= suppressConversationSelectionUntil else { return }
                withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                    navigation.replaceCurrentChat(
                        withMessage: messageID,
                        in: conversationID,
                        isPhone: true
                    )
                }
                closeSidebar()
            }
        )
        .accessibilityIdentifier("sidebar-panel")
    }

    /// The always-mounted chat surface behind the sidebar: the selected
    /// conversation, or the session's new-chat canvas. The server and account
    /// are resolved before mounting: identity can be torn down (session
    /// expiry, profile switch) between SwiftUI render passes, and a force
    /// unwrap here crashed in production.
    @ViewBuilder
    private var phoneChatLayer: some View {
        if let conversation = currentChatConversation,
           let repository = appModel.repository,
           let server = appModel.selectedServer,
           let user = appModel.user {
            phoneChatView(
                conversation: conversation,
                repository: repository,
                server: server,
                user: user
            )
        } else {
            // The moment between sign-in and the blank canvas (or the state
            // when no canvas can be created, e.g. offline). There is no
            // "choose a conversation" screen anywhere in the product — the
            // New Chat canvas is the default empty-chat state.
            NavigationStack {
                NewChatPreparingPlaceholder(
                    isPreparing: isPreparingLandingCanvas,
                    isOffline: appModel.isOffline,
                    onOpenSidebar: { openSidebar() }
                )
            }
        }
    }

    private var currentChatConversation: LibreChatDomain.Conversation? {
        guard let id = navigation.selectedConversationID else { return nil }
        let resolved = navigation.resolvedConversationID(for: id)
        return model.conversation(withID: resolved)
    }

    private func phoneChatView(
        conversation: LibreChatDomain.Conversation,
        repository: LibreChatRepository,
        server: ServerProfile,
        user: UserAccount
    ) -> some View {
        NavigationStack {
            ChatView(
                conversation: conversation,
                profileID: server.id,
                accountID: user.id,
                serverBaseURL: server.baseURL,
                repository: repository,
                conversationListModel: model,
                uploadManager: appModel.uploadManager,
                generationRecoverySignal: appModel.generationRecoverySignal,
                messageFocusRequest: navigation.messageFocusRequest(for: conversation.id),
                canGenerate: { appModel.canGenerate },
                canShare: { appModel.canShareConversations },
                canSnapshotSharedFiles: { appModel.canSnapshotFilesInSharedLinks },
                canUsePrompts: { appModel.canUsePrompts },
                canUseSkills: { appModel.canUseSkills },
                canUseVoiceDictation: { appModel.canUseVoiceDictation },
                canUseReadAloud: { appModel.canUseReadAloud },
                canUseBookmarks: { appModel.canUseBookmarks },
                isOffline: { appModel.isOffline },
                promptUserName: appModel.user?.name,
                temporaryChatPolicy: appModel.temporaryChatPolicy,
                compatibilityWarning: { appModel.compatibilityWarning },
                onUnauthorized: appModel.expireSessionCallback(),
                onConversationForked: replaceCurrentChat,
                onConversationDismissed: dismissConversation,
                onOpenSidebar: { openSidebar() },
                onConversationIdentityChanged: updateConversationIdentity
            )
            // A genuine selection builds a fresh ChatModel for the newly
            // mounted page; the identity handoff that promotes a local
            // draft keeps its generation, preserving a streaming model.
            .id(navigation.detailPresentationGeneration)
            .transition(.opacity)
        }
    }

    private func openSidebar() {
        // Opening the drawer dismisses the keyboard immediately — swiping or
        // tapping the hamburger should never leave the composer focused
        // underneath the panel.
        dismissKeyboard()
        Task { await model.refreshDraftCanvases() }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
            isSidebarOpen = true
        }
    }

    private func closeSidebar() {
        withAnimation(.easeIn(duration: 0.16)) {
            isSidebarOpen = false
        }
    }

    private var tabletNavigation: some View {
        NavigationSplitView {
            ConversationListView(
                model: model,
                searchModel: searchModel,
                appModel: appModel,
                selectedConversationID: $navigation.selectedConversationID,
                selectConversation: { navigation.select($0, isPhone: false) },
                selectMessage: { messageID, conversationID in
                    navigation.selectMessage(
                        messageID,
                        in: conversationID,
                        isPhone: false
                    )
                }
            )
        } detail: {
            if let conversation = selectedConversation,
               let repository = appModel.repository,
               let server = appModel.selectedServer,
               let user = appModel.user {
                ChatView(
                    conversation: conversation,
                    profileID: server.id,
                    accountID: user.id,
                    serverBaseURL: server.baseURL,
                    repository: repository,
                    conversationListModel: model,
                    uploadManager: appModel.uploadManager,
                    generationRecoverySignal: appModel.generationRecoverySignal,
                    messageFocusRequest: navigation.messageFocusRequest(
                        for: conversation.id
                    ),
                    canGenerate: { appModel.canGenerate },
                    canShare: { appModel.canShareConversations },
                    canSnapshotSharedFiles: { appModel.canSnapshotFilesInSharedLinks },
                    canUsePrompts: { appModel.canUsePrompts },
                    canUseSkills: { appModel.canUseSkills },
                    canUseVoiceDictation: { appModel.canUseVoiceDictation },
                    canUseReadAloud: { appModel.canUseReadAloud },
                    canUseBookmarks: { appModel.canUseBookmarks },
                    isOffline: { appModel.isOffline },
                    promptUserName: appModel.user?.name,
                    temporaryChatPolicy: appModel.temporaryChatPolicy,
                    compatibilityWarning: { appModel.compatibilityWarning },
                    onUnauthorized: appModel.expireSessionCallback(),
                    onConversationForked: replaceCurrentChat,
                    onConversationDismissed: dismissConversation,
                    onConversationIdentityChanged: updateConversationIdentity
                )
                // Keep the presentation identity stable while a local draft is
                // promoted to its canonical server ID. A genuine row selection
                // advances this value and creates a fresh ChatModel.
                .id(navigation.detailPresentationGeneration)
            } else {
                // New Chat is the default detail state here too: an empty
                // account (or a still-hydrating one) shows the blank canvas
                // instead of a "choose a conversation" placeholder.
                NewChatPreparingPlaceholder(
                    isPreparing: isPreparingLandingCanvas,
                    isOffline: appModel.isOffline,
                    onOpenSidebar: nil
                )
            }
        }
    }

    private var selectedConversation: LibreChatDomain.Conversation? {
        guard let selectedConversationID = navigation.selectedConversationID else { return nil }
        let resolvedID = navigation.resolvedConversationID(for: selectedConversationID)
        return model.conversation(withID: resolvedID)
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Mounts the blank new-chat canvas whenever navigation has no active
    /// conversation. The target catalog's first option already honors the
    /// account's recent-target preference, so no separate default selection
    /// is needed. Offline sign-ins stay on the read-only conversation list.
    private func openLandingCanvasIfPossible() async {
        // UI test fixtures drive explicit list-first flows; the auto canvas
        // would cover the rows they interact with.
        #if DEBUG
        if appModel.uiTestFixtureIsActive { return }
        #endif
        guard navigation.selectedConversationID == nil,
              !isPreparingLandingCanvas,
              !appModel.isOffline else { return }
        isPreparingLandingCanvas = true
        defer { isPreparingLandingCanvas = false }
        await model.loadTargets()
        // The catalog already resolves the persisted last-used target
        // (recent-option preference) into its effective default, so a fresh
        // canvas lands on the model or agent the user actually last chose —
        // created only after the catalog is loaded, so no other model is
        // ever briefly rendered.
        guard let defaultOption = model.targetCatalog?.effectiveDefaultOption
            ?? model.targetCatalog?.options.first else { return }
        guard let draft = await model.createConversation(
            title: "New Chat",
            target: defaultOption
        ) else { return }
        // Creation may race an explicit selection; never steal the page back.
        guard navigation.selectedConversationID == nil else { return }
        navigation.select(draft.id, isPhone: isPhone)
        isSidebarOpen = false
    }

    private func updateConversationIdentity(
        from previousID: ConversationID,
        to conversation: LibreChatDomain.Conversation
    ) {
        model.replaceConversation(id: previousID, with: conversation)
        navigation.replaceIdentity(from: previousID, with: conversation.id)
    }

    private func includeAndSelectConversation(_ conversation: LibreChatDomain.Conversation) {
        model.includeConversation(conversation)
        navigation.select(conversation.id, isPhone: isPhone)
    }

    /// Chats started from inside a chat replace the current chat page.
    private func replaceCurrentChat(with conversation: LibreChatDomain.Conversation) {
        model.includeConversation(conversation)
        navigation.replaceCurrentChat(with: conversation.id, isPhone: isPhone)
    }

    /// Clears a conversation the chat screen just archived or deleted; the
    /// overlay falls back to the empty choose state (or the next canvas).
    private func dismissConversation(_ conversationID: ConversationID) {
        navigation.dismissConversation(conversationID)
    }
}

/// A lightweight navigation instruction for one exact server message. The
/// monotonically increasing sequence makes selecting the same search result
/// twice a fresh request without putting view instances into navigation state.
struct ConversationMessageFocusRequest: Equatable, Hashable, Sendable {
    let sequence: UInt64
    let conversationID: ConversationID
    let messageID: MessageID
}

/// Navigation state is intentionally separate from the conversation cache.
/// A server can replace a local draft ID while its ChatModel is streaming; that
/// protocol identity change must not be mistaken for a user selecting a new row.
struct ConversationNavigationState: Equatable {
    var selectedConversationID: ConversationID?
    var phonePath: [ConversationID] = []
    private(set) var detailPresentationGeneration: UInt = 0
    private(set) var messageFocusRequest: ConversationMessageFocusRequest?
    private var conversationAliases: [ConversationID: ConversationID] = [:]
    private var messageFocusSequence: UInt64 = 0

    mutating func select(_ conversationID: ConversationID, isPhone: Bool) {
        messageFocusRequest = nil
        selectConversation(conversationID, isPhone: isPhone)
    }

    /// Selects a chat started from inside another chat. The app has exactly
    /// two pages on iPhone — list and one chat — so this replaces the current
    /// chat route instead of stacking another one.
    mutating func replaceCurrentChat(
        with conversationID: ConversationID,
        isPhone: Bool
    ) {
        messageFocusRequest = nil
        selectConversation(
            conversationID,
            isPhone: isPhone,
            replacingCurrentChat: true
        )
    }

    /// Search-result variant of the page replacement: the conversation page
    /// swaps in and focuses the matched message in one motion.
    mutating func replaceCurrentChat(
        withMessage messageID: MessageID,
        in conversationID: ConversationID,
        isPhone: Bool
    ) {
        messageFocusSequence &+= 1
        messageFocusRequest = ConversationMessageFocusRequest(
            sequence: messageFocusSequence,
            conversationID: conversationID,
            messageID: messageID
        )
        selectConversation(conversationID, isPhone: isPhone, replacingCurrentChat: true)
    }

    /// Removes a conversation from navigation after the chat screen archived
    /// or deleted it: pop its phone route(s) and fall the selection back to
    /// whatever remains beneath.
    mutating func dismissConversation(_ conversationID: ConversationID) {
        let resolvedTarget = resolvedConversationID(for: conversationID)
        let remainingPath = phonePath.filter {
            $0 != conversationID && resolvedConversationID(for: $0) != resolvedTarget
        }
        phonePath = remainingPath
        if let selected = selectedConversationID,
           selected == conversationID
               || resolvedConversationID(for: selected) == resolvedTarget {
            selectedConversationID = phonePath.last
            detailPresentationGeneration &+= 1
        }
    }

    mutating func selectMessage(
        _ messageID: MessageID,
        in conversationID: ConversationID,
        isPhone: Bool
    ) {
        messageFocusSequence &+= 1
        messageFocusRequest = ConversationMessageFocusRequest(
            sequence: messageFocusSequence,
            conversationID: conversationID,
            messageID: messageID
        )
        selectConversation(conversationID, isPhone: isPhone)
    }

    private mutating func selectConversation(
        _ conversationID: ConversationID,
        isPhone: Bool,
        replacingCurrentChat: Bool = false
    ) {
        if conversationID.isLocalDraft {
            conversationAliases[conversationID] = nil
        }

        let previousResolvedID = selectedConversationID.map(resolvedConversationID(for:))
        if previousResolvedID != conversationID {
            detailPresentationGeneration &+= 1
        }
        selectedConversationID = conversationID

        guard isPhone else { return }
        if replacingCurrentChat, phonePath.count > 1 {
            // One chat page: swap the route in place rather than stacking.
            phonePath[phonePath.count - 1] = conversationID
            return
        }
        let lastResolvedID = phonePath.last.map(resolvedConversationID(for:))
        if lastResolvedID != conversationID {
            phonePath.append(conversationID)
        }
    }

    mutating func reconcile(
        availableConversationIDs: [ConversationID],
        isPhone: Bool
    ) {
        let availableIDs = Set(availableConversationIDs)
        if let selectedConversationID {
            let resolvedID = resolvedConversationID(for: selectedConversationID)
            if availableIDs.contains(resolvedID) {
                self.selectedConversationID = resolvedID
                return
            }
        }

        guard !isPhone, let firstConversationID = availableConversationIDs.first else {
            selectedConversationID = nil
            messageFocusRequest = nil
            return
        }
        select(firstConversationID, isPhone: false)
    }

    mutating func replaceIdentity(from previousID: ConversationID, with canonicalID: ConversationID) {
        guard previousID != canonicalID else { return }
        conversationAliases[previousID] = canonicalID
        if selectedConversationID == previousID {
            selectedConversationID = canonicalID
        }
        if let focus = messageFocusRequest,
           focus.conversationID == previousID {
            messageFocusRequest = ConversationMessageFocusRequest(
                sequence: focus.sequence,
                conversationID: canonicalID,
                messageID: focus.messageID
            )
        }
    }

    func resolvedConversationID(for routeID: ConversationID) -> ConversationID {
        conversationAliases[routeID] ?? routeID
    }

    func messageFocusRequest(
        for routeID: ConversationID
    ) -> ConversationMessageFocusRequest? {
        guard let messageFocusRequest,
              resolvedConversationID(for: messageFocusRequest.conversationID)
                == resolvedConversationID(for: routeID) else { return nil }
        return messageFocusRequest
    }

    mutating func pruneAliases(keepingRoutes routes: [ConversationID]) {
        let liveRoutes = Set(routes)
        conversationAliases = conversationAliases.filter { liveRoutes.contains($0.key) }
    }
}


/// Toolbar-friendly way for ChatView to open the overlay sidebar without a
/// direct coupling to the root's state.
struct OpenSidebarAction {
    let action: @MainActor () -> Void

    @MainActor
    func callAsFunction() { action() }
}

/// The quiet surface mounted while the blank New Chat canvas is being
/// prepared (or when none can be created — offline). There is deliberately no
/// "choose a conversation" screen anywhere in the product: this either
/// resolves into the New Chat canvas within a beat or explains the offline
/// limitation.
struct NewChatPreparingPlaceholder: View {
    let isPreparing: Bool
    let isOffline: Bool
    /// nil on iPad, where the list is permanently visible beside the detail.
    var onOpenSidebar: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image("LogoMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)

            if isPreparing {
                ProgressView()
                    .padding(.top, 2)
            } else {
                if isOffline {
                    Text("Reconnect to LibreChat to start a new chat.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let onOpenSidebar {
                    // The settled fallback keeps the drawer one tap away on
                    // phone (offline state, and the list-first UI-test
                    // fixtures that opt out of the auto canvas).
                    Button {
                        onOpenSidebar()
                    } label: {
                        Label("Open sidebar", systemImage: "sidebar.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("placeholder-open-sidebar")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("new-chat-preparing")
    }
}

private struct OpenSidebarKey: EnvironmentKey {
    static let defaultValue = OpenSidebarAction(action: {})
}

extension EnvironmentValues {
    var openSidebar: OpenSidebarAction {
        get { self[OpenSidebarKey.self] }
        set { self[OpenSidebarKey.self] = newValue }
    }
}
