import Foundation
import LibreChatDomain

public struct GenerationSteerSubmitBodyDTO: Codable, Equatable, Sendable {
    public let conversationID: String
    public let generationCreatedAt: Int64
    public let clientSteerID: String
    public let text: String
    public let files: [String]
    public let preempt: Bool
    public let generationProtocolVersion: Int

    public init(
        conversationID: String,
        generationCreatedAt: Int64,
        clientSteerID: String,
        text: String,
        files: [String] = [],
        preempt: Bool,
        generationProtocolVersion: Int
    ) {
        self.conversationID = conversationID
        self.generationCreatedAt = generationCreatedAt
        self.clientSteerID = clientSteerID
        self.text = text
        self.files = files
        self.preempt = preempt
        self.generationProtocolVersion = generationProtocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case text, files, preempt, generationCreatedAt, generationProtocolVersion
        case conversationID = "conversationId"
        case clientSteerID = "clientSteerId"
    }
}

public struct GenerationSteerControlBodyDTO: Codable, Equatable, Sendable {
    public let conversationID: String
    public let generationCreatedAt: Int64
    public let steerID: String
    public let clientSteerID: String
    public let generationProtocolVersion: Int

    public init(
        conversationID: String,
        generationCreatedAt: Int64,
        steerID: String,
        clientSteerID: String,
        generationProtocolVersion: Int
    ) {
        self.conversationID = conversationID
        self.generationCreatedAt = generationCreatedAt
        self.steerID = steerID
        self.clientSteerID = clientSteerID
        self.generationProtocolVersion = generationProtocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case generationCreatedAt, generationProtocolVersion
        case conversationID = "conversationId"
        case steerID = "steerId"
        case clientSteerID = "clientSteerId"
    }
}

public struct GenerationSteerReceiptDTO: Codable, Equatable, Sendable {
    public let status: String?
    public let steerID: String?
    public let position: Int?
    public let conversationID: String?
    public let preempt: Bool?
    public let preemptRevision: Int?
    public let replayed: Bool?
    public let settled: Bool?
    public let leftover: Bool?
    public let generationProtocolVersion: Int?
    /// Not emitted by pinned protocol v2, but a newer server may echo it. If
    /// present it becomes proof and must match the caller-owned coordinate.
    public let clientSteerID: String?

    public init(
        status: String? = nil,
        steerID: String? = nil,
        position: Int? = nil,
        conversationID: String? = nil,
        preempt: Bool? = nil,
        preemptRevision: Int? = nil,
        replayed: Bool? = nil,
        settled: Bool? = nil,
        leftover: Bool? = nil,
        generationProtocolVersion: Int? = nil,
        clientSteerID: String? = nil
    ) {
        self.status = status
        self.steerID = steerID
        self.position = position
        self.conversationID = conversationID
        self.preempt = preempt
        self.preemptRevision = preemptRevision
        self.replayed = replayed
        self.settled = settled
        self.leftover = leftover
        self.generationProtocolVersion = generationProtocolVersion
        self.clientSteerID = clientSteerID
    }

    private enum CodingKeys: String, CodingKey {
        case status, position, preempt, preemptRevision, replayed, settled, leftover
        case steerID = "steerId"
        case conversationID = "conversationId"
        case generationProtocolVersion
        case clientSteerID = "clientSteerId"
    }

    public func domainOutcome(
        statusCode: Int,
        expectedConversationID: ConversationID,
        clientSteerID: String,
        expectedProtocolVersion: Int
    ) throws -> GenerationSteerSubmissionOutcome {
        guard statusCode == 202,
              status == "queued",
              let steerID,
              Self.isBoundedIdentifier(steerID),
              let position,
              position >= 0,
              conversationID == expectedConversationID.rawValue,
              self.clientSteerID.map({ $0 == clientSteerID }) ?? true,
              let preempt,
              generationProtocolVersion == expectedProtocolVersion,
              preemptRevision.map({ $0 >= 0 }) ?? true else {
            throw LibreChatProtocolError.invalidResponse
        }
        let receipt = GenerationSteerReceipt(
            steerID: steerID,
            clientSteerID: clientSteerID,
            position: position,
            conversationID: expectedConversationID,
            preempt: preempt,
            preemptRevision: preemptRevision,
            generationProtocolVersion: expectedProtocolVersion
        )
        if leftover == true {
            guard settled == true, replayed == true else {
                throw LibreChatProtocolError.invalidResponse
            }
            return .leftover(receipt)
        }
        if settled == true {
            guard replayed == true else { throw LibreChatProtocolError.invalidResponse }
            return .settled(receipt)
        }
        if replayed == true { return .replayed(receipt) }
        guard leftover != true, settled != true else {
            throw LibreChatProtocolError.invalidResponse
        }
        return .queued(receipt)
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: true
            default: false
            }
        }
    }
}

public struct GenerationSteerCancelResponseDTO: Codable, Equatable, Sendable {
    public let removed: Bool?
    public let replayed: Bool?
    public let generationProtocolVersion: Int?

    public init(
        removed: Bool? = nil,
        replayed: Bool? = nil,
        generationProtocolVersion: Int? = nil
    ) {
        self.removed = removed
        self.replayed = replayed
        self.generationProtocolVersion = generationProtocolVersion
    }

