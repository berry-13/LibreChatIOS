import Foundation

/// The exact authenticated conversation namespace that owns one follow-up queue.
/// A queue is never shared across profiles, accounts, or conversations.
public struct FollowUpQueueNamespace: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let conversationID: ConversationID

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        conversationID: ConversationID
    ) throws {
        guard Self.isSafeNamespaceComponent(profileID.rawValue),
              Self.isSafeNamespaceComponent(accountID.rawValue)
        else {
            throw FollowUpQueueError.invalidNamespace
        }
        guard Self.isPersistedConversation(conversationID) else {
            throw FollowUpQueueError.invalidConversation
        }
        self.profileID = profileID
        self.accountID = accountID
        self.conversationID = conversationID
    }

    public func owns(_ handle: GenerationHandle) -> Bool {
        profileID == handle.profileID
            && accountID == handle.accountID
            && conversationID == handle.conversationID
    }

    private static func isPersistedConversation(_ id: ConversationID) -> Bool {
        let value = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSafeNamespaceComponent(value) && !id.isLocalDraft
    }

    /// Queue journals currently use a delimiter-based cache namespace. Reject
    /// the delimiter and control characters at the domain boundary so two
    /// different profile/account/conversation tuples cannot alias one record.
    private static func isSafeNamespaceComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == value, !value.contains("|") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case profileID, accountID, conversationID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                profileID: container.decode(ServerProfileID.self, forKey: .profileID),
                accountID: container.decode(AccountID.self, forKey: .accountID),
                conversationID: container.decode(ConversationID.self, forKey: .conversationID)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .conversationID,
                in: container,
                debugDescription: "Invalid follow-up queue namespace."
            )
        }
    }
}

public struct FollowUpQueueItemID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A durable, caller-owned ordering coordinate. Order values must be unique in
/// one snapshot; restore never derives position from the current last item.
public struct FollowUpQueueOrder: RawRepresentable, Codable, Comparable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Routing that must remain byte-for-byte equivalent between enqueue and
/// admission. The mutable branch parent is intentionally represented by the
/// source anchor instead of being hidden in this fingerprint.
public struct FollowUpTargetFingerprint: Codable, Equatable, Hashable, Sendable {
    public let endpoint: String
    public let endpointType: String?
    public let model: String?
    public let agentID: String?
    public let assistantID: String?
    public let spec: String?
    public let promptPrefix: String?
    public let ephemeralAgent: EphemeralAgentConfiguration?

    public init(target: ConversationTarget) throws {
        try self.init(
            endpoint: target.endpoint,
            endpointType: target.endpointType,
            model: target.model,
            agentID: target.agentID,
            assistantID: target.assistantID,
            spec: target.spec,
            promptPrefix: target.promptPrefix,
            ephemeralAgent: target.ephemeralAgent
        )
    }

    public init(
        endpoint: String,
        endpointType: String? = nil,
        model: String? = nil,
        agentID: String? = nil,
        assistantID: String? = nil,
        spec: String? = nil,
        promptPrefix: String? = nil,
        ephemeralAgent: EphemeralAgentConfiguration? = nil
    ) throws {
        guard GenerationEndpointPolicy.route(
                endpoint: endpoint,
                endpointType: endpointType
              ).supportsResumableV2,
              !Self.containsNUL(endpoint),
              [endpointType, model, agentID, assistantID, spec, promptPrefix]
                .compactMap({ $0 })
                .allSatisfy({ !Self.containsNUL($0) }),
              ephemeralAgent?.isSafeForRequest != false
        else {
            throw FollowUpQueueError.invalidTarget
        }
        self.endpoint = endpoint
        self.endpointType = endpointType
        self.model = model
        self.agentID = agentID
        self.assistantID = assistantID
        self.spec = spec
        self.promptPrefix = promptPrefix
        self.ephemeralAgent = ephemeralAgent
    }

    private static func containsNUL(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, endpointType, model, agentID, assistantID, spec, promptPrefix, ephemeralAgent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                endpoint: container.decode(String.self, forKey: .endpoint),
                endpointType: container.decodeIfPresent(String.self, forKey: .endpointType),
                model: container.decodeIfPresent(String.self, forKey: .model),
                agentID: container.decodeIfPresent(String.self, forKey: .agentID),
                assistantID: container.decodeIfPresent(String.self, forKey: .assistantID),
                spec: container.decodeIfPresent(String.self, forKey: .spec),
                promptPrefix: container.decodeIfPresent(String.self, forKey: .promptPrefix),
                ephemeralAgent: container.decodeIfPresent(
                    EphemeralAgentConfiguration.self,
                    forKey: .ephemeralAgent
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .endpoint,
                in: container,
                debugDescription: "Invalid follow-up target fingerprint."
            )
        }
    }
}

/// A queue-owned uploaded file. The local upload coordinate keeps device-side
/// hold/refcount ownership separate from the server's canonical file identity.
/// Metadata is retained for the eventual generation body, while equality of a
/// recovered durable row is based on the canonical server file ID set.
public struct FollowUpQueuedAttachment: Codable, Equatable, Hashable, Sendable {
    public let uploadID: UUID
    public let file: UploadedFile

    public init(uploadID: UUID, file: UploadedFile) throws {
        let fileID = file.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileID.isEmpty,
              fileID == file.id,
              !fileID.unicodeScalars.contains(where: { $0.value == 0 }),
              !file.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw FollowUpQueueError.invalidAttachment
        }
        self.uploadID = uploadID
        self.file = file
    }

    private enum CodingKeys: String, CodingKey { case uploadID, file }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                uploadID: container.decode(UUID.self, forKey: .uploadID),
                file: container.decode(UploadedFile.self, forKey: .file)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .file,
                in: container,
                debugDescription: "Invalid queued attachment."
            )
        }
    }
}

/// The exact generation whose clean completion is allowed to release a queue
/// item, plus the persisted user message that owns that response branch.
public struct FollowUpSourceAnchor: Codable, Equatable, Hashable, Sendable {
    public let handle: GenerationHandle
    public let sourceUserMessageID: MessageID

