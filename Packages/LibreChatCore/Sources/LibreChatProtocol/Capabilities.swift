import Foundation
import LibreChatDomain

public struct CapabilityDetector: Sendable {
    public init() {}

    public func detect(
        startup: StartupConfigDTO,
        mobileAuthentication: MobileAuthenticationConfigDTO? = nil,
        generation: GenerationProtocolSupport = .unknown,
        authenticated: Bool = false,
        now: Date = Date()
    ) -> CompatibilityResult {
        var authenticationMethods = Set<AuthenticationMethod>()
        if startup.emailLoginEnabled != false { authenticationMethods.insert(.email) }
        if startup.appleLoginEnabled == true { authenticationMethods.insert(.apple) }
        if startup.discordLoginEnabled == true { authenticationMethods.insert(.discord) }
        if startup.facebookLoginEnabled == true { authenticationMethods.insert(.facebook) }
        if startup.githubLoginEnabled == true { authenticationMethods.insert(.github) }
        if startup.googleLoginEnabled == true { authenticationMethods.insert(.google) }
        if startup.openidLoginEnabled == true { authenticationMethods.insert(.openID) }
        if startup.samlLoginEnabled == true { authenticationMethods.insert(.saml) }
        if startup.ldap != nil { authenticationMethods.insert(.ldap) }

        let endpointObject = startup.endpoints?.objectValue ?? [:]
        let supportsAgents = endpointObject.keys.contains("agents")
        let temporaryChatPolicy = authenticated
            ? temporaryChatPolicy(from: startup.interface)
            : nil
        let capabilities = ServerCapabilities(
            generation: generation,
            authenticatedPolicyVerified: authenticated,
            supportsAgents: supportsAgents,
            supportsMCP: startup.mcpServers != nil
                || interfaceFeatureEnabled("mcpServers", in: startup.interface)
                || containsTruthyKey("mcp", in: startup.interface),
            supportsMemories: startup.memories != nil
                || interfaceFeatureEnabled("memories", in: startup.interface)
                || containsTruthyKey("memory", in: startup.interface),
            supportsSkills: authenticated ? false : nil,
            supportsSpeech: startup.speech != nil || containsTruthyKey("speech", in: startup.interface),
            supportsProjects: startup.projects != nil || containsTruthyKey("project", in: startup.interface),
            supportsPresets: authenticated ? presetsEnabled(in: startup.interface) : nil,
            temporaryChatPolicy: temporaryChatPolicy,
            supportsSharedLinks: startup.sharedLinksEnabled,
            supportsPublicSharedLinks: startup.publicSharedLinksEnabled,
            supportsSharedLinkFileSnapshots: startup.sharedLinksSnapshotFilesEnabled,
            supportsAccountDeletion: authenticated ? startup.allowAccountDeletion : nil,
            supportsTwoFactorAuth: true,
            supportsMobileAuthentication: mobileAuthentication?.protocolVersion == 1,
            authenticationMethods: authenticationMethods,
            preLogin: preLoginCapabilities(from: startup),
            publicLegal: publicLegalConfiguration(from: startup.interface),
            detectedAt: now,
            buildIdentifier: buildIdentifier(from: startup.buildInfo)
        )

        var warnings: [CompatibilityWarning] = []
        switch generation {
        case .unknown:
            break
        case let .resumable(version) where version == 2:
            break
        case let .resumable(version):
            warnings.append(.unsupportedGenerationProtocol(version))
        case let .unsupported(version):
            warnings.append(.unsupportedGenerationProtocol(version))
            warnings.append(.resumableGenerationRequired)
        }
        return CompatibilityResult(supported: true, warnings: warnings, capabilities: capabilities)
    }

