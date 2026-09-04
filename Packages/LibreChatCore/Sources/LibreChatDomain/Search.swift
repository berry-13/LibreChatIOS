import Foundation

/// A message returned by LibreChat's account-wide history search.
///
/// Search responses enrich the normal message wire model with conversation
/// metadata. Keeping that metadata beside, rather than inside, `ChatMessage`
/// prevents search-only fields from leaking into the stable message model.
public struct MessageSearchResult: Codable, Equatable, Identifiable, Sendable {
    public var message: ChatMessage
    public var conversationTitle: String
    public var model: String?
    public var endpoint: String?
    public var iconURL: URL?

    public var id: MessageID { message.id }

    public init(
        message: ChatMessage,
        conversationTitle: String,
        model: String? = nil,
        endpoint: String? = nil,
        iconURL: URL? = nil
    ) {
        self.message = message
        self.conversationTitle = conversationTitle
        self.model = model
        self.endpoint = endpoint
        self.iconURL = iconURL
    }
}

public struct MessageSearchPage: Codable, Equatable, Sendable {
    public var results: [MessageSearchResult]
    public var nextCursor: String?
    public var fetchedAt: Date

    public init(
        results: [MessageSearchResult],
        nextCursor: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.results = results
        self.nextCursor = nextCursor
        self.fetchedAt = fetchedAt
    }
}