    public init(handle: GenerationHandle, sourceUserMessageID: MessageID) throws {
        guard Self.isValidV2Handle(handle) else {
            throw FollowUpQueueError.invalidGenerationHandle
        }
        guard Self.isPersistedMessage(sourceUserMessageID) else {
            throw FollowUpQueueError.invalidMessageID
        }
        self.handle = handle
        self.sourceUserMessageID = sourceUserMessageID
    }

    fileprivate static func isValidV2Handle(_ handle: GenerationHandle) -> Bool {
        guard handle.protocolVersion == 2,
              let epoch = handle.generationCreatedAt,
              epoch >= 0,
              !handle.profileID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !handle.accountID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !handle.conversationID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !handle.conversationID.isLocalDraft,
              !handle.streamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    fileprivate static func isPersistedMessage(_ id: MessageID) -> Bool {
        let value = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != "new",
              !value.hasPrefix("local-"),
              value != "NO_PARENT",
              value != "00000000-0000-0000-0000-000000000000"
        else { return false }
        return !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private enum CodingKeys: String, CodingKey {
        case handle, sourceUserMessageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                handle: container.decode(GenerationHandle.self, forKey: .handle),
                sourceUserMessageID: container.decode(MessageID.self, forKey: .sourceUserMessageID)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .handle,
                in: container,
                debugDescription: "Invalid follow-up source anchor."
            )
        }
    }
}

/// Exact ownership coordinates for text recovered from a terminal v2 steer.
/// Both the server ID and caller ID are required; partial legacy identities do
/// not silently become a new follow-up.
public struct FollowUpRecoverableSource: Codable, Equatable, Hashable, Sendable {
    public let handle: GenerationHandle
    public let identity: RecoverableSteerIdentity

    public init(handle: GenerationHandle, identity: RecoverableSteerIdentity) throws {
        guard FollowUpSourceAnchor.isValidV2Handle(handle) else {
            throw FollowUpQueueError.invalidGenerationHandle
        }
        guard Self.isValidServerIdentity(identity.id),
              let clientID = identity.clientSteerID,
              Self.isValidClientIdentity(clientID)
        else {
            throw FollowUpQueueError.invalidRecoverableSource
        }
        self.handle = handle
        self.identity = identity
    }

    private static func isValidServerIdentity(_ value: String) -> Bool {
        isValidIdentity(value, allowsColon: true)
    }

    private static func isValidClientIdentity(_ value: String) -> Bool {
        isValidIdentity(value, allowsColon: false)
    }

    private static func isValidIdentity(_ value: String, allowsColon: Bool) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: true
            case 58: allowsColon
            default: false
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case handle, identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                handle: container.decode(GenerationHandle.self, forKey: .handle),
                identity: container.decode(RecoverableSteerIdentity.self, forKey: .identity)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .identity,
                in: container,
                debugDescription: "Invalid recoverable follow-up source."
            )
        }
    }
}

/// Neighbor coordinates captured before admission. A definitive rejection or
/// handoff restores the same item at this stable slot; it is never appended to
/// whatever happens to be last at restore time.
public struct FollowUpQueueSlot: Codable, Equatable, Hashable, Sendable {
    public let previousItemID: FollowUpQueueItemID?
    public let nextItemID: FollowUpQueueItemID?

    public init(
        previousItemID: FollowUpQueueItemID?,
        nextItemID: FollowUpQueueItemID?
    ) throws {
        guard previousItemID == nil || previousItemID != nextItemID else {
            throw FollowUpQueueError.invalidSlot
        }
        self.previousItemID = previousItemID
        self.nextItemID = nextItemID
    }
}

/// The semantic request body and all ownership coordinates frozen at reserve
/// time. An uncertain admission retains this fingerprint and its request IDs.
public struct FollowUpAttemptFingerprint: Codable, Equatable, Hashable, Sendable {
    public let namespace: FollowUpQueueNamespace
    public let itemID: FollowUpQueueItemID
    public let order: FollowUpQueueOrder
    public let text: String
    public let attachments: [FollowUpQueuedAttachment]
    public let target: FollowUpTargetFingerprint
    public let sourceAnchor: FollowUpSourceAnchor
    public let parentMessageID: MessageID
    public let recoverableSource: FollowUpRecoverableSource?

    public init(
        namespace: FollowUpQueueNamespace,
        itemID: FollowUpQueueItemID,
        order: FollowUpQueueOrder,
        text: String,
        attachments: [FollowUpQueuedAttachment] = [],
        target: FollowUpTargetFingerprint,
        sourceAnchor: FollowUpSourceAnchor,
        parentMessageID: MessageID,
        recoverableSource: FollowUpRecoverableSource? = nil
    ) throws {
        guard namespace.owns(sourceAnchor.handle) else {
            throw FollowUpQueueError.contextMismatch
        }
        guard FollowUpSourceAnchor.isPersistedMessage(parentMessageID) else {
            throw FollowUpQueueError.invalidMessageID
        }
        try Self.validateText(text)
        try Self.validateAttachments(attachments)
        if let recoverableSource, !namespace.owns(recoverableSource.handle) {
            throw FollowUpQueueError.contextMismatch
        }
        self.namespace = namespace
        self.itemID = itemID
        self.order = order
        self.text = text
        self.attachments = attachments
        self.target = target
        self.sourceAnchor = sourceAnchor
        self.parentMessageID = parentMessageID
        self.recoverableSource = recoverableSource
    }

    fileprivate static func validateText(_ text: String) throws {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FollowUpQueueError.invalidText
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == text else {
            throw FollowUpQueueError.invalidText
        }
        guard text.utf16.count <= 16_000 else {
            throw FollowUpQueueError.textTooLong(maximumUTF16Length: 16_000)
        }
    }

