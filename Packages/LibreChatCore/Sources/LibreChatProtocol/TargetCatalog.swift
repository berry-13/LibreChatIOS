import Foundation
import LibreChatDomain

public enum AgentTargetDiscovery: Equatable, Sendable {
    case notSupported
    case available([ChatTargetOption])
    case permissionDenied
    case unavailable

    public var status: AgentTargetDiscoveryStatus {
        switch self {
        case .notSupported: .notSupported
        case .available: .available
        case .permissionDenied: .permissionDenied
        case .unavailable: .unavailable
        }
    }
}

public enum TargetCredentialEvidence: Equatable, Sendable {
    case available
    case missing
    case expired
    case unavailable
}

public enum TargetIconCredentialPolicy: String, Codable, Equatable, Sendable {
    case profileSession
    case none
}

public struct ResolvedTargetIconURL: Equatable, Sendable {
    public var url: URL
    public var credentialPolicy: TargetIconCredentialPolicy

    public init(url: URL, credentialPolicy: TargetIconCredentialPolicy) {
        self.url = url
        self.credentialPolicy = credentialPolicy
    }
}

/// Validates catalog-provided image locations without ever granting a remote
/// host access to the active profile's bearer token or cookie jar.
public struct TargetIconURLPolicy: Sendable {
    public var allowsInsecureLoopback: Bool

    public init(allowsInsecureLoopback: Bool = false) {
        self.allowsInsecureLoopback = allowsInsecureLoopback
    }

    public func resolve(_ rawValue: String?, relativeTo baseURL: URL) -> ResolvedTargetIconURL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              !rawValue.contains("\\"),
              let base = validatedHTTPURL(baseURL) else { return nil }

        if let absoluteComponents = URLComponents(string: rawValue),
           absoluteComponents.scheme != nil {
            guard absoluteComponents.user == nil,
                  absoluteComponents.password == nil,
                  absoluteComponents.fragment == nil,
                  let absolute = absoluteComponents.url,
                  let validated = validatedHTTPURL(absolute) else { return nil }
            return ResolvedTargetIconURL(
                url: validated,
                credentialPolicy: sameOrigin(validated, base) ? .profileSession : .none
            )
        }

        // LibreChat's web client classifies this field with `isImageURL`:
        // only absolute http(s) URLs and "/…"-rooted site paths are images.
        // Anything else is a named icon key (for example `iconURL: openai`)
        // resolved through its endpoint icon table — not a server asset. A
        // bare word must therefore never become a same-origin URL, or the
        // client would request `https://host/openai` and show nothing.
        guard rawValue.hasPrefix("/"),
              !rawValue.hasPrefix("//"),
              URLComponents(string: rawValue)?.fragment == nil else { return nil }
        let pathForValidation = rawValue.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawValue
        guard !containsTraversal(pathForValidation) else {
            return nil
        }

        var baseComponents = URLComponents(url: base, resolvingAgainstBaseURL: false)
        guard baseComponents?.user == nil, baseComponents?.password == nil else { return nil }
        if baseComponents?.path.hasSuffix("/") == false {
            baseComponents?.path += "/"
        }
        guard let directoryURL = baseComponents?.url,
              let resolved = URL(string: rawValue.drop(while: { $0 == "/" }).description, relativeTo: directoryURL)?.absoluteURL,
              let validated = validatedHTTPURL(resolved),
              sameOrigin(validated, base) else { return nil }
        return ResolvedTargetIconURL(url: validated, credentialPolicy: .profileSession)
    }

    private func validatedHTTPURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || (scheme == "http" && allowsInsecureLoopback && isLoopback(host)) else {
            return nil
        }
        return components.url
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    private func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    private func containsTraversal(_ path: String) -> Bool {
        var candidate = path
        for _ in 0..<8 {
            if candidate.lowercased().contains("%2e")
                || candidate.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
                return true
            }
            guard let decoded = candidate.removingPercentEncoding, decoded != candidate else {
                return false
            }
            candidate = decoded
        }
        // More than eight nested encodings is not a useful image path and is
        // rejected rather than relying on a downstream decoder's behavior.
        return true
    }
}