    private func temporaryChatPolicy(from interface: JSONValue?) -> TemporaryChatPolicy {
        let object = interface?.objectValue ?? [:]
        let retention = object["temporaryChatRetention"]?.intValue
        return TemporaryChatPolicy(
            // LibreChat's loaded interface default is enabled. The exact
            // current-role permission remains required before presentation.
            interfaceEnabled: object["temporaryChat"]?.boolValue != false,
            roleAllowed: nil,
            retentionHours: retention.flatMap { (1...8_760).contains($0) ? $0 : nil }
        )
    }

    private func presetsEnabled(in interface: JSONValue?) -> Bool {
        guard let advertised = interface?.objectValue?["presets"] else {
            // LibreChat's loaded interface default is enabled when the key is
            // absent. This default is trusted only after authenticated config.
            return true
        }
        return advertised.boolValue == true
    }

    private func buildIdentifier(from value: JSONValue?) -> String? {
        guard let object = value?.objectValue else { return nil }
        return object["commitShort"]?.stringValue
            ?? object["commit"]?.stringValue
            ?? object["branch"]?.stringValue
    }

    private func containsTruthyKey(_ needle: String, in value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case let .object(object):
            return object.contains { key, nested in
                (key.localizedCaseInsensitiveContains(needle) && nested.boolValue != false)
                    || containsTruthyKey(needle, in: nested)
            }
        case let .array(array):
            return array.contains { containsTruthyKey(needle, in: $0) }
        default:
            return false
        }
    }

    private func interfaceFeatureEnabled(_ key: String, in value: JSONValue?) -> Bool {
        guard let feature = value?.objectValue?[key] else { return false }
        if let enabled = feature.boolValue { return enabled }
        if let object = feature.objectValue {
            return object["use"]?.boolValue ?? true
        }
        return false
    }

    private func preLoginCapabilities(from startup: StartupConfigDTO) -> PreLoginCapabilities {
        let configuredMinimum = startup.minPasswordLength ?? 8
        return PreLoginCapabilities(
            emailLoginEnabled: startup.emailLoginEnabled != false,
            registrationEnabled: startup.registrationEnabled == true,
            passwordResetEnabled: startup.passwordResetEnabled == true,
            emailDeliveryEnabled: startup.emailEnabled == true,
            minimumPasswordLength: min(128, max(1, configuredMinimum)),
            // The pinned server exposes only web presentation metadata and no
            // native proof protocol. Any advertised Turnstile value therefore
            // fails closed, including malformed or future shapes.
            requiresWebChallenge: startup.turnstile != nil
        )
    }

    private func publicLegalConfiguration(from interface: JSONValue?) -> PublicLegalConfiguration? {
        guard let interface = interface?.objectValue else { return nil }
        let privacyObject = interface["privacyPolicy"]?.objectValue
        let termsObject = interface["termsOfService"]?.objectValue
        let privacyURL = safeExternalURL(privacyObject?["externalUrl"]?.stringValue)
        let termsURL = safeExternalURL(termsObject?["externalUrl"]?.stringValue)
        let modalContent: String = {
            guard let value = termsObject?["modalContent"] else { return "" }
            if let string = value.stringValue { return string }
            return value.arrayValue?.compactMap(\.stringValue).joined(separator: "\n\n") ?? ""
        }()

        let privacy = privacyURL.map {
            PublicLegalLink(
                externalURL: $0,
                opensExternally: privacyObject?["openNewTab"]?.boolValue ?? true
            )
        }
        let terms: PublicTermsOfService? = if termsObject != nil {
            PublicTermsOfService(
                externalURL: termsURL,
                opensExternally: termsObject?["openNewTab"]?.boolValue ?? true,
                requiresAcceptance: termsObject?["modalAcceptance"]?.boolValue == true,
                title: termsObject?["modalTitle"]?.stringValue,
                content: modalContent
            )
        } else {
            nil
        }
        guard privacy != nil || terms != nil else { return nil }
        return PublicLegalConfiguration(privacyPolicy: privacy, termsOfService: terms)
    }

    private func safeExternalURL(_ rawValue: String?) -> URL? {
        guard let rawValue, let url = URL(string: rawValue), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased()) {
            return url
        }
        return nil
    }
}