    fileprivate static func validateAttachments(
        _ attachments: [FollowUpQueuedAttachment]
    ) throws {
        guard Set(attachments.map(\.uploadID)).count == attachments.count,
              Set(attachments.map { $0.file.id }).count == attachments.count
        else {
            throw FollowUpQueueError.duplicateAttachment
        }
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, itemID, order, text, attachments, target, sourceAnchor, parentMessageID
        case recoverableSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                namespace: container.decode(FollowUpQueueNamespace.self, forKey: .namespace),
                itemID: container.decode(FollowUpQueueItemID.self, forKey: .itemID),
                order: container.decode(FollowUpQueueOrder.self, forKey: .order),
                text: container.decode(String.self, forKey: .text),
                attachments: container.decodeIfPresent(
                    [FollowUpQueuedAttachment].self,
                    forKey: .attachments
                ) ?? [],
                target: container.decode(FollowUpTargetFingerprint.self, forKey: .target),
                sourceAnchor: container.decode(FollowUpSourceAnchor.self, forKey: .sourceAnchor),
                parentMessageID: container.decode(MessageID.self, forKey: .parentMessageID),
                recoverableSource: container.decodeIfPresent(
                    FollowUpRecoverableSource.self,
                    forKey: .recoverableSource
                )
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .itemID,
                in: container,
                debugDescription: "Invalid follow-up attempt fingerprint."
            )
        }
    }
}

public struct FollowUpAdmissionAttempt: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let clientRequestID: UUID
    public let clientMessageID: MessageID
    public let fingerprint: FollowUpAttemptFingerprint
    public let slot: FollowUpQueueSlot

    public init(
        id: UUID,
        clientRequestID: UUID,
        clientMessageID: MessageID,
        fingerprint: FollowUpAttemptFingerprint,
        slot: FollowUpQueueSlot
    ) throws {
        guard FollowUpSourceAnchor.isPersistedMessage(clientMessageID) else {
            throw FollowUpQueueError.invalidMessageID
        }
        guard clientMessageID != fingerprint.sourceAnchor.sourceUserMessageID,
              clientMessageID != fingerprint.parentMessageID else {
            throw FollowUpQueueError.messageIdentityCollision
        }
        if let recoverableSource = fingerprint.recoverableSource,
           clientMessageID.rawValue != recoverableSource.identity.id {
            throw FollowUpQueueError.recoverableClientMessageMismatch
        }
        self.id = id
        self.clientRequestID = clientRequestID
        self.clientMessageID = clientMessageID
        self.fingerprint = fingerprint
        self.slot = slot
    }

    private enum CodingKeys: String, CodingKey {
        case id, clientRequestID, clientMessageID, fingerprint, slot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                clientRequestID: container.decode(UUID.self, forKey: .clientRequestID),
                clientMessageID: container.decode(MessageID.self, forKey: .clientMessageID),
                fingerprint: container.decode(FollowUpAttemptFingerprint.self, forKey: .fingerprint),
                slot: container.decode(FollowUpQueueSlot.self, forKey: .slot)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .fingerprint,
                in: container,
                debugDescription: "Invalid follow-up admission attempt."
            )
        }
    }
}

public enum FollowUpQueueBlockReason: String, Codable, Equatable, Hashable, Sendable {
    case targetChanged
    case sourceUnavailable
    case predecessorUnverified
    case requiresUserReview
}

public enum FollowUpDeliveryUncertaintyReason: Codable, Equatable, Hashable, Sendable {
    case transport
    case server(status: Int)
    case invalidAcknowledgement
}

public enum FollowUpDeliveredTerminal: Codable, Equatable, Hashable, Sendable {
    case completed(responseMessageID: MessageID)
    case aborted
    case failed
    case superseded
}

public enum FollowUpQueueItemState: Codable, Equatable, Hashable, Sendable {
    case queued
    case reserved(FollowUpAdmissionAttempt)
    case admitted(attempt: FollowUpAdmissionAttempt, handle: GenerationHandle)
    case blocked(FollowUpQueueBlockReason)
    case deliveryUncertain(
        attempt: FollowUpAdmissionAttempt,
        reason: FollowUpDeliveryUncertaintyReason
    )
    /// The exact user row is durably present, but no attachable generation
    /// epoch was returned. This remains lane-occupying until later
    /// reconciliation proves the resulting generation; followers must not
    /// drain behind the old predecessor.
    case committed(FollowUpAdmissionAttempt)
    /// Authoritative history proves the exact committed user row and one
    /// clean direct assistant response, but the server no longer retains a
    /// generation epoch. The item itself is complete; followers remain
    /// blocked because no predecessor fence can be manufactured safely.
    case deliveredWithoutEpoch(
        attempt: FollowUpAdmissionAttempt,
        responseMessageID: MessageID
    )
    case delivered(
        attempt: FollowUpAdmissionAttempt,
        handle: GenerationHandle,
        terminal: FollowUpDeliveredTerminal
    )

    fileprivate var laneIsOccupied: Bool {
        switch self {
        case .reserved, .admitted, .deliveryUncertain, .committed: true
        case .queued, .blocked, .deliveredWithoutEpoch, .delivered: false
        }
    }
}

public struct FollowUpQueueItem: Codable, Equatable, Hashable, Sendable {
    public let id: FollowUpQueueItemID
    public let namespace: FollowUpQueueNamespace
    public private(set) var order: FollowUpQueueOrder
    public private(set) var text: String
    public let attachments: [FollowUpQueuedAttachment]
    public let target: FollowUpTargetFingerprint
    public private(set) var sourceAnchor: FollowUpSourceAnchor
    public let recoverableSource: FollowUpRecoverableSource?
    public private(set) var state: FollowUpQueueItemState

