import Foundation

public struct GenerationHandle: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let clientRequestID: UUID
    public let streamID: String
    public let conversationID: ConversationID
    public let generationCreatedAt: Int64?
    public let protocolVersion: Int

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        clientRequestID: UUID,
        streamID: String,
        conversationID: ConversationID,
        generationCreatedAt: Int64?,
        protocolVersion: Int
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.clientRequestID = clientRequestID
        self.streamID = streamID
        self.conversationID = conversationID
        self.generationCreatedAt = generationCreatedAt
        self.protocolVersion = protocolVersion
    }
}

public struct GenerationFailure: Error, Codable, Equatable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var isRecoverable: Bool

    public init(code: String, message: String, isRecoverable: Bool) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

/// A terminal result returned by the generation-start admission request.
///
/// This deliberately has no `GenerationHandle`: the server has not granted a
/// live generation epoch to attach to. Consumers must reload authoritative
/// history instead of attributing the most recent assistant message to the
/// optimistic submission that made the request.
public enum ChatSendOutcome: Codable, Equatable, Hashable, Sendable {
    case streaming(GenerationHandle)
    /// A separately-proven, already-existing generation won admission for
    /// this conversation. This is deliberately distinct from `.streaming`:
    /// the caller's POST did not start it and must never be retried or
    /// attributed to this handle.
    case handoff(GenerationHandle)
    case settled(conversationID: ConversationID)
    case aborted(conversationID: ConversationID)
    case failed(conversationID: ConversationID, failure: GenerationFailure)

    public var conversationID: ConversationID {
        switch self {
        case let .streaming(handle), let .handoff(handle):
            handle.conversationID
        case let .settled(conversationID), let .aborted(conversationID):
            conversationID
        case let .failed(conversationID, _):
            conversationID
        }
    }

    public var streamingHandle: GenerationHandle? {
        guard case let .streaming(handle) = self else { return nil }
        return handle
    }

    public var handoffHandle: GenerationHandle? {
        guard case let .handoff(handle) = self else { return nil }
        return handle
    }
}

public enum GenerationState: Codable, Equatable, Hashable, Sendable {
    case starting
    case streaming
    case awaitingApproval(PendingInteraction)
    case stopping
    case reconnecting(attempt: Int)
    case reconciling
    case superseded
    case completed
    case aborted
    case failed(GenerationFailure)

    public var isTerminal: Bool {
        switch self {
        case .superseded, .completed, .aborted, .failed: true
        default: false
        }
    }
}

public enum GenerationTerminal: Codable, Equatable, Hashable, Sendable {
    case completed
    case unfinished
    case reconciliationRequired(reason: String?)
}

public enum GenerationLifecycle: String, Codable, Equatable, Hashable, Sendable {
    case resumed
    case settled
    case replaced
    case predecessorMismatch = "predecessor_mismatch"
}

public struct GenerationSync: Codable, Equatable, Hashable, Sendable {
    public var aggregatedContent: [MessageContent]
    public var runSteps: [RunStep]
    public var toolCalls: [ToolCall]
    public var activities: [MessageActivityContent]
    public var pendingInteraction: PendingInteraction?
    public var usage: TokenUsage?
    public var contextUsage: ContextUsage?
    /// Steers already injected into the authoritative response content.
    public var appliedSteers: [SteerEvent]
    /// Server-owned FIFO items that have not reached an injection boundary.
    public var pendingSteers: [PendingSteer]
    /// Terminally parked items whose words still need an explicit client recovery flow.
    public var recoverableSteers: [PendingSteer]
    public var title: String?
    public var isComplete: Bool

    public init(
        aggregatedContent: [MessageContent] = [],
        runSteps: [RunStep] = [],
        toolCalls: [ToolCall] = [],
        activities: [MessageActivityContent] = [],
        pendingInteraction: PendingInteraction? = nil,
        usage: TokenUsage? = nil,
        contextUsage: ContextUsage? = nil,
        appliedSteers: [SteerEvent] = [],
        pendingSteers: [PendingSteer] = [],
        recoverableSteers: [PendingSteer] = [],
        title: String? = nil,
        isComplete: Bool = false
    ) {
        self.aggregatedContent = aggregatedContent
        self.runSteps = runSteps
        self.toolCalls = toolCalls
        self.activities = activities
        self.pendingInteraction = pendingInteraction
        self.usage = usage
        self.contextUsage = contextUsage
        self.appliedSteers = appliedSteers
        self.pendingSteers = pendingSteers
        self.recoverableSteers = recoverableSteers
        self.title = title
        self.isComplete = isComplete
    }

