import Foundation

public struct PromptPermissions: Codable, Equatable, Hashable, Sendable {
    public var use: Bool
    public var create: Bool
    public var share: Bool
    public var sharePublicly: Bool

    public init(
        use: Bool = false,
        create: Bool = false,
        share: Bool = false,
        sharePublicly: Bool = false
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
    }
}

/// View-safe metadata plus the current production text exposed by the ACL-
/// filtered prompt-group directory. Raw author IDs and version history are not
/// part of this read-and-insert slice.
public struct PromptTemplateGroup: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: PromptGroupID
    public var name: String
    public var summary: String?
    public var command: String?
    public var category: String?
    public var productionText: String?
    public var authorName: String?
    public var isPublic: Bool
    public var usageCount: Int?

    public init(
        id: PromptGroupID,
        name: String,
        summary: String? = nil,
        command: String? = nil,
        category: String? = nil,
        productionText: String? = nil,
        authorName: String? = nil,
        isPublic: Bool = false,
        usageCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.command = command
        self.category = category
        self.productionText = productionText
        self.authorName = authorName
        self.isPublic = isPublic
        self.usageCount = usageCount
    }

    public var isInsertable: Bool {
        productionText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

public struct PromptTemplatePage: Codable, Equatable, Sendable {
    public var groups: [PromptTemplateGroup]
    public var nextCursor: String?

    public init(groups: [PromptTemplateGroup], nextCursor: String? = nil) {
        self.groups = groups
        self.nextCursor = nextCursor
    }
}

public struct PromptTemplateQuery: Codable, Equatable, Sendable {
    public var search: String?
    public var category: String?
    public var cursor: String?
    public var limit: Int

    public init(
        search: String? = nil,
        category: String? = nil,
        cursor: String? = nil,
        limit: Int = 20
    ) {
        self.search = search
        self.category = category
        self.cursor = cursor
        self.limit = limit
    }
}

public enum PromptTemplateKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case text
    case chat
}

/// Exact, live-only metadata for an editable prompt group. Author IDs and ACL
/// principals remain outside this bounded management surface.
public struct ManagedPromptGroup: Equatable, Hashable, Identifiable, Sendable {
    public let id: PromptGroupID
    public var name: String
    public var summary: String
    public var category: String
    public var command: String?
    public var productionVersionID: PromptVersionID
    public var updatedAt: Date?

    public init(
        id: PromptGroupID,
        name: String,
        summary: String = "",
        category: String = "",
        command: String? = nil,
        productionVersionID: PromptVersionID,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.command = command
        self.productionVersionID = productionVersionID
        self.updatedAt = updatedAt
    }
}

public struct ManagedPromptVersion: Equatable, Hashable, Identifiable, Sendable {
    public let id: PromptVersionID
    public let groupID: PromptGroupID
    public var text: String
    public var kind: PromptTemplateKind
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: PromptVersionID,
        groupID: PromptGroupID,
        text: String,
        kind: PromptTemplateKind,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PromptManagementDetail: Equatable, Sendable {
    public var group: ManagedPromptGroup
    public var versions: [ManagedPromptVersion]

    public init(group: ManagedPromptGroup, versions: [ManagedPromptVersion]) {
        self.group = group
        self.versions = versions
    }
}

public struct CreatePromptGroupInput: Equatable, Sendable {
    public var name: String
    public var summary: String
    public var category: String
    public var command: String?
    public var text: String
    public var kind: PromptTemplateKind

    public init(
        name: String,
        summary: String = "",
        category: String = "",
        command: String? = nil,
        text: String,
        kind: PromptTemplateKind = .text
    ) {
        self.name = name
        self.summary = summary
        self.category = category
        self.command = command
        self.text = text
        self.kind = kind
    }
}

public struct AddPromptVersionInput: Equatable, Sendable {
    public var groupID: PromptGroupID
    public var text: String
    public var kind: PromptTemplateKind

    public init(groupID: PromptGroupID, text: String, kind: PromptTemplateKind) {
        self.groupID = groupID
        self.text = text
        self.kind = kind
    }
}

public struct UpdatePromptGroupInput: Equatable, Sendable {
    public var groupID: PromptGroupID
    public var name: String
    public var summary: String
    public var category: String
    public var command: String?

