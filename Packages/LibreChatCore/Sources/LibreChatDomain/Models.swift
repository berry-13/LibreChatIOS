import Foundation

public struct UserAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: AccountID
    public var name: String?
    public var username: String?
    public var email: String?
    /// The server-assigned role name. Older auth payloads may omit it.
    public var role: String?
    public var avatarURL: URL?
    public var twoFactorEnabled: Bool?
    public var memoriesEnabled: Bool?

    public init(
        id: AccountID,
        name: String? = nil,
        username: String? = nil,
        email: String? = nil,
        role: String? = nil,
        avatarURL: URL? = nil,
        twoFactorEnabled: Bool? = nil,
        memoriesEnabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.email = email
        self.role = role
        self.avatarURL = avatarURL
        self.twoFactorEnabled = twoFactorEnabled
        self.memoriesEnabled = memoriesEnabled
    }

    public var displayName: String {
        let candidates: [String?] = [name, username, email]
        return candidates
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .first ?? "LibreChat user"
    }
}

public enum TwoFactorProof: Codable, Equatable, Sendable {
    case authenticatorCode(String)
    case backupCode(String)

    public var value: String {
        switch self {
        case let .authenticatorCode(value), let .backupCode(value): value
        }
    }
}

public struct AuthenticatedSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let user: UserAccount

    public init(accessToken: String, user: UserAccount) {
        self.accessToken = accessToken
        self.user = user
    }
}

public struct TwoFactorChallenge: Codable, Equatable, Sendable {
    public let temporaryToken: String

    public init(temporaryToken: String) {
        self.temporaryToken = temporaryToken
    }
}

public struct TwoFactorSetup: Codable, Equatable, Sendable {
    public var secret: String?
    public var otpauthURL: URL?
    public var backupCodes: [String]

    public init(secret: String? = nil, otpauthURL: URL? = nil, backupCodes: [String] = []) {
        self.secret = secret
        self.otpauthURL = otpauthURL
        self.backupCodes = backupCodes
    }
}

public enum LoginResult: Codable, Equatable, Sendable {
    case authenticated(AuthenticatedSession)
    case requiresTwoFactor(TwoFactorChallenge)
}

/// A semantic password-login rejection that the native client can recover
/// from without guessing from localized UI text. LibreChat's pinned contract
/// reports this condition as HTTP 422 with a message-only envelope.
public enum AuthenticationLoginError: LocalizedError, Equatable, Sendable {
    case emailVerificationRequired

    public var errorDescription: String? {
        switch self {
        case .emailVerificationRequired:
            "Verify your email address before signing in."
        }
    }
}

public enum AuthenticationState: Codable, Equatable, Sendable {
    case restoring
    case needsServer
    case signedOut(ServerProfileID?)
    case awaitingTwoFactor(TwoFactorChallenge)
    case authenticated(UserAccount)
    case authenticatedOffline(UserAccount)

    public var user: UserAccount? {
        switch self {
        case let .authenticated(user), let .authenticatedOffline(user): user
        default: nil
        }
    }

    public var isReadOnly: Bool {
        if case .authenticatedOffline = self { return true }
        return false
    }
}

/// Browser-compatible request-scoped capabilities for an ephemeral LibreChat
/// agent. Model specs remain server-owned: this value only carries the public
/// companion fields that LibreChat's web client places in `ephemeralAgent`.
public struct EphemeralAgentConfiguration: Codable, Equatable, Hashable, Sendable {
    public enum ArtifactMode: Codable, Equatable, Hashable, Sendable {
        case disabled
        case serverDefault
        case named(String)
    }

    public var mcpServers: [String]
    public var webSearch: Bool
    public var fileSearch: Bool
    public var executeCode: Bool
    public var memory: Bool
    public var artifacts: ArtifactMode
    /// A model-spec-owned restriction. Nil means the spec did not advertise a
    /// restriction and a manual invocation may opt this turn into Skills.
    public var skillScope: EphemeralSkillScope?

    public init(
        mcpServers: [String] = [],
        webSearch: Bool = false,
        fileSearch: Bool = false,
        executeCode: Bool = false,
        memory: Bool = false,
        artifacts: ArtifactMode = .disabled,
        skillScope: EphemeralSkillScope? = nil
    ) {
        self.mcpServers = mcpServers
        self.webSearch = webSearch
        self.fileSearch = fileSearch
        self.executeCode = executeCode
        self.memory = memory
        self.artifacts = artifacts
        self.skillScope = skillScope
    }