/// Maps authenticated LibreChat policy and discovery responses into the exact
/// account-scoped choices currently authorized for starting a conversation.
public struct TargetCatalogMapper: Sendable {
    public init() {}

    /// Resolves the public, browser-compatible companion configuration for a
    /// visible model spec. Private preset fields and server-owned policies are
    /// intentionally not reconstructed here.
    public func ephemeralAgentConfiguration(
        specName: String,
        startup: StartupConfigDTO
    ) -> EphemeralAgentConfiguration? {
        guard let values = startup.modelSpecs?.objectValue?["list"]?.arrayValue,
              let object = values.first(where: {
                  $0.objectValue?["name"]?.stringValue == specName
              })?.objectValue else {
            return nil
        }
        return Self.ephemeralAgentConfiguration(from: object)
    }

    public func snapshot(
        profileID: ServerProfileID,
        accountID: AccountID,
        fetchedAt: Date,
        baseURL: URL,
        endpoints: JSONValue,
        models: JSONValue,
        startup: StartupConfigDTO,
        agentDiscovery: AgentTargetDiscovery,
        credentialEvidence: [String: TargetCredentialEvidence] = [:],
        recentOptionID: String? = nil
    ) -> TargetCatalogSnapshot {
        let endpointObjects = endpoints.objectValue ?? [:]
        let modelObjects = models.objectValue ?? [:]
        let modelSpecs = startup.modelSpecs?.objectValue
        let rawSpecs = modelSpecs?["list"]?.arrayValue ?? []
        let enforceSpecs = modelSpecs?["enforce"]?.boolValue == true
        let modelSelectionEnabled = startup.interface?.objectValue?["modelSelect"]?.boolValue ?? true
        let addedEndpoints = Set(
            modelSpecs?["addedEndpoints"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        let iconPolicy = TargetIconURLPolicy(
            allowsInsecureLoopback: baseURL.scheme?.lowercased() == "http"
                && Self.isLoopback(baseURL.host)
        )

        var warnings: [TargetCatalogWarning] = []
        var warningSet = Set<TargetCatalogWarning>()
        func warn(_ warning: TargetCatalogWarning) {
            if warningSet.insert(warning).inserted { warnings.append(warning) }
        }

        // LibreChat-web's icon chain (`getIconKey` + `SpecIcon`): a configured
        // value that `isImageURL` accepts is loaded as an image; a bare word
        // is honored only when it names one of the built-in endpoint glyphs
        // (librechat.yaml's `iconURL: openAI`). Plain endpoints and models
        // otherwise render the client's bundled glyph — including the
        // known-endpoint logos, which the web client also ships locally.
        func resolvedIcon(explicit: String?) -> (url: URL?, endpointKey: String?) {
            guard let raw = explicit?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return (nil, nil) }
            if let resolved = iconPolicy.resolve(raw, relativeTo: baseURL) {
                return (resolved.url, nil)
            }
            if Self.builtinGlyphEndpoints.contains(raw.lowercased()) {
                return (nil, raw.lowercased())
            }
            return (nil, nil)
        }

        if agentDiscovery.status == .permissionDenied {
            warn(.agentPermissionDenied)
        } else if agentDiscovery.status == .unavailable {
            warn(.agentDiscoveryUnavailable)
        }

        let savedAgents: [ChatTargetOption]
        if case let .available(options) = agentDiscovery {
            savedAgents = options
        } else {
            savedAgents = []
        }
        let accessibleAgentIDs = Set(savedAgents.compactMap(\.target.agentID))
        // The web's `getModelSpecIconURL` prefers an explicit spec or preset
        // icon; an agent-backed spec without one shows that agent's avatar.
        let savedAgentAvatars: [String: URL] = savedAgents.reduce(into: [:]) { avatars, option in
            guard let agentID = option.target.agentID, let url = option.iconURL else { return }
            avatars[agentID] = url
        }

        var seenSpecNames = Set<String>()
        var orderedSpecs: [OrderedSpec] = []
        for (sourceIndex, value) in rawSpecs.enumerated() {
            guard value.objectValue?["showInMenu"]?.boolValue != false else { continue }
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue?.trimmedNonEmpty,
                  seenSpecNames.insert(name).inserted,
                  let preset = object["preset"]?.objectValue,
                  let ephemeralAgent = Self.ephemeralAgentConfiguration(from: object) else {
                warn(.invalidModelSpec(name: value.objectValue?["name"]?.stringValue))
                continue
            }

            let agentID = preset["agent_id"]?.stringValue?.trimmedNonEmpty
            let assistantID = preset["assistant_id"]?.stringValue?.trimmedNonEmpty
            let endpoint = preset["endpoint"]?.stringValue?.trimmedNonEmpty
                ?? (agentID != nil ? "agents" : nil)
            guard let endpoint,
                  let endpointConfig = endpointObjects[endpoint]?.objectValue,
                  !(agentID != nil && endpoint != "agents"),
                  !(assistantID != nil && endpoint != "assistants" && endpoint != "azureAssistants"),
                  !(agentID != nil && assistantID != nil) else {
                warn(.invalidModelSpec(name: name))
                continue
            }

            let endpointType = preset["endpointType"]?.stringValue?.trimmedNonEmpty
                ?? endpointConfig["type"]?.stringValue?.trimmedNonEmpty
            guard GenerationEndpointPolicy.route(
                endpoint: endpoint,
                endpointType: endpointType
            ).supportsResumableV2 else {
                warn(.unsupportedTargetKind(endpoint: endpoint))
                continue
            }
            if endpoint == "agents" {
                guard agentDiscovery.status == .available,
                      let agentID,
                      !Self.isSavedAgentID(agentID) || accessibleAgentIDs.contains(agentID) else {
                    continue
                }
            }
            guard credentialAllows(
                endpoint: endpoint,
                config: endpointConfig,
                evidence: credentialEvidence,
                warn: warn
            ) else { continue }

            let label = object["label"]?.stringValue?.trimmedNonEmpty ?? name
            // Web's `SpecIcon` chain: explicit spec/preset image, a named
            // built-in glyph, then the target agent's own avatar.
            let explicitIcon = [object["iconURL"], preset["iconURL"]]
                .compactMap { $0?.stringValue?.trimmedNonEmpty }
                .first
            let specIcon = resolvedIcon(explicit: explicitIcon)
            orderedSpecs.append(OrderedSpec(
                sourceIndex: sourceIndex,
                order: object["order"]?.intValue,
                isDefault: object["default"]?.boolValue == true,
                isSoftDefault: object["softDefault"]?.boolValue == true,
                option: ChatTargetOption(
                    id: "spec:\(name)",
                    label: label,
                    subtitle: object["description"]?.stringValue?.trimmedNonEmpty,
                    iconURL: explicitIcon == nil
                        ? agentID.flatMap { savedAgentAvatars[$0] }
                        : specIcon.url,
                    iconEndpoint: specIcon.endpointKey,
                    target: ConversationTarget(
                        endpoint: endpoint,
                        endpointType: endpointType,
                        model: preset["model"]?.stringValue?.trimmedNonEmpty,
                        agentID: agentID,
                        assistantID: assistantID,
                        spec: name,
                        ephemeralAgent: ephemeralAgent
                    )
                )
            ))
        }
        orderedSpecs.sort {
            if $0.order != $1.order {
                return ($0.order ?? Int.max) < ($1.order ?? Int.max)
            }
            return $0.sourceIndex < $1.sourceIndex
        }

        var result = orderedSpecs.map(\.option)
        if !enforceSpecs, modelSelectionEnabled {
            let orderedEndpoints = endpointObjects.keys.filter { $0.trimmedNonEmpty == $0 }.sorted { lhs, rhs in
                let leftOrder = endpointObjects[lhs]?.objectValue?["order"]?.intValue ?? Int.max
                let rightOrder = endpointObjects[rhs]?.objectValue?["order"]?.intValue ?? Int.max
                return leftOrder == rightOrder ? lhs < rhs : leftOrder < rightOrder
            }
            for endpoint in orderedEndpoints {
                guard let config = endpointObjects[endpoint]?.objectValue else { continue }
                if !addedEndpoints.isEmpty, !addedEndpoints.contains(endpoint) { continue }
                let endpointType = config["type"]?.stringValue?.trimmedNonEmpty
                guard GenerationEndpointPolicy.route(
                    endpoint: endpoint,
                    endpointType: endpointType
                ).supportsResumableV2 else {
                    warn(.unsupportedTargetKind(endpoint: endpoint))
                    continue
                }
                guard credentialAllows(
                    endpoint: endpoint,
                    config: config,
                    evidence: credentialEvidence,
                    warn: warn
                ) else { continue }

                if endpoint == "agents" {
                    if agentDiscovery.status == .available {
                        result.append(contentsOf: savedAgents)
                    }
                    continue
                }

                guard let endpointModels = modelObjects[endpoint]?.arrayValue else { continue }
                let endpointLabel = config["modelDisplayLabel"]?.stringValue?.trimmedNonEmpty
                    ?? config["name"]?.stringValue?.trimmedNonEmpty
                    ?? endpoint
                for model in endpointModels.compactMap(\.stringValue).compactMap(\.trimmedNonEmpty) {
                    // The web selector never draws per-model images for plain
                    // endpoints — only the provider row carries the endpoint's
                    // own icon, resolved here from its configured `iconURL`.
                    let endpointIcon = resolvedIcon(explicit: config["iconURL"]?.stringValue)
                    result.append(ChatTargetOption(
                        id: "endpoint:\(endpoint):\(model)",
                        label: endpointLabel == endpoint ? model : "\(endpointLabel) · \(model)",
                        iconURL: endpointIcon.url,
                        iconEndpoint: endpointIcon.endpointKey,
                        target: ConversationTarget(
                            endpoint: endpoint,
                            endpointType: endpointType,
                            model: model
                        )
                    ))
                }
            }
        }

        for endpoint in modelObjects.keys where Self.isAssistantEndpoint(endpoint) {
            warn(.unsupportedTargetKind(endpoint: endpoint))
        }

        var seenOptionIDs = Set<String>()
        result = result.filter { seenOptionIDs.insert($0.id).inserted }
        let availableIDs = Set(result.map(\.id))
        let explicitDefault = orderedSpecs.first { $0.isDefault && availableIDs.contains($0.option.id) }?.option.id
        let recentDefault = recentOptionID.flatMap { recent -> String? in
            guard availableIDs.contains(recent), !enforceSpecs || recent.hasPrefix("spec:") else { return nil }
            return recent
        }
        let softDefault = orderedSpecs.first { $0.isSoftDefault && availableIDs.contains($0.option.id) }?.option.id
        let effectiveDefault = explicitDefault ?? recentDefault ?? softDefault ?? result.first?.id

        return TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: fetchedAt,
            options: result,
            effectiveDefaultOptionID: effectiveDefault,
            agentDiscoveryStatus: agentDiscovery.status,
            warnings: warnings
        )
    }

