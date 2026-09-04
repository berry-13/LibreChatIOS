import Foundation
import LibreChatDomain

/// The small, permissive wire projection returned by GET /api/skills.
/// Unknown fields are intentionally ignored and optional fields tolerate older
/// LibreChat deployments which predate the Skills metadata additions.
public struct LibreChatSkillSummaryDTO: Decodable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var displayTitle: String?
    public var description: String?
    public var category: String?
    public var source: String?
    public var author: String?
    public var version: Int?
    public var fileCount: Int?
    public var alwaysApply: Bool?
    public var isPublic: Bool?
    public var disableModelInvocation: Bool?
    public var userInvocable: Bool?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case name, displayTitle, description, category, source, author, version, fileCount
        case alwaysApply, isPublic, disableModelInvocation, userInvocable
    }

    public init(
        id: String? = nil,
        name: String? = nil,
        displayTitle: String? = nil,
        description: String? = nil,
        category: String? = nil,
        source: String? = nil,
        author: String? = nil,
        version: Int? = nil,
        fileCount: Int? = nil,
        alwaysApply: Bool? = nil,
        isPublic: Bool? = nil,
        disableModelInvocation: Bool? = nil,
        userInvocable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.displayTitle = displayTitle
        self.description = description
        self.category = category
        self.source = source
        self.author = author
        self.version = version
        self.fileCount = fileCount
        self.alwaysApply = alwaysApply
        self.isPublic = isPublic
        self.disableModelInvocation = disableModelInvocation
        self.userInvocable = userInvocable
    }

    public func domainModel(availability: SkillInvocationAvailability = .available) throws -> ChatSkillSummary {
        guard let rawID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !rawID.isEmpty else {
            throw DTOMapperError.missingRequiredField("skill._id")
        }
        let skillID = SkillID(rawValue: rawID)
        guard skillID.isSafePathComponent else { throw DTOMapperError.invalidField("skill._id") }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              SkillInvocationCatalog.isValidName(name) else {
            throw DTOMapperError.invalidField("skill.name")
        }
        guard let rawDescription = description,
              let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw DTOMapperError.missingRequiredField("skill.description")
        }
        guard rawDescription.utf16.count <= 1_024 else {
            throw DTOMapperError.invalidField("skill.description")
        }
        let resolvedDisplayTitle: String
        if let rawDisplayTitle = self.displayTitle {
            guard rawDisplayTitle.utf16.count <= 128 else {
                throw DTOMapperError.invalidField("skill.displayTitle")
            }
            resolvedDisplayTitle = rawDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? name
        } else {
            resolvedDisplayTitle = name
        }
        if let version, version < 0 { throw DTOMapperError.invalidField("skill.version") }
        if let fileCount, fileCount < 0 { throw DTOMapperError.invalidField("skill.fileCount") }
        return ChatSkillSummary(
            id: skillID,
            name: name,
            displayTitle: resolvedDisplayTitle,
            description: description,
            category: category?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            source: ChatSkillSource(rawValue: source ?? "") ?? .unknown,
            version: version ?? 0,
            fileCount: fileCount ?? 0,
            alwaysApply: alwaysApply == true,
            isPublic: isPublic == true,
            availability: availability
        )
    }
}

public struct LibreChatSkillPageDTO: Decodable, Equatable, Sendable {
    public var skills: [LibreChatSkillSummaryDTO]
    public var hasMore: Bool?
    public var after: String?

    private enum CodingKeys: String, CodingKey {
        case skills
        case hasMore = "has_more"
        case after
    }

    public init(skills: [LibreChatSkillSummaryDTO] = [], hasMore: Bool? = nil, after: String? = nil) {
        self.skills = skills
        self.hasMore = hasMore
        self.after = after
    }
}

public struct LibreChatSkillStatesDTO: Decodable, Equatable, Sendable {
    public var states: [String: Bool]

    public init(states: [String: Bool] = [:]) { self.states = states }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        states = try container.decode([String: Bool].self)
    }
}