    public var isSafeForRequest: Bool {
        guard mcpServers.count <= 128 else { return false }
        let values = mcpServers + {
            if case let .named(value) = artifacts { return [value] }
            return []
        }() + {
            if case let .names(names) = skillScope { return names }
            return []
        }()
        if case let .names(names) = skillScope,
           names.count > 1_000 || !names.allSatisfy({
               SkillInvocationCatalog.isValidName($0)
           }) {
            return false
        }
        return values.allSatisfy { value in
            !value.isEmpty
                && value.utf16.count <= 512
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
}

public struct ConversationTarget: Codable, Equatable, Hashable, Sendable {
    public var endpoint: String
    public var endpointType: String?
    public var model: String?
    public var agentID: String?
    public var assistantID: String?
    public var parentMessageID: MessageID?
    public var spec: String?
    public var promptPrefix: String?
    public var ephemeralAgent: EphemeralAgentConfiguration?

    public init(
        endpoint: String,
        endpointType: String? = nil,
        model: String? = nil,
        agentID: String? = nil,
        assistantID: String? = nil,
        parentMessageID: MessageID? = nil,
        spec: String? = nil,
        promptPrefix: String? = nil,
        ephemeralAgent: EphemeralAgentConfiguration? = nil
    ) {
        self.endpoint = endpoint
        self.endpointType = endpointType
        self.model = model
        self.agentID = agentID
        self.assistantID = assistantID
        self.parentMessageID = parentMessageID
        self.spec = spec
        self.promptPrefix = promptPrefix
        self.ephemeralAgent = ephemeralAgent
    }
}

public struct ChatTargetOption: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var subtitle: String?
    public var iconURL: URL?
    /// LibreChat-web also accepts bare icon values that name a built-in
    /// endpoint glyph (`iconURL: openAI` in librechat.yaml); those are not
    /// image URLs, so they travel as this display key instead.
    public var iconEndpoint: String?
    public var target: ConversationTarget

    public init(
        id: String,
        label: String,
        subtitle: String? = nil,
        iconURL: URL? = nil,
        iconEndpoint: String? = nil,
        target: ConversationTarget
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.iconURL = iconURL
        self.iconEndpoint = iconEndpoint
        self.target = target
    }
}

public struct Conversation: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ConversationID
    public var title: String
    public var model: String?
    public var updatedAt: Date?
    public var target: ConversationTarget?
    /// `nil` means this older or partial server response did not include an
    /// archive state; `false` is an explicit, active conversation.
    public var isArchived: Bool?
    /// `nil` means this older or partial server response did not include a
    /// pin state; `false` is an explicit unpinned conversation.
    public var pinned: Bool?
    /// Tags are names on the pinned LibreChat conversation wire model. The
    /// tag-directory API is intentionally outside this bounded core slice.
    public var tags: [String]?
    /// Nullable membership in the server's project namespace.
    public var projectID: ProjectID?
    /// Optional because legacy cache and partial server projections may omit
    /// the explicit flag. Older LibreChat rows with an expiration but no flag
    /// are still temporary.
    public var isTemporary: Bool?
    public var expiresAt: Date?

    public init(
        id: ConversationID,
        title: String,
        model: String? = nil,
        updatedAt: Date? = nil,
        target: ConversationTarget? = nil,
        isArchived: Bool? = nil,
        pinned: Bool? = nil,
        tags: [String]? = nil,
        projectID: ProjectID? = nil,
        isTemporary: Bool? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.model = model
        self.updatedAt = updatedAt
        self.target = target
        self.isArchived = isArchived
        self.pinned = pinned
        self.tags = tags
        self.projectID = projectID
        self.isTemporary = isTemporary
        self.expiresAt = expiresAt
    }

    public var isTemporaryConversation: Bool {
        isTemporary == true || (isTemporary == nil && expiresAt != nil)
    }
}

public enum MessageAuthor: Codable, Equatable, Hashable, Sendable {
    case user
    case assistant(name: String)
    case system(name: String?)

    public var displayName: String {
        switch self {
        case .user: "You"
        case let .assistant(name): name
        case let .system(name): name ?? "System"
        }
    }
}

public struct CodeContent: Codable, Equatable, Hashable, Sendable {
    public var language: String?
    public var code: String

