import Foundation
import LibreChatDomain

/// The role endpoint is intentionally decoded permissively. The server's role
/// object contains many permission families, while this package retains only
/// the current user's feature-gating bits it can enforce truthfully.
public struct LibreChatRoleDTO: Decodable, Equatable, Sendable {
    public var name: String?
    public var permissions: LibreChatRolePermissionsDTO?

    public init(name: String? = nil, permissions: LibreChatRolePermissionsDTO? = nil) {
        self.name = name
        self.permissions = permissions
    }

    /// Missing permissions and an explicit false both deny access. This is a
    /// known result once a role response has been received.
    public var supportsBookmarks: Bool {
        permissions?.bookmarks?.use == true
    }

    public var memoryPermissions: MemoryPermissions {
        permissions?.memories?.domainModel() ?? MemoryPermissions()
    }

    public var mcpPermissions: MCPPermissions {
        permissions?.mcpServers?.domainModel() ?? MCPPermissions()
    }

    public var promptPermissions: PromptPermissions {
        permissions?.prompts?.domainModel() ?? PromptPermissions()
    }

    public var agentPermissions: AgentPermissions {
        permissions?.agents?.domainModel() ?? AgentPermissions()
    }

    public var skillPermissions: SkillPermissions {
        permissions?.skills?.domainModel() ?? SkillPermissions()
    }
}

public struct LibreChatRolePermissionsDTO: Decodable, Equatable, Sendable {
    public var bookmarks: LibreChatBookmarkPermissionsDTO?
    public var memories: LibreChatMemoryPermissionsDTO?
    public var prompts: LibreChatPromptPermissionsDTO?
    public var agents: LibreChatAgentPermissionsDTO?
    public var mcpServers: LibreChatMCPPermissionsDTO?
    public var temporaryChat: LibreChatUsePermissionDTO?
    public var skills: LibreChatSkillPermissionsDTO?

    public init(
        bookmarks: LibreChatBookmarkPermissionsDTO? = nil,
        memories: LibreChatMemoryPermissionsDTO? = nil,
        prompts: LibreChatPromptPermissionsDTO? = nil,
        agents: LibreChatAgentPermissionsDTO? = nil,
        mcpServers: LibreChatMCPPermissionsDTO? = nil,
        temporaryChat: LibreChatUsePermissionDTO? = nil,
        skills: LibreChatSkillPermissionsDTO? = nil
    ) {
        self.bookmarks = bookmarks
        self.memories = memories
        self.prompts = prompts
        self.agents = agents
        self.mcpServers = mcpServers
        self.temporaryChat = temporaryChat
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey {
        case bookmarks = "BOOKMARKS"
        case memories = "MEMORIES"
        case prompts = "PROMPTS"
        case agents = "AGENTS"
        case mcpServers = "MCP_SERVERS"
        case temporaryChat = "TEMPORARY_CHAT"
        case skills = "SKILLS"
    }
}

public struct LibreChatSkillPermissionsDTO: Decodable, Equatable, Sendable {
    public var use: Bool?
    public var create: Bool?
    public var share: Bool?
    public var sharePublicly: Bool?

    public init(
        use: Bool? = nil,
        create: Bool? = nil,
        share: Bool? = nil,
        sharePublicly: Bool? = nil
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
        case create = "CREATE"
        case share = "SHARE"
        case sharePublicly = "SHARE_PUBLIC"
    }

    public func domainModel() -> SkillPermissions {
        SkillPermissions(
            use: use == true,
            create: create == true,
            share: share == true,
            sharePublicly: sharePublicly == true
        )
    }
}

public struct LibreChatAgentPermissionsDTO: Decodable, Equatable, Sendable {
    public var use: Bool?
    public var create: Bool?
    public var share: Bool?
    public var sharePublicly: Bool?

    public init(
        use: Bool? = nil,
        create: Bool? = nil,
        share: Bool? = nil,
        sharePublicly: Bool? = nil
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
        case create = "CREATE"
        case share = "SHARE"
        case sharePublicly = "SHARE_PUBLIC"
    }

    public func domainModel() -> AgentPermissions {
        AgentPermissions(
            use: use == true,
            create: create == true,
            share: share == true,
            sharePublicly: sharePublicly == true
        )
    }
}

public struct LibreChatUsePermissionDTO: Decodable, Equatable, Sendable {
    public var use: Bool?

    public init(use: Bool? = nil) {
        self.use = use
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
    }
}

public struct LibreChatMCPPermissionsDTO: Decodable, Equatable, Sendable {
    public var use: Bool?
    public var create: Bool?
    public var share: Bool?
    public var sharePublicly: Bool?
    public var configureOnBehalfOf: Bool?

