import LibreChatDomain
@testable import LibreChat
import XCTest

final class ArtifactPresentationTests: XCTestCase {
    func testSafePreviewPolicyAllowsOnlyNativeStaticTypes() {
        XCTAssertEqual(ArtifactNativePreviewPolicy(mimeType: "text/markdown"), .markdown)
        XCTAssertEqual(ArtifactNativePreviewPolicy(mimeType: "text/md"), .markdown)
        XCTAssertEqual(ArtifactNativePreviewPolicy(mimeType: "text/plain"), .plainText)

        for mimeType in [
            "text/html",
            "image/svg+xml",
            "application/vnd.mermaid",
            "application/vnd.react",
            "application/x-unknown"
        ] {
            XCTAssertFalse(ArtifactNativePreviewPolicy(mimeType: mimeType).supportsPreview)
        }
    }

    func testArtifactPresentationUsesSemanticSourceOnlyLabels() {
        let html = artifact(mimeType: "text/html", title: "Prototype")
        let presentation = ArtifactPresentation(artifact: html)

        XCTAssertEqual(presentation.typeLabel, "HTML · source only")
        XCTAssertEqual(presentation.systemImage, "chevron.left.forwardslash.chevron.right")
    }

    func testWorkspacePresentationUsesNavigationOnPhoneAndInspectorElsewhere() {
        XCTAssertEqual(ArtifactWorkspacePresentationMode(isPhone: true), .navigation)
        XCTAssertEqual(ArtifactWorkspacePresentationMode(isPhone: false), .inspector)
    }

    func testWorkspaceIdentityUsesConversationMessageAndServerDocumentOrderIndex() {
        let first = ArtifactWorkspaceSelection(
            conversationID: ConversationID(rawValue: "conversation-a"),
            artifact: artifact(messageID: "message", index: 1),
            citationAttachments: []
        )
        let second = ArtifactWorkspaceSelection(
            conversationID: ConversationID(rawValue: "conversation-a"),
            artifact: artifact(messageID: "message", index: 2),
            citationAttachments: []
        )
        let otherConversation = ArtifactWorkspaceSelection(
            conversationID: ConversationID(rawValue: "conversation-b"),
            artifact: artifact(messageID: "message", index: 1),
            citationAttachments: []
        )
        let otherMessage = ArtifactWorkspaceSelection(
            conversationID: ConversationID(rawValue: "conversation-a"),
            artifact: artifact(messageID: "message-b", index: 1),
            citationAttachments: []
        )

        XCTAssertEqual(first.id, ArtifactWorkspaceIdentity(
            conversationID: ConversationID(rawValue: "conversation-a"),
            artifactIdentity: ArtifactIdentity(
                messageID: MessageID(rawValue: "message"),
                documentOrderIndex: 1
            )
        ))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, otherConversation.id)
        XCTAssertNotEqual(first.id, otherMessage.id)
    }

    func testRenderableArtifactReplacesDirectiveButPreservesSurroundingText() throws {
        let raw = """
        Before
        :::artifact{identifier="notes" type="text/markdown" title="Notes"}
        # Native
        :::
        After
        """
        let document = ArtifactParser.parse(messageID: MessageID(rawValue: "message"), text: raw)

        XCTAssertEqual(document.artifacts.count, 1)
        XCTAssertEqual(document.artifacts[0].sourceContent, "# Native\n")
        let visibleText = document.segments.compactMap { segment -> String? in
            guard case let .text(text) = segment else { return nil }
            return text
        }.joined()
        XCTAssertTrue(visibleText.contains("Before"))
        XCTAssertTrue(visibleText.contains("After"))
        XCTAssertFalse(visibleText.contains(":::artifact"))
    }

    private func artifact(
        messageID: String = "message",
        index: Int = 0,
        mimeType: String = "text/plain",
        title: String = "Artifact"
    ) -> ParsedArtifact {
        ParsedArtifact(
            identity: ArtifactIdentity(
                messageID: MessageID(rawValue: messageID),
                documentOrderIndex: index
            ),
            identifier: "artifact-id",
            mimeType: mimeType,
            title: title,
            sourceContent: "content",
            rawContainer: "raw"
        )
    }
}