public struct LibreChatSkillStatesUpdateDTO: Codable, Equatable, Sendable {
    public var skillStates: [String: Bool]

    public init(skillStates: [String: Bool]) {
        self.skillStates = skillStates
    }
}

public enum LibreChatSkillsAPI {
    public static func list(
        category: String? = nil,
        search: String? = nil,
        limit: Int = 20,
        cursor: String? = nil
    ) -> APIRequest<LibreChatSkillPageDTO> {
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let category = category?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            query.append(URLQueryItem(name: "category", value: category))
        }
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        if let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return APIRequest(path: "api/skills", queryItems: query, retryPolicy: .idempotent(maximumAttempts: 2))
    }

    public static func activeStates() -> APIRequest<LibreChatSkillStatesDTO> {
        APIRequest(path: "api/user/settings/skills/active", retryPolicy: .idempotent(maximumAttempts: 2))
    }

    /// Replaces the account's complete explicit override map. The server route
    /// is a mutation and is never retried automatically after dispatch.
    public static func updateActiveStates(
        _ states: [String: Bool]
    ) throws -> APIRequest<LibreChatSkillStatesDTO> {
        guard states.count <= 400,
              states.keys.allSatisfy(isMutableSkillID) else {
            throw SkillManagementError.invalidCatalog
        }
        return try APIRequest(
            method: .post,
            path: "api/user/settings/skills/active",
            body: LibreChatSkillStatesUpdateDTO(skillStates: states),
            retryPolicy: .never
        )
    }

    public static func isMutableSkillID(_ value: String) -> Bool {
        guard value.utf8.count == 24 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }
}

/// Authorization evidence supplied by the repository after capability, ACL,
/// saved-agent and model-spec discovery. The mapper never infers authority
/// from a cached skill row alone.
public struct SkillInvocationTargetScope: Equatable, Sendable {
    public var capabilityEnabled: Bool
    public var ephemeralScope: EphemeralSkillScope?
    public var savedAgentScope: SavedAgentSkillScope?
    public var ephemeralBadgeEnabled: Bool

    public init(
        capabilityEnabled: Bool,
        ephemeralScope: EphemeralSkillScope? = nil,
        savedAgentScope: SavedAgentSkillScope? = nil,
        ephemeralBadgeEnabled: Bool = false
    ) {
        self.capabilityEnabled = capabilityEnabled
        self.ephemeralScope = ephemeralScope
        self.savedAgentScope = savedAgentScope
        self.ephemeralBadgeEnabled = ephemeralBadgeEnabled
    }
}

public enum LibreChatSkillsMapper {
    public static func accountCatalog(
        profileID: ServerProfileID,
        accountID: AccountID,
        page: LibreChatSkillPageDTO,
        activeStates: LibreChatSkillStatesDTO,
        sharedDefaultActive: Bool = false,
        fetchedAt: Date = Date()
    ) throws -> AccountSkillCatalog {
        guard page.hasMore != true else { throw SkillManagementError.invalidCatalog }

        var explicitStates: [SkillID: Bool] = [:]
        for (rawID, value) in activeStates.states {
            guard LibreChatSkillsAPI.isMutableSkillID(rawID) else {
                throw SkillManagementError.invalidCatalog
            }
            explicitStates[SkillID(rawValue: rawID)] = value
        }

        var seen = Set<SkillID>()
        let skills = try page.skills.map { wire -> AccountSkillSummary in
            let skill = try wire.domainModel()
            guard seen.insert(skill.id).inserted else {
                throw SkillManagementError.invalidCatalog
            }

            let explicit = explicitStates[skill.id]
            let basis: AccountSkillActivationBasis
            let active: Bool
            if let explicit {
                basis = .explicitOverride
                active = explicit
            } else if skill.source == .deployment {
                basis = .deploymentDefault
                active = true
            } else if wire.author == accountID.rawValue {
                basis = .ownerDefault
                active = true
            } else if sharedDefaultActive {
                basis = .sharedDefault
                active = true
            } else {
                basis = .inactiveDefault
                active = false
            }

            return AccountSkillSummary(
                id: skill.id,
                name: skill.name,
                displayTitle: skill.displayTitle,
                description: skill.description,
                category: skill.category,
                source: skill.source,
                version: skill.version,
                fileCount: skill.fileCount,
                alwaysApply: skill.alwaysApply,
                isPublic: skill.isPublic,
                isActive: active,
                activationBasis: basis,
                isUserInvocable: wire.userInvocable != false,
                canChangeActivation: LibreChatSkillsAPI.isMutableSkillID(skill.id.rawValue)
            )
        }

        return AccountSkillCatalog(
            profileID: profileID,
            accountID: accountID,
            skills: skills,
            explicitStates: explicitStates,
            fetchedAt: fetchedAt,
            isComplete: true
        )
    }

