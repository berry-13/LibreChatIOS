import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct ConversationTagsContractTests {
    @Test func tagDirectoryDTORequiresIdentityNameAndDatesButIgnoresUnknownFields() throws {
        let data = Data(
            """
            {
              "_id":"tag-1","user":"account-1","tag":"Work",
              "description":"Planning","createdAt":"2026-08-18T10:00:00.000Z",
              "updatedAt":"2026-08-18T11:00:00Z","count":3,"position":1,
              "future":{"color":"blue"}
            }
            """.utf8
        )

        let tag = try JSONDecoder()
            .decode(LibreChatConversationTagDTO.self, from: data)
            .domainModel()

        #expect(tag.id == ConversationTagID(rawValue: "tag-1"))
        #expect(tag.ownerID == AccountID(rawValue: "account-1"))
        #expect(tag.tag == "Work")
        #expect(tag.name == "Work")
        #expect(tag.description == "Planning")
        #expect(tag.conversationCount == 3)
        #expect(tag.position == 1)
        #expect(tag.createdAt < tag.updatedAt)

        let missingDate = Data(#"{"_id":"tag-1","user":"account-1","tag":"Work","count":0,"position":1}"#.utf8)
        #expect(throws: DTOMapperError.missingRequiredField("conversationTag.createdAt")) {
            try JSONDecoder().decode(LibreChatConversationTagDTO.self, from: missingDate).domainModel()
        }
    }

    @Test func directoryFactoriesUseExactRoutesRetryPoliciesAndNilOmission() throws {
        let list = LibreChatConversationTagsAPI.list()
        #expect(list.method == .get)
        #expect(list.path == "api/tags")
        #expect(list.retryPolicy == .idempotent(maximumAttempts: 2))

        let create = try LibreChatConversationTagsAPI.create(
            .init(tag: "Work", description: nil, conversationID: nil, addToConversation: nil)
        )
        #expect(create.method == .post)
        #expect(create.path == "api/tags")
        #expect(create.retryPolicy == .never)
        let createBody = try bodyObject(create)
        #expect(Set(createBody.keys) == Set(["tag"]))
        #expect(createBody["tag"] as? String == "Work")

        let update = try LibreChatConversationTagsAPI.update(
            named: "Work",
            input: UpdateConversationTagInput(tag: nil, description: "", position: 4)
        )
        #expect(update.method == .put)
        #expect(update.path == "api/tags/Work")
        #expect(update.pathComponents == ["api", "tags", "Work"])
        #expect(update.retryPolicy == .never)
        let updateBody = try bodyObject(update)
        #expect(Set(updateBody.keys) == Set(["description", "position"]))
        #expect(updateBody["description"] as? String == "")
        #expect(updateBody["position"] as? Int == 4)

        let delete = try LibreChatConversationTagsAPI.delete(named: "Work")
        #expect(delete.method == .delete)
        #expect(delete.path == "api/tags/Work")
        #expect(delete.pathComponents == ["api", "tags", "Work"])
        #expect(delete.retryPolicy == .never)
        #expect(delete.body == nil)

        let replacement = try LibreChatConversationTagsAPI.replace(
            conversationID: ConversationID(rawValue: "conversation-1"),
            tags: ["Work", "Reading"]
        )
        #expect(replacement.method == .put)
        #expect(replacement.path == "api/tags/convo/conversation-1")
        #expect(replacement.pathComponents == ["api", "tags", "convo", "conversation-1"])
        #expect(replacement.retryPolicy == .never)
        #expect(try bodyObject(replacement)["tags"] as? [String] == ["Work", "Reading"])
    }

    @Test func tagAndConversationPathComponentsArePercentEncodedExactlyOnce() async throws {
        let request = try LibreChatConversationTagsAPI.update(
            named: "Work ideas/% done",
            input: .init(tag: "Renamed")
        )
        let transport = HTTPTransport(
            baseURL: URL(string: "https://chat.example")!,
            session: URLSession(configuration: .ephemeral),
            cookieJar: ProfileCookieJar(
                profileID: ServerProfileID(rawValue: "profile"),
                baseURL: URL(string: "https://chat.example")!,
                secretStore: TagsSecretStore()
            )
        )

        let urlRequest = try await transport.request(
            method: request.method,
            path: request.path,
            pathComponents: request.pathComponents
        )

        #expect(urlRequest.url?.absoluteString == "https://chat.example/api/tags/Work%20ideas%2F%25%20done")
        #expect(urlRequest.url?.path == "/api/tags/Work ideas/% done")
    }

    @Test func replacementResponseDeduplicatesTagsInServerOrder() throws {
        let response = try JSONDecoder().decode(
            LibreChatConversationTagReplacementDTO.self,
            from: Data(#"["Work","Reading","Work","" ]"#.utf8)
        )
        #expect(response.domainModel() == ["Work", "Reading", ""])

        let list = try JSONDecoder().decode(
            LibreChatConversationTagListDTO.self,
            from: Data("[]".utf8)
        )
        #expect(try list.domainModels().isEmpty)
    }

    private func bodyObject<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor TagsSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}
