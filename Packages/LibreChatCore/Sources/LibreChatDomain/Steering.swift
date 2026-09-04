import Foundation

/// One caller-owned attempt to add text to an exact active generation.
/// `clientSteerID` is supplied by the caller and must be reused unchanged if
/// an uncertain delivery is explicitly reconciled or retried later.
public struct GenerationSteerRequest: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let conversationID: ConversationID
    public let handle: GenerationHandle
    public let clientSteerID: String
    public let text: String
    public let preempt: Bool

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        handle: GenerationHandle,
        clientSteerID: String,
        text: String,
        preempt: Bool = false
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
        self.handle = handle
        self.clientSteerID = clientSteerID
        self.text = text
        self.preempt = preempt
    }
}

/// Exact server/client steer coordinates bound to one complete generation
/// handle. Cancel and arm never search for or retarget a replacement epoch.
public struct GenerationSteerControlRequest: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let conversationID: ConversationID
    public let handle: GenerationHandle
    public let steerID: String
    public let clientSteerID: String

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        handle: GenerationHandle,
        steerID: String,
        clientSteerID: String
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
        self.handle = handle
        self.steerID = steerID
        self.clientSteerID = clientSteerID
    }
}

/// One caller-owned request to discard a terminally parked steer from the
/// exact generation that still owns it. This is deliberately separate from
/// active-generation cancel: terminal sources must not be looked up by
/// conversation alone or retargeted to a replacement generation.
public struct RecoverableSteerDiscardRequest: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let conversationID: ConversationID
    public let sourceHandle: GenerationHandle
    public let identity: RecoverableSteerIdentity

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID,
        sourceHandle: GenerationHandle,
        identity: RecoverableSteerIdentity
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
        self.sourceHandle = sourceHandle
        self.identity = identity
    }
}

public struct GenerationSteerReceipt: Codable, Equatable, Hashable, Sendable {
    public let steerID: String
    public let clientSteerID: String
    public let position: Int
    public let conversationID: ConversationID
    public let preempt: Bool
    public let preemptRevision: Int?
    public let generationProtocolVersion: Int

    public init(
        steerID: String,
        clientSteerID: String,
        position: Int,
        conversationID: ConversationID,
        preempt: Bool,
        preemptRevision: Int? = nil,
        generationProtocolVersion: Int
    ) {
        self.steerID = steerID
        self.clientSteerID = clientSteerID
        self.position = position
        self.conversationID = conversationID
        self.preempt = preempt
        self.preemptRevision = preemptRevision
        self.generationProtocolVersion = generationProtocolVersion
    }
}

/// A mutation whose request may have reached LibreChat but whose exact
/// acknowledgement could not be proven. This is data, not an invitation to
/// mint another identity or blindly repeat the operation.
public struct SteeringDeliveryUncertainty: Codable, Equatable, Hashable, Sendable {
    public enum Reason: Codable, Equatable, Hashable, Sendable {
        /// The transport ended without an authenticated HTTP acknowledgement.
        case transport
        /// LibreChat returned a server-side failure after the mutation might
        /// already have crossed its commit boundary. `code` is a bounded,
        /// structured protocol code only; response bodies are never retained.
        case server(status: Int, code: String?)
        /// A successful HTTP response could not prove the exact requested
        /// generation/control coordinates.
        case invalidAcknowledgement
    }

    public let clientSteerID: String
    public let steerID: String?
    public let reason: Reason

    public init(clientSteerID: String, steerID: String? = nil, reason: Reason) {
        self.clientSteerID = clientSteerID
        self.steerID = steerID
        self.reason = reason
    }
}

public enum GenerationSteerSubmissionOutcome: Codable, Equatable, Hashable, Sendable {
    case queued(GenerationSteerReceipt)
    case replayed(GenerationSteerReceipt)
    case settled(GenerationSteerReceipt)
    case leftover(GenerationSteerReceipt)
    case deliveryUncertain(SteeringDeliveryUncertainty)
}

public enum GenerationSteerCancelOutcome: Codable, Equatable, Hashable, Sendable {
    case removed(replayed: Bool)
    /// Advisory only: the steer may already be applied, parked, or absent.
    case notRemoved(replayed: Bool)
    case deliveryUncertain(SteeringDeliveryUncertainty)
}

/// Result of asking LibreChat to remove one terminal leftover. Only
/// `.discarded` is proof that permits deleting the exact local recovery copy.
public enum RecoverableSteerDiscardOutcome: Codable, Equatable, Hashable, Sendable {
    case discarded(RecoverableSteerIdentity)
    case notRemoved(replayed: Bool)
    case conflict(code: String?)
    case unauthorized
    case deliveryUncertain(SteeringDeliveryUncertainty)
}

public enum RecoverableSteerDiscardError: Error, Codable, Equatable, Hashable, Sendable {
    case contextMismatch
    case invalidConversation
    case invalidGenerationEpoch
    case protocolMismatch
    case invalidSteerID
    case invalidClientSteerID
    case sourceNotRecoverable
}

public enum GenerationSteerArmOutcome: Codable, Equatable, Hashable, Sendable {
    case armed(preemptRevision: Int)
    /// An advisory race/degradation. `code` preserves values such as
    /// `PREEMPT_UNSUPPORTED`; it does not mean the queued steer was removed.
    case notArmed(code: String?, preemptRevision: Int?)
    case deliveryUncertain(SteeringDeliveryUncertainty)
}

public enum GenerationSteeringError: Error, Codable, Equatable, Hashable, Sendable {
    case contextMismatch
    case invalidConversation
    case invalidGenerationEpoch
    case protocolMismatch
    case inactiveGeneration
    case invalidClientSteerID
    case invalidSteerID
    case emptyText
    case textTooLong(maximumUTF16Length: Int)
}
