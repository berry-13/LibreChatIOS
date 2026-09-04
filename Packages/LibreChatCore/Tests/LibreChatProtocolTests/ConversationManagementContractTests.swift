import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct ConversationManagementContractTests {
    @Test func conversationManagementMutationsUseExactRoutesBodiesAndNeverRetry() throws {
        let conversationID = ConversationID(rawValue: "conversation-1")

        let rename = try LibreChatConversationManagementAPI.rename(
            conversationID: conversationID,
            title: "Renamed thread"
        )
        #expect(rename.method == .post)
        #expect(rename.path == "api/convos/update")
        #expect(rename.retryPolicy == .never)
        let renameArgument = try bodyArgument(rename)
        #expect(Set(renameArgument.keys) == Set(["conversationId", "title"]))
        #expect(renameArgument["conversationId"] as? String == "conversation-1")
        #expect(renameArgument["title"] as? String == "Renamed thread")

        let archive = try LibreChatConversationManagementAPI.archive(
            conversationID: conversationID,
            isArchived: false
        )
        #expect(archive.method == .post)
        #expect(archive.path == "api/convos/archive")
        #expect(archive.retryPolicy == .never)
        let archiveArgument = try bodyArgument(archive)
        #expect(Set(archiveArgument.keys) == Set(["conversationId", "isArchived"]))
        #expect(archiveArgument["conversationId"] as? String == "conversation-1")
        #expect(archiveArgument["isArchived"] as? Bool == false)

        let pin = try LibreChatConversationManagementAPI.pin(
            conversationID: conversationID,
            pinned: true
        )
        #expect(pin.method == .post)
        #expect(pin.path == "api/convos/pin")
        #expect(pin.retryPolicy == .never)
        let pinArgument = try bodyArgument(pin)
        #expect(Set(pinArgument.keys) == Set(["conversationId", "pinned"]))
        #expect(pinArgument["conversationId"] as? String == "conversation-1")
        #expect(pinArgument["pinned"] as? Bool == true)
    }

    @Test func conversationManagementResponsesPreserveOptionalMetadataAndPinAlias() throws {
        let absent = try JSONDecoder().decode(
            LibreChatConversationDTO.self,
            from: Data(#"{"conversationId":"conversation-1","title":"Thread"}"#.utf8)
        ).domainModel()
        #expect(absent.isArchived == nil)
        #expect(absent.pinned == nil)
        #expect(absent.tags == nil)

        let explicit = try JSONDecoder().decode(
            LibreChatConversationDTO.self,
            from: Data(#"{"conversationId":"conversation-1","title":"Thread","isArchived":false,"pinned":false,"tags":[]}"#.utf8)
        ).domainModel()
        #expect(explicit.isArchived == false)
        #expect(explicit.pinned == false)
        #expect(explicit.tags == [])

        let legacyPin = try JSONDecoder().decode(
            LibreChatConversationDTO.self,
            from: Data(#"{"conversationId":"conversation-1","title":"Thread","isPinned":true,"tags":["work","swift"]}"#.utf8)
        ).domainModel()
        #expect(legacyPin.pinned == true)
        #expect(legacyPin.tags == ["work", "swift"])
    }

    private func bodyObject<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bodyArgument<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        try #require(bodyObject(request)["arg"] as? [String: Any])
    }
}
