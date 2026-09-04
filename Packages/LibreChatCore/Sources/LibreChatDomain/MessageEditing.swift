import Foundation

/// The exact persisted text slot addressed by LibreChat's message-update API.
///
/// A content-part index is the server array index, not a rendered-text index.
/// Retaining the part kind makes reconciliation fail closed if another client
/// changes the part at that index while this edit is in flight.
public enum MessageTextLocation: Codable, Equatable, Hashable, Sendable {
    case primaryText
    case contentPart(index: Int, kind: MessageTextPartKind)
}

public enum MessageTextPartKind: String, Codable, Equatable, Hashable, Sendable {
    case text
    case reasoning
}

/// Full server coordinates for one editable text value.
public struct MessageTextCoordinate: Codable, Equatable, Hashable, Sendable {
    public let conversationID: ConversationID
    public let messageID: MessageID
    public let location: MessageTextLocation

    public init(
        conversationID: ConversationID,
        messageID: MessageID,
        location: MessageTextLocation
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.location = location
    }
}

/// A transport-derived editable value. This catalog preserves exact raw
/// content-array indexes even when unknown parts are present between text parts.
public struct EditableMessageText: Codable, Equatable, Hashable, Sendable {
    public let location: MessageTextLocation
    public let text: String

    public init(location: MessageTextLocation, text: String) {
        self.location = location
        self.text = text
    }
}

public struct MessageEditRequest: Codable, Equatable, Hashable, Sendable {
    /// A bounded native-client limit. LibreChat deployments can impose lower
    /// limits and will report those as a non-ambiguous 4xx response.
    public static let maximumTextUTF16Length = 100_000

    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let coordinate: MessageTextCoordinate
    public let text: String

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        coordinate: MessageTextCoordinate,
        text: String
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.coordinate = coordinate
        self.text = text
    }
}

public enum MessageEditResolution: String, Codable, Equatable, Hashable, Sendable {
    case confirmedAfterResponse
    case reconciledAfterAmbiguousFailure
}

/// The complete authoritative history read after a save. Returning siblings
/// prevents callers from treating the edited message as a replacement for the
/// conversation graph.
public struct MessageEditResult: Codable, Equatable, Sendable {
    public let coordinate: MessageTextCoordinate
    public let resolution: MessageEditResolution
    public let authoritativeHistory: [ChatMessage]

    public init(
        coordinate: MessageTextCoordinate,
        resolution: MessageEditResolution,
        authoritativeHistory: [ChatMessage]
    ) {
        self.coordinate = coordinate
        self.resolution = resolution
        self.authoritativeHistory = authoritativeHistory
    }

    public var editedMessage: ChatMessage? {
        authoritativeHistory.first {
            $0.id == coordinate.messageID && $0.conversationID == coordinate.conversationID
        }
    }
}

public struct RecoverableMessageEditAmbiguity: Codable, Equatable, Hashable, Sendable {
    public enum Reason: String, Codable, Equatable, Hashable, Sendable {
        case authoritativeMismatch
        case verificationUnavailable
    }

    public let coordinate: MessageTextCoordinate
    public let submittedText: String
    public let authoritativeText: String?
    public let reason: Reason

    public init(
        coordinate: MessageTextCoordinate,
        submittedText: String,
        authoritativeText: String?,
        reason: Reason
    ) {
        self.coordinate = coordinate
        self.submittedText = submittedText
        self.authoritativeText = authoritativeText
        self.reason = reason
    }
}

public enum MessageEditError: LocalizedError, Equatable, Sendable {
    case localIdentifier
    case blankIdentifier
    case blankText
    case textTooLong(maximumUTF16Length: Int)
    case negativeContentPartIndex
    case profileMismatch
    case accountMismatch
    case ambiguous(RecoverableMessageEditAmbiguity)

    public var errorDescription: String? {
        switch self {
        case .localIdentifier:
            "Only persisted LibreChat messages can be edited."
        case .blankIdentifier:
            "The server message coordinates are incomplete."
        case .blankText:
            "An edited message cannot be blank."
        case let .textTooLong(maximum):
            "The edited message exceeds the \(maximum)-character safety limit."
        case .negativeContentPartIndex:
            "The message content-part index cannot be negative."
        case .profileMismatch, .accountMismatch:
            "This edit belongs to another LibreChat session."
        case .ambiguous:
            "LibreChat may have saved this edit. Refresh the conversation before retrying."
        }
    }
}

