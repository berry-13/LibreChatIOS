import Foundation

public enum AuthenticationMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case email
    case apple
    case discord
    case facebook
    case github
    case google
    case ldap
    case openID
    case saml
}

public enum GenerationProtocolSupport: Codable, Equatable, Sendable {
    case unknown
    case resumable(version: Int)
    case unsupported(advertisedVersion: Int?)

    public var canGenerate: Bool {
        switch self {
        case .unknown, .resumable:
            true
        case .unsupported:
            false
        }
    }
}

/// Authenticated Temporary Chat policy. Interface configuration describes the
/// server's retention behavior, while the current-role bit remains the exact
/// authorization proof used by presentation.
public struct TemporaryChatPolicy: Codable, Equatable, Sendable {
    public var interfaceEnabled: Bool
    public var roleAllowed: Bool?
    public var retentionHours: Int?

    public init(
        interfaceEnabled: Bool,
        roleAllowed: Bool? = nil,
        retentionHours: Int? = nil
    ) {
        self.interfaceEnabled = interfaceEnabled
        self.roleAllowed = roleAllowed
        self.retentionHours = retentionHours
    }

    public var isAvailable: Bool {
        interfaceEnabled && roleAllowed == true
    }
}

public struct ServerCapabilities: Codable, Equatable, Sendable {
    public var generation: GenerationProtocolSupport
    /// `true` only after the current authenticated account successfully
    /// fetched its post-login policy. `false` represents anonymous discovery
    /// or a fail-closed authenticated refresh; `nil` is a legacy cache value.
    public var authenticatedPolicyVerified: Bool?
    public var supportsAgents: Bool
    /// Nil until authenticated current-role discovery has proven saved-agent
    /// access. Individual resource ACLs remain server-authoritative.
    public var agentPermissions: AgentPermissions?
    public var supportsMCP: Bool
    /// Nil until authenticated role discovery has proven MCP access.
    public var mcpPermissions: MCPPermissions?
    public var supportsMemories: Bool
    /// Nil until the authenticated current-role contract has been fetched.
    public var memoryPermissions: MemoryPermissions?
    /// Nil until authenticated role discovery has proven prompt access.
    public var promptPermissions: PromptPermissions?
    /// Nil for legacy cached capability snapshots that predate Skills
    /// discovery; only an explicit authenticated `true` enables presentation.
    public var supportsSkills: Bool?
    /// Nil until authenticated current-role discovery has proven Skills use.
    public var skillPermissions: SkillPermissions?
    public var supportsSpeech: Bool
    /// Nil until authenticated speech configuration has been fetched.
    public var speechCapabilities: SpeechCapabilities?
    public var supportsProjects: Bool
    /// Nil before authenticated interface discovery or after policy failure.
    /// LibreChat's loaded interface defaults this feature to enabled, but the
    /// native UI still requires current authenticated evidence.
    public var supportsPresets: Bool?
    /// Nil before authenticated interface discovery or after that policy has
    /// failed closed. `roleAllowed == nil` means the current role was not
    /// verified, so Temporary Chat must remain unavailable.
    public var temporaryChatPolicy: TemporaryChatPolicy?
    /// Nil means current-user role permission discovery has not completed.
    public var supportsBookmarks: Bool?
    /// Nil means this capability was captured before authenticated startup
    /// configuration exposed the shared-link flags.
    public var supportsSharedLinks: Bool?
    public var supportsPublicSharedLinks: Bool?
    public var supportsSharedLinkFileSnapshots: Bool?
    /// Nil means authenticated account-deletion policy was not verified.
    public var supportsAccountDeletion: Bool?
    public var supportsTwoFactorAuth: Bool
    public var supportsMobileAuthentication: Bool
    public var authenticationMethods: Set<AuthenticationMethod>
    public var preLogin: PreLoginCapabilities?
    public var publicLegal: PublicLegalConfiguration?
    public var detectedAt: Date
    public var buildIdentifier: String?

