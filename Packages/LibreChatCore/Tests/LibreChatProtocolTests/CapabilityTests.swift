import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct CapabilityTests {
    @Test func unknownGenerationSupportAllowsFirstSendNegotiation() {
        #expect(GenerationProtocolSupport.unknown.canGenerate)
    }

    @Test func derivesLoginAndFeatureCapabilities() throws {
        let data = Data(
            """
            {
              "emailLoginEnabled":true,
              "registrationEnabled":true,
              "passwordResetEnabled":true,
              "emailEnabled":true,
              "minPasswordLength":12,
              "googleLoginEnabled":true,
              "openidLoginEnabled":true,
              "sharedLinksEnabled":true,
              "publicSharedLinksEnabled":false,
              "sharedLinksSnapshotFilesEnabled":true,
              "endpoints":{"agents":{}},
              "turnstile":{"siteKey":"public-site-key"},
              "interface":{
                "mcp":true,
                "memory":true,
                "privacyPolicy":{"externalUrl":"https://example.com/privacy"},
                "termsOfService":{
                  "externalUrl":"https://example.com/terms",
                  "modalAcceptance":true,
                  "modalTitle":"Community terms",
                  "modalContent":["First", "Second"]
                }
              },
              "buildInfo":{"commitShort":"abc123"}
            }
            """.utf8
        )
        let config = try JSONDecoder().decode(StartupConfigDTO.self, from: data)
        let result = CapabilityDetector().detect(
            startup: config,
            mobileAuthentication: MobileAuthenticationConfigDTO(protocolVersion: 1),
            generation: .resumable(version: 2),
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(result.supported)
        #expect(result.capabilities.authenticatedPolicyVerified == false)
        #expect(result.capabilities.authenticationMethods == [.email, .google, .openID])
        #expect(result.capabilities.supportsAgents)
        #expect(result.capabilities.supportsMCP)
        #expect(result.capabilities.supportsMemories)
        #expect(result.capabilities.supportsSharedLinks == true)
        #expect(result.capabilities.supportsPublicSharedLinks == false)
        #expect(result.capabilities.supportsSharedLinkFileSnapshots == true)
        #expect(result.capabilities.supportsMobileAuthentication)
        #expect(result.capabilities.buildIdentifier == "abc123")
        #expect(result.capabilities.preLogin?.registrationEnabled == true)
        #expect(result.capabilities.preLogin?.passwordResetEnabled == true)
        #expect(result.capabilities.preLogin?.emailDeliveryEnabled == true)
        #expect(result.capabilities.preLogin?.minimumPasswordLength == 12)
        #expect(result.capabilities.preLogin?.requiresWebChallenge == true)
        #expect(result.capabilities.publicLegal?.privacyPolicy?.externalURL.host == "example.com")
        #expect(result.capabilities.publicLegal?.termsOfService?.requiresAcceptance == true)
        #expect(result.capabilities.publicLegal?.termsOfService?.content == "First\n\nSecond")
    }

    @Test func authenticatedEvidenceAndFailClosedProjectionAreExplicitAndBackwardSafe() throws {
        let config = try JSONDecoder().decode(
            StartupConfigDTO.self,
            from: Data(
                #"{"sharedLinksEnabled":true,"publicSharedLinksEnabled":true,"interface":{"mcpServers":{"use":true},"memories":true,"temporaryChat":true,"temporaryChatRetention":48},"endpoints":{"agents":{}}}"#.utf8
            )
        )
        let authenticated = CapabilityDetector().detect(
            startup: config,
            authenticated: true,
            now: Date(timeIntervalSince1970: 10)
        ).capabilities

        #expect(authenticated.authenticatedPolicyVerified == true)
        #expect(authenticated.supportsAgents)
        #expect(authenticated.supportsMCP)
        #expect(authenticated.supportsMemories)
        #expect(authenticated.supportsPresets == true)
        #expect(authenticated.temporaryChatPolicy == TemporaryChatPolicy(
            interfaceEnabled: true,
            roleAllowed: nil,
            retentionHours: 48
        ))

        let failed = authenticated.failingClosedAuthenticatedPolicy(
            at: Date(timeIntervalSince1970: 20)
        )
        #expect(failed.authenticatedPolicyVerified == false)
        #expect(!failed.supportsAgents)
        #expect(!failed.supportsMCP)
        #expect(failed.mcpPermissions == nil)
        #expect(!failed.supportsMemories)
        #expect(failed.memoryPermissions == nil)
        #expect(failed.promptPermissions == nil)
        #expect(failed.supportsPresets == nil)
        #expect(!failed.supportsSpeech)
        #expect(failed.speechCapabilities == nil)
        #expect(failed.temporaryChatPolicy == nil)
        #expect(failed.supportsSharedLinks == nil)
        #expect(failed.supportsPublicSharedLinks == nil)
        #expect(failed.supportsSharedLinkFileSnapshots == nil)
        #expect(failed.detectedAt == Date(timeIntervalSince1970: 20))
        #expect(failed.authenticationMethods == authenticated.authenticationMethods)
        #expect(failed.generation == authenticated.generation)

        let legacy = try JSONDecoder().decode(
            ServerCapabilities.self,
            from: JSONEncoder().encode(ServerCapabilities())
        )
        #expect(legacy.authenticatedPolicyVerified == nil)
    }

    @Test func presetInterfacePolicyRequiresAuthenticatedBooleanEvidence() throws {
        let disabled = try JSONDecoder().decode(
            StartupConfigDTO.self,
            from: Data(#"{"interface":{"presets":false}}"#.utf8)
        )
        let malformed = try JSONDecoder().decode(
            StartupConfigDTO.self,
            from: Data(#"{"interface":{"presets":{"future":true}}}"#.utf8)
        )

        #expect(CapabilityDetector().detect(startup: disabled).capabilities.supportsPresets == nil)
        #expect(CapabilityDetector().detect(
            startup: disabled,
            authenticated: true
        ).capabilities.supportsPresets == false)
        #expect(CapabilityDetector().detect(
            startup: malformed,
            authenticated: true
        ).capabilities.supportsPresets == false)
        #expect(CapabilityDetector().detect(
            startup: StartupConfigDTO(),
            authenticated: true
        ).capabilities.supportsPresets == true)
    }

    @Test func temporaryChatPolicyRequiresAuthenticatedEvidenceAndValidRetention() throws {
        let startup = try JSONDecoder().decode(
            StartupConfigDTO.self,
            from: Data(#"{"interface":{"temporaryChat":false,"temporaryChatRetention":9000}}"#.utf8)
        )

        #expect(CapabilityDetector().detect(startup: startup).capabilities.temporaryChatPolicy == nil)
        #expect(CapabilityDetector().detect(
            startup: startup,
            authenticated: true
        ).capabilities.temporaryChatPolicy == TemporaryChatPolicy(
            interfaceEnabled: false,
            roleAllowed: nil,
            retentionHours: nil
        ))
    }

    @Test func legalConfigurationRejectsUnsafeExternalURLs() throws {
        let config = try JSONDecoder().decode(
            StartupConfigDTO.self,
            from: Data(
                #"{"interface":{"privacyPolicy":{"externalUrl":"javascript:alert(1)"},"termsOfService":{"externalUrl":"http://remote.example/terms"}}}"#.utf8
            )
        )
        let result = CapabilityDetector().detect(startup: config)

        #expect(result.capabilities.publicLegal?.privacyPolicy == nil)
        #expect(result.capabilities.publicLegal?.termsOfService?.externalURL == nil)
    }

    @Test func anyAdvertisedTurnstileShapeFailsNativeRegistrationClosed() throws {
        for rawJSON in [
            #"{"registrationEnabled":true,"turnstile":{}}"#,
            #"{"registrationEnabled":true,"turnstile":{"siteKey":""}}"#,
            #"{"registrationEnabled":true,"turnstile":"future-shape"}"#
        ] {
            let config = try JSONDecoder().decode(
                StartupConfigDTO.self,
                from: Data(rawJSON.utf8)
            )
            let result = CapabilityDetector().detect(startup: config)
            #expect(result.capabilities.preLogin?.registrationEnabled == true)
            #expect(result.capabilities.preLogin?.requiresWebChallenge == true)
        }
    }

    @Test func unsupportedGenerationDegradesWithoutRejectingServer() {
        let result = CapabilityDetector().detect(
            startup: StartupConfigDTO(),
            generation: .unsupported(advertisedVersion: 1)
        )
        #expect(result.supported)
        #expect(!result.capabilities.generation.canGenerate)
        #expect(result.warnings.contains(.resumableGenerationRequired))
    }
}
