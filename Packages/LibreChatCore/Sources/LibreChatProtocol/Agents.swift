import Foundation
import LibreChatDomain

public struct LibreChatAgentDetailDTO: Codable, Equatable, Sendable {
    public var id: String?
    public var mongoID: String?
    public var name: String?
    public var description: String?
    public var category: String?
    public var conversationStarters: [String]
    public var provider: String?
    public var model: String?
    public var isPublic: Bool?
    public var version: Int?
    public var skillsEnabled: Bool?
    public var skillIDs: [String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case mongoID = "_id"
        case name, description, category, provider, model, isPublic, version
        case skillsEnabled = "skills_enabled"
        case skillIDs = "skills"
        case conversationStarters = "conversation_starters"
    }

    public init(
        id: String? = nil,
        mongoID: String? = nil,
        name: String? = nil,
        description: String? = nil,
        category: String? = nil,
        conversationStarters: [String] = [],
        provider: String? = nil,
        model: String? = nil,
        isPublic: Bool? = nil,
        version: Int? = nil,
        skillsEnabled: Bool? = nil,
        skillIDs: [String]? = nil
    ) {
        self.id = id
        self.mongoID = mongoID
        self.name = name
        self.description = description
        self.category = category
        self.conversationStarters = conversationStarters
        self.provider = provider
        self.model = model
        self.isPublic = isPublic
        self.version = version
        self.skillsEnabled = skillsEnabled
        self.skillIDs = skillIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        mongoID = try? container.decodeIfPresent(String.self, forKey: .mongoID)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        category = try? container.decodeIfPresent(String.self, forKey: .category)
        conversationStarters = (try? container.decodeIfPresent([String].self, forKey: .conversationStarters)) ?? []
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        isPublic = try? container.decodeIfPresent(Bool.self, forKey: .isPublic)
        version = try? container.decodeIfPresent(Int.self, forKey: .version)
        skillsEnabled = try? container.decodeIfPresent(Bool.self, forKey: .skillsEnabled)
        skillIDs = try? container.decodeIfPresent([String].self, forKey: .skillIDs)
    }

    public func domainModel() throws -> ChatAgentDetail {
        guard let rawID = id?.nonEmpty ?? mongoID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("agent.id")
        }
        guard let name = name?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("agent.name")
        }
        let skillScope: SavedAgentSkillScope
        if skillsEnabled == true {
            if let rawIDs = skillIDs, !rawIDs.isEmpty {
                let ids = rawIDs.map(SkillID.init(rawValue:))
                guard ids.allSatisfy(\.isSafePathComponent), Set(ids).count == ids.count else {
                    throw DTOMapperError.invalidField("agent.skills")
                }
                skillScope = .identifiers(ids)
            } else {
                skillScope = .all
            }
        } else {
            skillScope = .disabled
        }
        return ChatAgentDetail(
            id: AgentID(rawValue: rawID),
            resourceID: mongoID?.nonEmpty
                .map { AgentResourceID(rawValue: $0) }
                .flatMap { $0.isSafePathComponent ? $0 : nil },
            name: name,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            conversationStarters: conversationStarters.compactMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            },
            provider: provider?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            isPublic: isPublic == true,
            version: version,
            skillScope: skillScope
        )
    }

    public func managedDomainModel() throws -> ManagedAgentMetadata {
        guard let rawID = id?.nonEmpty ?? mongoID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("agent.id")
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else {
            throw DTOMapperError.missingRequiredField("agent.name")
        }
        return ManagedAgentMetadata(
            id: AgentID(rawValue: rawID),
            resourceID: mongoID?.nonEmpty
                .map { AgentResourceID(rawValue: $0) }
                .flatMap { $0.isSafePathComponent ? $0 : nil },
            name: name,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            category: category?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            isPublic: isPublic == true,
            version: version
        )
    }

    public func summaryModel(canEdit: Bool) throws -> ChatAgentSummary {
        let managed = try managedDomainModel()
        return ChatAgentSummary(
            id: managed.id,
            name: managed.name,
            description: managed.description,
            category: managed.category,
            isPublic: managed.isPublic,
            canEdit: canEdit
        )
    }
}

public struct LibreChatAgentMetadataUpdateDTO: Encodable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var category: String

    public init(name: String, description: String, category: String) {
        self.name = name
        self.description = description
        self.category = category
    }
}

