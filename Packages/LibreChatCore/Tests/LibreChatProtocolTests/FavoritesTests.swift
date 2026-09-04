import Testing
import Foundation
@testable import LibreChatProtocol

struct FavoritesTests {
    @Test func favoriteDTOEncodesEachCanonicalShape() throws {
        let agent = try JSONEncoder().encode(ChatFavoriteDTO(ChatFavorite.agent(id: "agent-1")))
        #expect(String(decoding: agent, as: UTF8.self) == #"{"agentId":"agent-1"}"#)

        let model = try JSONEncoder().encode(ChatFavoriteDTO(ChatFavorite.model(endpoint: "openAI", model: "gpt-5")))
        let modelObject = try #require(JSONSerialization.jsonObject(with: model) as? [String: String])
        #expect(modelObject["endpoint"] == "openAI")
        #expect(modelObject["model"] == "gpt-5")
        #expect(modelObject.keys.count == 2)

        let spec = try JSONEncoder().encode(ChatFavoriteDTO(ChatFavorite.spec(name: "research")))
        #expect(String(decoding: spec, as: UTF8.self) == #"{"spec":"research"}"#)
    }

    @Test func favoriteDTODecodeDropsNonCanonicalShapes() throws {
        let payload = #"""
        [
          {"agentId":"agent-1"},
          {"model":"gpt-5","endpoint":"openAI"},
          {"spec":"research"},
          {"agentId":"a","model":"m","endpoint":"e"},
          {"model":"partial"},
          {}
        ]
        """#
        let decoded = try JSONDecoder().decode([ChatFavoriteDTO].self, from: Data(payload.utf8))
        let favorites = decoded.compactMap(\.favorite)
        #expect(favorites == [
            .agent(id: "agent-1"),
            .model(endpoint: "openAI", model: "gpt-5"),
            .spec(name: "research"),
        ])
    }

    @Test func replaceRequestPostsWholeListOnceAndEnforcesTheServerLimit() throws {
        let request = try LibreChatFavoritesAPI.replace([
            .agent(id: "agent-1"),
            .model(endpoint: "openAI", model: "gpt-5"),
        ])
        #expect(request.method == .post)
        #expect(request.path == "api/user/settings/favorites")
        #expect(request.retryPolicy == .never)
        #expect(request.authorization == .bearer)
        let body = try #require(JSONSerialization.jsonObject(with: request.body!) as? [String: Any])
        let favorites = try #require(body["favorites"] as? [[String: Any]])
        #expect(favorites.count == 2)

        let tooMany = (0..<LibreChatFavoritesAPI.maximumCount + 1).map { ChatFavorite.spec(name: "spec-\($0)") }
        #expect(throws: (any Error).self) {
            _ = try LibreChatFavoritesAPI.replace(tooMany)
        }
    }

    @Test func listRequestIsAnAuthenticatedIdempotentRead() {
        let request = LibreChatFavoritesAPI.list()
        #expect(request.method == .get)
        #expect(request.path == "api/user/settings/favorites")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func oversizeOrEmptyIdentitiesAreRejectedBeforeEncoding() {
        #expect(throws: LibreChatProtocolError.self) {
            _ = try ChatFavoriteDTO(.agent(id: String(repeating: "a", count: 257)))
        }
        #expect(throws: LibreChatProtocolError.self) {
            _ = try ChatFavoriteDTO(.spec(name: ""))
        }
    }
}
