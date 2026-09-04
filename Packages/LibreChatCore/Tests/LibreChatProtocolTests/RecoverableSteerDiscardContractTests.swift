import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct RecoverableSteerDiscardContractTests {
    private let conversationID = ConversationID(rawValue: "conversation")
    private let identity = RecoverableSteerIdentity(
        id: "server:leftover_1",
        clientSteerID: "client_leftover-1"
    )

    @Test func factoryUsesExactV2CancelWireAndNeverRetries() throws {
        let request = try LibreChatSteeringAPI.discardRecoverable(
            conversationID: conversationID,
            generationCreatedAt: 1_720_000_000_123,
            identity: identity
        )

        #expect(request.method == .post)
        #expect(request.path == "api/agents/chat/steer/cancel")
        #expect(request.pathComponents == nil)
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        #expect(request.headers["X-LibreChat-Generation-Protocol"] == "2")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try body(request)
        #expect(Set(body.keys) == [
            "conversationId", "generationCreatedAt", "steerId",
            "clientSteerId", "generationProtocolVersion"
        ])
        #expect(body["conversationId"] as? String == "conversation")
        #expect((body["generationCreatedAt"] as? NSNumber)?.int64Value == 1_720_000_000_123)
        #expect(body["steerId"] as? String == "server:leftover_1")
        #expect(body["clientSteerId"] as? String == "client_leftover-1")
        #expect((body["generationProtocolVersion"] as? NSNumber)?.intValue == 2)
    }

    @Test func factoryRequiresCompleteRecoveryIdentity() {
        #expect(throws: LibreChatProtocolError.encoding(
            "A terminal steer discard requires the complete recovery identity."
        )) {
            _ = try LibreChatSteeringAPI.discardRecoverable(
                conversationID: conversationID,
                generationCreatedAt: 10,
                identity: RecoverableSteerIdentity(id: "server-only")
            )
        }
    }

    @Test func onlyRemovedTrueMapsToConfirmedDiscard() throws {
        #expect(try GenerationSteerCancelResponseDTO(
            removed: true,
            replayed: false,
            generationProtocolVersion: 2
        ).recoverableDiscardOutcome(
            statusCode: 200,
            identity: identity,
            expectedProtocolVersion: 2
        ) == .discarded(identity))

        #expect(try GenerationSteerCancelResponseDTO(
            removed: false,
            replayed: true,
            generationProtocolVersion: 2
        ).recoverableDiscardOutcome(
            statusCode: 200,
            identity: identity,
            expectedProtocolVersion: 2
        ) == .notRemoved(replayed: true))
    }

    @Test func malformedOrMismatchedAcknowledgementFailsClosed() {
        for dto in [
            GenerationSteerCancelResponseDTO(
                removed: nil,
                replayed: false,
                generationProtocolVersion: 2
            ),
            GenerationSteerCancelResponseDTO(
                removed: true,
                replayed: false,
                generationProtocolVersion: 1
            )
        ] {
            #expect(throws: LibreChatProtocolError.invalidResponse) {
                _ = try dto.recoverableDiscardOutcome(
                    statusCode: 200,
                    identity: identity,
                    expectedProtocolVersion: 2
                )
            }
        }
        #expect(throws: LibreChatProtocolError.invalidResponse) {
            _ = try GenerationSteerCancelResponseDTO(
                removed: true,
                generationProtocolVersion: 2
            ).recoverableDiscardOutcome(
                statusCode: 202,
                identity: identity,
                expectedProtocolVersion: 2
            )
        }
    }

    @Test func requestAndOutcomesRoundTripWithoutLosingSourceCoordinates() throws {
        let handle = GenerationHandle(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
            streamID: conversationID.rawValue,
            conversationID: conversationID,
            generationCreatedAt: 100,
            protocolVersion: 2
        )
        let request = RecoverableSteerDiscardRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            sourceHandle: handle,
            identity: identity
        )
        let decoded = try JSONDecoder().decode(
            RecoverableSteerDiscardRequest.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)

        for outcome in [
            RecoverableSteerDiscardOutcome.discarded(identity),
            .notRemoved(replayed: true),
            .conflict(code: "RUN_SETTLED"),
            .unauthorized,
            .deliveryUncertain(SteeringDeliveryUncertainty(
                clientSteerID: "client_leftover-1",
                steerID: "server:leftover_1",
                reason: .server(status: 503, code: nil)
            ))
        ] {
            #expect(try JSONDecoder().decode(
                RecoverableSteerDiscardOutcome.self,
                from: JSONEncoder().encode(outcome)
            ) == outcome)
        }
    }

    private func body<Response>(_ request: APIRequest<Response>) throws -> [String: Any]
    where Response: Decodable & Sendable {
        let data = try #require(request.body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