/// Permissive wrapper for LibreChat's evolving authenticated `/api/models`
/// object. Only top-level provider arrays of string model identifiers are
/// reduced into the intentionally small basic-agent creation catalog.
public struct LibreChatAgentModelCatalogDTO: Decodable, Equatable, Sendable {
    public let fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            throw DTOMapperError.invalidField("models")
        }
        self.fields = fields
    }

    public func basicAgentCreationCatalog(
        profileID: ServerProfileID,
        accountID: AccountID
    ) -> BasicAgentModelCatalog {
        let modelsByProvider = fields.reduce(into: [String: [String]]()) { result, field in
            let provider = field.key
            guard Self.isSafeProviderOrModel(provider),
                  let values = field.value.arrayValue else {
                return
            }
            var seen = Set<String>()
            let models = values.compactMap(\.stringValue).filter {
                Self.isSafeProviderOrModel($0) && seen.insert($0).inserted
            }
            guard !models.isEmpty else { return }
            result[provider] = models
        }
        return BasicAgentModelCatalog(
            profileID: profileID,
            accountID: accountID,
            modelsByProvider: modelsByProvider
        )
    }

    private static func isSafeProviderOrModel(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf16.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Minimal response projection for the agent document returned directly by
/// LibreChat's `POST /api/agents` route. Values stay optional until strict 201
/// mapping verifies both server-generated identities and the requested echo.
public struct LibreChatBasicAgentCreationResponseDTO: Decodable, Equatable, Sendable {
    public let id: String?
    public let mongoID: String?
    public let name: String?
    public let provider: String?
    public let model: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, model
        case mongoID = "_id"
    }

    public init(
        id: String? = nil,
        mongoID: String? = nil,
        name: String? = nil,
        provider: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.mongoID = mongoID
        self.name = name
        self.provider = provider
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        mongoID = try? container.decodeIfPresent(String.self, forKey: .mongoID)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
    }
}

private struct LibreChatBasicAgentCreationBodyDTO: Encodable, Sendable {
    let name: String
    let description: String?
    let instructions: String?
    let provider: String
    let model: String
    let modelParameters: ModelParametersDTO?
    let tools: [String]
    let category: String?

    init(request: BasicAgentCreationRequest) {
        name = request.name
        description = request.description
        instructions = request.instructions
        provider = request.reviewedModel.provider
        model = request.reviewedModel.model
        modelParameters = request.modelParameters.map(ModelParametersDTO.init)
        tools = []
        category = request.category
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, instructions, provider, model, tools, category
        case modelParameters = "model_parameters"
    }

    struct ModelParametersDTO: Encodable, Sendable {
        let temperature: Double?
        let topP: Double?
        let maxTokens: Int?

        init(_ parameters: BasicAgentModelParameters) {
            temperature = parameters.temperature
            topP = parameters.topP
            maxTokens = parameters.maxTokens
        }

        private enum CodingKeys: String, CodingKey {
            case temperature
            case topP = "top_p"
            case maxTokens = "max_tokens"
        }
    }
}

public struct LibreChatAgentDuplicateResponseDTO: Decodable, Equatable, Sendable {
    public var agent: LibreChatAgentDetailDTO?

    public init(agent: LibreChatAgentDetailDTO? = nil) {
        self.agent = agent
    }
}

public struct LibreChatAgentEffectivePermissionsDTO: Decodable, Equatable, Sendable {
    public var permissionBits: Int?

    public init(permissionBits: Int? = nil) {
        self.permissionBits = permissionBits
    }

    public func domainModel() throws -> AgentResourcePermissions {
        guard let permissionBits, permissionBits >= 0 else {
            throw LibreChatProtocolError.invalidResponse
        }
        return AgentResourcePermissions(
            canView: permissionBits & 1 != 0,
            canEdit: permissionBits & 2 != 0,
            canDelete: permissionBits & 4 != 0,
            canShare: permissionBits & 8 != 0
        )
    }
}

public struct LibreChatAgentDeletionResponseDTO: Decodable, Equatable, Sendable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }

    public func confirmsDeletion() -> Bool { message == "Agent deleted" }
}

/// Permissive transport wrapper for LibreChat's raw `versions` array. Entries
/// are intentionally decoded as JSONValue because historical records evolve
/// with the server and can contain sensitive expanded configuration. Mapping
/// immediately reduces each raw position to bounded, safe metadata.
public struct LibreChatAgentVersionsDTO: Decodable, Equatable, Sendable {
    public var rawVersions: [JSONValue]

    public init(rawVersions: [JSONValue]) {
        self.rawVersions = rawVersions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawVersions = try container.decode([JSONValue].self)
    }