    public init(language: String? = nil, code: String) {
        self.language = language
        self.code = code
    }
}

public struct UploadedFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var temporaryID: String?
    public var filename: String
    public var filepath: String?
    public var mimeType: String?
    public var bytes: Int64?
    public var context: String?
    public var source: String?
    public var embedded: Bool?
    public var width: Int?
    public var height: Int?
    public var expiresAt: String?
    public var previewStatus: String?

    public init(
        id: String,
        temporaryID: String? = nil,
        filename: String,
        filepath: String? = nil,
        mimeType: String? = nil,
        bytes: Int64? = nil,
        context: String? = nil,
        source: String? = nil,
        embedded: Bool? = nil,
        width: Int? = nil,
        height: Int? = nil,
        expiresAt: String? = nil,
        previewStatus: String? = nil
    ) {
        self.id = id
        self.temporaryID = temporaryID
        self.filename = filename
        self.filepath = filepath
        self.mimeType = mimeType
        self.bytes = bytes
        self.context = context
        self.source = source
        self.embedded = embedded
        self.width = width
        self.height = height
        self.expiresAt = expiresAt
        self.previewStatus = previewStatus
    }
}

public struct MessageSummaryContent: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var tokenCount: Int?
    public var model: String?
    public var provider: String?
    public var isInProgress: Bool

    public init(
        text: String,
        tokenCount: Int? = nil,
        model: String? = nil,
        provider: String? = nil,
        isInProgress: Bool = false
    ) {
        self.text = text
        self.tokenCount = tokenCount
        self.model = model
        self.provider = provider
        self.isInProgress = isInProgress
    }
}

public struct MessageErrorContent: Codable, Equatable, Hashable, Sendable {
    public var code: String?
    public var message: String
    public var isRecoverable: Bool

    public init(code: String? = nil, message: String, isRecoverable: Bool = false) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

/// A privacy-bounded description of one child-agent progress envelope.
///
/// LibreChat's transport includes run and agent identifiers plus arbitrary
/// nested payloads. The stable domain keeps only the lifecycle information
/// needed to explain progress. Raw child reasoning, message deltas, tool
/// arguments, tool output, and transport identifiers never enter this value.
public enum SubagentActivityPhase: String, Codable, Equatable, Hashable, Sendable {
    case started
    case runningStep
    case updatingStep
    case completedStep
    case writing
    case reasoning
    case completed
    case failed
    case unknown
}

public struct SubagentActivityMetadata: Codable, Equatable, Hashable, Sendable {
    public var phase: SubagentActivityPhase
    /// Server-defined child type, such as `self` or `researcher`. Presentation
    /// must sanitize this value and must not treat it as an agent identifier.
    public var typeLabel: String?
    /// Tool names are retained for semantic progress only. Arguments and
    /// outputs are deliberately excluded at the protocol boundary.
    public var toolNames: [String]
    public var hasProducedText: Bool
    public var hasProducedReasoning: Bool

    public init(
        phase: SubagentActivityPhase,
        typeLabel: String? = nil,
        toolNames: [String] = [],
        hasProducedText: Bool = false,
        hasProducedReasoning: Bool = false
    ) {
        self.phase = phase
        self.typeLabel = typeLabel
        self.toolNames = toolNames
        self.hasProducedText = hasProducedText
        self.hasProducedReasoning = hasProducedReasoning
    }
}

public struct MessageActivityContent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var status: String?
    public var isPending: Bool
    public var agentID: String?
    public var subagent: SubagentActivityMetadata?

    public init(
        id: String,
        label: String,
        status: String? = nil,
        isPending: Bool = false,
        agentID: String? = nil,
        subagent: SubagentActivityMetadata? = nil
    ) {
        self.id = id
        self.label = label
        self.status = status
        self.isPending = isPending
        self.agentID = agentID
        self.subagent = subagent
    }
}

public enum MessageContent: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case reasoning(String)
    case summary(MessageSummaryContent)
    case code(CodeContent)
    case image(URL, alternativeText: String?)
    case video(URL, alternativeText: String?)
    case audio(URL, transcript: String?)
    case file(UploadedFile)
    /// Assistant/tool output with a deferred preview lifecycle. This is kept
    /// separate from uploaded input files so stream updates can replace a
    /// pending placeholder without reinterpreting the whole message.
    case generatedFile(GeneratedFile)
    case tool(ToolCall)
    case activity(MessageActivityContent)
    case error(MessageErrorContent)
    case toolReference(String)
    case unsupported(kind: String)

    public var textualValue: String? {
        switch self {
        case let .text(value), let .reasoning(value): value
        case let .summary(value): value.text
        case let .code(content): content.code
        case let .audio(_, transcript): transcript
        case let .tool(call): call.summary ?? call.name
        case let .activity(activity): activity.label
        case let .error(error): error.message
        default: nil
        }
    }
}