    /// Compatibility spelling for callers compiled against the first reducer model.
    public var steers: [SteerEvent] {
        get { appliedSteers }
        set { appliedSteers = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case aggregatedContent, runSteps, toolCalls, activities, pendingInteraction
        case usage, contextUsage, appliedSteers, pendingSteers, recoverableSteers
        case title, isComplete
        case legacySteers = "steers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aggregatedContent = try container.decodeIfPresent([MessageContent].self, forKey: .aggregatedContent) ?? []
        runSteps = try container.decodeIfPresent([RunStep].self, forKey: .runSteps) ?? []
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        activities = try container.decodeIfPresent([MessageActivityContent].self, forKey: .activities) ?? []
        pendingInteraction = try container.decodeIfPresent(PendingInteraction.self, forKey: .pendingInteraction)
        usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
        contextUsage = try container.decodeIfPresent(ContextUsage.self, forKey: .contextUsage)
        appliedSteers = try container.decodeIfPresent([SteerEvent].self, forKey: .appliedSteers)
            ?? container.decodeIfPresent([SteerEvent].self, forKey: .legacySteers)
            ?? []
        pendingSteers = try container.decodeIfPresent([PendingSteer].self, forKey: .pendingSteers) ?? []
        recoverableSteers = try container.decodeIfPresent([PendingSteer].self, forKey: .recoverableSteers) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aggregatedContent, forKey: .aggregatedContent)
        try container.encode(runSteps, forKey: .runSteps)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(activities, forKey: .activities)
        try container.encodeIfPresent(pendingInteraction, forKey: .pendingInteraction)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(contextUsage, forKey: .contextUsage)
        try container.encode(appliedSteers, forKey: .appliedSteers)
        try container.encode(pendingSteers, forKey: .pendingSteers)
        try container.encode(recoverableSteers, forKey: .recoverableSteers)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(isComplete, forKey: .isComplete)
    }
}

public enum GenerationEvent: Codable, Equatable, Hashable, Sendable {
    case created(ChatMessage?)
    case textDelta(String)
    case reasoningDelta(String)
    case replaceContent([MessageContent])
    case runStep(RunStep)
    case toolCall(ToolCall)
    case activity(MessageActivityContent)
    case attachment(MessageContent)
    case citationAttachment(CitationAttachment)
    case title(String)
    case pendingInteraction(PendingInteraction)
    case usage(TokenUsage)
    case contextUsage(ContextUsage)
    /// A steer proven to be present in response content.
    case steer(SteerEvent)
    case pendingSteerUpdate(PendingSteerUpdate)
    case recoverableSteers([PendingSteer])
    case synchronization(GenerationSync)
    case lifecycle(GenerationLifecycle)
    case reconnecting(attempt: Int)
    case stopRequested
    case terminal(GenerationTerminal)
    case completed
    case aborted
    case failed(GenerationFailure)
    case unsupported(kind: String)

    public var requiresImmediatePublication: Bool {
        switch self {
        case .textDelta, .reasoningDelta: false
        default: true
        }
    }
}

public struct SequencedGenerationEvent: Codable, Equatable, Hashable, Sendable {
    public var id: String?
    public var event: GenerationEvent

    public init(id: String? = nil, event: GenerationEvent) {
        self.id = id
        self.event = event
    }
}

public struct GenerationSnapshot: Codable, Equatable, Hashable, Sendable {
    public let handle: GenerationHandle
    public var state: GenerationState
    public var response: ChatMessage?
    public var reasoning: String
    public var runSteps: [RunStep]
    public var toolCalls: [ToolCall]
    public var activities: [MessageActivityContent]
    public var pendingInteraction: PendingInteraction?
    public var usage: TokenUsage?
    public var contextUsage: ContextUsage?
    /// Steers proven applied by inline content or `on_steer_applied`.
    public var appliedSteers: [SteerEvent]
    /// Steers still owned by the server's live FIFO.
    public var pendingSteers: [PendingSteer]
    /// Terminal leftovers surfaced exactly once per steer identity to a future
    /// recovery owner. This core slice deliberately does not submit them.
    public var recoverableSteers: [PendingSteer]
    public var title: String?
    public var lastEventID: String?
    public var stopRequestedAt: Date?
    public var updatedAt: Date

