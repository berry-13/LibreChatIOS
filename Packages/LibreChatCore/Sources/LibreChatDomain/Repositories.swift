import Foundation

public struct ConversationPage: Codable, Equatable, Sendable {
    public var conversations: [Conversation]
    public var nextCursor: String?
    public var fetchedAt: Date
    public var isFromCache: Bool

    public init(
        conversations: [Conversation],
        nextCursor: String? = nil,
        fetchedAt: Date = Date(),
        isFromCache: Bool = false
    ) {
        self.conversations = conversations
        self.nextCursor = nextCursor
        self.fetchedAt = fetchedAt
        self.isFromCache = isFromCache
    }
}

public protocol ConversationRepository: Sendable {
    func cachedConversations(limit: Int) async throws -> ConversationPage?
    func conversations(cursor: String?, limit: Int) async throws -> ConversationPage
    func conversation(id: ConversationID) async throws -> Conversation
    func cachedMessages(conversationID: ConversationID) async throws -> [ChatMessage]
    func messages(conversationID: ConversationID) async throws -> [ChatMessage]
    func searchConversations(query: String, cursor: String?, limit: Int) async throws -> ConversationPage
    func searchMessages(query: String) async throws -> MessageSearchPage
    func availableChatTargets() async throws -> [ChatTargetOption]
    func createConversation(title: String, target: ConversationTarget) async throws -> Conversation
    func createConversation(
        title: String,
        target: ConversationTarget,
        isTemporary: Bool
    ) async throws -> Conversation
    func delete(id: ConversationID) async throws
}

public extension ConversationRepository {
    func createConversation(
        title: String,
        target: ConversationTarget,
        isTemporary: Bool
    ) async throws -> Conversation {
        var conversation = try await createConversation(title: title, target: target)
        conversation.isTemporary = isTemporary
        return conversation
    }
}

/// Authenticated target discovery is separate from conversation browsing so
/// stale cached history can never be mistaken for authorization to start a run.
public protocol TargetCatalogRepository: Sendable {
    func targetCatalog(recentOptionID: String?) async throws -> TargetCatalogSnapshot
}

/// Live, account-scoped provider credentials. Catalogs contain status metadata
/// only; submitted secret material is never readable through this boundary.
public protocol UserKeyRepository: Sendable {
    func userKeyCatalog() async throws -> UserKeyCatalog
    func saveUserKey(_ input: UserKeyUpdateInput) async throws -> UserKeyMutationResult
    func revokeUserKey(_ endpointID: UserKeyEndpointID) async throws -> UserKeyMutationResult
}

/// Live account data and destructive account mutations. This boundary has no
/// offline fallback: cached identity can label local data but cannot authorize
/// a profile image change or account deletion.
public protocol AccountProfileRepository: Sendable {
    func accountProfile() async throws -> UserAccount
    /// Uploads once and returns only the account obtained from an authoritative
    /// post-mutation `/api/user` reconciliation. `previousAvatarURL` is the
    /// last account value visible to the caller and is used only to determine
    /// whether an ambiguous response can be proven to have changed state.
    func uploadAccountAvatar(
        _ upload: AccountAvatarUpload,
        previousAvatarURL: URL?
    ) async throws -> UserAccount
    func deleteAccount(proof: TwoFactorProof?) async throws
}

/// Read-only, ACL-filtered saved-agent discovery. Agent editing and permission
/// management use separate contracts because their authorization and payload
/// surfaces are materially more sensitive.
public protocol AgentRepository: Sendable {
    func agents(search: String?, cursor: String?, limit: Int) async throws -> ChatAgentPage
    func agent(id: AgentID) async throws -> ChatAgentDetail
}

/// Live-only, ACL- and target-scoped manual Skill invocation. Implementations
/// must re-read account permission, per-user active state, and target scope;
/// cached history is never authorization evidence.
public protocol SkillRepository: Sendable {
    func skillInvocationCatalog(for target: ConversationTarget) async throws -> SkillInvocationCatalog
    func accountSkillCatalog() async throws -> AccountSkillCatalog
    func setSkillActivation(_ request: SkillActivationRequest) async throws -> SkillActivationOutcome
}

