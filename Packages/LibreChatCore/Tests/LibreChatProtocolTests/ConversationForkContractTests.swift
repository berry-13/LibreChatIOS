import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct ConversationForkContractTests {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")
    private let conversationID = ConversationID(rawValue: "conversation")

    @Test func requestUsesExactAuthenticatedForkBodyAndNeverRetries() throws {
        let request = ConversationForkRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            targetMessageID: MessageID(rawValue: "target"),
            option: .directPath,
            splitAtTarget: true,
            latestMessageID: MessageID(rawValue: "latest")
        )
        let api = try LibreChatConversationForkAPI.fork(request)
        #expect(api.retryPolicy == .never)
        let body = try JSONEncoder().encode(ConversationForkRequestDTO(request))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["conversationId"] as? String == "conversation")
        #expect(object["messageId"] as? String == "target")
        #expect(object["option"] as? String == "directPath")
        #expect(object["splitAtTarget"] as? Bool == true)
        #expect(object["latestMessageId"] as? String == "latest")

        let noLatest = ConversationForkRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            targetMessageID: MessageID(rawValue: "target")
        )
        let noLatestBody = try JSONEncoder().encode(ConversationForkRequestDTO(noLatest))
        let noLatestObject = try #require(JSONSerialization.jsonObject(with: noLatestBody) as? [String: Any])
        #expect(noLatestObject["latestMessageId"] == nil)
    }

    @Test func preflightAcceptsRootTargetAndExactSplitDescendant() throws {
        let history = [
            message("root", parent: nil),
            message("child", parent: "root"),
            message("sibling", parent: "root"),
            message("grandchild", parent: "child")
        ]
        let request = ConversationForkRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            targetMessageID: MessageID(rawValue: "child"),
            splitAtTarget: true,
            latestMessageID: MessageID(rawValue: "grandchild")
        )
        let preflight = try ConversationForkValidator.preflight(
            request: request,
            conversation: Conversation(id: conversationID, title: "Source"),
            history: history
        )
        #expect(preflight.sourceMessageIDs == Set(history.map(\.id)))
    }

    @Test(arguments: [
        ConversationForkOption.directPath,
        ConversationForkOption.includeBranches,
        ConversationForkOption.targetLevel
    ])
    func allKnownOptionsRetainExactWireValues(_ option: ConversationForkOption) throws {
        #expect(ConversationForkOption(rawValue: option.rawValue) == option)
    }

    @Test func preflightFailsClosedForLocalMissingCrossConversationAndMalformedGraph() throws {
        let conversation = Conversation(id: conversationID, title: "Source")
        let cases: [([ChatMessage], MessageID)] = [
            ([message("local-target", parent: nil)], MessageID(rawValue: "local-target")),
            ([message("root", parent: nil)], MessageID(rawValue: "missing-target")),
            ([message("root", parent: nil), message("target", parent: "missing")], MessageID(rawValue: "target")),
            ([message("root", parent: nil), message("target", parent: "target")], MessageID(rawValue: "target"))
        ]
        for (history, targetMessageID) in cases {
            let request = ConversationForkRequest(
                profileID: profileID,
                accountID: accountID,
                conversationID: conversationID,
                targetMessageID: targetMessageID
            )
            #expect(throws: ConversationForkValidationError.self) {
                try ConversationForkValidator.preflight(
                    request: request,
                    conversation: conversation,
                    history: history
                )
            }
        }
    }

    @Test func splitRequiresLatestAndRejectsLatestOutsideTargetSubtree() throws {
        let history = [
            message("root", parent: nil),
            message("target", parent: "root"),
            message("other", parent: "root")
        ]
        let missingLatest = ConversationForkRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            targetMessageID: MessageID(rawValue: "target"),
            splitAtTarget: true
        )
        #expect(throws: ConversationForkValidationError.self) {
            try ConversationForkValidator.preflight(
                request: missingLatest,
                conversation: Conversation(id: conversationID, title: "Source"),
                history: history
            )
        }
        let outside = ConversationForkRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            targetMessageID: MessageID(rawValue: "target"),
            splitAtTarget: true,
            latestMessageID: MessageID(rawValue: "other")
        )
        #expect(throws: ConversationForkValidationError.self) {
            try ConversationForkValidator.preflight(
                request: outside,
                conversation: Conversation(id: conversationID, title: "Source"),
                history: history
            )
        }
    }

    @Test func responseRequiresFreshConversationMessageIDsAndValidParents() throws {
        let sourceHistory = [message("source", parent: nil)]
        let request = ConversationForkRequest(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            targetMessageID: MessageID(rawValue: "source")
        )
        let preflight = try ConversationForkValidator.preflight(
            request: request,
            conversation: Conversation(id: conversationID, title: "Source"),
            history: sourceHistory
        )
        let valid = ConversationForkResult(
            conversation: Conversation(id: ConversationID(rawValue: "fork"), title: "Source"),
            messages: [message("fresh", parent: nil, conversation: "fork")]
        )
        #expect(try ConversationForkValidator.validateResponse(valid, for: preflight) == valid)

        let collision = ConversationForkResult(
            conversation: Conversation(id: ConversationID(rawValue: "fork-2"), title: "Source"),
            messages: [message("source", parent: nil, conversation: "fork-2")]
        )
        #expect(throws: ConversationForkValidationError.self) {
            try ConversationForkValidator.validateResponse(collision, for: preflight)
        }

        let missingMessageConversation = Data(#"{"conversation":{"conversationId":"fork-3"},"messages":[{"messageId":"fresh","isCreatedByUser":true}]}"#.utf8)
        let dto = try JSONDecoder().decode(ConversationForkResponseDTO.self, from: missingMessageConversation)
        #expect(throws: ConversationForkValidationError.self) {
            try dto.domainModel(for: preflight)
        }
    }

    private func message(
        _ id: String,
        parent: String?,
        conversation: String = "conversation"
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: ConversationID(rawValue: conversation),
            parentMessageID: parent.map(MessageID.init(rawValue:)),
            content: [.text(id)],
            author: .user
        )
    }
}
