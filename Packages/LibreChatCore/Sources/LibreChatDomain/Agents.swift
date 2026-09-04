import Foundation

/// Authenticated current-role permissions for LibreChat's saved-agent
/// feature. Resource ACLs remain authoritative for each individual agent;
/// these bits only decide whether the native app may expose the feature and
/// its creation-backed mutations.
public struct AgentPermissions: Codable, Equatable, Sendable {
    public var use: Bool
    public var create: Bool
    public var share: Bool
    public var sharePublicly: Bool

    public init(
        use: Bool = false,
        create: Bool = false,
        share: Bool = false,
        sharePublicly: Bool = false
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
    }

    public var canManageMetadata: Bool { use && create }
}

/// Non-sensitive metadata for one saved agent visible to the current account.
public struct ChatAgentSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentID
    public var name: String
    public var description: String?
    public var category: String?
    public var isPublic: Bool
    public var canEdit: Bool
    /// The agent's own avatar, resolved against its server origin. Nil means
    /// the server provided no usable avatar and callers show a fallback glyph.
    public var avatarURL: URL?

    public init(
        id: AgentID,
        name: String,
        description: String? = nil,
        category: String? = nil,
        isPublic: Bool = false,
        canEdit: Bool = false,
        avatarURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.isPublic = isPublic
        self.canEdit = canEdit
        self.avatarURL = avatarURL
    }
}

public struct ChatAgentPage: Codable, Equatable, Sendable {
    public var agents: [ChatAgentSummary]
    public var nextCursor: String?
    public var fetchedAt: Date

    public init(
        agents: [ChatAgentSummary],
        nextCursor: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.agents = agents
        self.nextCursor = nextCursor
        self.fetchedAt = fetchedAt
    }
}

/// View-safe detail returned by LibreChat's VIEW-permission endpoint. Sensitive
/// instructions, tools, actions, and credentials are intentionally absent.
public struct ChatAgentDetail: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentID
    public let resourceID: AgentResourceID?
    public var name: String
    public var description: String?
    public var conversationStarters: [String]
    public var provider: String?
    public var model: String?
    public var isPublic: Bool
    public var version: Int?
    /// VIEW-filtered skill scope. Nil server fields map to `.disabled` so a
    /// stale or redacted agent can never expose the full catalog by accident.
    public var skillScope: SavedAgentSkillScope

    public init(
        id: AgentID,
        resourceID: AgentResourceID? = nil,
        name: String,
        description: String? = nil,
        conversationStarters: [String] = [],
        provider: String? = nil,
        model: String? = nil,
        isPublic: Bool = false,
        version: Int? = nil,
        skillScope: SavedAgentSkillScope = .disabled
    ) {
        self.id = id
        self.resourceID = resourceID
        self.name = name
        self.description = description
        self.conversationStarters = conversationStarters
        self.provider = provider
        self.model = model
        self.isPublic = isPublic
        self.version = version
        self.skillScope = skillScope
    }
}

/// Deliberately small projection of LibreChat's EDIT-permission expanded
/// agent response. Instructions, tools, actions, files, credentials, and
/// provider parameters never cross this management boundary.
public struct ManagedAgentMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentID
    public let resourceID: AgentResourceID?
    public var name: String
    public var description: String?
    public var category: String?
    public var isPublic: Bool
    public var version: Int?

    public init(
        id: AgentID,
        resourceID: AgentResourceID? = nil,
        name: String,
        description: String? = nil,
        category: String? = nil,
        isPublic: Bool = false,
        version: Int? = nil
    ) {
        self.id = id
        self.resourceID = resourceID
        self.name = name
        self.description = description
        self.category = category
        self.isPublic = isPublic
        self.version = version
    }
}

/// Metadata-only PATCH input. Empty description/category strings are sent
/// intentionally so users can clear those fields without resending the
/// agent's sensitive expanded configuration.
public struct AgentMetadataUpdateInput: Equatable, Sendable {
    public var agentID: AgentID
    public var name: String
    public var description: String
    public var category: String

    public init(
        agentID: AgentID,
        name: String,
        description: String,
        category: String
    ) {
        self.agentID = agentID
        self.name = name
        self.description = description
        self.category = category
    }
}

/// The exact provider/model pair a person reviewed before creating a saved
/// agent. This is evidence only: a repository must fetch `/api/models` again
/// immediately before the one-shot create request and validate this pair in
/// that fresh, account-scoped catalog.
public struct BasicAgentModelReview: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// A deliberately small, account-scoped projection of LibreChat's dynamic
/// `/api/models` response. It is not persisted authority and must be freshly
/// fetched for every basic saved-agent creation attempt.
public struct BasicAgentModelCatalog: Codable, Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let modelsByProvider: [String: [String]]

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        modelsByProvider: [String: [String]]
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.modelsByProvider = modelsByProvider
    }

    public func contains(_ review: BasicAgentModelReview) -> Bool {
        modelsByProvider[review.provider]?.contains(review.model) == true
    }
}