public struct ChatMessage: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: MessageID
    public let conversationID: ConversationID
    public var parentMessageID: MessageID?
    public var content: [MessageContent]
    public let author: MessageAuthor
    public var model: String?
    public var endpoint: String?
    public var createdAt: Date?
    public var isUnfinished: Bool?
    public var finishReason: String?
    public var feedback: MessageFeedback?
    /// Optional server replay metadata.  `nil` means the transport omitted
    /// the field; it is intentionally preserved so a repository can
    /// distinguish it from a non-empty value instead of silently dropping
    /// skills/quotes during a replay-sensitive action.
    public var manualSkills: [String]?
    public var quotes: [String]?
    /// Search/file-search provenance is retained separately from message
    /// content so citations survive history reload and stream replay.
    public var citationAttachments: [CitationAttachment]
    /// Authoritative, server-coordinate artifact catalog captured while the
    /// transport still knows whether source text came from a content part or
    /// the legacy `text` fallback.  This prevents DTO mapping from silently
    /// renumbering artifact edits.
    public var artifactCatalog: [ParsedArtifact]
    /// Exact server text locations retained before permissive content mapping.
    /// Like `artifactCatalog`, this lives inside the existing Codable cache
    /// blob and does not add a persistence-schema column.
    public var editableTextCatalog: [EditableMessageText]

    public init(
        id: MessageID,
        conversationID: ConversationID,
        parentMessageID: MessageID? = nil,
        content: [MessageContent],
        author: MessageAuthor,
        model: String? = nil,
        endpoint: String? = nil,
        createdAt: Date? = nil,
        isUnfinished: Bool? = nil,
        finishReason: String? = nil,
        feedback: MessageFeedback? = nil,
        manualSkills: [String]? = nil,
        quotes: [String]? = nil,
        citationAttachments: [CitationAttachment] = [],
        artifactCatalog: [ParsedArtifact] = [],
        editableTextCatalog: [EditableMessageText] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentMessageID = parentMessageID
        self.content = content
        self.author = author
        self.model = model
        self.endpoint = endpoint
        self.createdAt = createdAt
        self.isUnfinished = isUnfinished
        self.finishReason = finishReason
        self.feedback = feedback
        self.manualSkills = manualSkills
        self.quotes = quotes
        self.citationAttachments = citationAttachments
        self.artifactCatalog = artifactCatalog
        self.editableTextCatalog = editableTextCatalog
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, parentMessageID, content, author, model, endpoint, createdAt, isUnfinished, finishReason, feedback, manualSkills, quotes, citationAttachments, artifactCatalog, editableTextCatalog
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MessageID.self, forKey: .id)
        conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
        parentMessageID = try container.decodeIfPresent(MessageID.self, forKey: .parentMessageID)
        content = try container.decode([MessageContent].self, forKey: .content)
        author = try container.decode(MessageAuthor.self, forKey: .author)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        isUnfinished = try container.decodeIfPresent(Bool.self, forKey: .isUnfinished)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        feedback = try container.decodeIfPresent(MessageFeedback.self, forKey: .feedback)
        manualSkills = try container.decodeIfPresent([String].self, forKey: .manualSkills)
        quotes = try container.decodeIfPresent([String].self, forKey: .quotes)
        citationAttachments = try container.decodeIfPresent([CitationAttachment].self, forKey: .citationAttachments) ?? []
        artifactCatalog = try container.decodeIfPresent([ParsedArtifact].self, forKey: .artifactCatalog) ?? []
        editableTextCatalog = try container.decodeIfPresent([EditableMessageText].self, forKey: .editableTextCatalog) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(parentMessageID, forKey: .parentMessageID)
        try container.encode(content, forKey: .content)
        try container.encode(author, forKey: .author)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(isUnfinished, forKey: .isUnfinished)
        try container.encodeIfPresent(finishReason, forKey: .finishReason)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encodeIfPresent(manualSkills, forKey: .manualSkills)
        try container.encodeIfPresent(quotes, forKey: .quotes)
        try container.encode(citationAttachments, forKey: .citationAttachments)
        try container.encode(artifactCatalog, forKey: .artifactCatalog)
        try container.encode(editableTextCatalog, forKey: .editableTextCatalog)
    }

    public var rawPlainText: String {
        content.compactMap(\.textualValue).joined()
    }

    public var cleanedPlainText: String {
        CitationMarkerResolver.resolve(
            rawPlainText,
            sources: CitationSourceCatalog(attachments: citationAttachments)
        ).cleanedText
    }

    public var plainText: String { cleanedPlainText }
}

