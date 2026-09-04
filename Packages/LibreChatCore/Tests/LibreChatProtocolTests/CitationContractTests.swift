import Foundation
import Testing
import LibreChatDomain
import LibreChatTestSupport
@testable import LibreChatProtocol

struct CitationContractTests {
    @Test func resolverSupportsLiteralUnicodeCompositeAndHighlightMarkers() throws {
        let search = reference(.search, title: "Search")
        let news = reference(.news, title: "Top story")
        let video = reference(.video, title: "Video")
        let catalog = CitationSourceCatalog(webSearchByTurn: [
            0: WebSearchCitationData(
                turn: 0,
                organic: [search],
                topStories: [news],
                videos: [video],
                raw: .object([:])
            )
        ])

        let literal = #"Lead \ue203important\ue204\ue202turn0search0 and \ue200\ue202turn0news0\ue202turn0video0\ue201."#
        let resolved = CitationMarkerResolver.resolve(literal, sources: catalog)

        #expect(resolved.cleanedText == "Lead important and .")
        #expect(resolved.highlights == [CitationHighlight(id: 0, text: "important")])
        #expect(resolved.citations.map(\.reference.title) == ["Search", "Top story", "Video"])
        #expect(resolved.citations[0].anchor.highlightID == 0)
        #expect(resolved.citations[1].anchor.compositeGroupID == 1)
        #expect(resolved.citations[2].anchor.compositeGroupID == 1)
        let tokens = resolved.renderSegments.compactMap { segment -> CitationRenderToken? in
            guard case let .citation(token) = segment else { return nil }
            return token
        }
        #expect(tokens.count == 2)
        let token = try #require(tokens.last)
        #expect(token.anchors.count == 2)
        #expect(token.compositeGroupID == 1)

        let unicode = "Actual \u{E202}turn0news0."
        let unicodeResolved = CitationMarkerResolver.resolve(unicode, sources: catalog)
        #expect(unicodeResolved.cleanedText == "Actual .")
        #expect(unicodeResolved.citations.single?.reference.title == "Top story")
    }

    @Test func resolverSupportsAllWireReferenceTypesAndFailsClosedForFileAnchors() {
        let catalog = CitationSourceCatalog(
            webSearchByTurn: [
                0: WebSearchCitationData(
                    turn: 0,
                    organic: [reference(.search)],
                    images: [reference(.image)],
                    topStories: [reference(.news)],
                    videos: [reference(.video)],
                    references: [reference(.ref)],
                    raw: .object([:])
                )
            ],
            fileSearchByTurn: [
                0: FileSearchCitationData(
                    sources: [reference(.file, fileID: "file-1")],
                    raw: .object([:])
                )
            ]
        )
        let text = #"\ue202turn0search0\ue202turn0image0\ue202turn0news0\ue202turn0video0\ue202turn0ref0\ue202turn0file0"#
        let resolved = CitationMarkerResolver.resolve(text, sources: catalog)

        #expect(resolved.citations.map(\.anchor.referenceType) == [.search, .image, .news, .video, .ref])
        #expect(resolved.discardedAnchorCount == 1)
        #expect(resolved.cleanedText.isEmpty)
        #expect(catalog.displayFileSources(forTurn: 0).map(\.fileID) == ["file-1"])
    }

    @Test func resolverRemovesOrphanOutOfRangeAndMalformedAnchorsWithoutLeakingTokens() {
        let catalog = CitationSourceCatalog()
        let text = #"Before \ue202turn9search0 and \ue202turn0unknown0 after \ue200\ue202turn0search0"#
        let resolved = CitationMarkerResolver.resolve(text, sources: catalog)

        #expect(resolved.citations.isEmpty)
        #expect(resolved.cleanedText == "Before  and  after ")
        #expect(resolved.discardedAnchorCount >= 3)
        #expect(!resolved.cleanedText.contains("turn"))
        #expect(!resolved.cleanedText.unicodeScalars.contains(where: { (0xE200...0xE206).contains(Int($0.value)) }))
    }

