import Foundation
import LibreChatDomain

public struct SharedLinkLookupDTO: Decodable, Equatable, Sendable {
    public var resourceID: String?
    public var success: Bool?
    public var shareID: String?
    public var targetMessageID: String?
    public var snapshotFiles: Bool?
    public var conversationID: String?

    private enum CodingKeys: String, CodingKey {
        case resourceID = "_id"
        case success, shareID = "shareId", targetMessageID = "targetMessageId"
        case snapshotFiles, conversationID = "conversationId"
    }

    public func domainModel(requestedConversationID: ConversationID) throws -> SharedLinkState {
        guard let success else {
            throw DTOMapperError.missingRequiredField("sharedLink.success")
        }
        guard success else {
            return SharedLinkState(conversationID: requestedConversationID)
        }
        guard let shareID = shareID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedLink.shareId")
        }
        let sharedLinkID = SharedLinkID(rawValue: shareID)
        guard sharedLinkID.isSafePathComponent else {
            throw DTOMapperError.invalidField("sharedLink.shareId")
        }
        guard let conversationID = conversationID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedLink.conversationId")
        }
        // A stale or foreign lookup payload must never surface another
        // conversation's share URL as if it belonged to the viewed one.
        guard conversationID == requestedConversationID.rawValue else {
            throw DTOMapperError.invalidField("sharedLink.conversationId")
        }

        return SharedLinkState(
            conversationID: ConversationID(rawValue: conversationID),
            link: SharedLink(
                shareID: sharedLinkID,
                resourceID: resourceID?.nonEmpty,
                conversationID: ConversationID(rawValue: conversationID),
                targetMessageID: targetMessageID?.nonEmpty.map(MessageID.init(rawValue:)),
                snapshotFiles: snapshotFiles
            )
        )
    }
}

public struct SharedLinkMutationResponseDTO: Decodable, Equatable, Sendable {
    public var resourceID: String?
    public var shareID: String?
    public var conversationID: String?
    public var targetMessageID: String?

    private enum CodingKeys: String, CodingKey {
        case resourceID = "_id"
        case shareID = "shareId"
        case conversationID = "conversationId"
        case targetMessageID = "targetMessageId"
    }

    public func domainModel() throws -> SharedLinkMutationResult {
        guard let shareID = shareID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedLink.shareId")
        }
        let sharedLinkID = SharedLinkID(rawValue: shareID)
        guard sharedLinkID.isSafePathComponent else {
            throw DTOMapperError.invalidField("sharedLink.shareId")
        }
        guard let conversationID = conversationID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedLink.conversationId")
        }
        return SharedLinkMutationResult(
            shareID: sharedLinkID,
            resourceID: resourceID?.nonEmpty,
            conversationID: ConversationID(rawValue: conversationID),
            targetMessageID: targetMessageID?.nonEmpty.map(MessageID.init(rawValue:))
        )
    }
}

public struct SharedLinkDeletionResponseDTO: Decodable, Equatable, Sendable {
    public var resourceID: String?
    public var success: Bool?
    public var shareID: String?
    public var message: String?

    private enum CodingKeys: String, CodingKey {
        case resourceID = "_id"
        case success, shareID = "shareId", message
    }

    public func domainModel() throws -> SharedLinkDeletionResult {
        guard success == true else {
            throw DTOMapperError.missingRequiredField("sharedLink.success")
        }
        guard let shareID = shareID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedLink.shareId")
        }
        let sharedLinkID = SharedLinkID(rawValue: shareID)
        guard sharedLinkID.isSafePathComponent else {
            throw DTOMapperError.invalidField("sharedLink.shareId")
        }
        guard let message = message?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedLink.message")
        }
        return SharedLinkDeletionResult(
            shareID: sharedLinkID,
            resourceID: resourceID?.nonEmpty,
            message: message
        )
    }
}

public enum LibreChatSharedLinksAPI {
    public static func lookup(
        conversationID: ConversationID
    ) -> APIRequest<SharedLinkLookupDTO> {
        APIRequest(
            path: "api/share/link/\(conversationID.rawValue)",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func create(
        conversationID: ConversationID,
        request: SharedLinkPublishRequest
    ) throws -> APIRequest<SharedLinkMutationResponseDTO> {
        try APIRequest(
            method: .post,
            // The conversation id is server data; the component form is
            // encoded once and rejects dot-only traversal values.
            path: "api/share/\(conversationID.rawValue)",
            pathComponents: ["api", "share", conversationID.rawValue],
            body: request,
            retryPolicy: .never
        )
    }

    public static func update(
        shareID: SharedLinkID,
        request: SharedLinkPublishRequest
    ) throws -> APIRequest<SharedLinkMutationResponseDTO> {
        guard shareID.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")
        }
        return try APIRequest(
            method: .patch,
            path: "api/share/\(shareID.rawValue)",
            body: request,
            retryPolicy: .never
        )
    }

    public static func delete(
        shareID: SharedLinkID
    ) throws -> APIRequest<SharedLinkDeletionResponseDTO> {
        guard shareID.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")
        }
        return APIRequest(
            method: .delete,
            path: "api/share/\(shareID.rawValue)",
            retryPolicy: .never
        )
    }
}