/// The only provider parameters native basic-agent creation can author. The
/// wire names and ranges are intentionally explicit so arbitrary provider
/// settings, credentials, and execution features never enter this API.
public struct BasicAgentModelParameters: Codable, Equatable, Hashable, Sendable {
    public let temperature: Double?
    public let topP: Double?
    public let maxTokens: Int?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
    }

    public func validated() throws {
        guard temperature.map({ $0.isFinite && (0 ... 2).contains($0) }) ?? true,
              topP.map({ $0.isFinite && (0 ... 1).contains($0) }) ?? true,
              maxTokens.map({ (1 ... 128_000).contains($0) }) ?? true else {
            throw BasicAgentCreationError.invalidModelParameters
        }
    }
}

/// A bounded native authoring request for a new saved agent. It intentionally
/// has no tools, files, actions, MCP, skills, subagents, edges, avatar, or
/// metadata fields. Implementations must call `validated(in:)` against a
/// freshly fetched model catalog immediately before dispatching its POST.
public struct BasicAgentCreationRequest: Codable, Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let name: String
    public let description: String?
    public let instructions: String?
    public let category: String?
    public let reviewedModel: BasicAgentModelReview
    public let modelParameters: BasicAgentModelParameters?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        name: String,
        description: String? = nil,
        instructions: String? = nil,
        category: String? = nil,
        reviewedModel: BasicAgentModelReview,
        modelParameters: BasicAgentModelParameters? = nil
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.name = name
        self.description = description
        self.instructions = instructions
        self.category = category
        self.reviewedModel = reviewedModel
        self.modelParameters = modelParameters
    }

    /// Returns the exact, normalized data that may be sent after fresh model
    /// review. This fails closed for a different profile/account or a provider
    /// or model no longer returned by the authenticated server.
    public func validated(in catalog: BasicAgentModelCatalog) throws -> Self {
        guard Self.isBoundedIdentifier(profileID.rawValue) else {
            throw BasicAgentCreationError.invalidProfileID
        }
        guard Self.isBoundedIdentifier(accountID.rawValue) else {
            throw BasicAgentCreationError.invalidAccountID
        }
        guard catalog.profileID == profileID, catalog.accountID == accountID else {
            throw BasicAgentCreationError.reviewedScopeMismatch
        }

        let name = try Self.requiredSingleLine(name, maximumUTF16Count: 1_000, error: .invalidName)
        let provider = try Self.requiredSingleLine(
            reviewedModel.provider,
            maximumUTF16Count: 256,
            error: .invalidProvider
        )
        let model = try Self.requiredSingleLine(
            reviewedModel.model,
            maximumUTF16Count: 256,
            error: .invalidModel
        )
        let description = try Self.optionalText(description, maximumUTF16Count: 10_000, error: .invalidDescription)
        let instructions = try Self.optionalText(instructions, maximumUTF16Count: 32_000, error: .invalidInstructions)
        let category = try Self.optionalSingleLine(category, maximumUTF16Count: 200, error: .invalidCategory)
        try modelParameters?.validated()

        let reviewedModel = BasicAgentModelReview(provider: provider, model: model)
        guard catalog.contains(reviewedModel) else {
            throw BasicAgentCreationError.reviewedModelUnavailable
        }
        return Self(
            profileID: profileID,
            accountID: accountID,
            name: name,
            description: description,
            instructions: instructions,
            category: category,
            reviewedModel: reviewedModel,
            modelParameters: modelParameters
        )
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        (1 ... 512).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func requiredSingleLine(
        _ value: String,
        maximumUTF16Count: Int,
        error: BasicAgentCreationError
    ) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf16.count <= maximumUTF16Count,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw error
        }
        return value
    }

    private static func optionalSingleLine(
        _ value: String?,
        maximumUTF16Count: Int,
        error: BasicAgentCreationError
    ) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return try requiredSingleLine(normalized, maximumUTF16Count: maximumUTF16Count, error: error)
    }

    private static func optionalText(
        _ value: String?,
        maximumUTF16Count: Int,
        error: BasicAgentCreationError
    ) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let permittedControls: Set<Unicode.Scalar> = ["\t", "\n", "\r"]
        guard normalized.utf16.count <= maximumUTF16Count,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !permittedControls.contains($0)
              }) else {
            throw error
        }
        return normalized
    }
}

/// Identity returned after a strictly verified `201 Created` response. This
/// is intentionally smaller than an expanded saved-agent document.
public struct BasicAgentCreationResult: Codable, Equatable, Sendable {
    public let agentID: AgentID
    public let resourceID: AgentResourceID
    public let name: String
    public let provider: String
    public let model: String

