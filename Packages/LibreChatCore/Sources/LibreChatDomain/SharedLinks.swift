import Foundation

/// Owner-visible state for a conversation's current shared link.
///
/// The server's `_id` is retained separately because it is the ACL resource
/// identifier, whereas `shareID` identifies the link exposed in share URLs.
public struct SharedLink: Codable, Equatable, Hashable, Sendable {
    public let shareID: SharedLinkID
    public let resourceID: String?
    public let conversationID: ConversationID
    public var targetMessageID: MessageID?
    /// `nil` means an older server/link did not expose the per-link setting.
    public var snapshotFiles: Bool?

    public init(
        shareID: SharedLinkID,
        resourceID: String? = nil,
        conversationID: ConversationID,
        targetMessageID: MessageID? = nil,
        snapshotFiles: Bool? = nil
    ) {
        self.shareID = shareID
        self.resourceID = resourceID
        self.conversationID = conversationID
        self.targetMessageID = targetMessageID
        self.snapshotFiles = snapshotFiles
    }
}

public struct SharedLinkState: Codable, Equatable, Sendable {
    public let conversationID: ConversationID
    public let link: SharedLink?

    public init(conversationID: ConversationID, link: SharedLink? = nil) {
        self.conversationID = conversationID
        self.link = link
    }

    public var isShared: Bool { link != nil }
}

/// Optional publication settings. `nil` fields are intentionally omitted from
/// the wire body so the server can apply its current defaults.
public struct SharedLinkPublishRequest: Codable, Equatable, Sendable {
    public var targetMessageID: MessageID?
    public var snapshotFiles: Bool?

    public init(targetMessageID: MessageID? = nil, snapshotFiles: Bool? = nil) {
        self.targetMessageID = targetMessageID
        self.snapshotFiles = snapshotFiles
    }

    private enum CodingKeys: String, CodingKey {
        case targetMessageID = "targetMessageId"
        case snapshotFiles
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(targetMessageID?.rawValue, forKey: .targetMessageID)
        try container.encodeIfPresent(snapshotFiles, forKey: .snapshotFiles)
    }
}

public struct SharedLinkMutationResult: Codable, Equatable, Sendable {
    public let shareID: SharedLinkID
    public let resourceID: String?
    public let conversationID: ConversationID
    public let targetMessageID: MessageID?

    public init(
        shareID: SharedLinkID,
        resourceID: String? = nil,
        conversationID: ConversationID,
        targetMessageID: MessageID? = nil
    ) {
        self.shareID = shareID
        self.resourceID = resourceID
        self.conversationID = conversationID
        self.targetMessageID = targetMessageID
    }
}

public struct SharedLinkDeletionResult: Codable, Equatable, Sendable {
    public let shareID: SharedLinkID
    public let resourceID: String?
    public let message: String

    public init(shareID: SharedLinkID, resourceID: String? = nil, message: String) {
        self.shareID = shareID
        self.resourceID = resourceID
        self.message = message
    }
}
