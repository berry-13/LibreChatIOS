import Foundation
import LibreChatDomain

public struct LibreChatConversationTagDTO: Decodable, Equatable, Sendable {
    public var id: String?
    public var user: String?
    public var tag: String?
    public var description: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var count: Int?
    public var position: Int?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case user, tag, description, createdAt, updatedAt, count, position
    }

    public func domainModel() throws -> ConversationTag {
        guard let id = id?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("conversationTag._id")
        }
        guard let user = user?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("conversationTag.user")
        }
        guard let tag = tag?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("conversationTag.tag")
        }
        guard let createdAt else {
            throw DTOMapperError.missingRequiredField("conversationTag.createdAt")
        }
        guard let createdAtDate = Self.date(createdAt) else {
            throw DTOMapperError.invalidField("conversationTag.createdAt")
        }
        guard let updatedAt else {
            throw DTOMapperError.missingRequiredField("conversationTag.updatedAt")
        }
        guard let updatedAtDate = Self.date(updatedAt) else {
            throw DTOMapperError.invalidField("conversationTag.updatedAt")
        }
        guard let count else {
            throw DTOMapperError.missingRequiredField("conversationTag.count")
        }
        guard let position else {
            throw DTOMapperError.missingRequiredField("conversationTag.position")
        }

        return ConversationTag(
            id: ConversationTagID(rawValue: id),
            ownerID: AccountID(rawValue: user),
            tag: tag,
            description: description,
            createdAt: createdAtDate,
            updatedAt: updatedAtDate,
            conversationCount: count,
            position: position
        )
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// The list route returns a bare JSON array, not an object envelope.
public struct LibreChatConversationTagListDTO: Decodable, Equatable, Sendable {
    public let tags: [LibreChatConversationTagDTO]

    public init(from decoder: Decoder) throws {
        tags = try [LibreChatConversationTagDTO](from: decoder)
    }

    public func domainModels() throws -> [ConversationTag] {
        try tags.map { try $0.domainModel() }
    }
}

public struct LibreChatConversationTagReplacementDTO: Decodable, Equatable, Sendable {
    public let tags: [String]

    public init(from decoder: Decoder) throws {
        let values = try [String](from: decoder)
        var seen = Set<String>()
        tags = values.filter { seen.insert($0).inserted }
    }

    public func domainModel() -> [String] { tags }
}

private struct CreateConversationTagRequestDTO: Encodable, Sendable {
    let tag: String
    let description: String?
    let conversationID: String?
    let addToConversation: Bool?

    private enum CodingKeys: String, CodingKey {
        case tag, description
        case conversationID = "conversationId"
        case addToConversation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag, forKey: .tag)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(addToConversation, forKey: .addToConversation)
    }
}

private struct UpdateConversationTagRequestDTO: Encodable, Sendable {
    let tag: String?
    let description: String?
    let position: Int?

    private enum CodingKeys: String, CodingKey {
        case tag, description, position
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(tag, forKey: .tag)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(position, forKey: .position)
    }
}

private struct ReplaceConversationTagsRequestDTO: Encodable, Sendable {
    let tags: [String]
}

/// Exact request factories for the supported personal conversation-tag
/// directory and association routes. The stale `/list` and `/rebuild`
/// provider routes are intentionally absent.
public enum LibreChatConversationTagsAPI {
    public static func list() -> APIRequest<LibreChatConversationTagListDTO> {
        APIRequest(
            path: "api/tags",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func create(
        _ input: CreateConversationTagInput
    ) throws -> APIRequest<LibreChatConversationTagDTO> {
        try APIRequest(
            method: .post,
            path: "api/tags",
            body: CreateConversationTagRequestDTO(
                tag: input.tag,
                description: input.description,
                conversationID: input.conversationID?.rawValue,
                addToConversation: input.addToConversation
            ),
            retryPolicy: .never
        )
    }

    public static func update(
        named tag: String,
        input: UpdateConversationTagInput
    ) throws -> APIRequest<LibreChatConversationTagDTO> {
        let component = try pathComponent(tag)
        return try APIRequest(
            method: .put,
            path: "api/tags/\(tag)",
            pathComponents: ["api", "tags", component],
            body: UpdateConversationTagRequestDTO(
                tag: input.tag,
                description: input.description,
                position: input.position
            ),
            retryPolicy: .never
        )
    }

    public static func delete(
        named tag: String
    ) throws -> APIRequest<LibreChatConversationTagDTO> {
        let component = try pathComponent(tag)
        return APIRequest(
            method: .delete,
            path: "api/tags/\(tag)",
            pathComponents: ["api", "tags", component],
            retryPolicy: .never
        )
    }

    public static func replace(
        conversationID: ConversationID,
        tags: [String]
    ) throws -> APIRequest<LibreChatConversationTagReplacementDTO> {
        let component = try pathComponent(conversationID.rawValue)
        return try APIRequest(
            method: .put,
            path: "api/tags/convo/\(conversationID.rawValue)",
            pathComponents: ["api", "tags", "convo", component],
            body: ReplaceConversationTagsRequestDTO(tags: tags),
            retryPolicy: .never
        )
    }

    private static func pathComponent(_ value: String) throws -> String {
        guard value.isEmpty == false else {
            throw LibreChatProtocolError.encoding("The conversation-tag path component cannot be empty.")
        }
        return value
    }
}

public typealias LibreChatConversationTagAPI = LibreChatConversationTagsAPI
public typealias ConversationTagDTO = LibreChatConversationTagDTO
public typealias ConversationTagListDTO = LibreChatConversationTagListDTO
public typealias ConversationTagReplacementDTO = LibreChatConversationTagReplacementDTO