    public init(
        id: FollowUpQueueItemID,
        namespace: FollowUpQueueNamespace,
        order: FollowUpQueueOrder,
        text: String,
        attachments: [FollowUpQueuedAttachment] = [],
        target: FollowUpTargetFingerprint,
        sourceAnchor: FollowUpSourceAnchor,
        recoverableSource: FollowUpRecoverableSource? = nil,
        state: FollowUpQueueItemState = .queued
    ) throws {
        try FollowUpAttemptFingerprint.validateText(text)
        try FollowUpAttemptFingerprint.validateAttachments(attachments)
        guard namespace.owns(sourceAnchor.handle) else {
            throw FollowUpQueueError.contextMismatch
        }
        if let recoverableSource {
            guard namespace.owns(recoverableSource.handle),
                  let recoveryEpoch = recoverableSource.handle.generationCreatedAt,
                  let anchorEpoch = sourceAnchor.handle.generationCreatedAt,
                  recoveryEpoch <= anchorEpoch
            else {
                throw FollowUpQueueError.contextMismatch
            }
        }
        self.id = id
        self.namespace = namespace
        self.order = order
        self.text = text
        self.attachments = attachments
        self.target = target
        self.sourceAnchor = sourceAnchor
        self.recoverableSource = recoverableSource
        self.state = state
        try validateState()
    }

    fileprivate mutating func setState(_ state: FollowUpQueueItemState) throws {
        self.state = state
        try validateState()
    }

    fileprivate mutating func rebaseSource(to sourceAnchor: FollowUpSourceAnchor) throws {
        guard namespace.owns(sourceAnchor.handle) else {
            throw FollowUpQueueError.contextMismatch
        }
        self.sourceAnchor = sourceAnchor
        try validateState()
    }

    fileprivate mutating func editQueuedText(_ text: String) throws {
        guard case .queued = state else {
            throw FollowUpQueueError.invalidTransition
        }
        try FollowUpAttemptFingerprint.validateText(text)
        self.text = text
    }

    fileprivate mutating func assignQueuedOrder(_ order: FollowUpQueueOrder) throws {
        guard case .queued = state else {
            throw FollowUpQueueError.invalidTransition
        }
        self.order = order
    }

    fileprivate func validateState() throws {
        func validate(_ attempt: FollowUpAdmissionAttempt) throws {
            let fingerprint = attempt.fingerprint
            guard fingerprint.namespace == namespace,
                  fingerprint.itemID == id,
                  fingerprint.order == order,
                  fingerprint.text == text,
                  fingerprint.attachments == attachments,
                  fingerprint.target == target,
                  fingerprint.sourceAnchor == sourceAnchor,
                  fingerprint.recoverableSource == recoverableSource
            else {
                throw FollowUpQueueError.attemptMismatch
            }
            guard attempt.slot.previousItemID != id,
                  attempt.slot.nextItemID != id
            else {
                throw FollowUpQueueError.invalidSlot
            }
        }

        switch state {
        case .queued, .blocked:
            break
        case let .reserved(attempt), let .committed(attempt):
            try validate(attempt)
        case let .deliveredWithoutEpoch(attempt, responseMessageID):
            try validate(attempt)
            guard FollowUpSourceAnchor.isPersistedMessage(responseMessageID) else {
                throw FollowUpQueueError.invalidMessageID
            }
        case let .deliveryUncertain(attempt, reason):
            try validate(attempt)
            if case let .server(status) = reason, !(500...599).contains(status) {
                throw FollowUpQueueError.invalidUncertainty
            }
        case let .admitted(attempt, handle), let .delivered(attempt, handle, _):
            try validate(attempt)
            try Self.validateAcceptedHandle(handle, attempt: attempt)
        }
    }

    private static func validateAcceptedHandle(
        _ handle: GenerationHandle,
        attempt: FollowUpAdmissionAttempt
    ) throws {
        let predecessor = attempt.fingerprint.sourceAnchor.handle
        guard attempt.fingerprint.namespace.owns(handle),
              FollowUpSourceAnchor.isValidV2Handle(handle),
              handle.clientRequestID == attempt.clientRequestID,
              let predecessorEpoch = predecessor.generationCreatedAt,
              let acceptedEpoch = handle.generationCreatedAt,
              acceptedEpoch > predecessorEpoch
        else {
            throw FollowUpQueueError.invalidAcceptedHandle
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, namespace, order, text, attachments, target, sourceAnchor, recoverableSource, state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(FollowUpQueueItemID.self, forKey: .id),
                namespace: container.decode(FollowUpQueueNamespace.self, forKey: .namespace),
                order: container.decode(FollowUpQueueOrder.self, forKey: .order),
                text: container.decode(String.self, forKey: .text),
                attachments: container.decodeIfPresent(
                    [FollowUpQueuedAttachment].self,
                    forKey: .attachments
                ) ?? [],
                target: container.decode(FollowUpTargetFingerprint.self, forKey: .target),
                sourceAnchor: container.decode(FollowUpSourceAnchor.self, forKey: .sourceAnchor),
                recoverableSource: container.decodeIfPresent(
                    FollowUpRecoverableSource.self,
                    forKey: .recoverableSource
                ),
                state: container.decode(FollowUpQueueItemState.self, forKey: .state)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Invalid follow-up queue item."
            )
        }
    }
}

/// Generation evidence presented to the queue. Only `.completed` is a drain
/// authorization; every other case is intentionally non-draining.
public enum FollowUpGenerationSignal: Equatable, Hashable, Sendable {
    case completed(handle: GenerationHandle, responseMessageID: MessageID)
    case aborted(handle: GenerationHandle)
    case failed(handle: GenerationHandle)
    case superseded(handle: GenerationHandle)
    case awaitingInteraction(handle: GenerationHandle)
    case ambiguous(handle: GenerationHandle)

    public var handle: GenerationHandle {
        switch self {
        case let .completed(handle, _),
             let .aborted(handle),
             let .failed(handle),
             let .superseded(handle),
             let .awaitingInteraction(handle),
             let .ambiguous(handle):
            handle
        }
    }
}

/// Separately proven winner coordinates used after a generation-start handoff.
/// The queued request was not accepted, so the same item is restored and made
/// eligible only after this exact winner completes cleanly.
public struct FollowUpHandoffRebase: Equatable, Hashable, Sendable {
    public let winnerHandle: GenerationHandle
    public let winnerUserMessageID: MessageID

    public init(winnerHandle: GenerationHandle, winnerUserMessageID: MessageID) {
        self.winnerHandle = winnerHandle
        self.winnerUserMessageID = winnerUserMessageID
    }
}

