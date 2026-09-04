import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct ConversationDuplicationContractTests {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "source")

    @Test func requestUsesExactBodyOmitsAbsentTitleAndNeverRetries() throws {
        let preserving = ConversationDuplicationRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        let request = try LibreChatConversationDuplicationAPI.duplicate(preserving)
        #expect(request.method == .post)
        #expect(request.path == "api/convos/duplicate")
        #expect(request.retryPolicy == .never)
        let preservingBody = try body(request)
        #expect(Set(preservingBody.keys) == Set(["conversationId"]))
        #expect(preservingBody["conversationId"] as? String == "source")

        let titled = ConversationDuplicationRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            title: "Copy title"
        )
        let titledBody = try body(LibreChatConversationDuplicationAPI.duplicate(titled))
        #expect(Set(titledBody.keys) == Set(["conversationId", "title"]))
        #expect(titledBody["title"] as? String == "Copy title")
    }

    @Test func preflightAcceptsNonemptyAuthoritativeTreeAndCapturesSourceIDs() throws {
        let history = [
            message("user", parent: nil),
            message("assistant", parent: "user", user: false)
        ]
        let request = request()
        let preflight = try ConversationDuplicationValidator.preflight(
            request: request,
            conversation: Conversation(id: conversationID, title: "Source"),
            history: history
        )
        #expect(preflight.request == request)
        #expect(preflight.sourceMessageIDs == Set(history.map(\.id)))
    }

    @Test func preflightRejectsEmptyLocalCrossConversationAndMalformedHistory() throws {
        let source = Conversation(id: conversationID, title: "Source")
        #expect(throws: ConversationDuplicationValidationError.emptyHistory) {
            _ = try ConversationDuplicationValidator.preflight(
                request: request(),
                conversation: source,
                history: []
            )
        }
        #expect(throws: ConversationDuplicationValidationError.localIdentifier) {
            let localID = ConversationID(rawValue: "local-draft")
            _ = try ConversationDuplicationValidator.preflight(
                request: request(conversationID: localID),
                conversation: Conversation(id: localID, title: "Draft"),
                history: [message("server-message", parent: nil, conversation: localID)]
            )
        }
        #expect(throws: ConversationDuplicationValidationError.self) {
            try ConversationDuplicationValidator.preflight(
                request: request(),
                conversation: source,
                history: [message("foreign", parent: nil, conversation: ConversationID(rawValue: "other"))]
            )
        }
        #expect(throws: ConversationDuplicationValidationError.invalidGraph) {
            try ConversationDuplicationValidator.preflight(
                request: request(),
                conversation: source,
                history: [message("orphan", parent: "missing")]
            )
        }
    }

    @Test func responseRequiresFreshConversationAndFreshStructurallyValidMessages() throws {
        let preflight = try ConversationDuplicationValidator.preflight(
            request: request(),
            conversation: Conversation(id: conversationID, title: "Source"),
            history: [message("source-user", parent: nil)]
        )
        let freshID = ConversationID(rawValue: "copy")
        let valid = ConversationDuplicationResult(
            conversation: Conversation(id: freshID, title: "Source"),
            messages: [message("copy-user", parent: nil, conversation: freshID)]
        )
        #expect(try ConversationDuplicationValidator.validateResponse(valid, for: preflight) == valid)

        let sameConversation = ConversationDuplicationResult(
            conversation: Conversation(id: conversationID, title: "Source"),
            messages: [message("copy-user", parent: nil)]
        )
        #expect(throws: ConversationDuplicationValidationError.responseConversationCollision) {
            try ConversationDuplicationValidator.validateResponse(sameConversation, for: preflight)
        }

        let reusedMessage = ConversationDuplicationResult(
            conversation: Conversation(id: freshID, title: "Source"),
            messages: [message("source-user", parent: nil, conversation: freshID)]
        )
        #expect(throws: ConversationDuplicationValidationError.self) {
            try ConversationDuplicationValidator.validateResponse(reusedMessage, for: preflight)
        }
    }

    @Test func responseRejectsEmptyWrongConversationAndInvalidParentGraphs() throws {
        let preflight = try ConversationDuplicationValidator.preflight(
            request: request(),
            conversation: Conversation(id: conversationID, title: "Source"),
            history: [message("source-user", parent: nil)]
        )
        let copy = Conversation(id: ConversationID(rawValue: "copy"), title: "Copy")
        let invalidResults = [
            ConversationDuplicationResult(conversation: copy, messages: []),
            ConversationDuplicationResult(
                conversation: copy,
                messages: [message("fresh", parent: nil, conversation: ConversationID(rawValue: "other"))]
            ),
            ConversationDuplicationResult(
                conversation: copy,
                messages: [message("fresh", parent: "missing", conversation: copy.id)]
            )
        ]
        for result in invalidResults {
            #expect(throws: ConversationDuplicationValidationError.self) {
                try ConversationDuplicationValidator.validateResponse(result, for: preflight)
            }
        }
    }

    @Test func dtoRequiresExplicitFreshMessageCoordinates() throws {
        let preflight = try ConversationDuplicationValidator.preflight(
            request: request(),
            conversation: Conversation(id: conversationID, title: "Source"),
            history: [message("source-user", parent: nil)]
        )
        let validData = Data(#"{"conversation":{"conversationId":"copy","title":"Source"},"messages":[{"messageId":"copy-user","conversationId":"copy","isCreatedByUser":true,"text":"Hello"}]}"#.utf8)
        let valid = try JSONDecoder().decode(ConversationDuplicationResponseDTO.self, from: validData)
        #expect(try valid.domainModel(for: preflight).conversation.id == ConversationID(rawValue: "copy"))

        let missingConversation = Data(#"{"conversation":{"conversationId":"copy"},"messages":[{"messageId":"copy-user","isCreatedByUser":true}]}"#.utf8)
        let invalid = try JSONDecoder().decode(ConversationDuplicationResponseDTO.self, from: missingConversation)
        #expect(throws: ConversationDuplicationValidationError.invalidResponse) {
            try invalid.domainModel(for: preflight)
        }
    }

    private func request(
        conversationID: ConversationID? = nil
    ) -> ConversationDuplicationRequest {
        ConversationDuplicationRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID ?? self.conversationID
        )
    }

    private func message(
        _ id: String,
        parent: String?,
        conversation: ConversationID? = nil,
        user: Bool = true
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: conversation ?? conversationID,
            parentMessageID: parent.map(MessageID.init(rawValue:)),
            content: [.text(id)],
            author: user ? .user : .assistant(name: "Assistant")
        )
    }

    private func body<Response>(
        _ request: APIRequest<Response>
    ) throws -> [String: Any] where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