public extension SkillRepository {
    func accountSkillCatalog() async throws -> AccountSkillCatalog {
        throw SkillManagementError.unavailable
    }

    func setSkillActivation(_ request: SkillActivationRequest) async throws -> SkillActivationOutcome {
        throw SkillManagementError.unavailable
    }
}

/// Live-only, metadata-bounded saved-agent mutations. The expanded server
/// payload is reduced before returning and no sensitive agent configuration is
/// cached or exposed to presentation.
public protocol AgentManagementRepository: Sendable {
    func agentManagementDetail(id: AgentID) async throws -> ManagedAgentMetadata
    func agentResourcePermissions(id: AgentID) async throws -> AgentResourcePermissions
    func agentVersions(id: AgentID) async throws -> AgentVersionHistory
    func updateAgentMetadata(_ input: AgentMetadataUpdateInput) async throws -> ManagedAgentMetadata
    func duplicateAgent(id: AgentID) async throws -> ChatAgentSummary
    func revertAgentVersion(_ version: AgentVersionSummary) async throws -> ManagedAgentMetadata
    func deleteAgent(id: AgentID) async throws
}

/// One-shot, native-safe saved-agent creation. Implementations must fetch and
/// validate a fresh `/api/models` catalog for the active profile/account
/// immediately before POSTing, must not retry the POST automatically, and may
/// return `outcomeUnknown` only for a dispatched request whose result cannot
/// be reconciled before returning control to the caller.
public protocol BasicAgentCreationRepository: Sendable {
    func createBasicAgent(_ request: BasicAgentCreationRequest) async throws -> BasicAgentCreationOutcome
}

/// Live, read-only MCP connection discovery. Server definitions, status, and
/// authorization remain server-owned and are deliberately not cached here.
public protocol MCPRepository: Sendable {
    func mcpConnections() async throws -> MCPConnectionCatalog
}

/// Server-authoritative personal memory access. Memory values are deliberately
/// not cached by this repository contract because they are sensitive account
/// data and the server enforces independently revocable role permissions.
public protocol MemoryRepository: Sendable {
    func memories() async throws -> MemorySnapshot
    func createMemory(_ input: CreateMemoryInput) async throws -> UserMemory
    func updateMemory(_ input: UpdateMemoryInput) async throws -> UserMemory
    func deleteMemory(_ input: DeleteMemoryInput) async throws
    func setMemoriesEnabled(_ enabled: Bool) async throws -> Bool
}

/// Live, ACL-filtered prompt-group browsing. Prompt content is not cached by
/// this boundary, and selecting a template never sends a chat automatically.
public protocol PromptRepository: Sendable {
    func promptGroups(_ query: PromptTemplateQuery) async throws -> PromptTemplatePage
    func recordPromptUsage(groupID: PromptGroupID) async throws -> Int
    /// The server's shared category directory backing the category dropdown
    /// in the prompt and agent editors.
    func promptCategories() async throws -> [String]
}

public extension PromptRepository {
    /// Doubles without a category directory read an empty list; the editor
    /// then falls back to free entry.
    func promptCategories() async throws -> [String] { [] }
}

/// Live-only prompt authoring. Mutations have no idempotency key and never use
/// an offline cache or automatic retry.
public protocol PromptManagementRepository: Sendable {
    func promptManagementDetail(groupID: PromptGroupID) async throws -> PromptManagementDetail
    func createPromptGroup(_ input: CreatePromptGroupInput) async throws -> PromptManagementDetail
    func addPromptVersion(_ input: AddPromptVersionInput) async throws -> ManagedPromptVersion
    func updatePromptGroup(_ input: UpdatePromptGroupInput) async throws -> ManagedPromptGroup
    func promotePromptVersion(
        groupID: PromptGroupID,
        versionID: PromptVersionID
    ) async throws -> ManagedPromptGroup
}

/// Live, owner-scoped preset browsing. Presets can contain private prompt
/// prefixes and provider configuration, so this boundary does not expose a
/// cached fallback. Applying a preset is a separate, reviewed New Chat action.
public protocol PresetRepository: Sendable {
    func presets() async throws -> PresetLibrarySnapshot
}

