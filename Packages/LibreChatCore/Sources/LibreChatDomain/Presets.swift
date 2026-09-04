import Foundation

/// One private, server-owned LibreChat preset reduced to the settings the
/// native client can reason about safely.
///
/// `unsupportedSettings` is intentionally retained. A preset with any such
/// setting remains browsable, but it must not be applied by dropping fields or
/// guessing provider defaults.
public struct ChatPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: PresetID
    public var title: String
    public var isDefault: Bool
    public var order: Double?
    public var modelLabel: String?
    public var target: ConversationTarget?
    public var unsupportedSettings: [String]

    public init(
        id: PresetID,
        title: String,
        isDefault: Bool = false,
        order: Double? = nil,
        modelLabel: String? = nil,
        target: ConversationTarget? = nil,
        unsupportedSettings: [String] = []
    ) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
        self.order = order
        self.modelLabel = modelLabel
        self.target = target
        self.unsupportedSettings = unsupportedSettings
    }

    public var isNativelyRepresentable: Bool {
        target != nil && unsupportedSettings.isEmpty
    }
}

public enum PresetLibraryWarning: Codable, Equatable, Hashable, Sendable {
    case invalidPresetCount(Int)
    case duplicatePresetID(PresetID)
}

/// A live, account-scoped preset result. The app deliberately does not cache
/// this snapshot because prompt prefixes and provider settings may be private
/// and independently revocable on the server.
public struct PresetLibrarySnapshot: Codable, Equatable, Sendable {
    public var profileID: ServerProfileID
    public var accountID: AccountID
    public var fetchedAt: Date
    public var presets: [ChatPreset]
    public var warnings: [PresetLibraryWarning]

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        fetchedAt: Date = Date(),
        presets: [ChatPreset],
        warnings: [PresetLibraryWarning] = []
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.presets = presets
        self.warnings = warnings
    }
}

/// The execution-routing coordinates reviewed by a user before creating a
/// preset. This deliberately excludes mutable conversation state and
/// ephemeral agent configuration: a saved preset must be usable for a fresh
/// conversation without inheriting a prior branch or unreviewed tool policy.
public struct PresetTargetFingerprint: Codable, Equatable, Hashable, Sendable {
    public let endpoint: String
    public let endpointType: String?
    public let model: String?
    public let agentID: String?
    public let assistantID: String?
    public let spec: String?

    public init(target: ConversationTarget) throws {
        guard target.parentMessageID == nil,
              target.ephemeralAgent == nil else {
            throw PresetCreationError.unsupportedTargetState
        }
        self.endpoint = target.endpoint
        self.endpointType = target.endpointType
        self.model = target.model
        self.agentID = target.agentID
        self.assistantID = target.assistantID
        self.spec = target.spec
    }

    public init(
        endpoint: String,
        endpointType: String? = nil,
        model: String? = nil,
        agentID: String? = nil,
        assistantID: String? = nil,
        spec: String? = nil
    ) {
        self.endpoint = endpoint
        self.endpointType = endpointType
        self.model = model
        self.agentID = agentID
        self.assistantID = assistantID
        self.spec = spec
    }

    public func target(promptPrefix: String?) -> ConversationTarget {
        ConversationTarget(
            endpoint: endpoint,
            endpointType: endpointType,
            model: model,
            agentID: agentID,
            assistantID: assistantID,
            spec: spec,
            promptPrefix: promptPrefix
        )
    }
}

/// Evidence that a selected target option was reviewed for this account.
///
/// The option's presentation fields are intentionally not fingerprinted.
/// Before a repository sends this mutation it must obtain a fresh target
/// catalog and compare this exact option ID and fingerprint.
public struct PresetTargetReview: Codable, Equatable, Hashable, Sendable {
    public let optionID: String
    public let fingerprint: PresetTargetFingerprint

    public init(optionID: String, fingerprint: PresetTargetFingerprint) {
        self.optionID = optionID
        self.fingerprint = fingerprint
    }

    public init(option: ChatTargetOption) throws {
        self.init(
            optionID: option.id,
            fingerprint: try PresetTargetFingerprint(target: option.target)
        )
    }
}

/// A caller-generated, account-scoped request to create one native-safe
/// preset. The request itself is not authority: implementations must validate
/// it against a newly fetched `TargetCatalogSnapshot` immediately before POST.
public struct PresetCreationRequest: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let presetID: PresetID
    public let title: String
    public let reviewedTarget: PresetTargetReview
    public let promptPrefix: String?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        presetID: PresetID,
        title: String,
        reviewedTarget: PresetTargetReview,
        promptPrefix: String? = nil
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.presetID = presetID
        self.title = title
        self.reviewedTarget = reviewedTarget
        self.promptPrefix = promptPrefix
    }

    /// Fails closed if the account/profile changed or the freshly authorized
    /// option no longer has the exact execution routing the user reviewed.
    public func validatedTarget(in catalog: TargetCatalogSnapshot) throws -> ConversationTarget {
        guard catalog.profileID == profileID, catalog.accountID == accountID else {
            throw PresetCreationError.reviewedScopeMismatch
        }
        guard let option = catalog.options.first(where: { $0.id == reviewedTarget.optionID }) else {
            throw PresetCreationError.reviewedTargetUnavailable
        }
        guard try PresetTargetFingerprint(target: option.target) == reviewedTarget.fingerprint else {
            throw PresetCreationError.reviewedTargetChanged
        }
        return reviewedTarget.fingerprint.target(promptPrefix: promptPrefix)
    }
}

/// A finite description of a POST that may have reached the server but could
/// not be reconciled before control returned to the caller. It is never used
/// for definite HTTP failures such as a 401 or other 4xx response.
public enum PresetCreationUncertainty: Codable, Equatable, Hashable, Sendable {
    case responseLostAfterDispatch
    case reconciliationUnavailable
}

/// The result of a native preset create operation. A repository only returns
/// `outcomeUnknown` after dispatch has become ambiguous; callers must refresh
/// the owner-scoped preset list before offering another create action.
public enum PresetCreationOutcome: Codable, Equatable, Sendable {
    case confirmed(ChatPreset)
    case outcomeUnknown(PresetCreationUncertainty)
}

/// Validation and revalidation failures for the deliberately small native
/// preset-authoring surface.
public enum PresetCreationError: LocalizedError, Equatable, Sendable {
    case invalidProfileID
    case invalidAccountID
    case invalidPresetID
    case invalidTitle
    case invalidTarget
    case invalidPromptPrefix
    case unsupportedTargetState
    case reviewedScopeMismatch
    case reviewedTargetUnavailable
    case reviewedTargetChanged
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidProfileID, .invalidAccountID:
            "This preset request no longer belongs to the active account."
        case .invalidPresetID:
            "The preset identifier must be a newly generated UUID."
        case .invalidTitle:
            "Enter a preset title of 200 characters or fewer."
        case .invalidTarget, .unsupportedTargetState:
            "Choose a currently supported target for a new conversation."
        case .invalidPromptPrefix:
            "The prompt prefix is not valid for a preset."
        case .reviewedScopeMismatch, .reviewedTargetUnavailable, .reviewedTargetChanged:
            "That target changed. Review it again before saving the preset."
        case .invalidResponse:
            "LibreChat did not confirm that this preset was saved."
        }
    }
}