    public init(
        agentID: AgentID,
        resourceID: AgentResourceID,
        name: String,
        provider: String,
        model: String
    ) {
        self.agentID = agentID
        self.resourceID = resourceID
        self.name = name
        self.provider = provider
        self.model = model
    }
}

/// The finite ambiguity states for a dispatched, non-idempotent agent POST.
/// Definite HTTP or validation failures must be thrown instead.
public enum BasicAgentCreationUncertainty: Codable, Equatable, Sendable {
    case responseLostAfterDispatch
    case reconciliationUnavailable
}

/// A repository returns `outcomeUnknown` only after a dispatched POST could
/// not be reconciled. Callers must refresh the agent directory before offering
/// another create action; they must never blindly repeat the POST.
public enum BasicAgentCreationOutcome: Codable, Equatable, Sendable {
    case confirmed(BasicAgentCreationResult)
    case outcomeUnknown(BasicAgentCreationUncertainty)
}

public enum BasicAgentCreationError: LocalizedError, Equatable, Sendable {
    case invalidProfileID
    case invalidAccountID
    case invalidName
    case invalidProvider
    case invalidModel
    case invalidDescription
    case invalidInstructions
    case invalidCategory
    case invalidModelParameters
    case reviewedScopeMismatch
    case reviewedModelUnavailable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidProfileID, .invalidAccountID, .reviewedScopeMismatch:
            "This agent request no longer belongs to the active account."
        case .invalidName:
            "Enter an agent name between 1 and 1,000 characters."
        case .invalidProvider, .invalidModel, .reviewedModelUnavailable:
            "That model changed. Review it again before creating the agent."
        case .invalidDescription:
            "Keep the agent description under 10,000 characters."
        case .invalidInstructions:
            "Keep the agent instructions under 32,000 characters."
        case .invalidCategory:
            "Keep the agent category under 200 characters."
        case .invalidModelParameters:
            "The selected model parameters are not supported."
        case .invalidResponse:
            "LibreChat did not confirm that this agent was created."
        }
    }
}

/// Stable coordinate for one entry in LibreChat's server-owned saved-agent
/// version array. `serverIndex` is the original array position expected by the
/// revert endpoint; presentation may reverse display order but must never
/// compact or renumber this value.
public struct AgentVersionCoordinate: Codable, Equatable, Hashable, Sendable {
    public let agentID: AgentID
    public let serverIndex: Int

    public init(agentID: AgentID, serverIndex: Int) {
        self.agentID = agentID
        self.serverIndex = serverIndex
    }
}

/// Non-sensitive projection of one server-owned saved-agent version. Full
/// version records can contain instructions, tools, actions, files, and model
/// parameters; none of those values cross this domain boundary.
public struct AgentVersionSummary: Codable, Equatable, Identifiable, Sendable {
    public let coordinate: AgentVersionCoordinate
    public var name: String?
    public var description: String?
    public var category: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        coordinate: AgentVersionCoordinate,
        name: String? = nil,
        description: String? = nil,
        category: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.coordinate = coordinate
        self.name = name
        self.description = description
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var id: AgentVersionCoordinate { coordinate }
    public var isRestorable: Bool { name != nil }
}

/// Live-only safe version history. This type is Codable for protocol isolation
/// and fixtures; production repositories do not persist these snapshots.
public struct AgentVersionHistory: Codable, Equatable, Sendable {
    public let agentID: AgentID
    public var versions: [AgentVersionSummary]
    public var fetchedAt: Date

    public init(
        agentID: AgentID,
        versions: [AgentVersionSummary],
        fetchedAt: Date = Date()
    ) {
        self.agentID = agentID
        self.versions = versions
        self.fetchedAt = fetchedAt
    }
}

/// Effective ACL bits for one exact saved agent. These are fetched live from
/// LibreChat and are never inferred from the directory's `isEditable` flag.
public struct AgentResourcePermissions: Codable, Equatable, Sendable {
    public var canView: Bool
    public var canEdit: Bool
    public var canDelete: Bool
    public var canShare: Bool

    public init(
        canView: Bool = false,
        canEdit: Bool = false,
        canDelete: Bool = false,
        canShare: Bool = false
    ) {
        self.canView = canView
        self.canEdit = canEdit
        self.canDelete = canDelete
        self.canShare = canShare
    }
}

public enum AgentManagementError: LocalizedError, Equatable, Sendable {
    case unavailable
    case insufficientPermission
    case invalidInput(String)
    case invalidResponse
    case deletionNotApplied
    case outcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Agent management is unavailable for this account."
        case .insufficientPermission:
            "This account does not have permission to perform that agent action."
        case let .invalidInput(message):
            message
        case .invalidResponse:
            "LibreChat returned agent data that could not be verified."
        case .deletionNotApplied:
            "LibreChat confirmed that this agent still exists. You can try deleting it again."
        case .outcomeUnknown:
            "LibreChat may have applied this change. Refresh before trying again."
        }
    }
}
