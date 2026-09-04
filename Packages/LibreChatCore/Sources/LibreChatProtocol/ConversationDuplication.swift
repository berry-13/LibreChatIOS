import Foundation
import LibreChatDomain

public struct ConversationDuplicationRequestDTO: Encodable, Equatable, Sendable {
    public let conversationID: String
    public let title: String?

    public init(_ request: ConversationDuplicationRequest) {
        conversationID = request.conversationID.rawValue
        title = request.title
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case title
    }
}

public struct ConversationDuplicationResponseDTO: Decodable, Equatable, Sendable {
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
        for preflight: ConversationDuplicationPreflight
    ) throws -> ConversationDuplicationResult {
        let conversation = try conversation.domainModel()
        guard messages.allSatisfy({
            $0.messageID?.nonEmpty != nil && $0.conversationID?.nonEmpty != nil
        }) else {
            throw ConversationDuplicationValidationError.invalidResponse
        }
        let mapped = try messages.map {
            try $0.domainModel(defaultConversationID: conversation.id)
        }
        return try ConversationDuplicationValidator.validateResponse(
            ConversationDuplicationResult(
                conversation: conversation,
                messages: mapped
            ),
            for: preflight
        )
    }
}

public enum LibreChatConversationDuplicationAPI {
    /// The pinned server has no idempotency key for duplication. A single user
    /// confirmation produces one POST and transport never retries it.
    public static func duplicate(
        _ request: ConversationDuplicationRequest
    ) throws -> APIRequest<ConversationDuplicationResponseDTO> {
        try APIRequest(
            method: .post,
            path: "api/convos/duplicate",
            body: ConversationDuplicationRequestDTO(request),
            retryPolicy: .never
        )
    }
}