public struct FollowUpQueueSnapshot: Codable, Equatable, Sendable {
    public let namespace: FollowUpQueueNamespace
    public let items: [FollowUpQueueItem]

    public init(
        namespace: FollowUpQueueNamespace,
        items: [FollowUpQueueItem] = []
    ) throws {
        let sorted = items.sorted { $0.order < $1.order }
        guard sorted.allSatisfy({ $0.namespace == namespace }) else {
            throw FollowUpQueueError.contextMismatch
        }
        guard Set(sorted.map(\.id)).count == sorted.count else {
            throw FollowUpQueueError.duplicateItemID
        }
        guard Set(sorted.map(\.order)).count == sorted.count else {
            throw FollowUpQueueError.duplicateOrder
        }
        guard sorted.filter({ $0.state.laneIsOccupied }).count <= 1 else {
            throw FollowUpQueueError.multipleActiveReservations
        }
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        for item in sorted {
            try item.validateState()
            guard item.state.laneIsOccupied,
                  let attempt = item.state.attempt
            else { continue }
            if let previous = attempt.slot.previousItemID {
                guard let previousItem = byID[previous], previousItem.order < item.order else {
                    throw FollowUpQueueError.invalidSlot
                }
            }
            if let next = attempt.slot.nextItemID {
                guard let nextItem = byID[next], item.order < nextItem.order else {
                    throw FollowUpQueueError.invalidSlot
                }
            }
        }
        self.namespace = namespace
        self.items = sorted
    }

    private enum CodingKeys: String, CodingKey {
        case namespace, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                namespace: container.decode(FollowUpQueueNamespace.self, forKey: .namespace),
                items: container.decode([FollowUpQueueItem].self, forKey: .items)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .items,
                in: container,
                debugDescription: "Invalid follow-up queue snapshot."
            )
        }
    }
}

private extension FollowUpQueueItemState {
    var attempt: FollowUpAdmissionAttempt? {
        switch self {
        case let .reserved(attempt),
             let .admitted(attempt, _),
             let .deliveryUncertain(attempt, _),
             let .committed(attempt),
             let .deliveredWithoutEpoch(attempt, _),
             let .delivered(attempt, _, _):
            attempt
        case .queued, .blocked:
            nil
        }
    }
}

/// A deterministic, side-effect-free state machine. Callers persist snapshots
/// and perform network operations outside this value.
public struct FollowUpQueueReducer: Sendable {
    public private(set) var snapshot: FollowUpQueueSnapshot

    public init(snapshot: FollowUpQueueSnapshot) {
        self.snapshot = snapshot
    }

    public init(namespace: FollowUpQueueNamespace) throws {
        snapshot = try FollowUpQueueSnapshot(namespace: namespace)
    }

    public mutating func enqueue(_ item: FollowUpQueueItem) throws {
        guard item.namespace == snapshot.namespace else {
            throw FollowUpQueueError.contextMismatch
        }
        guard item.state == .queued else {
            throw FollowUpQueueError.invalidTransition
        }
        guard !snapshot.items.contains(where: { $0.id == item.id }) else {
            throw FollowUpQueueError.duplicateItemID
        }
        guard !snapshot.items.contains(where: { $0.order == item.order }) else {
            throw FollowUpQueueError.duplicateOrder
        }
        try replaceItems(snapshot.items + [item])
    }

    /// Edits only the text of an item that has not crossed an admission
    /// boundary. Identity, source ownership, target, and order are preserved.
    public mutating func editQueued(
        itemID: FollowUpQueueItemID,
        text: String
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        try items[index].editQueuedText(text)
        try replaceItems(items)
    }

    /// Removes an untouched queued item or a definitively rejected review
    /// item. Admission/uncertainty journal states are never collapsed into an
    /// apparent local cancellation.
    public mutating func removeQueued(itemID: FollowUpQueueItemID) throws {
        let index = try requireIndex(of: itemID)
        switch snapshot.items[index].state {
        case .queued, .blocked:
            break
        case .reserved, .admitted, .deliveryUncertain, .committed,
             .deliveredWithoutEpoch, .delivered:
            throw FollowUpQueueError.invalidTransition
        }
        var items = snapshot.items
        items.remove(at: index)
        try replaceItems(items)
    }

    /// Atomically replaces the complete queued FIFO order. Existing order
    /// coordinates are reassigned instead of manufacturing clock-derived
    /// positions, making the result deterministic across restore.
    public mutating func reorderQueued(
        itemIDs: [FollowUpQueueItemID]
    ) throws {
        guard !snapshot.items.contains(where: { $0.state.laneIsOccupied }) else {
            throw FollowUpQueueError.invalidTransition
        }
        let queued = snapshot.items.filter { $0.state == .queued }
        guard Set(itemIDs).count == itemIDs.count,
              Set(itemIDs) == Set(queued.map(\.id))
        else {
            throw FollowUpQueueError.invalidReorder
        }
        let availableOrders = queued.map(\.order).sorted()
        var orderByID: [FollowUpQueueItemID: FollowUpQueueOrder] = [:]
        for (id, order) in zip(itemIDs, availableOrders) {
            orderByID[id] = order
        }
        var items = snapshot.items
        for index in items.indices {
            guard let order = orderByID[items[index].id] else { continue }
            try items[index].assignQueuedOrder(order)
        }
        try replaceItems(items)
    }