/// Live-only creation of a native-safe preset.
///
/// Implementations must fetch the current target catalog and call
/// `PresetCreationRequest.validatedTarget(in:)` immediately before dispatch.
/// Definite authentication and HTTP failures are thrown; only an already
/// dispatched request that cannot be reconciled may return `outcomeUnknown`.
public protocol PresetCreationRepository: TargetCatalogRepository {
    func createPreset(_ request: PresetCreationRequest) async throws -> PresetCreationOutcome
}

/// Live, owner-scoped file catalog browsing. File metadata is deliberately not
/// cached by this contract: the server can revoke access, expire uploads, or
/// change tenant/account ownership independently of local conversation state.
public protocol FileLibraryRepository: Sendable {
    func fileLibrary() async throws -> FileLibrarySnapshot
    func filePreview(fileID: String) async throws -> FilePreviewSnapshot
    func downloadFile(_ item: FileLibraryItem) async throws -> DownloadedLibraryFile
    func deleteFile(_ item: FileLibraryItem) async throws -> FileLibraryDeletionResult
}

public extension FileLibraryRepository {
    func downloadFile(_ item: FileLibraryItem) async throws -> DownloadedLibraryFile {
        throw FileLibraryError.unavailable
    }

    func deleteFile(_ item: FileLibraryItem) async throws -> FileLibraryDeletionResult {
        throw FileLibraryError.unavailable
    }
}

public extension TargetCatalogRepository {
    func targetCatalog() async throws -> TargetCatalogSnapshot {
        try await targetCatalog(recentOptionID: nil)
    }
}

/// Mutations for an existing, server-owned conversation.
///
/// This is intentionally separate from browsing and generation so clients can
/// adopt conversation management without taking on a tag directory or the
/// broader history repository surface.
public protocol ConversationManagementRepository: Sendable {
    func rename(id: ConversationID, title: String) async throws -> Conversation
    func archive(id: ConversationID, isArchived: Bool) async throws -> Conversation
    func pin(id: ConversationID, pinned: Bool) async throws -> Conversation
}

/// Personal conversation-tag directory operations. This is deliberately
/// separate from conversation rename/archive/pin management: tags are a
/// user-owned directory plus a conversation association mutation.
public protocol ConversationTagRepository: Sendable {
    func conversationTags() async throws -> [ConversationTag]
    func createConversationTag(_ input: CreateConversationTagInput) async throws -> ConversationTag
    func updateConversationTag(
        named tag: String,
        input: UpdateConversationTagInput
    ) async throws -> ConversationTag
    func deleteConversationTag(named tag: String) async throws -> ConversationTag
    func replaceConversationTags(
        conversationID: ConversationID,
        tags: [String]
    ) async throws -> [String]
}

public extension ConversationTagRepository {
    func tags() async throws -> [ConversationTag] {
        try await conversationTags()
    }

    func createTag(_ input: CreateConversationTagInput) async throws -> ConversationTag {
        try await createConversationTag(input)
    }

    func updateTag(
        named tag: String,
        input: UpdateConversationTagInput
    ) async throws -> ConversationTag {
        try await updateConversationTag(named: tag, input: input)
    }

    func deleteTag(named tag: String) async throws -> ConversationTag {
        try await deleteConversationTag(named: tag)
    }
}

/// Narrow owner-facing contract for the LibreChat shared-link lifecycle.
///
/// This intentionally excludes public snapshot viewing, ACL management, file
/// access, and forking; those require separate privacy and presentation flows.
public protocol SharedLinkRepository: Sendable {
    func sharedLink(for conversationID: ConversationID) async throws -> SharedLinkState
    func createSharedLink(
        for conversationID: ConversationID,
        request: SharedLinkPublishRequest
    ) async throws -> SharedLinkMutationResult
    func updateSharedLink(
        _ shareID: SharedLinkID,
        request: SharedLinkPublishRequest
    ) async throws -> SharedLinkMutationResult
    func deleteSharedLink(_ shareID: SharedLinkID) async throws -> SharedLinkDeletionResult
}

