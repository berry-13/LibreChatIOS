import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct SearchContractTests {
    @Test func searchRequestsUseCurrentLibreChatRoutesAndExactQueryShape() {
        let conversations = LibreChatSearchAPI.conversations(
            matching: "  release plan\n",
            cursor: "opaque==cursor",
            limit: 25
        )

        #expect(conversations.method == .get)
        #expect(conversations.path == "api/convos")
        #expect(conversations.queryItems == [
            URLQueryItem(name: "search", value: "release plan"),
            URLQueryItem(name: "cursor", value: "opaque==cursor"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "isArchived", value: "false"),
            URLQueryItem(name: "sortBy", value: "updatedAt"),
            URLQueryItem(name: "sortDirection", value: "desc")
        ])

        let messages = LibreChatSearchAPI.messages(matching: "\tSwift concurrency  ")
        #expect(messages.method == .get)
        #expect(messages.path == "api/messages")
        #expect(messages.queryItems == [
            URLQueryItem(name: "search", value: "Swift concurrency")
        ])
        #expect(messages.path != "api/search")
    }

    @Test func messageSearchPageDecodesEnrichedResultsAndTerminalNullCursor() throws {
        let data = Data(
            """
            {
              "messages":[{
                "messageId":"message-1",
                "conversationId":"conversation-1",
                "parentMessageId":"parent-1",
                "title":"Concurrency notes",
                "model":"gpt-5",
                "endpoint":"openAI",
                "iconURL":"https://chat.example.com/images/model.png",
                "sender":"Assistant",
                "isCreatedByUser":false,
                "text":"Use an actor.",
                "futureSearchMetadata":{"score":0.99},
                "content":[
                  {"type":"text","text":"Use an actor."},
                  {"type":"future_search_part","payload":{"rank":1}}
                ]
              }],
              "nextCursor":null,
              "futurePageMetadata":{"total":1}
            }
            """.utf8
        )

        let dto = try JSONDecoder().decode(LibreChatMessagePageDTO.self, from: data)
        let page = try dto.domainSearchPage()

        #expect(dto.nextCursor == nil)
        #expect(page.nextCursor == nil)
        #expect(page.results.count == 1)
        let result = try #require(page.results.first)
        #expect(result.id == MessageID(rawValue: "message-1"))
        #expect(result.conversationTitle == "Concurrency notes")
        #expect(result.model == "gpt-5")
        #expect(result.endpoint == "openAI")
        #expect(result.iconURL == URL(string: "https://chat.example.com/images/model.png"))
        #expect(result.message.conversationID == ConversationID(rawValue: "conversation-1"))
        #expect(result.message.parentMessageID == MessageID(rawValue: "parent-1"))
        #expect(result.message.content == [
            .text("Use an actor."),
            .unsupported(kind: "future_search_part")
        ])
    }

    @Test func messageSearchMetadataRemainsOptionalForEvolvingServers() throws {
        let data = Data(
            """
            {"messages":[{
              "messageId":"message-2",
              "conversationId":"conversation-2",
              "sender":"You",
              "isCreatedByUser":true,
              "text":"needle",
              "unknown":true
            }],"nextCursor":"future-cursor"}
            """.utf8
        )

        let page = try JSONDecoder()
            .decode(LibreChatMessagePageDTO.self, from: data)
            .domainSearchPage()
        let result = try #require(page.results.first)

        #expect(page.nextCursor == "future-cursor")
        #expect(result.conversationTitle == "Untitled chat")
        #expect(result.iconURL == nil)
        #expect(result.message.author == .user)
        #expect(result.message.content == [.text("needle")])
    }
}
