import Foundation

/// An endpoint name advertised by the authenticated LibreChat endpoint catalog.
///
/// The value is server-owned and deliberately distinct from a model or target
/// identifier. Only bounded route-safe names may become credential resources.
public struct UserKeyEndpointID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isSafePathComponent: Bool {
        guard (1...128).contains(rawValue.utf8.count) else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: true
            case 45, 46, 58, 95: true // - . : _
            default: false
            }
        }
    }
}

/// Non-secret evidence returned by `GET /api/keys?name=...`.
public enum UserKeyAvailability: Codable, Equatable, Sendable {
    case missing
    case stored(expiresAt: Date?)
    case expired(at: Date)
    case unavailable

    public var isUsable: Bool {
        if case .stored = self { return true }
        return false
    }
}

public struct UserKeyBedrockRequirements: Codable, Equatable, Sendable {
    public var accessKeyID: Bool
    public var secretAccessKey: Bool
    public var sessionToken: Bool
    public var bearerToken: Bool

    public init(
        accessKeyID: Bool,
        secretAccessKey: Bool,
        sessionToken: Bool,
        bearerToken: Bool
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.bearerToken = bearerToken
    }
}

/// The exact native form compatible with the endpoint's server credential envelope.
public enum UserKeyCredentialForm: Codable, Equatable, Sendable {
    case simple
    case openAI(allowsBaseURL: Bool)
    case azureOpenAI
    case google
    case bedrock(UserKeyBedrockRequirements)
}

public struct UserKeyRequirement: Identifiable, Codable, Equatable, Sendable {
    public var id: UserKeyEndpointID
    public var displayName: String
    public var form: UserKeyCredentialForm
    public var availability: UserKeyAvailability

    public init(
        id: UserKeyEndpointID,
        displayName: String,
        form: UserKeyCredentialForm,
        availability: UserKeyAvailability
    ) {
        self.id = id
        self.displayName = displayName
        self.form = form
        self.availability = availability
    }
}

/// A fresh account-scoped credential catalog. It intentionally contains no secret values.
public struct UserKeyCatalog: Codable, Equatable, Sendable {
    public var profileID: ServerProfileID
    public var accountID: AccountID
    public var fetchedAt: Date
    public var requirements: [UserKeyRequirement]

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        fetchedAt: Date,
        requirements: [UserKeyRequirement]
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.requirements = requirements
    }
}

/// Transient provider secrets accepted by the mutation boundary.
///
/// This type is intentionally not `Codable`: secrets must never enter cache,
/// scene restoration, navigation state, or an observable catalog snapshot.
public enum UserKeyCredentials: Equatable, Sendable {
    case simple(secret: String)
    case openAI(apiKey: String, baseURL: String?)
    case azureOpenAI(
        apiKey: String,
        instanceName: String,
        deploymentName: String,
        apiVersion: String
    )
    case google(apiKey: String?, serviceAccountJSON: String?)
    case bedrock(
        accessKeyID: String?,
        secretAccessKey: String?,
        sessionToken: String?,
        bearerToken: String?
    )
}

public struct UserKeyUpdateInput: Equatable, Sendable {
    public var endpointID: UserKeyEndpointID
    public var credentials: UserKeyCredentials
    public var expiresAt: Date?

    public init(
        endpointID: UserKeyEndpointID,
        credentials: UserKeyCredentials,
        expiresAt: Date?
    ) {
        self.endpointID = endpointID
        self.credentials = credentials
        self.expiresAt = expiresAt
    }
}

public enum UserKeyExpirationPreset: String, CaseIterable, Codable, Equatable, Sendable {
    case thirtyMinutes
    case twoHours
    case twelveHours
    case oneDay
    case sevenDays
    case thirtyDays
    case never

    public func expirationDate(relativeTo now: Date) -> Date? {
        let interval: TimeInterval? = switch self {
        case .thirtyMinutes: 30 * 60
        case .twoHours: 2 * 60 * 60
        case .twelveHours: 12 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        case .never: nil
        }
        return interval.map { now.addingTimeInterval($0) }
    }
}

public enum UserKeyMutationResult: Equatable, Sendable {
    case confirmed(UserKeyAvailability)
    /// The mutation may have reached the server but no safe proof is available.
    /// A caller must refresh status and must never replay the secret automatically.
    case deliveryUncertain
}

public enum UserKeyError: LocalizedError, Equatable, Sendable {
    case endpointUnavailable
    case incompatibleCredentialForm
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .endpointUnavailable:
            "This provider no longer accepts account credentials. Refresh and try again."
        case .incompatibleCredentialForm:
            "Those credentials do not match the provider's current configuration."
        case let .invalidInput(message):
            message
        }
    }
}
