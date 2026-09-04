import Foundation
import LibreChatDomain

public struct LibreChatMemoryDTO: Decodable, Equatable, Sendable {
    public var key: String?
    public var value: String?
    public var updatedAt: String?
    public var tokenCount: Int?
    public var agentID: String?
    public var agentName: String?

    private enum CodingKeys: String, CodingKey {
        case key, value, tokenCount, agentName
        case updatedAt = "updated_at"
        case agentID = "agentId"
    }

    public init(
        key: String? = nil,
        value: String? = nil,
        updatedAt: String? = nil,
        tokenCount: Int? = nil,
        agentID: String? = nil,
        agentName: String? = nil
    ) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.tokenCount = tokenCount
        self.agentID = agentID
        self.agentName = agentName
    }

    public func domainModel() throws -> UserMemory {
        guard let key,
              key.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil,
              key.utf16.count <= 1_000 else {
            throw DTOMapperError.invalidField("memory.key")
        }
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil else {
            throw DTOMapperError.invalidField("memory.value")
        }
        let resolvedAgentID: AgentID?
        if let rawAgentID = agentID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            let candidate = AgentID(rawValue: rawAgentID)
            guard candidate.isSafePathComponent else {
                throw DTOMapperError.invalidField("memory.agentId")
            }
            resolvedAgentID = candidate
        } else {
            resolvedAgentID = nil
        }
        return UserMemory(
            key: key,
            value: value,
            agentID: resolvedAgentID,
            agentName: agentName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            updatedAt: updatedAt.flatMap(Self.date),
            tokenCount: tokenCount.flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct LibreChatMemoriesResponseDTO: Decodable, Equatable, Sendable {
    public var memories: [LibreChatMemoryDTO]
    public var totalTokens: Int?
    public var tokenLimit: Int?
    public var charLimit: Int?
    public var usagePercentage: Int?

    public init(
        memories: [LibreChatMemoryDTO] = [],
        totalTokens: Int? = nil,
        tokenLimit: Int? = nil,
        charLimit: Int? = nil,
        usagePercentage: Int? = nil
    ) {
        self.memories = memories
        self.totalTokens = totalTokens
        self.tokenLimit = tokenLimit
        self.charLimit = charLimit
        self.usagePercentage = usagePercentage
    }

    public func domainModel(fetchedAt: Date = Date()) throws -> MemorySnapshot {
        guard let totalTokens, totalTokens >= 0 else {
            throw DTOMapperError.missingRequiredField("memories.totalTokens")
        }
        if let tokenLimit, tokenLimit <= 0 {
            throw DTOMapperError.invalidField("memories.tokenLimit")
        }
        let characterLimit = charLimit ?? 10_000
        guard characterLimit > 0 else {
            throw DTOMapperError.invalidField("memories.charLimit")
        }
        if let usagePercentage, !(0...100).contains(usagePercentage) {
            throw DTOMapperError.invalidField("memories.usagePercentage")
        }

        var seen = Set<UserMemoryID>()
        let mapped = try memories.compactMap { dto -> UserMemory? in
            let memory = try dto.domainModel()
            return seen.insert(memory.id).inserted ? memory : nil
        }
        return MemorySnapshot(
            memories: mapped,
            totalTokens: totalTokens,
            tokenLimit: tokenLimit,
            characterLimit: characterLimit,
            usagePercentage: usagePercentage,
            fetchedAt: fetchedAt
        )
    }
}

public struct LibreChatMemoryMutationDTO: Decodable, Equatable, Sendable {
    public var created: Bool?
    public var updated: Bool?
    public var memory: LibreChatMemoryDTO?

    public func createdMemory() throws -> UserMemory {
        guard created == true, let memory else { throw LibreChatProtocolError.invalidResponse }
        return try memory.domainModel()
    }

    public func updatedMemory() throws -> UserMemory {
        guard updated == true, let memory else { throw LibreChatProtocolError.invalidResponse }
        return try memory.domainModel()
    }
}

public struct LibreChatMemoryDeleteDTO: Decodable, Equatable, Sendable {
    public var deleted: Bool?
}

public struct LibreChatMemoryPreferenceDTO: Decodable, Equatable, Sendable {
    public struct Preferences: Decodable, Equatable, Sendable {
        public var memories: Bool?
    }

    public var updated: Bool?
    public var preferences: Preferences?

    public func enabledValue() throws -> Bool {
        guard updated == true, let enabled = preferences?.memories else {
            throw LibreChatProtocolError.invalidResponse
        }
        return enabled
    }
}

private struct CreateMemoryRequestDTO: Encodable, Sendable {
    let key: String
    let value: String
    let agentID: String?

    private enum CodingKeys: String, CodingKey {
        case key, value
        case agentID = "agentId"
    }
}

private struct UpdateMemoryRequestDTO: Encodable, Sendable {
    let key: String
    let value: String
}

private struct MemoryPreferenceRequestDTO: Encodable, Sendable {
    let memories: Bool
}

public enum LibreChatMemoriesAPI {
    public static func list() -> APIRequest<LibreChatMemoriesResponseDTO> {
        APIRequest(
            path: "api/memories",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func create(
        _ input: CreateMemoryInput,
        characterLimit: Int
    ) throws -> APIRequest<LibreChatMemoryMutationDTO> {
        let values = try validated(
            key: input.key,
            value: input.value,
            characterLimit: characterLimit,
            agentID: input.agentID
        )
        return try APIRequest(
            method: .post,
            path: "api/memories",
            body: CreateMemoryRequestDTO(
                key: values.key,
                value: values.value,
                agentID: input.agentID?.rawValue
            ),
            retryPolicy: .never
        )
    }

    public static func update(
        _ input: UpdateMemoryInput,
        characterLimit: Int
    ) throws -> APIRequest<LibreChatMemoryMutationDTO> {
        let originalKey = try validatedExistingKey(input.originalKey)
        let values = try validated(
            key: input.key,
            value: input.value,
            characterLimit: characterLimit,
            agentID: input.agentID
        )
        return try APIRequest(
            method: .patch,
            path: "api/memories/\(originalKey)",
            pathComponents: ["api", "memories", originalKey],
            queryItems: agentQuery(input.agentID),
            body: UpdateMemoryRequestDTO(key: values.key, value: values.value),
            retryPolicy: .never
        )
    }

    public static func delete(
        _ input: DeleteMemoryInput
    ) throws -> APIRequest<LibreChatMemoryDeleteDTO> {
        let key = try validatedExistingKey(input.key)
        if let agentID = input.agentID, !agentID.isSafePathComponent {
            throw MemoryMutationError.invalidAgent
        }
        return APIRequest(
            method: .delete,
            path: "api/memories/\(key)",
            pathComponents: ["api", "memories", key],
            queryItems: agentQuery(input.agentID),
            retryPolicy: .never
        )
    }

    public static func setEnabled(
        _ enabled: Bool
    ) throws -> APIRequest<LibreChatMemoryPreferenceDTO> {
        try APIRequest(
            method: .patch,
            path: "api/memories/preferences",
            body: MemoryPreferenceRequestDTO(memories: enabled),
            retryPolicy: .never
        )
    }

    private static func validated(
        key: String,
        value: String,
        characterLimit: Int,
        agentID: AgentID?
    ) throws -> (key: String, value: String) {
        let key = try normalizedNewKey(key)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MemoryMutationError.invalidValue }
        guard value.utf16.count <= characterLimit else {
            throw MemoryMutationError.valueTooLong(limit: characterLimit)
        }
        if let agentID, !agentID.isSafePathComponent {
            throw MemoryMutationError.invalidAgent
        }
        return (key, value)
    }

    private static func normalizedNewKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf16.count <= 1_000 else {
            throw MemoryMutationError.invalidKey
        }
        return key
    }

    /// Existing keys are opaque server coordinates. Validate but never trim
    /// them: older/evolving deployments may already contain whitespace that
    /// is part of the exact PATCH/DELETE identity.
    private static func validatedExistingKey(_ key: String) throws -> String {
        guard key.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty != nil,
              key.utf16.count <= 1_000 else {
            throw MemoryMutationError.invalidKey
        }
        return key
    }

    private static func agentQuery(_ id: AgentID?) -> [URLQueryItem] {
        id.map { [URLQueryItem(name: "agentId", value: $0.rawValue)] } ?? []
    }
}