    public func domainModel(
        agentID: AgentID,
        fetchedAt: Date = Date()
    ) -> AgentVersionHistory {
        AgentVersionHistory(
            agentID: agentID,
            versions: rawVersions.enumerated().map { serverIndex, raw in
                let object = raw.objectValue
                return AgentVersionSummary(
                    coordinate: AgentVersionCoordinate(
                        agentID: agentID,
                        serverIndex: serverIndex
                    ),
                    name: Self.safeString(object?["name"], maximumUTF16Count: 1_000),
                    description: Self.safeString(object?["description"], maximumUTF16Count: 10_000),
                    category: Self.safeString(object?["category"], maximumUTF16Count: 200),
                    createdAt: Self.date(object?["createdAt"]),
                    updatedAt: Self.date(object?["updatedAt"])
                )
            },
            fetchedAt: fetchedAt
        )
    }

    private static func safeString(
        _ value: JSONValue?,
        maximumUTF16Count: Int
    ) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf16.count <= maximumUTF16Count else {
            return nil
        }
        return normalized
    }

    private static func date(_ value: JSONValue?) -> Date? {
        guard let raw = value?.stringValue else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

public struct LibreChatAgentVersionRevertDTO: Encodable, Equatable, Sendable {
    public let versionIndex: Int

    public init(versionIndex: Int) {
        self.versionIndex = versionIndex
    }

    private enum CodingKeys: String, CodingKey {
        case versionIndex = "version_index"
    }
}

public extension SavedAgentDTO {
    /// - Parameter avatarBaseURL: the profile's server origin; the agent's
    ///   avatar filepath is resolved against it with the same policy as
    ///   target icons. Nil leaves the avatar unresolved.
    func summaryModel(avatarBaseURL: URL? = nil) throws -> ChatAgentSummary {
        guard let rawID = id?.nonEmpty ?? mongoID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("agent.id")
        }
        guard let name = name?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("agent.name")
        }
        let resolvedAvatar: URL?
        if let avatarBaseURL {
            resolvedAvatar = TargetIconURLPolicy(
                allowsInsecureLoopback: avatarBaseURL.scheme?.lowercased() == "http"
            )
            .resolve(avatar?.filepath?.nonEmpty, relativeTo: avatarBaseURL)?.url
        } else {
            resolvedAvatar = nil
        }
        return ChatAgentSummary(
            id: AgentID(rawValue: rawID),
            name: name,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            category: category?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            isPublic: isPublic == true,
            canEdit: isEditable == true,
            avatarURL: resolvedAvatar
        )
    }
}

