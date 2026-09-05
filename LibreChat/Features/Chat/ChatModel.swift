import DesignKit
import Foundation
import LibreChatDomain
import LibreChatProtocol
import Observation
import OSLog

/// The narrow capability surface needed by the chat presentation model.
///
/// Keeping this protocol at the feature boundary lets generation, history,
/// drafts, and pending interactions be exercised without constructing the
/// concrete LibreChat transport/cache actor.
protocol ChatFeatureRepository: ChatRepository, ConversationRepository, ConversationForkRepository, GenerationSteeringRepository, MessageEditingRepository, MessageFeedbackRepository, ArtifactRepository, GeneratedFileRepository, ChatFollowUpRepository, SpeechTranscriptionRepository, SpeechSynthesisRepository, SkillRepository {
    func respond(
        to interaction: PendingInteraction,
        handle: GenerationHandle,
        toolResolutions: [ToolApprovalResolution]?,
        answer: String?,
        batchAnswers: [String: String]?
    ) async throws -> GenerationSnapshot
    func recoverableGenerations() async throws -> [GenerationSnapshot]
    func draft(conversationID: ConversationID) async -> String
    func saveDraft(_ text: String, conversationID: ConversationID) async
}

/// Feature doubles that do not exercise steering remain intentionally
/// source-compatible. Production uses LibreChatRepository's exact v2
/// implementation; an unimplemented feature boundary fails closed.
extension ChatFeatureRepository {
    func skillInvocationCatalog(
        for target: ConversationTarget
    ) async throws -> SkillInvocationCatalog {
        throw SkillInvocationError.unavailable
    }

    func speechCapabilities() async throws -> SpeechCapabilities {
        SpeechCapabilities(supportsSpeechToText: false, supportsTextToSpeech: false)
    }

    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscription {
        throw LibreChatProtocolError.unsupported("Speech-to-text is unavailable.")
    }

    func updateMessageFeedback(
        _ request: MessageFeedbackRequest
    ) async throws -> MessageFeedbackResult {
        throw MessageFeedbackError.unavailable
    }

    func fork(_ request: ConversationForkRequest) async throws -> ConversationForkResult {
        throw ConversationForkValidationError.invalidResponse
    }

    func submitSteer(
        _ request: GenerationSteerRequest
    ) async throws -> GenerationSteerSubmissionOutcome {
        throw GenerationSteeringError.protocolMismatch
    }

    func cancelSteer(
        _ request: GenerationSteerControlRequest
    ) async throws -> GenerationSteerCancelOutcome {
        throw GenerationSteeringError.protocolMismatch
    }

    func armSteer(
        _ request: GenerationSteerControlRequest
    ) async throws -> GenerationSteerArmOutcome {
        throw GenerationSteeringError.protocolMismatch
    }

    func followUpQueue(conversationID: ConversationID) async throws -> FollowUpQueueSnapshot {
        throw FollowUpQueueError.invalidTransition
    }

    func enqueueFollowUp(_ item: FollowUpQueueItem) async throws -> FollowUpQueueSnapshot {
        throw FollowUpQueueError.invalidTransition
    }

    func editQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID,
        text: String
    ) async throws -> FollowUpQueueSnapshot {
        throw FollowUpQueueError.invalidTransition
    }

    func removeQueuedFollowUp(
        itemID: FollowUpQueueItemID,
        conversationID: ConversationID
    ) async throws -> FollowUpQueueSnapshot {
        throw FollowUpQueueError.invalidTransition
    }

    func drainFollowUp(after signal: FollowUpGenerationSignal) async throws -> FollowUpDrainResult {
        throw FollowUpQueueError.invalidTransition
    }

    func followUpAdmissionProof(
        for attempt: FollowUpAdmissionAttempt
    ) async throws -> FollowUpAdmissionProof? {
        nil
    }

    func recoverableSteerBatches(
        conversationID: ConversationID
    ) async throws -> [RecoverableSteerBatch] {
        []
    }

    func acknowledgeRecoverableSteers(
        handle: GenerationHandle,
        identities: Set<RecoverableSteerIdentity>
    ) async throws -> RecoverableSteerBatch? {
        nil
    }

    func discardRecoverableSteer(
        _ request: RecoverableSteerDiscardRequest
    ) async throws -> RecoverableSteerDiscardOutcome {
        throw RecoverableSteerDiscardError.sourceNotRecoverable
    }
}

private enum ConversationHydrationFailure: LocalizedError {
    case invalidAuthoritativeConversation

    var errorDescription: String? {
        "LibreChat did not return a complete conversation target."
    }
}

extension LibreChatRepository: ChatFeatureRepository {}

@MainActor
@Observable
final class ChatModel {
    /// Immutable, view-facing projection of the complete authoritative graph.
    ///
    /// `messages` remains the complete history needed for safety-sensitive
    /// mutations, while this is the only branch projection the chat surface
    /// needs to observe. Keeping it materialized prevents every body pass from
    /// rebuilding `MessageTree` while a response is streaming.
    struct ChatRenderProjection: Equatable {
        let revision: UInt64
        let isStructurallyValid: Bool
        let visibleEntries: [MessageTree.BranchEntry]
        let visibleMessages: [ChatMessage]
        let visibleMessageCount: Int
        let lastVisibleMessageID: MessageID?
        let lastVisiblePlainTextRevision: UInt64
        let lastVisiblePlainText: String?

        static let empty = ChatRenderProjection(
            revision: 0,
            isStructurallyValid: true,
            visibleEntries: [],
            visibleMessages: [],
            visibleMessageCount: 0,
            lastVisibleMessageID: nil,
            lastVisiblePlainTextRevision: 0,
            lastVisiblePlainText: nil
        )
    }

    /// The view-level polling task must observe ownership changes even when a
    /// pending card retains the same backing `file_id`. The coordinator then
    /// cancels the former owner before polling the replacement card.
    struct GeneratedFilePreviewPollingSignature: Hashable {
        let fileID: String
        let identity: GeneratedFileIdentity
        let messageID: MessageID
        let conversationID: ConversationID
    }

    enum SearchResultFocusOutcome: Equatable {
        case focused(MessageID)
        case unavailable
    }

    private struct MessageEditOperationKey: Equatable {
        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let conversationID: ConversationID
        let coordinate: MessageTextCoordinate
        let baselineText: String
    }

    private struct MessageFeedbackOperationKey: Equatable {
        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let conversationID: ConversationID
        let messageID: MessageID
        let baselineFeedback: MessageFeedback?
        let submittedFeedback: MessageFeedback?
    }

    /// One artifact source mutation owns the conversation until its server
    /// result is known. This prevents a second Save or a new generation from
    /// racing the source/content comparison used by LibreChat's artifact API.
    private struct ArtifactEditOperationKey: Equatable {
        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let conversationID: ConversationID
        let artifact: ParsedArtifact
    }

    private enum SnapshotCancellationPolicy {
        /// Lifecycle detachment, profile switching, and explicit operation
        /// replacement own the next recovery step.
        case lifecycleOwnsRecovery
        /// A human response was already consumed by LibreChat. Cancelling the
        /// replacement stream must leave a visible Resume path and must never
        /// restore or repost that response.
        case acknowledgedInteraction
    }

    private struct PromptResubmitOperationKey: Equatable {
        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let conversationID: ConversationID
        let sourceMessageID: MessageID
        let sourceParentMessageID: MessageID?
        let baselineText: String
        let submittedText: String
        let clientRequestID: UUID
        let clientMessageID: MessageID
    }

    private struct ResponseRegenerationOperationKey: Equatable {
        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let conversationID: ConversationID
        let conversationTarget: ConversationTarget
        let sourceUserMessage: ChatMessage
        let sourceParentMessageID: MessageID?
        let targetAssistantMessage: ChatMessage
        let preAdmissionAssistantSiblingIDs: Set<MessageID>
        let preservedTargetSubtree: [ChatMessage]
        let clientRequestID: UUID
        let clientMessageID: MessageID
    }

    private struct InteractionSubmissionKey: Hashable {
        let handle: GenerationHandle
        let interaction: PendingInteraction
    }

    private struct SteeringOperationKey: Equatable {
        enum Kind: Equatable {
            case submit(clientSteerID: String)
            case cancel(steerID: String, clientSteerID: String)
            case arm(steerID: String, clientSteerID: String)
        }

        let id: UUID
        let handle: GenerationHandle
        let kind: Kind
    }

    private struct UncertainSteeringKey: Equatable {
        let handle: GenerationHandle
        let clientSteerID: String
        let steerID: String?
    }

    private struct ConversationForkOperationKey: Equatable {
        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let sourceConversationID: ConversationID
        let targetMessageID: MessageID
    }

    private struct FollowUpOperationKey: Equatable {
        enum Kind: Equatable {
            case enqueueDraft(source: GenerationHandle)
            case remove(FollowUpQueueItemID)
            case retry(FollowUpQueueItemID, source: GenerationHandle)
            case enqueueRecovery(handle: GenerationHandle, identity: RecoverableSteerIdentity)
            case discardRecovery(handle: GenerationHandle, identity: RecoverableSteerIdentity)
        }

        let id: UUID
        let profileID: ServerProfileID
        let accountID: AccountID
        let conversationID: ConversationID
        let kind: Kind
    }

    private struct FollowUpSourceContext {
        let handle: GenerationHandle
        let userMessageID: MessageID
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum RoutingState: Equatable {
        case unverified
        case hydrating
        case authoritative
        case unavailable
    }

    enum HistoryState: Equatable {
        case notCurrent
        case loading
        case authoritative
        case cached
        case cachedAfterFailure
        case unavailable
    }

    private(set) var conversation: LibreChatDomain.Conversation
    let profileID: ServerProfileID
    let accountID: AccountID
    private let repository: any ChatFeatureRepository
    private let uploadManager: UploadManager?
    private let canGenerateRemotely: @MainActor () -> Bool
    private let canUseSkillsRemotely: @MainActor () -> Bool
    private let compatibilityWarning: @MainActor () -> String?
    private let now: @MainActor () -> Date
    private let onUnauthorized: @MainActor () async -> Void
    private let onConversationIdentityChanged: @MainActor (ConversationID, LibreChatDomain.Conversation) -> Void

    private(set) var state: State = .idle
    private(set) var messages: [ChatMessage] = [] {
        didSet {
            guard oldValue != messages else { return }
            // Streaming fast path: a delta that only grows the text of the
            // final message (identity, structure, and count unchanged) can
            // update just that render entry. Rebuilding the whole message
            // tree per token made long conversations janky.
            if isStreaming,
               oldValue.count == messages.count,
               oldValue.dropLast() == messages.dropLast(),
               let lastOld = oldValue.last,
               let lastNew = messages.last,
               lastNew.isStreamingTextGrowth(of: lastOld) {
                applyStreamingTextUpdate(lastNew)
            } else {
                rebuildChatRenderProjection()
            }
        }
    }
    private(set) var generationSnapshot: GenerationSnapshot?
    private(set) var isStreaming = false {
        didSet {
            // Leaving streaming requires one authoritative projection rebuild:
            // the streaming fast path skips tree maintenance by design.
            if oldValue, !isStreaming {
                rebuildChatRenderProjection()
            }
        }
    }
    private(set) var isStopping = false
    private(set) var isRespondingToInteraction = false
    private(set) var isShowingCache = false
    private(set) var uploads: [PendingUpload] = []
    private(set) var routingState: RoutingState
    private(set) var historyState: HistoryState
    private(set) var isDraftLoaded = false
    private(set) var branchSelection: [MessageTree.BranchParent: MessageID] = [:] {
        didSet {
            guard oldValue != branchSelection else { return }
            rebuildChatRenderProjection()
        }
    }
    private(set) var renderProjection = ChatRenderProjection.empty
    private(set) var followUpQueue: FollowUpQueueSnapshot?
    private(set) var recoverableSteerBatches: [RecoverableSteerBatch] = []
    private(set) var skillCatalog: SkillInvocationCatalog?
    private(set) var isLoadingSkills = false
    private(set) var selectedSkillNames: [String] = []
    var draft = ""
    var errorMessage: String?
    /// Transient, auto-dismissing notice (toast). Used for rejections that
    /// must never persist as an inline error strip — file-size rejections,
    /// for example.
    var transientNotice: String?
    var skillCatalogError: String?

    private var sendTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var interactionTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var uploadObservationTask: Task<Void, Never>?
    private var generatedFilePreviewPollingCoordinator: GeneratedFilePreviewPollingCoordinator?
    private var activeGeneration: GenerationHandle?
    private var activeOperationID: UUID?
    private var messageEditOperation: MessageEditOperationKey?
    private var messageFeedbackOperation: MessageFeedbackOperationKey?
    private var artifactEditOperation: ArtifactEditOperationKey?
    private var promptResubmitOperation: PromptResubmitOperationKey?
    private var responseRegenerationOperation: ResponseRegenerationOperationKey?
    private var steeringOperation: SteeringOperationKey?
    private var uncertainSteering: UncertainSteeringKey?
    private var conversationForkOperation: ConversationForkOperationKey?
    private var followUpOperation: FollowUpOperationKey?
    private var uncertainConversationForkTargets: Set<MessageID> = []
    private var uncertainFeedbackTargets: Set<MessageID> = []
    private var optimisticUserID: MessageID?
    private var optimisticAssistantID: MessageID?
    private var branchSelectionBeforeOptimisticSend: [MessageTree.BranchParent: MessageID]?
    private var preferredBranchFocusID: MessageID?
    private var preferredBranchFallbackID: MessageID?
    private var stopRequested = false
    private var respondingInteractionKey: InteractionSubmissionKey?
    private var lastGenerationRecoverySequence: UInt64?
    private var cachedMessageTree = MessageTree(messages: [])

    init(
        conversation: LibreChatDomain.Conversation,
        profileID: ServerProfileID,
        accountID: AccountID,
        repository: any ChatFeatureRepository,
        uploadManager: UploadManager?,
        canGenerate: @escaping @MainActor () -> Bool,
        canUseSkills: @escaping @MainActor () -> Bool = { false },
        compatibilityWarning: @escaping @MainActor () -> String?,
        now: @escaping @MainActor () -> Date = { Date() },
        onUnauthorized: @escaping @MainActor () async -> Void,
        onConversationIdentityChanged: @escaping @MainActor (ConversationID, LibreChatDomain.Conversation) -> Void
    ) {
        self.conversation = conversation
        self.profileID = profileID
        self.accountID = accountID
        self.repository = repository
        self.uploadManager = uploadManager
        canGenerateRemotely = canGenerate
        canUseSkillsRemotely = canUseSkills
        self.compatibilityWarning = compatibilityWarning
        self.now = now
        self.onUnauthorized = onUnauthorized
        self.onConversationIdentityChanged = onConversationIdentityChanged
        if conversation.id.isLocalDraft {
            routingState = .authoritative
            historyState = .authoritative
        } else {
            routingState = .unverified
            historyState = .notCurrent
        }
    }