    public init(
        handle: GenerationHandle,
        state: GenerationState = .starting,
        response: ChatMessage? = nil,
        reasoning: String = "",
        runSteps: [RunStep] = [],
        toolCalls: [ToolCall] = [],
        activities: [MessageActivityContent] = [],
        pendingInteraction: PendingInteraction? = nil,
        usage: TokenUsage? = nil,
        contextUsage: ContextUsage? = nil,
        appliedSteers: [SteerEvent] = [],
        pendingSteers: [PendingSteer] = [],
        recoverableSteers: [PendingSteer] = [],
        title: String? = nil,
        lastEventID: String? = nil,
        stopRequestedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.handle = handle
        self.state = state
        self.response = response
        self.reasoning = reasoning
        self.runSteps = runSteps
        self.toolCalls = toolCalls
        self.activities = activities
        self.pendingInteraction = pendingInteraction
        self.usage = usage
        self.contextUsage = contextUsage
        self.appliedSteers = appliedSteers
        self.pendingSteers = pendingSteers
        self.recoverableSteers = recoverableSteers
        self.title = title
        self.lastEventID = lastEventID
        self.stopRequestedAt = stopRequestedAt
        self.updatedAt = updatedAt
    }

    /// Compatibility spelling for presentation code written before pending
    /// and applied steer ownership were modeled separately.
    public var steers: [SteerEvent] {
        get { appliedSteers }
        set { appliedSteers = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case handle, state, response, reasoning, runSteps, toolCalls, activities
        case pendingInteraction, usage, contextUsage, appliedSteers, pendingSteers
        case recoverableSteers, title, lastEventID, stopRequestedAt, updatedAt
        case legacySteers = "steers"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decode(GenerationHandle.self, forKey: .handle)
        state = try container.decode(GenerationState.self, forKey: .state)
        response = try container.decodeIfPresent(ChatMessage.self, forKey: .response)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        runSteps = try container.decodeIfPresent([RunStep].self, forKey: .runSteps) ?? []
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        activities = try container.decodeIfPresent([MessageActivityContent].self, forKey: .activities) ?? []
        pendingInteraction = try container.decodeIfPresent(PendingInteraction.self, forKey: .pendingInteraction)
        usage = try container.decodeIfPresent(TokenUsage.self, forKey: .usage)
        contextUsage = try container.decodeIfPresent(ContextUsage.self, forKey: .contextUsage)
        appliedSteers = try container.decodeIfPresent([SteerEvent].self, forKey: .appliedSteers)
            ?? container.decodeIfPresent([SteerEvent].self, forKey: .legacySteers)
            ?? []
        pendingSteers = try container.decodeIfPresent([PendingSteer].self, forKey: .pendingSteers) ?? []
        recoverableSteers = try container.decodeIfPresent([PendingSteer].self, forKey: .recoverableSteers) ?? []
        title = try container.decodeIfPresent(String.self, forKey: .title)
        lastEventID = try container.decodeIfPresent(String.self, forKey: .lastEventID)
        stopRequestedAt = try container.decodeIfPresent(Date.self, forKey: .stopRequestedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handle, forKey: .handle)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(response, forKey: .response)
        try container.encode(reasoning, forKey: .reasoning)
        try container.encode(runSteps, forKey: .runSteps)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(activities, forKey: .activities)
        try container.encodeIfPresent(pendingInteraction, forKey: .pendingInteraction)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(contextUsage, forKey: .contextUsage)
        try container.encode(appliedSteers, forKey: .appliedSteers)
        try container.encode(pendingSteers, forKey: .pendingSteers)
        try container.encode(recoverableSteers, forKey: .recoverableSteers)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(lastEventID, forKey: .lastEventID)
        try container.encodeIfPresent(stopRequestedAt, forKey: .stopRequestedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public struct SteerEvent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var clientSteerID: String?
    public var targetMessageID: MessageID?
    public var conversationID: ConversationID?
    public var contentIndex: Int?
    public var text: String?
    public var createdAt: Int64?
    public var files: [UploadedFile]

    public init(
        id: String,
        clientSteerID: String? = nil,
        targetMessageID: MessageID? = nil,
        conversationID: ConversationID? = nil,
        contentIndex: Int? = nil,
        text: String? = nil,
        createdAt: Int64? = nil,
        files: [UploadedFile] = []
    ) {
        self.id = id
        self.clientSteerID = clientSteerID
        self.targetMessageID = targetMessageID
        self.conversationID = conversationID
        self.contentIndex = contentIndex
        self.text = text
        self.createdAt = createdAt
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case id, clientSteerID, targetMessageID, conversationID, contentIndex
        case text, createdAt, files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        clientSteerID = try container.decodeIfPresent(String.self, forKey: .clientSteerID)
        targetMessageID = try container.decodeIfPresent(MessageID.self, forKey: .targetMessageID)
        conversationID = try container.decodeIfPresent(ConversationID.self, forKey: .conversationID)
        contentIndex = try container.decodeIfPresent(Int.self, forKey: .contentIndex)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
        files = try container.decodeIfPresent([UploadedFile].self, forKey: .files) ?? []
    }
}

/// A server-acknowledged steer that has not yet been injected into response content.
public struct PendingSteer: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var clientSteerID: String?
    public var text: String
    public var createdAt: Int64?
    public var files: [UploadedFile]
    public var preempt: Bool?
    public var preemptRevision: Int?

    public init(
        id: String,
        clientSteerID: String? = nil,
        text: String,
        createdAt: Int64? = nil,
        files: [UploadedFile] = [],
        preempt: Bool? = nil,
        preemptRevision: Int? = nil
    ) {
        self.id = id
        self.clientSteerID = clientSteerID
        self.text = text
        self.createdAt = createdAt
        self.files = files
        self.preempt = preempt
        self.preemptRevision = preemptRevision
    }

    /// The complete identity a recovery owner must echo when acknowledging a
    /// terminally parked steer. Keeping both coordinates prevents a stale
    /// client-only identifier from acknowledging a different server item.
    public var recoveryIdentity: RecoverableSteerIdentity {
        RecoverableSteerIdentity(id: id, clientSteerID: clientSteerID)
    }
}

public struct RecoverableSteerIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let clientSteerID: String?

    public init(id: String, clientSteerID: String? = nil) {
        self.id = id
        self.clientSteerID = clientSteerID
    }
}

/// A terminal generation's parked steer words. This is intentionally not a
/// chat request: deciding whether and how to use these words remains an
/// explicit future user action.
public struct RecoverableSteerBatch: Codable, Equatable, Hashable, Sendable {
    public let handle: GenerationHandle
    public var steers: [PendingSteer]
    public var checkpointedAt: Date

