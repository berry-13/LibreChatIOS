import Foundation
import LibreChatDomain
import LibreChatProtocol
import Testing

@Suite("Authoritative target catalog")
struct TargetCatalogTests {
    private let profileID = ServerProfileID(rawValue: "profile-a")
    private let accountID = AccountID(rawValue: "account-a")
    private let baseURL = URL(string: "https://chat.example.com/librechat")!
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func enforcedPolicyExposesOnlyAuthorizedSpecsAndUsesExplicitDefault() throws {
        let endpoints = try json(#"{"openAI":{"order":0},"agents":{"order":1}}"#)
        let models = try json(#"{"openAI":["raw-model"]}"#)
        let startup = try config(
            #"{"interface":{"modelSelect":true},"modelSpecs":{"enforce":true,"list":[{"name":"direct","order":2,"preset":{"endpoint":"openAI","model":"spec-model"}},{"name":"agent","order":1,"default":true,"preset":{"endpoint":"agents","agent_id":"agent_allowed"}}]}}"#
        )
        let agent = ChatTargetOption(
            id: "agent:agent_allowed",
            label: "Allowed",
            target: ConversationTarget(endpoint: "agents", agentID: "agent_allowed")
        )

        let snapshot = map(
            endpoints: endpoints,
            models: models,
            startup: startup,
            agentDiscovery: .available([agent]),
            recentOptionID: "endpoint:openAI:raw-model"
        )

        #expect(snapshot.options.map(\.id) == ["spec:agent", "spec:direct"])
        #expect(snapshot.effectiveDefaultOptionID == "spec:agent")
        #expect(snapshot.options.allSatisfy { $0.target.spec != nil })
    }

    @Test func modelSpecCarriesTheBrowserCompanionToolConfiguration() throws {
        let startup = try config(
            #"{"modelSpecs":{"enforce":true,"list":[{"name":"research","preset":{"endpoint":"openAI","model":"gpt"},"mcpServers":["docs","search"],"webSearch":true,"fileSearch":true,"executeCode":true,"memory":true,"artifacts":true,"skills":["review-code"]}]}}"#
        )
        let snapshot = map(
            endpoints: try json(#"{"openAI":{}}"#),
            models: .object([:]),
            startup: startup,
            agentDiscovery: .notSupported
        )

        #expect(snapshot.options.count == 1)
        #expect(snapshot.options[0].target.ephemeralAgent == EphemeralAgentConfiguration(
            mcpServers: ["docs", "search"],
            webSearch: true,
            fileSearch: true,
            executeCode: true,
            memory: true,
            artifacts: .serverDefault,
            skillScope: .names(["review-code"])
        ))
        #expect(TargetCatalogMapper().ephemeralAgentConfiguration(
            specName: "research",
            startup: startup
        ) == snapshot.options[0].target.ephemeralAgent)
    }

    @Test func malformedModelSpecCompanionPolicyFailsClosed() throws {
        let startup = try config(
            #"{"modelSpecs":{"enforce":true,"list":[{"name":"bad-bool","preset":{"endpoint":"openAI","model":"gpt"},"webSearch":"yes"},{"name":"bad-mcp","preset":{"endpoint":"openAI","model":"gpt"},"mcpServers":["ok",42]},{"name":"bad-artifacts","preset":{"endpoint":"openAI","model":"gpt"},"artifacts":{"mode":"default"}},{"name":"bad-skills","preset":{"endpoint":"openAI","model":"gpt"},"skills":["../unsafe"]}]}}"#
        )
        let snapshot = map(
            endpoints: try json(#"{"openAI":{}}"#),
            models: .object([:]),
            startup: startup,
            agentDiscovery: .notSupported
        )

        #expect(snapshot.options.isEmpty)
        #expect(snapshot.warnings == [
            .invalidModelSpec(name: "bad-bool"),
            .invalidModelSpec(name: "bad-mcp"),
            .invalidModelSpec(name: "bad-artifacts"),
            .invalidModelSpec(name: "bad-skills")
        ])
    }

    @Test func modelSelectionAndAddedEndpointPolicyGateEveryRawChoice() throws {
        let endpoints = try json(
            #"{"openAI":{"order":0},"agents":{"order":1},"custom":{"order":2}}"#
        )
        let models = try json(#"{"openAI":["gpt"],"custom":["one","two"]}"#)
        let agent = ChatTargetOption(
            id: "agent:agent_one",
            label: "Agent",
            target: ConversationTarget(endpoint: "agents", agentID: "agent_one")
        )
        let allowAgents = try config(
            #"{"interface":{"modelSelect":true},"modelSpecs":{"addedEndpoints":["agents"],"list":[]}}"#
        )
        let hidden = try config(
            #"{"interface":{"modelSelect":false},"modelSpecs":{"addedEndpoints":["agents"],"list":[]}}"#
        )

        #expect(map(
            endpoints: endpoints,
            models: models,
            startup: allowAgents,
            agentDiscovery: .available([agent])
        ).options.map(\.id) == ["agent:agent_one"])
        #expect(map(
            endpoints: endpoints,
            models: models,
            startup: hidden,
            agentDiscovery: .available([agent])
        ).options.isEmpty)
    }

    @Test func agentEvidenceSeparatesEphemeralSavedDeniedAndUnavailable() throws {
        let endpoints = try json(#"{"agents":{"order":0}}"#)
        let startup = try config(
            #"{"modelSpecs":{"enforce":true,"list":[{"name":"ephemeral","preset":{"endpoint":"agents","agent_id":"ephemeral-run"}},{"name":"saved","preset":{"endpoint":"agents","agent_id":"agent_saved"}}]}}"#
        )
        let saved = ChatTargetOption(
            id: "agent:agent_saved",
            label: "Saved",
            target: ConversationTarget(endpoint: "agents", agentID: "agent_saved")
        )

        let emptySuccess = map(
            endpoints: endpoints,
            models: .object([:]),
            startup: startup,
            agentDiscovery: .available([])
        )
        let allowed = map(
            endpoints: endpoints,
            models: .object([:]),
            startup: startup,
            agentDiscovery: .available([saved])
        )
        let denied = map(
            endpoints: endpoints,
            models: .object([:]),
            startup: startup,
            agentDiscovery: .permissionDenied
        )
        let unavailable = map(
            endpoints: endpoints,
            models: .object([:]),
            startup: startup,
            agentDiscovery: .unavailable
        )

        #expect(emptySuccess.options.map(\.id) == ["spec:ephemeral"])
        #expect(allowed.options.map(\.id) == ["spec:ephemeral", "spec:saved"])
        #expect(denied.options.isEmpty)
        #expect(denied.agentDiscoveryStatus == .permissionDenied)
        #expect(denied.warnings.contains(.agentPermissionDenied))
        #expect(unavailable.options.isEmpty)
        #expect(unavailable.warnings.contains(.agentDiscoveryUnavailable))
    }

    @Test func everyCredentialFlagRequiresNonsecretKeyEvidenceButURLAloneDoesNot() throws {
        let requiredFlags = [
            "userProvide",
            "userProvideAccessKeyId",
            "userProvideSecretAccessKey",
            "userProvideSessionToken",
            "userProvideBearerToken"
        ]
        var endpointObject: [String: JSONValue] = [
            "urlOnly": .object([
                "type": .string("custom"),
                "userProvideURL": .bool(true),
                "order": .number(99)
            ])
        ]
        var modelObject: [String: JSONValue] = ["urlOnly": .array([.string("model")])]
        var evidence: [String: TargetCredentialEvidence] = [:]
        for (index, flag) in requiredFlags.enumerated() {
            let endpoint = "key\(index)"
            endpointObject[endpoint] = .object([
                "type": .string("custom"),
                flag: .bool(true),
                "order": .number(Double(index))
            ])
            modelObject[endpoint] = .array([.string("model")])
            evidence[endpoint] = .available
        }
        let startup = try config(#"{"interface":{"modelSelect":true}}"#)

        let allAvailable = map(
            endpoints: .object(endpointObject),
            models: .object(modelObject),
            startup: startup,
            agentDiscovery: .notSupported,
            credentialEvidence: evidence
        )
        #expect(allAvailable.options.count == requiredFlags.count + 1)

        let absent = map(
            endpoints: .object(endpointObject),
            models: .object(modelObject),
            startup: startup,
            agentDiscovery: .notSupported
        )
        #expect(absent.options.map(\.target.endpoint) == ["urlOnly"])
        #expect(absent.warnings.filter {
            if case .userKeyStatusUnavailable = $0 { return true }
            return false
        }.count == requiredFlags.count)

        evidence["key0"] = .expired
        let expired = map(
            endpoints: .object(endpointObject),
            models: .object(modelObject),
            startup: startup,
            agentDiscovery: .notSupported,
            credentialEvidence: evidence
        )
        #expect(!expired.options.contains { $0.target.endpoint == "key0" })
        #expect(expired.warnings.contains(.userKeyExpired(endpoint: "key0")))
    }

    @Test func defaultPrecedenceOrderingAndPrivateFieldsRemainFailClosed() throws {
        let endpoints = try json(
            #"{"later":{"order":9,"type":"custom"},"first":{"order":1,"type":"custom"}}"#
        )
        let models = try json(#"{"later":["z"],"first":["b","a","   "]}"#)
        let startup = try config(
            #"{"interface":{"modelSelect":true},"modelSpecs":{"list":[{"name":"soft","order":5,"softDefault":true,"preset":{"endpoint":"later","model":" z ","promptPrefix":"private"}},{"name":"hard","order":6,"default":true,"preset":{"endpoint":"first","model":" b "}},{"name":"   ","preset":{"endpoint":"first","model":"b"}},{"name":"bad","preset":{"endpoint":"missing","model":"b"}}]}}"#
        )
        let hard = map(
            endpoints: endpoints,
            models: models,
            startup: startup,
            agentDiscovery: .notSupported,
            recentOptionID: "endpoint:first:a"
        )
        #expect(hard.options.map(\.id) == [
            "spec:soft", "spec:hard", "endpoint:first:b", "endpoint:first:a", "endpoint:later:z"
        ])
        #expect(hard.effectiveDefaultOptionID == "spec:hard")
        #expect(hard.options.first?.target.model == "z")
        #expect(hard.options.first?.target.promptPrefix == nil)
        #expect(hard.warnings.contains(.invalidModelSpec(name: "   ")))
        #expect(hard.warnings.contains(.invalidModelSpec(name: "bad")))

        let recentStartup = try config(
            #"{"interface":{"modelSelect":true},"modelSpecs":{"list":[{"name":"soft","softDefault":true,"preset":{"endpoint":"later","model":"z"}}]}}"#
        )
        #expect(map(
            endpoints: endpoints,
            models: models,
            startup: recentStartup,
            agentDiscovery: .notSupported,
            recentOptionID: "endpoint:first:a"
        ).effectiveDefaultOptionID == "endpoint:first:a")
        #expect(map(
            endpoints: endpoints,
            models: models,
            startup: recentStartup,
            agentDiscovery: .notSupported,
            recentOptionID: "missing"
        ).effectiveDefaultOptionID == "spec:soft")
    }

    @Test func iconPolicyPreservesSubpathsAndClassifiesCredentialScope() {
        let policy = TargetIconURLPolicy()
        let sameOrigin = policy.resolve("/images/agent.png", relativeTo: baseURL)
        let external = policy.resolve("https://cdn.example.net/avatar.png", relativeTo: baseURL)

        #expect(sameOrigin?.url == URL(string: "https://chat.example.com/librechat/images/agent.png"))
        #expect(sameOrigin?.credentialPolicy == .profileSession)
        #expect(external?.credentialPolicy == TargetIconCredentialPolicy.none)
        #expect(policy.resolve("javascript:alert(1)", relativeTo: baseURL) == nil)
        #expect(policy.resolve("file:///tmp/avatar.png", relativeTo: baseURL) == nil)
        #expect(policy.resolve("http://cdn.example.net/avatar.png", relativeTo: baseURL) == nil)
        #expect(policy.resolve("https://user:pass@cdn.example.net/avatar.png", relativeTo: baseURL) == nil)
        #expect(policy.resolve("image.png#fragment", relativeTo: baseURL) == nil)
        #expect(policy.resolve("../secret.png", relativeTo: baseURL) == nil)
        #expect(policy.resolve("%2e%2e/secret.png", relativeTo: baseURL) == nil)
        #expect(policy.resolve("%252e%252e/secret.png", relativeTo: baseURL) == nil)

        let loopback = TargetIconURLPolicy(allowsInsecureLoopback: true).resolve(
            "/avatar.png",
            relativeTo: URL(string: "http://127.0.0.1:3080/chat")!
        )
        #expect(loopback?.credentialPolicy == .profileSession)
    }

    @Test func iconPolicyTreatsNamedKeysAsNonImagesLikeLibreChatWeb() {
        // LibreChat-web's `isImageURL` only accepts absolute http(s) URLs and
        // "/…"-rooted site paths; bare words are named icon keys resolved
        // through the endpoint icon table, never requested as server assets.
        let policy = TargetIconURLPolicy()
        #expect(policy.resolve("openai", relativeTo: baseURL) == nil)
        #expect(policy.resolve("anthropic", relativeTo: baseURL) == nil)
        #expect(policy.resolve("DALL-E", relativeTo: baseURL) == nil)
        #expect(policy.resolve("assets/openai.svg", relativeTo: baseURL) == nil)
    }

    @Test func targetIconsFollowTheWebChainOfExplicitImageThenNamedGlyphKey() throws {
        let endpoints = try json(
            #"{"openAI":{"order":0},"deepseek":{"order":1,"type":"custom"},"private-gateway":{"order":2,"type":"custom","iconURL":"openAI"},"branded":{"order":3,"type":"custom","iconURL":"/assets/brand.png"}}"#
        )
        let models = try json(
            #"{"openAI":["gpt-5","gpt-4o"],"deepseek":["deepseek-chat"],"private-gateway":["mystery"],"branded":["b1"]}"#
        )
        let startup = try config(
            #"{"interface":{"modelSelect":true},"modelSpecs":{"list":[{"name":"research","iconURL":"anthropic","preset":{"endpoint":"openAI","model":"gpt-5"}},{"name":"writer","iconURL":"https://cdn.example.net/writer.png","preset":{"endpoint":"deepseek"}}]}}"#
        )
        let snapshot = map(
            endpoints: endpoints,
            models: models,
            startup: startup,
            agentDiscovery: .notSupported
        )

        func option(_ id: String) throws -> ChatTargetOption {
            try #require(snapshot.options.first { $0.id == id })
        }
        // Plain endpoints and models never carry per-model images; the web
        // builds modelIcons client-side only for agents/assistants, and the
        // known-endpoint logos (deepseek and friends) are bundled in the
        // client, keyed by endpoint name at render time.
        #expect(try option("endpoint:openAI:gpt-5").iconURL == nil)
        #expect(try option("endpoint:deepseek:deepseek-chat").iconURL == nil)
        #expect(try option("endpoint:deepseek:deepseek-chat").iconEndpoint == nil)
        // A custom endpoint may point its icon at a built-in glyph by name…
        #expect(try option("endpoint:private-gateway:mystery").iconEndpoint == "openai")
        // …or at a server-hosted image path.
        #expect(try option("endpoint:branded:b1").iconURL
            == URL(string: "https://chat.example.com/librechat/assets/brand.png"))
        // Spec icons: a named glyph key travels as iconEndpoint; images as URLs.
        #expect(try option("spec:research").iconEndpoint == "anthropic")
        #expect(try option("spec:research").iconURL == nil)
        #expect(try option("spec:writer").iconURL
            == URL(string: "https://cdn.example.net/writer.png"))
    }

    @Test func agentBackedSpecsUseTheAgentAvatarAsIconFallback() throws {
        let agent = try SavedAgentDTO(
            id: "agent_local",
            name: "Local",
            avatar: SavedAgentAvatarDTO(filepath: "/images/local.png")
        ).targetOption(baseURL: baseURL)
        let startup = try config(
            #"{"interface":{"modelSelect":true},"modelSpecs":{"list":[{"name":"helper","preset":{"endpoint":"agents","agent_id":"agent_local"}},{"name":"overridden","iconURL":"/images/spec.png","preset":{"endpoint":"agents","agent_id":"agent_local"}}]}}"#
        )
        let snapshot = map(
            endpoints: try json(#"{"agents":{"order":0}}"#),
            models: try json(#"{"agents":[]}"#),
            startup: startup,
            agentDiscovery: .available([agent])
        )

        func spec(_ id: String) throws -> ChatTargetOption {
            try #require(snapshot.options.first { $0.id == id })
        }
        // Web's getModelSpecIconURL: an explicit spec image wins, otherwise
        // an agent-backed spec shows that agent's avatar.
        #expect(try spec("spec:helper").iconURL
            == URL(string: "https://chat.example.com/librechat/images/local.png"))
        #expect(try spec("spec:overridden").iconURL
            == URL(string: "https://chat.example.com/librechat/images/spec.png"))
    }

    @Test func savedAgentMappingUsesTheSameSafeSubpathAwareIconPolicy() throws {
        let local = SavedAgentDTO(
            id: "agent_local",
            name: "Local",
            avatar: SavedAgentAvatarDTO(filepath: "/images/local.png")
        )
        let unsafe = SavedAgentDTO(
            id: "agent_unsafe",
            name: "Unsafe",
            avatar: SavedAgentAvatarDTO(filepath: "javascript:alert(1)")
        )

        #expect(try local.targetOption(baseURL: baseURL).iconURL
            == URL(string: "https://chat.example.com/librechat/images/local.png"))
        #expect(try unsafe.targetOption(baseURL: baseURL).iconURL == nil)

        let normalized = SavedAgentDTO(id: "   ", mongoID: " agent_fallback ", name: "   ")
        let normalizedOption = try normalized.targetOption(baseURL: baseURL)
        #expect(normalizedOption.id == "agent:agent_fallback")
        #expect(normalizedOption.label == "agent_fallback")
        #expect(throws: DTOMapperError.missingRequiredField("agent.id")) {
            try SavedAgentDTO(id: "  ", mongoID: "\n", name: "Name").targetOption(baseURL: baseURL)
        }
    }

    @Test func unsupportedAndControlRouteEndpointsAreNeverAdvertised() throws {
        let endpoints = try json(
            #"{"openAI":{"order":0},"Custom Gateway":{"order":1,"type":"custom"},"unknown":{"order":2},"resume":{"order":3,"type":"custom"},"assistants":{"order":4}}"#
        )
        let models = try json(
            #"{"openAI":["gpt"],"Custom Gateway":["custom-model"],"unknown":["future"],"resume":["bad"],"assistants":["assistant"]}"#
        )
        let snapshot = map(
            endpoints: endpoints,
            models: models,
            startup: try config(#"{"interface":{"modelSelect":true}}"#),
            agentDiscovery: .notSupported
        )

        #expect(snapshot.options.map(\.target.endpoint) == ["openAI", "Custom Gateway"])
        #expect(snapshot.options.last?.target.endpointType == "custom")
        #expect(snapshot.warnings.contains(.unsupportedTargetKind(endpoint: "unknown")))
        #expect(snapshot.warnings.contains(.unsupportedTargetKind(endpoint: "resume")))
        #expect(snapshot.warnings.contains(.unsupportedTargetKind(endpoint: "assistants")))
    }

    private func map(
        endpoints: JSONValue,
        models: JSONValue,
        startup: StartupConfigDTO,
        agentDiscovery: AgentTargetDiscovery,
        credentialEvidence: [String: TargetCredentialEvidence] = [:],
        recentOptionID: String? = nil
    ) -> TargetCatalogSnapshot {
        TargetCatalogMapper().snapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: fetchedAt,
            baseURL: baseURL,
            endpoints: endpoints,
            models: models,
            startup: startup,
            agentDiscovery: agentDiscovery,
            credentialEvidence: credentialEvidence,
            recentOptionID: recentOptionID
        )
    }

    private func json(_ value: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
    }

    private func config(_ value: String) throws -> StartupConfigDTO {
        try JSONDecoder().decode(StartupConfigDTO.self, from: Data(value.utf8))
    }
}
