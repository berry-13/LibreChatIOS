import Foundation

/// Why a conversation target cannot use LibreChat's resumable generation-v2
/// ingress. The endpoint name is server data, so routing must be explicit and
/// shared by discovery, presentation, uploads, queues, and the final request.
public enum GenerationEndpointUnsupportedReason: String, Codable, Equatable, Sendable {
    case invalidIdentity
    case reservedControlRoute
    case assistantsProtocol
    case unknownEndpointFamily
    case inconsistentEndpointType
}

public enum GenerationEndpointRoute: Equatable, Sendable {
    /// LibreChat's current native-compatible start route:
    /// `POST /api/agents/chat/:endpoint` with resumable protocol v2.
    case resumableV2(endpointPathComponent: String)
    case unsupported(GenerationEndpointUnsupportedReason)

    public var supportsResumableV2: Bool {
        if case .resumableV2 = self { return true }
        return false
    }
}

/// Exact routing policy for the pinned LibreChat generation surface.
///
/// Built-in modular endpoints and server-typed custom endpoints use the
/// resumable agents ingress. Assistants use separate v1/v2 route families and
/// remain unsupported until they have their own native adapter. Control-route
/// names are rejected because Express resolves them before `/:endpoint`.
public enum GenerationEndpointPolicy {
    public static func route(for target: ConversationTarget) -> GenerationEndpointRoute {
        route(endpoint: target.endpoint, endpointType: target.endpointType)
    }

    public static func route(
        endpoint: String,
        endpointType: String? = nil
    ) -> GenerationEndpointRoute {
        guard isValidIdentity(endpoint, maximumUTF16Length: 256),
              endpoint.trimmingCharacters(in: .whitespacesAndNewlines) == endpoint else {
            return .unsupported(.invalidIdentity)
        }
        if let endpointType,
           (!isValidIdentity(endpointType, maximumUTF16Length: 64)
                || endpointType.trimmingCharacters(in: .whitespacesAndNewlines) != endpointType) {
            return .unsupported(.invalidIdentity)
        }

        if assistantEndpoints.contains(endpoint)
            || endpointType.map(assistantEndpoints.contains) == true {
            return .unsupported(.assistantsProtocol)
        }
        if reservedControlRoutes.contains(endpoint) {
            return .unsupported(.reservedControlRoute)
        }

        if endpoint == "agents" {
            // Saved/ephemeral agent conversations may expose the resolved
            // provider family as endpointType (for example `custom`) while the
            // public generation route remains `/chat/agents`.
            if let endpointType, !standardResumableEndpoints.contains(endpointType) {
                return .unsupported(.inconsistentEndpointType)
            }
            return .resumableV2(endpointPathComponent: endpoint)
        }

        if standardResumableEndpoints.contains(endpoint) {
            guard endpointType == nil || endpointType == endpoint else {
                return .unsupported(.inconsistentEndpointType)
            }
            return .resumableV2(endpointPathComponent: endpoint)
        }

        // LibreChat permits arbitrary custom endpoint display names, including
        // spaces and punctuation. The authenticated endpoint configuration's
        // `type: "custom"` evidence is what distinguishes one from an unknown
        // future route family.
        guard endpointType == "custom" else {
            return .unsupported(.unknownEndpointFamily)
        }
        return .resumableV2(endpointPathComponent: endpoint)
    }

    private static let standardResumableEndpoints: Set<String> = [
        "agents",
        "openAI",
        "azureOpenAI",
        "google",
        "anthropic",
        "custom",
        "bedrock"
    ]

    private static let assistantEndpoints: Set<String> = [
        "assistants",
        "azureAssistants"
    ]

    private static let reservedControlRoutes: Set<String> = [
        "abort",
        "resume",
        "steer"
    ]

    private static func isValidIdentity(_ value: String, maximumUTF16Length: Int) -> Bool {
        !value.isEmpty
            && value.utf16.count <= maximumUTF16Length
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
