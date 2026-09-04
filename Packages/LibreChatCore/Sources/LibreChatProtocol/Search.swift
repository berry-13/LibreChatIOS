import Foundation
import LibreChatDomain

/// Exact request construction for the current LibreChat history-search
/// contract. In particular, account-wide message search does not use the
/// legacy `/api/search?q=` URL.
public enum LibreChatSearchAPI {
    public static func conversations(
        matching query: String,
        cursor: String? = nil,
        limit: Int
    ) -> APIRequest<LibreChatConversationPageDTO> {
        var queryItems = [
            URLQueryItem(name: "search", value: normalized(query)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "isArchived", value: "false"),
            URLQueryItem(name: "sortBy", value: "updatedAt"),
            URLQueryItem(name: "sortDirection", value: "desc")
        ]
        if let cursor, !cursor.isEmpty {
            queryItems.insert(URLQueryItem(name: "cursor", value: cursor), at: 1)
        }
        return APIRequest(
            path: "api/convos",
            queryItems: queryItems,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func messages(
        matching query: String
    ) -> APIRequest<LibreChatMessagePageDTO> {
        APIRequest(
            path: "api/messages",
            queryItems: [URLQueryItem(name: "search", value: normalized(query))],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