/// Exact read-only factories for the pinned ACL-aware saved-agent routes.
public enum LibreChatAgentsAPI {
    /// Fetches fresh, authenticated provider/model evidence for basic saved
    /// agent creation. Repositories must call this immediately before
    /// `createBasic`, rather than trusting a previously displayed catalog.
    public static func modelsForBasicCreation() -> APIRequest<LibreChatAgentModelCatalogDTO> {
        APIRequest(
            path: "api/models",
            pathComponents: ["api", "models"],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    /// Builds the sole native-safe saved-agent creation body. The provider and
    /// model review must have been revalidated against a newly fetched model
    /// catalog for this exact profile and account immediately before this call.
    public static func createBasic(
        _ request: BasicAgentCreationRequest,
        validatingAgainst freshModels: BasicAgentModelCatalog
    ) throws -> APIRequest<LibreChatBasicAgentCreationResponseDTO> {
        let request = try request.validated(in: freshModels)
        return try APIRequest(
            method: .post,
            path: "api/agents",
            pathComponents: ["api", "agents"],
            body: LibreChatBasicAgentCreationBodyDTO(request: request),
            retryPolicy: .never
        )
    }

    /// Accepts a creation only when the server sent exactly `201 Created` and
    /// returned both generated identities plus an exact echo of native-safe
    /// fields. Any other status or partial/error envelope is a definite
    /// invalid response, never a successful creation.
    public static func confirmedBasicCreation(
        from response: LibreChatBasicAgentCreationResponseDTO,
        statusCode: Int,
        for request: BasicAgentCreationRequest,
        validatingAgainst freshModels: BasicAgentModelCatalog
    ) throws -> BasicAgentCreationOutcome {
        let request = try request.validated(in: freshModels)
        guard statusCode == 201,
              let rawAgentID = response.id,
              rawAgentID.hasPrefix("agent_"),
              let rawResourceID = response.mongoID,
              let responseName = response.name,
              let responseProvider = response.provider,
              let responseModel = response.model else {
            throw BasicAgentCreationError.invalidResponse
        }

        let agentID = AgentID(rawValue: rawAgentID)
        let resourceID = AgentResourceID(rawValue: rawResourceID)
        guard agentID.isSafePathComponent,
              resourceID.isSafePathComponent,
              responseName == request.name,
              responseProvider == request.reviewedModel.provider,
              responseModel == request.reviewedModel.model else {
            throw BasicAgentCreationError.invalidResponse
        }

        return .confirmed(BasicAgentCreationResult(
            agentID: agentID,
            resourceID: resourceID,
            name: responseName,
            provider: responseProvider,
            model: responseModel
        ))
    }

    public static func list(
        search: String? = nil,
        cursor: String? = nil,
        limit: Int = 25
    ) -> APIRequest<AgentListResponseDTO> {
        var queryItems = [
            URLQueryItem(name: "requiredPermission", value: "1"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))
        ]
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            queryItems.append(URLQueryItem(name: "search", value: String(search.prefix(100))))
        }
        if let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return APIRequest(
            path: "api/agents",
            queryItems: queryItems,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func detail(id: AgentID) throws -> APIRequest<LibreChatAgentDetailDTO> {
        try validate(id)
        return APIRequest(
            path: "api/agents/\(id.rawValue)",
            pathComponents: ["api", "agents", id.rawValue],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func expanded(id: AgentID) throws -> APIRequest<LibreChatAgentDetailDTO> {
        try validate(id)
        return APIRequest(
            path: "api/agents/\(id.rawValue)/expanded",
            pathComponents: ["api", "agents", id.rawValue, "expanded"],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func versions(id: AgentID) throws -> APIRequest<LibreChatAgentVersionsDTO> {
        try validate(id)
        return APIRequest(
            path: "api/agents/\(id.rawValue)/versions",
            pathComponents: ["api", "agents", id.rawValue, "versions"],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func updateMetadata(
        _ input: AgentMetadataUpdateInput
    ) throws -> APIRequest<LibreChatAgentDetailDTO> {
        try validate(input.agentID)
        let body = try metadataBody(input)
        return try APIRequest(
            method: .patch,
            path: "api/agents/\(input.agentID.rawValue)",
            pathComponents: ["api", "agents", input.agentID.rawValue],
            body: body,
            retryPolicy: .never
        )
    }

    public static func duplicate(
        id: AgentID
    ) throws -> APIRequest<LibreChatAgentDuplicateResponseDTO> {
        try validate(id)
        return APIRequest(
            method: .post,
            path: "api/agents/\(id.rawValue)/duplicate",
            pathComponents: ["api", "agents", id.rawValue, "duplicate"],
            retryPolicy: .never
        )
    }

    public static func revert(
        _ coordinate: AgentVersionCoordinate
    ) throws -> APIRequest<LibreChatAgentDetailDTO> {
        try validate(coordinate.agentID)
        guard coordinate.serverIndex >= 0 else {
            throw AgentManagementError.invalidInput("This saved agent version is no longer available.")
        }
        return try APIRequest(
            method: .post,
            path: "api/agents/\(coordinate.agentID.rawValue)/revert",
            pathComponents: ["api", "agents", coordinate.agentID.rawValue, "revert"],
            body: LibreChatAgentVersionRevertDTO(versionIndex: coordinate.serverIndex),
            retryPolicy: .never
        )
    }

    public static func effectivePermissions(
        resourceID: AgentResourceID
    ) throws -> APIRequest<LibreChatAgentEffectivePermissionsDTO> {
        guard resourceID.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("Invalid saved-agent resource identifier.")
        }
        return APIRequest(
            path: "api/permissions/agent/\(resourceID.rawValue)/effective",
            pathComponents: ["api", "permissions", "agent", resourceID.rawValue, "effective"],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func delete(
        id: AgentID
    ) throws -> APIRequest<LibreChatAgentDeletionResponseDTO> {
        try validate(id)
        return APIRequest(
            method: .delete,
            path: "api/agents/\(id.rawValue)",
            pathComponents: ["api", "agents", id.rawValue],
            retryPolicy: .never
        )
    }

    public static func metadataBody(
        _ input: AgentMetadataUpdateInput
    ) throws -> LibreChatAgentMetadataUpdateDTO {
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = input.category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1_000).contains(name.utf16.count) else {
            throw AgentManagementError.invalidInput("Enter an agent name between 1 and 1,000 characters.")
        }
        guard description.utf16.count <= 10_000 else {
            throw AgentManagementError.invalidInput("Keep the agent description under 10,000 characters.")
        }
        guard category.utf16.count <= 200 else {
            throw AgentManagementError.invalidInput("Keep the agent category under 200 characters.")
        }
        return LibreChatAgentMetadataUpdateDTO(
            name: name,
            description: description,
            category: category
        )
    }

    private static func validate(_ id: AgentID) throws {
        guard id.isSafePathComponent else {
            throw LibreChatProtocolError.encoding("Invalid saved-agent identifier.")
        }
    }
}