    /// Reserves the FIFO head once. Concurrent or repeated triggers observe an
    /// occupied lane and return `nil` rather than minting a second admission.
    public mutating func reserveNext(
        after signal: FollowUpGenerationSignal,
        attemptID: UUID,
        clientRequestID: UUID,
        clientMessageID: MessageID
    ) throws -> FollowUpAdmissionAttempt? {
        try validateSignalHandle(signal.handle)
        guard !snapshot.items.contains(where: { $0.state.laneIsOccupied }) else {
            return nil
        }
        guard case let .completed(handle, responseMessageID) = signal else {
            return nil
        }
        guard FollowUpSourceAnchor.isPersistedMessage(responseMessageID),
              FollowUpSourceAnchor.isPersistedMessage(clientMessageID)
        else {
            throw FollowUpQueueError.invalidMessageID
        }

        let live = snapshot.items.filter { item in
            if case .delivered = item.state { return false }
            if case .deliveredWithoutEpoch = item.state { return false }
            return true
        }
        guard let head = live.first else { return nil }
        guard case .queued = head.state,
              head.sourceAnchor.handle == handle
        else { return nil }

        if let prior = snapshot.items.first(where: { item in
            guard case let .delivered(_, deliveredHandle, _) = item.state else { return false }
            return deliveredHandle == handle
        }) {
            guard case let .delivered(_, _, .completed(provenResponse)) = prior.state,
                  provenResponse == responseMessageID
            else { return nil }
        }

        let headIndex = try requireIndex(of: head.id)
        let liveIndex = try requireLiveIndex(of: head.id, in: live)
        let slot = try FollowUpQueueSlot(
            previousItemID: liveIndex > 0 ? live[liveIndex - 1].id : nil,
            nextItemID: liveIndex + 1 < live.count ? live[liveIndex + 1].id : nil
        )
        let fingerprint = try FollowUpAttemptFingerprint(
            namespace: head.namespace,
            itemID: head.id,
            order: head.order,
            text: head.text,
            attachments: head.attachments,
            target: head.target,
            sourceAnchor: head.sourceAnchor,
            parentMessageID: responseMessageID,
            recoverableSource: head.recoverableSource
        )
        let attempt = try FollowUpAdmissionAttempt(
            id: attemptID,
            clientRequestID: clientRequestID,
            clientMessageID: clientMessageID,
            fingerprint: fingerprint,
            slot: slot
        )
        var items = snapshot.items
        try items[headIndex].setState(.reserved(attempt))
        try replaceItems(items)
        return attempt
    }

    public mutating func markDeliveryUncertain(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        reason: FollowUpDeliveryUncertaintyReason
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case let .reserved(attempt) = items[index].state,
              attempt.id == attemptID
        else {
            throw FollowUpQueueError.invalidTransition
        }
        try items[index].setState(.deliveryUncertain(attempt: attempt, reason: reason))
        try replaceItems(items)
    }

    /// Atomically converts a preflight-invalid reservation into a review
    /// state. No intermediate queued snapshot is ever persisted, so a
    /// concurrent completion trigger cannot reserve the same item again.
    public mutating func blockReserved(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        reason: FollowUpQueueBlockReason
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case let .reserved(attempt) = items[index].state,
              attempt.id == attemptID else {
            throw FollowUpQueueError.invalidTransition
        }
        try items[index].setState(.queued)
        try items[index].setState(.blocked(reason))
        try replaceItems(items)
    }

