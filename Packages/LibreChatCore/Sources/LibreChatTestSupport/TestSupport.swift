import Foundation
import LibreChatDomain
import LibreChatProtocol

public actor MemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]

    public init() {}

    public func data(for key: String) async throws -> Data? {
        values[key]
    }

    public func set(_ data: Data, for key: String) async throws {
        values[key] = data
    }

    public func remove(_ key: String) async throws {
        values.removeValue(forKey: key)
    }
}

public struct FixtureEventStreamTransport: EventStreamTransport {
    public var eventsToSend: [ServerSentEvent]
    public var terminalError: (any Error & Sendable)?

    public init(events: [ServerSentEvent], terminalError: (any Error & Sendable)? = nil) {
        eventsToSend = events
        self.terminalError = terminalError
    }

    public func events(request: URLRequest) async -> AsyncThrowingStream<ServerSentEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in eventsToSend { continuation.yield(event) }
            if let terminalError {
                continuation.finish(throwing: terminalError)
            } else {
                continuation.finish()
            }
        }
    }
}

public enum LibreChatFixtures {
    public static let profile = ServerProfile(
        id: ServerProfileID(rawValue: "profile-1"),
        baseURL: URL(string: "https://chat.example.com")!,
        displayName: "Example"
    )

    public static let handle = GenerationHandle(
        profileID: profile.id,
        accountID: AccountID(rawValue: "account-1"),
        clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        streamID: "stream-1",
        conversationID: ConversationID(rawValue: "conversation-1"),
        generationCreatedAt: 42,
        protocolVersion: 2
    )
}
