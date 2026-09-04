import Foundation

public enum MessageFeedbackRating: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case thumbsUp
    case thumbsDown
}

/// LibreChat's closed feedback-tag registry.
///
/// Rating is derived from the tag so an impossible tag/rating pair cannot be
/// represented in the native domain even if a future or malformed server
/// payload reaches the permissive DTO boundary.
public enum MessageFeedbackTag: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case notMatched = "not_matched"
    case inaccurate
    case badStyle = "bad_style"
    case missingImage = "missing_image"
    case unjustifiedRefusal = "unjustified_refusal"
    case notHelpful = "not_helpful"
    case other
    case accurateReliable = "accurate_reliable"
    case creativeSolution = "creative_solution"
    case clearWellWritten = "clear_well_written"
    case attentionToDetail = "attention_to_detail"

    public var rating: MessageFeedbackRating {
        switch self {
        case .notMatched, .inaccurate, .badStyle, .missingImage,
             .unjustifiedRefusal, .notHelpful, .other:
            .thumbsDown
        case .accurateReliable, .creativeSolution, .clearWellWritten,
             .attentionToDetail:
            .thumbsUp
        }
    }

    public var title: String {
        switch self {
        case .notMatched: "Did not follow the request"
        case .inaccurate: "Inaccurate"
        case .badStyle: "Writing style"
        case .missingImage: "Missing image"
        case .unjustifiedRefusal: "Unjustified refusal"
        case .notHelpful: "Not helpful"
        case .other: "Something else"
        case .accurateReliable: "Accurate and reliable"
        case .creativeSolution: "Creative solution"
        case .clearWellWritten: "Clear and well written"
        case .attentionToDetail: "Attention to detail"
        }
    }

    public static func tags(for rating: MessageFeedbackRating) -> [MessageFeedbackTag] {
        allCases.filter { $0.rating == rating }
    }
}

public struct MessageFeedback: Codable, Equatable, Hashable, Sendable {
    public let tag: MessageFeedbackTag
    public let text: String?

    public init(tag: MessageFeedbackTag, text: String? = nil) {
        self.tag = tag
        self.text = text
    }

    public var rating: MessageFeedbackRating { tag.rating }
}

public struct MessageFeedbackCoordinate: Codable, Equatable, Hashable, Sendable {
    public let conversationID: ConversationID
    public let messageID: MessageID

    public init(conversationID: ConversationID, messageID: MessageID) {
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

public struct MessageFeedbackRequest: Codable, Equatable, Hashable, Sendable {
    /// Zod string length follows JavaScript UTF-16 code-unit semantics.
    public static let maximumTextUTF16Length = 1_024

    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let coordinate: MessageFeedbackCoordinate
    /// `nil` means clear the existing feedback. The pinned web client encodes
    /// this as an omitted `feedback` field in an otherwise empty JSON object.
    public let feedback: MessageFeedback?

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        coordinate: MessageFeedbackCoordinate,
        feedback: MessageFeedback?
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.coordinate = coordinate
        self.feedback = feedback
    }
}

public enum MessageFeedbackResolution: String, Codable, Equatable, Hashable, Sendable {
    case confirmedAfterResponse
    case reconciledAfterAmbiguousFailure
}

public struct MessageFeedbackResult: Codable, Equatable, Sendable {
    public let coordinate: MessageFeedbackCoordinate
    public let feedback: MessageFeedback?
    public let resolution: MessageFeedbackResolution
    /// Present only when an ambiguity required an authoritative history read.
    public let authoritativeHistory: [ChatMessage]?

    public init(
        coordinate: MessageFeedbackCoordinate,
        feedback: MessageFeedback?,
        resolution: MessageFeedbackResolution,
        authoritativeHistory: [ChatMessage]? = nil
    ) {
        self.coordinate = coordinate
        self.feedback = feedback
        self.resolution = resolution
        self.authoritativeHistory = authoritativeHistory
    }
}

public struct RecoverableMessageFeedbackAmbiguity: Codable, Equatable, Hashable, Sendable {
    public enum Reason: String, Codable, Equatable, Hashable, Sendable {
        case verificationUnavailable
        case messageMissing
        case authoritativeMismatch
    }

    public let coordinate: MessageFeedbackCoordinate
    public let submittedFeedback: MessageFeedback?
    public let authoritativeFeedback: MessageFeedback?
    public let reason: Reason

    public init(
        coordinate: MessageFeedbackCoordinate,
        submittedFeedback: MessageFeedback?,
        authoritativeFeedback: MessageFeedback?,
        reason: Reason
    ) {
        self.coordinate = coordinate
        self.submittedFeedback = submittedFeedback
        self.authoritativeFeedback = authoritativeFeedback
        self.reason = reason
    }
}

public enum MessageFeedbackError: LocalizedError, Equatable, Sendable {
    case unavailable
    case profileMismatch
    case accountMismatch
    case localIdentifier
    case blankIdentifier
    case textTooLong(maximumUTF16Length: Int)
    case ambiguous(RecoverableMessageFeedbackAmbiguity)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Message feedback is unavailable."
        case .profileMismatch, .accountMismatch:
            "This feedback belongs to another LibreChat session."
        case .localIdentifier:
            "Only saved LibreChat responses can receive feedback."
        case .blankIdentifier:
            "The server message coordinates are incomplete."
        case let .textTooLong(maximum):
            "Feedback details must be \(maximum) characters or fewer."
        case .ambiguous:
            "LibreChat may have saved this feedback. Refresh before trying again."
        }
    }
}