    /// Records exact durable user-row proof for a receipt that supplied no
    /// attachable generation handle. The lane stays occupied and the original
    /// request identity stays frozen for later reconciliation.
    public mutating func confirmDurableAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        let attempt: FollowUpAdmissionAttempt
        switch items[index].state {
        case let .reserved(value), let .deliveryUncertain(value, _):
            attempt = value
        default:
            throw FollowUpQueueError.invalidTransition
        }
        guard attempt.id == attemptID else {
            throw FollowUpQueueError.invalidTransition
        }
        try items[index].setState(.committed(attempt))
        try replaceItems(items)
    }

    public mutating func markAdmitted(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case let .reserved(attempt) = items[index].state,
              attempt.id == attemptID
        else {
            throw FollowUpQueueError.invalidTransition
        }
        let oldAnchor = items[index].sourceAnchor
        try items[index].setState(.admitted(attempt: attempt, handle: handle))
        let newAnchor = try FollowUpSourceAnchor(
            handle: handle,
            sourceUserMessageID: attempt.clientMessageID
        )
        try rebaseQueuedFollowers(in: &items, from: oldAnchor, to: newAnchor)
        try replaceItems(items)
    }

    /// Promotes an uncertain admission only after a separately proven exact
    /// handle. It reuses the retained attempt and never mints another request.
    public mutating func confirmUncertainAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case let .deliveryUncertain(attempt, _) = items[index].state,
              attempt.id == attemptID
        else {
            throw FollowUpQueueError.invalidTransition
        }
        let oldAnchor = items[index].sourceAnchor
        try items[index].setState(.admitted(attempt: attempt, handle: handle))
        let newAnchor = try FollowUpSourceAnchor(
            handle: handle,
            sourceUserMessageID: attempt.clientMessageID
        )
        try rebaseQueuedFollowers(in: &items, from: oldAnchor, to: newAnchor)
        try replaceItems(items)
    }

    /// Promotes a crash-restored or ambiguity-locked attempt only after an
    /// independent status read proves the exact user-message identity and v2
    /// generation epoch. Unlike `markAdmitted`, this intentionally accepts
    /// every pre-attachment journal state while preserving the original
    /// request IDs and byte-stable fingerprint.
    public mutating func confirmOutstandingAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        let attempt: FollowUpAdmissionAttempt
        switch items[index].state {
        case let .reserved(value),
             let .deliveryUncertain(value, _),
             let .committed(value):
            attempt = value
        default:
            throw FollowUpQueueError.invalidTransition
        }
        guard attempt.id == attemptID else {
            throw FollowUpQueueError.invalidTransition
        }
        let oldAnchor = items[index].sourceAnchor
        try items[index].setState(.admitted(attempt: attempt, handle: handle))
        let newAnchor = try FollowUpSourceAnchor(
            handle: handle,
            sourceUserMessageID: attempt.clientMessageID
        )
        try rebaseQueuedFollowers(in: &items, from: oldAnchor, to: newAnchor)
        try replaceItems(items)
    }

    /// Atomically records a separately proven retained terminal generation.
    /// This avoids persisting an intermediate admitted snapshot and never
    /// manufactures a handle for a jobless status. A completed proof rebases
    /// followers to the exact accepted epoch; non-completed terminals keep
    /// those followers ineligible for automatic drain.
    public mutating func confirmOutstandingTerminal(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle,
        terminal: FollowUpDeliveredTerminal
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        let attempt: FollowUpAdmissionAttempt
        switch items[index].state {
        case let .reserved(value),
             let .deliveryUncertain(value, _),
             let .committed(value):
            attempt = value
        default:
            throw FollowUpQueueError.invalidTransition
        }
        guard attempt.id == attemptID else {
            throw FollowUpQueueError.invalidTransition
        }
        if case let .completed(responseMessageID) = terminal,
           !FollowUpSourceAnchor.isPersistedMessage(responseMessageID) {
            throw FollowUpQueueError.invalidMessageID
        }
        let oldAnchor = items[index].sourceAnchor
        try items[index].setState(
            .delivered(attempt: attempt, handle: handle, terminal: terminal)
        )
        let newAnchor = try FollowUpSourceAnchor(
            handle: handle,
            sourceUserMessageID: attempt.clientMessageID
        )
        try rebaseQueuedFollowers(in: &items, from: oldAnchor, to: newAnchor)
        try replaceItems(items)
    }

    /// Records a jobless completion only when the caller has independently
    /// proven the exact durable user row and its single clean assistant child.
    /// No generation handle is invented. Every untouched follower anchored to
    /// the superseded predecessor is blocked because an atomic predecessor
    /// epoch is unavailable.
    public mutating func confirmJoblessCompletion(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        responseMessageID: MessageID
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        let attempt: FollowUpAdmissionAttempt
        switch items[index].state {
        case let .reserved(value),
             let .deliveryUncertain(value, _),
             let .committed(value),
             let .admitted(value, _):
            attempt = value
        default:
            throw FollowUpQueueError.invalidTransition
        }
        guard attempt.id == attemptID,
              FollowUpSourceAnchor.isPersistedMessage(responseMessageID)
        else {
            throw FollowUpQueueError.invalidTransition
        }
        let oldAnchor = items[index].sourceAnchor
        let followerAnchor: FollowUpSourceAnchor
        if case let .admitted(_, handle) = items[index].state {
            followerAnchor = try FollowUpSourceAnchor(
                handle: handle,
                sourceUserMessageID: attempt.clientMessageID
            )
        } else {
            followerAnchor = oldAnchor
        }
        try items[index].setState(
            .deliveredWithoutEpoch(
                attempt: attempt,
                responseMessageID: responseMessageID
            )
        )
        for followerIndex in items.indices where followerIndex != index {
            guard case .queued = items[followerIndex].state,
                  items[followerIndex].sourceAnchor == followerAnchor
            else { continue }
            try items[followerIndex].setState(.blocked(.predecessorUnverified))
        }
        try replaceItems(items)
    }

    /// A definitive non-admission restores the same item and ordering slot.
    /// If an exact handoff winner is proven, all followers of the old source
    /// wait for that winner's clean completion instead.
    public mutating func restoreReserved(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handoff: FollowUpHandoffRebase? = nil
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case let .reserved(attempt) = items[index].state,
              attempt.id == attemptID
        else {
            throw FollowUpQueueError.invalidTransition
        }
        let oldAnchor = items[index].sourceAnchor
        try items[index].setState(.queued)
        if let handoff {
            try validateHandoff(handoff, after: oldAnchor)
            let newAnchor = try FollowUpSourceAnchor(
                handle: handoff.winnerHandle,
                sourceUserMessageID: handoff.winnerUserMessageID
            )
            try rebaseQueuedFollowers(in: &items, from: oldAnchor, to: newAnchor)
        }
        try replaceItems(items)
    }

    public mutating func block(
        itemID: FollowUpQueueItemID,
        reason: FollowUpQueueBlockReason
    ) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case .queued = items[index].state else {
            throw FollowUpQueueError.invalidTransition
        }
        try items[index].setState(.blocked(reason))
        try replaceItems(items)
    }

    public mutating func unblock(itemID: FollowUpQueueItemID) throws {
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case .blocked = items[index].state else {
            throw FollowUpQueueError.invalidTransition
        }
        try items[index].setState(.queued)
        try replaceItems(items)
    }

    /// Records terminal evidence for an accepted admission. HITL and ambiguous
    /// observations are deliberately no-ops and keep the lane occupied.
    @discardableResult
    public mutating func observeAdmittedTerminal(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        signal: FollowUpGenerationSignal
    ) throws -> Bool {
        try validateSignalHandle(signal.handle)
        let index = try requireIndex(of: itemID)
        var items = snapshot.items
        guard case let .admitted(attempt, admittedHandle) = items[index].state,
              attempt.id == attemptID,
              admittedHandle == signal.handle
        else {
            throw FollowUpQueueError.invalidTransition
        }

        let terminal: FollowUpDeliveredTerminal
        switch signal {
        case let .completed(_, responseMessageID):
            guard FollowUpSourceAnchor.isPersistedMessage(responseMessageID) else {
                throw FollowUpQueueError.invalidMessageID
            }
            terminal = .completed(responseMessageID: responseMessageID)
        case .aborted:
            terminal = .aborted
        case .failed:
            terminal = .failed
        case .superseded:
            terminal = .superseded
        case .awaitingInteraction, .ambiguous:
            return false
        }
        try items[index].setState(
            .delivered(attempt: attempt, handle: admittedHandle, terminal: terminal)
        )
        try replaceItems(items)
        return true
    }

    private mutating func replaceItems(_ items: [FollowUpQueueItem]) throws {
        snapshot = try FollowUpQueueSnapshot(namespace: snapshot.namespace, items: items)
    }

    private func requireIndex(of id: FollowUpQueueItemID) throws -> Int {
        guard let index = snapshot.items.firstIndex(where: { $0.id == id }) else {
            throw FollowUpQueueError.itemNotFound
        }
        return index
    }

    private func requireLiveIndex(
        of id: FollowUpQueueItemID,
        in items: [FollowUpQueueItem]
    ) throws -> Int {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw FollowUpQueueError.itemNotFound
        }
        return index
    }

    private func validateSignalHandle(_ handle: GenerationHandle) throws {
        guard snapshot.namespace.owns(handle) else {
            throw FollowUpQueueError.contextMismatch
        }
        guard FollowUpSourceAnchor.isValidV2Handle(handle) else {
            throw FollowUpQueueError.invalidGenerationHandle
        }
    }

    private func validateHandoff(
        _ handoff: FollowUpHandoffRebase,
        after oldAnchor: FollowUpSourceAnchor
    ) throws {
        try validateSignalHandle(handoff.winnerHandle)
        guard FollowUpSourceAnchor.isPersistedMessage(handoff.winnerUserMessageID),
              let oldEpoch = oldAnchor.handle.generationCreatedAt,
              let winnerEpoch = handoff.winnerHandle.generationCreatedAt,
              winnerEpoch > oldEpoch
        else {
            throw FollowUpQueueError.invalidHandoff
        }
    }

    private func rebaseQueuedFollowers(
        in items: inout [FollowUpQueueItem],
        from oldAnchor: FollowUpSourceAnchor,
        to newAnchor: FollowUpSourceAnchor
    ) throws {
        for index in items.indices {
            guard case .queued = items[index].state,
                  items[index].sourceAnchor == oldAnchor
            else { continue }
            // A parked server steer is bound to its original source epoch. It
            // must never be replayed as an ordinary follow-up behind a winner
            // or a different admitted generation.
            if items[index].recoverableSource != nil {
                try items[index].setState(.blocked(.sourceUnavailable))
                continue
            }
            try items[index].rebaseSource(to: newAnchor)
        }
    }
}