/// A deterministic parent-linked view of one authoritative message history.
/// Any structural anomaly invalidates selectors for the whole snapshot so a
/// caller cannot silently select a different branch.
public struct MessageTree: Sendable {
    /// The root selection is scoped by the owning conversation model. Every
    /// other key names the exact message whose direct children are siblings.
    public enum BranchParent: Codable, Equatable, Hashable, Sendable {
        case root
        case message(MessageID)
    }

    public struct BranchEntry: Equatable, Identifiable, Sendable {
        public let parent: BranchParent
        public let message: ChatMessage
        public let siblings: [ChatMessage]
        public let selectedIndex: Int

        public init(
            parent: BranchParent,
            message: ChatMessage,
            siblings: [ChatMessage],
            selectedIndex: Int
        ) {
            self.parent = parent
            self.message = message
            self.siblings = siblings
            self.selectedIndex = selectedIndex
        }

        public var id: MessageID { message.id }
    }

    public struct BranchProjection: Equatable, Sendable {
        public let entries: [BranchEntry]

        public init(entries: [BranchEntry]) {
            self.entries = entries
        }

        public var messages: [ChatMessage] { entries.map(\.message) }
        public var tail: ChatMessage? { entries.last?.message }
    }

    public enum Anomaly: Codable, Equatable, Hashable, Sendable {
        case duplicateMessageID(MessageID)
        case missingParent(messageID: MessageID, parentMessageID: MessageID)
        case selfParent(MessageID)
        case cycle(messageIDs: [MessageID])
    }

    public struct SiblingSelection: Equatable, Sendable {
        public let parentMessageID: MessageID?
        public let siblings: [ChatMessage]
        public let selectedIndex: Int

        public init(
            parentMessageID: MessageID?,
            siblings: [ChatMessage],
            selectedIndex: Int
        ) {
            self.parentMessageID = parentMessageID
            self.siblings = siblings
            self.selectedIndex = selectedIndex
        }

        public var selectedMessage: ChatMessage { siblings[selectedIndex] }
    }

    private let messagesByID: [MessageID: ChatMessage]
    private let orderedChildrenByParent: [MessageID?: [ChatMessage]]
    public let anomalies: [Anomaly]

    public init(messages: [ChatMessage]) {
        var groups: [MessageID: [ChatMessage]] = [:]
        for message in messages {
            groups[message.id, default: []].append(message)
        }

        let duplicateIDs = groups
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted(by: Self.identifierOrder)
        var anomalySet = Set(duplicateIDs.map(Anomaly.duplicateMessageID))
        let unique = groups.compactMapValues { values in
            values.count == 1 ? values[0] : nil
        }

        for message in unique.values {
            guard let parent = Self.normalizedParent(message.parentMessageID) else { continue }
            if parent == message.id {
                anomalySet.insert(.selfParent(message.id))
            } else if unique[parent] == nil {
                anomalySet.insert(.missingParent(messageID: message.id, parentMessageID: parent))
            }
        }

        // Cycle detection walks each node's parent chain at most once: a
        // parent-linked forest gives every node a single deterministic
        // suffix, so any later walk reaching an already-verified node can
        // stop there. Re-walking every message's full path to the root made
        // long linear histories quadratic (seconds at a few thousand
        // messages).
        var verifiedAcyclic = Set<MessageID>()
        for message in unique.values {
            guard !verifiedAcyclic.contains(message.id) else { continue }
            var path: [MessageID] = []
            var positions: [MessageID: Int] = [:]
            var cursor: MessageID? = message.id
            var recordedCycle = false
            while let current = cursor, let node = unique[current] {
                if verifiedAcyclic.contains(current) { break }
                if let start = positions[current] {
                    let cycle = path[start...].sorted(by: Self.identifierOrder)
                    anomalySet.insert(.cycle(messageIDs: Array(cycle)))
                    recordedCycle = true
                    break
                }
                positions[current] = path.count
                path.append(current)
                cursor = Self.normalizedParent(node.parentMessageID)
            }
            // A walk that recorded a cycle keeps its nodes unverified; the
            // anomaly is already recorded and later walks through this path
            // can only rediscover the same single-parent chain.
            if !recordedCycle {
                verifiedAcyclic.formUnion(path)
            }
        }

        // Preserve the authoritative flat-history ordinal for sibling/root
        // presentation. Parent lookup remains identity-based and therefore
        // does not depend on parents appearing before their children.
        var children: [MessageID?: [ChatMessage]] = [:]
        for message in messages where unique[message.id] != nil {
            children[Self.normalizedParent(message.parentMessageID), default: []].append(message)
        }

        messagesByID = unique
        orderedChildrenByParent = children
        anomalies = anomalySet.sorted(by: Self.anomalyOrder)
    }