    var canSend: Bool {
        state == .loaded
            && isDraftLoaded
            && !isStreaming
            && activeGeneration == nil
            && messageEditOperation == nil
            && messageFeedbackOperation == nil
            && artifactEditOperation == nil
            && promptResubmitOperation == nil
            && responseRegenerationOperation == nil
            && conversationForkOperation == nil
            && canGenerateRemotely()
            && routingState == .authoritative
            && historyState == .authoritative
            && hasValidMessageTree
            && hasSendableBranchParent
            && Self.hasUsableTarget(conversation)
            && skillSelectionDisabledReason == nil
            && uploadStatusMessage == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Drafting is local-first: a compatibility or connectivity restriction
    /// prevents remote submission, not writing and saving the next request.
    var canEditDraft: Bool {
        isDraftLoaded
            && promptResubmitOperation == nil
            && responseRegenerationOperation == nil
            && conversationForkOperation == nil
    }

    var canExportSelectedBranch: Bool {
        !isStreaming && visibleMessages.contains {
            !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var selectedBranchTranscript: String {
        ConversationTranscript.markdown(
            title: conversation.title,
            messages: visibleMessages
        )
    }

    /// Prompt insertion is deliberately a local draft mutation. It never
    /// invokes generation and never replaces text the user already authored.
    @discardableResult
    func insertPromptIntoDraft(_ text: String) -> Bool {
        guard canEditDraft,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if draft.isEmpty {
            draft = text
        } else {
            let separator = draft.hasSuffix("\n") ? "\n" : "\n\n"
            draft += separator + text
        }
        draftChanged()
        return true
    }

    /// Dictation is always a draft edit, never a send action. Existing text is
    /// preserved so the user can review the combined prompt before admission.
    @discardableResult
    func insertTranscriptionIntoDraft(_ text: String) -> Bool {
        guard canEditDraft else { return false }
        guard let merged = VoiceDictationDraft.merging(existing: draft, transcript: text) else {
            return false
        }
        draft = merged
        draftChanged()
        return true
    }

    var activeFollowUpItems: [FollowUpQueueItem] {
        (followUpQueue?.items ?? []).filter { item in
            if case .delivered = item.state { return false }
            if case .deliveredWithoutEpoch = item.state { return false }
            return true
        }
    }

    var isFollowUpMutationInProgress: Bool { followUpOperation != nil }

    func canRetryQueuedFollowUp(_ item: FollowUpQueueItem) -> Bool {
        guard case .queued = item.state,
              followUpOperation == nil,
              canGenerateRemotely(),
              routingState == .authoritative,
              historyState == .authoritative,
              item.namespace.profileID == profileID,
              item.namespace.accountID == accountID,
              item.namespace.conversationID == conversation.id,
              let signal = generationSnapshot.flatMap(followUpSignal(from:)),
              case let .completed(handle, _) = signal,
              handle == item.sourceAnchor.handle,
              generationSnapshot?.response?.parentMessageID == item.sourceAnchor.sourceUserMessageID
        else { return false }
        return true
    }

    var canQueueFollowUp: Bool {
        guard canGenerateRemotely(),
              isStreaming,
              selectedSkillNames.isEmpty,
              !conversation.isTemporaryConversation,
              followUpOperation == nil,
              !conversation.id.isLocalDraft,
              routingState == .authoritative,
              historyState != .unavailable,
              let target = conversation.target,
              (try? FollowUpTargetFingerprint(target: target)) != nil,
              followUpAttachmentCandidates != nil,
              activeFollowUpSource != nil else { return false }
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized.utf16.count <= 16_000
    }

    var followUpQueueDisabledReason: String? {
        guard isStreaming else { return nil }
        guard selectedSkillNames.isEmpty else {
            return "Skills stay with the live composer. Send this selection after the current response finishes."
        }
        guard !conversation.isTemporaryConversation else {
            return "Temporary Chat keeps the next message in the live composer instead of the durable queue."
        }
        guard canGenerateRemotely() else {
            return compatibilityWarning() ?? "Queueing is unavailable while offline."
        }
        guard followUpAttachmentCandidates != nil else {
            return uploadStatusMessage
                ?? "Every queued attachment must be complete and match the current chat target."
        }
        guard activeFollowUpSource != nil else {
            return "Queueing becomes available after LibreChat confirms this response’s message coordinates."
        }
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Write the next message before queueing it." }
        guard normalized.utf16.count <= 16_000 else {
            return "Shorten this queued message to 16,000 characters or fewer."
        }
        return followUpOperation == nil ? nil : "Finishing the current queue action."
    }

    var generationDisabledReason: String? {
        guard canGenerateRemotely() else {
            return compatibilityWarning() ?? "Sending is unavailable while offline."
        }
        // Transitional hydration states stay silent: the composer already
        // gates sending through `canSend`, and a frame of "verifying" copy
        // above the composer is noise, not information.
        guard routingState == .authoritative else { return nil }
        if let reason = targetUnavailableReason {
            return reason
        }
        guard historyState == .authoritative else { return nil }
        guard hasValidMessageTree else {
            return "LibreChat returned an inconsistent message tree. Refresh before sending."
        }
        guard hasSendableBranchParent else {
            return "Select a complete saved conversation branch before sending."
        }
        if let skillSelectionDisabledReason { return skillSelectionDisabledReason }
        return nil
    }

    var canPresentSkills: Bool {
        canUseSkillsRemotely()
            && canEditDraft
            // A local draft has no server routing to verify; its reviewed
            // target from the catalog is enough to scope the skill list.
            && (conversation.id.isLocalDraft || routingState == .authoritative)
            && conversation.target != nil
            && !isStreaming
            && activeGeneration == nil
    }

    var availableSkills: [ChatSkillSummary] {
        skillCatalog?.skills ?? []
    }

    var skillSelectionDisabledReason: String? {
        guard !selectedSkillNames.isEmpty else { return nil }
        guard canUseSkillsRemotely() else {
            return "Skills are no longer available for this account. Review the message setup before sending."
        }
        guard let target = conversation.target,
              let catalog = skillCatalog,
              catalog.profileID == profileID,
              catalog.accountID == accountID,
              catalog.target == target,
              catalog.isComplete else {
            return "Review the selected Skills against this model before sending."
        }
        do {
            _ = try catalog.validatedSelection(selectedSkillNames)
            return nil
        } catch {
            return error.userFacingMessage
        }
    }

    func refreshSkillCatalog() async {
        guard canPresentSkills, let target = conversation.target else {
            skillCatalogError = SkillInvocationError.unavailable.localizedDescription
            return
        }
        let expectedTarget = target
        isLoadingSkills = true
        skillCatalogError = nil
        defer { isLoadingSkills = false }
        do {
            let catalog = try await repository.skillInvocationCatalog(for: expectedTarget)
            try Task.checkCancellation()
            guard canUseSkillsRemotely(),
                  conversation.target == expectedTarget,
                  catalog.profileID == profileID,
                  catalog.accountID == accountID,
                  catalog.target == expectedTarget,
                  catalog.isComplete else {
                throw SkillInvocationError.targetChanged
            }
            skillCatalog = catalog
            if let disabled = skillSelectionDisabledReason {
                skillCatalogError = disabled
            }
        } catch is CancellationError {
            return
        } catch {
            skillCatalog = nil
            skillCatalogError = error.userFacingMessage
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    func toggleSkill(_ skill: ChatSkillSummary) {
        guard canPresentSkills,
              let catalog = skillCatalog,
              catalog.profileID == profileID,
              catalog.accountID == accountID,
              catalog.target == conversation.target,
              catalog.skills.contains(skill),
              skill.availability.isSelectable else { return }
        if let index = selectedSkillNames.firstIndex(of: skill.name) {
            selectedSkillNames.remove(at: index)
        } else if selectedSkillNames.count < 10 {
            selectedSkillNames.append(skill.name)
        } else {
            skillCatalogError = SkillInvocationError.tooManySelected.localizedDescription
        }
    }

    func removeSelectedSkill(named name: String) {
        selectedSkillNames.removeAll { $0 == name }
    }

    @discardableResult
    func replaceSelectedSkills(_ names: [String]) -> Bool {
        if names.isEmpty {
            selectedSkillNames = []
            skillCatalogError = nil
            return true
        }
        guard canPresentSkills,
              let target = conversation.target,
              let catalog = skillCatalog,
              catalog.profileID == profileID,
              catalog.accountID == accountID,
              catalog.target == target,
              catalog.isComplete else {
            skillCatalogError = SkillInvocationError.targetChanged.localizedDescription
            return false
        }
        do {
            selectedSkillNames = try catalog.validatedSelection(names)
            skillCatalogError = nil
            return true
        } catch {
            skillCatalogError = error.userFacingMessage
            return false
        }
    }

    var canStageAttachments: Bool {
        isDraftLoaded
            && (isStreaming || activeGeneration == nil)
            && promptResubmitOperation == nil
            && responseRegenerationOperation == nil
            && conversationForkOperation == nil
            && uploadManager != nil
            && hasValidMessageTree
            && routingState == .authoritative
            && Self.hasUsableTarget(conversation)
    }

    /// Target changes in the pinned LibreChat frontend normally begin a new
    /// conversation. Until native modular multi-chat exists, allow that
    /// transition only when leaving this screen cannot orphan an in-flight
    /// operation or silently retarget staged files.
    var canStartNewChatWithAnotherTarget: Bool {
        targetSwitchDisabledReason == nil
    }

    var targetSwitchDisabledReason: String? {
        if conversation.id.isLocalDraft, messages.isEmpty, !isStreaming {
            // An unsent canvas is exactly where the top-bar model dropdown
            // lives: switching re-points the draft in place, so it stays
            // allowed without waiting for routing verification.
            return nil
        }
        guard canGenerateRemotely() else {
            return compatibilityWarning() ?? "New chats are unavailable while offline."
        }
        guard !isStreaming, activeGeneration == nil, !isStopping else {
            return "Finish, stop, or resume the current response before starting another chat."
        }
        guard uploads.isEmpty else {
            return "Remove or send this chat’s attachments before choosing another target."
        }
        guard messageEditOperation == nil,
              messageFeedbackOperation == nil,
              promptResubmitOperation == nil,
              responseRegenerationOperation == nil,
              conversationForkOperation == nil,
              steeringOperation == nil,
              followUpOperation == nil,
              !isRespondingToInteraction else {
            return "Finish the current chat action before starting another chat."
        }
        return nil
    }

    var attachmentDisabledReason: String? {
        guard uploadManager != nil else { return "Uploads are not available for this profile." }
        guard isStreaming || activeGeneration == nil else {
            return "Resume or finish the saved response before adding attachments."
        }
        guard hasValidMessageTree else {
            return "Refresh this conversation before adding attachments."
        }
        guard routingState == .authoritative else {
            return "Attachments are available after this conversation’s server routing is verified."
        }
        if let reason = targetUnavailableReason {
            return reason
        }
        return nil
    }

    var shareTargetMessageID: MessageID? {
        guard hasValidMessageTree,
              let tail = selectedBranchTail,
              !Self.isLocalMessageID(tail.id) else { return nil }
        return tail.id
    }

    var canShareSelectedBranch: Bool {
        !conversation.id.isLocalDraft
            && !isStreaming
            && messageEditOperation == nil
            && messageFeedbackOperation == nil
            && promptResubmitOperation == nil
            && responseRegenerationOperation == nil
            && conversationForkOperation == nil
            && historyState == .authoritative
            && shareTargetMessageID != nil
    }

    var isSavingMessageEdit: Bool { messageEditOperation != nil }
    var isSavingMessageFeedback: Bool { messageFeedbackOperation != nil }
    var isResubmittingPrompt: Bool { promptResubmitOperation != nil }
    var isRegeneratingResponse: Bool { responseRegenerationOperation != nil }
    var isSteeringMutationInProgress: Bool { steeringOperation != nil }
    var isForkingConversation: Bool { conversationForkOperation != nil }

    var canGuideCurrentResponse: Bool {
        guard state == .loaded,
              isStreaming,
              !isStopping,
              steeringOperation == nil,
              uncertainSteering == nil,
              let handle = activeGeneration,
              owns(handle),
              handle.protocolVersion == 2,
              handle.generationCreatedAt.map({ $0 >= 0 }) == true,
              let snapshot = generationSnapshot,
              snapshot.handle == handle,
              !snapshot.state.isTerminal,
              snapshot.pendingInteraction == nil else { return false }
        if case .stopping = snapshot.state { return false }
        return true
    }

    var steeringStatusMessage: String? {
        guard uncertainSteering?.handle == activeGeneration else { return nil }
        return "Syncing your direction…"
    }

    func conversationForkSelection(
        for messageID: MessageID
    ) -> ConversationForkSelection? {
        guard state == .loaded,
              !conversation.id.isLocalDraft,
              !isStreaming,
              activeGeneration == nil,
              messageEditOperation == nil,
              promptResubmitOperation == nil,
              responseRegenerationOperation == nil,
              steeringOperation == nil,
              conversationForkOperation == nil,
              routingState == .authoritative,
              historyState == .authoritative,
              hasValidMessageTree,
              let target = visibleMessages.first(where: { $0.id == messageID }),
              !Self.isLocalMessageID(target.id),
              !uncertainConversationForkTargets.contains(target.id),
              target.isUnfinished != true else { return nil }
        return ConversationForkSelection(
            profileID: profileID,
            accountID: accountID,
            sourceConversationID: conversation.id,
            targetMessage: target
        )
    }

    func forkConversation(
        _ selection: ConversationForkSelection
    ) async throws -> ConversationForkResult {
        guard conversationForkOperation == nil,
              let current = conversationForkSelection(for: selection.targetMessage.id),
              current == selection else {
            throw ConversationForkPresentationError.stale
        }
        let operation = ConversationForkOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            sourceConversationID: conversation.id,
            targetMessageID: selection.targetMessage.id
        )
        conversationForkOperation = operation
        defer {
            if conversationForkOperation == operation { conversationForkOperation = nil }
        }
        do {
            let result = try await repository.fork(ConversationForkRequest(
                profileID: profileID,
                accountID: accountID,
                conversationID: conversation.id,
                targetMessageID: selection.targetMessage.id,
                option: .directPath,
                splitAtTarget: false,
                latestMessageID: nil
            ))
            guard conversationForkOperation == operation,
                  profileID == operation.profileID,
                  accountID == operation.accountID,
                  conversation.id == operation.sourceConversationID,
                  result.conversation.id != conversation.id,
                  !result.messages.isEmpty else {
                throw ConversationForkPresentationError.invalidResult
            }
            return result
        } catch is CancellationError {
            throw ConversationForkPresentationError.preflightUnavailable
        } catch {
            let presentation = ConversationForkPresentationError.from(error)
            if presentation == .deliveryUncertain || presentation == .invalidResult {
                uncertainConversationForkTargets.insert(selection.targetMessage.id)
            }
            if error.isUnauthorized { await onUnauthorized() }
            throw presentation
        }
    }

    func generationSteerSelection() -> GenerationSteerSelection? {
        guard canGuideCurrentResponse, let handle = activeGeneration else { return nil }
        return GenerationSteerSelection(
            handle: handle,
            clientSteerID: UUID().uuidString
        )
    }

    func submitSteer(
        _ selection: GenerationSteerSelection,
        text: String,
        preempt: Bool
    ) async throws -> GenerationSteerSubmissionOutcome {
        let draftState = GenerationSteerDraftState(draft: text)
        guard draftState.canSubmit else {
            throw GenerationSteeringPresentationError.invalidText
        }
        guard canGuideCurrentResponse,
              activeGeneration == selection.handle,
              generationSnapshot?.handle == selection.handle,
              owns(selection.handle) else {
            throw GenerationSteeringPresentationError.generationChanged
        }

        let operation = SteeringOperationKey(
            id: UUID(),
            handle: selection.handle,
            kind: .submit(clientSteerID: selection.clientSteerID)
        )
        steeringOperation = operation
        defer {
            if steeringOperation == operation { steeringOperation = nil }
        }

        do {
            let outcome = try await repository.submitSteer(GenerationSteerRequest(
                profileID: profileID,
                accountID: accountID,
                conversationID: conversation.id,
                handle: selection.handle,
                clientSteerID: selection.clientSteerID,
                text: draftState.normalizedText,
                preempt: preempt
            ))
            guard isCurrentSteeringOperation(operation) else {
                throw GenerationSteeringPresentationError.staleAcknowledgement
            }

            switch outcome {
            case let .queued(receipt), let .replayed(receipt):
                uncertainSteering = nil
                installAcceptedSteer(
                    receipt,
                    text: draftState.normalizedText,
                    handle: selection.handle
                )
                if preempt, !receipt.preempt {
                    errorMessage = "Direction queued for the next normal response boundary. Apply sooner is unavailable for this run."
                }
            case .settled:
                uncertainSteering = nil
                await reconcileSteeringState(handle: selection.handle)
            case let .leftover(receipt):
                uncertainSteering = nil
                installRecoverableSteer(
                    receipt,
                    text: draftState.normalizedText,
                    handle: selection.handle
                )
                errorMessage = "The response ended before this direction was applied. It was saved for explicit recovery."
                await reconcileSteeringState(handle: selection.handle)
            case let .deliveryUncertain(uncertainty):
                uncertainSteering = UncertainSteeringKey(
                    handle: selection.handle,
                    clientSteerID: uncertainty.clientSteerID,
                    steerID: uncertainty.steerID
                )
                errorMessage = "Direction delivery could not be verified. It will not be sent again until LibreChat reports its status."
                await reconcileSteeringState(handle: selection.handle)
            }
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            throw GenerationSteeringPresentationError.from(error)
        }
    }

    func cancelPendingSteer(_ steer: PendingSteer) {
        guard let request = steeringControlRequest(for: steer),
              steeringOperation == nil else { return }
        let operation = SteeringOperationKey(
            id: UUID(),
            handle: request.handle,
            kind: .cancel(steerID: request.steerID, clientSteerID: request.clientSteerID)
        )
        steeringOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if steeringOperation == operation { steeringOperation = nil }
            }
            do {
                let outcome = try await repository.cancelSteer(request)
                guard isCurrentSteeringOperation(operation) else { return }
                switch outcome {
                case .removed:
                    removeAcceptedSteer(steer, handle: request.handle)
                case .notRemoved:
                    errorMessage = "This direction could not be removed. Refreshing its current server state."
                    await reconcileSteeringState(handle: request.handle)
                case let .deliveryUncertain(uncertainty):
                    uncertainSteering = UncertainSteeringKey(
                        handle: request.handle,
                        clientSteerID: uncertainty.clientSteerID,
                        steerID: uncertainty.steerID
                    )
                    errorMessage = "Removal could not be verified. The action will not be repeated automatically."
                    await reconcileSteeringState(handle: request.handle)
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentSteeringOperation(operation) else { return }
                errorMessage = GenerationSteeringPresentationError.from(error).localizedDescription
                if error.isUnauthorized { await onUnauthorized() }
            }
        }
    }

    func armPendingSteer(_ steer: PendingSteer) {
        guard let request = steeringControlRequest(for: steer),
              steeringOperation == nil else { return }
        let operation = SteeringOperationKey(
            id: UUID(),
            handle: request.handle,
            kind: .arm(steerID: request.steerID, clientSteerID: request.clientSteerID)
        )
        steeringOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if steeringOperation == operation { steeringOperation = nil }
            }
            do {
                let outcome = try await repository.armSteer(request)
                guard isCurrentSteeringOperation(operation) else { return }
                switch outcome {
                case let .armed(preemptRevision):
                    armAcceptedSteer(steer, revision: preemptRevision, handle: request.handle)
                case .notArmed:
                    errorMessage = "Apply sooner is unavailable. The direction remains queued for a normal boundary."
                    await reconcileSteeringState(handle: request.handle)
                case let .deliveryUncertain(uncertainty):
                    uncertainSteering = UncertainSteeringKey(
                        handle: request.handle,
                        clientSteerID: uncertainty.clientSteerID,
                        steerID: uncertainty.steerID
                    )
                    errorMessage = "Apply-sooner delivery could not be verified. The action will not be repeated automatically."
                    await reconcileSteeringState(handle: request.handle)
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentSteeringOperation(operation) else { return }
                errorMessage = GenerationSteeringPresentationError.from(error).localizedDescription
                if error.isUnauthorized { await onUnauthorized() }
            }
        }
    }

    func canQueueRecoverableSteer(
        _ steer: PendingSteer,
        from batch: RecoverableSteerBatch
    ) -> Bool {
        guard canGenerateRemotely(),
              !conversation.isTemporaryConversation,
              followUpOperation == nil,
              uploads.isEmpty,
              routingState == .authoritative,
              historyState == .authoritative,
              batch.handle.profileID == profileID,
              batch.handle.accountID == accountID,
              batch.handle.conversationID == conversation.id,
              steer.clientSteerID != nil,
              steer.files.isEmpty,
              !steer.text.isEmpty,
              steer.text == steer.text.trimmingCharacters(in: .whitespacesAndNewlines),
              steer.text.utf16.count <= 16_000,
              recoverableCompletionSignal(for: batch.handle) != nil else { return false }
        return batch.steers.contains { $0.recoveryIdentity == steer.recoveryIdentity }
    }

    func queueRecoverableSteer(
        _ steer: PendingSteer,
        from batch: RecoverableSteerBatch
    ) {
        guard canQueueRecoverableSteer(steer, from: batch),
              let signal = recoverableCompletionSignal(for: batch.handle),
              let sourceUserID = generationSnapshot?.response?.parentMessageID,
              let target = conversation.target else { return }
        let identity = steer.recoveryIdentity
        let operation = FollowUpOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            kind: .enqueueRecovery(handle: batch.handle, identity: identity)
        )
        followUpOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if followUpOperation == operation { followUpOperation = nil }
            }
            do {
                let current = try await repository.followUpQueue(
                    conversationID: operation.conversationID
                )
                let namespace = try FollowUpQueueNamespace(
                    profileID: profileID,
                    accountID: accountID,
                    conversationID: conversation.id
                )
                let recovery = try FollowUpRecoverableSource(
                    handle: batch.handle,
                    identity: identity
                )
                let item = try FollowUpQueueItem(
                    id: FollowUpQueueItemID(),
                    namespace: namespace,
                    order: try Self.nextFollowUpOrder(after: current),
                    text: steer.text,
                    target: FollowUpTargetFingerprint(target: target),
                    sourceAnchor: FollowUpSourceAnchor(
                        handle: batch.handle,
                        sourceUserMessageID: sourceUserID
                    ),
                    recoverableSource: recovery
                )
                let updated = try await repository.enqueueFollowUp(item)
                try Task.checkCancellation()
                guard isCurrentFollowUpOperation(operation) else { return }
                followUpQueue = updated
                await continueWithFollowUpQueue(after: signal, operationID: nil)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentFollowUpOperation(operation) else { return }
                errorMessage = "The saved direction was not queued. \(error.userFacingMessage)"
                if error.isUnauthorized { await onUnauthorized() }
            }
        }
    }

