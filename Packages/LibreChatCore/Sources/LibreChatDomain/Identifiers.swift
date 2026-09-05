import Foundation

public protocol LibreChatIdentifier: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {}

public extension LibreChatIdentifier {
    var description: String { rawValue }
}

public struct AccountID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ConversationID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(localDraftID: UUID = UUID()) {
        rawValue = "local-new-\(localDraftID.uuidString)"
    }

    public var isLocalDraft: Bool {
        rawValue == "new" || rawValue.hasPrefix("local-new-")
    }

    public var serverValue: String {
        isLocalDraft ? "new" : rawValue
    }
}

/// A server-owned LibreChat project identifier.
///
/// Project IDs are deliberately distinct from conversation IDs: a project is
/// an organizational container, while a conversation only has nullable
/// membership in one project at a time.
public struct ProjectID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A server-owned saved-agent identifier.
///
/// Agent identity is deliberately distinct from a target-option identifier:
/// one agent can be exposed through more than one configured model spec.
public struct AgentID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isSafePathComponent: Bool {
        guard (1...128).contains(rawValue.utf8.count) else { return false }
        // Dot-only values survive the allowlist but normalize to parent
        // routes once interpolated into a path.
        guard rawValue != ".", rawValue != ".." else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: true
            case 45, 58, 95: true // - : _
            default: false
            }
        }
    }
}

/// LibreChat's Mongo-backed ACL resource coordinate for a saved agent.
///
/// This is intentionally distinct from `AgentID`: `/api/agents/:id` uses the
/// public agent identifier, while `/api/permissions/agent/:resource/effective`
/// requires the agent document's `_id`.
public struct AgentResourceID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isSafePathComponent: Bool {
        guard rawValue.utf8.count == 24 else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }
}

/// An ACL-scoped LibreChat skill coordinate.
///
/// Persisted skills currently use Mongo ObjectIds while deployment-provided
/// skills may use a server-derived identifier. Treat both as opaque and only
/// require an RFC 3986 unreserved path component before constructing routes.
public struct SkillID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isSafePathComponent: Bool {
        guard (1...256).contains(rawValue.utf8.count) else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: true
            case 45, 46, 95, 126: true // - . _ ~
            default: false
            }
        }
    }
}

/// A server-owned prompt-group resource coordinate.
public struct PromptGroupID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isSafePathComponent: Bool {
        guard rawValue.utf8.count == 24 else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }
}

/// A server-owned prompt version inside one prompt group.
public struct PromptVersionID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isSafePathComponent: Bool {
        guard rawValue.utf8.count == 24 else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }
}

/// An opaque, server-owned preset identifier.
///
/// Presets are currently fetched as an owner-scoped collection rather than by
/// path, so this type intentionally does not imply URL-path safety.
public struct PresetID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct MessageID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The server identity of one user's conversation-tag directory record.
public struct ConversationTagID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// An opaque identifier for a server-owned shared conversation link.
///
/// This is deliberately distinct from both the Mongo resource identifier used
/// for ACLs and the source conversation identifier. The value is safe to use
/// in the `/share/:shareId` route, but it must not be confused with either of
/// those private identifiers.
public struct SharedLinkID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// LibreChat currently creates share IDs with `nanoid`, but older and
    /// self-hosted deployments may use another opaque ASCII identifier. Keep
    /// the accepted set URL-path safe and reject traversal/separator input.
    public var isSafePathComponent: Bool {
        guard (1...256).contains(rawValue.utf8.count) else { return false }
        // Dots may appear inside an id, but dot-only values normalize to
        // parent routes once interpolated into a path.
        guard rawValue != ".", rawValue != ".." else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: true
            case 45, 46, 95, 126: true // - . _ ~
            default: false
            }
        }
    }
}

/// An identifier anonymized by the server for one shared-snapshot response.
/// It must never be used as a canonical `ConversationID` or persisted as one.
public struct SharedConversationID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// An identifier anonymized by the server for one shared-snapshot response.
/// It is intentionally distinct from a source `MessageID`.
public struct SharedMessageID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A file identifier exposed inside a shared snapshot.
public struct SharedFileID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct ServerProfileID: LibreChatIdentifier {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: UUID = UUID()) {
        rawValue = value.uuidString
    }
}