    public init(
        use: Bool? = nil,
        create: Bool? = nil,
        share: Bool? = nil,
        sharePublicly: Bool? = nil,
        configureOnBehalfOf: Bool? = nil
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
        self.configureOnBehalfOf = configureOnBehalfOf
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
        case create = "CREATE"
        case share = "SHARE"
        case sharePublicly = "SHARE_PUBLIC"
        case configureOnBehalfOf = "CONFIGURE_OBO"
    }

    public func domainModel() -> MCPPermissions {
        MCPPermissions(
            use: use == true,
            create: create == true,
            share: share == true,
            sharePublicly: sharePublicly == true,
            configureOnBehalfOf: configureOnBehalfOf == true
        )
    }
}

public struct LibreChatPromptPermissionsDTO: Decodable, Equatable, Sendable {
    public var use: Bool?
    public var create: Bool?
    public var share: Bool?
    public var sharePublicly: Bool?

    public init(
        use: Bool? = nil,
        create: Bool? = nil,
        share: Bool? = nil,
        sharePublicly: Bool? = nil
    ) {
        self.use = use
        self.create = create
        self.share = share
        self.sharePublicly = sharePublicly
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
        case create = "CREATE"
        case share = "SHARE"
        case sharePublicly = "SHARE_PUBLIC"
    }

    public func domainModel() -> PromptPermissions {
        PromptPermissions(
            use: use == true,
            create: create == true,
            share: share == true,
            sharePublicly: sharePublicly == true
        )
    }
}

public struct LibreChatMemoryPermissionsDTO: Decodable, Equatable, Sendable {
    public var use: Bool?
    public var create: Bool?
    public var update: Bool?
    public var read: Bool?
    public var optOut: Bool?

    public init(
        use: Bool? = nil,
        create: Bool? = nil,
        update: Bool? = nil,
        read: Bool? = nil,
        optOut: Bool? = nil
    ) {
        self.use = use
        self.create = create
        self.update = update
        self.read = read
        self.optOut = optOut
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
        case create = "CREATE"
        case update = "UPDATE"
        case read = "READ"
        case optOut = "OPT_OUT"
    }

    public func domainModel() -> MemoryPermissions {
        MemoryPermissions(
            use: use == true,
            create: create == true,
            update: update == true,
            read: read == true,
            optOut: optOut == true
        )
    }
}

public struct LibreChatBookmarkPermissionsDTO: Decodable, Equatable, Sendable {
    public var use: Bool?

    public init(use: Bool? = nil) {
        self.use = use
    }

    private enum CodingKeys: String, CodingKey {
        case use = "USE"
    }
}

/// Applies a role response to server capability state without treating the
/// interface `bookmarks` setting as authorization evidence.
public enum LibreChatRoleCapabilityMapper {
    public static func supportsBookmarks(from role: LibreChatRoleDTO) -> Bool {
        role.supportsBookmarks
    }

    public static func applying(
        _ role: LibreChatRoleDTO,
        to capabilities: ServerCapabilities
    ) -> ServerCapabilities {
        var result = capabilities
        result.supportsBookmarks = role.supportsBookmarks
        result.memoryPermissions = role.memoryPermissions
        result.promptPermissions = role.promptPermissions
        result.agentPermissions = role.agentPermissions
        result.mcpPermissions = role.mcpPermissions
        result.skillPermissions = role.skillPermissions
        // Skills have no startup-config evidence: authenticated /api/config
        // payloads strip endpoint payloads, so the role's SKILLS permission
        // is the authoritative signal. Keep explicit startup advertisement
        // (future servers) as an additional acceptance path.
        result.supportsSkills = capabilities.supportsSkills == true
            || role.skillPermissions.use
        if var temporaryChatPolicy = result.temporaryChatPolicy {
            temporaryChatPolicy.roleAllowed = role.permissions?.temporaryChat?.use == true
            result.temporaryChatPolicy = temporaryChatPolicy
        }
        return result
    }
}

/// Exact current-user role lookup. `pathComponents` carries raw values so the
/// transport percent-encodes the role name exactly once.
public enum LibreChatRolesAPI {
    public static func get(roleName: String) throws -> APIRequest<LibreChatRoleDTO> {
        guard roleName.isEmpty == false else {
            throw LibreChatProtocolError.encoding("The role path component cannot be empty.")
        }

        return APIRequest(
            method: .get,
            path: "api/roles/\(roleName)",
            pathComponents: ["api", "roles", roleName],
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }
}

public typealias LibreChatRoleAPI = LibreChatRolesAPI