    public init(
        handle: GenerationHandle,
        steers: [PendingSteer],
        checkpointedAt: Date
    ) {
        self.handle = handle
        self.steers = steers
        self.checkpointedAt = checkpointedAt
    }
}

public enum RecoverableSteerError: Error, Codable, Equatable, Hashable, Sendable {
    /// The supplied profile/account/conversation does not own the handle.
    case contextMismatch
}

public struct PendingSteerUpdate: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var clientSteerID: String?
    public var preempt: Bool
    public var preemptRevision: Int

    public init(
        id: String,
        clientSteerID: String? = nil,
        preempt: Bool,
        preemptRevision: Int
    ) {
        self.id = id
        self.clientSteerID = clientSteerID
        self.preempt = preempt
        self.preemptRevision = preemptRevision
    }
}

/// The user-facing intent for a generation start.  The action is deliberately
/// not a collection of LibreChat wire flags: repository code translates the
/// intent to the protocol only after it has validated the authoritative graph.
public enum ChatRequestAction: Codable, Equatable, Hashable, Sendable {
    case send
    /// Create a new user sibling from this persisted user turn.  The source
    /// message is never edited or deleted by generation start.
    case editPromptAndResubmit(sourceUserMessageID: MessageID)
    /// Regenerate one authoritative assistant response from its exact source
    /// user turn.  The repository translates this intent to LibreChat's
    /// response-regeneration wire flags only after validating the graph.
    case regenerateResponse(
        sourceUserMessageID: MessageID,
        targetAssistantMessageID: MessageID
    )
}