    /// Transitional compatibility wrapper. Production discovery should use
    /// `snapshot`, which requires authenticated account and policy evidence.
    public func options(
        endpoints: JSONValue,
        models: JSONValue,
        startup: StartupConfigDTO?,
        savedAgents: [ChatTargetOption]? = nil
    ) -> [ChatTargetOption] {
        snapshot(
            profileID: ServerProfileID(rawValue: "transitional"),
            accountID: AccountID(rawValue: "transitional"),
            fetchedAt: Date(timeIntervalSince1970: 0),
            baseURL: URL(string: "https://invalid.local")!,
            endpoints: endpoints,
            models: models,
            startup: startup ?? StartupConfigDTO(),
            agentDiscovery: savedAgents.map(AgentTargetDiscovery.available) ?? .unavailable
        ).options
    }

    private func credentialAllows(
        endpoint: String,
        config: [String: JSONValue]?,
        evidence: [String: TargetCredentialEvidence],
        warn: (TargetCatalogWarning) -> Void
    ) -> Bool {
        let credentialFlags = [
            "userProvide",
            "userProvideAccessKeyId",
            "userProvideSecretAccessKey",
            "userProvideSessionToken",
            "userProvideBearerToken"
        ]
        guard credentialFlags.contains(where: { config?[$0]?.boolValue == true }) else { return true }
        switch evidence[endpoint] ?? .unavailable {
        case .available:
            return true
        case .missing:
            warn(.userKeyRequired(endpoint: endpoint))
        case .expired:
            warn(.userKeyExpired(endpoint: endpoint))
        case .unavailable:
            warn(.userKeyStatusUnavailable(endpoint: endpoint))
        }
        return false
    }

