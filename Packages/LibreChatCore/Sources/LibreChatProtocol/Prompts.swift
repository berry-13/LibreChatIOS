import Foundation
import LibreChatDomain

public struct LibreChatPromptProductionDTO: Decodable, Equatable, Sendable {
    public var prompt: String?

    public init(prompt: String? = nil) {
        self.prompt = prompt
    }
}

public struct LibreChatPromptGroupDTO: Decodable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var numberOfGenerations: Int?
    public var command: String?
    public var oneliner: String?
    public var category: String?
    public var productionPrompt: LibreChatPromptProductionDTO?
    public var productionID: String?
    public var authorName: String?
    public var isPublic: Bool?
    public var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, numberOfGenerations, command, oneliner, category
        case productionPrompt, productionID = "productionId", authorName, isPublic, updatedAt
    }

    public init(
        id: String? = nil,
        name: String? = nil,
        numberOfGenerations: Int? = nil,
        command: String? = nil,
        oneliner: String? = nil,
        category: String? = nil,
        productionPrompt: LibreChatPromptProductionDTO? = nil,
        productionID: String? = nil,
        authorName: String? = nil,
        isPublic: Bool? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.numberOfGenerations = numberOfGenerations
        self.command = command
        self.oneliner = oneliner
        self.category = category
        self.productionPrompt = productionPrompt
        self.productionID = productionID
        self.authorName = authorName
        self.isPublic = isPublic
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        numberOfGenerations = try? container.decodeIfPresent(Int.self, forKey: .numberOfGenerations)
        command = try? container.decodeIfPresent(String.self, forKey: .command)
        oneliner = try? container.decodeIfPresent(String.self, forKey: .oneliner)
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        productionPrompt = try? container.decodeIfPresent(LibreChatPromptProductionDTO.self, forKey: .productionPrompt)
        productionID = try? container.decodeIfPresent(String.self, forKey: .productionID)
        authorName = try? container.decodeIfPresent(String.self, forKey: .authorName)
        isPublic = try? container.decodeIfPresent(Bool.self, forKey: .isPublic)
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    public func domainModel() throws -> PromptTemplateGroup {
        guard let rawID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty else {
            throw DTOMapperError.missingRequiredField("promptGroup._id")
        }
        let groupID = PromptGroupID(rawValue: rawID)
        guard groupID.isSafePathComponent else {
            throw DTOMapperError.invalidField("promptGroup._id")
        }
        guard let name = clean(name), name.utf16.count <= 1_000 else {
            throw DTOMapperError.missingRequiredField("promptGroup.name")
        }
        if let numberOfGenerations, numberOfGenerations < 0 {
            throw DTOMapperError.invalidField("promptGroup.numberOfGenerations")
        }
        let productionText: String? = if let raw = productionPrompt?.prompt,
                                         !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw
        } else {
            nil
        }
        if let productionText, productionText.utf16.count > 100_000 {
            throw DTOMapperError.invalidField("promptGroup.productionPrompt.prompt")
        }
        return PromptTemplateGroup(
            id: groupID,
            name: name,
            summary: clean(oneliner),
            command: clean(command),
            category: clean(category),
            productionText: productionText,
            authorName: clean(authorName),
            isPublic: isPublic == true,
            usageCount: numberOfGenerations
        )
    }

    public func managedDomainModel() throws -> ManagedPromptGroup {
        let group = try domainModel()
        guard let rawProductionID = productionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawProductionID.isEmpty else {
            throw DTOMapperError.missingRequiredField("promptGroup.productionId")
        }
        let productionVersionID = PromptVersionID(rawValue: rawProductionID)
        guard productionVersionID.isSafePathComponent else {
            throw DTOMapperError.invalidField("promptGroup.productionId")
        }
        return ManagedPromptGroup(
            id: group.id,
            name: group.name,
            summary: group.summary ?? "",
            category: group.category ?? "",
            command: group.command,
            productionVersionID: productionVersionID,
            updatedAt: updatedAt.flatMap(Self.parseDate)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct LibreChatPromptGroupPageDTO: Decodable, Equatable, Sendable {
    public var promptGroups: [LibreChatPromptGroupDTO]
    public var hasMore: Bool?
    public var after: String?

    private enum CodingKeys: String, CodingKey {
        case promptGroups
        case hasMore = "has_more"
        case after
    }

    public init(
        promptGroups: [LibreChatPromptGroupDTO] = [],
        hasMore: Bool? = nil,
        after: String? = nil
    ) {
        self.promptGroups = promptGroups
        self.hasMore = hasMore
        self.after = after
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        promptGroups = (try? container.decodeIfPresent([LibreChatPromptGroupDTO].self, forKey: .promptGroups)) ?? []
        hasMore = try? container.decodeIfPresent(Bool.self, forKey: .hasMore)
        after = try? container.decodeIfPresent(String.self, forKey: .after)
    }

    public func domainModel() throws -> PromptTemplatePage {
        guard let hasMore else {
            throw DTOMapperError.missingRequiredField("promptGroups.has_more")
        }
        let nextCursor: String?
        if hasMore {
            guard let cursor = after?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cursor.isEmpty, cursor.utf8.count <= 4_096 else {
                throw DTOMapperError.invalidField("promptGroups.after")
            }
            nextCursor = cursor
        } else {
            nextCursor = nil
        }
        var seen = Set<PromptGroupID>()
        let groups = promptGroups.compactMap { dto -> PromptTemplateGroup? in
            guard let group = try? dto.domainModel(), seen.insert(group.id).inserted else { return nil }
            return group
        }
        return PromptTemplatePage(groups: groups, nextCursor: nextCursor)
    }
}

public struct LibreChatPromptUsageDTO: Decodable, Equatable, Sendable {
    public var numberOfGenerations: Int?

    public init(numberOfGenerations: Int? = nil) {
        self.numberOfGenerations = numberOfGenerations
    }

    public func count() throws -> Int {
        guard let numberOfGenerations, numberOfGenerations >= 0 else {
            throw LibreChatProtocolError.invalidResponse
        }
        return numberOfGenerations
    }
}

public struct LibreChatPromptVersionDTO: Decodable, Equatable, Sendable {
    public var id: String?
    public var groupID: String?
    public var prompt: String?
    public var type: String?
    public var createdAt: String?
    public var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case groupID = "groupId"
        case prompt, type, createdAt, updatedAt
    }

    public init(
        id: String? = nil,
        groupID: String? = nil,
        prompt: String? = nil,
        type: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.prompt = prompt
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func domainModel(expectedGroupID: PromptGroupID? = nil) throws -> ManagedPromptVersion {
        guard let rawID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty else {
            throw DTOMapperError.missingRequiredField("prompt._id")
        }
        let versionID = PromptVersionID(rawValue: rawID)
        guard versionID.isSafePathComponent else {
            throw DTOMapperError.invalidField("prompt._id")
        }
        guard let rawGroupID = groupID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawGroupID.isEmpty else {
            throw DTOMapperError.missingRequiredField("prompt.groupId")
        }
        let mappedGroupID = PromptGroupID(rawValue: rawGroupID)
        guard mappedGroupID.isSafePathComponent,
              expectedGroupID == nil || expectedGroupID == mappedGroupID else {
            throw DTOMapperError.invalidField("prompt.groupId")
        }
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf16.count <= 100_000 else {
            throw DTOMapperError.invalidField("prompt.prompt")
        }
        guard let type, let kind = PromptTemplateKind(rawValue: type) else {
            throw DTOMapperError.invalidField("prompt.type")
        }
        return ManagedPromptVersion(
            id: versionID,
            groupID: mappedGroupID,
            text: prompt,
            kind: kind,
            createdAt: createdAt.flatMap(Self.parseDate),
            updatedAt: updatedAt.flatMap(Self.parseDate)
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct LibreChatPromptMutationResponseDTO: Decodable, Equatable, Sendable {
    public var prompt: LibreChatPromptVersionDTO?
    public var group: LibreChatPromptGroupDTO?
    public var message: String?

    public init(
        prompt: LibreChatPromptVersionDTO? = nil,
        group: LibreChatPromptGroupDTO? = nil,
        message: String? = nil
    ) {
        self.prompt = prompt
        self.group = group
        self.message = message
    }
}

private struct PromptVersionInputDTO: Encodable, Sendable {
    var prompt: String
    var type: String
}

private struct PromptGroupCreateDTO: Encodable, Sendable {
    var name: String
    var category: String?
    var oneliner: String?
    var command: String?
}

private struct PromptCreateBodyDTO: Encodable, Sendable {
    var prompt: PromptVersionInputDTO
    var group: PromptGroupCreateDTO
}

private struct PromptAddVersionBodyDTO: Encodable, Sendable {
    var prompt: PromptVersionInputDTO
}

private struct PromptGroupUpdateBodyDTO: Encodable, Sendable {
    var name: String
    var oneliner: String
    var category: String
    var command: String?

    private enum CodingKeys: String, CodingKey {
        case name, oneliner, category, command
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(oneliner, forKey: .oneliner)
        try container.encode(category, forKey: .category)
        if let command {
            try container.encode(command, forKey: .command)
        } else {
            try container.encodeNil(forKey: .command)
        }
    }
}

public enum LibreChatPromptsAPI {
    public static let myPromptsCategory = "sys__my__prompts__sys"

    /// One entry of the server's `/api/categories` directory that backs the
    /// web client's prompt CategorySelector.
    public struct PromptCategoryDTO: Decodable, Equatable, Sendable {
        public var label: String?
        public var value: String

        public init(label: String?, value: String) {
            self.label = label
            self.value = value
        }

        public var displayName: String {
            if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                return label
            }
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public static func categories() -> APIRequest<[PromptCategoryDTO]> {
        APIRequest(
            path: "api/categories",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func groups(
        _ query: PromptTemplateQuery = .init()
    ) throws -> APIRequest<LibreChatPromptGroupPageDTO> {
        guard (1...100).contains(query.limit) else {
            throw LibreChatProtocolError.encoding("Prompt page size must be between 1 and 100.")
        }
        var queryItems = [URLQueryItem(name: "limit", value: String(query.limit))]
        if let search = try normalized(query.search, maximumUTF16: 200, field: "search") {
            queryItems.append(URLQueryItem(name: "name", value: search))
        }
        if let category = try normalized(query.category, maximumUTF16: 200, field: "category") {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }
        if let cursor = try normalized(query.cursor, maximumUTF16: 4_096, field: "cursor") {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return APIRequest(
            path: "api/prompts/groups",
            queryItems: queryItems,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func recordUsage(
        groupID: PromptGroupID
    ) throws -> APIRequest<LibreChatPromptUsageDTO> {
        guard groupID.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("Invalid prompt-group identifier.")
        }
        return APIRequest(
            method: .post,
            path: "api/prompts/groups/\(groupID.rawValue)/use",
            pathComponents: ["api", "prompts", "groups", groupID.rawValue, "use"],
            retryPolicy: .never
        )
    }

    public static func group(
        groupID: PromptGroupID
    ) throws -> APIRequest<LibreChatPromptGroupDTO> {
        try validate(groupID)
        return APIRequest(
            path: "api/prompts/groups/\(groupID.rawValue)",
            pathComponents: ["api", "prompts", "groups", groupID.rawValue],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func versions(
        groupID: PromptGroupID
    ) throws -> APIRequest<[LibreChatPromptVersionDTO]> {
        try validate(groupID)
        return APIRequest(
            path: "api/prompts",
            queryItems: [URLQueryItem(name: "groupId", value: groupID.rawValue)],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func create(
        _ input: CreatePromptGroupInput
    ) throws -> APIRequest<LibreChatPromptMutationResponseDTO> {
        let values = try validated(input)
        return try APIRequest(
            method: .post,
            path: "api/prompts",
            body: PromptCreateBodyDTO(
                prompt: PromptVersionInputDTO(prompt: values.text, type: input.kind.rawValue),
                group: PromptGroupCreateDTO(
                    name: values.name,
                    category: values.category.nilIfEmpty,
                    oneliner: values.summary.nilIfEmpty,
                    command: values.command
                )
            ),
            retryPolicy: .never
        )
    }

    public static func addVersion(
        _ input: AddPromptVersionInput
    ) throws -> APIRequest<LibreChatPromptMutationResponseDTO> {
        try validate(input.groupID)
        let text = try required(input.text, maximumUTF16: 100_000, field: "Prompt text")
        return try APIRequest(
            method: .post,
            path: "api/prompts/groups/\(input.groupID.rawValue)/prompts",
            pathComponents: ["api", "prompts", "groups", input.groupID.rawValue, "prompts"],
            body: PromptAddVersionBodyDTO(
                prompt: PromptVersionInputDTO(prompt: text, type: input.kind.rawValue)
            ),
            retryPolicy: .never
        )
    }

    public static func updateGroup(
        _ input: UpdatePromptGroupInput
    ) throws -> APIRequest<LibreChatPromptGroupDTO> {
        try validate(input.groupID)
        let values = try validated(input)
        return try APIRequest(
            method: .patch,
            path: "api/prompts/groups/\(input.groupID.rawValue)",
            pathComponents: ["api", "prompts", "groups", input.groupID.rawValue],
            body: PromptGroupUpdateBodyDTO(
                name: values.name,
                oneliner: values.summary,
                category: values.category,
                command: values.command
            ),
            retryPolicy: .never
        )
    }

    public static func promote(
        versionID: PromptVersionID
    ) throws -> APIRequest<LibreChatPromptMutationResponseDTO> {
        guard versionID.isSafePathComponent else {
            throw PromptManagementError.invalidInput("The prompt version identifier is invalid.")
        }
        return APIRequest(
            method: .patch,
            path: "api/prompts/\(versionID.rawValue)/tags/production",
            pathComponents: ["api", "prompts", versionID.rawValue, "tags", "production"],
            retryPolicy: .never
        )
    }

    private static func validate(_ groupID: PromptGroupID) throws {
        guard groupID.isSafePathComponent else {
            throw PromptManagementError.invalidInput("The prompt-group identifier is invalid.")
        }
    }

    private static func validated(_ input: CreatePromptGroupInput) throws -> (
        name: String, summary: String, category: String, command: String?, text: String
    ) {
        (
            try required(input.name, maximumUTF16: 255, field: "Template name"),
            try optional(input.summary, maximumUTF16: 500, field: "Template summary") ?? "",
            try optional(input.category, maximumUTF16: 100, field: "Template category") ?? "",
            try command(input.command),
            try required(input.text, maximumUTF16: 100_000, field: "Prompt text")
        )
    }

    private static func validated(_ input: UpdatePromptGroupInput) throws -> (
        name: String, summary: String, category: String, command: String?
    ) {
        (
            try required(input.name, maximumUTF16: 255, field: "Template name"),
            try optional(input.summary, maximumUTF16: 500, field: "Template summary") ?? "",
            try optional(input.category, maximumUTF16: 100, field: "Template category") ?? "",
            try command(input.command)
        )
    }

    private static func required(
        _ value: String,
        maximumUTF16: Int,
        field: String
    ) throws -> String {
        guard let value = try optional(value, maximumUTF16: maximumUTF16, field: field) else {
            throw PromptManagementError.invalidInput("\(field) is required.")
        }
        return value
    }

    private static func optional(
        _ value: String?,
        maximumUTF16: Int,
        field: String
    ) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        guard value.utf16.count <= maximumUTF16 else {
            throw PromptManagementError.invalidInput("\(field) is too long.")
        }
        return value
    }

    private static func command(_ value: String?) throws -> String? {
        guard let value = try optional(value, maximumUTF16: 56, field: "Command") else {
            return nil
        }
        guard value.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw PromptManagementError.invalidInput(
                "Command can contain only lowercase letters, numbers, and hyphens."
            )
        }
        return value
    }

    private static func normalized(
        _ value: String?,
        maximumUTF16: Int,
        field: String
    ) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        guard value.utf16.count <= maximumUTF16 else {
            throw LibreChatProtocolError.encoding("Prompt \(field) is too long.")
        }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