/// Read-only public shared snapshots plus the authenticated fork operation.
/// Public lookup is intentionally distinct from `ConversationRepository` so
/// pseudonymized snapshot data cannot be mistaken for owned history.
public protocol SharedSnapshotRepository: Sendable {
    func sharedSnapshot(for shareID: SharedLinkID) async throws -> SharedConversationSnapshot
    func forkSharedConversation(
        _ request: SharedConversationForkRequest
    ) async throws -> SharedConversationForkResult
}

public protocol ProjectRepository: Sendable {
    func projects(options: ChatProjectListOptions) async throws -> ChatProjectPage
    func project(id: ProjectID) async throws -> ChatProject
    func createProject(_ input: CreateChatProjectInput) async throws -> ChatProject
    func updateProject(id: ProjectID, input: UpdateChatProjectInput) async throws -> ChatProject
    func deleteProject(id: ProjectID) async throws -> DeleteChatProjectResult
    func assignConversation(
        id: ConversationID,
        to projectID: ProjectID?
    ) async throws -> ConversationProjectAssignment
    func projectConversations(
        projectID: ProjectID,
        cursor: String?,
        limit: Int
    ) async throws -> ConversationPage
}

public protocol ChatRepository: Sendable {
    func send(_ request: ChatRequest) async throws -> ChatSendOutcome
    func snapshots(for handle: GenerationHandle) async -> AsyncThrowingStream<GenerationSnapshot, Error>
    func resume(_ generation: GenerationHandle) async throws
    func reconcile(_ generation: GenerationHandle) async throws -> GenerationSnapshot
    func recoverActiveGenerations() async throws -> [GenerationSnapshot]
    func stop(_ generation: GenerationHandle) async throws
}

/// Authenticated, server-backed speech transcription. Implementations must not
/// automatically retry the multipart mutation after a transport or 5xx error.
public protocol SpeechTranscriptionRepository: Sendable {
    func speechCapabilities() async throws -> SpeechCapabilities
    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscription
}

public protocol SpeechSynthesisRepository: Sendable {
    func speechSynthesisVoices() async throws -> [SpeechSynthesisVoice]
    func speechSynthesisVoicePreference() async throws -> SpeechSynthesisVoicePreference?
    func setSpeechSynthesisVoicePreference(
        _ preference: SpeechSynthesisVoicePreference
    ) async throws
    func synthesizeSpeech(_ request: SpeechSynthesisRequest) async throws -> SynthesizedSpeechAudio
}

public extension SpeechSynthesisRepository {
    func speechSynthesisVoices() async throws -> [SpeechSynthesisVoice] { [] }

    func speechSynthesisVoicePreference() async throws -> SpeechSynthesisVoicePreference? { nil }

    func setSpeechSynthesisVoicePreference(
        _ preference: SpeechSynthesisVoicePreference
    ) async throws {
        throw SpeechSynthesisRepositoryError.unavailable
    }

    func synthesizeSpeech(
        _ request: SpeechSynthesisRequest
    ) async throws -> SynthesizedSpeechAudio {
        throw SpeechSynthesisRepositoryError.unavailable
    }
}

/// Durable access to terminal steer leftovers. This contract is separate
/// from active generation recovery so terminal records can never be resumed
/// or silently converted into an ordinary send.
public protocol RecoverableSteerRepository: Sendable {
    func recoverableSteerBatches(
        conversationID: ConversationID
    ) async throws -> [RecoverableSteerBatch]

    @discardableResult
    func acknowledgeRecoverableSteers(
        handle: GenerationHandle,
        identities: Set<RecoverableSteerIdentity>
    ) async throws -> RecoverableSteerBatch?
}

/// Server-side discard of one terminal v2 steer leftover. This does not expose
/// active steer control and does not acknowledge local recovery until an exact
/// `removed: true` response is proven.
public protocol RecoverableSteerDiscardRepository: Sendable {
    func discardRecoverableSteer(
        _ request: RecoverableSteerDiscardRequest
    ) async throws -> RecoverableSteerDiscardOutcome
}

