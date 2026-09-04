import LibreChatDomain
@testable import LibreChat
import XCTest

final class CitationPresentationTests: XCTestCase {
    func testPresentationParsesMarkdownOnceAcrossInlineCitation() throws {
        let messageID = MessageID(rawValue: "message")
        let reference = CitationReference(
            type: .search,
            title: "Example",
            link: try XCTUnwrap(URL(string: "https://example.com/source")),
            attribution: "example.com",
            raw: .object([:])
        )
        let attachment = CitationAttachment(
            identity: CitationAttachmentIdentity(messageID: messageID, toolCallID: "tool", name: "search"),
            payload: .webSearch(WebSearchCitationData(
                turn: 0,
                organic: [reference],
                raw: .object([:])
            ))
        )

        let presentation = CitationTextPresentation(
            text: "**Important \u{E202}turn0search0 fact**",
            attachments: [attachment],
            selectionIDPrefix: "message:0"
        )

        XCTAssertEqual(String(presentation.attributedText.characters), "Important \u{202F}[1] fact")
        XCTAssertEqual(presentation.cleanedText, "Important  fact")
        XCTAssertEqual(presentation.selections[0]?.references, [reference])
        let links = presentation.attributedText.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.scheme), [CitationTextPresentation.selectionScheme])
    }

    func testSourceCollectionIncludesFullWebDirectoryAndFileMetadata() throws {
        let messageID = MessageID(rawValue: "message")
        let conversationID = ConversationID(rawValue: "conversation")
        let cited = reference(type: .search, title: "Cited", url: "https://example.com/cited")
        let story = reference(type: .news, title: "Story", url: "https://news.example/story")
        let related = reference(type: .ref, title: "Related", url: "https://example.com/related")
        let file = CitationReference(
            type: .file,
            title: "Guide.pdf",
            link: URL(string: "#file-file-1"),
            fileID: "file-1",
            fileName: "Guide.pdf",
            pages: [2, 4],
            relevance: 0.91,
            raw: .object([:])
        )
        let attachments = [
            CitationAttachment(
                identity: CitationAttachmentIdentity(messageID: messageID, toolCallID: "web", name: "web"),
                payload: .webSearch(WebSearchCitationData(
                    turn: 0,
                    organic: [cited],
                    topStories: [story],
                    references: [related],
                    raw: .object([:])
                ))
            ),
            CitationAttachment(
                identity: CitationAttachmentIdentity(messageID: messageID, toolCallID: "file", name: "file"),
                payload: .fileSearch(FileSearchCitationData(
                    sources: [file],
                    raw: .object([:])
                ))
            )
        ]
        let message = ChatMessage(
            id: messageID,
            conversationID: conversationID,
            content: [.text("Answer\u{E202}turn0search0")],
            author: .assistant(name: "Assistant"),
            citationAttachments: attachments
        )

        let collection = CitationSourceCollection(message: message)

        XCTAssertEqual(collection.references.map(\.title), ["Cited", "Story", "Related", "Guide.pdf"])
        XCTAssertEqual(collection.fileCount, 1)
        XCTAssertEqual(collection.references.last?.pages, [2, 4])
        XCTAssertEqual(collection.references.last?.relevance, 0.91)
        XCTAssertNil(CitationURLValidator.validatedExternalURL(collection.references.last?.link))
        XCTAssertFalse(message.plainText.unicodeScalars.contains { 0xE200...0xE206 ~= $0.value })
    }

    func testExternalURLValidationRejectsUnsafeSchemes() throws {
        XCTAssertNotNil(CitationURLValidator.validatedExternalURL(
            try XCTUnwrap(URL(string: "https://example.com"))
        ))
        XCTAssertNil(CitationURLValidator.validatedExternalURL(URL(string: "javascript:alert(1)")))
        XCTAssertNil(CitationURLValidator.validatedExternalURL(URL(string: "#file-file-1")))
        XCTAssertNil(CitationURLValidator.validatedExternalURL(URL(string: "file:///tmp/source")))
    }

    private func reference(type: CitationReferenceType, title: String, url: String) -> CitationReference {
        CitationReference(
            type: type,
            title: title,
            link: URL(string: url),
            raw: .object([:])
        )
    }
}
