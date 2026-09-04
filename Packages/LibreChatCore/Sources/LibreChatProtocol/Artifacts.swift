import Foundation
import LibreChatDomain

/// Exact body accepted by `POST /api/messages/artifact/:messageId` at the
/// pinned LibreChat revision. `index` is document order across the message's
/// text/content, not the model's artifact `identifier`.
public struct ArtifactUpdateRequestDTO: Encodable, Equatable, Sendable {
    public let index: Int
    public let original: String
    public let updated: String
    public let isTemporary: Bool?

    public init(index: Int, original: String, updated: String, isTemporary: Bool? = nil) {
        self.index = index
        self.original = original
        self.updated = updated
        self.isTemporary = isTemporary
    }

    private enum CodingKeys: String, CodingKey {
        case index, original, updated, isTemporary
    }
}

/// Successful artifact updates return the saved message's conversation,
/// content, and legacy text fields. Content is intentionally raw JSON: the
/// endpoint may carry arbitrary assistant content parts and the artifact
/// editor must not discard unknown fields.
public struct ArtifactUpdateResponseDTO: Decodable, Equatable, Sendable {
    public let conversationID: String?
    public let content: [JSONValue]?
    public let text: String?

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case content, text
    }
}

public enum LibreChatArtifactAPI {
    /// Builds a non-retriable artifact edit request. Retrying can apply an
    /// edit against a changed message and the server intentionally treats a
    /// stale `original` as a conflict (`400`).
    public static func update(
        messageID: MessageID,
        index: Int,
        original: String,
        updated: String,
        isTemporary: Bool? = nil
    ) throws -> APIRequest<ArtifactUpdateResponseDTO> {
        guard messageID.rawValue.isEmpty == false else {
            throw LibreChatProtocolError.encoding("The artifact message ID cannot be empty.")
        }
        guard index >= 0 else {
            throw LibreChatProtocolError.encoding("The artifact index cannot be negative.")
        }
        return try APIRequest<ArtifactUpdateResponseDTO>(
            method: .post,
            path: "api/messages/artifact/\(messageID.rawValue)",
            pathComponents: ["api", "messages", "artifact", messageID.rawValue],
            body: ArtifactUpdateRequestDTO(
                index: index,
                original: original,
                updated: updated,
                isTemporary: isTemporary
            ),
            retryPolicy: .never
        )
    }
}
