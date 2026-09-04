import Foundation
import LibreChatDomain

public struct UserKeyUpdateBodyDTO: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public var expiresAt: String

    public init(name: String, value: String, expiresAt: String) {
        self.name = name
        self.value = value
        self.expiresAt = expiresAt
    }
}

public enum LibreChatUserKeysAPI {
    public static func status(
        endpointID: UserKeyEndpointID
    ) throws -> APIRequest<UserKeyExpiryDTO> {
        guard endpointID.isSafePathComponent else {
            throw UserKeyError.endpointUnavailable
        }
        return APIRequest(
            path: "api/keys",
            queryItems: [URLQueryItem(name: "name", value: endpointID.rawValue)],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    public static func update(
        endpointID: UserKeyEndpointID,
        encodedValue: String,
        expiresAt: Date?
    ) throws -> APIRequest<EmptyResponse> {
        guard endpointID.isSafePathComponent,
              !encodedValue.isEmpty,
              encodedValue.utf8.count <= 64 * 1_024 else {
            throw UserKeyError.invalidInput("The provider credential is empty or too large.")
        }
        let body = UserKeyUpdateBodyDTO(
            name: endpointID.rawValue,
            value: encodedValue,
            expiresAt: expiresAt.map(Self.timestamp) ?? ""
        )
        return try APIRequest(
            method: .put,
            path: "api/keys",
            body: body,
            retryPolicy: .never,
            encoder: deterministicEncoder()
        )
    }

    public static func revoke(
        endpointID: UserKeyEndpointID
    ) throws -> APIRequest<EmptyResponse> {
        guard endpointID.isSafePathComponent else {
            throw UserKeyError.endpointUnavailable
        }
        return APIRequest(
            method: .delete,
            path: "api/keys/\(endpointID.rawValue)",
            pathComponents: ["api", "keys", endpointID.rawValue],
            retryPolicy: .never
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func deterministicEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public struct UserKeyCatalogMapper: Sendable {
    public init() {}

    /// Finds only credential forms that this native client can encode exactly.
    /// Unsupported assistant and agent endpoint families remain absent.
    public func requirements(from endpoints: JSONValue) -> [UserKeyRequirement] {
        guard let endpointObjects = endpoints.objectValue else { return [] }
        var requirements: [UserKeyEndpointID: UserKeyRequirement] = [:]

        for sourceName in endpointObjects.keys.sorted() {
            guard let config = endpointObjects[sourceName]?.objectValue,
                  Self.requiresUserCredential(config) else { continue }
            let isAzure = config["azure"]?.boolValue == true || sourceName == "azureOpenAI"
            let keyName = isAzure ? "azureOpenAI" : sourceName
            let endpointID = UserKeyEndpointID(rawValue: keyName)
            guard endpointID.isSafePathComponent,
                  !Self.unsupportedEndpointNames.contains(sourceName),
                  !Self.unsupportedEndpointNames.contains(keyName),
                  let form = Self.form(
                    sourceName: sourceName,
                    keyName: keyName,
                    config: config
                  ) else { continue }

            let displayName = Self.displayName(
                config["name"]?.stringValue
                    ?? config["label"]?.stringValue
                    ?? keyName
            )
            let requirement = UserKeyRequirement(
                id: endpointID,
                displayName: displayName,
                form: form,
                availability: .unavailable
            )
            // Several Azure-backed endpoint entries share LibreChat's single
            // `azureOpenAI` user-key slot. Keep one deterministic requirement.
            if requirements[endpointID] == nil || sourceName == keyName {
                requirements[endpointID] = requirement
            }
        }
        return requirements.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static let unsupportedEndpointNames: Set<String> = [
        "agents", "assistants", "azureAssistants"
    ]

    private static func requiresUserCredential(_ config: [String: JSONValue]) -> Bool {
        [
            "userProvide", "userProvideAccessKeyId", "userProvideSecretAccessKey",
            "userProvideSessionToken", "userProvideBearerToken"
        ].contains { config[$0]?.boolValue == true }
    }

    private static func form(
        sourceName: String,
        keyName: String,
        config: [String: JSONValue]
    ) -> UserKeyCredentialForm? {
        switch keyName {
        case "azureOpenAI":
            return .azureOpenAI
        case "google":
            return .google
        case "bedrock":
            let requirements = UserKeyBedrockRequirements(
                accessKeyID: config["userProvideAccessKeyId"]?.boolValue == true,
                secretAccessKey: config["userProvideSecretAccessKey"]?.boolValue == true,
                sessionToken: config["userProvideSessionToken"]?.boolValue == true,
                bearerToken: config["userProvideBearerToken"]?.boolValue == true
            )
            guard requirements.accessKeyID || requirements.secretAccessKey
                    || requirements.sessionToken || requirements.bearerToken else {
                return .simple
            }
            return .bedrock(requirements)
        case "openAI":
            return .openAI(allowsBaseURL: config["userProvideURL"]?.boolValue == true)
        default:
            let type = config["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if type == "custom" || config["userProvideURL"]?.boolValue == true {
                return .openAI(allowsBaseURL: config["userProvideURL"]?.boolValue == true)
            }
            return .simple
        }
    }

    private static func displayName(_ raw: String) -> String {
        switch raw {
        case "openAI": "OpenAI"
        case "azureOpenAI": "Azure OpenAI"
        case "google": "Google"
        case "bedrock": "Amazon Bedrock"
        case "anthropic": "Anthropic"
        default: raw
        }
    }
}

public struct UserKeyCredentialEncoder: Sendable {
    public init() {}

    public func encode(
        _ credentials: UserKeyCredentials,
        for requirement: UserKeyRequirement
    ) throws -> String {
        switch (requirement.form, credentials) {
        case (.simple, let .simple(secret)):
            return try requiredSecret(secret, label: "Provider key")

        case let (.openAI(allowsBaseURL), .openAI(apiKey, baseURL)):
            let key = try requiredSecret(apiKey, label: "API key")
            let normalizedURL = try normalizedBaseURL(baseURL, allowed: allowsBaseURL)
            return try jsonString(["apiKey": key, "baseURL": normalizedURL ?? ""])

        case let (.azureOpenAI, .azureOpenAI(apiKey, instance, deployment, version)):
            let nested = try jsonString([
                "azureOpenAIApiKey": requiredSecret(apiKey, label: "Azure API key"),
                "azureOpenAIApiInstanceName": requiredValue(instance, label: "Instance name"),
                "azureOpenAIApiDeploymentName": requiredValue(deployment, label: "Deployment name"),
                "azureOpenAIApiVersion": requiredValue(version, label: "API version")
            ])
            return try jsonString(["apiKey": nested, "baseURL": ""])

        case let (.google, .google(apiKey, serviceAccountJSON)):
            var outer: [String: String] = [:]
            if let apiKey = try optionalSecret(apiKey, label: "Google API key") {
                outer["GOOGLE_API_KEY"] = apiKey
            }
            if let serviceAccountJSON = try optionalSecret(
                serviceAccountJSON,
                label: "Google service-account JSON"
            ) {
                outer["GOOGLE_SERVICE_KEY"] = try canonicalServiceAccount(serviceAccountJSON)
            }
            guard !outer.isEmpty else {
                throw UserKeyError.invalidInput("Enter a Google API key or service-account JSON.")
            }
            return try jsonString(outer)

        case let (.bedrock(requirements), .bedrock(accessKeyID, secretAccessKey, sessionToken, bearerToken)):
            let bearer = try optionalSecret(bearerToken, label: "Bedrock bearer token")
            var inner: [String: String] = [:]
            if let bearer {
                guard requirements.bearerToken else {
                    throw UserKeyError.incompatibleCredentialForm
                }
                inner["bearerToken"] = bearer
            } else {
                if requirements.accessKeyID {
                    inner["accessKeyId"] = try requiredSecret(accessKeyID ?? "", label: "Access key ID")
                }
                if requirements.secretAccessKey {
                    inner["secretAccessKey"] = try requiredSecret(
                        secretAccessKey ?? "", label: "Secret access key"
                    )
                }
                if requirements.sessionToken {
                    inner["sessionToken"] = try requiredSecret(
                        sessionToken ?? "", label: "Session token"
                    )
                }
                guard !inner.isEmpty else {
                    throw UserKeyError.invalidInput("Enter the Bedrock credentials required by this server.")
                }
            }
            let nested = try jsonString(inner)
            return try jsonString(["apiKey": nested, "baseURL": ""])

        default:
            throw UserKeyError.incompatibleCredentialForm
        }
    }

    private func requiredSecret(_ raw: String, label: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= 32_768 else {
            throw UserKeyError.invalidInput("\(label) is empty or invalid.")
        }
        return value
    }

    private func requiredValue(_ raw: String, label: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= 2_048 else {
            throw UserKeyError.invalidInput("\(label) is empty or invalid.")
        }
        return value
    }

    private func optionalSecret(_ raw: String?, label: String) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard !value.contains("\0"), value.utf8.count <= 32_768 else {
            throw UserKeyError.invalidInput("\(label) is invalid or too large.")
        }
        return value
    }

    private func normalizedBaseURL(_ raw: String?, allowed: Bool) throws -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        guard allowed else { throw UserKeyError.incompatibleCredentialForm }
        guard value.utf8.count <= 2_048,
              let components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              let url = components.url else {
            throw UserKeyError.invalidInput("Enter a valid HTTP or HTTPS API base URL.")
        }
        return url.absoluteString
    }

    private func canonicalServiceAccount(_ raw: String) throws -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let email = dictionary["client_email"] as? String,
              email.contains("@"),
              let project = dictionary["project_id"] as? String,
              project.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
              let privateKey = dictionary["private_key"] as? String,
              privateKey.count >= 601 else {
            throw UserKeyError.invalidInput("The Google service-account JSON is incomplete or invalid.")
        }
        return try jsonString(dictionary)
    }

    private func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw UserKeyError.invalidInput("The provider credential could not be encoded.")
        }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let result = String(data: data, encoding: .utf8),
              result.utf8.count <= 64 * 1_024 else {
            throw UserKeyError.invalidInput("The provider credential is too large.")
        }
        return result
    }
}

public extension UserKeyExpiryDTO {
    func domainAvailability(at now: Date) -> UserKeyAvailability {
        guard let raw = expiresAt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .missing }
        if raw.lowercased() == "never" { return .stored(expiresAt: nil) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
            return .unavailable
        }
        return date > now ? .stored(expiresAt: date) : .expired(at: date)
    }
}
