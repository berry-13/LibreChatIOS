import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

@Suite("User-provided provider credentials")
struct UserKeysContractTests {
    @Test func catalogMapsOnlyNativeCompatibleRequiredFormsAndCollapsesAzureSlots() throws {
        let endpoints: JSONValue = .object([
            "openAI": .object([
                "userProvide": .bool(true),
                "userProvideURL": .bool(true)
            ]),
            "azure-east": .object([
                "userProvide": .bool(true),
                "azure": .bool(true)
            ]),
            "azure-west": .object([
                "userProvide": .bool(true),
                "azure": .bool(true)
            ]),
            "google": .object(["userProvide": .bool(true)]),
            "bedrock": .object([
                "userProvideAccessKeyId": .bool(true),
                "userProvideSecretAccessKey": .bool(true),
                "userProvideSessionToken": .bool(false),
                "userProvideBearerToken": .bool(true)
            ]),
            "my-provider": .object([
                "type": .string("custom"),
                "userProvide": .bool(true),
                "userProvideURL": .bool(false)
            ]),
            "assistants": .object(["userProvide": .bool(true)]),
            "unconfigured": .object(["userProvideURL": .bool(true)]),
            "unsafe/name": .object(["userProvide": .bool(true)])
        ])

        let requirements = UserKeyCatalogMapper().requirements(from: endpoints)
        #expect(requirements.map(\.id.rawValue).sorted() == [
            "azureOpenAI", "bedrock", "google", "my-provider", "openAI"
        ])
        #expect(requirements.first { $0.id.rawValue == "openAI" }?.form == .openAI(allowsBaseURL: true))
        #expect(requirements.first { $0.id.rawValue == "azureOpenAI" }?.form == .azureOpenAI)
        #expect(requirements.first { $0.id.rawValue == "google" }?.form == .google)
        #expect(requirements.first { $0.id.rawValue == "my-provider" }?.form == .openAI(allowsBaseURL: false))
        #expect(requirements.filter { $0.id.rawValue == "azureOpenAI" }.count == 1)
        #expect(requirements.allSatisfy { $0.availability == .unavailable })
    }

    @Test func statusFactoryAndExpiryMappingKeepSecretsUnreadable() throws {
        let endpointID = UserKeyEndpointID(rawValue: "custom-provider")
        let request = try LibreChatUserKeysAPI.status(endpointID: endpointID)
        #expect(request.method == .get)
        #expect(request.path == "api/keys")
        #expect(request.queryItems == [URLQueryItem(name: "name", value: "custom-provider")])
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
        #expect(request.body == nil)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(UserKeyExpiryDTO(expiresAt: nil).domainAvailability(at: now) == .missing)
        #expect(UserKeyExpiryDTO(expiresAt: "never").domainAvailability(at: now) == .stored(expiresAt: nil))
        #expect(UserKeyExpiryDTO(expiresAt: "garbage").domainAvailability(at: now) == .unavailable)
        #expect(UserKeyExpiryDTO(expiresAt: "2023-01-01T00:00:00Z").domainAvailability(at: now).isUsable == false)
        #expect(UserKeyExpiryDTO(expiresAt: "2030-01-01T00:00:00.000Z").domainAvailability(at: now).isUsable)
    }

    @Test func updateAndRevokeUseExactBearerWireAndNeverRetry() throws {
        let endpointID = UserKeyEndpointID(rawValue: "provider.name")
        let expiry = Date(timeIntervalSince1970: 1_700_000_000.125)
        let update = try LibreChatUserKeysAPI.update(
            endpointID: endpointID,
            encodedValue: "private-secret",
            expiresAt: expiry
        )
        #expect(update.method == .put)
        #expect(update.path == "api/keys")
        #expect(update.authorization == .bearer)
        #expect(update.retryPolicy == .never)
        let body = try body(update)
        #expect(Set(body.keys) == ["name", "value", "expiresAt"])
        #expect(body["name"] as? String == "provider.name")
        #expect(body["value"] as? String == "private-secret")
        #expect(body["expiresAt"] as? String == "2023-11-14T22:13:20.125Z")

        let revoke = try LibreChatUserKeysAPI.revoke(endpointID: endpointID)
        #expect(revoke.method == .delete)
        #expect(revoke.pathComponents == ["api", "keys", "provider.name"])
        #expect(revoke.authorization == .bearer)
        #expect(revoke.retryPolicy == .never)
        #expect(revoke.body == nil)
    }

    @Test func openAIAndAzureEnvelopesMatchThePinnedWebClient() throws {
        let encoder = UserKeyCredentialEncoder()
        let openAI = requirement(
            "openAI",
            form: .openAI(allowsBaseURL: true)
        )
        let openAIValue = try encoder.encode(
            .openAI(apiKey: "sk-test", baseURL: "https://proxy.example/v1"),
            for: openAI
        )
        #expect(try stringObject(openAIValue) == [
            "apiKey": "sk-test",
            "baseURL": "https://proxy.example/v1"
        ])

        let azureValue = try encoder.encode(
            .azureOpenAI(
                apiKey: "azure-secret",
                instanceName: "instance",
                deploymentName: "deployment",
                apiVersion: "2025-01-01"
            ),
            for: requirement("azureOpenAI", form: .azureOpenAI)
        )
        let azureOuter = try stringObject(azureValue)
        #expect(azureOuter["baseURL"] == "")
        let nested = try #require(azureOuter["apiKey"])
        #expect(try stringObject(nested) == [
            "azureOpenAIApiKey": "azure-secret",
            "azureOpenAIApiInstanceName": "instance",
            "azureOpenAIApiDeploymentName": "deployment",
            "azureOpenAIApiVersion": "2025-01-01"
        ])
    }

    @Test func googleEnvelopeKeepsServiceAccountAsNestedJSONString() throws {
        let serviceAccount = """
        {"type":"service_account","project_id":"project-1","client_email":"service@example.com","private_key":"\(String(repeating: "x", count: 601))"}
        """
        let value = try UserKeyCredentialEncoder().encode(
            .google(apiKey: "google-key", serviceAccountJSON: serviceAccount),
            for: requirement("google", form: .google)
        )
        let outer = try stringObject(value)
        #expect(outer["GOOGLE_API_KEY"] == "google-key")
        let nested = try #require(outer["GOOGLE_SERVICE_KEY"])
        let service = try stringObject(nested)
        #expect(service["project_id"] == "project-1")
        #expect(service["client_email"] == "service@example.com")
        #expect(service["private_key"]?.count == 601)
    }

    @Test func bedrockBearerAndAccessKeyEnvelopesAreMutuallyExclusive() throws {
        let requirements = UserKeyBedrockRequirements(
            accessKeyID: true,
            secretAccessKey: true,
            sessionToken: true,
            bearerToken: true
        )
        let requirement = requirement("bedrock", form: .bedrock(requirements))
        let encoder = UserKeyCredentialEncoder()
        let bearer = try encoder.encode(
            .bedrock(
                accessKeyID: "ignored", secretAccessKey: "ignored",
                sessionToken: "ignored", bearerToken: "bearer"
            ),
            for: requirement
        )
        let bearerOuter = try stringObject(bearer)
        #expect(try stringObject(try #require(bearerOuter["apiKey"])) == ["bearerToken": "bearer"])

        let access = try encoder.encode(
            .bedrock(
                accessKeyID: "access", secretAccessKey: "secret",
                sessionToken: "session", bearerToken: nil
            ),
            for: requirement
        )
        let accessOuter = try stringObject(access)
        #expect(try stringObject(try #require(accessOuter["apiKey"])) == [
            "accessKeyId": "access",
            "secretAccessKey": "secret",
            "sessionToken": "session"
        ])
    }

    @Test func validationRejectsWrongFormsUnsafeURLsAndIncompleteGoogleJSON() throws {
        let encoder = UserKeyCredentialEncoder()
        #expect(throws: UserKeyError.incompatibleCredentialForm) {
            _ = try encoder.encode(
                .simple(secret: "secret"),
                for: requirement("openAI", form: .openAI(allowsBaseURL: true))
            )
        }
        #expect(throws: UserKeyError.self) {
            _ = try encoder.encode(
                .openAI(apiKey: "secret", baseURL: "javascript:alert(1)"),
                for: requirement("openAI", form: .openAI(allowsBaseURL: true))
            )
        }
        #expect(throws: UserKeyError.self) {
            _ = try encoder.encode(
                .google(apiKey: nil, serviceAccountJSON: "{\"project_id\":\"p\"}"),
                for: requirement("google", form: .google)
            )
        }
        #expect(throws: UserKeyError.self) {
            _ = try encoder.encode(
                .google(apiKey: "otherwise-valid", serviceAccountJSON: "\0"),
                for: requirement("google", form: .google)
            )
        }
        #expect(throws: UserKeyError.self) {
            _ = try encoder.encode(
                .bedrock(
                    accessKeyID: "access",
                    secretAccessKey: "secret",
                    sessionToken: nil,
                    bearerToken: "\0"
                ),
                for: requirement(
                    "bedrock",
                    form: .bedrock(.init(
                        accessKeyID: true,
                        secretAccessKey: true,
                        sessionToken: false,
                        bearerToken: true
                    ))
                )
            )
        }
        #expect(throws: UserKeyError.self) {
            _ = try LibreChatUserKeysAPI.status(
                endpointID: UserKeyEndpointID(rawValue: "unsafe/name")
            )
        }
    }

    @Test func expirationPresetsMatchThePinnedWebChoices() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(UserKeyExpirationPreset.allCases.count == 7)
        #expect(UserKeyExpirationPreset.thirtyMinutes.expirationDate(relativeTo: now) == now.addingTimeInterval(1_800))
        #expect(UserKeyExpirationPreset.twelveHours.expirationDate(relativeTo: now) == now.addingTimeInterval(43_200))
        #expect(UserKeyExpirationPreset.thirtyDays.expirationDate(relativeTo: now) == now.addingTimeInterval(2_592_000))
        #expect(UserKeyExpirationPreset.never.expirationDate(relativeTo: now) == nil)
    }

    private func requirement(
        _ id: String,
        form: UserKeyCredentialForm
    ) -> UserKeyRequirement {
        UserKeyRequirement(
            id: UserKeyEndpointID(rawValue: id),
            displayName: id,
            form: form,
            availability: .missing
        )
    }

    private func body<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        try object(String(data: try #require(request.body), encoding: .utf8) ?? "")
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }

    private func stringObject(_ json: String) throws -> [String: String] {
        try #require(object(json) as? [String: String])
    }
}