public enum ToolApprovalDecision: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case approve
    case reject
    case edit
    case respond
}

/// One independently reviewable tool call in a LibreChat approval interrupt.
///
/// `arguments` is intentionally presentation-ready text rather than an opaque
/// transport object. A missing value means the server did not disclose enough
/// information for a native approval and must fail closed.
public struct ToolApprovalItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var arguments: String?
    public var summary: String?
    public var allowedDecisions: [ToolApprovalDecision]

    public init(
        id: String,
        name: String,
        arguments: String?,
        summary: String? = nil,
        allowedDecisions: [ToolApprovalDecision]
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.summary = summary
        self.allowedDecisions = allowedDecisions
    }
}

public struct ToolApprovalResolution: Codable, Equatable, Hashable, Sendable {
    public let toolCallID: String
    public var decision: ToolApprovalDecision
    /// Raw JSON typed by the user. The repository accepts it only when it is a
    /// JSON object and serializes the parsed object as `editedArguments`.
    public var editedArgumentsJSON: String?
    public var responseText: String?
    public var reason: String?
    public var scope: String

    public init(
        toolCallID: String,
        decision: ToolApprovalDecision,
        editedArgumentsJSON: String? = nil,
        responseText: String? = nil,
        reason: String? = nil,
        scope: String = "once"
    ) {
        self.toolCallID = toolCallID
        self.decision = decision
        self.editedArgumentsJSON = editedArgumentsJSON
        self.responseText = responseText
        self.reason = reason
        self.scope = scope
    }
}

public struct ToolApprovalRequest: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var toolName: String
    public var summary: String?
    public var toolCallIDs: [String]
    public var allowedDecisions: [String: [String]]
    /// Present for current protocol payloads. `nil` identifies a legacy cache
    /// entry that lacks per-call arguments and is therefore not actionable.
    public var items: [ToolApprovalItem]?
    public var createdAt: Date?
    public var expiresAt: Date?
    public var streamID: String?
    public var conversationID: ConversationID?
    public var runID: String?
    public var interruptID: String?

    public init(
        id: String,
        toolName: String,
        summary: String? = nil,
        toolCallIDs: [String] = [],
        allowedDecisions: [String: [String]] = [:],
        items: [ToolApprovalItem]? = nil,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        streamID: String? = nil,
        conversationID: ConversationID? = nil,
        runID: String? = nil,
        interruptID: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.toolCallIDs = toolCallIDs
        self.allowedDecisions = allowedDecisions
        self.items = items
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.streamID = streamID
        self.conversationID = conversationID
        self.runID = runID
        self.interruptID = interruptID
    }

    public init(
        id: String,
        items: [ToolApprovalItem],
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        streamID: String? = nil,
        conversationID: ConversationID? = nil,
        runID: String? = nil,
        interruptID: String? = nil
    ) {
        self.id = id
        self.items = items
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.streamID = streamID
        self.conversationID = conversationID
        self.runID = runID
        self.interruptID = interruptID
        toolName = items.count == 1 ? (items.first?.name ?? "Tool") : "\(items.count) tool calls"
        summary = items.first?.summary
        toolCallIDs = items.map(\.id)
        allowedDecisions = items.reduce(into: [:]) { result, item in
            // Duplicate identities remain visible in `items` so repository
            // validation can fail closed; the compatibility dictionary must
            // never trap while decoding or constructing evolving payloads.
            result[item.id] = item.allowedDecisions.map(\.rawValue)
        }
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

public struct UserQuestion: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var prompt: String
    public var detail: String?
    public var options: [String]
    public var optionValues: [String: String]
    public var questionIDs: [String]
    public var items: [UserQuestionItem]?
    public var allowsMultipleSelection: Bool?
    public var createdAt: Date?
    public var expiresAt: Date?
    public var streamID: String?
    public var conversationID: ConversationID?
    public var runID: String?
    public var interruptID: String?

    public init(
        id: String,
        prompt: String,
        detail: String? = nil,
        options: [String] = [],
        optionValues: [String: String] = [:],
        questionIDs: [String] = [],
        items: [UserQuestionItem]? = nil,
        allowsMultipleSelection: Bool? = nil,
        createdAt: Date? = nil,
        expiresAt: Date? = nil,
        streamID: String? = nil,
        conversationID: ConversationID? = nil,
        runID: String? = nil,
        interruptID: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.optionValues = optionValues
        self.questionIDs = questionIDs
        self.items = items
        self.allowsMultipleSelection = allowsMultipleSelection
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.streamID = streamID
        self.conversationID = conversationID
        self.runID = runID
        self.interruptID = interruptID
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

public struct UserQuestionItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var header: String?
    public var prompt: String
    public var detail: String?
    public var options: [String]
    public var optionValues: [String: String]
    public var allowsMultipleSelection: Bool

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        detail: String? = nil,
        options: [String] = [],
        optionValues: [String: String] = [:],
        allowsMultipleSelection: Bool = false
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.optionValues = optionValues
        self.allowsMultipleSelection = allowsMultipleSelection
    }
}

