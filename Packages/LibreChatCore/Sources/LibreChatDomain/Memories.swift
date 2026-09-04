import Foundation

/// The stable identity of one server-owned memory. Keys are unique only
/// inside a memory partition, so the optional agent coordinate is part of the
/// identity everywhere in the native client.
public struct UserMemoryID: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let agentID: AgentID?

    public init(key: String, agentID: AgentID? = nil) {
        self.key = key
        self.agentID = agentID
    }
}

public struct UserMemory: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UserMemoryID
    public var value: String
    public var updatedAt: Date?
    public var tokenCount: Int?
    /// The server returns a display name only when the current user can VIEW
    /// the referenced agent. A missing name must never be replaced with a raw
    /// private resource identifier in presentation.
    public var agentName: String?

    public init(
        key: String,
        value: String,
        agentID: AgentID? = nil,
        agentName: String? = nil,
        updatedAt: Date? = nil,
        tokenCount: Int? = nil
    ) {
        id = UserMemoryID(key: key, agentID: agentID)
        self.value = value
        self.agentName = agentName
        self.updatedAt = updatedAt
        self.tokenCount = tokenCount
    }

    public var key: String { id.key }
    public var agentID: AgentID? { id.agentID }
}

public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var memories: [UserMemory]
    public var totalTokens: Int
    public var tokenLimit: Int?
    public var characterLimit: Int
    public var usagePercentage: Int?
    public var fetchedAt: Date

    public init(
        memories: [UserMemory],
        totalTokens: Int,
        tokenLimit: Int?,
        characterLimit: Int = 10_000,
        usagePercentage: Int?,
        fetchedAt: Date = Date()
    ) {
        self.memories = memories
        self.totalTokens = totalTokens
        self.tokenLimit = tokenLimit
        self.characterLimit = characterLimit
        self.usagePercentage = usagePercentage
        self.fetchedAt = fetchedAt
    }
}

public struct MemoryPermissions: Codable, Equatable, Hashable, Sendable {
    public var use: Bool
    public var create: Bool
    public var update: Bool
    public var read: Bool
    public var optOut: Bool

    public init(
        use: Bool = false,
        create: Bool = false,
        update: Bool = false,
        read: Bool = false,
        optOut: Bool = false
    ) {
        self.use = use
        self.create = create
        self.update = update
        self.read = read
        self.optOut = optOut
    }

    public var canRead: Bool { use && read }
    public var canCreate: Bool { use && create }
    public var canUpdate: Bool { use && update }
    /// The pinned DELETE route intentionally checks UPDATE permission.
    public var canDelete: Bool { canUpdate }
    public var canChangePreference: Bool { use && optOut }
}

public struct CreateMemoryInput: Codable, Equatable, Sendable {
    public var key: String
    public var value: String
    public var agentID: AgentID?

    public init(key: String, value: String, agentID: AgentID? = nil) {
        self.key = key
        self.value = value
        self.agentID = agentID
    }
}

public struct UpdateMemoryInput: Codable, Equatable, Sendable {
    public var originalKey: String
    public var key: String
    public var value: String
    public var agentID: AgentID?

    public init(
        originalKey: String,
        key: String,
        value: String,
        agentID: AgentID? = nil
    ) {
        self.originalKey = originalKey
        self.key = key
        self.value = value
        self.agentID = agentID
    }
}

public struct DeleteMemoryInput: Codable, Equatable, Sendable {
    public var key: String
    public var agentID: AgentID?

    public init(key: String, agentID: AgentID? = nil) {
        self.key = key
        self.agentID = agentID
    }
}

public enum MemoryMutationError: LocalizedError, Codable, Equatable, Sendable {
    case invalidKey
    case invalidValue
    case valueTooLong(limit: Int)
    case invalidAgent

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            "Use a memory label between 1 and 1,000 characters."
        case .invalidValue:
            "Enter something for LibreChat to remember."
        case let .valueTooLong(limit):
            "Shorten this memory to \(limit) characters or fewer."
        case .invalidAgent:
            "This memory belongs to an invalid agent partition."
        }
    }
}
