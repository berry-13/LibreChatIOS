import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct SteeringMutationContractTests {
    private let conversationID = ConversationID(rawValue: "conversation-1")

    @Test func submitFactoryUsesExactV2WireAndNeverRetries() throws {
        let request = try LibreChatSteeringAPI.submit(
            conversationID: conversationID,
            generationCreatedAt: 1_720_000_000_123,
            clientSteerID: "client_steer-1",
            text: "Use a concise table",
            preempt: true
        )

        #expect(request.method == .post)
        #expect(request.path == "api/agents/chat/steer")
        #expect(request.pathComponents == nil)
        #expect(request.headers["X-LibreChat-Generation-Protocol"] == "2")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        let body = try body(request)
        #expect(Set(body.keys) == [
            "conversationId", "generationCreatedAt", "clientSteerId",
            "text", "files", "preempt", "generationProtocolVersion"
        ])
        #expect(body["conversationId"] as? String == "conversation-1")
        #expect((body["generationCreatedAt"] as? NSNumber)?.int64Value == 1_720_000_000_123)
        #expect(body["clientSteerId"] as? String == "client_steer-1")
        #expect(body["text"] as? String == "Use a concise table")
        #expect((body["files"] as? [Any])?.isEmpty == true)
        #expect(body["preempt"] as? Bool == true)
        #expect(body["generationProtocolVersion"] as? Int == 2)
    }

    @Test func cancelAndArmFactoriesUseExactControlCoordinates() throws {
        let cancel = try LibreChatSteeringAPI.cancel(
            conversationID: conversationID,
            generationCreatedAt: 44,
            steerID: "server-steer",
            clientSteerID: "client-steer"
        )
        let arm = try LibreChatSteeringAPI.arm(
            conversationID: conversationID,
            generationCreatedAt: 44,
            steerID: "server-steer",
            clientSteerID: "client-steer"
        )

        #expect(cancel.path == "api/agents/chat/steer/cancel")
        #expect(arm.path == "api/agents/chat/steer/arm")
        try verifyControl(cancel)
        try verifyControl(arm)
    }

    @Test func submissionMapsFreshReplaySettledAndLeftoverWithoutLosingReceipt() throws {
        let fresh = GenerationSteerReceiptDTO(
            status: "queued", steerID: "server", position: 2,
            conversationID: conversationID.rawValue, preempt: true,
            preemptRevision: 4, generationProtocolVersion: 2
        )
        let expected = GenerationSteerReceipt(
            steerID: "server", clientSteerID: "client", position: 2,
            conversationID: conversationID, preempt: true,
            preemptRevision: 4, generationProtocolVersion: 2
        )
        #expect(try fresh.domainOutcome(
            statusCode: 202,
            expectedConversationID: conversationID,
            clientSteerID: "client",
            expectedProtocolVersion: 2
        ) == .queued(expected))

        for (dto, outcome) in [
            (GenerationSteerReceiptDTO(
                status: "queued", steerID: "server", position: 2,
                conversationID: conversationID.rawValue, preempt: true,
                preemptRevision: 4, replayed: true,
                generationProtocolVersion: 2
            ), GenerationSteerSubmissionOutcome.replayed(expected)),
            (GenerationSteerReceiptDTO(
                status: "queued", steerID: "server", position: 2,
                conversationID: conversationID.rawValue, preempt: true,
                preemptRevision: 4, replayed: true, settled: true,
                generationProtocolVersion: 2
            ), .settled(expected)),
            (GenerationSteerReceiptDTO(
                status: "queued", steerID: "server", position: 2,
                conversationID: conversationID.rawValue, preempt: true,
                preemptRevision: 4, replayed: true, settled: true, leftover: true,
                generationProtocolVersion: 2
            ), .leftover(expected))
        ] {
            #expect(try dto.domainOutcome(
                statusCode: 202,
                expectedConversationID: conversationID,
                clientSteerID: "client",
                expectedProtocolVersion: 2
            ) == outcome)
        }
    }

    @Test func submissionFailsClosedOnAnyEchoOrStateMismatch() {
        let base = GenerationSteerReceiptDTO(
            status: "queued", steerID: "server", position: 0,
            conversationID: conversationID.rawValue, preempt: false,
            generationProtocolVersion: 2, clientSteerID: "different-client"
        )
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try base.domainOutcome(
                statusCode: 202,
                expectedConversationID: conversationID,
                clientSteerID: "client",
                expectedProtocolVersion: 2
            )
        }
        for dto in [
            GenerationSteerReceiptDTO(
                status: "started", steerID: "server", position: 0,
                conversationID: conversationID.rawValue, preempt: false,
                generationProtocolVersion: 2
            ),
            GenerationSteerReceiptDTO(
                status: "queued", steerID: "server", position: 0,
                conversationID: "replacement", preempt: false,
                generationProtocolVersion: 2
            ),
            GenerationSteerReceiptDTO(
                status: "queued", steerID: "server", position: 0,
                conversationID: conversationID.rawValue, preempt: false,
                generationProtocolVersion: 1
            ),
            GenerationSteerReceiptDTO(
                status: "queued", steerID: "server", position: 0,
                conversationID: conversationID.rawValue, preempt: false,
                replayed: false, settled: true, generationProtocolVersion: 2
            )
        ] {
            #expect(throws: LibreChatProtocolError.invalidResponse) {
                _ = try dto.domainOutcome(
                    statusCode: 202,
                    expectedConversationID: conversationID,
                    clientSteerID: "client",
                    expectedProtocolVersion: 2
                )
            }
        }
    }

    @Test func serverPreemptDowngradeIsAnAuthoritativeAcceptedReceipt() throws {
        let outcome = try GenerationSteerReceiptDTO(
            status: "queued", steerID: "server", position: 0,
            conversationID: conversationID.rawValue,
            preempt: false,
            generationProtocolVersion: 2
        ).domainOutcome(
            statusCode: 202,
            expectedConversationID: conversationID,
            clientSteerID: "requested-preempt",
            expectedProtocolVersion: 2
        )
        guard case let .queued(receipt) = outcome else {
            Issue.record("Expected a valid queued receipt")
            return
        }
        #expect(receipt.preempt == false)
        #expect(receipt.clientSteerID == "requested-preempt")
    }

    @Test func cancelOutcomeKeepsRemovedAndReplayAdvisoryDistinct() throws {
        #expect(try GenerationSteerCancelResponseDTO(
            removed: true, replayed: false, generationProtocolVersion: 2
        ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2) == .removed(replayed: false))
        #expect(try GenerationSteerCancelResponseDTO(
            removed: false, replayed: true, generationProtocolVersion: 2
        ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2) == .notRemoved(replayed: true))
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try GenerationSteerCancelResponseDTO(
                removed: true, generationProtocolVersion: 1
            ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2)
        }
    }

    @Test func armOutcomeRequiresMonotonicCoordinateAndBoundsAdvisoryCode() throws {
        #expect(try GenerationSteerArmResponseDTO(
            armed: true, preemptRevision: 7, generationProtocolVersion: 2
        ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2) == .armed(preemptRevision: 7))
        #expect(try GenerationSteerArmResponseDTO(
            armed: false, code: "PREEMPT_UNSUPPORTED", preemptRevision: 6,
            generationProtocolVersion: 2
        ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2) == .notArmed(
            code: "PREEMPT_UNSUPPORTED", preemptRevision: 6
        ))
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try GenerationSteerArmResponseDTO(
                armed: true, generationProtocolVersion: 2
            ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2)
        }
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try GenerationSteerArmResponseDTO(
                armed: false, code: "private response text", generationProtocolVersion: 2
            ).domainOutcome(statusCode: 200, expectedProtocolVersion: 2)
        }
    }

    private func body<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func verifyControl<Response>(_ request: APIRequest<Response>) throws
    where Response: Decodable & Sendable {
        #expect(request.method == .post)
        #expect(request.retryPolicy == .never)
        #expect(request.headers["X-LibreChat-Generation-Protocol"] == "2")
        let value = try body(request)
        #expect(Set(value.keys) == [
            "conversationId", "generationCreatedAt", "steerId",
            "clientSteerId", "generationProtocolVersion"
        ])
        #expect(value["conversationId"] as? String == "conversation-1")
        #expect(value["generationCreatedAt"] as? Int == 44)
        #expect(value["steerId"] as? String == "server-steer")
        #expect(value["clientSteerId"] as? String == "client-steer")
        #expect(value["generationProtocolVersion"] as? Int == 2)
    }
}