public struct ChatRequest: Codable, Equatable, Sendable {
    public var profileID: ServerProfileID
    public var accountID: AccountID
    public var conversation: Conversation
    public var parentMessageID: MessageID?
    public var text: String
    public var attachments: [UploadedFile]
    /// Exact kebab-case names selected for this user turn. The repository
    /// revalidates them against fresh role, ACL, active-state, and target
    /// evidence immediately before generation admission.
    public var manualSkills: [String]
    public var expectedPredecessorCreatedAt: Int64?
    /// Exact server-owned parked steer source to recover as a new user turn.
    /// When present, the repository requires a persisted conversation,
    /// resumable protocol v2, the source-derived `clientMessageID`, and an
    /// exact predecessor epoch. It is never downgraded to an ordinary send.
    public var recoverySteerID: String?
    /// Stable across the complete admission attempt, including transport and
    /// readiness retries.  Callers may persist/reuse it when retrying an
    /// identical request after an ambiguous return.
    public var clientRequestID: UUID
    /// Stable client-side message coordinate paired with `clientRequestID`.
    /// LibreChat's ambiguous-start history reconciliation uses both values.
    public var clientMessageID: MessageID
    public var action: ChatRequestAction

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversation: Conversation,
        parentMessageID: MessageID? = nil,
        text: String,
        attachments: [UploadedFile] = [],
        manualSkills: [String] = [],
        expectedPredecessorCreatedAt: Int64? = nil,
        recoverySteerID: String? = nil,
        clientRequestID: UUID = UUID(),
        clientMessageID: MessageID = MessageID(rawValue: UUID().uuidString),
        action: ChatRequestAction = .send
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.conversation = conversation
        self.parentMessageID = parentMessageID
        self.text = text
        self.attachments = attachments
        self.manualSkills = manualSkills
        self.expectedPredecessorCreatedAt = expectedPredecessorCreatedAt
        self.recoverySteerID = recoverySteerID
        self.clientRequestID = clientRequestID
        self.clientMessageID = clientMessageID
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case profileID, accountID, conversation, parentMessageID, text, attachments, manualSkills
        case expectedPredecessorCreatedAt, recoverySteerID, clientRequestID, clientMessageID, action
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(ServerProfileID.self, forKey: .profileID)
        accountID = try container.decode(AccountID.self, forKey: .accountID)
        conversation = try container.decode(Conversation.self, forKey: .conversation)
        parentMessageID = try container.decodeIfPresent(MessageID.self, forKey: .parentMessageID)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([UploadedFile].self, forKey: .attachments) ?? []
        manualSkills = try container.decodeIfPresent([String].self, forKey: .manualSkills) ?? []
        expectedPredecessorCreatedAt = try container.decodeIfPresent(
            Int64.self,
            forKey: .expectedPredecessorCreatedAt
        )
        recoverySteerID = try container.decodeIfPresent(String.self, forKey: .recoverySteerID)
        clientRequestID = try container.decodeIfPresent(UUID.self, forKey: .clientRequestID) ?? UUID()
        clientMessageID = try container.decodeIfPresent(MessageID.self, forKey: .clientMessageID)
            ?? MessageID(rawValue: UUID().uuidString)
        action = try container.decodeIfPresent(ChatRequestAction.self, forKey: .action) ?? .send
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(conversation, forKey: .conversation)
        try container.encodeIfPresent(parentMessageID, forKey: .parentMessageID)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(manualSkills, forKey: .manualSkills)
        try container.encodeIfPresent(expectedPredecessorCreatedAt, forKey: .expectedPredecessorCreatedAt)
        try container.encodeIfPresent(recoverySteerID, forKey: .recoverySteerID)
        try container.encode(clientRequestID, forKey: .clientRequestID)
        try container.encode(clientMessageID, forKey: .clientMessageID)
        try container.encode(action, forKey: .action)
    }
}