    func discardRecoverableSteer(
        _ steer: PendingSteer,
        from batch: RecoverableSteerBatch
    ) {
        let identity = steer.recoveryIdentity
        guard followUpOperation == nil,
              batch.handle.profileID == profileID,
              batch.handle.accountID == accountID,
              batch.handle.conversationID == conversation.id,
              steer.clientSteerID != nil,
              batch.steers.contains(where: { $0.recoveryIdentity == identity }) else { return }
        let operation = FollowUpOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            kind: .discardRecovery(handle: batch.handle, identity: identity)
        )
        followUpOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if followUpOperation == operation { followUpOperation = nil }
            }
            do {
                let outcome = try await repository.discardRecoverableSteer(
                    RecoverableSteerDiscardRequest(
                        profileID: profileID,
                        accountID: accountID,
                        conversationID: conversation.id,
                        sourceHandle: batch.handle,
                        identity: identity
                    )
                )
                guard isCurrentFollowUpOperation(operation) else { return }
                switch outcome {
                case .discarded:
                    await refreshFollowUpState()
                    errorMessage = nil
                case .notRemoved:
                    await refreshFollowUpState()
                    errorMessage = "LibreChat did not confirm removal. The saved direction remains available."
                case .conflict:
                    await refreshFollowUpState()
                    errorMessage = "This saved direction changed on the server. Review the refreshed recovery state."
                case .unauthorized:
                    await onUnauthorized()
                case .deliveryUncertain:
                    errorMessage = "Removal could not be verified. It will not be repeated automatically."
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentFollowUpOperation(operation) else { return }
                errorMessage = "The saved direction was not removed. \(error.userFacingMessage)"
                if error.isUnauthorized { await onUnauthorized() }
            }
        }
    }

    var visibleMessageEntries: [MessageTree.BranchEntry] { renderProjection.visibleEntries }

    var visibleMessages: [ChatMessage] { renderProjection.visibleMessages }

    var pendingGeneratedFilePreviewSignature: [GeneratedFilePreviewPollingSignature] {
        visibleMessages.flatMap { message in
            message.content.compactMap { content -> GeneratedFilePreviewPollingSignature? in
                guard case let .generatedFile(file) = content,
                      file.lifecycle == .pending,
                      let fileID = file.fileID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !fileID.isEmpty else { return nil }
                return GeneratedFilePreviewPollingSignature(
                    fileID: fileID,
                    identity: file.identity,
                    messageID: message.id,
                    conversationID: message.conversationID
                )
            }
        }
        .sorted {
            ($0.fileID, $0.messageID.rawValue, $0.identity.resourceID,
             $0.identity.toolCallID ?? "", $0.identity.agentID ?? "")
                < ($1.fileID, $1.messageID.rawValue, $1.identity.resourceID,
                   $1.identity.toolCallID ?? "", $1.identity.agentID ?? "")
        }
    }

    func generatedFile(matching identity: GeneratedFileIdentity) -> GeneratedFile? {
        messages.lazy.flatMap(\.content).compactMap { content -> GeneratedFile? in
            guard case let .generatedFile(file) = content,
                  file.identity == identity else { return nil }
            return file
        }.first
    }

    func synchronizeGeneratedFilePreviewPolling(isActive: Bool) async {
        if generatedFilePreviewPollingCoordinator == nil {
            generatedFilePreviewPollingCoordinator = GeneratedFilePreviewPollingCoordinator(
                repository: repository,
                onUpdate: { @MainActor [weak self] updated in
                    self?.replaceGeneratedFile(updated)
                },
                onUnauthorized: { @MainActor [weak self] in
                    guard let self else { return }
                    await self.onUnauthorized()
                }
            )
        }
        await generatedFilePreviewPollingCoordinator?.synchronize(
            files: pendingGeneratedFilePreviews,
            isActive: isActive
        )
    }

    func stopGeneratedFilePreviewPolling() async {
        await generatedFilePreviewPollingCoordinator?.stop()
        generatedFilePreviewPollingCoordinator = nil
    }

    var hasValidMessageTree: Bool { renderProjection.isStructurallyValid }

    private var messageTree: MessageTree { cachedMessageTree }

    private var selectedBranchTail: ChatMessage? { renderProjection.visibleMessages.last }

    private var activeFollowUpSource: FollowUpSourceContext? {
        guard let handle = activeGeneration,
              owns(handle),
              handle.protocolVersion == 2,
              handle.generationCreatedAt.map({ $0 >= 0 }) == true,
              let snapshot = generationSnapshot,
              snapshot.handle == handle,
              !snapshot.state.isTerminal,
              let userMessageID = snapshot.response?.parentMessageID,
              !Self.isUnsavedMessageID(userMessageID) else { return nil }
        return FollowUpSourceContext(handle: handle, userMessageID: userMessageID)
    }

    /// A root generation is valid only when authoritative history is empty.
    /// Any nonempty history must resolve to an exact, persisted branch tail.
    private var hasSendableBranchParent: Bool {
        if messages.isEmpty { return true }
        guard let tail = selectedBranchTail else { return false }
        return !Self.isLocalMessageID(tail.id)
    }

    var uploadStatusMessage: String? {
        if uploads.contains(where: { $0.state == .deliveryUncertain }) {
            return "An attachment may have reached LibreChat, but its acknowledgement was lost. Check its status or remove it; the file will not be posted again."
        }
        if uploads.contains(where: { $0.state == .failed }) {
            return "Retry failed attachments before sending."
        }
        if uploads.contains(where: { $0.state == .staged || $0.state == .uploading }) {
            return "Wait for attachments to finish uploading."
        }
        if uploads.contains(where: { $0.state == .completed && $0.remoteFile == nil }) {
            return "One attachment did not return a valid server file reference."
        }
        return nil
    }

    private var followUpAttachmentCandidates: [FollowUpQueuedAttachment]? {
        guard let target = conversation.target else { return nil }
        var result: [FollowUpQueuedAttachment] = []
        for upload in uploads {
            guard upload.profileID == profileID,
                  upload.accountID == accountID,
                  upload.conversationID == conversation.id,
                  upload.state == .completed,
                  upload.endpoint == target.endpoint,
                  upload.endpointType == target.endpointType,
                  let file = upload.remoteFile,
                  let attachment = try? FollowUpQueuedAttachment(
                      uploadID: upload.id,
                      file: file
                  ) else { return nil }
            result.append(attachment)
        }
        return result
    }

    // MARK: - Execution target presentation
    //
    // The pill always presents the CONVERSATION's own routing, read straight
    // off the mounted conversation object — never gated on hydration state.
    // Gating these on `routingState == .authoritative` made the selection
    // visually reset to a generic fallback every time a chat page hydrated
    // (switching conversations, reopening a draft, app resume), which read as
    // "the model got deselected" even though the routing itself never changed.

    var executionTargetSpec: String? {
        conversation.target?.spec
    }

    var executionTargetModel: String? {
        conversation.target?.model ?? conversation.model
    }

    var executionSelectedAgentOrAssistant: String? {
        if nonEmpty(conversation.target?.agentID) != nil { return "Selected agent" }
        if nonEmpty(conversation.target?.assistantID) != nil { return "Selected assistant" }
        return nil
    }

    var executionTargetEndpoint: String? {
        conversation.target?.endpoint
    }

    var executionAttachmentState: String? {
        guard !uploads.isEmpty else { return nil }
        if uploads.contains(where: {
            $0.state == .failed
                || $0.state == .deliveryUncertain
                || ($0.state == .completed && $0.remoteFile == nil)
        }) {
            return "needs attention"
        }
        if uploads.contains(where: { $0.state == .staged || $0.state == .uploading }) {
            return "uploading"
        }
        return "ready"
    }

    /// A privacy-bounded description of model-spec execution scope. The
    /// server-owned MCP and artifact identifiers never enter presentation.
    var executionCapabilities: [String]? {
        guard let configuration = conversation.target?.ephemeralAgent,
              configuration.isSafeForRequest else {
            return nil
        }

        var capabilities: [String] = []
        if configuration.webSearch { capabilities.append("Web search") }
        if configuration.fileSearch { capabilities.append("File search") }
        if configuration.executeCode { capabilities.append("Code execution") }
        if configuration.memory { capabilities.append("Memory") }
        if !configuration.mcpServers.isEmpty {
            let count = configuration.mcpServers.count
            capabilities.append("MCP (\(count) \(count == 1 ? "server" : "servers"))")
        }
        if configuration.artifacts != .disabled { capabilities.append("Artifacts") }
        return capabilities
    }

    func loadIfNeeded() async {
        guard state == .idle else { return }
        // Draft hydration runs alongside the message loads instead of ahead
        // of them: the transcript is the thing the user is waiting for.
        func hydrateDraft() async {
            if conversation.isTemporaryConversation {
                draft = ""
            } else {
                draft = await repository.draft(conversationID: conversation.id)
            }
            isDraftLoaded = true
            #if DEBUG
            // UI-test seeding: fill the draft from the launch environment so
            // E2E runs never depend on synthesized keyboard focus.
            if draft.isEmpty, let seededDraft = ProcessInfo.processInfo.environment["E2E_DRAFT"] {
                draft = seededDraft
                draftChanged()
            }
            #endif
            observeUploads()
        }

        if conversation.id.isLocalDraft {
            await hydrateDraft()
            state = .loaded
            return
        }
        async let draftHydration: Void = hydrateDraft()
        let hydrationStart = Date()
        await loadCache()
        let cacheMs = Date().timeIntervalSince(hydrationStart) * 1000
        let reloadStart = Date()
        await reload()
        let reloadMs = Date().timeIntervalSince(reloadStart) * 1000
        await draftHydration
        await recoverGenerationIfNeeded()
        await refreshFollowUpState()
        if messages.count >= 500 || cacheMs > 250 || reloadMs > 250 {
            AppLog.perf.debug(
                "chat-hydration conversation=\(self.conversation.id.rawValue, privacy: .private) cacheMs=\(Int(cacheMs)) reloadMs=\(Int(reloadMs)) messages=\(self.messages.count)"
            )
        }
    }

    func reload() async {
        guard messageEditOperation == nil,
              messageFeedbackOperation == nil,
              promptResubmitOperation == nil,
              responseRegenerationOperation == nil else { return }
        if conversation.id.isLocalDraft {
            state = .loaded
            return
        }
        let expectedConversationID = conversation.id
        let previousState = state
        let previousRoutingState = routingState
        let previousHistoryState = historyState
        if messages.isEmpty { state = .loading }
        routingState = .hydrating
        historyState = .loading

        var routingError: Error?
        var installedAuthoritativeConversation = false
        do {
            let authoritative = try await repository.conversation(id: expectedConversationID)
            try Task.checkCancellation()
            guard conversation.id == expectedConversationID,
                  authoritative.id == expectedConversationID,
                  Self.hasUsableTarget(authoritative) else {
                throw ConversationHydrationFailure.invalidAuthoritativeConversation
            }
            installAuthoritativeConversation(authoritative, expectedID: expectedConversationID)
            installedAuthoritativeConversation = true
        } catch is CancellationError {
            routingState = previousRoutingState
            historyState = previousHistoryState
            state = previousState
            return
        } catch {
            if error.isUnauthorized {
                await handleUnauthorizedHydrationFailure(error)
                return
            }
            routingState = .unavailable
            routingError = error
        }

        do {
            let fetchStart = Date()
            let authoritativeMessages = try await repository.messages(
                conversationID: expectedConversationID
            )
            let fetchMs = Date().timeIntervalSince(fetchStart) * 1000
            try Task.checkCancellation()
            guard conversation.id == expectedConversationID else { return }
            let installStart = Date()
            installMessages(authoritativeMessages)
            let installMs = Date().timeIntervalSince(installStart) * 1000
            if authoritativeMessages.count >= 500 || fetchMs > 250 || installMs > 250 {
                AppLog.perf.debug(
                    "chat-reload fetchMs=\(Int(fetchMs)) installMs=\(Int(installMs)) count=\(authoritativeMessages.count)"
                )
            }
            uncertainFeedbackTargets.removeAll()
            historyState = .authoritative
            state = .loaded
            isShowingCache = false
            errorMessage = routingError == nil
                ? nil
                : "Conversation details are unavailable. Sending and attachments remain disabled."
        } catch is CancellationError {
            if !installedAuthoritativeConversation { routingState = previousRoutingState }
            historyState = previousHistoryState
            state = previousState
            return
        } catch {
            if error.isUnauthorized {
                await handleUnauthorizedHydrationFailure(error)
                return
            }
            let hasBrowsableServerHistory = messages.contains {
                !$0.id.rawValue.hasPrefix("local-")
            }
            historyState = hasBrowsableServerHistory ? .cachedAfterFailure : .unavailable
            state = hasBrowsableServerHistory ? .loaded : .failed(error.userFacingMessage)
            isShowingCache = hasBrowsableServerHistory
            if hasBrowsableServerHistory {
                errorMessage = routingError == nil
                    ? "Offline or unavailable. Showing saved messages. Sending is disabled until history refreshes."
                    : "Offline or unavailable. Showing saved messages while conversation details refresh."
            } else if routingError != nil {
                errorMessage = conversation.isTemporaryConversation
                    ? "Temporary Chat details and history are unavailable. This chat is not stored for offline recovery."
                    : "Conversation details and history are unavailable. Your draft is still saved locally."
            } else {
                errorMessage = "Authoritative conversation history is unavailable. Sending remains disabled."
            }
        }
    }

    func draftChanged() {
        draftTask?.cancel()
        guard !conversation.isTemporaryConversation else {
            draftTask = nil
            return
        }
        let text = draft
        draftTask = Task { [repository, conversation] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await repository.saveDraft(text, conversationID: conversation.id)
        }
    }

    func checkpointDraft() async {
        draftTask?.cancel()
        draftTask = nil
        guard !conversation.isTemporaryConversation else { return }
        await repository.saveDraft(draft, conversationID: conversation.id)
    }

    func queueDraftFollowUp() {
        guard canQueueFollowUp,
              let source = activeFollowUpSource,
              let target = conversation.target,
              let queuedAttachments = followUpAttachmentCandidates else {
            errorMessage = followUpQueueDisabledReason
            return
        }
        let normalizedText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = FollowUpOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            kind: .enqueueDraft(source: source.handle)
        )
        followUpOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if followUpOperation == operation { followUpOperation = nil }
            }
            do {
                let current = try await repository.followUpQueue(
                    conversationID: operation.conversationID
                )
                try Task.checkCancellation()
                guard isCurrentFollowUpOperation(operation),
                      activeGeneration == source.handle else {
                    throw FollowUpQueueError.contextMismatch
                }
                let nextOrder = try Self.nextFollowUpOrder(after: current)
                let namespace = try FollowUpQueueNamespace(
                    profileID: profileID,
                    accountID: accountID,
                    conversationID: conversation.id
                )
                let item = try FollowUpQueueItem(
                    id: FollowUpQueueItemID(),
                    namespace: namespace,
                    order: nextOrder,
                    text: normalizedText,
                    attachments: queuedAttachments,
                    target: FollowUpTargetFingerprint(target: target),
                    sourceAnchor: FollowUpSourceAnchor(
                        handle: source.handle,
                        sourceUserMessageID: source.userMessageID
                    )
                )
                let updated = try await repository.enqueueFollowUp(item)
                try Task.checkCancellation()
                guard isCurrentFollowUpOperation(operation) else { return }
                followUpQueue = updated
                if !queuedAttachments.isEmpty {
                    do {
                        try await uploadManager?.markQueued(
                            ids: queuedAttachments.map(\.uploadID),
                            conversationID: conversation.id
                        )
                    } catch {
                        // The queue journal is authoritative and the upload's
                        // completed state still renews its server hold. Never
                        // report the already-persisted item as not queued.
                        AppLog.uploads.error(
                            "Queued attachment ownership will be reconciled from the durable journal."
                        )
                    }
                    removeQueueOwnedUploadsFromComposer()
                }
                draftTask?.cancel()
                draftTask = nil
                draft = ""
                await repository.saveDraft("", conversationID: conversation.id)
                errorMessage = nil

                if let terminal = generationSnapshot.flatMap({ followUpSignal(from: $0) }),
                   terminal.handle == source.handle {
                    await continueWithFollowUpQueue(
                        after: terminal,
                        operationID: activeOperationID
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentFollowUpOperation(operation) else { return }
                errorMessage = "This message was not queued. \(error.userFacingMessage)"
                if error.isUnauthorized { await onUnauthorized() }
            }
        }
    }

    func removeQueuedFollowUp(_ item: FollowUpQueueItem) {
        let canRemove: Bool
        switch item.state {
        case .queued, .blocked:
            canRemove = true
        case .reserved, .admitted, .deliveryUncertain, .committed,
             .deliveredWithoutEpoch, .delivered:
            canRemove = false
        }
        guard canRemove,
              followUpOperation == nil,
              item.namespace.profileID == profileID,
              item.namespace.accountID == accountID,
              item.namespace.conversationID == conversation.id else { return }
        let operation = FollowUpOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            kind: .remove(item.id)
        )
        followUpOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if followUpOperation == operation { followUpOperation = nil }
            }
            do {
                let updated = try await repository.removeQueuedFollowUp(
                    itemID: item.id,
                    conversationID: operation.conversationID
                )
                guard isCurrentFollowUpOperation(operation) else { return }
                followUpQueue = updated
                let remainingUploadIDs = Set(updated.items.flatMap { $0.attachments.map(\.uploadID) })
                let releasedUploadIDs = item.attachments.map(\.uploadID).filter {
                    !remainingUploadIDs.contains($0)
                }
                if !releasedUploadIDs.isEmpty {
                    try await uploadManager?.markUnqueued(
                        ids: releasedUploadIDs,
                        conversationID: conversation.id
                    )
                }
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentFollowUpOperation(operation) else { return }
                errorMessage = "The queued message could not be removed. \(error.userFacingMessage)"
                if error.isUnauthorized { await onUnauthorized() }
            }
        }
    }

    func retryQueuedFollowUp(_ item: FollowUpQueueItem) {
        guard canRetryQueuedFollowUp(item),
              let signal = generationSnapshot.flatMap(followUpSignal(from:)) else { return }
        let operation = FollowUpOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            kind: .retry(item.id, source: signal.handle)
        )
        followUpOperation = operation
        Task { [weak self] in
            guard let self else { return }
            defer {
                if followUpOperation == operation { followUpOperation = nil }
            }
            _ = await continueWithFollowUpQueue(after: signal, operationID: nil)
        }
    }

    func selectSibling(
        _ messageID: MessageID,
        under parent: MessageTree.BranchParent
    ) {
        guard messageEditOperation == nil,
              promptResubmitOperation == nil,
              responseRegenerationOperation == nil else { return }
        let tree = messageTree
        guard tree.isStructurallyValid,
              let siblingSelection = tree.siblings(containing: messageID) else { return }
        let resolvedParent: MessageTree.BranchParent = siblingSelection.parentMessageID
            .map(MessageTree.BranchParent.message) ?? .root
        guard resolvedParent == parent else { return }
        branchSelection[parent] = messageID
    }

    /// Selects the exact ancestor path needed to reveal a message-search hit.
    /// Only the current conversation's authoritative, structurally valid
    /// history is eligible; stale search results never choose a nearby branch.
    func focusSearchResult(
        _ request: ConversationMessageFocusRequest
    ) -> SearchResultFocusOutcome {
        guard request.conversationID == conversation.id,
              historyState == .authoritative else { return .unavailable }

        let tree = messageTree
        guard tree.isStructurallyValid,
              let focusedSelections = tree.selections(focusing: request.messageID) else {
            errorMessage = "The matched message is no longer available in this conversation."
            return .unavailable
        }

        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        branchSelection = tree.validSelections(from: branchSelection)
        branchSelection.merge(focusedSelections) { _, focused in focused }
        return .focused(request.messageID)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else {
            errorMessage = generationDisabledReason
            return
        }

        let originalDraft = draft
        let originalManualSkills = selectedSkillNames
        let completedUploads = uploads.filter { $0.state == .completed }
        let attachments = completedUploads.compactMap(\.remoteFile)
        guard completedUploads.count == attachments.count else {
            errorMessage = "One attachment is not ready to send."
            return
        }
        // `messages` is the complete flat server graph. Its final element can
        // belong to an unselected branch; only the projected branch tail is a
        // valid generation head. Nil is reserved for an authoritative empty
        // history (including a native local draft's first send).
        let parentID = selectedBranchTail?.id
        guard messages.isEmpty || parentID != nil else {
            errorMessage = "Select a complete saved conversation branch before sending."
            return
        }
        let localUserID = MessageID(rawValue: "local-user-\(UUID().uuidString)")
        let localAssistantID = MessageID(rawValue: "local-assistant-\(UUID().uuidString)")
        let operationID = UUID()
        let expectedPredecessorCreatedAt: Int64? = if let snapshot = generationSnapshot,
                                                      snapshot.handle.conversationID == conversation.id {
            switch snapshot.state {
            case .completed, .aborted, .failed: snapshot.handle.generationCreatedAt
            default: nil
            }
        } else {
            nil
        }

        branchSelectionBeforeOptimisticSend = branchSelection
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        messages.append(ChatMessage(
            id: localUserID,
            conversationID: conversation.id,
            parentMessageID: parentID,
            content: [.text(text)] + attachments.map(MessageContent.file),
            author: .user,
            model: conversation.model,
            endpoint: conversation.target?.endpoint,
            createdAt: Date(),
            manualSkills: originalManualSkills.isEmpty ? nil : originalManualSkills
        ))
        messages.append(ChatMessage(
            id: localAssistantID,
            conversationID: conversation.id,
            parentMessageID: localUserID,
            content: [.text("")],
            author: .assistant(name: conversation.model ?? "Assistant"),
            model: conversation.model,
            endpoint: conversation.target?.endpoint,
            createdAt: Date()
        ))
        branchSelection[parentID.map(MessageTree.BranchParent.message) ?? .root] = localUserID
        branchSelection[.message(localUserID)] = localAssistantID

        optimisticUserID = localUserID
        optimisticAssistantID = localAssistantID
        draft = ""
        selectedSkillNames = []
        draftChanged()
        errorMessage = nil
        generationSnapshot = nil
        isStreaming = true
        historyState = .notCurrent
        isStopping = false
        stopRequested = false
        activeOperationID = operationID

        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.performSend(
                text: text,
                originalDraft: originalDraft,
                originalManualSkills: originalManualSkills,
                parentMessageID: parentID,
                attachments: attachments,
                uploadIDs: completedUploads.map(\.id),
                expectedPredecessorCreatedAt: expectedPredecessorCreatedAt,
                operationID: operationID
            )
        }
    }

    func stop() {
        guard isStreaming,
              !isStopping,
              steeringOperation == nil,
              let operationID = activeOperationID else { return }
        stopRequested = true
        isStopping = true
        if let generation = activeGeneration {
            requestStop(generation, operationID: operationID)
        }
    }

    func retryRecovery() {
        if let key = respondingInteractionKey,
           let interaction = generationSnapshot?.pendingInteraction,
           interaction == key.interaction,
           activeGeneration == key.handle,
           let operationID = activeOperationID,
           owns(key.handle) {
            interactionTask?.cancel()
            interactionTask = Task { [weak self] in
                guard let self else { return }
                await reconcileAmbiguousInteractionSubmission(
                    key: key,
                    submittedInteraction: interaction,
                    operationID: operationID
                )
            }
            return
        }
        guard let handle = activeGeneration,
              owns(handle),
              !isStreaming else { return }
        sendTask?.cancel()
        isStreaming = true
        errorMessage = nil
        let operationID = UUID()
        activeOperationID = operationID
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.resume(handle)
            } catch is CancellationError {
                return
            } catch {
                guard activeOperationID == operationID, activeGeneration == handle else { return }
                isStreaming = false
                errorMessage = error.userFacingMessage
                if error.isUnauthorized { await onUnauthorized() }
                return
            }
            await consumeSnapshots(handle: handle, operationID: operationID)
        }
    }

    /// Reattaches the visible chat after app-level foreground reconciliation.
    ///
    /// Every signal is consumed at most once. Existing generation ownership is
    /// exact-handle matched; a chat without an active handle may adopt only a
    /// reconciled snapshot in its own profile/account/conversation namespace.
    func applyForegroundGenerationRecovery(_ signal: GenerationRecoverySignal) async {
        guard signal.sequence != lastGenerationRecoverySequence,
              signal.profileID == profileID,
              signal.accountID == accountID else { return }

        // Consume before the first suspension so duplicate deliveries of the
        // same app-level signal cannot race through queue refresh or stream
        // attachment. Queue reconciliation runs before active-job discovery,
        // so the visible chat must refresh that journal even when no active
        // generation snapshot remains.
        lastGenerationRecoverySequence = signal.sequence
        let priorFollowUpQueue = followUpQueue
        await refreshFollowUpState()
        if followUpQueue != priorFollowUpQueue {
            await reload()
        }

        if signal.trigger == .connectivity {
            await applyConnectivityGenerationRecovery(signal)
            return
        }

        let ownedSnapshots = signal.activeSnapshots
            .filter { owns($0.handle) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let previouslyActiveHandle = activeGeneration
        let recoveredSnapshot: GenerationSnapshot?
        if let previouslyActiveHandle {
            recoveredSnapshot = ownedSnapshots.first { $0.handle == previouslyActiveHandle }
        } else {
            recoveredSnapshot = ownedSnapshots.first
        }
        guard let handle = recoveredSnapshot?.handle ?? previouslyActiveHandle,
              owns(handle) else {
            return
        }

        sendTask?.cancel()
        sendTask = nil
        let operationID = UUID()
        activeOperationID = operationID
        activeGeneration = handle
        isStreaming = true
        isStopping = false
        errorMessage = nil
        await Task.yield()

        do {
            try Task.checkCancellation()
            let snapshot = if let recoveredSnapshot {
                recoveredSnapshot
            } else {
                try await repository.reconcile(handle)
            }
            try Task.checkCancellation()
            guard owns(handle),
                  activeGeneration == handle,
                  activeOperationID == operationID,
                  lastGenerationRecoverySequence == signal.sequence else { return }

            apply(snapshot)
            if snapshot.state.isTerminal {
                let followUpSignal = self.followUpSignal(from: snapshot)
                await reloadAfterGeneration()
                guard activeGeneration == handle, activeOperationID == operationID else { return }
                if let followUpSignal,
                   await continueWithFollowUpQueue(
                       after: followUpSignal,
                       operationID: operationID
                   ) {
                    return
                }
                finishOperation(operationID)
                return
            }

            AppLog.generation.info(
                "Visible chat accepted foreground generation recovery; activeMatch=\(recoveredSnapshot != nil, privacy: .public)."
            )
            try await repository.resume(handle)
            try Task.checkCancellation()
            guard activeGeneration == handle, activeOperationID == operationID else { return }
            await consumeSnapshots(handle: handle, operationID: operationID)
        } catch is CancellationError {
            return
        } catch {
            guard activeGeneration == handle, activeOperationID == operationID else { return }
            isStreaming = false
            isStopping = false
            errorMessage = "A saved response is waiting to be resumed. \(error.userFacingMessage)"
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    #if DEBUG
    /// Installs a server-proven replacement epoch for deterministic race tests.
    /// Production replacement/handoff paths retain their own reconciliation
    /// proof; this seam exists only so suspended mutation acknowledgements can
    /// be verified against a generation identity change without weakening the
    /// foreground exact-handle adoption policy.
    func installAuthoritativeGenerationForTesting(_ snapshot: GenerationSnapshot) {
        guard owns(snapshot.handle) else { return }
        activeOperationID = UUID()
        activeGeneration = snapshot.handle
        generationSnapshot = snapshot
        isStreaming = !snapshot.state.isTerminal
        isStopping = false
        stopRequested = false
        errorMessage = nil
    }
    #endif

    /// Reopens a paused, owned stream once for an offline-to-online signal.
    ///
    /// Connectivity recovery never adopts a newly discovered handle and never
    /// interrupts a live stream. Foreground recovery remains responsible for
    /// the broader reconciliation/adoption path.
    private func applyConnectivityGenerationRecovery(_ signal: GenerationRecoverySignal) async {
        lastGenerationRecoverySequence = signal.sequence
        guard canGenerateRemotely(),
              !isStreaming,
              let handle = activeGeneration,
              owns(handle),
              generationSnapshot?.state.isTerminal != true,
              let snapshot = signal.activeSnapshots.first(where: {
                  $0.handle == handle && owns($0.handle) && !$0.state.isTerminal
              }) else { return }

        // The sequence was consumed before suspension, so duplicate view
        // deliveries cannot produce a second retry for this connectivity edge.
        sendTask?.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        isStreaming = true
        isStopping = false
        errorMessage = nil
        apply(snapshot)
        await Task.yield()

        do {
            try Task.checkCancellation()
            guard activeGeneration == handle,
                  activeOperationID == operationID,
                  generationSnapshot?.state.isTerminal != true else { return }
            try await repository.resume(handle)
            try Task.checkCancellation()
            guard activeGeneration == handle,
                  activeOperationID == operationID else { return }
            await consumeSnapshots(handle: handle, operationID: operationID)
        } catch is CancellationError {
            return
        } catch {
            guard activeGeneration == handle,
                  activeOperationID == operationID else { return }
            isStreaming = false
            isStopping = false
            errorMessage = "A saved response is waiting to be resumed. \(error.userFacingMessage)"
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    func respondToInteraction(
        toolResolutions: [ToolApprovalResolution]? = nil,
        answer: String? = nil,
        batchAnswers: [String: String]? = nil
    ) {
        guard let snapshot = generationSnapshot,
              let interaction = snapshot.pendingInteraction,
              snapshot.state == .awaitingApproval(interaction),
              owns(snapshot.handle),
              activeGeneration == snapshot.handle,
              !isRespondingToInteraction else { return }
        let key = InteractionSubmissionKey(
            handle: snapshot.handle,
            interaction: interaction
        )
        let operationID = activeOperationID ?? UUID()
        activeOperationID = operationID
        isRespondingToInteraction = true
        respondingInteractionKey = key
        interactionTask?.cancel()
        if interactionIsExpired(interaction, at: now()) {
            errorMessage = "This request has expired. Checking LibreChat’s current generation status."
            interactionTask = Task { [weak self] in
                guard let self else { return }
                await reconcileAmbiguousInteractionSubmission(
                    key: key,
                    submittedInteraction: interaction,
                    operationID: operationID
                )
            }
            return
        }
        interactionTask = Task { [weak self] in
            guard let self else { return }
            let acknowledged: GenerationSnapshot
            do {
                acknowledged = try await repository.respond(
                    to: interaction,
                    handle: snapshot.handle,
                    toolResolutions: toolResolutions,
                    answer: answer,
                    batchAnswers: batchAnswers
                )
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentInteractionSubmission(key, operationID: operationID) else { return }
                if error.isUnauthorized {
                    clearInteractionSubmission(key)
                    await onUnauthorized()
                    return
                }
                if error.isSafeToRetryPendingInteraction {
                    clearInteractionSubmission(key)
                    errorMessage = error.userFacingMessage
                    return
                }
                await reconcileAmbiguousInteractionSubmission(
                    key: key,
                    submittedInteraction: interaction,
                    operationID: operationID
                )
                return
            }

            do {
                try Task.checkCancellation()
                guard isCurrentInteractionSubmission(key, operationID: operationID) else { return }
                apply(acknowledged)
                isRespondingToInteraction = false
                respondingInteractionKey = nil
                isStreaming = true
                errorMessage = nil
                try await repository.resume(snapshot.handle)
                try Task.checkCancellation()
                guard activeGeneration == snapshot.handle,
                      activeOperationID == operationID else { return }
                await consumeSnapshots(
                    handle: snapshot.handle,
                    operationID: operationID,
                    cancellationPolicy: .acknowledgedInteraction
                )
            } catch is CancellationError {
                // The acknowledgement already consumed the server action.
                // Cancellation while reopening SSE is a recoverable attach
                // failure, never a reason to restore or repost the action.
                await handleAcknowledgedInteractionAttachFailure(
                    CancellationError(),
                    handle: snapshot.handle,
                    operationID: operationID
                )
                return
            } catch {
                await handleAcknowledgedInteractionAttachFailure(
                    error,
                    handle: snapshot.handle,
                    operationID: operationID
                )
            }
        }
    }

    func attach(data: Data, filename: String, mimeType: String?) async {
        guard canStageAttachments,
              let uploadManager,
              let target = conversation.target else {
            errorMessage = attachmentDisabledReason ?? "Attachments are not available right now."
            return
        }
        do {
            _ = try await uploadManager.stage(
                data: data,
                filename: filename,
                mimeType: mimeType,
                conversationID: conversation.id,
                target: target,
                isTemporary: conversation.isTemporaryConversation
            )
            transientNotice = nil
        } catch let rejection as FileUploadRejection {
            // Size and count limits surface as a toast: no persistent inline
            // strip, no dismiss button — the composer stays clean.
            transientNotice = rejection.message
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func cancelUpload(_ upload: PendingUpload) {
        Task { await uploadManager?.cancel(id: upload.id) }
    }

    func retryUpload(_ upload: PendingUpload) {
        Task {
            do { try await uploadManager?.retry(id: upload.id) }
            catch { errorMessage = error.userFacingMessage }
        }
    }

    func reconcileUpload(_ upload: PendingUpload) {
        Task {
            do {
                try await uploadManager?.reconcileDelivery(id: upload.id)
                errorMessage = nil
            } catch {
                if error.isUnauthorized {
                    await onUnauthorized()
                } else {
                    errorMessage = error.userFacingMessage
                }
            }
        }
    }

    /// Artifact source remains readable during generation recovery, but a
    /// persisted edit is admitted only from an idle, authoritative message
    /// graph. A paused/reconnecting generation still owns the conversation
    /// even when no token is currently streaming.
    func canEditArtifacts(in messageID: MessageID) -> Bool {
        guard artifactEditingEnvironmentIsIdle,
              let message = selectedPersistedAssistantMessage(id: messageID),
              !message.artifactCatalog.isEmpty else { return false }
        var identities = Set<ArtifactIdentity>()
        return message.artifactCatalog.allSatisfy {
            $0.identity.messageID == message.id && identities.insert($0.identity).inserted
        }
    }

    func editArtifact(_ artifact: ParsedArtifact, updatedContent: String) async throws {
        guard artifactEditOperation == nil,
              artifactEditingEnvironmentIsIdle else {
            throw ArtifactEditError.unavailable
        }
        let persistedArtifact = try exactPersistedArtifactForEditing(artifact)
        guard updatedContent != artifact.sourceContent else { return }

        // This final exact lookup is intentionally immediately before the
        // repository call. The sheet's selection is only a display snapshot;
        // it never authorizes a POST after branch/history reconciliation.
        let source = try exactPersistedArtifactForEditing(artifact)
        guard source == persistedArtifact else {
            throw ArtifactEditError.changedOnServer
        }
        let operation = ArtifactEditOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            artifact: source
        )
        artifactEditOperation = operation
        defer {
            if artifactEditOperation == operation { artifactEditOperation = nil }
        }

        do {
            let authoritative = try await repository.updateArtifact(ArtifactEditRequest(
                identity: source.identity,
                conversationID: conversation.id,
                originalContent: source.sourceContent,
                updatedContent: updatedContent
            ))
            try Task.checkCancellation()
            guard artifactEditOperation == operation,
                  profileID == operation.profileID,
                  accountID == operation.accountID,
                  conversation.id == operation.conversationID,
                  authoritative.id == source.identity.messageID,
                  authoritative.conversationID == operation.conversationID else {
                throw ArtifactEditError.verificationRequired
            }
            if let index = messages.firstIndex(where: { $0.id == authoritative.id }) {
                messages[index] = authoritative
            } else {
                await reload()
            }
            errorMessage = nil
        } catch {
            if error.isUnauthorized {
                historyState = .unavailable
                installMessages([])
                isShowingCache = false
                await onUnauthorized()
            }
            throw error
        }
    }

    private var artifactEditingEnvironmentIsIdle: Bool {
        state == .loaded
            && routingState == .authoritative
            && historyState == .authoritative
            && !conversation.id.isLocalDraft
            && !isStreaming
            && !isStopping
            && !isRespondingToInteraction
            && activeGeneration == nil
            && (generationSnapshot?.state.isTerminal ?? true)
            && generationSnapshot?.pendingInteraction == nil
            && activeOperationID == nil
            && respondingInteractionKey == nil
            && messageEditOperation == nil
            && messageFeedbackOperation == nil
            && artifactEditOperation == nil
            && promptResubmitOperation == nil
            && responseRegenerationOperation == nil
            && steeringOperation == nil
            && uncertainSteering == nil
            && conversationForkOperation == nil
            && followUpOperation == nil
            && uncertainConversationForkTargets.isEmpty
            && uncertainFeedbackTargets.isEmpty
            && hasValidMessageTree
    }

    /// Resolves only a single, currently selected assistant message from the
    /// persisted complete graph. A matching ID in a stale sheet or a different
    /// branch is not enough to authorize an artifact mutation.
    private func selectedPersistedAssistantMessage(id: MessageID) -> ChatMessage? {
        let persisted = messages.filter {
            $0.id == id && $0.conversationID == conversation.id
        }
        guard persisted.count == 1,
              let visible = visibleMessages.first(where: { $0.id == id }),
              visible == persisted[0],
              !Self.isUnsavedMessageID(persisted[0].id),
              persisted[0].isUnfinished != true,
              case .assistant = persisted[0].author else {
            return nil
        }
        return persisted[0]
    }

    /// Revalidates every persisted coordinate used by an artifact POST. A
    /// missing message is distinct from a source/coordinate mismatch so the
    /// editor can preserve its draft and explain the safe next action.
    private func exactPersistedArtifactForEditing(
        _ artifact: ParsedArtifact
    ) throws -> ParsedArtifact {
        guard let message = selectedPersistedAssistantMessage(
            id: artifact.identity.messageID
        ) else {
            if messages.contains(where: {
                $0.id == artifact.identity.messageID && $0.conversationID == conversation.id
            }) {
                throw ArtifactEditError.changedOnServer
            }
            throw ArtifactEditError.messageNotFound
        }
        guard canEditArtifacts(in: message.id) else {
            throw ArtifactEditError.unavailable
        }
        let matches = message.artifactCatalog.filter { $0.identity == artifact.identity }
        guard matches.count == 1, matches[0] == artifact else {
            throw ArtifactEditError.changedOnServer
        }
        return matches[0]
    }

    /// Returns edit actions only for exact text coordinates on the currently
    /// visible authoritative branch. Rendered indexes are never converted back
    /// into server content indexes here.
    func editableMessageTextSelections(for messageID: MessageID) -> [MessageTextEditSelection] {
        guard state == .loaded,
              historyState == .authoritative,
              !conversation.id.isLocalDraft,
              !isStreaming,
              !isStopping,
              !isRespondingToInteraction,
              activeGeneration == nil,
              activeOperationID == nil,
              messageEditOperation == nil,
              promptResubmitOperation == nil,
              responseRegenerationOperation == nil,
              hasValidMessageTree,
              let message = visibleMessages.first(where: { $0.id == messageID }),
              message.conversationID == conversation.id,
              !Self.isUnsavedMessageID(message.id),
              message.isUnfinished != true else { return [] }

        var locations = Set<MessageTextLocation>()
        guard message.editableTextCatalog.allSatisfy({ locations.insert($0.location).inserted }) else {
            return []
        }

        let hasDescendants = !messageTree.children(of: message.id).isEmpty
        return message.editableTextCatalog.compactMap { editable in
            if case let .contentPart(index, _) = editable.location, index < 0 { return nil }
            guard ArtifactParser.parse(messageID: message.id, text: editable.text)
                .nextDocumentOrderIndex == 0 else { return nil }
            guard CitationMarkerResolver.resolve(
                editable.text,
                sources: CitationSourceCatalog(attachments: message.citationAttachments)
            ).cleanedText == editable.text,
                  !Self.containsRawCitationMarker(in: editable.text) else { return nil }

            return MessageTextEditSelection(
                coordinate: MessageTextCoordinate(
                    conversationID: conversation.id,
                    messageID: message.id,
                    location: editable.location
                ),
                originalText: editable.text,
                title: Self.messageEditTitle(author: message.author, location: editable.location),
                hasDescendants: hasDescendants
            )
        }
    }

    /// A prompt resubmit is a new generation branch, not an edit of persisted
    /// history. Only an exact plain-text user turn on the selected branch is
    /// eligible.
    func promptResubmitSelection(for messageID: MessageID) -> PromptResubmitSelection? {
        makePromptResubmitSelection(for: messageID, requiringIdleAdmission: true)
    }

    @discardableResult
    func editPromptAndResubmit(
        _ selection: PromptResubmitSelection,
        text: String
    ) async throws -> PromptResubmitAdmissionResult {
        guard promptResubmitOperation == nil else {
            throw PromptResubmitPresentationError.operationInProgress
        }
        guard let current = makePromptResubmitSelection(
            for: selection.sourceMessageID,
            requiringIdleAdmission: true
        ) else {
            throw PromptResubmitPresentationError.unavailable
        }
        guard current == selection else {
            throw PromptResubmitPresentationError.stale
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptResubmitPresentationError.blankText
        }
        guard text.utf16.count <= MessageEditRequest.maximumTextUTF16Length else {
            throw PromptResubmitPresentationError.textTooLong
        }

        let operation = PromptResubmitOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            sourceMessageID: selection.sourceMessageID,
            sourceParentMessageID: selection.sourceParentMessageID,
            baselineText: selection.baselineText,
            submittedText: text,
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: UUID().uuidString)
        )
        promptResubmitOperation = operation
        defer {
            if promptResubmitOperation == operation { promptResubmitOperation = nil }
        }

        do {
            let outcome = try await repository.send(ChatRequest(
                profileID: profileID,
                accountID: accountID,
                conversation: conversation,
                parentMessageID: operation.sourceParentMessageID,
                text: text,
                attachments: [],
                clientRequestID: operation.clientRequestID,
                clientMessageID: operation.clientMessageID,
                action: .editPromptAndResubmit(sourceUserMessageID: operation.sourceMessageID)
            ))
            try Task.checkCancellation()
            try requireCurrentPromptResubmit(operation)

            switch outcome {
            case let .streaming(handle):
                guard owns(handle),
                      handle.clientRequestID == operation.clientRequestID else {
                    throw PromptResubmitPresentationError.invalidAdmission
                }
                acceptStreamingPromptResubmit(
                    handle: handle,
                    operation: operation,
                    text: text
                )
                return .streaming

            case let .settled(conversationID):
                guard conversationID == operation.conversationID else {
                    throw PromptResubmitPresentationError.invalidAdmission
                }
                try await reloadPromptResubmitHistory(focusing: operation)
                return .settled

            case let .aborted(conversationID):
                guard conversationID == operation.conversationID else {
                    throw PromptResubmitPresentationError.invalidAdmission
                }
                try await reloadPromptResubmitHistory(focusing: operation)
                return .aborted

            case let .failed(conversationID, failure):
                guard conversationID == operation.conversationID else {
                    throw PromptResubmitPresentationError.invalidAdmission
                }
                try await reloadPromptResubmitHistory(focusing: operation)
                errorMessage = failure.message
                return .failed

            case let .handoff(handle):
                guard owns(handle) else {
                    throw PromptResubmitPresentationError.invalidAdmission
                }
                try await attachPromptResubmitWinner(handle, operation: operation)
                throw PromptResubmitPresentationError.handoff
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PromptResubmitPresentationError {
            throw error
        } catch {
            if error.isUnauthorized {
                historyState = .unavailable
                installMessages([])
                isShowingCache = false
                await onUnauthorized()
            } else {
                // Admission failures can be ambiguous. The user must refresh
                // and explicitly reopen this action; this method never reposts.
                historyState = .notCurrent
            }
            throw error
        }
    }

    /// Returns a regeneration action only for the exact selected assistant
    /// response and its persisted user parent in the authoritative graph.
    func responseRegenerationSelection(
        for messageID: MessageID
    ) -> ResponseRegenerationSelection? {
        makeResponseRegenerationSelection(
            for: messageID,
            requiringVisibleBranch: true,
            requiringIdleAdmission: true
        )
    }

    /// Starts one response-regeneration admission. There is deliberately no
    /// optimistic response until the repository grants this request a live
    /// generation handle, and this method never repeats a failed POST.
    @discardableResult
    func regenerateResponse(
        _ selection: ResponseRegenerationSelection
    ) async throws -> ResponseRegenerationAdmissionResult {
        guard responseRegenerationOperation == nil else {
            throw ResponseRegenerationPresentationError.operationInProgress
        }
        guard let current = makeResponseRegenerationSelection(
            for: selection.targetAssistantMessageID,
            requiringVisibleBranch: true,
            requiringIdleAdmission: true
        ) else {
            let sourceIsUnchanged = messages.first(where: {
                $0.id == selection.sourceUserMessageID
            }) == selection.sourceUserMessage
            let responseIsUnchanged = messages.first(where: {
                $0.id == selection.targetAssistantMessageID
            }) == selection.targetAssistantMessage
            if !sourceIsUnchanged
                || !responseIsUnchanged
                || conversation.target != selection.conversationTarget {
                throw ResponseRegenerationPresentationError.stale
            }
            throw ResponseRegenerationPresentationError.unavailable
        }
        guard current == selection else {
            throw ResponseRegenerationPresentationError.stale
        }

        let tree = messageTree
        guard let sourceSelection = tree.siblings(containing: selection.sourceUserMessageID),
              let assistantSelection = tree.siblings(
                containing: selection.targetAssistantMessageID
              ),
              assistantSelection.parentMessageID == selection.sourceUserMessageID else {
            throw ResponseRegenerationPresentationError.stale
        }
        let operation = ResponseRegenerationOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            conversationTarget: selection.conversationTarget,
            sourceUserMessage: selection.sourceUserMessage,
            sourceParentMessageID: sourceSelection.parentMessageID,
            targetAssistantMessage: selection.targetAssistantMessage,
            preAdmissionAssistantSiblingIDs: Set(assistantSelection.siblings.map(\.id)),
            preservedTargetSubtree: responseSubtree(
                rootedAt: selection.targetAssistantMessageID,
                tree: tree
            ),
            clientRequestID: UUID(),
            clientMessageID: MessageID(rawValue: UUID().uuidString)
        )
        responseRegenerationOperation = operation
        defer {
            if responseRegenerationOperation == operation {
                responseRegenerationOperation = nil
            }
        }

        let expectedPredecessorCreatedAt: Int64? = if let snapshot = generationSnapshot,
                                                      snapshot.handle.conversationID == conversation.id,
                                                      snapshot.state.isTerminal {
            snapshot.handle.generationCreatedAt
        } else {
            nil
        }

        do {
            let outcome = try await repository.send(ChatRequest(
                profileID: profileID,
                accountID: accountID,
                conversation: conversation,
                parentMessageID: operation.sourceParentMessageID,
                text: operation.sourceUserMessage.rawPlainText,
                attachments: [],
                manualSkills: operation.sourceUserMessage.manualSkills ?? [],
                expectedPredecessorCreatedAt: expectedPredecessorCreatedAt,
                clientRequestID: operation.clientRequestID,
                clientMessageID: operation.clientMessageID,
                action: .regenerateResponse(
                    sourceUserMessageID: operation.sourceUserMessage.id,
                    targetAssistantMessageID: operation.targetAssistantMessage.id
                )
            ))
            try Task.checkCancellation()
            try requireCurrentResponseRegeneration(operation)

            switch outcome {
            case let .streaming(handle):
                guard owns(handle),
                      handle.clientRequestID == operation.clientRequestID else {
                    throw ResponseRegenerationPresentationError.invalidAdmission
                }
                acceptStreamingResponseRegeneration(handle: handle, operation: operation)
                return .streaming

            case let .settled(conversationID):
                guard conversationID == operation.conversationID else {
                    throw ResponseRegenerationPresentationError.invalidAdmission
                }
                try await reloadResponseRegenerationHistory(focusing: operation)
                return .settled

            case let .aborted(conversationID):
                guard conversationID == operation.conversationID else {
                    throw ResponseRegenerationPresentationError.invalidAdmission
                }
                try await reloadResponseRegenerationHistory(focusing: operation)
                return .aborted

            case let .failed(conversationID, failure):
                guard conversationID == operation.conversationID else {
                    throw ResponseRegenerationPresentationError.invalidAdmission
                }
                try await reloadResponseRegenerationHistory(focusing: operation)
                errorMessage = failure.message
                return .failed

            case let .handoff(handle):
                guard owns(handle),
                      handle.clientRequestID != operation.clientRequestID else {
                    throw ResponseRegenerationPresentationError.invalidAdmission
                }
                try await attachResponseRegenerationWinner(handle, operation: operation)
                throw ResponseRegenerationPresentationError.handoff
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ResponseRegenerationPresentationError {
            if error == .invalidAdmission || error == .ambiguousAuthoritativeHistory {
                historyState = .notCurrent
            }
            throw error
        } catch {
            if error.isUnauthorized {
                historyState = .unavailable
                installMessages([])
                isShowingCache = false
                await onUnauthorized()
            } else {
                // Admission may have reached the server. Never repeat it from
                // this operation; require an authoritative refresh and a new
                // explicit user action.
                historyState = .notCurrent
            }
            throw error
        }
    }

    func messageFeedbackSelection(
        for messageID: MessageID,
        suggestedRating: MessageFeedbackRating
    ) -> MessageFeedbackSelection? {
        guard state == .loaded,
              !conversation.id.isLocalDraft,
              !isStreaming,
              activeGeneration == nil,
              messageEditOperation == nil,
              messageFeedbackOperation == nil,
              promptResubmitOperation == nil,
              responseRegenerationOperation == nil,
              conversationForkOperation == nil,
              steeringOperation == nil,
              followUpOperation == nil,
              !isRespondingToInteraction,
              historyState == .authoritative,
              hasValidMessageTree,
              !uncertainFeedbackTargets.contains(messageID),
              let message = visibleMessages.first(where: { $0.id == messageID }),
              message.conversationID == conversation.id,
              !Self.isUnsavedMessageID(message.id),
              message.isUnfinished != true,
              case .assistant = message.author else { return nil }
        return MessageFeedbackSelection(
            profileID: profileID,
            accountID: accountID,
            coordinate: MessageFeedbackCoordinate(
                conversationID: conversation.id,
                messageID: message.id
            ),
            currentFeedback: message.feedback,
            suggestedRating: message.feedback?.rating ?? suggestedRating
        )
    }

    @discardableResult
    func updateMessageFeedback(
        _ selection: MessageFeedbackSelection,
        feedback: MessageFeedback?
    ) async throws -> MessageFeedbackResolution {
        guard messageFeedbackOperation == nil else {
            throw MessageFeedbackError.unavailable
        }
        guard let current = messageFeedbackSelection(
            for: selection.coordinate.messageID,
            suggestedRating: selection.suggestedRating
        ),
              current.profileID == selection.profileID,
              current.accountID == selection.accountID,
              current.coordinate == selection.coordinate,
              current.currentFeedback == selection.currentFeedback else {
            throw MessageFeedbackError.unavailable
        }

        let operation = MessageFeedbackOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            messageID: selection.coordinate.messageID,
            baselineFeedback: selection.currentFeedback,
            submittedFeedback: feedback
        )
        messageFeedbackOperation = operation
        defer {
            if messageFeedbackOperation == operation { messageFeedbackOperation = nil }
        }

        do {
            let result = try await repository.updateMessageFeedback(MessageFeedbackRequest(
                profileID: profileID,
                accountID: accountID,
                coordinate: selection.coordinate,
                feedback: feedback
            ))
            try Task.checkCancellation()
            guard messageFeedbackOperation == operation,
                  profileID == operation.profileID,
                  accountID == operation.accountID,
                  conversation.id == operation.conversationID,
                  result.coordinate == selection.coordinate,
                  result.feedback == feedback else {
                throw MessageFeedbackError.unavailable
            }

            if let history = result.authoritativeHistory {
                guard Self.isExactAuthoritativeFeedbackHistory(
                    history,
                    coordinate: selection.coordinate,
                    expected: feedback
                ) else {
                    throw MessageFeedbackError.ambiguous(
                        RecoverableMessageFeedbackAmbiguity(
                            coordinate: selection.coordinate,
                            submittedFeedback: feedback,
                            authoritativeFeedback: nil,
                            reason: .verificationUnavailable
                        )
                    )
                }
                installMessages(history)
            } else {
                let matches = messages.indices.filter {
                    messages[$0].id == operation.messageID
                        && messages[$0].conversationID == operation.conversationID
                }
                guard matches.count == 1,
                      messages[matches[0]].feedback == operation.baselineFeedback else {
                    throw MessageFeedbackError.unavailable
                }
                messages[matches[0]].feedback = result.feedback
            }

            uncertainFeedbackTargets.remove(operation.messageID)
            historyState = .authoritative
            state = .loaded
            isShowingCache = false
            errorMessage = nil
            return result.resolution
        } catch is CancellationError {
            throw CancellationError()
        } catch let MessageFeedbackError.ambiguous(ambiguity) {
            uncertainFeedbackTargets.insert(operation.messageID)
            historyState = .notCurrent
            errorMessage = ambiguity.reason == .authoritativeMismatch
                ? "Feedback changed on the server. Refresh before another update."
                : "Feedback delivery could not be verified. Refresh before another update."
            throw MessageFeedbackError.ambiguous(ambiguity)
        } catch {
            if error.isUnauthorized {
                historyState = .unavailable
                installMessages([])
                isShowingCache = false
                await onUnauthorized()
            } else if case let LibreChatProtocolError.httpStatus(status, _, _) = error,
                      status == 400 || status == 404 {
                historyState = .notCurrent
            }
            throw error
        }
    }

    /// Saves one persisted text slot and installs the repository's complete,
    /// authoritative graph. There is deliberately no optimistic message edit
    /// and no retry of the mutation.
    @discardableResult
    func saveMessageEdit(
        _ selection: MessageTextEditSelection,
        text: String
    ) async throws -> MessageEditResolution {
        guard messageEditOperation == nil else {
            throw MessageEditPresentationError.operationInProgress
        }
        guard let current = editableMessageTextSelections(for: selection.coordinate.messageID)
            .first(where: { $0.coordinate == selection.coordinate }) else {
            throw MessageEditPresentationError.unavailable
        }
        guard current.originalText == selection.originalText else {
            throw MessageEditPresentationError.stale
        }

        let operation = MessageEditOperationKey(
            id: UUID(),
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            coordinate: selection.coordinate,
            baselineText: selection.originalText
        )
        messageEditOperation = operation
        defer {
            if messageEditOperation == operation { messageEditOperation = nil }
        }

        do {
            let result = try await repository.saveMessageEdit(MessageEditRequest(
                profileID: profileID,
                accountID: accountID,
                coordinate: selection.coordinate,
                text: text
            ))
            try Task.checkCancellation()
            guard messageEditOperation == operation,
                  profileID == operation.profileID,
                  accountID == operation.accountID,
                  conversation.id == operation.conversationID,
                  result.coordinate == operation.coordinate,
                  Self.isExactAuthoritativeHistory(
                    result.authoritativeHistory,
                    coordinate: operation.coordinate,
                    expectedText: text
                  ) else {
                throw MessageEditPresentationError.invalidAuthoritativeHistory
            }
            installMessages(result.authoritativeHistory)
            historyState = .authoritative
            state = .loaded
            isShowingCache = false
            errorMessage = nil
            return result.resolution
        } catch is CancellationError {
            throw CancellationError()
        } catch let MessageEditError.ambiguous(ambiguity) {
            historyState = .notCurrent
            if ambiguity.reason == .authoritativeMismatch {
                await installVerifiedAmbiguousHistory(ambiguity, operation: operation)
            }
            throw MessageEditError.ambiguous(ambiguity)
        } catch {
            if error.isUnauthorized {
                historyState = .unavailable
                installMessages([])
                isShowingCache = false
                await onUnauthorized()
            } else if case let LibreChatProtocolError.httpStatus(status, _, _) = error,
                      status == 400 || status == 404 {
                historyState = .notCurrent
            }
            throw error
        }
    }

    func refreshGeneratedFile(_ file: GeneratedFile) async throws -> GeneratedFile {
        do {
            let updated = try await repository.refreshGeneratedFile(file)
            replaceGeneratedFile(updated)
            errorMessage = nil
            return updated
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            throw error
        }
    }

    func downloadGeneratedFile(_ file: GeneratedFile) async throws -> DownloadedGeneratedFile {
        do {
            let downloaded = try await repository.downloadGeneratedFile(file)
            errorMessage = nil
            return downloaded
        } catch {
            if error.isUnauthorized { await onUnauthorized() }
            throw error
        }
    }

    private func performSend(
        text: String,
        originalDraft: String,
        originalManualSkills: [String],
        parentMessageID: MessageID?,
        attachments: [UploadedFile],
        uploadIDs: [UUID],
        expectedPredecessorCreatedAt: Int64?,
        operationID: UUID
    ) async {
        do {
            let outcome = try await repository.send(ChatRequest(
                profileID: profileID,
                accountID: accountID,
                conversation: conversation,
                parentMessageID: parentMessageID,
                text: text,
                attachments: attachments,
                manualSkills: originalManualSkills,
                expectedPredecessorCreatedAt: expectedPredecessorCreatedAt
            ))
            switch outcome {
            case let .streaming(handle):
                guard handle.profileID == profileID, handle.accountID == accountID else {
                    rollbackOptimisticMessages(restoring: originalDraft)
                    selectedSkillNames = originalManualSkills
                    errorMessage = "LibreChat returned generation ownership for another server account."
                    finishOperation(operationID)
                    return
                }
                await uploadManager?.markAttached(ids: uploadIDs, conversationID: handle.conversationID)
                if handle.conversationID != conversation.id {
                    guard promoteLocalConversation(to: handle.conversationID) else {
                        rollbackOptimisticMessages(restoring: originalDraft)
                        selectedSkillNames = originalManualSkills
                        errorMessage = "LibreChat returned a response for a different conversation."
                        finishOperation(operationID)
                        return
                    }
                    let shouldContinue = await hydrateConversationRouting(
                        conversationID: handle.conversationID,
                        surfaceFailure: false
                    )
                    guard shouldContinue,
                          activeOperationID == operationID,
                          conversation.id == handle.conversationID else { return }
                }
                activeGeneration = handle
                if stopRequested {
                    requestStop(handle, operationID: operationID)
                }
                await consumeSnapshots(handle: handle, operationID: operationID)
            case let .handoff(handle):
                selectedSkillNames = originalManualSkills
                await adoptWinnerHandoff(
                    handle,
                    originalDraft: originalDraft,
                    operationID: operationID
                )
            case let .settled(conversationID):
                await finishTerminalStart(
                    conversationID: conversationID,
                    originalDraft: originalDraft,
                    originalManualSkills: originalManualSkills,
                    uploadIDs: uploadIDs,
                    operationID: operationID
                )
            case let .aborted(conversationID):
                await finishTerminalStart(
                    conversationID: conversationID,
                    originalDraft: originalDraft,
                    originalManualSkills: originalManualSkills,
                    uploadIDs: uploadIDs,
                    operationID: operationID
                )
            case let .failed(conversationID, failure):
                await finishTerminalStart(
                    conversationID: conversationID,
                    originalDraft: originalDraft,
                    originalManualSkills: originalManualSkills,
                    uploadIDs: uploadIDs,
                    operationID: operationID,
                    failure: failure
                )
            }
        } catch is CancellationError {
            if activeGeneration == nil {
                rollbackOptimisticMessages(restoring: originalDraft)
                selectedSkillNames = originalManualSkills
            }
        } catch {
            rollbackOptimisticMessages(restoring: originalDraft)
            selectedSkillNames = originalManualSkills
            errorMessage = error.userFacingMessage
            if error.isUnauthorized { await onUnauthorized() }
            finishOperation(operationID)
        }
    }

    /// The admission POST lost to an independently-proven active v2 epoch.
    /// Preserve the user's unsent draft and attach only after reconciling the
    /// exact winner. This path intentionally never replays the losing POST or
    /// treats the winner as evidence that the original message was accepted.
    private func adoptWinnerHandoff(
        _ handle: GenerationHandle,
        originalDraft: String,
        operationID: UUID
    ) async {
        guard activeOperationID == operationID,
              handle.profileID == profileID,
              handle.accountID == accountID else { return }

        removeLosingOptimisticMessages(restoring: originalDraft)
        if handle.conversationID != conversation.id {
            guard promoteLocalConversation(to: handle.conversationID) else {
                errorMessage = "LibreChat returned a replacement for a different conversation. Your draft was restored."
                finishOperation(operationID)
                return
            }
            let shouldContinue = await hydrateConversationRouting(
                conversationID: handle.conversationID,
                surfaceFailure: false
            )
            guard shouldContinue,
                  activeOperationID == operationID,
                  conversation.id == handle.conversationID else { return }
        }
        await repository.saveDraft(originalDraft, conversationID: conversation.id)

        activeGeneration = handle
        // Keep a nonterminal local checkpoint visible while the first status
        // reconciliation is in flight. If that request fails, the existing
        // Resume control remains available instead of hiding the proven
        // winner behind a private handle.
        generationSnapshot = GenerationSnapshot(handle: handle, state: .reconciling)
        isStreaming = true
        isStopping = false
        // A Stop tap belonged to the request that lost admission; it must not
        // abort another client's already-existing generation.
        stopRequested = false

        do {
            let reconciled = try await repository.reconcile(handle)
            guard activeOperationID == operationID,
                  activeGeneration == handle else { return }
            apply(reconciled)
            errorMessage = "A newer response is already in progress. Your draft was restored."

            guard !reconciled.state.isTerminal else {
                await reloadAfterGeneration()
                guard activeOperationID == operationID,
                      activeGeneration == handle else { return }
                finishOperation(operationID)
                return
            }

            try await repository.resume(handle)
            guard activeOperationID == operationID,
                  activeGeneration == handle else { return }
            await consumeSnapshots(handle: handle, operationID: operationID)
        } catch is CancellationError {
            // A profile switch or explicit teardown owns the subsequent UI.
        } catch {
            guard activeOperationID == operationID,
                  activeGeneration == handle else { return }
            isStreaming = false
            isStopping = false
            stopRequested = false
            activeOperationID = nil
            sendTask = nil
            // Keep the exact proven handle installed. `retryRecovery()` can
            // resume it later; clearing it here would turn a transient
            // handoff/reconcile failure into an unrecoverable dead end.
            errorMessage = "Connection to the newer response paused. Your draft is available; use Resume to reconnect."
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    /// Terminal admission receipts have no live generation coordinates. Drop
    /// the placeholder assistant immediately and replace the conversation with
    /// server history. The admission receipt has already claimed this
    /// submission, so a transient refresh failure must *not* restore/re-send
    /// the draft (which could duplicate it).
    private func finishTerminalStart(
        conversationID: ConversationID,
        originalDraft: String,
        originalManualSkills: [String],
        uploadIDs: [UUID],
        operationID: UUID,
        failure: GenerationFailure? = nil
    ) async {
        guard activeOperationID == operationID else { return }
        if conversationID != conversation.id {
            guard promoteLocalConversation(to: conversationID) else {
                rollbackOptimisticMessages(restoring: originalDraft)
                selectedSkillNames = originalManualSkills
                errorMessage = "LibreChat returned a terminal result for a different conversation."
                finishOperation(operationID)
                return
            }
        }
        if let optimisticAssistantID {
            messages.removeAll { $0.id == optimisticAssistantID }
            self.optimisticAssistantID = nil
        }
        await uploadManager?.markAttached(ids: uploadIDs, conversationID: conversationID)
        await reload()
        guard activeOperationID == operationID,
              self.conversation.id == conversationID else { return }
        if let failure {
            if let refreshContext = errorMessage,
               routingState != .authoritative || historyState != .authoritative {
                errorMessage = "\(failure.message) \(refreshContext)"
            } else {
                errorMessage = failure.message
            }
        }
        finishOperation(operationID)
    }

    private func consumeSnapshots(
        handle: GenerationHandle,
        operationID: UUID,
        preservingBranchSelection: [MessageTree.BranchParent: MessageID]? = nil,
        cancellationPolicy: SnapshotCancellationPolicy = .lifecycleOwnsRecovery
    ) async {
        let stream = await repository.snapshots(for: handle)
        do {
            for try await snapshot in stream {
                try Task.checkCancellation()
                guard activeGeneration == handle, activeOperationID == operationID else { return }
                apply(snapshot)
                if let preservingBranchSelection {
                    restoreBranchSelection(preservingBranchSelection)
                }
            }
            guard activeGeneration == handle, activeOperationID == operationID else { return }
            if generationSnapshot?.state.isTerminal == true {
                let followUpSignal = generationSnapshot.flatMap { self.followUpSignal(from: $0) }
                if preservingBranchSelection != nil {
                    preferredBranchFocusID = nil
                    preferredBranchFallbackID = nil
                }
                await reloadAfterGeneration()
                guard activeGeneration == handle, activeOperationID == operationID else { return }
                if let preservingBranchSelection {
                    restoreBranchSelection(preservingBranchSelection)
                }
                if let followUpSignal,
                   await continueWithFollowUpQueue(
                       after: followUpSignal,
                       operationID: operationID
                   ) {
                    return
                }
                finishOperation(operationID)
            } else {
                isStreaming = false
                isStopping = false
                errorMessage = "The live connection paused. Your generation is saved and can be resumed."
            }
        } catch is CancellationError {
            switch cancellationPolicy {
            case .lifecycleOwnsRecovery:
                // Stop or background detachment owns subsequent recovery.
                break
            case .acknowledgedInteraction:
                await handleAcknowledgedInteractionAttachFailure(
                    CancellationError(),
                    handle: handle,
                    operationID: operationID
                )
            }
        } catch {
            guard activeGeneration == handle, activeOperationID == operationID else { return }
            isStreaming = false
            errorMessage = "The stream disconnected. Your generation is saved and can be resumed."
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    private func requestStop(_ generation: GenerationHandle, operationID: UUID) {
        guard stopTask == nil else { return }
        stopTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await repository.stop(generation)
            } catch is CancellationError {
                return
            } catch {
                guard activeOperationID == operationID else { return }
                isStopping = false
                stopRequested = false
                errorMessage = error.userFacingMessage
                if error.isUnauthorized { await onUnauthorized() }
            }
            stopTask = nil
        }
    }

    private func apply(_ snapshot: GenerationSnapshot) {
        generationSnapshot = snapshot
        if let uncertainSteering,
           uncertainSteering.handle == snapshot.handle {
            let identityValues = Set(
                [uncertainSteering.clientSteerID, uncertainSteering.steerID].compactMap { $0 }
            )
            let isAuthoritativelyVisible = snapshot.pendingSteers.contains { steer in
                !identityValues.isDisjoint(with: Set([steer.id, steer.clientSteerID].compactMap { $0 }))
            } || snapshot.appliedSteers.contains { steer in
                !identityValues.isDisjoint(with: Set([steer.id, steer.clientSteerID].compactMap { $0 }))
            } || snapshot.recoverableSteers.contains { steer in
                !identityValues.isDisjoint(with: Set([steer.id, steer.clientSteerID].compactMap { $0 }))
            }
            if isAuthoritativelyVisible || snapshot.state.isTerminal {
                self.uncertainSteering = nil
            }
        }
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title != conversation.title {
            let currentID = conversation.id
            conversation.title = title
            onConversationIdentityChanged(currentID, conversation)
        }
        if let respondingInteractionKey,
           snapshot.pendingInteraction.map({
               InteractionSubmissionKey(handle: snapshot.handle, interaction: $0)
           }) != respondingInteractionKey {
            isRespondingToInteraction = false
            self.respondingInteractionKey = nil
        }
        guard let response = snapshot.response else { return }
        preferredBranchFocusID = response.id
        preferredBranchFallbackID = response.parentMessageID
        if let optimisticAssistantID,
           messages.contains(where: { $0.id == optimisticAssistantID }) {
            updateMessage(id: optimisticAssistantID) { message in
                message.content = response.content
            }
        } else if let responseIndex = messages.firstIndex(where: { $0.id == response.id }) {
            messages[responseIndex] = response
            optimisticAssistantID = response.id
        } else {
            messages.append(response)
            optimisticAssistantID = response.id
        }
        reconcileBranchSelection()
    }

    /// Rebuilds the message graph and its render-facing branch exactly when
    /// history or branch selection changes. The projection retains stable
    /// message and branch-entry values for unchanged rows, allowing SwiftUI's
    /// `ForEach` to diff by the server message ID rather than rebuilding tree
    /// structure from each body evaluation.
    /// Streaming-only: swap the final visible entry's message without
    /// touching the tree. Structural truth is refreshed by the full rebuild
    /// that runs when the generation terminalizes.
    private func applyStreamingTextUpdate(_ newLast: ChatMessage) {
        var entries = renderProjection.visibleEntries
        guard let lastIndex = entries.indices.last,
              entries[lastIndex].message.id == newLast.id else {
            rebuildChatRenderProjection()
            return
        }
        entries[lastIndex] = MessageTree.BranchEntry(
            parent: entries[lastIndex].parent,
            message: newLast,
            siblings: entries[lastIndex].siblings,
            selectedIndex: entries[lastIndex].selectedIndex
        )
        let visibleMessages = entries.map(\.message)
        renderProjection = ChatRenderProjection(
            revision: renderProjection.revision &+ 1,
            isStructurallyValid: renderProjection.isStructurallyValid,
            visibleEntries: entries,
            visibleMessages: visibleMessages,
            visibleMessageCount: visibleMessages.count,
            lastVisibleMessageID: newLast.id,
            lastVisiblePlainTextRevision: renderProjection.lastVisiblePlainTextRevision &+ 1,
            lastVisiblePlainText: newLast.plainText
        )
    }

    private func rebuildChatRenderProjection() {
        let rebuildStart = Date()
        let tree = MessageTree(messages: messages)
        cachedMessageTree = tree
        let treeMs = Date().timeIntervalSince(rebuildStart) * 1000
        let entries = tree.projection(selectedChildByParent: branchSelection)?.entries ?? []
        let projectionMs = Date().timeIntervalSince(rebuildStart) * 1000 - treeMs
        let visibleMessages = entries.map(\.message)
        let lastMessage = visibleMessages.last
        let lastMessageID = lastMessage?.id
        let lastPlainText = lastMessage?.plainText
        let prior = renderProjection
        let plainTextChanged = prior.lastVisibleMessageID != lastMessageID
            || prior.lastVisiblePlainText != lastPlainText

        renderProjection = ChatRenderProjection(
            revision: prior.revision &+ 1,
            isStructurallyValid: tree.isStructurallyValid,
            visibleEntries: entries,
            visibleMessages: visibleMessages,
            visibleMessageCount: visibleMessages.count,
            lastVisibleMessageID: lastMessageID,
            lastVisiblePlainTextRevision: plainTextChanged
                ? prior.lastVisiblePlainTextRevision &+ 1
                : prior.lastVisiblePlainTextRevision,
            lastVisiblePlainText: lastPlainText
        )
        if messages.count >= 500 {
            AppLog.perf.debug(
                "chat-rebuild treeMs=\(Int(treeMs)) projectionMs=\(Int(projectionMs)) finalizeMs=\(Int(Date().timeIntervalSince(rebuildStart) * 1000 - treeMs - projectionMs)) count=\(self.messages.count)"
            )
        }
    }

    private func installMessages(_ authoritativeMessages: [ChatMessage]) {
        let installStart = Date()
        messages = authoritativeMessages
        let assignMs = Date().timeIntervalSince(installStart) * 1000
        reconcileBranchSelection()
        if authoritativeMessages.count >= 500 {
            AppLog.perf.debug(
                "chat-install assignMs=\(Int(assignMs)) reconcileMs=\(Int(Date().timeIntervalSince(installStart) * 1000 - assignMs)) count=\(authoritativeMessages.count)"
            )
        }
    }

    /// Retain only exact direct-child selections in the current graph, then
    /// restore a generation-proven branch when its response (or, during a
    /// partial save, its parent) exists. No timestamp/text heuristic is used.
    private func reconcileBranchSelection() {
        let tree = messageTree
        guard tree.isStructurallyValid else {
            branchSelection = [:]
            return
        }

        branchSelection = tree.validSelections(from: branchSelection)
        let focusSelections = preferredBranchFocusID
            .flatMap(tree.selections(focusing:))
            ?? preferredBranchFallbackID.flatMap(tree.selections(focusing:))
        if let focusSelections {
            branchSelection.merge(focusSelections) { _, focused in focused }
        }
    }

    private func loadCache() async {
        guard !conversation.isTemporaryConversation else { return }
        do {
            let cached = try await repository.cachedMessages(conversationID: conversation.id)
            guard !cached.isEmpty else { return }
            installMessages(cached)
            isShowingCache = true
            historyState = .cached
            state = .loaded
        } catch {
            AppLog.persistence.error("Message cache read failed.")
        }
    }

    private func hydrateConversationRouting(
        conversationID: ConversationID,
        surfaceFailure: Bool
    ) async -> Bool {
        guard !conversationID.isLocalDraft,
              conversation.id == conversationID else { return false }
        routingState = .hydrating
        do {
            let authoritative = try await repository.conversation(id: conversationID)
            try Task.checkCancellation()
            guard conversation.id == conversationID,
                  authoritative.id == conversationID,
                  Self.hasUsableTarget(authoritative) else {
                throw ConversationHydrationFailure.invalidAuthoritativeConversation
            }
            installAuthoritativeConversation(authoritative, expectedID: conversationID)
            return true
        } catch is CancellationError {
            guard conversation.id == conversationID else { return false }
            routingState = .unverified
            return false
        } catch {
            guard conversation.id == conversationID else { return false }
            if error.isUnauthorized {
                await handleUnauthorizedHydrationFailure(error)
                return false
            }
            routingState = .unavailable
            if surfaceFailure {
                errorMessage = "Conversation details are unavailable. Sending and attachments remain disabled."
            }
            return true
        }
    }

    /// Replaces an unsent canvas with a fresh draft in place — model switch,
    /// temporary toggle, preset application — without pushing a new page. The
    /// existing conversation's identity is re-pointed the same way draft
    /// promotion does, so navigation and the sidebar stay on this page.
    func replaceUnsentDraft(with newConversation: LibreChatDomain.Conversation) {
        guard conversation.id != newConversation.id, messages.isEmpty else { return }
        let previousID = conversation.id
        conversation = newConversation
        // A canvas draft has no server identity to verify: its reviewed target
        // from the target catalog is authoritative from birth, exactly like a
        // freshly mounted draft. Only a server-backed replacement still owes
        // its routing and history hydration. Marking a draft unverified here
        // wedged the model — nothing re-hydrates a local-draft identity.
        if newConversation.id.isLocalDraft {
            routingState = .authoritative
            historyState = .authoritative
        } else {
            routingState = .unverified
            historyState = .notCurrent
        }
        onConversationIdentityChanged(previousID, newConversation)
    }

    @discardableResult
    private func promoteLocalConversation(to conversationID: ConversationID) -> Bool {
        guard conversationID != conversation.id else { return true }
        guard conversation.id.isLocalDraft, !conversationID.isLocalDraft else { return false }
        let previousID = conversation.id
        let localConversation = conversation
        // The local draft's routing was client-inferred. Every promotion is
        // immediately followed by an authoritative routing/history fetch, so
        // the inferred target must not leak into the promoted identity.
        conversation = LibreChatDomain.Conversation(
            id: conversationID,
            title: localConversation.title,
            model: localConversation.model,
            updatedAt: Date(),
            target: nil,
            projectID: localConversation.projectID,
            isTemporary: localConversation.isTemporary,
            expiresAt: localConversation.expiresAt
        )
        routingState = .unverified
        historyState = .notCurrent
        onConversationIdentityChanged(previousID, conversation)
        return true
    }

    private func installAuthoritativeConversation(
        _ authoritative: LibreChatDomain.Conversation,
        expectedID: ConversationID
    ) {
        guard conversation.id == expectedID,
              authoritative.id == expectedID,
              Self.hasUsableTarget(authoritative) else { return }
        if conversation.target != authoritative.target {
            skillCatalog = nil
            if !selectedSkillNames.isEmpty {
                skillCatalogError = SkillInvocationError.targetChanged.localizedDescription
            }
        }
        conversation = authoritative
        routingState = .authoritative
        // Search/list results may contain only a partial wire projection. A
        // same-ID callback installs the server-owned title, model, project and
        // target into the navigation/list owner without pretending promotion.
        onConversationIdentityChanged(expectedID, authoritative)
    }

    private func handleUnauthorizedHydrationFailure(_ error: Error) async {
        routingState = .unavailable
        historyState = .unavailable
        installMessages([])
        isShowingCache = false
        state = .failed(error.userFacingMessage)
        errorMessage = error.userFacingMessage
        await onUnauthorized()
    }

    private static func hasUsableTarget(_ conversation: LibreChatDomain.Conversation) -> Bool {
        guard let target = conversation.target else { return false }
        guard GenerationEndpointPolicy.route(for: target).supportsResumableV2 else { return false }
        if target.endpoint == "agents" {
            return target.agentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return true
    }

    private var targetUnavailableReason: String? {
        guard let target = conversation.target else {
            return conversation.id.isLocalDraft
                ? "Choose a chat target before sending or adding attachments."
                : "This conversation has no server-owned chat target. Start a new chat and choose one."
        }
        switch GenerationEndpointPolicy.route(for: target) {
        case .resumableV2:
            if target.endpoint == "agents",
               target.agentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                return "This agent conversation is missing its server-owned agent identity. Start a new chat and choose the agent again."
            }
            return nil
        case .unsupported(.assistantsProtocol):
            return "This conversation uses LibreChat Assistants, which is read-only in the native app for now. Start a new chat with a supported model or agent."
        case .unsupported:
            return "This conversation’s endpoint cannot be routed safely by the native app. Start a new chat and choose a supported target."
        }
    }

    private static func isLocalMessageID(_ messageID: MessageID) -> Bool {
        messageID.rawValue.hasPrefix("local-user-")
            || messageID.rawValue.hasPrefix("local-assistant-")
    }

    private static func isUnsavedMessageID(_ messageID: MessageID) -> Bool {
        let value = messageID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "new" || value.hasPrefix("local-")
    }

    private static func containsRawCitationMarker(in text: String) -> Bool {
        if text.lowercased().contains("\\ue20") { return true }
        return text.unicodeScalars.contains { (0xE200...0xE204).contains($0.value) }
    }

    private func makePromptResubmitSelection(
        for messageID: MessageID,
        requiringIdleAdmission: Bool
    ) -> PromptResubmitSelection? {
        guard state == .loaded,
              historyState == .authoritative,
              routingState == .authoritative,
              canGenerateRemotely(),
              Self.hasUsableTarget(conversation),
              !conversation.id.isLocalDraft,
              !isStreaming,
              !isStopping,
              !isRespondingToInteraction,
              activeGeneration == nil,
              activeOperationID == nil,
              messageEditOperation == nil,
              uploads.isEmpty,
              generationSnapshot?.pendingInteraction == nil,
              hasValidMessageTree,
              responseRegenerationOperation == nil,
              (!requiringIdleAdmission || promptResubmitOperation == nil) else { return nil }
        return currentPromptResubmitSource(for: messageID, requiringVisibleBranch: true)
    }

    private func currentPromptResubmitSource(
        for messageID: MessageID,
        requiringVisibleBranch: Bool
    ) -> PromptResubmitSelection? {
        let candidateMessages = requiringVisibleBranch ? visibleMessages : messages
        guard hasValidMessageTree,
              let message = candidateMessages.first(where: { $0.id == messageID }),
              message.conversationID == conversation.id,
              !Self.isUnsavedMessageID(message.id),
              message.isUnfinished != true,
              case .user = message.author,
              message.content.count == 1,
              case let .text(sourceText) = message.content[0],
              message.editableTextCatalog.count == 1,
              case .primaryText = message.editableTextCatalog[0].location,
              message.editableTextCatalog[0].text == sourceText,
              message.manualSkills?.isEmpty ?? true,
              message.quotes?.isEmpty ?? true,
              message.citationAttachments.isEmpty,
              message.artifactCatalog.isEmpty,
              let siblingSelection = messageTree.siblings(containing: message.id),
              siblingSelection.selectedMessage.id == message.id else { return nil }

        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.rawPlainText == text,
              !Self.containsRawCitationMarker(in: text),
              CitationMarkerResolver.resolve(
                text,
                sources: CitationSourceCatalog(attachments: [])
              ).cleanedText == text,
              ArtifactParser.parse(messageID: message.id, text: text)
                .nextDocumentOrderIndex == 0 else { return nil }

        if let endpoint = message.endpoint,
           endpoint != conversation.target?.endpoint { return nil }
        if let model = message.model,
           model != conversation.target?.model { return nil }

        return PromptResubmitSelection(
            conversationID: conversation.id,
            sourceMessageID: message.id,
            sourceParentMessageID: siblingSelection.parentMessageID,
            baselineText: text
        )
    }

    private func requireCurrentPromptResubmit(
        _ operation: PromptResubmitOperationKey
    ) throws {
        guard promptResubmitOperation == operation,
              profileID == operation.profileID,
              accountID == operation.accountID,
              conversation.id == operation.conversationID else {
            throw PromptResubmitPresentationError.stale
        }
        guard let current = currentPromptResubmitSource(
            for: operation.sourceMessageID,
            requiringVisibleBranch: false
        ),
              current.sourceParentMessageID == operation.sourceParentMessageID,
              current.baselineText == operation.baselineText else {
            throw PromptResubmitPresentationError.stale
        }
    }

    private func acceptStreamingPromptResubmit(
        handle: GenerationHandle,
        operation: PromptResubmitOperationKey,
        text: String
    ) {
        let localAssistantID = MessageID(rawValue: "local-assistant-\(UUID().uuidString)")
        let generationOperationID = UUID()
        messages.append(ChatMessage(
            id: operation.clientMessageID,
            conversationID: operation.conversationID,
            parentMessageID: operation.sourceParentMessageID,
            content: [.text(text)],
            author: .user,
            model: conversation.model,
            endpoint: conversation.target?.endpoint,
            createdAt: now()
        ))
        messages.append(ChatMessage(
            id: localAssistantID,
            conversationID: operation.conversationID,
            parentMessageID: operation.clientMessageID,
            content: [.text("")],
            author: .assistant(name: conversation.model ?? "Assistant"),
            model: conversation.model,
            endpoint: conversation.target?.endpoint,
            createdAt: now()
        ))
        branchSelection[
            operation.sourceParentMessageID.map(MessageTree.BranchParent.message) ?? .root
        ] = operation.clientMessageID
        branchSelection[.message(operation.clientMessageID)] = localAssistantID
        preferredBranchFocusID = operation.clientMessageID
        preferredBranchFallbackID = operation.sourceParentMessageID
        optimisticUserID = operation.clientMessageID
        optimisticAssistantID = localAssistantID
        activeGeneration = handle
        activeOperationID = generationOperationID
        generationSnapshot = GenerationSnapshot(handle: handle, state: .starting)
        isStreaming = true
        isStopping = false
        stopRequested = false
        historyState = .notCurrent
        errorMessage = nil
        reconcileBranchSelection()

        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeSnapshots(handle: handle, operationID: generationOperationID)
        }
    }

    private func reloadPromptResubmitHistory(
        focusing operation: PromptResubmitOperationKey
    ) async throws {
        let history = try await repository.messages(conversationID: operation.conversationID)
        try Task.checkCancellation()
        try requireCurrentPromptResubmit(operation)
        let tree = MessageTree(messages: history)
        guard history.allSatisfy({ $0.conversationID == operation.conversationID }),
              tree.isStructurallyValid,
              tree.siblings(containing: operation.clientMessageID)?.parentMessageID
                == operation.sourceParentMessageID,
              history.contains(where: { message in
                  guard message.id == operation.clientMessageID,
                        message.rawPlainText == operation.submittedText,
                        case .user = message.author else { return false }
                  return true
              }) else {
            throw PromptResubmitPresentationError.invalidAdmission
        }

        preferredBranchFocusID = operation.clientMessageID
        preferredBranchFallbackID = operation.sourceParentMessageID
        installMessages(history)
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        historyState = .authoritative
        state = .loaded
        isShowingCache = false
    }

    private func attachPromptResubmitWinner(
        _ handle: GenerationHandle,
        operation: PromptResubmitOperationKey
    ) async throws {
        let generationOperationID = UUID()
        activeGeneration = handle
        activeOperationID = generationOperationID
        generationSnapshot = GenerationSnapshot(handle: handle, state: .reconciling)
        isStreaming = true
        isStopping = false
        stopRequested = false
        historyState = .notCurrent

        do {
            let snapshot = try await repository.reconcile(handle)
            try Task.checkCancellation()
            try requireCurrentPromptResubmit(operation)
            guard activeGeneration == handle,
                  activeOperationID == generationOperationID else {
                throw PromptResubmitPresentationError.stale
            }
            apply(snapshot)
            if snapshot.state.isTerminal {
                try await reloadWinnerHistory(operation: operation)
                guard activeGeneration == handle,
                      activeOperationID == generationOperationID else { return }
                finishOperation(generationOperationID)
                return
            }

            try await repository.resume(handle)
            try Task.checkCancellation()
            try requireCurrentPromptResubmit(operation)
            guard activeGeneration == handle,
                  activeOperationID == generationOperationID else {
                throw PromptResubmitPresentationError.stale
            }
            sendTask = Task { [weak self] in
                guard let self else { return }
                await self.consumeSnapshots(handle: handle, operationID: generationOperationID)
            }
        } catch {
            if activeGeneration == handle, activeOperationID == generationOperationID {
                isStreaming = false
                isStopping = false
                errorMessage = "Connection to the newer response paused. Refresh before editing and sending again."
            }
            throw error
        }
    }

    private func reloadWinnerHistory(operation: PromptResubmitOperationKey) async throws {
        let history = try await repository.messages(conversationID: operation.conversationID)
        try Task.checkCancellation()
        guard promptResubmitOperation == operation,
              profileID == operation.profileID,
              accountID == operation.accountID,
              conversation.id == operation.conversationID,
              history.allSatisfy({ $0.conversationID == operation.conversationID }),
              MessageTree(messages: history).isStructurallyValid else {
            throw PromptResubmitPresentationError.invalidAdmission
        }
        installMessages(history)
        historyState = .authoritative
        state = .loaded
        isShowingCache = false
    }

    private func makeResponseRegenerationSelection(
        for messageID: MessageID,
        requiringVisibleBranch: Bool,
        requiringIdleAdmission: Bool
    ) -> ResponseRegenerationSelection? {
        guard state == .loaded,
              historyState == .authoritative,
              routingState == .authoritative,
              canGenerateRemotely(),
              Self.hasUsableTarget(conversation),
              !conversation.id.isLocalDraft,
              !isStreaming,
              !isStopping,
              !isRespondingToInteraction,
              activeGeneration == nil,
              activeOperationID == nil,
              messageEditOperation == nil,
              promptResubmitOperation == nil,
              uploads.isEmpty,
              generationSnapshot?.pendingInteraction == nil,
              hasValidMessageTree,
              (!requiringIdleAdmission || responseRegenerationOperation == nil) else {
            return nil
        }
        return currentResponseRegenerationSelection(
            for: messageID,
            requiringVisibleBranch: requiringVisibleBranch
        )
    }

    private func currentResponseRegenerationSelection(
        for messageID: MessageID,
        requiringVisibleBranch: Bool
    ) -> ResponseRegenerationSelection? {
        guard let target = conversation.target else { return nil }
        let candidateMessages = requiringVisibleBranch ? visibleMessages : messages
        guard hasValidMessageTree,
              let assistant = candidateMessages.first(where: { $0.id == messageID }),
              assistant.conversationID == conversation.id,
              !Self.isUnsavedMessageID(assistant.id),
              assistant.isUnfinished != true,
              assistant.finishReason?.lowercased() != "error",
              case .assistant = assistant.author,
              !assistant.content.isEmpty,
              assistant.content.allSatisfy({ content in
                  if case .text = content { return true }
                  return false
              }),
              assistant.manualSkills?.isEmpty ?? true,
              assistant.quotes?.isEmpty ?? true,
              assistant.citationAttachments.isEmpty,
              assistant.artifactCatalog.isEmpty,
              let assistantSelection = messageTree.siblings(containing: assistant.id),
              assistantSelection.selectedMessage.id == assistant.id,
              let sourceUserMessageID = assistantSelection.parentMessageID,
              let source = messages.first(where: { $0.id == sourceUserMessageID }),
              source.conversationID == conversation.id,
              !Self.isUnsavedMessageID(source.id),
              source.isUnfinished != true,
              case .user = source.author,
              source.content.count == 1,
              case let .text(sourceText) = source.content[0],
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.rawPlainText == sourceText,
              source.editableTextCatalog.count == 1,
              source.editableTextCatalog[0].location == .primaryText,
              source.editableTextCatalog[0].text == sourceText,
              source.manualSkills?.isEmpty ?? true,
              source.quotes?.isEmpty ?? true,
              source.citationAttachments.isEmpty,
              source.artifactCatalog.isEmpty,
              messageTree.siblings(containing: source.id) != nil,
              !Self.containsRawCitationMarker(in: sourceText),
              CitationMarkerResolver.resolve(
                sourceText,
                sources: CitationSourceCatalog(attachments: [])
              ).cleanedText == sourceText,
              ArtifactParser.parse(messageID: source.id, text: sourceText)
                .nextDocumentOrderIndex == 0,
              Self.hasCompatibleRegenerationRouting(source, target: target),
              Self.hasCompatibleRegenerationRouting(assistant, target: target) else {
            return nil
        }

        let presentation = ComposerExecutionSummaryPresentation(
            targetSpec: executionTargetSpec,
            model: executionTargetModel,
            selectedAgentOrAssistant: executionSelectedAgentOrAssistant,
            endpoint: executionTargetEndpoint,
            attachmentCount: 0,
            attachmentState: nil,
            serverHost: nil
        )
        return ResponseRegenerationSelection(
            conversationID: conversation.id,
            sourceUserMessageID: source.id,
            targetAssistantMessageID: assistant.id,
            sourceUserMessage: source,
            targetAssistantMessage: assistant,
            conversationTarget: target,
            targetLabel: presentation.target
        )
    }

    private static func hasCompatibleRegenerationRouting(
        _ message: ChatMessage,
        target: ConversationTarget
    ) -> Bool {
        if let endpoint = message.endpoint,
           !endpoint.isEmpty,
           endpoint != target.endpoint {
            return false
        }
        if let model = message.model,
           !model.isEmpty,
           let targetModel = target.model,
           model != targetModel {
            return false
        }
        return true
    }

    private func requireCurrentResponseRegeneration(
        _ operation: ResponseRegenerationOperationKey
    ) throws {
        guard responseRegenerationOperation == operation,
              profileID == operation.profileID,
              accountID == operation.accountID,
              conversation.id == operation.conversationID,
              conversation.target == operation.conversationTarget,
              let current = currentResponseRegenerationSelection(
                for: operation.targetAssistantMessage.id,
                requiringVisibleBranch: false
              ),
              current.sourceUserMessage == operation.sourceUserMessage,
              current.targetAssistantMessage == operation.targetAssistantMessage,
              messageTree.siblings(containing: operation.sourceUserMessage.id)?.parentMessageID
                == operation.sourceParentMessageID,
              responseSubtree(
                rootedAt: operation.targetAssistantMessage.id,
                tree: messageTree
              ) == operation.preservedTargetSubtree else {
            throw ResponseRegenerationPresentationError.stale
        }
    }

    private func responseSubtree(
        rootedAt messageID: MessageID,
        tree: MessageTree
    ) -> [ChatMessage] {
        guard tree.isStructurallyValid,
              let root = messages.first(where: { $0.id == messageID }) else { return [] }
        var result = [root]
        var nextIndex = 0
        while nextIndex < result.count {
            let parent = result[nextIndex]
            result.append(contentsOf: tree.children(of: parent.id))
            nextIndex += 1
        }
        return result
    }

    private func acceptStreamingResponseRegeneration(
        handle: GenerationHandle,
        operation: ResponseRegenerationOperationKey
    ) {
        let localAssistantID = MessageID(rawValue: "local-assistant-\(UUID().uuidString)")
        let generationOperationID = UUID()
        messages.append(ChatMessage(
            id: localAssistantID,
            conversationID: operation.conversationID,
            parentMessageID: operation.sourceUserMessage.id,
            content: [.text("")],
            author: .assistant(name: conversation.model ?? "Assistant"),
            model: conversation.model,
            endpoint: conversation.target?.endpoint,
            createdAt: now()
        ))
        branchSelection[.message(operation.sourceUserMessage.id)] = localAssistantID
        preferredBranchFocusID = localAssistantID
        preferredBranchFallbackID = operation.sourceUserMessage.id
        optimisticUserID = nil
        optimisticAssistantID = localAssistantID
        activeGeneration = handle
        activeOperationID = generationOperationID
        generationSnapshot = GenerationSnapshot(handle: handle, state: .starting)
        isStreaming = true
        isStopping = false
        stopRequested = false
        historyState = .notCurrent
        errorMessage = nil
        reconcileBranchSelection()

        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.consumeSnapshots(handle: handle, operationID: generationOperationID)
        }
    }

    private func reloadResponseRegenerationHistory(
        focusing operation: ResponseRegenerationOperationKey
    ) async throws {
        let history = try await repository.messages(conversationID: operation.conversationID)
        try Task.checkCancellation()
        try requireCurrentResponseRegeneration(operation)
        let tree = MessageTree(messages: history)
        guard history.allSatisfy({ $0.conversationID == operation.conversationID }),
              tree.isStructurallyValid,
              history.first(where: { $0.id == operation.sourceUserMessage.id })
                == operation.sourceUserMessage,
              history.first(where: { $0.id == operation.targetAssistantMessage.id })
                == operation.targetAssistantMessage,
              tree.siblings(containing: operation.sourceUserMessage.id)?.parentMessageID
                == operation.sourceParentMessageID,
              let assistantSiblings = tree.siblings(
                containing: operation.targetAssistantMessage.id
              ),
              assistantSiblings.parentMessageID == operation.sourceUserMessage.id,
              operation.preAdmissionAssistantSiblingIDs.isSubset(
                of: Set(assistantSiblings.siblings.map(\.id))
              ),
              operation.preservedTargetSubtree.allSatisfy({ baseline in
                  history.first(where: { $0.id == baseline.id }) == baseline
              }) else {
            throw ResponseRegenerationPresentationError.ambiguousAuthoritativeHistory
        }

        let candidates = assistantSiblings.siblings.filter { message in
            guard !operation.preAdmissionAssistantSiblingIDs.contains(message.id),
                  !Self.isUnsavedMessageID(message.id),
                  message.isUnfinished != true,
                  case .assistant = message.author else { return false }
            return true
        }
        guard candidates.count == 1, let accepted = candidates.first else {
            throw ResponseRegenerationPresentationError.ambiguousAuthoritativeHistory
        }

        preferredBranchFocusID = accepted.id
        preferredBranchFallbackID = operation.sourceUserMessage.id
        installMessages(history)
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        historyState = .authoritative
        state = .loaded
        isShowingCache = false
    }

    private func attachResponseRegenerationWinner(
        _ handle: GenerationHandle,
        operation: ResponseRegenerationOperationKey
    ) async throws {
        let generationOperationID = UUID()
        let preservedBranchSelection = branchSelection
        activeGeneration = handle
        activeOperationID = generationOperationID
        generationSnapshot = GenerationSnapshot(handle: handle, state: .reconciling)
        isStreaming = true
        isStopping = false
        stopRequested = false
        historyState = .notCurrent

        do {
            let snapshot = try await repository.reconcile(handle)
            try Task.checkCancellation()
            try requireCurrentResponseRegeneration(operation)
            guard activeGeneration == handle,
                  activeOperationID == generationOperationID else {
                throw ResponseRegenerationPresentationError.stale
            }
            apply(snapshot)
            restoreBranchSelection(preservedBranchSelection)
            if snapshot.state.isTerminal {
                try await reloadResponseRegenerationWinnerHistory(
                    operation: operation,
                    preserving: preservedBranchSelection
                )
                guard activeGeneration == handle,
                      activeOperationID == generationOperationID else { return }
                finishOperation(generationOperationID)
                return
            }

            try await repository.resume(handle)
            try Task.checkCancellation()
            guard responseRegenerationOperation == operation,
                  activeGeneration == handle,
                  activeOperationID == generationOperationID else {
                throw ResponseRegenerationPresentationError.stale
            }
            sendTask = Task { [weak self] in
                guard let self else { return }
                await self.consumeSnapshots(
                    handle: handle,
                    operationID: generationOperationID,
                    preservingBranchSelection: preservedBranchSelection
                )
            }
        } catch {
            if activeGeneration == handle, activeOperationID == generationOperationID {
                isStreaming = false
                isStopping = false
                restoreBranchSelection(preservedBranchSelection)
                errorMessage = "Connection to the newer response paused. Refresh before regenerating again."
            }
            throw error
        }
    }

    private func reloadResponseRegenerationWinnerHistory(
        operation: ResponseRegenerationOperationKey,
        preserving branchSelection: [MessageTree.BranchParent: MessageID]
    ) async throws {
        let history = try await repository.messages(conversationID: operation.conversationID)
        try Task.checkCancellation()
        let tree = MessageTree(messages: history)
        guard responseRegenerationOperation == operation,
              profileID == operation.profileID,
              accountID == operation.accountID,
              conversation.id == operation.conversationID,
              history.allSatisfy({ $0.conversationID == operation.conversationID }),
              tree.isStructurallyValid,
              history.first(where: { $0.id == operation.sourceUserMessage.id })
                == operation.sourceUserMessage,
              history.first(where: { $0.id == operation.targetAssistantMessage.id })
                == operation.targetAssistantMessage else {
            throw ResponseRegenerationPresentationError.invalidAdmission
        }
        installMessages(history)
        restoreBranchSelection(branchSelection)
        historyState = .authoritative
        state = .loaded
        isShowingCache = false
    }

    private func restoreBranchSelection(
        _ preserved: [MessageTree.BranchParent: MessageID]
    ) {
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        branchSelection = messageTree.validSelections(from: preserved)
    }

    private static func messageEditTitle(
        author: MessageAuthor,
        location: MessageTextLocation
    ) -> String {
        switch location {
        case .primaryText:
            if case .user = author { return "Edit saved message text" }
            return "Edit saved response text"
        case let .contentPart(index, kind):
            return switch kind {
            case .text: "Edit text part \(index + 1)"
            case .reasoning: "Edit reasoning part \(index + 1)"
            }
        }
    }

    private static func isExactAuthoritativeHistory(
        _ history: [ChatMessage],
        coordinate: MessageTextCoordinate,
        expectedText: String
    ) -> Bool {
        guard history.allSatisfy({ $0.conversationID == coordinate.conversationID }),
              MessageTree(messages: history).isStructurallyValid else {
            return false
        }
        let messages = history.filter { $0.id == coordinate.messageID }
        guard messages.count == 1 else { return false }
        let texts = messages[0].editableTextCatalog.filter { $0.location == coordinate.location }
        return texts.count == 1 && texts[0].text == expectedText
    }

    private static func isExactAuthoritativeFeedbackHistory(
        _ history: [ChatMessage],
        coordinate: MessageFeedbackCoordinate,
        expected: MessageFeedback?
    ) -> Bool {
        guard history.allSatisfy({ $0.conversationID == coordinate.conversationID }),
              MessageTree(messages: history).isStructurallyValid else {
            return false
        }
        let matches = history.filter { $0.id == coordinate.messageID }
        return matches.count == 1 && matches[0].feedback == expected
    }

    private func installVerifiedAmbiguousHistory(
        _ ambiguity: RecoverableMessageEditAmbiguity,
        operation: MessageEditOperationKey
    ) async {
        guard ambiguity.coordinate == operation.coordinate else { return }
        do {
            let cached = try await repository.cachedMessages(conversationID: operation.conversationID)
            try Task.checkCancellation()
            guard messageEditOperation == operation,
                  profileID == operation.profileID,
                  accountID == operation.accountID,
                  conversation.id == operation.conversationID,
                  cached.allSatisfy({ $0.conversationID == operation.conversationID }),
                  MessageTree(messages: cached).isStructurallyValid else { return }

            let matchingMessages = cached.filter { $0.id == operation.coordinate.messageID }
            guard matchingMessages.count <= 1 else { return }
            let matchingTexts = matchingMessages.first?.editableTextCatalog.filter {
                $0.location == operation.coordinate.location
            } ?? []
            guard matchingTexts.count <= 1 else { return }
            if let authoritativeText = ambiguity.authoritativeText {
                guard matchingTexts.first?.text == authoritativeText else { return }
            } else {
                guard matchingTexts.isEmpty else { return }
            }

            installMessages(cached)
            historyState = .authoritative
            state = .loaded
            isShowingCache = false
        } catch is CancellationError {
            return
        } catch {
            AppLog.persistence.error("Authoritative message-edit cache validation failed.")
        }
    }

    private func observeUploads() {
        guard uploadObservationTask == nil, let uploadManager else { return }
        uploadObservationTask = Task { [weak self] in
            let stream = await uploadManager.updates()
            for await uploads in stream {
                guard let self else { return }
                let queueOwned = self.queueOwnedUploadIDs
                self.uploads = uploads.filter {
                    $0.conversationID == self.conversation.id
                        && $0.state != .attached
                        && $0.state != .cancelled
                        && !queueOwned.contains($0.id)
                }
            }
        }
    }

    private var queueOwnedUploadIDs: Set<UUID> {
        Set((followUpQueue?.items ?? []).flatMap { item -> [UUID] in
            switch item.state {
            case .delivered, .deliveredWithoutEpoch:
                return []
            default:
                return item.attachments.map(\.uploadID)
            }
        })
    }

    private func removeQueueOwnedUploadsFromComposer() {
        let queueOwned = queueOwnedUploadIDs
        uploads.removeAll { queueOwned.contains($0.id) }
    }

    private func reconcileQueuedUploadOwnership(_ queue: FollowUpQueueSnapshot) async {
        guard let uploadManager else { return }
        let activeIDs = queue.items.flatMap { item -> [UUID] in
            switch item.state {
            case .delivered, .deliveredWithoutEpoch:
                return []
            default:
                return item.attachments.map(\.uploadID)
            }
        }
        if !activeIDs.isEmpty {
            do {
                try await uploadManager.markQueued(
                    ids: activeIDs,
                    conversationID: conversation.id
                )
            } catch {
                AppLog.uploads.error(
                    "Durable queued attachment ownership could not be fully restored."
                )
            }
        }
        let activeIDSet = Set(activeIDs)
        let deliveredIDs = queue.items.flatMap { item -> [UUID] in
            switch item.state {
            case .delivered, .deliveredWithoutEpoch:
                return item.attachments.map(\.uploadID).filter { !activeIDSet.contains($0) }
            default:
                return []
            }
        }
        if !deliveredIDs.isEmpty {
            await uploadManager.markAttached(
                ids: deliveredIDs,
                conversationID: conversation.id
            )
        }
        removeQueueOwnedUploadsFromComposer()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func refreshFollowUpState() async {
        guard !conversation.id.isLocalDraft,
              !conversation.isTemporaryConversation else {
            followUpQueue = nil
            recoverableSteerBatches = []
            return
        }
        do {
            let queue = try await repository.followUpQueue(conversationID: conversation.id)
            let recoveries = try await repository.recoverableSteerBatches(
                conversationID: conversation.id
            )
            guard queue.namespace.profileID == profileID,
                  queue.namespace.accountID == accountID,
                  queue.namespace.conversationID == conversation.id else { return }
            followUpQueue = queue
            await reconcileQueuedUploadOwnership(queue)
            recoverableSteerBatches = recoveries
                .filter { owns($0.handle) && !$0.steers.isEmpty }
                .sorted { $0.checkpointedAt > $1.checkpointedAt }
        } catch {
            // A corrupt journal or unavailable cache is never represented as
            // an empty queue. Keep the last truthful presentation snapshot.
            AppLog.persistence.error("Chat follow-up ownership refresh failed closed.")
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    private static func nextFollowUpOrder(
        after snapshot: FollowUpQueueSnapshot
    ) throws -> FollowUpQueueOrder {
        guard let maximum = snapshot.items.map(\.order.rawValue).max() else {
            return FollowUpQueueOrder(rawValue: 1)
        }
        guard maximum < UInt64.max else { throw FollowUpQueueError.invalidReorder }
        return FollowUpQueueOrder(rawValue: maximum + 1)
    }

    private func isCurrentFollowUpOperation(_ operation: FollowUpOperationKey) -> Bool {
        followUpOperation == operation
            && profileID == operation.profileID
            && accountID == operation.accountID
            && conversation.id == operation.conversationID
    }

    private func followUpSignal(
        from snapshot: GenerationSnapshot
    ) -> FollowUpGenerationSignal? {
        guard owns(snapshot.handle), snapshot.state.isTerminal else { return nil }
        return switch snapshot.state {
        case .completed:
            if let responseID = snapshot.response?.id,
               !Self.isUnsavedMessageID(responseID) {
                .completed(handle: snapshot.handle, responseMessageID: responseID)
            } else {
                nil
            }
        case .aborted:
            .aborted(handle: snapshot.handle)
        case .failed:
            .failed(handle: snapshot.handle)
        case .superseded:
            .superseded(handle: snapshot.handle)
        default:
            nil
        }
    }

    private func recoverableCompletionSignal(
        for handle: GenerationHandle
    ) -> FollowUpGenerationSignal? {
        guard let snapshot = generationSnapshot,
              snapshot.handle == handle,
              case .completed = snapshot.state,
              let responseID = snapshot.response?.id,
              let sourceUserID = snapshot.response?.parentMessageID,
              !Self.isUnsavedMessageID(responseID),
              !Self.isUnsavedMessageID(sourceUserID) else { return nil }
        return .completed(handle: handle, responseMessageID: responseID)
    }

    /// Drives a persisted queue transition and, when one item is admitted,
    /// hands its exact handle to a fresh snapshot consumer without blocking
    /// the queue mutation UI for the duration of the generation.
    @discardableResult
    private func continueWithFollowUpQueue(
        after signal: FollowUpGenerationSignal,
        operationID: UUID?
    ) async -> Bool {
        do {
            let result = try await repository.drainFollowUp(after: signal)
            await refreshFollowUpState()
            switch result {
            case let .admitted(itemID, handle):
                guard owns(handle) else { return false }
                if let operationID, activeOperationID != operationID { return false }
                let nextOperationID = operationID ?? UUID()
                activeOperationID = nextOperationID
                activeGeneration = handle
                generationSnapshot = GenerationSnapshot(handle: handle, state: .starting)
                isStreaming = true
                isStopping = false
                stopRequested = false
                errorMessage = nil
                installAdmittedFollowUpUser(itemID: itemID, handle: handle)
                sendTask = Task { [weak self] in
                    guard let self else { return }
                    await consumeSnapshots(handle: handle, operationID: nextOperationID)
                }
                return true

            case .noWork, .committed, .deliveredWithoutEpoch, .delivered:
                return false
            case .deliveryUncertain:
                errorMessage = "Checking the queued message…"
            case .blocked:
                errorMessage = "The next queued message needs review before it can be sent."
            case .ambiguous:
                errorMessage = "The queued message crossed an uncertain delivery boundary. It will not be sent again automatically."
            }
        } catch FollowUpDrainError.unauthorized {
            await onUnauthorized()
        } catch is CancellationError {
            return false
        } catch {
            // Admission failures stay on the queue strip; the item keeps its
            // "Next message" state and drains again after the next response.
            errorMessage = nil
        }
        return false
    }

    private func installAdmittedFollowUpUser(
        itemID: FollowUpQueueItemID,
        handle: GenerationHandle
    ) {
        guard let item = followUpQueue?.items.first(where: { $0.id == itemID }),
              case let .admitted(attempt, admittedHandle) = item.state,
              admittedHandle == handle,
              !messages.contains(where: { $0.id == attempt.clientMessageID }) else { return }
        messages.append(ChatMessage(
            id: attempt.clientMessageID,
            conversationID: conversation.id,
            parentMessageID: attempt.fingerprint.parentMessageID,
            content: [.text(attempt.fingerprint.text)]
                + attempt.fingerprint.attachments.map { .file($0.file) },
            author: .user,
            model: conversation.model,
            endpoint: conversation.target?.endpoint,
            createdAt: Date()
        ))
        preferredBranchFocusID = attempt.clientMessageID
        preferredBranchFallbackID = attempt.fingerprint.parentMessageID
        reconcileBranchSelection()
    }

    private func recoverGenerationIfNeeded() async {
        guard let snapshot = try? await repository.recoverableGenerations()
            .first(where: { owns($0.handle) }) else { return }
        generationSnapshot = snapshot
        activeGeneration = snapshot.handle
        activeOperationID = UUID()
        optimisticAssistantID = snapshot.response?.id
        preferredBranchFocusID = snapshot.response?.id
        preferredBranchFallbackID = snapshot.response?.parentMessageID
        if let response = snapshot.response, !messages.contains(where: { $0.id == response.id }) {
            messages.append(response)
        }
        reconcileBranchSelection()
        do {
            let reconciled = try await repository.reconcile(snapshot.handle)
            apply(reconciled)
            if !reconciled.state.isTerminal { retryRecovery() }
            else { await reloadAfterGeneration() }
        } catch {
            errorMessage = "A saved response is waiting to be reconciled."
        }
    }

    private func reloadAfterGeneration() async {
        await reload()
        if (routingState != .authoritative || historyState != .authoritative),
           errorMessage == nil {
            errorMessage = "The reply ended, but authoritative conversation details could not be refreshed."
        }
    }

    private func rollbackOptimisticMessages(restoring originalDraft: String) {
        let ids = Set([optimisticUserID, optimisticAssistantID].compactMap { $0 })
        messages.removeAll { ids.contains($0.id) }
        branchSelection = branchSelectionBeforeOptimisticSend ?? branchSelection
        reconcileBranchSelection()
        branchSelectionBeforeOptimisticSend = nil
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        historyState = .authoritative
        draft = originalDraft
        draftChanged()
    }

    private func removeLosingOptimisticMessages(restoring originalDraft: String) {
        let ids = Set([optimisticUserID, optimisticAssistantID].compactMap { $0 })
        messages.removeAll { ids.contains($0.id) }
        branchSelection = branchSelectionBeforeOptimisticSend ?? branchSelection
        reconcileBranchSelection()
        branchSelectionBeforeOptimisticSend = nil
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        optimisticUserID = nil
        optimisticAssistantID = nil
        // Cancel the debounced empty-draft save from `send()` before writing
        // the restored draft under the winner's (possibly promoted) identity.
        draftTask?.cancel()
        draftTask = nil
        draft = originalDraft
    }

    private func finishOperation(_ operationID: UUID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        activeGeneration = nil
        optimisticUserID = nil
        optimisticAssistantID = nil
        branchSelectionBeforeOptimisticSend = nil
        preferredBranchFocusID = nil
        preferredBranchFallbackID = nil
        isStreaming = false
        isStopping = false
        stopRequested = false
        isRespondingToInteraction = false
        respondingInteractionKey = nil
        steeringOperation = nil
        uncertainSteering = nil
        interactionTask?.cancel()
        interactionTask = nil
        sendTask = nil
        stopTask?.cancel()
        stopTask = nil
    }

    private func steeringControlRequest(
        for steer: PendingSteer
    ) -> GenerationSteerControlRequest? {
        guard steeringOperation == nil,
              uncertainSteering == nil,
              let handle = activeGeneration,
              owns(handle),
              generationSnapshot?.handle == handle,
              generationSnapshot?.pendingSteers.contains(where: {
                  $0.id == steer.id && $0.clientSteerID == steer.clientSteerID
              }) == true,
              let clientSteerID = steer.clientSteerID,
              !clientSteerID.isEmpty else { return nil }
        return GenerationSteerControlRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversation.id,
            handle: handle,
            steerID: steer.id,
            clientSteerID: clientSteerID
        )
    }

    private func isCurrentSteeringOperation(_ operation: SteeringOperationKey) -> Bool {
        steeringOperation == operation
            && activeGeneration == operation.handle
            && generationSnapshot?.handle == operation.handle
            && owns(operation.handle)
    }

    private func installAcceptedSteer(
        _ receipt: GenerationSteerReceipt,
        text: String,
        handle: GenerationHandle
    ) {
        guard var snapshot = generationSnapshot,
              snapshot.handle == handle,
              !snapshot.state.isTerminal else { return }
        let identities = Set([receipt.steerID, receipt.clientSteerID])
        guard !snapshot.appliedSteers.contains(where: {
            !identities.isDisjoint(with: Set([$0.id, $0.clientSteerID].compactMap { $0 }))
        }), !snapshot.recoverableSteers.contains(where: {
            !identities.isDisjoint(with: Set([$0.id, $0.clientSteerID].compactMap { $0 }))
        }) else { return }

        let pending = PendingSteer(
            id: receipt.steerID,
            clientSteerID: receipt.clientSteerID,
            text: text,
            preempt: receipt.preempt,
            preemptRevision: receipt.preemptRevision
        )
        snapshot.pendingSteers.removeAll {
            $0.id == receipt.steerID || $0.clientSteerID == receipt.clientSteerID
        }
        let insertionIndex = min(max(receipt.position, 0), snapshot.pendingSteers.count)
        snapshot.pendingSteers.insert(pending, at: insertionIndex)
        generationSnapshot = snapshot
    }

    private func installRecoverableSteer(
        _ receipt: GenerationSteerReceipt,
        text: String,
        handle: GenerationHandle
    ) {
        guard var snapshot = generationSnapshot,
              snapshot.handle == handle else { return }
        snapshot.pendingSteers.removeAll {
            $0.id == receipt.steerID || $0.clientSteerID == receipt.clientSteerID
        }
        snapshot.recoverableSteers.removeAll {
            $0.id == receipt.steerID || $0.clientSteerID == receipt.clientSteerID
        }
        snapshot.recoverableSteers.append(PendingSteer(
            id: receipt.steerID,
            clientSteerID: receipt.clientSteerID,
            text: text,
            preempt: receipt.preempt,
            preemptRevision: receipt.preemptRevision
        ))
        generationSnapshot = snapshot
    }

    private func removeAcceptedSteer(_ steer: PendingSteer, handle: GenerationHandle) {
        guard var snapshot = generationSnapshot, snapshot.handle == handle else { return }
        snapshot.pendingSteers.removeAll {
            $0.id == steer.id && $0.clientSteerID == steer.clientSteerID
        }
        generationSnapshot = snapshot
    }

    private func armAcceptedSteer(
        _ steer: PendingSteer,
        revision: Int,
        handle: GenerationHandle
    ) {
        guard var snapshot = generationSnapshot,
              snapshot.handle == handle,
              let index = snapshot.pendingSteers.firstIndex(where: {
                  $0.id == steer.id && $0.clientSteerID == steer.clientSteerID
              }) else { return }
        let currentRevision = snapshot.pendingSteers[index].preemptRevision ?? -1
        guard revision >= currentRevision else { return }
        snapshot.pendingSteers[index].preempt = true
        snapshot.pendingSteers[index].preemptRevision = revision
        generationSnapshot = snapshot
    }

    private func reconcileSteeringState(handle: GenerationHandle) async {
        do {
            let reconciled = try await repository.reconcile(handle)
            guard activeGeneration == handle, owns(handle) else { return }
            apply(reconciled)
            if reconciled.state.isTerminal, let operationID = activeOperationID {
                let followUpSignal = followUpSignal(from: reconciled)
                await reloadAfterGeneration()
                guard activeGeneration == handle, activeOperationID == operationID else { return }
                if let followUpSignal,
                   await continueWithFollowUpQueue(
                       after: followUpSignal,
                       operationID: operationID
                   ) {
                    return
                }
                finishOperation(operationID)
            }
        } catch {
            guard activeGeneration == handle, owns(handle) else { return }
            if error.isUnauthorized { await onUnauthorized() }
        }
    }

    private func updateMessage(id: MessageID, change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func owns(_ handle: GenerationHandle) -> Bool {
        handle.profileID == profileID
            && handle.accountID == accountID
            && handle.conversationID == conversation.id
    }

    private func replaceGeneratedFile(_ updated: GeneratedFile) {
        for messageIndex in messages.indices {
            for contentIndex in messages[messageIndex].content.indices {
                guard case let .generatedFile(current) = messages[messageIndex].content[contentIndex]
                else { continue }
                var reducer = GeneratedFileReducer(files: [current])
                guard let merged = reducer.applyPreview(updated).first,
                      merged != current else { continue }
                messages[messageIndex].content[contentIndex] = .generatedFile(merged)
            }
        }
    }

    private var pendingGeneratedFilePreviews: [GeneratedFile] {
        var seen: Set<String> = []
        return visibleMessages.lazy.flatMap(\.content).compactMap { content -> GeneratedFile? in
            guard case let .generatedFile(file) = content,
                  file.lifecycle == .pending,
                  let fileID = file.fileID,
                  !fileID.isEmpty,
                  seen.insert(fileID).inserted else { return nil }
            return file
        }
    }

    private func interactionIsExpired(_ interaction: PendingInteraction, at date: Date) -> Bool {
        switch interaction {
        case let .toolApproval(request): request.isExpired(at: date)
        case let .userQuestion(question): question.isExpired(at: date)
        case .externalAuthentication: true
        }
    }

    private func isCurrentInteractionSubmission(
        _ key: InteractionSubmissionKey,
        operationID: UUID
    ) -> Bool {
        respondingInteractionKey == key
            && activeGeneration == key.handle
            && activeOperationID == operationID
            && owns(key.handle)
    }

    private func clearInteractionSubmission(_ key: InteractionSubmissionKey) {
        guard respondingInteractionKey == key else { return }
        isRespondingToInteraction = false
        respondingInteractionKey = nil
        interactionTask = nil
    }

    /// A resume POST is single-winner and never retried blindly. Transport and
    /// 409 outcomes are reconciled against the exact generation/action fence;
    /// retry is re-enabled only if the server still reports the identical
    /// pending action as authoritative.
    private func reconcileAmbiguousInteractionSubmission(
        key: InteractionSubmissionKey,
        submittedInteraction: PendingInteraction,
        operationID: UUID
    ) async {
        do {
            let reconciled = try await repository.reconcile(key.handle)
            guard isCurrentInteractionSubmission(key, operationID: operationID) else { return }
            apply(reconciled)

            if reconciled.state.isTerminal {
                clearInteractionSubmission(key)
                await reloadAfterGeneration()
                guard activeGeneration == key.handle,
                      activeOperationID == operationID else { return }
                finishOperation(operationID)
                return
            }

            if reconciled.pendingInteraction == submittedInteraction,
               reconciled.state == .awaitingApproval(submittedInteraction) {
                if interactionIsExpired(submittedInteraction, at: now()) {
                    isStreaming = false
                    errorMessage = "This request has expired and LibreChat still reports it as pending. It will not be submitted again."
                    return
                }
                clearInteractionSubmission(key)
                errorMessage = "Still generating — review and send again."
                return
            }

            clearInteractionSubmission(key)
            if reconciled.pendingInteraction != nil {
                errorMessage = "LibreChat returned an updated request. Review it before continuing."
                return
            }

            isStreaming = true
            do {
                try await repository.resume(key.handle)
                try Task.checkCancellation()
                guard activeGeneration == key.handle,
                      activeOperationID == operationID else { return }
                await consumeSnapshots(
                    handle: key.handle,
                    operationID: operationID,
                    cancellationPolicy: .acknowledgedInteraction
                )
            } catch is CancellationError {
                // Reconciliation proved the action was consumed before this
                // attach. Preserve that proof when attachment is cancelled.
                await handleAcknowledgedInteractionAttachFailure(
                    CancellationError(),
                    handle: key.handle,
                    operationID: operationID
                )
                return
            } catch {
                await handleAcknowledgedInteractionAttachFailure(
                    error,
                    handle: key.handle,
                    operationID: operationID
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentInteractionSubmission(key, operationID: operationID) else { return }
            if error.isUnauthorized {
                clearInteractionSubmission(key)
                await onUnauthorized()
                return
            }
            isStreaming = false
            errorMessage = "Couldn’t verify the response — use Resume to check."
        }
    }

    /// The pending action has already been consumed authoritatively. Stream
    /// attachment failures are recoverable, but must never restore the old
    /// approval/question or repeat its POST.
    private func handleAcknowledgedInteractionAttachFailure(
        _ error: Error,
        handle: GenerationHandle,
        operationID: UUID
    ) async {
        guard activeGeneration == handle,
              activeOperationID == operationID,
              owns(handle) else { return }
        isStreaming = false
        isStopping = false
        errorMessage = "Your response was submitted. The live connection could not reopen; use Resume to continue."
        if error.isUnauthorized { await onUnauthorized() }
    }
}

/// A streaming delta only grows text payloads: identity, authorship,
/// timing, tree position, and content structure all stay fixed. Anything
/// else (tool calls, files, reorderings) falls back to the full rebuild.
private extension ChatMessage {
    func isStreamingTextGrowth(of previous: ChatMessage) -> Bool {
        guard id == previous.id,
              conversationID == previous.conversationID,
              parentMessageID == previous.parentMessageID,
              author == previous.author,
              createdAt == previous.createdAt,
              model == previous.model,
              endpoint == previous.endpoint,
              content.count == previous.content.count,
              citationAttachments == previous.citationAttachments,
              artifactCatalog == previous.artifactCatalog,
              editableTextCatalog == previous.editableTextCatalog
        else { return false }
        for (newPart, oldPart) in zip(content, previous.content) {
            switch (newPart, oldPart) {
            case let (.text(newText), .text(oldText)):
                guard newText.count >= oldText.count else { return false }
            case let (.reasoning(newText), .reasoning(oldText)):
                guard newText.count >= oldText.count else { return false }
            default:
                guard newPart == oldPart else { return false }
            }
        }
        return true
    }
}

