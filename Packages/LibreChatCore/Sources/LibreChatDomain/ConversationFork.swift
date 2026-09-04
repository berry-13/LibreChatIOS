import Foundation

/// The exact authenticated `/api/convos/fork` option values.  The native
/// client models every known server option even when a UI initially exposes
/// only `directPath`.
public enum ConversationForkOption: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case directPath
    case includeBranches
    case targetLevel
}

public struct ConversationForkRequest: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let conversationID: ConversationID
    public let targetMessageID: MessageID
    public let option: ConversationForkOption
    public let splitAtTarget: Bool
    public let latestMessageID: MessageID?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        targetMessageID: MessageID,
        option: ConversationForkOption = .directPath,
        splitAtTarget: Bool = false,
        latestMessageID: MessageID? = nil
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
        self.targetMessageID = targetMessageID
        self.option = option
        self.splitAtTarget = splitAtTarget
        self.latestMessageID = latestMessageID
    }
}

public struct ConversationForkResult: Codable, Equatable, Sendable {
    public let conversation: Conversation
    public let messages: [ChatMessage]

    public init(conversation: Conversation, messages: [ChatMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}

public struct ConversationForkPreflight: Codable, Equatable, Sendable {
    public let request: ConversationForkRequest
    public let sourceMessageIDs: Set<MessageID>

    public init(request: ConversationForkRequest, sourceMessageIDs: Set<MessageID>) {
        self.request = request
        self.sourceMessageIDs = sourceMessageIDs
    }
}

public enum ConversationForkValidationError: Error, LocalizedError, Equatable, Sendable {
    case localIdentifier
    case blankIdentifier
    case targetNotFound(MessageID)
    case latestMessageRequired
    case unexpectedLatestMessage
    case latestMessageNotFound(MessageID)
    case latestMessageOutsideSplit(MessageID)
    case crossConversationMessage(MessageID)
    case invalidGraph
    case invalidResponse
    case responseConversationCollision
    case responseMessageCollision(MessageID)

    public var errorDescription: String? {
        switch self {
        case .localIdentifier:
            "A fork requires a server-owned conversation and message graph."
        case .blankIdentifier:
            "The fork identity is incomplete."
        case .targetNotFound:
            "The selected fork target is not in the authoritative history."
        case .latestMessageRequired:
            "A split-at-target fork requires a latest message identity."
        case .unexpectedLatestMessage:
            "A latest message identity is only valid for a split-at-target fork."
        case .latestMessageNotFound:
            "The split fork latest message is not in the authoritative history."
        case .latestMessageOutsideSplit:
            "The split fork latest message is outside the selected target subtree."
        case .crossConversationMessage:
            "A fork history row belongs to another conversation."
        case .invalidGraph:
            "The authoritative message graph is malformed."
        case .invalidResponse:
            "LibreChat returned a malformed fork result."
        case .responseConversationCollision:
            "LibreChat returned the source conversation instead of a fresh fork."
        case .responseMessageCollision:
            "LibreChat returned a source message identity in the fresh fork."
        }
    }
}

/// Repository-stage outcomes for the non-idempotent fork mutation.  A
/// preflight/read failure occurred before the POST and is safe for the caller
/// to retry.  `ambiguous` means the POST may have reached LibreChat; callers
/// must refresh/reconcile and must not blindly submit the same mutation again.
public enum ConversationForkError: Error, LocalizedError, Equatable, Sendable {
    case profileMismatch
    case accountMismatch
    case preflightValidation(ConversationForkValidationError)
    case preflightReadFailed
    case ambiguous

    public var errorDescription: String? {
        switch self {
        case .profileMismatch, .accountMismatch:
            "This fork belongs to another LibreChat session."
        case let .preflightValidation(error):
            error.errorDescription
        case .preflightReadFailed:
            "The source conversation could not be verified. No fork was created."
        case .ambiguous:
            "LibreChat may have created this fork. Refresh before trying again."
        }
    }
}

/// Pure graph and identity checks performed before a fork POST and after its
/// response.  The server's fork helper is permissive for missing targets, so
/// native callers must not rely on its empty-result behavior.
public enum ConversationForkValidator {
    public static func preflight(
        request: ConversationForkRequest,
        conversation: Conversation,
        history: [ChatMessage]
    ) throws -> ConversationForkPreflight {
        guard conversation.id == request.conversationID else {
            throw ConversationForkValidationError.crossConversationMessage(request.targetMessageID)
        }
        guard isServerIdentifier(conversation.id.rawValue) else {
            throw isBlank(conversation.id.rawValue)
                ? ConversationForkValidationError.blankIdentifier
                : ConversationForkValidationError.localIdentifier
        }
        guard history.allSatisfy({ $0.conversationID == request.conversationID }) else {
            let offending = history.first { $0.conversationID != request.conversationID }?.id
                ?? request.targetMessageID
            throw ConversationForkValidationError.crossConversationMessage(offending)
        }
        guard history.allSatisfy({ isServerIdentifier($0.id.rawValue) }) else {
            throw ConversationForkValidationError.localIdentifier
        }

        let tree = MessageTree(messages: history)
        guard tree.isStructurallyValid else {
            throw ConversationForkValidationError.invalidGraph
        }
        guard tree.siblings(containing: request.targetMessageID) != nil else {
            throw ConversationForkValidationError.targetNotFound(request.targetMessageID)
        }

        if request.splitAtTarget {
            guard let latest = request.latestMessageID else {
                throw ConversationForkValidationError.latestMessageRequired
            }
            guard tree.siblings(containing: latest) != nil else {
                throw ConversationForkValidationError.latestMessageNotFound(latest)
            }
            guard isAtOrBelowTarget(
                latest,
                target: request.targetMessageID,
                history: history
            ) else {
                throw ConversationForkValidationError.latestMessageOutsideSplit(latest)
            }
        } else if request.latestMessageID != nil {
            // The server ignores this field unless splitAtTarget is true;
            // rejecting it prevents a caller from believing it affected the
            // fork selection.
            throw ConversationForkValidationError.unexpectedLatestMessage
        }

        return ConversationForkPreflight(
            request: request,
            sourceMessageIDs: Set(history.map(\.id))
        )
    }

    public static func validateResponse(
        _ result: ConversationForkResult,
        for preflight: ConversationForkPreflight
    ) throws -> ConversationForkResult {
        guard isServerIdentifier(result.conversation.id.rawValue),
              result.conversation.id != preflight.request.conversationID else {
            throw result.conversation.id == preflight.request.conversationID
                ? ConversationForkValidationError.responseConversationCollision
                : (isBlank(result.conversation.id.rawValue)
                    ? ConversationForkValidationError.blankIdentifier
                    : ConversationForkValidationError.localIdentifier)
        }
        guard !result.messages.isEmpty else {
            throw ConversationForkValidationError.invalidResponse
        }
        guard result.messages.allSatisfy({ message in
            message.conversationID == result.conversation.id
                && isServerIdentifier(message.id.rawValue)
        }) else {
            throw ConversationForkValidationError.invalidResponse
        }
        if let collision = result.messages.first(where: {
            preflight.sourceMessageIDs.contains($0.id)
        }) {
            throw ConversationForkValidationError.responseMessageCollision(collision.id)
        }
        let tree = MessageTree(messages: result.messages)
        guard tree.isStructurallyValid else {
            throw ConversationForkValidationError.invalidResponse
        }
        return result
    }

    private static func isAtOrBelowTarget(
        _ candidate: MessageID,
        target: MessageID,
        history: [ChatMessage]
    ) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        var cursor: MessageID? = candidate
        var visited = Set<MessageID>()
        while let current = cursor, visited.insert(current).inserted {
            if current == target { return true }
            cursor = byID[current]?.parentMessageID
            if let parent = cursor,
               Self.isRootSentinel(parent.rawValue) {
                cursor = nil
            }
        }
        return false
    }

    private static func isServerIdentifier(_ value: String) -> Bool {
        !isBlank(value) && !value.lowercased().hasPrefix("local-") && !isRootSentinel(value)
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

/// Repository seam for the authenticated fork mutation.  The app repository
/// is intentionally added in a later slice so this contract can be tested in
/// isolation first.
public protocol ConversationForkRepository: Sendable {
    func fork(_ request: ConversationForkRequest) async throws -> ConversationForkResult
}