    public static func catalog(
        profileID: ServerProfileID,
        accountID: AccountID,
        target: ConversationTarget,
        page: LibreChatSkillPageDTO,
        activeStates: LibreChatSkillStatesDTO,
        scope: SkillInvocationTargetScope,
        sharedDefaultActive: Bool = false,
        fetchedAt: Date = Date()
    ) throws -> SkillInvocationCatalog {
        var values = try page.skills.map { try $0.domainModel() }
        let idStates = activeStates.states
        let enabledIDs: Set<String>? = {
            if let saved = scope.savedAgentScope {
                switch saved {
                case .disabled: return []
                case .all: return nil
                case let .identifiers(ids): return Set(ids.map(\.rawValue))
                }
            }
            if let ephemeral = scope.ephemeralScope {
                switch ephemeral {
                case .disabled: return []
                case .all: return nil
                case .names: return nil
                }
            }
            return scope.ephemeralBadgeEnabled ? nil : []
        }()
        let enabledNames: Set<String>? = if case let .names(names) = scope.ephemeralScope {
            Set(names)
        } else { nil }

        values = zip(values, page.skills).map { skill, wire in
            var availability: SkillInvocationAvailability
            if !scope.capabilityEnabled {
                availability = .targetDisabled
            } else if enabledIDs?.contains(skill.id.rawValue) == false {
                availability = .excludedByTarget
            } else if enabledNames?.contains(skill.name) == false {
                availability = .excludedByTarget
            } else if !(idStates[skill.id.rawValue] ?? defaultActive(
                wire: wire,
                accountID: accountID,
                sharedDefaultActive: sharedDefaultActive
            )) {
                availability = .inactive
            } else if wire.userInvocable == false {
                availability = .modelOnly
            } else {
                availability = .available
            }
            return ChatSkillSummary(
                id: skill.id, name: skill.name, displayTitle: skill.displayTitle,
                description: skill.description, category: skill.category, source: skill.source,
                version: skill.version, fileCount: skill.fileCount, alwaysApply: skill.alwaysApply,
                isPublic: skill.isPublic, availability: availability
            )
        }
        let grouped = Dictionary(grouping: values, by: \.name)
        let ambiguous = Set(grouped.filter { _, rows in rows.filter { $0.availability == .available }.count > 1 }.keys)
        if !ambiguous.isEmpty {
            values = values.map { skill in
                guard ambiguous.contains(skill.name), skill.availability == .available else { return skill }
                return ChatSkillSummary(id: skill.id, name: skill.name, displayTitle: skill.displayTitle,
                    description: skill.description, category: skill.category, source: skill.source,
                    version: skill.version, fileCount: skill.fileCount, alwaysApply: skill.alwaysApply,
                    isPublic: skill.isPublic, availability: .ambiguousName)
            }
        }
        return SkillInvocationCatalog(profileID: profileID, accountID: accountID, target: target,
                                      skills: values, fetchedAt: fetchedAt,
                                      isComplete: page.hasMore != true)
    }

    private static func defaultActive(
        wire: LibreChatSkillSummaryDTO,
        accountID: AccountID,
        sharedDefaultActive: Bool
    ) -> Bool {
        if wire.source == "deployment" { return true }
        if wire.author == accountID.rawValue { return true }
        return sharedDefaultActive
    }
}