    public func domainOutcome(
        statusCode: Int,
        expectedProtocolVersion: Int
    ) throws -> GenerationSteerCancelOutcome {
        guard statusCode == 200,
              let removed,
              generationProtocolVersion == expectedProtocolVersion else {
            throw LibreChatProtocolError.invalidResponse
        }
        return removed
            ? .removed(replayed: replayed == true)
            : .notRemoved(replayed: replayed == true)
    }

    /// Terminal discard intentionally has a distinct result type so callers
    /// cannot treat an active-control advisory as permission to delete a
    /// durable recovery record.
    public func recoverableDiscardOutcome(
        statusCode: Int,
        identity: RecoverableSteerIdentity,
        expectedProtocolVersion: Int
    ) throws -> RecoverableSteerDiscardOutcome {
        guard statusCode == 200,
              let removed,
              generationProtocolVersion == expectedProtocolVersion else {
            throw LibreChatProtocolError.invalidResponse
        }
        return removed
            ? .discarded(identity)
            : .notRemoved(replayed: replayed == true)
    }
}

public struct GenerationSteerArmResponseDTO: Codable, Equatable, Sendable {
    public let armed: Bool?
    public let code: String?
    public let preemptRevision: Int?
    public let generationProtocolVersion: Int?

    public init(
        armed: Bool? = nil,
        code: String? = nil,
        preemptRevision: Int? = nil,
        generationProtocolVersion: Int? = nil
    ) {
        self.armed = armed
        self.code = code
        self.preemptRevision = preemptRevision
        self.generationProtocolVersion = generationProtocolVersion
    }

    public func domainOutcome(
        statusCode: Int,
        expectedProtocolVersion: Int
    ) throws -> GenerationSteerArmOutcome {
        guard statusCode == 200,
              let armed,
              generationProtocolVersion == expectedProtocolVersion,
              preemptRevision.map({ $0 >= 0 }) ?? true else {
            throw LibreChatProtocolError.invalidResponse
        }
        if armed {
            guard let preemptRevision else { throw LibreChatProtocolError.invalidResponse }
            return .armed(preemptRevision: preemptRevision)
        }
        let boundedCode: String?
        if let code {
            guard (1...128).contains(code.utf8.count),
                  code.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 48...57, 65...90, 95: true
                      default: false
                      }
                  }) else {
                throw LibreChatProtocolError.invalidResponse
            }
            boundedCode = code
        } else {
            boundedCode = nil
        }
        return .notArmed(code: boundedCode, preemptRevision: preemptRevision)
    }
}

public enum LibreChatSteeringAPI {
    public static let protocolVersion = 2
    public static let protocolHeader = "X-LibreChat-Generation-Protocol"

    public static func submit(
        conversationID: ConversationID,
        generationCreatedAt: Int64,
        clientSteerID: String,
        text: String,
        preempt: Bool
    ) throws -> APIRequest<GenerationSteerReceiptDTO> {
        try APIRequest(
            path: "api/agents/chat/steer",
            headers: [protocolHeader: String(protocolVersion)],
            body: GenerationSteerSubmitBodyDTO(
                conversationID: conversationID.rawValue,
                generationCreatedAt: generationCreatedAt,
                clientSteerID: clientSteerID,
                text: text,
                files: [],
                preempt: preempt,
                generationProtocolVersion: protocolVersion
            ),
            retryPolicy: .never
        )
    }

    public static func cancel(
        conversationID: ConversationID,
        generationCreatedAt: Int64,
        steerID: String,
        clientSteerID: String
    ) throws -> APIRequest<GenerationSteerCancelResponseDTO> {
        try control(
            path: "api/agents/chat/steer/cancel",
            conversationID: conversationID,
            generationCreatedAt: generationCreatedAt,
            steerID: steerID,
            clientSteerID: clientSteerID
        )
    }

    public static func discardRecoverable(
        conversationID: ConversationID,
        generationCreatedAt: Int64,
        identity: RecoverableSteerIdentity
    ) throws -> APIRequest<GenerationSteerCancelResponseDTO> {
        guard let clientSteerID = identity.clientSteerID else {
            throw LibreChatProtocolError.encoding(
                "A terminal steer discard requires the complete recovery identity."
            )
        }
        return try control(
            path: "api/agents/chat/steer/cancel",
            conversationID: conversationID,
            generationCreatedAt: generationCreatedAt,
            steerID: identity.id,
            clientSteerID: clientSteerID
        )
    }

    public static func arm(
        conversationID: ConversationID,
        generationCreatedAt: Int64,
        steerID: String,
        clientSteerID: String
    ) throws -> APIRequest<GenerationSteerArmResponseDTO> {
        try control(
            path: "api/agents/chat/steer/arm",
            conversationID: conversationID,
            generationCreatedAt: generationCreatedAt,
            steerID: steerID,
            clientSteerID: clientSteerID
        )
    }

    private static func control<Response: Decodable & Sendable>(
        path: String,
        conversationID: ConversationID,
        generationCreatedAt: Int64,
        steerID: String,
        clientSteerID: String
    ) throws -> APIRequest<Response> {
        try APIRequest(
            path: path,
            headers: [protocolHeader: String(protocolVersion)],
            body: GenerationSteerControlBodyDTO(
                conversationID: conversationID.rawValue,
                generationCreatedAt: generationCreatedAt,
                steerID: steerID,
                clientSteerID: clientSteerID,
                generationProtocolVersion: protocolVersion
            ),
            retryPolicy: .never
        )
    }
}
