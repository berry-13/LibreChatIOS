import Foundation
import LibreChatDomain

/// DTOs and exact request construction for the pinned LibreChat project
/// contract. This surface deliberately covers project metadata and nullable
/// conversation membership only; the backend exposes no project-owned files
/// or instructions on these routes.
public struct LibreChatProjectDTO: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var description: String?
    public var conversationCount: Int?
    public var lastConversationAt: String?
    public var lastConversationID: String?
    public var createdAt: String?
    public var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, description, conversationCount, lastConversationAt, createdAt, updatedAt
        case lastConversationID = "lastConversationId"
    }

    public func domainModel() throws -> ChatProject {
        guard let id = id?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("project._id")
        }
        guard let name = name?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("project.name")
        }
        guard let conversationCount else {
            throw DTOMapperError.missingRequiredField("project.conversationCount")
        }

        return ChatProject(
            id: ProjectID(rawValue: id),
            name: name,
            description: description,
            conversationCount: conversationCount,
            lastConversationAt: lastConversationAt.flatMap(Self.date),
            lastConversationID: lastConversationID?.nonEmpty.map(ConversationID.init(rawValue:)),
            createdAt: createdAt.flatMap(Self.date),
            updatedAt: updatedAt.flatMap(Self.date)
        )
    }

    /// LibreChat serializes Mongo dates with `toISOString`, which always
    /// carries fractional seconds (`2026-08-18T10:30:00.123Z`); the plain
    /// form is kept as a fallback. Matches the DTO date parsing idiom.
    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct LibreChatProjectPageDTO: Decodable, Equatable, Sendable {
    public var projects: [LibreChatProjectDTO]
    public var nextCursor: String?

    public init(projects: [LibreChatProjectDTO], nextCursor: String? = nil) {
        self.projects = projects
        self.nextCursor = nextCursor
    }

    public func domainModel() throws -> ChatProjectPage {
        ChatProjectPage(projects: try projects.map { try $0.domainModel() }, nextCursor: nextCursor)
    }
}

public struct LibreChatProjectAssignmentDTO: Decodable, Equatable, Sendable {
    public var conversation: LibreChatConversationDTO
    public var previousProjectID: String?
    public var projectID: String?

    private enum CodingKeys: String, CodingKey {
        case conversation
        case previousProjectID = "previousProjectId"
        case projectID = "projectId"
    }

    public func domainModel() throws -> ConversationProjectAssignment {
        ConversationProjectAssignment(
            conversation: try conversation.domainModel(),
            previousProjectID: previousProjectID?.nonEmpty.map(ProjectID.init(rawValue:)),
            projectID: projectID?.nonEmpty.map(ProjectID.init(rawValue:))
        )
    }
}

public struct LibreChatDeleteProjectDTO: Decodable, Equatable, Sendable {
    public var deletedCount: Int
    public var modifiedCount: Int

    public init(deletedCount: Int, modifiedCount: Int) {
        self.deletedCount = deletedCount
        self.modifiedCount = modifiedCount
    }

    public func domainModel() -> DeleteChatProjectResult {
        DeleteChatProjectResult(deletedCount: deletedCount, modifiedCount: modifiedCount)
    }
}

private struct ProjectAssignmentRequestDTO: Encodable, Sendable {
    let projectID: String?

    private enum CodingKeys: String, CodingKey {
        case projectID = "projectId"
    }

    /// `projectId: null` means unassign. `encodeIfPresent` would wrongly omit
    /// this field, changing the meaning of an unassignment request.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
    }
}

/// Exact factories for `/api/projects` and its nullable membership endpoint.
public enum LibreChatProjectsAPI {
    public static func list(
        _ options: ChatProjectListOptions = .init()
    ) -> APIRequest<LibreChatProjectPageDTO> {
        var queryItems: [URLQueryItem] = []
        if let cursor = options.cursor?.nonEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        if let limit = options.limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let sortBy = options.sortBy {
            queryItems.append(URLQueryItem(name: "sortBy", value: sortBy.rawValue))
        }
        if let sortDirection = options.sortDirection {
            queryItems.append(URLQueryItem(name: "sortDirection", value: sortDirection.rawValue))
        }
        if let search = options.search?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }
        return APIRequest(
            path: "api/projects",
            queryItems: queryItems,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func create(
        _ input: CreateChatProjectInput
    ) throws -> APIRequest<LibreChatProjectDTO> {
        // Creation is non-idempotent: an internal replay after a lost
        // response would create a duplicate project even though the caller
        // holds an outcome-unknown lock against user-driven retries.
        try APIRequest(method: .post, path: "api/projects", body: input, retryPolicy: .never)
    }

    public static func project(
        id: ProjectID
    ) -> APIRequest<LibreChatProjectDTO> {
        APIRequest(path: projectPath(id))
    }

    public static func update(
        id: ProjectID,
        input: UpdateChatProjectInput
    ) throws -> APIRequest<LibreChatProjectDTO> {
        try APIRequest(method: .patch, path: projectPath(id), body: input)
    }

    public static func delete(
        id: ProjectID
    ) -> APIRequest<LibreChatDeleteProjectDTO> {
        APIRequest(method: .delete, path: projectPath(id), retryPolicy: .never)
    }

    public static func assign(
        conversationID: ConversationID,
        projectID: ProjectID?
    ) throws -> APIRequest<LibreChatProjectAssignmentDTO> {
        try APIRequest(
            method: .put,
            path: "api/projects/conversations/\(conversationID.rawValue)",
            body: ProjectAssignmentRequestDTO(projectID: projectID?.rawValue)
        )
    }

    private static func projectPath(_ id: ProjectID) -> String {
        "api/projects/\(id.rawValue)"
    }
}

// Compatibility aliases for the concise vocabulary used by the domain layer.
public typealias ChatProjectDTO = LibreChatProjectDTO
public typealias ChatProjectPageDTO = LibreChatProjectPageDTO
public typealias ProjectAssignmentDTO = LibreChatProjectAssignmentDTO
