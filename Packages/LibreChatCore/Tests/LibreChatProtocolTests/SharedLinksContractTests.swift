import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct SharedLinksContractTests {
    @Test func lookupMapsAbsentAndLiveStatesWithoutConflatingIdentifiers() throws {
        let conversationID = ConversationID(rawValue: "conversation-1")
        let absent = try JSONDecoder().decode(
            SharedLinkLookupDTO.self,
            from: Data(#"{"success":false,"shareId":null,"conversationId":"conversation-1"}"#.utf8)
        ).domainModel(requestedConversationID: conversationID)
        #expect(absent.conversationID == conversationID)
        #expect(absent.link == nil)
        #expect(!absent.isShared)

        let live = try JSONDecoder().decode(
            SharedLinkLookupDTO.self,
            from: Data(#"{"_id":"507f1f77bcf86cd799439011","success":true,"shareId":"share-safe-id","targetMessageId":"message-9","snapshotFiles":false,"conversationId":"conversation-1"}"#.utf8)
        ).domainModel(requestedConversationID: conversationID)
        let link = try #require(live.link)
        #expect(link.shareID == SharedLinkID(rawValue: "share-safe-id"))
        #expect(link.resourceID == "507f1f77bcf86cd799439011")
        #expect(link.conversationID == conversationID)
        #expect(link.targetMessageID == MessageID(rawValue: "message-9"))
        #expect(link.snapshotFiles == false)
    }

    @Test func lookupAndMutationMappingRejectMissingShareIDInSuccessfulShapes() throws {
        let conversationID = ConversationID(rawValue: "conversation-1")
        let lookup = try JSONDecoder().decode(
            SharedLinkLookupDTO.self,
            from: Data(#"{"success":true,"conversationId":"conversation-1"}"#.utf8)
        )
        #expect(throws: DTOMapperError.missingRequiredField("sharedLink.shareId")) {
            try lookup.domainModel(requestedConversationID: conversationID)
        }

        let mutation = try JSONDecoder().decode(
            SharedLinkMutationResponseDTO.self,
            from: Data(#"{"conversationId":"conversation-1"}"#.utf8)
        )
        #expect(throws: DTOMapperError.missingRequiredField("sharedLink.shareId")) {
            try mutation.domainModel()
        }
    }

    @Test func requestFactoriesUseExactOwnerLifecyclePathsMethodsAndRetryPolicies() throws {
        let conversationID = ConversationID(rawValue: "conversation-1")
        let shareID = SharedLinkID(rawValue: "share-safe-id")
        let payload = SharedLinkPublishRequest(
            targetMessageID: MessageID(rawValue: "message-9"),
            snapshotFiles: false
        )

        let lookup = LibreChatSharedLinksAPI.lookup(conversationID: conversationID)
        #expect(lookup.method == .get)
        #expect(lookup.path == "api/share/link/conversation-1")
        #expect(lookup.retryPolicy == .idempotent(maximumAttempts: 2))

        let create = try LibreChatSharedLinksAPI.create(conversationID: conversationID, request: payload)
        #expect(create.method == .post)
        #expect(create.path == "api/share/conversation-1")
        #expect(create.retryPolicy == .never)
        #expect(try bodyObject(create) as NSDictionary == ["targetMessageId": "message-9", "snapshotFiles": false] as NSDictionary)

        let update = try LibreChatSharedLinksAPI.update(shareID: shareID, request: payload)
        #expect(update.method == .patch)
        #expect(update.path == "api/share/share-safe-id")
        #expect(update.retryPolicy == .never)
        #expect(try bodyObject(update) as NSDictionary == ["targetMessageId": "message-9", "snapshotFiles": false] as NSDictionary)

        let delete = try LibreChatSharedLinksAPI.delete(shareID: shareID)
        #expect(delete.method == .delete)
        #expect(delete.path == "api/share/share-safe-id")
        #expect(delete.retryPolicy == .never)
        #expect(delete.body == nil)

        let unsafeShareID = SharedLinkID(rawValue: "../owner")
        #expect(throws: LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")) {
            try LibreChatSharedLinksAPI.update(shareID: unsafeShareID, request: payload)
        }
        #expect(throws: LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")) {
            try LibreChatSharedLinksAPI.delete(shareID: unsafeShareID)
        }
    }

    @Test func publicationRequestOmitsNilOptionalFields() throws {
        let request = try LibreChatSharedLinksAPI.create(
            conversationID: ConversationID(rawValue: "conversation-1"),
            request: SharedLinkPublishRequest()
        )
        #expect(try bodyObject(request).isEmpty)
    }

    private func bodyObject<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
