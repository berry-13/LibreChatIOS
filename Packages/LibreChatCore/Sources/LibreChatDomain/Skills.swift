import Foundation

/// Authenticated current-role permission evidence for LibreChat Skills.
/// Resource ACLs and target scope remain authoritative for every row.
public struct SkillPermissions: Codable, Equatable, Hashable, Sendable {
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
}

public enum ChatSkillSource: String, Codable, Equatable, Hashable, Sendable {
    case inline
    case deployment
    case github
    case notion
    case unknown
}

/// Why an ACL-visible skill cannot be manually invoked for the reviewed
/// target. Keeping unavailable rows visible explains server policy instead of
/// making a disappearing catalog look like a loading failure.
public enum SkillInvocationAvailability: String, Codable, Equatable, Hashable, Sendable {
    case available
    case inactive
    case modelOnly
    case excludedByTarget
    case targetDisabled
    case ambiguousName

    public var isSelectable: Bool { self == .available }

    public var explanation: String? {
        switch self {
        case .available:
            nil
        case .inactive:
            "Inactive for this account"
        case .modelOnly:
            "Available only when the model invokes it"
        case .excludedByTarget:
            "Not enabled for this model or agent"
        case .targetDisabled:
            "Skills are disabled for this model or agent"
        case .ambiguousName:
            "The server returned more than one invocable skill with this name"
        }
    }
}

/// View-safe metadata from the ACL-filtered Skills directory. Skill bodies,
/// frontmatter, author identifiers, source credentials, and bundled-file
/// locations deliberately stay below the repository boundary.
public struct ChatSkillSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: SkillID
    public let name: String
    public var displayTitle: String
    public var description: String
    public var category: String?
    public var source: ChatSkillSource
    public var version: Int
    public var fileCount: Int
    public var alwaysApply: Bool
    public var isPublic: Bool
    public var availability: SkillInvocationAvailability

    public init(
        id: SkillID,
        name: String,
        displayTitle: String,
        description: String,
        category: String? = nil,
        source: ChatSkillSource,
        version: Int,
        fileCount: Int,
        alwaysApply: Bool = false,
        isPublic: Bool = false,
        availability: SkillInvocationAvailability
    ) {
        self.id = id
        self.name = name
        self.displayTitle = displayTitle
        self.description = description
        self.category = category
        self.source = source
        self.version = version
        self.fileCount = fileCount
        self.alwaysApply = alwaysApply
        self.isPublic = isPublic
        self.availability = availability
    }
}

/// The model-spec-owned skill scope for an ephemeral target. A nil scope on
/// `EphemeralAgentConfiguration` means no model-spec field was advertised and
/// a manual selection may opt the turn into the full accessible catalog.
public enum EphemeralSkillScope: Codable, Equatable, Hashable, Sendable {
    case disabled
    case all
    case names([String])
}

/// The VIEW-filtered scope returned for one persisted saved agent.
public enum SavedAgentSkillScope: Codable, Equatable, Hashable, Sendable {
    case disabled
    case all
    case identifiers([SkillID])
}

/// Fresh, account- and target-scoped selection evidence. This is deliberately
/// live-only: role, ACL, per-user active state, saved-agent scope, and model
/// specs can all change independently of cached conversation history.
public struct SkillInvocationCatalog: Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let target: ConversationTarget
    public let skills: [ChatSkillSummary]
    public let fetchedAt: Date
    public let isComplete: Bool

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        target: ConversationTarget,
        skills: [ChatSkillSummary],
        fetchedAt: Date = Date(),
        isComplete: Bool = true
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.target = target
        self.skills = skills
        self.fetchedAt = fetchedAt
        self.isComplete = isComplete
    }

    /// Returns caller order after proving every unique exact name is still
    /// selectable. LibreChat truncates after ten names; native fails closed
    /// instead of making a visible eleventh choice silently disappear.
    public func validatedSelection(_ names: [String]) throws -> [String] {
        guard names.count <= 10 else { throw SkillInvocationError.tooManySelected }
        var seen = Set<String>()
        let byName = Dictionary(grouping: skills, by: \.name)
        return try names.map { name in
            guard Self.isValidName(name), seen.insert(name).inserted else {
                throw SkillInvocationError.invalidSelection
            }
            guard let matches = byName[name], matches.count == 1,
                  matches[0].availability == .available else {
                throw SkillInvocationError.selectionUnavailable(name)
            }
            return name
        }
    }

    public static func isValidName(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count),
              let first = value.utf8.first,
              Self.isLowercaseLetterOrDigit(first) else { return false }
        return value.utf8.allSatisfy {
            Self.isLowercaseLetterOrDigit($0) || $0 == 45
        }
    }

    private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }
}