    /// Values LibreChat-web's `getIconKey` accepts as a bare icon word: the
    /// built-in endpoint names from `EModelEndpoint` that map to a client
    /// glyph component.
    private static let builtinGlyphEndpoints: Set<String> = [
        "azureopenai", "openai", "google", "anthropic", "assistants",
        "azureassistants", "agents", "custom", "bedrock",
    ]

    private static func isAssistantEndpoint(_ endpoint: String) -> Bool {
        endpoint == "assistants" || endpoint == "azureAssistants"
    }

    private static func isSavedAgentID(_ identifier: String) -> Bool {
        identifier.hasPrefix("agent_")
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// LibreChat's web client creates this object for every selected model
    /// spec. Most flags are also resolved server-side; `artifacts` is not, so
    /// omitting the companion object changes the selected spec's behavior.
    private static func ephemeralAgentConfiguration(
        from modelSpec: [String: JSONValue]
    ) -> EphemeralAgentConfiguration? {
        func boolean(_ key: String) -> Bool? {
            guard let value = modelSpec[key] else { return false }
            return value.boolValue
        }

        guard let webSearch = boolean("webSearch"),
              let fileSearch = boolean("fileSearch"),
              let executeCode = boolean("executeCode"),
              let memory = boolean("memory") else {
            return nil
        }

        let mcpServers: [String]
        if let rawMCP = modelSpec["mcpServers"] {
            guard let values = rawMCP.arrayValue else { return nil }
            let strings = values.compactMap(\.stringValue)
            guard strings.count == values.count else { return nil }
            mcpServers = strings
        } else {
            mcpServers = []
        }

        let artifacts: EphemeralAgentConfiguration.ArtifactMode
        switch modelSpec["artifacts"] {
        case nil:
            artifacts = .disabled
        case .some(.bool(false)):
            artifacts = .disabled
        case .some(.bool(true)):
            artifacts = .serverDefault
        case let .some(.string(value)):
            artifacts = value.isEmpty ? .disabled : .named(value)
        default:
            return nil
        }

        let skillScope: EphemeralSkillScope?
        switch modelSpec["skills"] {
        case nil:
            skillScope = nil
        case .some(.bool(false)):
            skillScope = .disabled
        case .some(.bool(true)):
            skillScope = .all
        case let .some(.array(values)):
            let names = values.compactMap(\.stringValue)
            guard names.count == values.count,
                  names.count <= 1_000,
                  names.allSatisfy({ SkillInvocationCatalog.isValidName($0) }) else { return nil }
            skillScope = names.isEmpty ? .disabled : .names(names)
        default:
            return nil
        }

        let configuration = EphemeralAgentConfiguration(
            mcpServers: mcpServers,
            webSearch: webSearch,
            fileSearch: fileSearch,
            executeCode: executeCode,
            memory: memory,
            artifacts: artifacts,
            skillScope: skillScope
        )
        return configuration.isSafeForRequest ? configuration : nil
    }

    private struct OrderedSpec: Sendable {
        var sourceIndex: Int
        var order: Int?
        var isDefault: Bool
        var isSoftDefault: Bool
        var option: ChatTargetOption
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
