import Foundation

/// Coordinates for LibreChat's authenticated whole-conversation duplication
/// mutation. The source is always an owned, persisted conversation; local
/// drafts deliberately fail validation before any request is dispatched.
public struct ConversationDuplicationRequest: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let conversationID: ConversationID
    public let title: String?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        title: String? = nil
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
        self.title = title
    }
}

public struct ConversationDuplicationResult: Codable, Equatable, Sendable {
    public let conversation: Conversation
    public let messages: [ChatMessage]

    public init(conversation: Conversation, messages: [ChatMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}

public struct ConversationDuplicationPreflight: Codable, Equatable, Sendable {
    public let request: ConversationDuplicationRequest
    public let sourceMessageIDs: Set<MessageID>

    public init(
        request: ConversationDuplicationRequest,
        sourceMessageIDs: Set<MessageID>
    ) {
        self.request = request
        self.sourceMessageIDs = sourceMessageIDs
    }
}

public enum ConversationDuplicationValidationError: Error, LocalizedError, Equatable, Sendable {
    case localIdentifier
    case blankIdentifier
    case emptyHistory
    case crossConversationMessage(MessageID)
    case invalidGraph
    case invalidResponse
    case responseConversationCollision
    case responseMessageCollision(MessageID)

    public var errorDescription: String? {
        switch self {
        case .localIdentifier:
            "Only a server-owned conversation can be duplicated."
        case .blankIdentifier:
            "The conversation identity is incomplete."
        case .emptyHistory:
            "Add a message before duplicating this conversation."
        case .crossConversationMessage:
            "The authoritative history contains a message from another conversation."
        case .invalidGraph:
            "The authoritative message graph is malformed."
        case .invalidResponse:
            "LibreChat returned an incomplete duplicated conversation."
        case .responseConversationCollision:
            "LibreChat returned the original conversation instead of a new copy."
        case .responseMessageCollision:
            "LibreChat reused an original message identity in the new copy."
        }
    }
}

/// LibreChat does not expose an idempotency key or a unique lookup coordinate
/// for this mutation. Once the POST has been dispatched, a transport failure,
/// server failure, cancellation, or malformed 2xx acknowledgement is therefore
/// outcome-unknown and must never be retried automatically.
public enum ConversationDuplicationError: Error, LocalizedError, Equatable, Sendable {
    case profileMismatch
    case accountMismatch
    case preflightValidation(ConversationDuplicationValidationError)
    case preflightReadFailed
    case ambiguous

    public var errorDescription: String? {
        switch self {
        case .profileMismatch, .accountMismatch:
            "This copy request belongs to another LibreChat session."
        case let .preflightValidation(error):
            error.errorDescription
        case .preflightReadFailed:
            "The source conversation could not be verified. No copy request was sent."
        case .ambiguous:
            "LibreChat may have created a copy. Refresh conversations before trying again."
        }
    }
}

public enum ConversationDuplicationValidator {
    public static func preflight(
        request: ConversationDuplicationRequest,
        conversation: Conversation,
        history: [ChatMessage]
    ) throws -> ConversationDuplicationPreflight {
        guard conversation.id == request.conversationID else {
            throw ConversationDuplicationValidationError.invalidResponse
        }
        guard isServerIdentifier(conversation.id.rawValue) else {
            throw isBlank(conversation.id.rawValue)
                ? ConversationDuplicationValidationError.blankIdentifier
                : ConversationDuplicationValidationError.localIdentifier
        }
        guard !history.isEmpty else {
            throw ConversationDuplicationValidationError.emptyHistory
        }
        guard history.allSatisfy({ $0.conversationID == request.conversationID }) else {
            let offending = history.first { $0.conversationID != request.conversationID }?.id
                ?? MessageID(rawValue: "unknown")
            throw ConversationDuplicationValidationError.crossConversationMessage(offending)
        }
        guard history.allSatisfy({ isServerIdentifier($0.id.rawValue) }) else {
            throw ConversationDuplicationValidationError.localIdentifier
        }
        guard MessageTree(messages: history).isStructurallyValid else {
            throw ConversationDuplicationValidationError.invalidGraph
        }
        return ConversationDuplicationPreflight(
            request: request,
            sourceMessageIDs: Set(history.map(\.id))
        )
    }

    public static func validateResponse(
        _ result: ConversationDuplicationResult,
        for preflight: ConversationDuplicationPreflight
    ) throws -> ConversationDuplicationResult {
        guard isServerIdentifier(result.conversation.id.rawValue) else {
            throw isBlank(result.conversation.id.rawValue)
                ? ConversationDuplicationValidationError.blankIdentifier
                : ConversationDuplicationValidationError.localIdentifier
        }
        guard result.conversation.id != preflight.request.conversationID else {
            throw ConversationDuplicationValidationError.responseConversationCollision
        }
        guard !result.messages.isEmpty,
              result.messages.allSatisfy({
                  $0.conversationID == result.conversation.id
                      && isServerIdentifier($0.id.rawValue)
              }) else {
            throw ConversationDuplicationValidationError.invalidResponse
        }
        if let collision = result.messages.first(where: {
            preflight.sourceMessageIDs.contains($0.id)
        }) {
            throw ConversationDuplicationValidationError.responseMessageCollision(collision.id)
        }
        guard MessageTree(messages: result.messages).isStructurallyValid else {
            throw ConversationDuplicationValidationError.invalidResponse
        }
        return result
    }

    private static func isServerIdentifier(_ value: String) -> Bool {
        !isBlank(value)
            && !value.lowercased().hasPrefix("local-")
            && !isRootSentinel(value)
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isRootSentinel(_ value: String) -> Bool {
        switch value.uppercased() {
        case "NO_PARENT", "00000000-0000-0000-0000-000000000000": true
        default: false
        }
    }
}

public protocol ConversationDuplicationRepository: Sendable {
    func duplicate(
        _ request: ConversationDuplicationRequest
    ) async throws -> ConversationDuplicationResult
}

public extension ConversationDuplicationRepository {
    func duplicate(
        _ request: ConversationDuplicationRequest
    ) async throws -> ConversationDuplicationResult {
        throw ConversationDuplicationError.preflightReadFailed
    }
}
