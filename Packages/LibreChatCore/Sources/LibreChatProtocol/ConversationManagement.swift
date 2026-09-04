import Foundation
import LibreChatDomain

/// Exact `arg` envelope used by LibreChat conversation-management mutations.
public struct ConversationManagementRequestDTO<Argument: Encodable & Sendable>: Encodable, Sendable {
    public let arg: Argument

    public init(arg: Argument) {
        self.arg = arg
    }
}

public struct RenameConversationArgumentDTO: Encodable, Equatable, Sendable {
    public let conversationID: String
    public let title: String

    public init(conversationID: ConversationID, title: String) {
        self.conversationID = conversationID.rawValue
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case title
    }
}

public struct ArchiveConversationArgumentDTO: Encodable, Equatable, Sendable {
    public let conversationID: String
    public let isArchived: Bool

    public init(conversationID: ConversationID, isArchived: Bool) {
        self.conversationID = conversationID.rawValue
        self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case isArchived
    }
}

public struct PinConversationArgumentDTO: Encodable, Equatable, Sendable {
    public let conversationID: String
    public let pinned: Bool

    public init(conversationID: ConversationID, pinned: Bool) {
        self.conversationID = conversationID.rawValue
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case pinned
    }
}

/// Exact factories for the bounded native conversation-management endpoints
/// in LibreChat b2128a7. These mutations are deliberately never retried.
public enum LibreChatConversationManagementAPI {
    public static func rename(
        conversationID: ConversationID,
        title: String
    ) throws -> APIRequest<LibreChatConversationDTO> {
        try APIRequest(
            method: .post,
            path: "api/convos/update",
            body: ConversationManagementRequestDTO(
                arg: RenameConversationArgumentDTO(conversationID: conversationID, title: title)
            ),
            retryPolicy: .never
        )
    }

    public static func archive(
        conversationID: ConversationID,
        isArchived: Bool
    ) throws -> APIRequest<LibreChatConversationDTO> {
        try APIRequest(
            method: .post,
            path: "api/convos/archive",
            body: ConversationManagementRequestDTO(
                arg: ArchiveConversationArgumentDTO(conversationID: conversationID, isArchived: isArchived)
            ),
            retryPolicy: .never
        )
    }

    public static func pin(
        conversationID: ConversationID,
        pinned: Bool
    ) throws -> APIRequest<LibreChatConversationDTO> {
        try APIRequest(
            method: .post,
            path: "api/convos/pin",
            body: ConversationManagementRequestDTO(
                arg: PinConversationArgumentDTO(conversationID: conversationID, pinned: pinned)
            ),
            retryPolicy: .never
        )
    }
}