public struct ExternalAuthRequest: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public var serviceName: String
    public var authorizationURL: URL

    public init(id: String, serviceName: String, authorizationURL: URL) {
        self.id = id
        self.serviceName = serviceName
        self.authorizationURL = authorizationURL
    }
}

public enum PendingInteraction: Codable, Equatable, Hashable, Sendable {
    case toolApproval(ToolApprovalRequest)
    case userQuestion(UserQuestion)
    case externalAuthentication(ExternalAuthRequest)
}

/// Semantic evidence retained from a persisted `subagent_content` trace.
/// It intentionally records presence and tool names only; child text,
/// reasoning, arguments, and output remain outside the stable domain.
public struct SubagentTraceSummary: Codable, Equatable, Hashable, Sendable {
    public var toolNames: [String]
    public var hasResponseText: Bool
    public var hasReasoning: Bool

    public init(
        toolNames: [String] = [],
        hasResponseText: Bool = false,
        hasReasoning: Bool = false
    ) {
        self.toolNames = toolNames
        self.hasResponseText = hasResponseText
        self.hasReasoning = hasReasoning
    }
}

public struct ToolCall: Codable, Equatable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending, running, awaitingApproval, completed, failed
    }

    public let id: String
    public var name: String
    public var status: Status
    public var summary: String?
    public var duration: TimeInterval?
    public var input: String?
    public var output: String?
    public var progress: Double?
    public var authorizationURL: URL?
    public var subagentTrace: SubagentTraceSummary?

    public init(
        id: String,
        name: String,
        status: Status,
        summary: String? = nil,
        duration: TimeInterval? = nil,
        input: String? = nil,
        output: String? = nil,
        progress: Double? = nil,
        authorizationURL: URL? = nil,
        subagentTrace: SubagentTraceSummary? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.summary = summary
        self.duration = duration
        self.input = input
        self.output = output
        self.progress = progress
        self.authorizationURL = authorizationURL
        self.subagentTrace = subagentTrace
    }
}

public struct RunStep: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var isComplete: Bool

    public init(id: String, label: String, isComplete: Bool = false) {
        self.id = id
        self.label = label
        self.isComplete = isComplete
    }
}

public struct TokenUsage: Codable, Equatable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ContextUsage: Codable, Equatable, Hashable, Sendable {
    public var maximumTokens: Int?
    public var messageTokens: Int?
    public var instructionTokens: Int?
    public var remainingTokens: Int?
    public var toolCount: Int?
    public var messageCount: Int?

    public init(
        maximumTokens: Int? = nil,
        messageTokens: Int? = nil,
        instructionTokens: Int? = nil,
        remainingTokens: Int? = nil,
        toolCount: Int? = nil,
        messageCount: Int? = nil
    ) {
        self.maximumTokens = maximumTokens
        self.messageTokens = messageTokens
        self.instructionTokens = instructionTokens
        self.remainingTokens = remainingTokens
        self.toolCount = toolCount
        self.messageCount = messageCount
    }
}
