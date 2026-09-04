import Foundation

/// The exact `updatedAt` token returned with a shared snapshot. It is retained
/// verbatim because a fork request compares it against the server's revision.
public struct SharedSnapshotRevision: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Share-scoped routes for a file exposed by a shared snapshot.
///
/// These paths are intentionally derived from the share and file identifiers,
/// rather than trusting any owner-scoped filepath returned by an attachment.
public struct SharedFileAccess: Codable, Equatable, Hashable, Sendable {
    public let shareID: SharedLinkID
    public let fileID: SharedFileID

    public init(shareID: SharedLinkID, fileID: SharedFileID) {
        self.shareID = shareID
        self.fileID = fileID
    }

    public var path: String {
        "/api/share/\(Self.encode(shareID.rawValue))/files/\(Self.encode(fileID.rawValue))"
    }
    public var downloadPath: String { "\(path)/download" }
    public var previewPath: String { "\(path)/preview" }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public struct SharedSnapshotFile: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: SharedFileID
    public let access: SharedFileAccess
    public var filename: String
    public var mimeType: String?
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    public var previewStatus: String?

    public init(
        id: SharedFileID,
        access: SharedFileAccess,
        filename: String,
        mimeType: String? = nil,
        bytes: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        previewStatus: String? = nil
    ) {
        self.id = id
        self.access = access
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
        self.width = width
        self.height = height
        self.previewStatus = previewStatus
    }

    /// A display-compatible projection whose path remains share-authorized.
    public var uploadedFile: UploadedFile {
        UploadedFile(
            id: id.rawValue,
            filename: filename,
            filepath: access.path,
            mimeType: mimeType,
            bytes: bytes,
            width: width,
            height: height,
            previewStatus: previewStatus
        )
    }
}

/// A sanitized, read-only message from a shared-link response. Its identifiers
/// are pseudonyms and must not enter canonical conversation caches.
public struct SharedSnapshotMessage: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: SharedMessageID
    public let conversationID: SharedConversationID
    public var parentMessageID: SharedMessageID?
    public var author: MessageAuthor
    public var text: String?
    public var content: [MessageContent]
    public var files: [SharedSnapshotFile]
    public var model: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var isUnfinished: Bool?
    public var finishReason: String?

    public init(
        id: SharedMessageID,
        conversationID: SharedConversationID,
        parentMessageID: SharedMessageID? = nil,
        author: MessageAuthor,
        text: String? = nil,
        content: [MessageContent] = [],
        files: [SharedSnapshotFile] = [],
        model: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        isUnfinished: Bool? = nil,
        finishReason: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentMessageID = parentMessageID
        self.author = author
        self.text = text
        self.content = content
        self.files = files
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isUnfinished = isUnfinished
        self.finishReason = finishReason
    }
}

/// An immutable, public-link view. The source conversation and message IDs are
/// deliberately unavailable in this type.
public struct SharedConversationSnapshot: Codable, Equatable, Sendable {
    public let shareID: SharedLinkID
    public let conversationID: SharedConversationID
    public var title: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var revision: SharedSnapshotRevision?
    public var messages: [SharedSnapshotMessage]

    public init(
        shareID: SharedLinkID,
        conversationID: SharedConversationID,
        title: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        revision: SharedSnapshotRevision? = nil,
        messages: [SharedSnapshotMessage]
    ) {
        self.shareID = shareID
        self.conversationID = conversationID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.messages = messages
    }
}

public struct SharedConversationForkRequest: Codable, Equatable, Sendable {
    public let shareID: SharedLinkID
    public var targetMessageIndex: Int?
    public var shareRevision: SharedSnapshotRevision?

    public init(
        shareID: SharedLinkID,
        targetMessageIndex: Int? = nil,
        shareRevision: SharedSnapshotRevision? = nil
    ) {
        self.shareID = shareID
        self.targetMessageIndex = targetMessageIndex
        self.shareRevision = shareRevision
    }
}

/// A fork crosses the privacy boundary: the result is a newly owned canonical
/// conversation and therefore uses ordinary conversation/message identifiers.
public struct SharedConversationForkResult: Codable, Equatable, Sendable {
    public var conversation: Conversation
    public var messages: [ChatMessage]

    public init(conversation: Conversation, messages: [ChatMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}
