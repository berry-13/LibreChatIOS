import Foundation

/// Finite authorization evidence obtained while discovering saved agents.
public enum AgentTargetDiscoveryStatus: String, Codable, Equatable, Hashable, Sendable {
    case notSupported
    case available
    case permissionDenied
    case unavailable
}

/// Non-sensitive compatibility information produced while building a target catalog.
public enum TargetCatalogWarning: Codable, Equatable, Hashable, Sendable {
    case agentPermissionDenied
    case agentDiscoveryUnavailable
    case unsupportedTargetKind(endpoint: String)
    case userKeyRequired(endpoint: String)
    case userKeyExpired(endpoint: String)
    case userKeyStatusUnavailable(endpoint: String)
    case invalidModelSpec(name: String?)
}

/// One authenticated, account-scoped view of the targets the server currently authorizes.
public struct TargetCatalogSnapshot: Codable, Equatable, Sendable {
    public var profileID: ServerProfileID
    public var accountID: AccountID
    public var fetchedAt: Date
    public var options: [ChatTargetOption]
    public var effectiveDefaultOptionID: String?
    public var agentDiscoveryStatus: AgentTargetDiscoveryStatus
    public var warnings: [TargetCatalogWarning]

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        fetchedAt: Date,
        options: [ChatTargetOption],
        effectiveDefaultOptionID: String? = nil,
        agentDiscoveryStatus: AgentTargetDiscoveryStatus,
        warnings: [TargetCatalogWarning] = []
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.options = options
        self.effectiveDefaultOptionID = effectiveDefaultOptionID
        self.agentDiscoveryStatus = agentDiscoveryStatus
        self.warnings = warnings
    }

    public var effectiveDefaultOption: ChatTargetOption? {
        guard let effectiveDefaultOptionID else { return nil }
        return options.first { $0.id == effectiveDefaultOptionID }
    }
}