    public var isStructurallyValid: Bool { anomalies.isEmpty }

    public var roots: [ChatMessage] {
        guard isStructurallyValid else { return [] }
        return orderedChildrenByParent[nil] ?? []
    }

    public func children(of parentMessageID: MessageID) -> [ChatMessage] {
        guard isStructurallyValid else { return [] }
        if Self.normalizedParent(parentMessageID) == nil {
            return orderedChildrenByParent[nil] ?? []
        }
        guard messagesByID[parentMessageID] != nil else { return [] }
        return orderedChildrenByParent[parentMessageID] ?? []
    }

    /// Returns the one visible branch selected by exact child identities.
    /// Missing or stale selections fall back to LibreChat's default: the last
    /// sibling in the authoritative flat-history order at every depth.
    public func projection(
        selectedChildByParent: [BranchParent: MessageID] = [:]
    ) -> BranchProjection? {
        guard isStructurallyValid else { return nil }

        var entries: [BranchEntry] = []
        var parent = BranchParent.root
        var siblings = orderedChildrenByParent[nil] ?? []

        while !siblings.isEmpty {
            let selectedID = selectedChildByParent[parent]
            let selectedIndex = selectedID.flatMap { selectedID in
                siblings.firstIndex { $0.id == selectedID }
            } ?? (siblings.count - 1)
            let message = siblings[selectedIndex]
            entries.append(BranchEntry(
                parent: parent,
                message: message,
                siblings: siblings,
                selectedIndex: selectedIndex
            ))
            parent = .message(message.id)
            siblings = orderedChildrenByParent[message.id] ?? []
        }

        return BranchProjection(entries: entries)
    }

    /// Reconstructs the exact ancestor selections required to make a server
    /// message visible. This is used after resume/final reconciliation, where
    /// the generation protocol supplies an authoritative response identity.
    public func selections(focusing messageID: MessageID) -> [BranchParent: MessageID]? {
        guard isStructurallyValid, messagesByID[messageID] != nil else { return nil }

        var selections: [BranchParent: MessageID] = [:]
        var cursor = messageID
        while let message = messagesByID[cursor] {
            if let parentID = Self.normalizedParent(message.parentMessageID) {
                selections[.message(parentID)] = message.id
                cursor = parentID
            } else {
                selections[.root] = message.id
                return selections
            }
        }
        return nil
    }

    /// Removes selections that no longer name a direct child in this exact
    /// authoritative snapshot. Identity validation prevents a stale choice
    /// from silently selecting a similarly positioned sibling.
    public func validSelections(
        from selections: [BranchParent: MessageID]
    ) -> [BranchParent: MessageID] {
        guard isStructurallyValid else { return [:] }
        return selections.filter { parent, selectedID in
            siblings(of: parent).contains { $0.id == selectedID }
        }
    }

    /// Selects siblings from the exact message ID. No array-tail or timestamp
    /// heuristic is used as a branch anchor.
    public func siblings(containing messageID: MessageID) -> SiblingSelection? {
        guard isStructurallyValid, let message = messagesByID[messageID] else { return nil }
        let parent = Self.normalizedParent(message.parentMessageID)
        let siblings = orderedChildrenByParent[parent] ?? []
        guard let index = siblings.firstIndex(where: { $0.id == messageID }) else { return nil }
        return SiblingSelection(
            parentMessageID: parent,
            siblings: siblings,
            selectedIndex: index
        )
    }

    private func siblings(of parent: BranchParent) -> [ChatMessage] {
        switch parent {
        case .root:
            return orderedChildrenByParent[nil] ?? []
        case let .message(messageID):
            guard messagesByID[messageID] != nil else { return [] }
            return orderedChildrenByParent[messageID] ?? []
        }
    }

    private static func identifierOrder(_ lhs: MessageID, _ rhs: MessageID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func normalizedParent(_ parent: MessageID?) -> MessageID? {
        guard let parent else { return nil }
        switch parent.rawValue.uppercased() {
        case "00000000-0000-0000-0000-000000000000", "NO_PARENT":
            return nil
        default:
            return parent
        }
    }

    private static func anomalyOrder(_ lhs: Anomaly, _ rhs: Anomaly) -> Bool {
        String(reflecting: lhs) < String(reflecting: rhs)
    }
}
