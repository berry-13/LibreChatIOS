import Foundation

/// Stable project metadata exposed by the current LibreChat project API.
///
/// Project-owned instructions, files, and sources are intentionally not
/// represented here: they are not part of the pinned server contract.
public struct ChatProject: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ProjectID
    public var name: String
    public var description: String?
    public var conversationCount: Int
    public var lastConversationAt: Date?
    public var lastConversationID: ConversationID?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: ProjectID,
        name: String,
        description: String? = nil,
        conversationCount: Int,
        lastConversationAt: Date? = nil,
        lastConversationID: ConversationID? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.conversationCount = conversationCount
        self.lastConversationAt = lastConversationAt
        self.lastConversationID = lastConversationID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ChatProjectSortBy: String, Codable, CaseIterable, Sendable {
    case name
    case createdAt
    case lastConversationAt
}

public enum ChatProjectSortDirection: String, Codable, CaseIterable, Sendable {
    case ascending = "asc"
    case descending = "desc"
}

/// Pagination and ordering options accepted by `GET /api/projects`.
/// Nil leaves server defaults in effect.
public struct ChatProjectListOptions: Codable, Equatable, Sendable {
    public var cursor: String?
    public var limit: Int?
    public var sortBy: ChatProjectSortBy?
    public var sortDirection: ChatProjectSortDirection?
    public var search: String?

    public init(
        cursor: String? = nil,
        limit: Int? = nil,
        sortBy: ChatProjectSortBy? = nil,
        sortDirection: ChatProjectSortDirection? = nil,
        search: String? = nil
    ) {
        self.cursor = cursor
        self.limit = limit
        self.sortBy = sortBy
        self.sortDirection = sortDirection
        self.search = search
    }
}

public struct ChatProjectPage: Codable, Equatable, Sendable {
    public var projects: [ChatProject]
    public var nextCursor: String?

    public init(projects: [ChatProject], nextCursor: String? = nil) {
        self.projects = projects
        self.nextCursor = nextCursor
    }
}

public struct CreateChatProjectInput: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// A partial project update. A nil field is omitted from the PATCH body.
public struct UpdateChatProjectInput: Codable, Equatable, Sendable {
    public var name: String?
    public var description: String?

    public init(name: String? = nil, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Authoritative response after moving a conversation into, between, or out
/// of a project. Both project IDs are nullable because unassignment is a
/// supported server operation.
public struct ConversationProjectAssignment: Codable, Equatable, Sendable {
    public var conversation: Conversation
    public var previousProjectID: ProjectID?
    public var projectID: ProjectID?

    public init(
        conversation: Conversation,
        previousProjectID: ProjectID?,
        projectID: ProjectID?
    ) {
        self.conversation = conversation
        self.previousProjectID = previousProjectID
        self.projectID = projectID
    }
}

public struct DeleteChatProjectResult: Codable, Equatable, Sendable {
    public var deletedCount: Int
    public var modifiedCount: Int

    public init(deletedCount: Int, modifiedCount: Int) {
        self.deletedCount = deletedCount
        self.modifiedCount = modifiedCount
    }
}

// Short names make the domain pleasant to use without obscuring the server's
// `ChatProject` terminology in the canonical types above.
public typealias ProjectListOptions = ChatProjectListOptions
public typealias ProjectListSortBy = ChatProjectSortBy
public typealias ProjectListSortDirection = ChatProjectSortDirection
public typealias ProjectPage = ChatProjectPage
public typealias ProjectAssignmentResult = ConversationProjectAssignment
