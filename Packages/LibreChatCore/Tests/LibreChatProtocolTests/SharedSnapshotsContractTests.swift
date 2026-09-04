import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct SharedSnapshotsContractTests {
    @Test func snapshotMapsPseudonymizedIdentifiersAndShareScopedFiles() throws {
        let data = Data(
            #"""
            {
              "shareId":"share-1",
              "conversationId":"convo_pseudonym",
              "title":"Published thread",
              "createdAt":"2026-08-18T10:00:00Z",
              "updatedAt":"2026-08-18T10:05:00Z",
              "messages":[{
                "messageId":"msg_pseudonym",
                "parentMessageId":"NO_PARENT",
                "conversationId":"convo_pseudonym",
                "sender":"Assistant",
                "text":"Hello",
                "files":[{
                  "file_id":"file /?one",
                  "filename":"report.pdf",
                  "filepath":"/api/files/private-owner-path",
                  "type":"application/pdf",
                  "bytes":42
                }]
              }]
            }
            """#.utf8
        )
        let snapshot = try JSONDecoder().decode(SharedConversationSnapshotDTO.self, from: data).domainModel()

        #expect(snapshot.shareID == SharedLinkID(rawValue: "share-1"))
        #expect(snapshot.conversationID == SharedConversationID(rawValue: "convo_pseudonym"))
        #expect(snapshot.revision == SharedSnapshotRevision(rawValue: "2026-08-18T10:05:00Z"))
        let message = try #require(snapshot.messages.first)
        #expect(message.id == SharedMessageID(rawValue: "msg_pseudonym"))
        #expect(message.conversationID == snapshot.conversationID)
        let file = try #require(message.files.first)
        #expect(file.access.path == "/api/share/share-1/files/file%20%2F%3Fone")
        #expect(file.access.downloadPath == "/api/share/share-1/files/file%20%2F%3Fone/download")
        #expect(file.uploadedFile.filepath == file.access.path)
        #expect(!file.access.path.contains("private-owner-path"))
    }

    @Test func snapshotMappingRejectsMissingShareIDAndMismatchedMessageConversation() throws {
        let missingShare = try JSONDecoder().decode(
            SharedConversationSnapshotDTO.self,
            from: Data(#"{"conversationId":"convo","messages":[]}"#.utf8)
        )
        #expect(throws: DTOMapperError.missingRequiredField("sharedSnapshot.shareId")) {
            try missingShare.domainModel()
        }

        let mismatchedMessage = try JSONDecoder().decode(
            SharedConversationSnapshotDTO.self,
            from: Data(#"{"shareId":"share-1","conversationId":"convo-one","messages":[{"messageId":"msg","conversationId":"convo-two"}]}"#.utf8)
        )
        #expect(throws: DTOMapperError.invalidField("sharedSnapshot.message.conversationId")) {
            try mismatchedMessage.domainModel()
        }
    }

    @Test func snapshotAndForkFactoriesUseExactAuthorizationPathsBodiesAndRetries() throws {
        let shareID = SharedLinkID(rawValue: "share-1")
        let snapshot = try LibreChatSharedSnapshotsAPI.snapshot(shareID: shareID)
        #expect(snapshot.method == .get)
        #expect(snapshot.path == "api/share/share-1")
        #expect(snapshot.authorization == .none)
        #expect(snapshot.retryPolicy == .idempotent(maximumAttempts: 2))

        let fork = try LibreChatSharedSnapshotsAPI.fork(.init(
            shareID: shareID,
            targetMessageIndex: 3,
            shareRevision: SharedSnapshotRevision(rawValue: "2026-08-18T10:05:00.000Z")
        ))
        #expect(fork.method == .post)
        #expect(fork.path == "api/share/share-1/fork")
        #expect(fork.authorization == .bearer)
        #expect(fork.retryPolicy == .never)
        #expect(try bodyObject(fork) as NSDictionary == [
            "targetMessageIndex": 3,
            "shareRevision": "2026-08-18T10:05:00.000Z"
        ] as NSDictionary)
    }

    @Test func forkRequestOmitsNilCoordinatesAndResponseRestoresCanonicalIdentifiers() throws {
        let request = try LibreChatSharedSnapshotsAPI.fork(.init(shareID: SharedLinkID(rawValue: "share-1")))
        #expect(try bodyObject(request).isEmpty)

        let response = try JSONDecoder().decode(
            SharedConversationForkResponseDTO.self,
            from: Data(#"{"conversation":{"conversationId":"owned-conversation","title":"Forked"},"messages":[{"messageId":"owned-message","conversationId":"owned-conversation","isCreatedByUser":true,"text":"Hello"}]}"#.utf8)
        ).domainModel()
        #expect(response.conversation.id == ConversationID(rawValue: "owned-conversation"))
        #expect(response.messages.first?.id == MessageID(rawValue: "owned-message"))
        #expect(response.messages.first?.conversationID == response.conversation.id)
    }

    @Test func snapshotMappingRejectsUnexpectedOrUnsafeShareIdentity() throws {
        let payload = try JSONDecoder().decode(
            SharedConversationSnapshotDTO.self,
            from: Data(#"{"shareId":"share-b","conversationId":"convo","messages":[]}"#.utf8)
        )
        #expect(throws: DTOMapperError.invalidField("sharedSnapshot.shareId")) {
            try payload.domainModel(expectedShareID: SharedLinkID(rawValue: "share-a"))
        }

        let unsafePayload = try JSONDecoder().decode(
            SharedConversationSnapshotDTO.self,
            from: Data(#"{"shareId":"../private","conversationId":"convo","messages":[]}"#.utf8)
        )
        #expect(throws: DTOMapperError.invalidField("sharedSnapshot.shareId")) {
            try unsafePayload.domainModel()
        }
        #expect(throws: LibreChatProtocolError.encoding("The shared-link identifier is not path safe.")) {
            try LibreChatSharedSnapshotsAPI.snapshot(shareID: SharedLinkID(rawValue: "../private"))
        }
    }

    @Test func snapshotMappingDoesNotExposeOwnerScopedInlineMedia() throws {
        let payload = try JSONDecoder().decode(
            SharedConversationSnapshotDTO.self,
            from: Data(
                #"{"shareId":"share-1","conversationId":"convo","messages":[{"messageId":"message","conversationId":"convo","content":[{"type":"image_url","image_url":{"url":"/api/files/private-owner-file"}},{"type":"video_url","url":"/api/files/private-owner-video"},{"type":"image_file","image_file":{"file_id":"private","filepath":"/api/files/private"}}]}]}"#.utf8
            )
        )
        let snapshot = try payload.domainModel(expectedShareID: SharedLinkID(rawValue: "share-1"))
        let content = try #require(snapshot.messages.first?.content)
        #expect(content == [
            .unsupported(kind: "shared_image"),
            .unsupported(kind: "shared_video"),
            .unsupported(kind: "shared_file")
        ])
    }

    @Test func forkMappingRejectsMessagesFromAnotherCanonicalConversation() throws {
        let response = try JSONDecoder().decode(
            SharedConversationForkResponseDTO.self,
            from: Data(#"{"conversation":{"conversationId":"owned-a","title":"Forked"},"messages":[{"messageId":"owned-message","conversationId":"owned-b","text":"Wrong owner"}]}"#.utf8)
        )
        #expect(throws: DTOMapperError.invalidField("sharedFork.messages.conversationId")) {
            try response.domainModel()
        }
    }

    private func bodyObject<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