    public init(
        generation: GenerationProtocolSupport = .unknown,
        authenticatedPolicyVerified: Bool? = nil,
        supportsAgents: Bool = false,
        agentPermissions: AgentPermissions? = nil,
        supportsMCP: Bool = false,
        mcpPermissions: MCPPermissions? = nil,
        supportsMemories: Bool = false,
        memoryPermissions: MemoryPermissions? = nil,
        promptPermissions: PromptPermissions? = nil,
        supportsSkills: Bool? = nil,
        skillPermissions: SkillPermissions? = nil,
        supportsSpeech: Bool = false,
        speechCapabilities: SpeechCapabilities? = nil,
        supportsProjects: Bool = false,
        supportsPresets: Bool? = nil,
        temporaryChatPolicy: TemporaryChatPolicy? = nil,
        supportsBookmarks: Bool? = nil,
        supportsSharedLinks: Bool? = nil,
        supportsPublicSharedLinks: Bool? = nil,
        supportsSharedLinkFileSnapshots: Bool? = nil,
        supportsAccountDeletion: Bool? = nil,
        supportsTwoFactorAuth: Bool = false,
        supportsMobileAuthentication: Bool = false,
        authenticationMethods: Set<AuthenticationMethod> = [],
        preLogin: PreLoginCapabilities? = nil,
        publicLegal: PublicLegalConfiguration? = nil,
        detectedAt: Date = Date(),
        buildIdentifier: String? = nil
    ) {
        self.generation = generation
        self.authenticatedPolicyVerified = authenticatedPolicyVerified
        self.supportsAgents = supportsAgents
        self.agentPermissions = agentPermissions
        self.supportsMCP = supportsMCP
        self.mcpPermissions = mcpPermissions
        self.supportsMemories = supportsMemories
        self.memoryPermissions = memoryPermissions
        self.promptPermissions = promptPermissions
        self.supportsSkills = supportsSkills
        self.skillPermissions = skillPermissions
        self.supportsSpeech = supportsSpeech
        self.speechCapabilities = speechCapabilities
        self.supportsProjects = supportsProjects
        self.supportsPresets = supportsPresets
        self.temporaryChatPolicy = temporaryChatPolicy
        self.supportsBookmarks = supportsBookmarks
        self.supportsSharedLinks = supportsSharedLinks
        self.supportsPublicSharedLinks = supportsPublicSharedLinks
        self.supportsSharedLinkFileSnapshots = supportsSharedLinkFileSnapshots
        self.supportsAccountDeletion = supportsAccountDeletion
        self.supportsTwoFactorAuth = supportsTwoFactorAuth
        self.supportsMobileAuthentication = supportsMobileAuthentication
        self.authenticationMethods = authenticationMethods
        self.preLogin = preLogin
        self.publicLegal = publicLegal
        self.detectedAt = detectedAt
        self.buildIdentifier = buildIdentifier
    }

    /// Removes every feature claim that requires post-login policy or role
    /// evidence while preserving pre-login, build, and negotiated generation
    /// information. This prevents a failed authenticated refresh from leaving
    /// anonymous or cached feature flags visible as current authorization.
    public func failingClosedAuthenticatedPolicy(at date: Date = Date()) -> Self {
        var result = self
        result.authenticatedPolicyVerified = false
        result.supportsAgents = false
        result.agentPermissions = nil
        result.supportsMCP = false
        result.mcpPermissions = nil
        result.supportsMemories = false
        result.memoryPermissions = nil
        result.promptPermissions = nil
        result.supportsSkills = false
        result.skillPermissions = nil
        result.supportsSpeech = false
        result.speechCapabilities = nil
        result.supportsProjects = false
        result.supportsPresets = nil
        result.temporaryChatPolicy = nil
        result.supportsBookmarks = nil
        result.supportsSharedLinks = nil
        result.supportsPublicSharedLinks = nil
        result.supportsSharedLinkFileSnapshots = nil
        result.supportsAccountDeletion = nil
        result.detectedAt = date
        return result
    }
}

public enum CompatibilityWarning: Codable, Equatable, Identifiable, Sendable {
    case resumableGenerationRequired
    case unknownServerBuild(String)
    case unsupportedGenerationProtocol(Int?)
    case featureUnavailable(String)

    public var id: String {
        switch self {
        case .resumableGenerationRequired:
            "resumable-generation-required"
        case let .unknownServerBuild(build):
            "unknown-build-\(build)"
        case let .unsupportedGenerationProtocol(version):
            "unsupported-generation-\(version.map(String.init) ?? "unknown")"
        case let .featureUnavailable(feature):
            "feature-unavailable-\(feature)"
        }
    }

    public var message: String {
        switch self {
        case .resumableGenerationRequired:
            "This server can be browsed, but sending requires resumable generation protocol v2."
        case let .unknownServerBuild(build):
            "Server build \(build) is outside the tested compatibility matrix."
        case let .unsupportedGenerationProtocol(version):
            "Generation protocol \(version.map(String.init) ?? "unknown") is not supported."
        case let .featureUnavailable(feature):
            "\(feature) is not available on this server."
        }
    }
}

public struct CompatibilityResult: Codable, Equatable, Sendable {
    public var supported: Bool
    public var warnings: [CompatibilityWarning]
    public var capabilities: ServerCapabilities

    public init(supported: Bool, warnings: [CompatibilityWarning], capabilities: ServerCapabilities) {
        self.supported = supported
        self.warnings = warnings
        self.capabilities = capabilities
    }
}

public enum ServerTrustPolicy: String, Codable, Equatable, Sendable {
    case system
    case localDevelopment
}

public struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: ServerProfileID
    public var baseURL: URL
    public var displayName: String
    public var accountIdentifier: AccountID?
    public var capabilities: ServerCapabilities?
    public var trustPolicy: ServerTrustPolicy

    public init(
        id: ServerProfileID = ServerProfileID(),
        baseURL: URL,
        displayName: String,
        accountIdentifier: AccountID? = nil,
        capabilities: ServerCapabilities? = nil,
        trustPolicy: ServerTrustPolicy = .system
    ) {
        self.id = id
        self.baseURL = baseURL
        self.displayName = displayName
        self.accountIdentifier = accountIdentifier
        self.capabilities = capabilities
        self.trustPolicy = trustPolicy
    }
}
