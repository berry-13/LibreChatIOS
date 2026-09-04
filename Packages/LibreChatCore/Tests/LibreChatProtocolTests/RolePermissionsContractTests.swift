import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct RolePermissionsContractTests {
    @Test func userRoleDecodesAndOlderPayloadsRemainValid() throws {
        let withRole = try JSONDecoder().decode(
            LibreChatUserDTO.self,
            from: Data(#"{"id":"u-1","name":"Ada","role":"USER"}"#.utf8)
        )
        #expect(withRole.role == "USER")
        #expect(try withRole.domainModel().role == "USER")

        let old = try JSONDecoder().decode(
            LibreChatUserDTO.self,
            from: Data(#"{"id":"u-2","name":"Grace"}"#.utf8)
        )
        #expect(old.role == nil)
        #expect(try old.domainModel().role == nil)

        let oldAccount = try JSONDecoder().decode(
            UserAccount.self,
            from: Data(#"{"id":"u-3","name":"Lin"}"#.utf8)
        )
        #expect(oldAccount.role == nil)
    }

    @Test func bookmarkPermissionRequiresExplicitUseTrue() throws {
        let allowed = try role(#"{"name":"USER","permissions":{"BOOKMARKS":{"USE":true}}}"#)
        let denied = try role(#"{"name":"USER","permissions":{"BOOKMARKS":{"USE":false}}}"#)
        let missing = try role(#"{"name":"USER","permissions":{"PROMPTS":{"USE":true}}}"#)

        #expect(LibreChatRoleCapabilityMapper.supportsBookmarks(from: allowed))
        #expect(!LibreChatRoleCapabilityMapper.supportsBookmarks(from: denied))
        #expect(!LibreChatRoleCapabilityMapper.supportsBookmarks(from: missing))

        let initial = ServerCapabilities(supportsBookmarks: nil)
        #expect(LibreChatRoleCapabilityMapper.applying(allowed, to: initial).supportsBookmarks == true)
        #expect(LibreChatRoleCapabilityMapper.applying(denied, to: initial).supportsBookmarks == false)
        #expect(initial.supportsBookmarks == nil)
    }

    @Test func temporaryChatRequiresBothInterfaceAndExactRolePermission() throws {
        let allowed = try role(#"{"permissions":{"TEMPORARY_CHAT":{"USE":true}}}"#)
        let denied = try role(#"{"permissions":{"TEMPORARY_CHAT":{"USE":false}}}"#)
        let initial = ServerCapabilities(temporaryChatPolicy: TemporaryChatPolicy(
            interfaceEnabled: true,
            retentionHours: 24
        ))

        let enabled = LibreChatRoleCapabilityMapper.applying(allowed, to: initial)
        #expect(enabled.temporaryChatPolicy?.isAvailable == true)
        #expect(enabled.temporaryChatPolicy?.retentionHours == 24)
        #expect(LibreChatRoleCapabilityMapper.applying(
            denied,
            to: initial
        ).temporaryChatPolicy?.isAvailable == false)

        let interfaceDisabled = ServerCapabilities(temporaryChatPolicy: TemporaryChatPolicy(
            interfaceEnabled: false,
            retentionHours: 24
        ))
        #expect(LibreChatRoleCapabilityMapper.applying(
            allowed,
            to: interfaceDisabled
        ).temporaryChatPolicy?.isAvailable == false)
    }

    @Test func agentPermissionsRequireExplicitCurrentRoleBits() throws {
        let allowed = try role(
            #"{"permissions":{"AGENTS":{"USE":true,"CREATE":true,"SHARE":false,"SHARE_PUBLIC":true}}}"#
        )
        #expect(allowed.agentPermissions == AgentPermissions(
            use: true,
            create: true,
            share: false,
            sharePublicly: true
        ))
        let mapped = LibreChatRoleCapabilityMapper.applying(
            allowed,
            to: ServerCapabilities(supportsAgents: true)
        )
        #expect(mapped.agentPermissions?.canManageMetadata == true)

        let missing = try role(#"{"permissions":{"PROMPTS":{"USE":true}}}"#)
        #expect(missing.agentPermissions == AgentPermissions())
        #expect(LibreChatRoleCapabilityMapper.applying(
            missing,
            to: ServerCapabilities(supportsAgents: true)
        ).agentPermissions == AgentPermissions())
    }

    @Test func skillPermissionsRequireExactCurrentRoleBits() throws {
        let role = try role(
            #"{"permissions":{"SKILLS":{"USE":true,"CREATE":false,"SHARE":true,"SHARE_PUBLIC":false}}}"#
        )
        #expect(role.skillPermissions == SkillPermissions(
            use: true,
            create: false,
            share: true,
            sharePublicly: false
        ))
        let mapped = LibreChatRoleCapabilityMapper.applying(
            role,
            to: ServerCapabilities(supportsSkills: true)
        )
        #expect(mapped.skillPermissions?.use == true)

        let missing = try self.role(#"{"permissions":{"AGENTS":{"USE":true}}}"#)
        #expect(missing.skillPermissions == SkillPermissions())
    }

    @Test func roleFactoryUsesBearerIdempotentRetryAndOnePassPathEncoding() async throws {
        let request = try LibreChatRolesAPI.get(roleName: "custom role/%")
        #expect(request.method == .get)
        #expect(request.path == "api/roles/custom role/%")
        #expect(request.pathComponents == ["api", "roles", "custom role/%"])
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))

        let transport = HTTPTransport(
            baseURL: URL(string: "https://chat.example")!,
            session: URLSession(configuration: .ephemeral),
            cookieJar: ProfileCookieJar(
                profileID: ServerProfileID(rawValue: "profile"),
                baseURL: URL(string: "https://chat.example")!,
                secretStore: RoleSecretStore()
            )
        )
        let urlRequest = try await transport.request(
            method: request.method,
            path: request.path,
            pathComponents: request.pathComponents
        )
        #expect(urlRequest.url?.absoluteString == "https://chat.example/api/roles/custom%20role%2F%25")
        #expect(urlRequest.url?.path == "/api/roles/custom role/%")
        #expect(throws: LibreChatProtocolError.encoding("The role path component cannot be empty.")) {
            try LibreChatRolesAPI.get(roleName: "")
        }
    }

    @Test func capabilitiesDecodeWithoutNewBookmarkField() throws {
        let encoded = try JSONEncoder().encode(ServerCapabilities(supportsBookmarks: true))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "supportsBookmarks")
        let decoded = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.supportsBookmarks == nil)
    }

    @Test func capabilitiesDecodeWithoutNewAgentPermissionsField() throws {
        let encoded = try JSONEncoder().encode(ServerCapabilities(
            supportsAgents: true,
            agentPermissions: AgentPermissions(use: true, create: true)
        ))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "agentPermissions")
        let decoded = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.supportsAgents)
        #expect(decoded.agentPermissions == nil)
    }

    @Test func skillsCapabilityFollowsRolePermissionEvenWithoutStartupEvidence() throws {
        // Authenticated /api/config payloads carry no skills evidence, so the
        // detector's placeholder (false) must not veto the role's SKILLS
        // permission. MCP and memories follow the same role-evidence pattern.
        let allowed = try role(#"{"name":"USER","permissions":{"SKILLS":{"USE":true}}}"#)
        let denied = try role(#"{"name":"USER","permissions":{"SKILLS":{"USE":false}}}"#)
        let missing = try role(#"{"name":"USER"}"#)

        // The authenticated detector emits `false` until role evidence lands.
        let authenticatedPlaceholder = ServerCapabilities(supportsSkills: false)

        #expect(LibreChatRoleCapabilityMapper
            .applying(allowed, to: authenticatedPlaceholder).supportsSkills == true)
        #expect(LibreChatRoleCapabilityMapper
            .applying(denied, to: authenticatedPlaceholder).supportsSkills == false)
        #expect(LibreChatRoleCapabilityMapper
            .applying(missing, to: authenticatedPlaceholder).supportsSkills == false)
        #expect(authenticatedPlaceholder.supportsSkills == false)
    }

    private func role(_ json: String) throws -> LibreChatRoleDTO {
        try JSONDecoder().decode(LibreChatRoleDTO.self, from: Data(json.utf8))
    }
}

private actor RoleSecretStore: SecretStore {
    func data(for key: String) -> Data? { nil }
    func set(_ data: Data, for key: String) {}
    func remove(_ key: String) {}
}
