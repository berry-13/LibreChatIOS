import Foundation
import LibreChatDomain
@testable import LibreChatProtocol
import Testing

struct MessageFeedbackContractTests {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let coordinate = MessageFeedbackCoordinate(
        conversationID: ConversationID(rawValue: "conversation/a %"),
        messageID: MessageID(rawValue: "message/b %")
    )

    @Test func tagRegistryDerivesOnlyValidRatingPairs() {
        #expect(MessageFeedbackTag.tags(for: .thumbsUp) == [
            .accurateReliable, .creativeSolution, .clearWellWritten, .attentionToDetail
        ])
        #expect(MessageFeedbackTag.tags(for: .thumbsDown) == [
            .notMatched, .inaccurate, .badStyle, .missingImage,
            .unjustifiedRefusal, .notHelpful, .other
        ])
        #expect(MessageFeedback(tag: .inaccurate).rating == .thumbsDown)
        #expect(MessageFeedback(tag: .clearWellWritten).rating == .thumbsUp)
    }

    @Test func exactSetAndClearBodiesUseRawPathComponentsAndNeverRetry() throws {
        let set = try LibreChatMessagesAPI.updateFeedback(MessageFeedbackRequest(
            profileID: profileID,
            accountID: accountID,
            coordinate: coordinate,
            feedback: MessageFeedback(tag: .inaccurate, text: "Incorrect detail")
        ))
        #expect(set.method == .put)
        #expect(set.path == "api/messages")
        #expect(set.pathComponents == [
            "api", "messages", "conversation/a %", "message/b %", "feedback"
        ])
        #expect(set.retryPolicy == .never)
        let setBody = try body(set)
        let feedback = try #require(setBody["feedback"] as? [String: Any])
        #expect(Set(feedback.keys) == ["rating", "tag", "text"])
        #expect(feedback["rating"] as? String == "thumbsDown")
        #expect(feedback["tag"] as? String == "inaccurate")
        #expect(feedback["text"] as? String == "Incorrect detail")

        let clear = try LibreChatMessagesAPI.updateFeedback(MessageFeedbackRequest(
            profileID: profileID,
            accountID: accountID,
            coordinate: coordinate,
            feedback: nil
        ))
        #expect(try body(clear).isEmpty)
        #expect(clear.retryPolicy == .never)
    }

    @Test func textLimitUsesUTF16AndRejectsBeforeTransport() throws {
        let exactly = String(repeating: "😀", count: 512)
        _ = try LibreChatMessagesAPI.updateFeedback(MessageFeedbackRequest(
            profileID: profileID,
            accountID: accountID,
            coordinate: coordinate,
            feedback: MessageFeedback(tag: .other, text: exactly)
        ))

        let tooLong = exactly + "x"
        #expect(throws: MessageFeedbackError.textTooLong(maximumUTF16Length: 1_024)) {
            _ = try LibreChatMessagesAPI.updateFeedback(MessageFeedbackRequest(
                profileID: profileID,
                accountID: accountID,
                coordinate: coordinate,
                feedback: MessageFeedback(tag: .other, text: tooLong)
            ))
        }
    }

    @Test func responseRequiresExactCoordinatesAndPresenceAwareClear() throws {
        let setData = Data(#"{"messageId":"message/b %","conversationId":"conversation/a %","feedback":{"rating":"thumbsUp","tag":"accurate_reliable","text":"Solid"},"future":true}"#.utf8)
        let set = try JSONDecoder().decode(MessageFeedbackUpdateResponseDTO.self, from: setData)
            .domainModel(expected: coordinate)
        #expect(set.feedback == MessageFeedback(tag: .accurateReliable, text: "Solid"))
        #expect(set.resolution == .confirmedAfterResponse)

        let clearData = Data(#"{"messageId":"message/b %","conversationId":"conversation/a %","feedback":null}"#.utf8)
        let clear = try JSONDecoder().decode(MessageFeedbackUpdateResponseDTO.self, from: clearData)
            .domainModel(expected: coordinate)
        #expect(clear.feedback == nil)

        let omittedData = Data(#"{"messageId":"message/b %","conversationId":"conversation/a %"}"#.utf8)
        let omitted = try JSONDecoder().decode(MessageFeedbackUpdateResponseDTO.self, from: omittedData)
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try omitted.domainModel(expected: coordinate)
        }

        let wrongData = Data(#"{"messageId":"other","conversationId":"conversation/a %","feedback":null}"#.utf8)
        let wrong = try JSONDecoder().decode(MessageFeedbackUpdateResponseDTO.self, from: wrongData)
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try wrong.domainModel(expected: coordinate)
        }
    }

    @Test func mismatchedAndUnknownDTOValuesFailClosed() throws {
        #expect(throws: DTOMapperError.invalidField("message.feedback")) {
            _ = try LibreChatMessageFeedbackDTO(
                rating: "thumbsUp",
                tag: "inaccurate"
            ).domainModel()
        }
        #expect(throws: DTOMapperError.invalidField("message.feedback")) {
            _ = try LibreChatMessageFeedbackDTO(
                rating: "future_rating",
                tag: "future_tag"
            ).domainModel()
        }
    }

    @Test func historyMappingPreservesValidFeedbackAndIgnoresInvalidFeedback() throws {
        let valid = try JSONDecoder().decode(LibreChatMessageDTO.self, from: Data(#"""
        {
          "messageId":"message",
          "conversationId":"conversation",
          "text":"Answer",
          "feedback":{"rating":"thumbsDown","tag":"not_helpful","text":"Needs detail"}
        }
        """#.utf8)).domainModel()
        #expect(valid.feedback == MessageFeedback(tag: .notHelpful, text: "Needs detail"))

        let invalid = try JSONDecoder().decode(LibreChatMessageDTO.self, from: Data(#"""
        {
          "messageId":"message",
          "conversationId":"conversation",
          "text":"Answer",
          "feedback":{"rating":"thumbsUp","tag":"not_helpful"}
        }
        """#.utf8)).domainModel()
        #expect(invalid.feedback == nil)
    }

    @Test func legacyCachedMessageDecodesWithoutFeedback() throws {
        let current = ChatMessage(
            id: MessageID(rawValue: "message"),
            conversationID: ConversationID(rawValue: "conversation"),
            content: [.text("Answer")],
            author: .assistant(name: "Assistant")
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)
        ) as? [String: Any])
        object.removeValue(forKey: "feedback")

        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.feedback == nil)
    }

    private func body<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