    public init(
        groupID: PromptGroupID,
        name: String,
        summary: String,
        category: String,
        command: String?
    ) {
        self.groupID = groupID
        self.name = name
        self.summary = summary
        self.category = category
        self.command = command
    }
}

public enum PromptManagementError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidInput(String)
    case invalidResponse
    case outcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Prompt management is unavailable for this account."
        case let .invalidInput(message):
            message
        case .invalidResponse:
            "LibreChat returned prompt data that could not be verified."
        case .outcomeUnknown:
            "LibreChat may have saved this change. Refresh before trying again."
        }
    }
}

public struct PromptVariableID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct PromptVariable: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: PromptVariableID
    public var name: String
    public var options: [String]

    public init(id: PromptVariableID, name: String, options: [String] = []) {
        self.id = id
        self.name = name
        self.options = options
    }

    public var placeholder: String { "{{\(id.rawValue)}}" }
}

public enum PromptExpansionError: LocalizedError, Equatable, Sendable {
    case invalidTemplate
    case missingValues([PromptVariableID])

    public var errorDescription: String? {
        switch self {
        case .invalidTemplate:
            "This prompt contains an invalid variable definition."
        case .missingValues:
            "Complete every prompt field before inserting it."
        }
    }
}

/// LibreChat prompt variables use `{{name}}` or
/// `{{name:option one|option two}}`. Special variables are resolved before
/// user fields, matching the web client while keeping expansion deterministic
/// and independently testable.
public enum PromptTemplateExpander {
    private static let specialNames: Set<String> = [
        "current_date", "current_datetime", "iso_datetime", "current_user",
    ]

    public static func variables(in text: String) throws -> [PromptVariable] {
        let matches = try placeholders(in: text)
        var seen = Set<PromptVariableID>()
        var result: [PromptVariable] = []
        for raw in matches {
            let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw PromptExpansionError.invalidTemplate }
            if specialNames.contains(content.lowercased()) { continue }
            let id = PromptVariableID(rawValue: raw)
            guard seen.insert(id).inserted else { continue }

            let pieces = content.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw PromptExpansionError.invalidTemplate }
            let options: [String]
            if pieces.count == 2, pieces[1].contains("|") {
                options = pieces[1]
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else {
                options = []
            }
            result.append(PromptVariable(id: id, name: name, options: options))
        }
        return result
    }

    public static func expand(
        _ text: String,
        values: [PromptVariableID: String],
        userName: String?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> String {
        var result = replaceSpecialVariables(
            in: text,
            userName: userName,
            now: now,
            timeZone: timeZone
        )
        let variables = try variables(in: result)
        let missing = variables.compactMap { variable -> PromptVariableID? in
            guard let value = values[variable.id],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return variable.id
            }
            return nil
        }
        guard missing.isEmpty else { throw PromptExpansionError.missingValues(missing) }
        for variable in variables {
            guard let value = values[variable.id] else { continue }
            result = result.replacingOccurrences(of: variable.placeholder, with: value)
        }
        return result
    }

    private static func placeholders(in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"\{\{([^{}]+?)\}\}"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func replaceSpecialVariables(
        in text: String,
        userName: String?,
        now: Date,
        timeZone: TimeZone
    ) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let date = DateFormatter()
        date.locale = locale
        date.timeZone = timeZone
        date.dateFormat = "yyyy-MM-dd (EEEE)"
        let dateTime = DateFormatter()
        dateTime.locale = locale
        dateTime.timeZone = timeZone
        dateTime.dateFormat = "yyyy-MM-dd HH:mm:ss Z (EEEE)"
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var result = text
        result = replace(#"\{\{\s*current_date\s*\}\}"#, in: result, with: date.string(from: now))
        result = replace(#"\{\{\s*current_datetime\s*\}\}"#, in: result, with: dateTime.string(from: now))
        result = replace(#"\{\{\s*iso_datetime\s*\}\}"#, in: result, with: iso.string(from: now))
        if let userName = userName?.trimmingCharacters(in: .whitespacesAndNewlines), !userName.isEmpty {
            result = replace(#"\{\{\s*current_user\s*\}\}"#, in: result, with: userName)
        }
        return result
    }

    private static func replace(_ pattern: String, in text: String, with value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: escapedTemplate(value))
    }

    private static func escapedTemplate(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}
