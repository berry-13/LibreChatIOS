import Foundation
import LibreChatDomain

/// One LibreChat favorite (pinned target): exactly an agent, an endpoint
/// model pair, or a model spec — mirroring the web client's
/// `useFavorites` canonical shapes.
public enum ChatFavorite: Equatable, Hashable, Sendable {
    case agent(id: String)
    case model(endpoint: String, model: String)
    case spec(name: String)
}

/// LibreChat's `/api/user/settings/favorites` contract. The server accepts
/// at most 50 favorites; each carries exactly one identity shape.
public struct ChatFavoriteDTO: Codable, Equatable, Sendable {
    public var agentId: String?
    public var model: String?
    public var endpoint: String?
    public var spec: String?

    public init(agentId: String? = nil, model: String? = nil, endpoint: String? = nil, spec: String? = nil) {
        self.agentId = agentId
        self.model = model
        self.endpoint = endpoint
        self.spec = spec
    }

    public init(_ favorite: ChatFavorite) throws {
        switch favorite {
        case let .agent(id):
            guard Self.isValidLength(id) else { throw LibreChatProtocolError.encoding("That agent pin is too long.") }
            self.init(agentId: id)
        case let .model(endpoint, model):
            guard Self.isValidLength(endpoint), Self.isValidLength(model) else {
                throw LibreChatProtocolError.encoding("That model pin is too long.")
            }
            self.init(model: model, endpoint: endpoint)
        case let .spec(name):
            guard !name.isEmpty, Self.isValidLength(name) else {
                throw LibreChatProtocolError.encoding("That model-spec pin is invalid.")
            }
            self.init(spec: name)
        }
    }

    /// Permissive read: exactly-one-shape favorites decode; anything the
    /// server should never have accepted is dropped rather than crashing the
    /// whole list.
    public var favorite: ChatFavorite? {
        let hasAgent = agentId?.isEmpty == false
        let hasModel = model?.isEmpty == false && endpoint?.isEmpty == false
        let hasSpec = spec?.isEmpty == false
        let typeCount = [hasAgent, hasModel, hasSpec].filter { $0 }.count
        guard typeCount == 1 else { return nil }
        if hasAgent { return .agent(id: agentId!) }
        if hasSpec { return .spec(name: spec!) }
        guard let endpoint, let model, !endpoint.isEmpty, !model.isEmpty else { return nil }
        return .model(endpoint: endpoint, model: model)
    }

    private static func isValidLength(_ value: String) -> Bool {
        value.count <= 256
    }
}

public enum LibreChatFavoritesAPI {
    public static let maximumCount = 50

    public static func list() -> APIRequest<[ChatFavoriteDTO]> {
        APIRequest<[ChatFavoriteDTO]>(
            path: "api/user/settings/favorites",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    /// Whole-list replacement. The POST is dispatched exactly once: a lost
    /// response is reconciled by the next read, never blindly reposted.
    public static func replace(_ favorites: [ChatFavorite]) throws -> APIRequest<[ChatFavoriteDTO]> {
        guard favorites.count <= maximumCount else {
            throw LibreChatProtocolError.unsupported("LibreChat allows at most \(maximumCount) pinned models and agents.")
        }
        let payloads = try favorites.map { try ChatFavoriteDTO($0) }
        return try APIRequest<[ChatFavoriteDTO]>(
            method: .post,
            path: "api/user/settings/favorites",
            body: FavoritesRequestBodyDTO(favorites: payloads),
            retryPolicy: .never
        )
    }
}

struct FavoritesRequestBodyDTO: Encodable, Equatable, Sendable {
    var favorites: [ChatFavoriteDTO]
}
