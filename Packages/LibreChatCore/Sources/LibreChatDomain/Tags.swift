import Foundation

/// One user-owned record in LibreChat's conversation-tag (Bookmarks)
/// directory. The conversation's `tags` array remains the source of each
/// association; this record carries directory metadata and the denormalized
/// count.
public struct ConversationTag: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ConversationTagID
    public let ownerID: AccountID
    public var tag: String
    public var description: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var conversationCount: Int
    public var position: Int

    public var name: String {
        get { tag }
        set { tag = newValue }
    }

    public init(
        id: ConversationTagID,
        ownerID: AccountID,
        tag: String,
        description: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        conversationCount: Int,
        position: Int
    ) {
        self.id = id
        self.ownerID = ownerID
        self.tag = tag
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.conversationCount = conversationCount
        self.position = position
    }

    public init(
        id: ConversationTagID,
        ownerID: AccountID,
        name: String,
        description: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        conversationCount: Int,
        position: Int
    ) {
        self.init(
            id: id,
            ownerID: ownerID,
            tag: name,
            description: description,
            createdAt: createdAt,
            updatedAt: updatedAt,
            conversationCount: conversationCount,
            position: position
        )
    }
}

public struct CreateConversationTagInput: Codable, Equatable, Sendable {
    public var tag: String
    public var description: String?
    public var conversationID: ConversationID?
    public var addToConversation: Bool?

    public var name: String {
        get { tag }
        set { tag = newValue }
    }

    public init(
        tag: String,
        description: String? = nil,
        conversationID: ConversationID? = nil,
        addToConversation: Bool? = nil
    ) {
        self.tag = tag
        self.description = description
        self.conversationID = conversationID
        self.addToConversation = addToConversation
    }

    public init(
        name: String,
        description: String? = nil,
        conversationID: ConversationID? = nil,
        addToConversation: Bool? = nil
    ) {
        self.init(
            tag: name,
            description: description,
            conversationID: conversationID,
            addToConversation: addToConversation
        )
    }
}

/// A partial directory update. Nil fields are omitted; an empty description
/// is intentionally representable so callers can clear the description.
public struct UpdateConversationTagInput: Codable, Equatable, Sendable {
    public var tag: String?
    public var description: String?
    public var position: Int?

    public var name: String? {
        get { tag }
        set { tag = newValue }
    }

    public init(tag: String? = nil, description: String? = nil, position: Int? = nil) {
        self.tag = tag
        self.description = description
        self.position = position
    }

    public init(name: String, description: String? = nil, position: Int? = nil) {
        self.init(tag: name, description: description, position: position)
    }
}

public struct ReplaceConversationTagsInput: Codable, Equatable, Sendable {
    public var tags: [String]

    public init(tags: [String]) {
        self.tags = tags
    }
}

public typealias ConversationTagReplacementInput = ReplaceConversationTagsInput
