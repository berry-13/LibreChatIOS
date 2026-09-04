import LibreChatDomain
import Testing

@Suite("Generation endpoint routing policy")
struct GenerationEndpointPolicyTests {
    @Test func builtInModularEndpointsUseResumableV2() {
        for endpoint in [
            "agents", "openAI", "azureOpenAI", "google",
            "anthropic", "custom", "bedrock"
        ] {
            #expect(
                GenerationEndpointPolicy.route(endpoint: endpoint).supportsResumableV2,
                "Expected \(endpoint) to use the resumable v2 ingress."
            )
            #expect(
                GenerationEndpointPolicy.route(
                    endpoint: endpoint,
                    endpointType: endpoint
                ) == .resumableV2(endpointPathComponent: endpoint)
            )
        }
        #expect(
            GenerationEndpointPolicy.route(endpoint: "agents", endpointType: "custom")
                == .resumableV2(endpointPathComponent: "agents")
        )
    }

    @Test func arbitraryCustomNamesRequireAuthenticatedTypeEvidence() {
        let names = ["My LLM Gateway", "company-internal-api", "localhost:8080"]
        for name in names {
            #expect(
                GenerationEndpointPolicy.route(endpoint: name)
                    == .unsupported(.unknownEndpointFamily)
            )
            #expect(
                GenerationEndpointPolicy.route(endpoint: name, endpointType: "custom")
                    == .resumableV2(endpointPathComponent: name)
            )
        }
    }

    @Test func assistantsRemainASeparateUnsupportedProtocolFamily() {
        #expect(
            GenerationEndpointPolicy.route(endpoint: "assistants")
                == .unsupported(.assistantsProtocol)
        )
        #expect(
            GenerationEndpointPolicy.route(endpoint: "provider", endpointType: "azureAssistants")
                == .unsupported(.assistantsProtocol)
        )
    }

    @Test func controlRouteCollisionsFailClosed() {
        for endpoint in ["abort", "resume", "steer"] {
            #expect(
                GenerationEndpointPolicy.route(endpoint: endpoint, endpointType: "custom")
                    == .unsupported(.reservedControlRoute)
            )
        }
    }

    @Test func inconsistentAndMalformedIdentitiesFailClosed() {
        #expect(
            GenerationEndpointPolicy.route(endpoint: "openAI", endpointType: "custom")
                == .unsupported(.inconsistentEndpointType)
        )
        for endpoint in ["", " openAI", "openAI ", "bad\nendpoint", String(repeating: "x", count: 257)] {
            #expect(
                GenerationEndpointPolicy.route(endpoint: endpoint)
                    == .unsupported(.invalidIdentity)
            )
        }
    }

    @Test func followUpFingerprintUsesTheSameRoutingFence() throws {
        #expect(throws: FollowUpQueueError.invalidTarget) {
            try FollowUpTargetFingerprint(endpoint: "resume", endpointType: "custom")
        }
        #expect(throws: FollowUpQueueError.invalidTarget) {
            try FollowUpTargetFingerprint(endpoint: "future-provider")
        }
        let custom = try FollowUpTargetFingerprint(
            endpoint: "My LLM Gateway",
            endpointType: "custom",
            model: "model"
        )
        #expect(custom.endpoint == "My LLM Gateway")
    }
}
