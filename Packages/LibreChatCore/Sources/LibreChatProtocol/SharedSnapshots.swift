import Foundation
import LibreChatDomain

public struct SharedSnapshotFileDTO: Decodable, Equatable, Sendable {
    public var fileID: String?
    public var filename: String?
    public var type: String?
    public var bytes: Int64?
    public var width: Int?
    public var height: Int?
    public var status: String?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case filename, type, bytes, width, height, status
    }

    public func domainModel(shareID: SharedLinkID, fallbackFilename: String = "Attachment") throws -> SharedSnapshotFile {
        guard let fileID = fileID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedSnapshot.file_id")
        }
        let sharedFileID = SharedFileID(rawValue: fileID)
        return SharedSnapshotFile(
            id: sharedFileID,
            access: SharedFileAccess(shareID: shareID, fileID: sharedFileID),
            filename: filename?.nonEmpty ?? fallbackFilename,
            mimeType: type,
            bytes: bytes,
            width: width,
            height: height,
            previewStatus: status
        )
    }
}

public struct SharedSnapshotMessageDTO: Decodable, Equatable, Sendable {
    public var messageID: String?
    public var conversationID: String?
    public var parentMessageID: String?
    public var sender: String?
    public var isCreatedByUser: Bool?
    public var text: String?
    public var content: [JSONValue]?
    public var files: [SharedSnapshotFileDTO]?
    public var attachments: [JSONValue]?
    public var model: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var unfinished: Bool?
    public var finishReason: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case conversationID = "conversationId"
        case parentMessageID = "parentMessageId"
        case sender, isCreatedByUser, text, content, files, attachments, model, createdAt, updatedAt, unfinished
        case finishReason = "finish_reason"
    }

    public func domainModel(
        shareID: SharedLinkID,
        expectedConversationID: SharedConversationID
    ) throws -> SharedSnapshotMessage {
        guard let messageID = messageID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedSnapshot.messageId")
        }
        guard let rawConversationID = conversationID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedSnapshot.conversationId")
        }
        let messageConversationID = SharedConversationID(rawValue: rawConversationID)
        guard messageConversationID == expectedConversationID else {
            throw DTOMapperError.invalidField("sharedSnapshot.message.conversationId")
        }

        let sharedFiles = try (files ?? []).map { try $0.domainModel(shareID: shareID) }
        var mappedContent = LibreChatMessageDTO.domainContent(from: content ?? []).map {
            Self.sanitizedSharedContent($0, shareID: shareID)
        }
        mappedContent.append(contentsOf: sharedFiles.map { .file($0.uploadedFile) })
        mappedContent.append(contentsOf: try (attachments ?? []).compactMap {
            try Self.domainAttachment($0, shareID: shareID)
        })
        if mappedContent.isEmpty, let text, !text.isEmpty {
            mappedContent.append(.text(text))
        }

        let author: MessageAuthor = if isCreatedByUser == true {
            .user
        } else {
            .assistant(name: sender?.nonEmpty ?? "Assistant")
        }
        return SharedSnapshotMessage(
            id: SharedMessageID(rawValue: messageID),
            conversationID: messageConversationID,
            parentMessageID: parentMessageID?.nonEmpty.map(SharedMessageID.init(rawValue:)),
            author: author,
            text: text,
            content: mappedContent,
            files: sharedFiles,
            model: model,
            createdAt: createdAt.flatMap(Self.date),
            updatedAt: updatedAt.flatMap(Self.date),
            isUnfinished: unfinished,
            finishReason: finishReason
        )
    }

    private static func domainAttachment(
        _ value: JSONValue,
        shareID: SharedLinkID
    ) throws -> MessageContent? {
        guard let object = value.objectValue else { return .unsupported(kind: "attachment") }
        if object["file_id"]?.stringValue != nil {
            let data = try JSONEncoder().encode(value)
            let file = try JSONDecoder().decode(SharedSnapshotFileDTO.self, from: data)
                .domainModel(shareID: shareID)
            return .file(file.uploadedFile)
        }
        if object["type"]?.stringValue == "image_file" {
            let fileValue = object["image_file"] ?? value
            if let data = try? JSONEncoder().encode(fileValue),
               let file = try? JSONDecoder().decode(SharedSnapshotFileDTO.self, from: data)
                .domainModel(shareID: shareID, fallbackFilename: "Image") {
                return .file(file.uploadedFile)
            }
        }
        if object["type"]?.stringValue != nil {
            return LibreChatMessageDTO.domainContent(from: [value]).first.map {
                sanitizedSharedContent($0, shareID: shareID)
            }
        }
        return .unsupported(kind: "attachment")
    }

    private static func sanitizedSharedContent(
        _ content: MessageContent,
        shareID: SharedLinkID
    ) -> MessageContent {
        switch content {
        case let .image(url, alternativeText):
            guard isAllowedMediaURL(url, shareID: shareID) else {
                return .unsupported(kind: "shared_image")
            }
            return .image(url, alternativeText: alternativeText)
        case let .video(url, alternativeText):
            guard isAllowedMediaURL(url, shareID: shareID) else {
                return .unsupported(kind: "shared_video")
            }
            return .video(url, alternativeText: alternativeText)
        case let .audio(url, transcript):
            guard isAllowedMediaURL(url, shareID: shareID) else {
                return .unsupported(kind: "shared_audio")
            }
            return .audio(url, transcript: transcript)
        case let .file(file):
            guard let filepath = file.filepath,
                  isShareScopedPath(filepath, shareID: shareID) else {
                return .unsupported(kind: "shared_file")
            }
            return .file(file)
        default:
            return content
        }
    }

    private static func isAllowedMediaURL(_ url: URL, shareID: SharedLinkID) -> Bool {
        if url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            return true
        }
        guard url.scheme == nil,
              url.host == nil,
              url.query == nil,
              url.fragment == nil else { return false }
        return isShareScopedPath(url.path, shareID: shareID)
    }

    private static func isShareScopedPath(_ path: String, shareID: SharedLinkID) -> Bool {
        guard shareID.isSafePathComponent,
              !path.contains("..") else { return false }
        return path.hasPrefix("/api/share/\(shareID.rawValue)/files/")
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

public struct SharedConversationSnapshotDTO: Decodable, Equatable, Sendable {
    public var shareID: String?
    public var title: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var conversationID: String?
    public var messages: [SharedSnapshotMessageDTO]?

    private enum CodingKeys: String, CodingKey {
        case shareID = "shareId"
        case title, createdAt, updatedAt
        case conversationID = "conversationId"
        case messages
    }

    public func domainModel(expectedShareID: SharedLinkID? = nil) throws -> SharedConversationSnapshot {
        guard let rawShareID = shareID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedSnapshot.shareId")
        }
        let sharedLinkID = SharedLinkID(rawValue: rawShareID)
        guard sharedLinkID.isSafePathComponent else {
            throw DTOMapperError.invalidField("sharedSnapshot.shareId")
        }
        if let expectedShareID, sharedLinkID != expectedShareID {
            throw DTOMapperError.invalidField("sharedSnapshot.shareId")
        }
        guard let conversationID = conversationID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("sharedSnapshot.conversationId")
        }
        guard let messages else {
            throw DTOMapperError.missingRequiredField("sharedSnapshot.messages")
        }
        let sharedConversationID = SharedConversationID(rawValue: conversationID)
        return SharedConversationSnapshot(
            shareID: sharedLinkID,
            conversationID: sharedConversationID,
            title: title,
            createdAt: createdAt.flatMap(Self.date),
            updatedAt: updatedAt.flatMap(Self.date),
            revision: updatedAt?.nonEmpty.map(SharedSnapshotRevision.init(rawValue:)),
            messages: try messages.map {
                try $0.domainModel(shareID: sharedLinkID, expectedConversationID: sharedConversationID)
            }
        )
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

public struct SharedConversationForkRequestDTO: Encodable, Equatable, Sendable {
    public var targetMessageIndex: Int?
    public var shareRevision: String?

    public init(request: SharedConversationForkRequest) {
        targetMessageIndex = request.targetMessageIndex
        shareRevision = request.shareRevision?.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case targetMessageIndex, shareRevision
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(targetMessageIndex, forKey: .targetMessageIndex)
        try container.encodeIfPresent(shareRevision, forKey: .shareRevision)
    }
}

public struct SharedConversationForkResponseDTO: Decodable, Equatable, Sendable {
    public var conversation: LibreChatConversationDTO?
    public var messages: [LibreChatMessageDTO]?

    public func domainModel() throws -> SharedConversationForkResult {
        guard let conversation else {
            throw DTOMapperError.missingRequiredField("sharedFork.conversation")
        }
        guard let messages else {
            throw DTOMapperError.missingRequiredField("sharedFork.messages")
        }
        let canonicalConversation = try conversation.domainModel()
        let canonicalMessages = try messages.map {
            try $0.domainModel(defaultConversationID: canonicalConversation.id)
        }
        guard canonicalMessages.allSatisfy({ $0.conversationID == canonicalConversation.id }) else {
            throw DTOMapperError.invalidField("sharedFork.messages.conversationId")
        }
        return SharedConversationForkResult(
            conversation: canonicalConversation,
            messages: canonicalMessages
        )
    }
}

public enum LibreChatSharedSnapshotsAPI {
    /// Public shared snapshots intentionally make no bearer attempt: the server
    /// can authorize anonymous viewers and returns 401 when it cannot.
    public static func snapshot(
        shareID: SharedLinkID
    ) throws -> APIRequest<SharedConversationSnapshotDTO> {
        guard shareID.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")
        }
        return APIRequest(
            path: "api/share/\(shareID.rawValue)",
            authorization: .none,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    /// Forking is authenticated and non-idempotent because it creates a new
    /// canonical conversation for the requesting user.
    public static func fork(
        _ request: SharedConversationForkRequest
    ) throws -> APIRequest<SharedConversationForkResponseDTO> {
        guard request.shareID.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")
        }
        return try APIRequest(
            method: .post,
            path: "api/share/\(request.shareID.rawValue)/fork",
            body: SharedConversationForkRequestDTO(request: request),
            retryPolicy: .never
        )
    }
}
