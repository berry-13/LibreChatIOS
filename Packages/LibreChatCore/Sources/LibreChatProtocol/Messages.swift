import Foundation
import LibreChatDomain

public struct LibreChatMessageFeedbackDTO: Codable, Equatable, Sendable {
    public let rating: String?
    public let tag: String?
    public let text: String?

    public init(rating: String?, tag: String?, text: String? = nil) {
        self.rating = rating
        self.tag = tag
        self.text = text
    }

    public init(_ feedback: MessageFeedback) {
        rating = feedback.rating.rawValue
        tag = feedback.tag.rawValue
        text = feedback.text
    }

    public func domainModel() throws -> MessageFeedback {
        guard let rating,
              let parsedRating = MessageFeedbackRating(rawValue: rating),
              let tag,
              let parsedTag = MessageFeedbackTag(rawValue: tag),
              parsedTag.rating == parsedRating else {
            throw DTOMapperError.invalidField("message.feedback")
        }
        return MessageFeedback(tag: parsedTag, text: text)
    }
}

private struct MessageFeedbackUpdateBodyDTO: Encodable, Sendable {
    let feedback: LibreChatMessageFeedbackDTO?

    private enum CodingKeys: String, CodingKey { case feedback }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(feedback, forKey: .feedback)
    }
}

public struct MessageFeedbackUpdateResponseDTO: Decodable, Equatable, Sendable {
    public let messageID: String?
    public let conversationID: String?
    public let feedback: LibreChatMessageFeedbackDTO?
    public let containsFeedback: Bool

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case conversationID = "conversationId"
        case feedback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
        containsFeedback = container.contains(.feedback)
        feedback = try container.decodeIfPresent(
            LibreChatMessageFeedbackDTO.self,
            forKey: .feedback
        )
    }

    public func domainModel(
        expected: MessageFeedbackCoordinate
    ) throws -> MessageFeedbackResult {
        guard messageID == expected.messageID.rawValue,
              conversationID == expected.conversationID.rawValue,
              containsFeedback else {
            throw LibreChatProtocolError.invalidResponse
        }
        return MessageFeedbackResult(
            coordinate: expected,
            feedback: try feedback?.domainModel(),
            resolution: .confirmedAfterResponse
        )
    }
}

private struct MessageUpdateBodyDTO: Encodable, Sendable {
    let text: String
    let index: Int?

    private enum CodingKeys: String, CodingKey {
        case text, index
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(index, forKey: .index)
    }
}

public enum LibreChatMessagesAPI {
    /// Constructs the pinned feedback mutation. Clearing deliberately omits
    /// `feedback`, matching the web client's JSON `{}` request and the
    /// server's `feedback == null` clearing semantics.
    public static func updateFeedback(
        _ request: MessageFeedbackRequest
    ) throws -> APIRequest<MessageFeedbackUpdateResponseDTO> {
        let conversationID = request.coordinate.conversationID.rawValue
        let messageID = request.coordinate.messageID.rawValue
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageFeedbackError.blankIdentifier
        }
        if let text = request.feedback?.text,
           text.utf16.count > MessageFeedbackRequest.maximumTextUTF16Length {
            throw MessageFeedbackError.textTooLong(
                maximumUTF16Length: MessageFeedbackRequest.maximumTextUTF16Length
            )
        }
        return try APIRequest(
            method: .put,
            path: "api/messages",
            pathComponents: ["api", "messages", conversationID, messageID, "feedback"],
            body: MessageFeedbackUpdateBodyDTO(
                feedback: request.feedback.map(LibreChatMessageFeedbackDTO.init)
            ),
            retryPolicy: .never
        )
    }

    /// Constructs a save-only message edit. It is intentionally never retried:
    /// a lost response is reconciled by an idempotent history read at the
    /// repository boundary.
    public static func update(
        coordinate: MessageTextCoordinate,
        text: String
    ) throws -> APIRequest<JSONValue> {
        let conversationID = coordinate.conversationID.rawValue
        let messageID = coordinate.messageID.rawValue
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageEditError.blankIdentifier
        }
        let index: Int?
        switch coordinate.location {
        case .primaryText:
            index = nil
        case let .contentPart(value, _):
            guard value >= 0 else { throw MessageEditError.negativeContentPartIndex }
            index = value
        }
        return try APIRequest(
            method: .put,
            path: "api/messages",
            pathComponents: ["api", "messages", conversationID, messageID],
            body: MessageUpdateBodyDTO(text: text, index: index),
            retryPolicy: .never
        )
    }
}