/// Exact protocol-v2 generation controls. This remains separate from normal
/// sends and from the future local follow-up queue/drain coordinator.
public protocol GenerationSteeringRepository: Sendable {
    func submitSteer(
        _ request: GenerationSteerRequest
    ) async throws -> GenerationSteerSubmissionOutcome

    func cancelSteer(
        _ request: GenerationSteerControlRequest
    ) async throws -> GenerationSteerCancelOutcome

    func armSteer(
        _ request: GenerationSteerControlRequest
    ) async throws -> GenerationSteerArmOutcome
}

/// Save-only persisted message editing. This does not regenerate, continue,
/// resubmit, fork, or enqueue a generation.
public protocol MessageEditingRepository: Sendable {
    func saveMessageEdit(_ request: MessageEditRequest) async throws -> MessageEditResult
}

/// Rating and optional explanation for one persisted assistant response.
/// Mutations are not automatically retried because LibreChat also forwards
/// accepted feedback to configured observability destinations.
public protocol MessageFeedbackRepository: Sendable {
    func updateMessageFeedback(
        _ request: MessageFeedbackRequest
    ) async throws -> MessageFeedbackResult
}

/// Comparison-based editing for persisted message artifacts. Implementations
/// must not blindly retry this mutation and must reconcile ambiguous outcomes
/// against authoritative message history.
public protocol ArtifactRepository: Sendable {
    func updateArtifact(_ request: ArtifactEditRequest) async throws -> ChatMessage
}

public extension ArtifactRepository {
    func updateArtifact(_ request: ArtifactEditRequest) async throws -> ChatMessage {
        throw ArtifactEditError.unavailable
    }
}

/// Read/transfer operations for server-generated response files. Input
/// uploads remain a separate repository because their ownership, staging,
/// and retry semantics differ.
public protocol GeneratedFileRepository: Sendable {
    func refreshGeneratedFile(_ file: GeneratedFile) async throws -> GeneratedFile
    func downloadGeneratedFile(_ file: GeneratedFile) async throws -> DownloadedGeneratedFile
}

public extension GeneratedFileRepository {
    func refreshGeneratedFile(_ file: GeneratedFile) async throws -> GeneratedFile {
        throw GeneratedFileError.unavailable
    }

    func downloadGeneratedFile(_ file: GeneratedFile) async throws -> DownloadedGeneratedFile {
        throw GeneratedFileError.unavailable
    }
}

public protocol GenerationCheckpointStore: Sendable {
    func save(_ snapshot: GenerationSnapshot) async throws
    func recoverableGenerations(profileID: ServerProfileID, accountID: AccountID) async throws -> [GenerationSnapshot]
    func remove(handle: GenerationHandle) async throws
}

public protocol UploadRepository: Sendable {
    func enqueue(_ upload: PendingUpload) async throws
    func cancel(id: UUID) async
    func retry(id: UUID) async throws
}

public struct PendingUpload: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case staged, uploading, completed, queued, failed, deliveryUncertain, cancelled, attached
    }

    public let id: UUID
    public var profileID: ServerProfileID
    public var accountID: AccountID
    public var conversationID: ConversationID?
    public var localURL: URL
    public var filename: String
    public var mimeType: String?
    public var endpoint: String?
    public var endpointType: String?
    public var isTemporary: Bool?
    public var width: Int?
    public var height: Int?
    public var progress: Double
    public var state: State
    public var remoteIdentifier: String?
    public var remoteFile: UploadedFile?

    public init(
        id: UUID = UUID(),
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID? = nil,
        localURL: URL,
        filename: String,
        mimeType: String? = nil,
        endpoint: String? = nil,
        endpointType: String? = nil,
        isTemporary: Bool? = false,
        width: Int? = nil,
        height: Int? = nil,
        progress: Double = 0,
        state: State = .staged,
        remoteIdentifier: String? = nil,
        remoteFile: UploadedFile? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
        self.localURL = localURL
        self.filename = filename
        self.mimeType = mimeType
        self.endpoint = endpoint
        self.endpointType = endpointType
        self.isTemporary = isTemporary
        self.width = width
        self.height = height
        self.progress = progress
        self.state = state
        self.remoteIdentifier = remoteIdentifier
        self.remoteFile = remoteFile
    }
}
