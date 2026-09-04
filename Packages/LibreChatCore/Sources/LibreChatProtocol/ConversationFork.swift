import Foundation
import LibreChatDomain

public struct ConversationForkRequestDTO: Encodable, Equatable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let option: String
    public let splitAtTarget: Bool
    public let latestMessageID: String?

    public init(_ request: ConversationForkRequest) {
        self.conversationID = request.conversationID.rawValue
        self.messageID = request.targetMessageID.rawValue
        self.option = request.option.rawValue
        self.splitAtTarget = request.splitAtTarget
        self.latestMessageID = request.latestMessageID?.rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case messageID = "messageId"
        case option, splitAtTarget
        case latestMessageID = "latestMessageId"
    }
}

public struct ConversationForkResponseDTO: Decodable, Equatable, Sendable {
    public let conversation: LibreChatConversationDTO
    public let messages: [LibreChatMessageDTO]

    public init(
        conversation: LibreChatConversationDTO,
        messages: [LibreChatMessageDTO]
    ) {
        self.conversation = conversation
        self.messages = messages
    }

    public func domainModel(
        for preflight: ConversationForkPreflight
    ) throws -> ConversationForkResult {
        let conversation = try conversation.domainModel()
        guard conversation.id != preflight.request.conversationID else {
            throw ConversationForkValidationError.responseConversationCollision
        }
        // The general history mapper may use a caller-provided conversation
        // as a compatibility default. A fork response must identify every
        // fresh message explicitly so an incomplete payload cannot be
        // mistaken for a valid new conversation.
        guard messages.allSatisfy({
            $0.messageID?.nonEmpty != nil && $0.conversationID?.nonEmpty != nil
        }) else {
            throw ConversationForkValidationError.invalidResponse
        }
        let mapped = try messages.map {
            try $0.domainModel(defaultConversationID: conversation.id)
        }
        return try ConversationForkValidator.validateResponse(
            ConversationForkResult(conversation: conversation, messages: mapped),
            for: preflight
        )
    }
}

public enum LibreChatConversationForkAPI {
    /// Authenticated clone creation has no server idempotency key; it must
    /// never be automatically retried after an ambiguous transport result.
    public static func fork(
        _ request: ConversationForkRequest
    ) throws -> APIRequest<ConversationForkResponseDTO> {
        try APIRequest(
            method: .post,
            path: "api/convos/fork",
            body: ConversationForkRequestDTO(request),
            retryPolicy: .never
        )
    }
}
