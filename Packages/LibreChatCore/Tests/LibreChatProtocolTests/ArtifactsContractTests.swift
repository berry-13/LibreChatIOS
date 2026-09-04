import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct ArtifactsContractTests {
    @Test func parsesCanonicalHeadersAndPreservesOrderedInterleavedContent() throws {
        let messageID = MessageID(rawValue: "message-1")
        let text = """
        Before
        :::artifact{identifier="first" type="text/markdown" title="First" custom="future"}
        ````markdown
        # First
        ```
        inside
        ```
        ````
        :::
        Between
        :::artifact{identifier="second" type="application/vnd.mermaid" title="Second"}
        ~~~
        graph TD
          A --> B
        ~~~
        :::
        After
        """

        let document = ArtifactParser.parse(messageID: messageID, text: text)
        #expect(document.artifacts.count == 2)
        #expect(document.artifacts[0].identity == ArtifactIdentity(messageID: messageID, documentOrderIndex: 0))
        #expect(document.artifacts[1].identity.documentOrderIndex == 1)
        #expect(document.artifacts[0].sourceContent.contains("```\ninside\n```"))
        #expect(document.artifacts[0].attributes["custom"] == "future")
        #expect(document.artifacts[1].mimeType == "application/vnd.mermaid")

        let textSegments = document.segments.compactMap { segment -> String? in
            guard case let .text(value) = segment else { return nil }
            return value
        }
        #expect(textSegments.joined().contains("Before"))
        #expect(textSegments.joined().contains("Between"))
        #expect(textSegments.joined().contains("After"))
    }

    @Test func incompleteArtifactFailsClosedWithoutExposingPartialArtifact() {
        let messageID = MessageID(rawValue: "message-2")
        let text = "Before\n:::artifact{identifier=\"live\" type=\"text/html\" title=\"Live\"}\n```\npartial"
        let document = ArtifactParser.parse(messageID: messageID, text: text)

        #expect(document.artifacts.isEmpty)
        #expect(document.segments.count == 1)
        guard case let .text(raw) = document.segments[0] else {
            Issue.record("An incomplete artifact must remain text.")
            return
        }
        #expect(raw == text)
    }

    @Test func malformedClosedArtifactDoesNotShiftFollowingServerIndex() {
        let text = """
        :::artifact{identifier="" type="text/plain" title="bad"}
        bad
        :::
        :::artifact{identifier="good" type="text/plain" title="Good"}
        good
        :::
        """
        let document = ArtifactParser.parse(messageID: MessageID(rawValue: "message-3"), text: text)

        #expect(document.artifacts.count == 1)
        #expect(document.artifacts[0].identity.documentOrderIndex == 1)
    }

    @Test func syntacticallyMalformedAndIncompleteCandidatesStillReserveServerCoordinates() {
        let messageID = MessageID(rawValue: "message-malformed")
        let malformed = ArtifactParser.parse(
            messageID: messageID,
            text: ":::artifact{broken}\nraw\n:::"
        )
        #expect(malformed.artifacts.isEmpty)
        #expect(malformed.nextDocumentOrderIndex == 1)

        let incomplete = ArtifactParser.parse(
            messageID: messageID,
            text: ":::artifact{identifier=\"live\" type=\"text/plain\" title=\"Live\"}\npartial",
            startingDocumentOrderIndex: malformed.nextDocumentOrderIndex
        )
        #expect(incomplete.artifacts.isEmpty)
        #expect(incomplete.nextDocumentOrderIndex == 2)
    }

    @Test func runningIndexCarriesAcrossMessageContentParts() {
        let messageID = MessageID(rawValue: "message-parts")
        let first = ArtifactParser.parse(
            messageID: messageID,
            text: ":::artifact{identifier=\"one\" type=\"text/plain\" title=\"One\"}\none\n:::")
        let second = ArtifactParser.parse(
            messageID: messageID,
            text: ":::artifact{identifier=\"two\" type=\"text/plain\" title=\"Two\"}\ntwo\n:::",
            startingDocumentOrderIndex: first.nextDocumentOrderIndex
        )

        #expect(first.artifacts[0].identity.documentOrderIndex == 0)
        #expect(second.artifacts[0].identity.documentOrderIndex == 1)
    }

    @Test func dtoMappingCapturesGlobalArtifactCatalogBeforeLosingContentPartProvenance() throws {
        let data = try #require("""
        {
          "messageId": "message-catalog",
          "conversationId": "conversation-1",
          "text": ":::artifact{identifier=\\\"legacy\\\" type=\\\"text/plain\\\" title=\\\"Legacy\\\"}\\nlegacy\\n:::",
          "content": [
            {"type":"text","text":":::artifact{broken}\\nraw\\n:::"},
            {"type":"text","text":":::artifact{identifier=\\\"valid\\\" type=\\\"text/plain\\\" title=\\\"Valid\\\"}\\nvalue\\n:::"}
          ]
        }
        """.data(using: .utf8))

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()
        #expect(message.artifactCatalog.count == 1)
        let artifact = try #require(message.artifactCatalog.first)
        #expect(artifact.identifier == "valid")
        #expect(artifact.identity.documentOrderIndex == 1)
    }

    @Test func dtoArtifactCatalogUsesLegacyTextOnlyWhenContentHasNoRawCandidate() throws {
        let data = try #require("""
        {
          "messageId": "message-legacy",
          "conversationId": "conversation-1",
          "text": ":::artifact{identifier=\\\"legacy\\\" type=\\\"text/markdown\\\" title=\\\"Legacy\\\"}\\n# Legacy\\n:::",
          "content": [
            {"type":"text","text":"Structured prose without an artifact."},
            {"type":"reasoning","text":":::artifact{identifier=\\\"ignored\\\" type=\\\"text/plain\\\" title=\\\"Ignored\\\"}\\nignored\\n:::"}
          ]
        }
        """.data(using: .utf8))

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()
        #expect(message.artifactCatalog.count == 1)
        let artifact = try #require(message.artifactCatalog.first)
        #expect(artifact.identifier == "legacy")
        #expect(artifact.identity.documentOrderIndex == 0)
    }

    @Test func legacyCachedChatMessageDecodesWithEmptyArtifactCatalog() throws {
        // Encode through the current model, then remove the new key to model
        // an older SwiftData/cache payload without relying on enum wire shape.
        let current = ChatMessage(
            id: MessageID(rawValue: "message-old"),
            conversationID: ConversationID(rawValue: "conversation-1"),
            content: [.text("hello")],
            author: .assistant(name: "Assistant")
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)
        ) as? [String: Any])
        object.removeValue(forKey: "artifactCatalog")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
        #expect(decoded.artifactCatalog.isEmpty)
    }

    @Test func buildsExactNonRetriableArtifactUpdateRequest() throws {
        let request = try LibreChatArtifactAPI.update(
            messageID: MessageID(rawValue: "message/a"),
            index: 2,
            original: "old",
            updated: "new",
            isTemporary: true
        )

        #expect(request.method == .post)
        #expect(request.path == "api/messages/artifact/message/a")
        #expect(request.pathComponents == ["api", "messages", "artifact", "message/a"])
        #expect(request.retryPolicy == .never)
        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["index"] as? Int == 2)
        #expect(object["original"] as? String == "old")
        #expect(object["updated"] as? String == "new")
        #expect(object["isTemporary"] as? Bool == true)
    }
}