public enum SkillInvocationError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidCatalog
    case invalidSelection
    case tooManySelected
    case selectionUnavailable(String)
    case targetChanged

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Skills are unavailable for this account or model."
        case .invalidCatalog:
            "LibreChat returned a Skills catalog that could not be verified."
        case .invalidSelection:
            "The selected Skills request is invalid."
        case .tooManySelected:
            "Choose no more than 10 Skills for one message."
        case let .selectionUnavailable(name):
            "“\(name)” is no longer available for this model or account. Review your Skills before sending."
        case .targetChanged:
            "The model or agent changed. Review your Skills again before sending."
        }
    }
}

/// Why an account Skill currently resolves active or inactive when no target
/// has been selected. An explicit override is distinct from a server default
/// so the UI never implies that a deployment- or owner-level default was a
/// choice already made on this device.
public enum AccountSkillActivationBasis: String, Codable, Equatable, Hashable, Sendable {
    case explicitOverride
    case deploymentDefault
    case ownerDefault
    case sharedDefault
    case inactiveDefault

    public var displayName: String {
        switch self {
        case .explicitOverride: "Account preference"
        case .deploymentDefault: "Deployment default"
        case .ownerDefault: "Owned Skill default"
        case .sharedDefault: "Shared Skill default"
        case .inactiveDefault: "Inactive by default"
        }
    }
}

/// Live-only, account-scoped Skill metadata for the native Settings surface.
/// Skill bodies, file paths, source credentials, and author identifiers never
/// cross this boundary.
public struct AccountSkillSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: SkillID
    public let name: String
    public var displayTitle: String
    public var description: String
    public var category: String?
    public var source: ChatSkillSource
    public var version: Int
    public var fileCount: Int
    public var alwaysApply: Bool
    public var isPublic: Bool
    public var isActive: Bool
    public var activationBasis: AccountSkillActivationBasis
    public var isUserInvocable: Bool
    public var canChangeActivation: Bool

    public init(
        id: SkillID,
        name: String,
        displayTitle: String,
        description: String,
        category: String? = nil,
        source: ChatSkillSource,
        version: Int,
        fileCount: Int,
        alwaysApply: Bool = false,
        isPublic: Bool = false,
        isActive: Bool,
        activationBasis: AccountSkillActivationBasis,
        isUserInvocable: Bool,
        canChangeActivation: Bool
    ) {
        self.id = id
        self.name = name
        self.displayTitle = displayTitle
        self.description = description
        self.category = category
        self.source = source
        self.version = version
        self.fileCount = fileCount
        self.alwaysApply = alwaysApply
        self.isPublic = isPublic
        self.isActive = isActive
        self.activationBasis = activationBasis
        self.isUserInvocable = isUserInvocable
        self.canChangeActivation = canChangeActivation
    }
}

/// A complete, freshly authorized account catalog. Explicit state is retained
/// so one mutation can submit the server's required whole-map replacement
/// without deriving preferences from visible rows or target policy.
public struct AccountSkillCatalog: Codable, Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let skills: [AccountSkillSummary]
    public let explicitStates: [SkillID: Bool]
    public let fetchedAt: Date
    public let isComplete: Bool

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        skills: [AccountSkillSummary],
        explicitStates: [SkillID: Bool],
        fetchedAt: Date = Date(),
        isComplete: Bool = true
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.skills = skills
        self.explicitStates = explicitStates
        self.fetchedAt = fetchedAt
        self.isComplete = isComplete
    }

    public func skill(id: SkillID) -> AccountSkillSummary? {
        skills.first { $0.id == id }
    }
}

public struct SkillActivationRequest: Codable, Equatable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let skillID: SkillID
    public let isActive: Bool

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        skillID: SkillID,
        isActive: Bool
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.skillID = skillID
        self.isActive = isActive
    }
}

public enum SkillActivationUncertainty: String, Codable, Equatable, Sendable {
    case responseLostAfterDispatch
    case reconciliationUnavailable
}

/// `notConfirmed` carries the one authoritative reconciliation read and never
/// causes the mutation to be posted again. `outcomeUnknown` means even that
/// bounded read could not establish the current account state.
public enum SkillActivationOutcome: Equatable, Sendable {
    case confirmed(AccountSkillCatalog)
    case notConfirmed(AccountSkillCatalog)
    case outcomeUnknown(SkillActivationUncertainty)
}

public enum SkillManagementError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidCatalog
    case reviewedScopeMismatch
    case skillUnavailable
    case immutableSkillIdentifier
    case mutationInProgress

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Skills are unavailable for this account."
        case .invalidCatalog:
            "LibreChat returned a Skills catalog that could not be verified."
        case .reviewedScopeMismatch:
            "The active LibreChat account changed. Reload Skills before changing this setting."
        case .skillUnavailable:
            "This Skill is no longer available to the active account."
        case .immutableSkillIdentifier:
            "This deployment-managed Skill cannot be changed from the native app."
        case .mutationInProgress:
            "Wait for the current Skill setting to finish saving."
        }
    }
}
