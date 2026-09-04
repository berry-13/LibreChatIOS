import Foundation
import Testing
import LibreChatDomain
@testable import LibreChatProtocol

struct MessageEditingContractTests {
    @Test func exactPrimaryAndIndexedBodiesUseRawPathComponentsAndNeverRetry() throws {
        let primaryCoordinate = MessageTextCoordinate(
            conversationID: ConversationID(rawValue: "conversation/a %"),
            messageID: MessageID(rawValue: "message/b %"),
            location: .primaryText
        )
        let primary = try LibreChatMessagesAPI.update(
            coordinate: primaryCoordinate,
            text: "Revised"
        )
        #expect(primary.method == .put)
        #expect(primary.path == "api/messages")
        #expect(primary.pathComponents == [
            "api", "messages", "conversation/a %", "message/b %"
        ])
        #expect(primary.retryPolicy == .never)
        let primaryBody = try body(primary)
        #expect(Set(primaryBody.keys) == ["text"])
        #expect(primaryBody["text"] as? String == "Revised")

        let indexed = try LibreChatMessagesAPI.update(
            coordinate: MessageTextCoordinate(
                conversationID: primaryCoordinate.conversationID,
                messageID: primaryCoordinate.messageID,
                location: .contentPart(index: 3, kind: .reasoning)
            ),
            text: "Updated thought"
        )
        let indexedBody = try body(indexed)
        #expect(Set(indexedBody.keys) == ["text", "index"])
        #expect(indexedBody["text"] as? String == "Updated thought")
        #expect(indexedBody["index"] as? Int == 3)
        #expect(indexed.retryPolicy == .never)
    }

    @Test func negativeContentIndexIsRejectedBeforeTransport() {
        #expect(throws: MessageEditError.negativeContentPartIndex) {
            _ = try LibreChatMessagesAPI.update(
                coordinate: MessageTextCoordinate(
                    conversationID: ConversationID(rawValue: "conversation"),
                    messageID: MessageID(rawValue: "message"),
                    location: .contentPart(index: -1, kind: .text)
                ),
                text: "Value"
            )
        }
    }

    @Test func dtoPreservesPrimaryAndRawPartCoordinatesAcrossUnknownFields() throws {
        let data = Data(#"""
        {
          "messageId":"message",
          "conversationId":"conversation",
          "text":"Legacy",
          "futureTopLevel":{"enabled":true},
          "content":[
            {"type":"future_part","future":"value"},
            {"type":"text","text":"Visible","future":7},
            {"type":"think","think":"Private reasoning","unknown":true},
            {"type":"reasoning","text":"Render-only alias"}
          ]
        }
        """#.utf8)

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()
        #expect(message.editableTextCatalog == [
            EditableMessageText(location: .primaryText, text: "Legacy"),
            EditableMessageText(location: .contentPart(index: 1, kind: .text), text: "Visible"),
            EditableMessageText(location: .contentPart(index: 2, kind: .reasoning), text: "Private reasoning")
        ])
        #expect(message.content.contains(.unsupported(kind: "future_part")))
    }

    @Test func legacyCachedMessageDecodesWithoutInventingCoordinates() throws {
        let current = message(id: "message", parent: nil)
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)
        ) as? [String: Any])
        object.removeValue(forKey: "editableTextCatalog")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacy)

        #expect(decoded.editableTextCatalog.isEmpty)
    }

    @Test func treePreservesAuthoritativeSiblingOrdinalAndResolvesAncestryByIdentity() throws {
        let root = message(id: "root", parent: nil, createdAt: 1)
        // Same timestamp and reverse lexical IDs prove the server response
        // ordinal, not a locally invented ID tie-break, controls siblings.
        let first = message(id: "assistant-z", parent: "root", createdAt: 2)
        let second = message(id: "assistant-a", parent: "root", createdAt: 2)
        let child = message(id: "child", parent: "assistant-a", createdAt: 4)

        // Child-before-parent input still resolves ancestry by explicit IDs;
        // sibling ordinal remains exactly the authoritative flat-array order.
        let tree = MessageTree(messages: [child, root, first, second])
        let selection = try #require(tree.siblings(containing: second.id))

        #expect(tree.isStructurallyValid)
        #expect(tree.roots.map(\.id) == [root.id])
        #expect(selection.siblings.map(\.id) == [first.id, second.id])
        #expect(selection.selectedIndex == 1)
        #expect(selection.selectedMessage.id == second.id)
        #expect(tree.children(of: second.id).map(\.id) == [child.id])
    }

    @Test func knownRootSentinelsNormalizeToNilWithoutHidingUnknownMissingParents() throws {
        let uuidRoot = message(
            id: "uuid-root",
            parent: "00000000-0000-0000-0000-000000000000"
        )
        let legacyRoot = message(id: "legacy-root", parent: "NO_PARENT")
        let tree = MessageTree(messages: [legacyRoot, uuidRoot])

        #expect(tree.isStructurallyValid)
        #expect(tree.roots.map(\.id) == [legacyRoot.id, uuidRoot.id])
        let selection = try #require(tree.siblings(containing: uuidRoot.id))
        #expect(selection.parentMessageID == nil)
        #expect(selection.siblings.map(\.id) == [legacyRoot.id, uuidRoot.id])

        let missing = message(id: "orphan", parent: "unknown-parent")
        let invalid = MessageTree(messages: [uuidRoot, missing])
        #expect(!invalid.isStructurallyValid)
        #expect(invalid.roots.isEmpty)
        #expect(invalid.siblings(containing: uuidRoot.id) == nil)
        #expect(invalid.anomalies.contains(.missingParent(
            messageID: missing.id,
            parentMessageID: MessageID(rawValue: "unknown-parent")
        )))
    }

    @Test func branchProjectionUsesNewestSiblingAtEachDepthRatherThanFlatArrayTail() throws {
        let root = message(id: "root", parent: nil, createdAt: 1)
        let oldResponse = message(id: "old-response", parent: "root", createdAt: 2)
        let newResponse = message(id: "new-response", parent: "root", createdAt: 3)
        // This row is last in the authoritative flat array but belongs to the
        // older response branch. It must not become the default send parent.
        let oldBranchTail = message(id: "old-branch-tail", parent: "old-response", createdAt: 4)
        let tree = MessageTree(messages: [root, oldResponse, newResponse, oldBranchTail])

        let defaultProjection = try #require(tree.projection())
        #expect(defaultProjection.messages.map(\.id) == [root.id, newResponse.id])
        #expect(defaultProjection.tail?.id == newResponse.id)

        let selectedProjection = try #require(tree.projection(selectedChildByParent: [
            .message(root.id): oldResponse.id
        ]))
        #expect(selectedProjection.messages.map(\.id) == [
            root.id, oldResponse.id, oldBranchTail.id
        ])
        #expect(selectedProjection.entries[1].siblings.map(\.id) == [
            oldResponse.id, newResponse.id
        ])
        #expect(selectedProjection.entries[1].selectedIndex == 0)
    }

    @Test func focusingExactMessageReconstructsPathAndStaleSelectionsFallBackToNewest() throws {
        let rootA = message(id: "root-a", parent: nil, createdAt: 1)
        let rootB = message(id: "root-b", parent: nil, createdAt: 2)
        let responseA = message(id: "response-a", parent: "root-a", createdAt: 3)
        let responseB = message(id: "response-b", parent: "root-a", createdAt: 4)
        let tree = MessageTree(messages: [rootA, rootB, responseA, responseB])

        let focus = try #require(tree.selections(focusing: responseA.id))
        #expect(focus[.root] == rootA.id)
        #expect(focus[.message(rootA.id)] == responseA.id)
        #expect(tree.projection(selectedChildByParent: focus)?.tail?.id == responseA.id)

        let stale: [MessageTree.BranchParent: MessageID] = [
            .root: MessageID(rawValue: "deleted-root"),
            .message(rootA.id): responseA.id
        ]
        #expect(tree.validSelections(from: stale) == [
            .message(rootA.id): responseA.id
        ])
        #expect(tree.projection(selectedChildByParent: stale)?.tail?.id == rootB.id)
    }

    @Test func duplicateSelfParentAndCyclesFailClosed() {
        let duplicateA = message(id: "duplicate", parent: nil)
        let duplicateB = message(id: "duplicate", parent: nil, createdAt: 2)
        let selfParent = message(id: "self", parent: "self")
        let cycleA = message(id: "cycle-a", parent: "cycle-b")
        let cycleB = message(id: "cycle-b", parent: "cycle-a")
        let tree = MessageTree(messages: [cycleB, duplicateB, selfParent, cycleA, duplicateA])

        #expect(!tree.isStructurallyValid)
        #expect(tree.roots.isEmpty)
        #expect(tree.siblings(containing: cycleA.id) == nil)
        #expect(tree.projection() == nil)
        #expect(tree.selections(focusing: cycleA.id) == nil)
        #expect(tree.anomalies.contains(.duplicateMessageID(duplicateA.id)))
        #expect(tree.anomalies.contains(.selfParent(selfParent.id)))
        #expect(tree.anomalies.contains(.cycle(messageIDs: [cycleA.id, cycleB.id])))
    }

    private func body<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func message(
        id: String,
        parent: String?,
        createdAt: TimeInterval? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: ConversationID(rawValue: "conversation"),
            parentMessageID: parent.map(MessageID.init(rawValue:)),
            content: [.text(id)],
            author: .assistant(name: "Assistant"),
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:))
        )
    }
}