/// Actor serialization for UI/repository owners that may receive foreground,
/// connectivity, and generation-completion triggers concurrently.
public actor FollowUpQueueCoordinator {
    private var reducer: FollowUpQueueReducer

    public init(snapshot: FollowUpQueueSnapshot) {
        reducer = FollowUpQueueReducer(snapshot: snapshot)
    }

    public init(namespace: FollowUpQueueNamespace) throws {
        reducer = try FollowUpQueueReducer(namespace: namespace)
    }

    public func currentSnapshot() -> FollowUpQueueSnapshot {
        reducer.snapshot
    }

    public func enqueue(_ item: FollowUpQueueItem) throws {
        try reducer.enqueue(item)
    }

    public func editQueued(itemID: FollowUpQueueItemID, text: String) throws {
        try reducer.editQueued(itemID: itemID, text: text)
    }

    public func removeQueued(itemID: FollowUpQueueItemID) throws {
        try reducer.removeQueued(itemID: itemID)
    }

    public func reorderQueued(itemIDs: [FollowUpQueueItemID]) throws {
        try reducer.reorderQueued(itemIDs: itemIDs)
    }

    public func reserveNext(
        after signal: FollowUpGenerationSignal,
        attemptID: UUID,
        clientRequestID: UUID,
        clientMessageID: MessageID
    ) throws -> FollowUpAdmissionAttempt? {
        try reducer.reserveNext(
            after: signal,
            attemptID: attemptID,
            clientRequestID: clientRequestID,
            clientMessageID: clientMessageID
        )
    }

    public func markDeliveryUncertain(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        reason: FollowUpDeliveryUncertaintyReason
    ) throws {
        try reducer.markDeliveryUncertain(
            itemID: itemID,
            attemptID: attemptID,
            reason: reason
        )
    }

    public func blockReserved(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        reason: FollowUpQueueBlockReason
    ) throws {
        try reducer.blockReserved(
            itemID: itemID,
            attemptID: attemptID,
            reason: reason
        )
    }

    public func confirmDurableAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID
    ) throws {
        try reducer.confirmDurableAdmission(itemID: itemID, attemptID: attemptID)
    }

    public func markAdmitted(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle
    ) throws {
        try reducer.markAdmitted(itemID: itemID, attemptID: attemptID, handle: handle)
    }

    public func confirmUncertainAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle
    ) throws {
        try reducer.confirmUncertainAdmission(
            itemID: itemID,
            attemptID: attemptID,
            handle: handle
        )
    }

    public func confirmOutstandingAdmission(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle
    ) throws {
        try reducer.confirmOutstandingAdmission(
            itemID: itemID,
            attemptID: attemptID,
            handle: handle
        )
    }

    public func confirmOutstandingTerminal(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handle: GenerationHandle,
        terminal: FollowUpDeliveredTerminal
    ) throws {
        try reducer.confirmOutstandingTerminal(
            itemID: itemID,
            attemptID: attemptID,
            handle: handle,
            terminal: terminal
        )
    }

    public func restoreReserved(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        handoff: FollowUpHandoffRebase? = nil
    ) throws {
        try reducer.restoreReserved(itemID: itemID, attemptID: attemptID, handoff: handoff)
    }

    public func block(itemID: FollowUpQueueItemID, reason: FollowUpQueueBlockReason) throws {
        try reducer.block(itemID: itemID, reason: reason)
    }

    public func unblock(itemID: FollowUpQueueItemID) throws {
        try reducer.unblock(itemID: itemID)
    }

    @discardableResult
    public func observeAdmittedTerminal(
        itemID: FollowUpQueueItemID,
        attemptID: UUID,
        signal: FollowUpGenerationSignal
    ) throws -> Bool {
        try reducer.observeAdmittedTerminal(
            itemID: itemID,
            attemptID: attemptID,
            signal: signal
        )
    }
}

public enum FollowUpQueueError: Error, Codable, Equatable, Hashable, Sendable {
    case invalidNamespace
    case invalidConversation
    case invalidGenerationHandle
    case invalidAcceptedHandle
    case invalidTarget
    case invalidText
    case textTooLong(maximumUTF16Length: Int)
    case invalidMessageID
    case messageIdentityCollision
    case invalidRecoverableSource
    case invalidAttachment
    case duplicateAttachment
    case recoverableClientMessageMismatch
    case invalidSlot
    case invalidUncertainty
    case invalidHandoff
    case contextMismatch
    case attemptMismatch
    case duplicateItemID
    case duplicateOrder
    case invalidReorder
    case multipleActiveReservations
    case itemNotFound
    case invalidTransition
}