    @Test func attachmentDTOPreservesUnknownProviderFieldsAndRejectsUnsafeURLs() throws {
        let data = Data(
            """
            {
              "messageId":"message-1","toolCallId":"call-1","conversationId":"conversation-1",
              "name":"search-result","type":"web_search","futureEnvelope":{"stable":true},
              "web_search":{"turn":2,"topStories":[{"title":"News","link":"https://news.example/article","future":"keep"}],
              "organic":[{"title":"Unsafe","link":"javascript:alert(1)"}],"providerFuture":{"nested":[1,2]}}
            }
            """.utf8
        )
        let dto = try JSONDecoder().decode(LibreChatCitationAttachmentDTO.self, from: data)
        let attachment = try dto.domainModel()

        #expect(dto.unknownFields["futureEnvelope"] == .object(["stable": .bool(true)]))
        guard case let .webSearch(search) = attachment.payload else {
            Issue.record("Expected a web-search attachment.")
            return
        }
        #expect(search.topStories.single?.link == URL(string: "https://news.example/article"))
        #expect(search.organic.single?.link == nil)
        #expect(search.raw == .object([
            "turn": .number(2),
            "topStories": .array([.object([
                "title": .string("News"), "link": .string("https://news.example/article"), "future": .string("keep")
            ])]),
            "organic": .array([.object(["title": .string("Unsafe"), "link": .string("javascript:alert(1)")])]),
            "providerFuture": .object(["nested": .array([.number(1), .number(2)])])
        ]))

        let reencoded = try JSONEncoder().encode(dto)
        let redecoded = try JSONDecoder().decode(LibreChatCitationAttachmentDTO.self, from: reencoded)
        #expect(redecoded.unknownFields == dto.unknownFields)
    }

    @Test func historyAndStandardOrResponsesAttachmentsUseOneUpsertIdentity() throws {
        let history = try attachmentJSON(
            """
            {"messageId":"message-1","toolCallId":"call-1","conversationId":"conversation-1","name":"search","type":"web_search","web_search":{"turn":0,"organic":[{"title":"Before","link":"https://example.com"}]}}
            """
        )
        let standard = try attachmentJSON(
            """
            {"messageId":"message-1","toolCallId":"call-1","conversationId":"conversation-1","name":"search","type":"web_search","web_search":{"turn":0,"organic":[{"title":"After","link":"https://example.com","processed":true}]}}
            """
        )
        let responses = try attachmentJSON(
            """
            {"type":"librechat:attachment","message_id":"message-1","conversation_id":"conversation-1","attachment":{"type":"web_search","toolCallId":"call-2","web_search":{"turn":1,"organic":[{"title":"Wrapper","link":"https://example.com/w"}]}}}
            """
        )

        var reducer = CitationAttachmentReducer()
        _ = reducer.upsert(try LibreChatCitationAttachmentDTO(value: history).domainModel())
        _ = reducer.upsert(try LibreChatCitationAttachmentDTO.generationAttachment(from: standard))
        _ = reducer.upsert(try LibreChatCitationAttachmentDTO.generationAttachment(from: responses))

        #expect(reducer.attachments.count == 2)
        #expect(reducer.attachments[0].identity.name == "search")
        #expect(reducer.attachments[1].identity.name == "web_search:call-2")
        guard case let .webSearch(updated) = reducer.attachments[0].payload else {
            Issue.record("Expected updated web-search payload.")
            return
        }
        #expect(updated.organic.single?.title == "After")
        #expect(updated.organic.single?.raw == .object([
            "title": .string("After"), "link": .string("https://example.com"), "processed": .bool(true)
        ]))
    }

    @Test func historicalMessageMappingUpsertsRepeatedHighlightAttachment() throws {
        let data = Data(
            """
            {
              "messageId":"message-1","conversationId":"conversation-1","sender":"Assistant","text":"Answer",
              "attachments":[
                {"messageId":"message-1","toolCallId":"call-1","name":"search","type":"web_search","web_search":{"turn":0,"organic":[{"title":"Before","link":"https://example.com"}]}},
                {"messageId":"message-1","toolCallId":"call-1","name":"search","type":"web_search","web_search":{"turn":0,"organic":[{"title":"After","link":"https://example.com","processed":true}]}}
              ]
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()

        let attachment = try #require(message.citationAttachments.single)
        guard case let .webSearch(search) = attachment.payload else {
            Issue.record("Expected an upserted web-search attachment.")
            return
        }
        #expect(search.organic.single?.title == "After")
    }

    @Test func liveStandardAndResponsesAttachmentsReachGenerationSnapshotThroughOneReducer() throws {
        let standard = ServerSentEvent(
            event: "attachment",
            data: """
            {"messageId":"message-1","toolCallId":"call-1","name":"search","type":"web_search","web_search":{"turn":0,"organic":[{"title":"First","link":"https://example.com"}]}}
            """
        )
        let responses = ServerSentEvent(
            data: """
            {"type":"librechat:attachment","message_id":"message-1","attachment":{"type":"web_search","toolCallId":"call-2","web_search":{"turn":1,"organic":[{"title":"Second","link":"https://example.com/second"}]}}}
            """
        )
        let decoder = LibreChatGenerationDecoder()
        var reducer = GenerationReducer(handle: LibreChatFixtures.handle)

        for event in decoder.decode(standard, conversationID: LibreChatFixtures.handle.conversationID) {
            _ = reducer.apply(event)
        }
        for event in decoder.decode(responses, conversationID: LibreChatFixtures.handle.conversationID) {
            _ = reducer.apply(event)
        }

        let attachments = try #require(reducer.snapshot.response?.citationAttachments)
        #expect(attachments.count == 2)
        #expect(attachments.map(\.identity.name) == ["search", "web_search:call-2"])
    }

    @Test func fileSearchDisplayMergesWithoutMutatingRawProvenance() throws {
        let value = try attachmentJSON(
            """
            {"messageId":"message-1","toolCallId":"call-1","name":"files","type":"file_search","file_search":{"sources":[
              {"fileId":"f1","fileName":"Notes.pdf","pages":[4,2],"relevance":0.4,"pageRelevance":{"2":0.4},"future":"first"},
              {"fileId":"f1","fileName":"Notes.pdf","pages":[2,3],"relevance":0.9,"pageRelevance":{"3":0.9},"future":"second"}
            ]}}
            """
        )
        let attachment = try LibreChatCitationAttachmentDTO(value: value).domainModel()
        guard case let .fileSearch(files) = attachment.payload else {
            Issue.record("Expected file-search payload.")
            return
        }
        #expect(files.sources.count == 2)
        let display = try #require(files.displaySources().single)
        #expect(display.pages == [2, 3, 4])
        #expect(display.relevance == 0.9)
        #expect(display.pageRelevance == ["2": 0.4, "3": 0.9])
        #expect(display.raw == .object([
            "fileId": .string("f1"), "fileName": .string("Notes.pdf"),
            "pages": .array([.number(4), .number(2)]), "relevance": .number(0.4),
            "pageRelevance": .object(["2": .number(0.4)]), "future": .string("first")
        ]))
    }

    @Test func legacyCachedMessageDecodesWithoutCitationAttachmentKey() throws {
        let data = Data(
            """
            {"id":"message-1","conversationID":"conversation-1","content":[{"text":{"_0":"Hello"}}],"author":{"assistant":{"name":"Assistant"}}}
            """.utf8
        )
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(message.citationAttachments.isEmpty)
    }

    @Test func plainTextCleansCitationMarkersBeforeRowsSearchAndAccessibilityConsumeIt() {
        let attachment = CitationAttachment(
            identity: CitationAttachmentIdentity(
                messageID: MessageID(rawValue: "message-1"),
                toolCallID: "call-1",
                name: "search"
            ),
            payload: .webSearch(WebSearchCitationData(
                turn: 0,
                organic: [reference(.search, title: "Source")],
                raw: .object([:])
            ))
        )
        let message = ChatMessage(
            id: MessageID(rawValue: "message-1"),
            conversationID: ConversationID(rawValue: "conversation-1"),
            content: [.text("Answer \u{E202}turn0search0")],
            author: .assistant(name: "Assistant"),
            citationAttachments: [attachment]
        )

        #expect(message.rawPlainText.contains("turn0search0"))
        #expect(message.plainText == "Answer ")
        #expect(!message.plainText.unicodeScalars.contains(where: { (0xE200...0xE206).contains(Int($0.value)) }))
    }

    private func reference(
        _ type: CitationReferenceType,
        title: String? = nil,
        fileID: String? = nil
    ) -> CitationReference {
        CitationReference(
            type: type,
            title: title,
            fileID: fileID,
            raw: .object([:])
        )
    }

    private func attachmentJSON(_ string: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
