import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class SteeringRepositoryTests: XCTestCase {
    override func tearDown() {
        SteeringURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSubmitUsesExactWireNormalizesTextAndInstallsAcceptedReceipt() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            return (
                Self.response(for: request, status: 202),
                Data(#"{"status":"queued","steerId":"server-1","position":0,"conversationId":"conversation","preempt":false,"generationProtocolVersion":2,"future":true}"#.utf8)
            )
        }

        let outcome = try await repository.submitSteer(GenerationSteerRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            handle: handle,
            clientSteerID: "client_1",
            text: " \0  Use a table  \n",
            preempt: true
        ))

        guard case let .queued(receipt) = outcome else {
            return XCTFail("Expected an accepted queued receipt")
        }
        XCTAssertEqual(receipt.steerID, "server-1")
        XCTAssertEqual(receipt.clientSteerID, "client_1")
        XCTAssertFalse(receipt.preempt, "The server's capability downgrade is authoritative")
        XCTAssertEqual(capture.paths, ["/api/agents/chat/steer"])
        XCTAssertEqual(capture.methods, ["POST"])
        XCTAssertEqual(capture.headers.first?["X-LibreChat-Generation-Protocol"], "2")
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(Set(body.keys), [
            "conversationId", "generationCreatedAt", "clientSteerId",
            "text", "files", "preempt", "generationProtocolVersion"
        ])
        XCTAssertEqual(body["conversationId"] as? String, "conversation")
        XCTAssertEqual((body["generationCreatedAt"] as? NSNumber)?.int64Value, 1000)
        XCTAssertEqual(body["clientSteerId"] as? String, "client_1")
        XCTAssertEqual(body["text"] as? String, "Use a table")
        XCTAssertEqual((body["files"] as? [Any])?.count, 0)
        XCTAssertEqual(body["preempt"] as? Bool, true)
        XCTAssertEqual((body["generationProtocolVersion"] as? NSNumber)?.intValue, 2)

        let saved = try await dependencies.cache.recoverableGenerations(
            profileID: handle.profileID,
            accountID: handle.accountID
        )
        XCTAssertEqual(saved.first?.pendingSteers, [PendingSteer(
            id: "server-1",
            clientSteerID: "client_1",
            text: "Use a table",
            files: [],
            preempt: false
        )])
    }

    func testRecoveredSteerStartUsesExactSourceDerivedWireCoordinates() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Test","endpoint":"agents","agent_id":"agent"}"#.utf8)
                )
            case ("POST", "/api/agents/chat/agents"):
                capture.record(request: request, body: try Self.bodyData(for: request))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected recovered-start request: \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let sourceID = "server-steer:1"
        let clientRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        let outcome = try await repository.send(ChatRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversation: Conversation(
                id: handle.conversationID,
                title: "Test",
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            parentMessageID: MessageID(rawValue: "finished-assistant"),
            text: "Use a table",
            expectedPredecessorCreatedAt: 1_000,
            recoverySteerID: sourceID,
            clientRequestID: clientRequestID,
            clientMessageID: MessageID(rawValue: sourceID)
        ))

        XCTAssertEqual(outcome, .settled(conversationID: handle.conversationID))
        XCTAssertEqual(capture.paths, ["/api/agents/chat/agents"])
        XCTAssertEqual(capture.headers.first?["X-LibreChat-Generation-Protocol"], "2")
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(body["recoverySteerId"] as? String, sourceID)
        XCTAssertEqual(body["overrideUserMessageId"] as? String, sourceID)
        XCTAssertEqual(body["messageId"] as? String, sourceID)
        XCTAssertEqual(body["parentMessageId"] as? String, "finished-assistant")
        XCTAssertEqual(body["clientRequestId"] as? String, clientRequestID.uuidString)
        XCTAssertEqual((body["expectedPredecessorCreatedAt"] as? NSNumber)?.int64Value, 1_000)
        XCTAssertEqual(body["isRegenerate"] as? Bool, false)
        XCTAssertEqual(body["isContinued"] as? Bool, false)
        XCTAssertNil(body["overrideParentMessageId"])
        XCTAssertNil(body["responseMessageId"])
    }

    func testCustomGenerationEndpointUsesOneEncodedPathComponentAndExactType() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Custom","endpoint":"My LLM Gateway","endpointType":"custom","model":"custom-model"}"#.utf8)
                )
            case ("POST", "/api/agents/chat/My LLM Gateway"):
                capture.record(request: request, body: try Self.bodyData(for: request))
                XCTAssertEqual(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.percentEncodedPath,
                    "/api/agents/chat/My%20LLM%20Gateway"
                )
                XCTAssertEqual(request.url?.pathComponents.suffix(1), ["My LLM Gateway"])
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected custom-endpoint request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let outcome = try await repository.send(ChatRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversation: Conversation(
                id: handle.conversationID,
                title: "Custom",
                target: ConversationTarget(
                    endpoint: "My LLM Gateway",
                    endpointType: "custom",
                    model: "custom-model"
                )
            ),
            parentMessageID: MessageID(rawValue: "finished-assistant"),
            text: "Hello",
            clientMessageID: MessageID(rawValue: "user-custom")
        ))

        XCTAssertEqual(outcome, .settled(conversationID: handle.conversationID))
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(body["endpoint"] as? String, "My LLM Gateway")
        XCTAssertEqual(body["endpointType"] as? String, "custom")
    }

    func testControlAndUnknownEndpointFamiliesNeverReachGenerationStart() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        let targets = [
            ConversationTarget(endpoint: "resume", endpointType: "custom", model: "model"),
            ConversationTarget(endpoint: "future-provider", model: "model")
        ]

        for target in targets {
            SteeringURLProtocolStub.handler = { request in
                capture.record(request: request, body: try Self.bodyData(for: request))
                guard request.httpMethod == "GET",
                      request.url?.path == "/api/convos/conversation" else {
                    XCTFail("An unsupported target must not reach generation ingress")
                    return (Self.response(for: request, status: 500), Data())
                }
                var object: [String: Any] = [
                    "conversationId": "conversation",
                    "title": "Unsupported",
                    "endpoint": target.endpoint,
                    "model": "model"
                ]
                object["endpointType"] = target.endpointType
                let body = try JSONSerialization.data(withJSONObject: object)
                return (Self.response(for: request, status: 200), body)
            }

            do {
                _ = try await repository.send(ChatRequest(
                    profileID: handle.profileID,
                    accountID: handle.accountID,
                    conversation: Conversation(
                        id: handle.conversationID,
                        title: "Unsupported",
                        target: target
                    ),
                    parentMessageID: MessageID(rawValue: "finished-assistant"),
                    text: "Do not send",
                    clientMessageID: MessageID(rawValue: "user-unsupported")
                ))
                XCTFail("Expected a fail-closed endpoint routing error")
            } catch let error as LibreChatProtocolError {
                guard case .unsupported = error else {
                    return XCTFail("Expected unsupported endpoint error, got \(error)")
                }
            }
        }

        XCTAssertEqual(capture.methods, ["GET", "GET"])
        XCTAssertEqual(capture.paths, ["/api/convos/conversation", "/api/convos/conversation"])
    }

    func testManualSkillsUseFreshPolicyAndExactGenerationWire() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"capabilities":["skills"]}}"#.utf8))
            case ("GET", "/api/config"):
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"skills":{"defaultActiveOnShare":false}}}"#.utf8))
            case ("GET", "/api/roles/USER"):
                return (Self.response(for: request, status: 200), Data(#"{"permissions":{"SKILLS":{"USE":true}}}"#.utf8))
            case ("GET", "/api/user/settings/skills/active"):
                return (Self.response(for: request, status: 200), Data("{}".utf8))
            case ("GET", "/api/skills"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","displayTitle":"Review code","description":"Review this change","author":"account","userInvocable":true}],"has_more":false,"after":null}"#.utf8)
                )
            case ("POST", "/api/agents/chat/openAI"):
                capture.record(request: request, body: try Self.bodyData(for: request))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"canonical","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected Skills request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let target = ConversationTarget(
            endpoint: "openAI",
            model: "gpt",
            ephemeralAgent: EphemeralAgentConfiguration()
        )
        let outcome = try await repository.send(ChatRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversation: Conversation(
                id: ConversationID(localDraftID: UUID()),
                title: "Skills",
                target: target
            ),
            text: "Review this",
            manualSkills: ["review-code"],
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            clientMessageID: MessageID(rawValue: "user-skills")
        ))

        XCTAssertEqual(outcome, .settled(conversationID: ConversationID(rawValue: "canonical")))
        XCTAssertEqual(capture.paths, ["/api/agents/chat/openAI"])
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(body["manualSkills"] as? [String], ["review-code"])
        let ephemeral = try XCTUnwrap(body["ephemeralAgent"] as? [String: Any])
        XCTAssertEqual(ephemeral["skills"] as? Bool, true)
    }

    func testInactiveManualSkillFailsBeforeGenerationPost() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"capabilities":["skills"]}}"#.utf8))
            case ("GET", "/api/config"):
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"skills":{"defaultActiveOnShare":false}}}"#.utf8))
            case ("GET", "/api/roles/USER"):
                return (Self.response(for: request, status: 200), Data(#"{"permissions":{"SKILLS":{"USE":true}}}"#.utf8))
            case ("GET", "/api/user/settings/skills/active"):
                return (Self.response(for: request, status: 200), Data(#"{"507f1f77bcf86cd799439011":false}"#.utf8))
            case ("GET", "/api/skills"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","description":"Review","author":"account","userInvocable":true}],"has_more":false}"#.utf8)
                )
            case ("POST", "/api/agents/chat/openAI"):
                capture.record(request: request, body: try Self.bodyData(for: request))
                return (Self.response(for: request, status: 500), Data())
            default:
                XCTFail("Unexpected Skills request: \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }

        do {
            _ = try await repository.send(ChatRequest(
                profileID: handle.profileID,
                accountID: handle.accountID,
                conversation: Conversation(
                    id: ConversationID(localDraftID: UUID()),
                    title: "Skills",
                    target: ConversationTarget(
                        endpoint: "openAI",
                        model: "gpt",
                        ephemeralAgent: EphemeralAgentConfiguration()
                    )
                ),
                text: "Review this",
                manualSkills: ["review-code"],
                clientMessageID: MessageID(rawValue: "user-skills")
            ))
            XCTFail("Expected inactive Skills selection to fail closed")
        } catch let error as SkillInvocationError {
            XCTAssertEqual(error, .selectionUnavailable("review-code"))
        }
        XCTAssertEqual(capture.count, 0)
    }

    func testResponseRegenerationReplaysOnlyFreshlyAuthorizedPersistedSkills() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        try await dependencies.cache.remove(handle: handle)
        await repository.resetInMemoryState()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Skills","endpoint":"agents","agent_id":"agent","model":"agent-model"}"#.utf8)
                )
            case ("GET", "/api/agents/chat/status/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"active":false,"status":"complete","createdAt":1000,"generationProtocolVersion":2}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"[{"messageId":"source-user","conversationId":"conversation","text":"Review this","manualSkills":["review-code"],"isCreatedByUser":true},{"messageId":"target-assistant__","conversationId":"conversation","parentMessageId":"source-user","text":"Prior answer","isCreatedByUser":false}]"#.utf8)
                )
            case ("GET", "/api/endpoints"):
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"capabilities":["skills"]}}"#.utf8))
            case ("GET", "/api/config"):
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"skills":{"defaultActiveOnShare":false}}}"#.utf8))
            case ("GET", "/api/roles/USER"):
                return (Self.response(for: request, status: 200), Data(#"{"permissions":{"SKILLS":{"USE":true}}}"#.utf8))
            case ("GET", "/api/user/settings/skills/active"):
                return (Self.response(for: request, status: 200), Data("{}".utf8))
            case ("GET", "/api/skills"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","description":"Review this change","author":"account","userInvocable":true}],"has_more":false}"#.utf8)
                )
            case ("GET", "/api/agents/agent"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"id":"agent","name":"Agent","provider":"openAI","model":"agent-model","skills_enabled":true,"skills":["507f1f77bcf86cd799439011"]}"#.utf8)
                )
            case ("POST", "/api/agents/chat/agents"):
                capture.record(request: request, body: try Self.bodyData(for: request))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","status":"settled","generationProtocolVersion":2}"#.utf8)
                )
            default:
                XCTFail("Unexpected regeneration Skills request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let outcome = try await repository.send(ChatRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversation: Conversation(
                id: handle.conversationID,
                title: "Skills",
                target: ConversationTarget(endpoint: "agents", model: "agent-model", agentID: "agent")
            ),
            text: "Review this",
            manualSkills: ["review-code"],
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            clientMessageID: MessageID(rawValue: "native-regeneration"),
            action: .regenerateResponse(
                sourceUserMessageID: MessageID(rawValue: "source-user"),
                targetAssistantMessageID: MessageID(rawValue: "target-assistant__")
            )
        ))

        XCTAssertEqual(outcome, .settled(conversationID: handle.conversationID))
        XCTAssertEqual(capture.paths, ["/api/agents/chat/agents"])
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(body["manualSkills"] as? [String], ["review-code"])
        XCTAssertEqual(body["messageId"] as? String, "source-user")
        XCTAssertEqual(body["overrideParentMessageId"] as? String, "source-user")
        XCTAssertEqual(body["responseMessageId"] as? String, "target-assistant_")
    }

    func testFollowUpAdmissionProofRequiresExactResumeUserAndReturnsRetainedActiveEpoch() async throws {
        let (repository, sourceHandle) = try await makeActiveRepository()
        let attempt = try makeFollowUpAttempt(sourceHandle: sourceHandle)
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: Data())
            return (
                Self.response(for: request, status: 200),
                Data(#"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof","files":[],"quotes":[],"manualSkills":[],"alwaysAppliedSkills":[]},"responseMessageId":"assistant-proof"}}"#.utf8)
            )
        }

        let proof = try await repository.followUpAdmissionProof(for: attempt)

        guard case let .active(handle) = proof else {
            return XCTFail("Expected exact retained active proof")
        }
        XCTAssertEqual(handle.clientRequestID, attempt.clientRequestID)
        XCTAssertEqual(handle.generationCreatedAt, 2_000)
        XCTAssertEqual(handle.streamID, "conversation")
        XCTAssertEqual(capture.paths, ["/api/agents/chat/status/conversation"])
        XCTAssertEqual(capture.methods, ["GET"])
        XCTAssertEqual(capture.headers.first?["X-LibreChat-Generation-Protocol"], "2")
    }

    func testFollowUpAdmissionProofMapsExactRetainedTerminalWithoutInventingJoblessProof() async throws {
        let (repository, sourceHandle) = try await makeActiveRepository()
        let attempt = try makeFollowUpAttempt(sourceHandle: sourceHandle)
        SteeringURLProtocolStub.handler = { request in
            return (
                Self.response(for: request, status: 200),
                Data(#"{"active":false,"streamId":"conversation","status":"complete","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof"},"responseMessageId":"assistant-proof"}}"#.utf8)
            )
        }

        let terminal = try await repository.followUpAdmissionProof(for: attempt)
        guard case let .terminal(handle, result) = terminal else {
            return XCTFail("Expected exact retained terminal proof")
        }
        XCTAssertEqual(handle.generationCreatedAt, 2_000)
        XCTAssertEqual(result, .completed(responseMessageID: MessageID(rawValue: "assistant-proof")))

        SteeringURLProtocolStub.handler = { request in
            return (
                Self.response(for: request, status: 200),
                Data(#"{"active":false,"generationProtocolVersion":2}"#.utf8)
            )
        }
        let jobless = try await repository.followUpAdmissionProof(for: attempt)
        XCTAssertNil(jobless)
    }

    func testFollowUpAdmissionProofRejectsMismatchedIdentityOrUnexpectedFiles() async throws {
        let (repository, sourceHandle) = try await makeActiveRepository()
        let attempt = try makeFollowUpAttempt(sourceHandle: sourceHandle)
        let bodies = [
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"other-user","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof"},"responseMessageId":"assistant-proof"}}"#,
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof","files":[{"file_id":"unexpected"}]},"responseMessageId":"assistant-proof"}}"#,
            #"{"active":true,"streamId":"conversation","status":"running","createdAt":1000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof"},"responseMessageId":"assistant-proof"}}"#
        ]

        for body in bodies {
            SteeringURLProtocolStub.handler = { request in
                (Self.response(for: request, status: 200), Data(body.utf8))
            }
            let proof = try await repository.followUpAdmissionProof(for: attempt)
            XCTAssertNil(proof)
        }
    }

    func testFollowUpAdmissionProofAcceptsOnlyExactCanonicalQueuedFileSet() async throws {
        let (repository, sourceHandle) = try await makeActiveRepository()
        let attachment = try FollowUpQueuedAttachment(
            uploadID: UUID(uuidString: "00000000-0000-0000-0000-000000000219")!,
            file: UploadedFile(
                id: "queued-file-proof",
                filename: "proof.txt",
                mimeType: "text/plain"
            )
        )
        let attempt = try makeFollowUpAttempt(
            sourceHandle: sourceHandle,
            attachments: [attachment]
        )

        SteeringURLProtocolStub.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data(#"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof","files":[{"file_id":"queued-file-proof","filename":"proof.txt"}],"quotes":[],"manualSkills":[],"alwaysAppliedSkills":[]},"responseMessageId":"assistant-proof"}}"#.utf8)
            )
        }
        let exact = try await repository.followUpAdmissionProof(for: attempt)
        guard case .active = exact else {
            return XCTFail("Expected the exact canonical file identity to be recoverable")
        }

        SteeringURLProtocolStub.handler = { request in
            (
                Self.response(for: request, status: 200),
                Data(#"{"active":true,"streamId":"conversation","status":"running","createdAt":2000,"generationProtocolVersion":2,"resumeState":{"userMessage":{"messageId":"queued-user-proof","conversationId":"conversation","parentMessageId":"assistant-source","text":"Queued proof","files":[{"file_id":"different-file"}]},"responseMessageId":"assistant-proof"}}"#.utf8)
            )
        }
        let mismatch = try await repository.followUpAdmissionProof(for: attempt)
        XCTAssertNil(mismatch)
    }

    func testRecoveredSteerStartRejectsIncompleteSourceCoordinatesBeforeNetwork() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: Data())
            return (Self.response(for: request, status: 500), Data())
        }
        let conversation = Conversation(
            id: handle.conversationID,
            title: "Test",
            target: ConversationTarget(endpoint: "agents", agentID: "agent")
        )

        for request in [
            ChatRequest(
                profileID: handle.profileID,
                accountID: handle.accountID,
                conversation: conversation,
                parentMessageID: MessageID(rawValue: "finished-assistant"),
                text: "Recover",
                recoverySteerID: "source-steer",
                clientMessageID: MessageID(rawValue: "different-message")
            ),
            ChatRequest(
                profileID: handle.profileID,
                accountID: handle.accountID,
                conversation: conversation,
                parentMessageID: MessageID(rawValue: "finished-assistant"),
                text: "Recover",
                recoverySteerID: "source-steer",
                clientMessageID: MessageID(rawValue: "source-steer")
            )
        ] {
            do {
                _ = try await repository.send(request)
                XCTFail("Incomplete recovery coordinates must fail before transport")
            } catch let error as LibreChatProtocolError {
                guard case .unsupported = error else {
                    return XCTFail("Expected fail-closed unsupported error, got \(error)")
                }
            }
        }
        XCTAssertTrue(capture.paths.isEmpty)
    }

    func testValidationRejectsNamespaceEpochProtocolIdentifiersAndTextBeforeNetwork() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: Data())
            return (Self.response(for: request, status: 500), Data())
        }

        let wrongNamespace = GenerationSteerRequest(
            profileID: .init(rawValue: "other-profile"),
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            handle: handle,
            clientSteerID: "client",
            text: "Valid"
        )
        await assertSteeringError(.contextMismatch) {
            _ = try await repository.submitSteer(wrongNamespace)
        }
        await assertSteeringError(.contextMismatch) {
            _ = try await repository.submitSteer(GenerationSteerRequest(
                profileID: handle.profileID,
                accountID: .init(rawValue: "other-account"),
                conversationID: handle.conversationID,
                handle: handle,
                clientSteerID: "client",
                text: "Valid"
            ))
        }

        for invalidHandle in [
            GenerationHandle(
                profileID: handle.profileID, accountID: handle.accountID,
                clientRequestID: handle.clientRequestID, streamID: handle.streamID,
                conversationID: handle.conversationID, generationCreatedAt: nil,
                protocolVersion: 2
            ),
            GenerationHandle(
                profileID: handle.profileID, accountID: handle.accountID,
                clientRequestID: handle.clientRequestID, streamID: handle.streamID,
                conversationID: handle.conversationID, generationCreatedAt: -1,
                protocolVersion: 2
            )
        ] {
            await assertSteeringError(.invalidGenerationEpoch) {
                _ = try await repository.submitSteer(self.request(handle: invalidHandle))
            }
        }
        let v1 = GenerationHandle(
            profileID: handle.profileID, accountID: handle.accountID,
            clientRequestID: handle.clientRequestID, streamID: handle.streamID,
            conversationID: handle.conversationID, generationCreatedAt: 1000,
            protocolVersion: 1
        )
        await assertSteeringError(.protocolMismatch) {
            _ = try await repository.submitSteer(self.request(handle: v1))
        }
        let unknownActiveHandle = GenerationHandle(
            profileID: handle.profileID, accountID: handle.accountID,
            clientRequestID: UUID(), streamID: handle.streamID,
            conversationID: handle.conversationID, generationCreatedAt: 1000,
            protocolVersion: 2
        )
        await assertSteeringError(.inactiveGeneration) {
            _ = try await repository.submitSteer(self.request(handle: unknownActiveHandle))
        }
        await assertSteeringError(.invalidClientSteerID) {
            _ = try await repository.submitSteer(self.request(handle: handle, clientID: "invalid id"))
        }
        await assertSteeringError(.emptyText) {
            _ = try await repository.submitSteer(self.request(handle: handle, text: " \0\n "))
        }
        await assertSteeringError(.textTooLong(maximumUTF16Length: 16_000)) {
            _ = try await repository.submitSteer(self.request(
                handle: handle,
                text: String(repeating: "😀", count: 8_001)
            ))
        }
        await assertSteeringError(.invalidSteerID) {
            _ = try await repository.cancelSteer(GenerationSteerControlRequest(
                profileID: handle.profileID,
                accountID: handle.accountID,
                conversationID: handle.conversationID,
                handle: handle,
                steerID: "bad/id",
                clientSteerID: "client"
            ))
        }
        XCTAssertEqual(capture.count, 0)
    }

    func testUncertainDeliveryAndMismatched202NeverRetryOrInstallPending() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            switch capture.count {
            case 1:
                throw URLError(.networkConnectionLost)
            case 2:
                return (
                    Self.response(for: request, status: 500),
                    Data(#"{"code":"PRIVATE_BODY_MUST_NOT_ESCAPE","message":"https://secret.invalid/value"}"#.utf8)
                )
            default:
                return (
                    Self.response(for: request, status: 202),
                    Data(#"{"status":"queued","steerId":"server-3","position":0,"conversationId":"different-conversation","preempt":false,"generationProtocolVersion":2}"#.utf8)
                )
            }
        }

        let first = try await repository.submitSteer(request(handle: handle, clientID: "stable_client"))
        XCTAssertEqual(first, .deliveryUncertain(SteeringDeliveryUncertainty(
            clientSteerID: "stable_client",
            reason: .transport
        )))
        let second = try await repository.submitSteer(request(handle: handle, clientID: "stable_client"))
        XCTAssertEqual(second, .deliveryUncertain(SteeringDeliveryUncertainty(
            clientSteerID: "stable_client",
            reason: .server(status: 500, code: nil)
        )))
        let third = try await repository.submitSteer(request(handle: handle, clientID: "stable_client"))
        XCTAssertEqual(third, .deliveryUncertain(SteeringDeliveryUncertainty(
            clientSteerID: "stable_client",
            reason: .invalidAcknowledgement
        )))
        XCTAssertEqual(capture.count, 3, "No ambiguous POST may be blindly repeated")
        XCTAssertEqual(Set(capture.bodies.compactMap { $0["clientSteerId"] as? String }), ["stable_client"])
        let saved = try await dependencies.cache.recoverableGenerations(
            profileID: handle.profileID,
            accountID: handle.accountID
        )
        XCTAssertTrue(saved.first?.pendingSteers.isEmpty == true)
    }

    func testDefiniteHTTPFailuresAnd409CodeRemainStructuredAndSingleAttempt() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            let status = [400, 403, 404, 409][capture.count - 1]
            let body = status == 409
                ? Data(#"{"code":"RUN_REPLACED"}"#.utf8)
                : Data(#"{"code":"REJECTED"}"#.utf8)
            return (Self.response(for: request, status: status), body)
        }

        for expectedStatus in [400, 403, 404] {
            do {
                _ = try await repository.submitSteer(request(handle: handle, clientID: "stable"))
                XCTFail("Expected HTTP \(expectedStatus)")
            } catch let LibreChatProtocolError.httpStatus(status, _, _) {
                XCTAssertEqual(status, expectedStatus)
            } catch {
                XCTFail("Expected a definite HTTP error, got \(error)")
            }
        }
        do {
            _ = try await repository.submitSteer(request(handle: handle, clientID: "stable"))
            XCTFail("Expected a structured generation conflict")
        } catch let LibreChatProtocolError.generationConflict(details) {
            XCTAssertEqual(details.code, "RUN_REPLACED")
        } catch {
            XCTFail("Expected a structured generation conflict, got \(error)")
        }
        XCTAssertEqual(capture.count, 4)
    }

    func testReplayLeftoverBecomesExactTerminalRecoveryNotActivePending() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        SteeringURLProtocolStub.handler = { request in
            (
                Self.response(for: request, status: 202),
                Data(#"{"status":"queued","steerId":"server-leftover","position":1,"conversationId":"conversation","preempt":true,"preemptRevision":4,"replayed":true,"settled":true,"leftover":true,"generationProtocolVersion":2}"#.utf8)
            )
        }

        let outcome = try await repository.submitSteer(request(
            handle: handle,
            clientID: "client-leftover",
            text: "  Preserve exactly  " ,
            preempt: true
        ))
        guard case let .leftover(receipt) = outcome else {
            return XCTFail("Expected an exact leftover replay receipt")
        }
        XCTAssertEqual(receipt.steerID, "server-leftover")
        let active = try await repository.recoverableGenerations()
        let terminal = try await repository.recoverableSteerBatches(
            conversationID: handle.conversationID
        )
        XCTAssertTrue(active.isEmpty)
        XCTAssertEqual(terminal.count, 1)
        XCTAssertEqual(terminal.first?.handle, handle)
        XCTAssertEqual(terminal.first?.steers, [PendingSteer(
            id: "server-leftover",
            clientSteerID: "client-leftover",
            text: "Preserve exactly",
            files: [],
            preempt: true,
            preemptRevision: 4
        )])
    }

    func testArmAndCancelShareOneLaneAndRevisionNeverRollsBack() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        SteeringURLProtocolStub.handler = { request in
            (
                Self.response(for: request, status: 202),
                Data(#"{"status":"queued","steerId":"server-race","position":0,"conversationId":"conversation","preempt":false,"preemptRevision":1,"generationProtocolVersion":2}"#.utf8)
            )
        }
        _ = try await repository.submitSteer(request(handle: handle, clientID: "client-race"))

        let gate = SteeringMutationGate()
        SteeringURLProtocolStub.handler = { request in
            let ordinal = gate.record(request.url?.path ?? "")
            if ordinal == 1 { gate.waitUntilReleased() }
            switch ordinal {
            case 1:
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"armed":true,"preemptRevision":7,"generationProtocolVersion":2}"#.utf8)
                )
            case 2:
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"armed":true,"preemptRevision":5,"generationProtocolVersion":2}"#.utf8)
                )
            default:
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"removed":true,"replayed":false,"generationProtocolVersion":2}"#.utf8)
                )
            }
        }
        let control = GenerationSteerControlRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            handle: handle,
            steerID: "server-race",
            clientSteerID: "client-race"
        )

        let firstArm = Task { try await repository.armSteer(control) }
        while gate.count == 0 { await Task.yield() }
        let staleArm = Task { try await repository.armSteer(control) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.count, 1, "The exact generation control lane must serialize requests")
        gate.releaseFirst()
        let firstArmOutcome = try await firstArm.value
        let staleArmOutcome = try await staleArm.value
        XCTAssertEqual(firstArmOutcome, .armed(preemptRevision: 7))
        XCTAssertEqual(staleArmOutcome, .armed(preemptRevision: 5))

        let beforeCancel = try await dependencies.cache.recoverableGenerations(
            profileID: handle.profileID,
            accountID: handle.accountID
        )
        XCTAssertEqual(beforeCancel.first?.pendingSteers.first?.preemptRevision, 7)
        XCTAssertEqual(beforeCancel.first?.pendingSteers.first?.preempt, true)
        let cancelOutcome = try await repository.cancelSteer(control)
        XCTAssertEqual(cancelOutcome, .removed(replayed: false))
        XCTAssertEqual(gate.paths, [
            "/api/agents/chat/steer/arm",
            "/api/agents/chat/steer/arm",
            "/api/agents/chat/steer/cancel"
        ])
        let afterCancel = try await dependencies.cache.recoverableGenerations(
            profileID: handle.profileID,
            accountID: handle.accountID
        )
        XCTAssertTrue(afterCancel.first?.pendingSteers.isEmpty == true)
    }

    func testCancelledLaneWaiterNeverDispatchesAfterEarlierMutationReleases() async throws {
        let (repository, handle) = try await makeActiveRepository()
        SteeringURLProtocolStub.handler = { request in
            (
                Self.response(for: request, status: 202),
                Data(#"{"status":"queued","steerId":"server-cancelled-waiter","position":0,"conversationId":"conversation","preempt":false,"generationProtocolVersion":2}"#.utf8)
            )
        }
        _ = try await repository.submitSteer(request(handle: handle, clientID: "client-cancelled-waiter"))

        let gate = SteeringMutationGate()
        SteeringURLProtocolStub.handler = { request in
            let ordinal = gate.record(request.url?.path ?? "")
            if ordinal == 1 { gate.waitUntilReleased() }
            return (
                Self.response(for: request, status: 200),
                Data(#"{"armed":true,"preemptRevision":2,"generationProtocolVersion":2}"#.utf8)
            )
        }
        let control = GenerationSteerControlRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            handle: handle,
            steerID: "server-cancelled-waiter",
            clientSteerID: "client-cancelled-waiter"
        )

        let first = Task { try await repository.armSteer(control) }
        while gate.count == 0 { await Task.yield() }
        let cancelled = Task { try await repository.cancelSteer(control) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        gate.releaseFirst()
        _ = try await first.value

        do {
            _ = try await cancelled.value
            XCTFail("A cancelled pre-dispatch waiter must not reach the control route")
        } catch is CancellationError {
            // Expected: cancellation was observed after lane admission and
            // before any second HTTP mutation was dispatched.
        }
        XCTAssertEqual(gate.count, 1)
        XCTAssertEqual(gate.paths, ["/api/agents/chat/steer/arm"])
    }

    func testTerminalDiscardUsesExactCancelWireAndOnlyRemovedTrueAcknowledgesRecovery() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        let identity = RecoverableSteerIdentity(
            id: "server:leftover_1",
            clientSteerID: "client_leftover-1"
        )
        try await seedTerminalRecovery(
            dependencies: dependencies,
            handle: handle,
            identity: identity
        )
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            return (
                Self.response(for: request, status: 200),
                Data(#"{"removed":true,"replayed":false,"generationProtocolVersion":2,"future":true}"#.utf8)
            )
        }

        let outcome = try await repository.discardRecoverableSteer(
            discardRequest(handle: handle, identity: identity)
        )

        XCTAssertEqual(outcome, .discarded(identity))
        XCTAssertEqual(capture.paths, ["/api/agents/chat/steer/cancel"])
        XCTAssertEqual(capture.methods, ["POST"])
        XCTAssertEqual(capture.headers.first?["X-LibreChat-Generation-Protocol"], "2")
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(Set(body.keys), [
            "conversationId", "generationCreatedAt", "steerId",
            "clientSteerId", "generationProtocolVersion"
        ])
        XCTAssertEqual(body["conversationId"] as? String, "conversation")
        XCTAssertEqual((body["generationCreatedAt"] as? NSNumber)?.int64Value, 1000)
        XCTAssertEqual(body["steerId"] as? String, "server:leftover_1")
        XCTAssertEqual(body["clientSteerId"] as? String, "client_leftover-1")
        XCTAssertEqual((body["generationProtocolVersion"] as? NSNumber)?.intValue, 2)
        let remaining = try await repository.recoverableSteerBatches(
            conversationID: handle.conversationID
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTerminalDiscardNonSuccessAndUncertaintyNeverDeleteRecoveryOrRetryMutation() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        let identity = RecoverableSteerIdentity(
            id: "server:leftover_2",
            clientSteerID: "client_leftover-2"
        )
        try await seedTerminalRecovery(
            dependencies: dependencies,
            handle: handle,
            identity: identity
        )
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            guard request.url?.path == "/api/agents/chat/steer/cancel" else {
                return (
                    Self.response(for: request, status: 401),
                    Data(#"{"code":"UNAUTHORIZED"}"#.utf8)
                )
            }
            capture.record(request: request, body: try Self.bodyData(for: request))
            switch capture.count {
            case 1:
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"removed":false,"replayed":true,"generationProtocolVersion":2}"#.utf8)
                )
            case 2:
                return (
                    Self.response(for: request, status: 409),
                    Data(#"{"code":"RUN_SETTLED","message":"private detail"}"#.utf8)
                )
            case 3:
                throw URLError(.networkConnectionLost)
            case 4:
                return (
                    Self.response(for: request, status: 500),
                    Data(#"{"code":"PRIVATE_BODY","message":"https://secret.invalid/value"}"#.utf8)
                )
            case 5:
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"removed":true,"generationProtocolVersion":1}"#.utf8)
                )
            default:
                return (
                    Self.response(for: request, status: 401),
                    Data(#"{"code":"UNAUTHORIZED"}"#.utf8)
                )
            }
        }
        let request = discardRequest(handle: handle, identity: identity)

        let outcomes = try await [
            repository.discardRecoverableSteer(request),
            repository.discardRecoverableSteer(request),
            repository.discardRecoverableSteer(request),
            repository.discardRecoverableSteer(request),
            repository.discardRecoverableSteer(request),
            repository.discardRecoverableSteer(request)
        ]

        XCTAssertEqual(outcomes, [
            .notRemoved(replayed: true),
            .conflict(code: "RUN_SETTLED"),
            .deliveryUncertain(SteeringDeliveryUncertainty(
                clientSteerID: "client_leftover-2",
                steerID: "server:leftover_2",
                reason: .transport
            )),
            .deliveryUncertain(SteeringDeliveryUncertainty(
                clientSteerID: "client_leftover-2",
                steerID: "server:leftover_2",
                reason: .server(status: 500, code: nil)
            )),
            .deliveryUncertain(SteeringDeliveryUncertainty(
                clientSteerID: "client_leftover-2",
                steerID: "server:leftover_2",
                reason: .invalidAcknowledgement
            )),
            .unauthorized
        ])
        XCTAssertEqual(capture.count, 6, "Every non-idempotent cancel is dispatched at most once")
        let remaining = try await repository.recoverableSteerBatches(
            conversationID: handle.conversationID
        )
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.steers.map(\.recoveryIdentity), [identity])
    }

    func testTerminalDiscardValidatesFullSourceAndExactRecoveryBeforeNetwork() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let (repository, handle) = try await makeActiveRepository(dependencies: dependencies)
        let identity = RecoverableSteerIdentity(
            id: "server:leftover_3",
            clientSteerID: "client_leftover-3"
        )
        try await seedTerminalRecovery(
            dependencies: dependencies,
            handle: handle,
            identity: identity
        )
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            return (Self.response(for: request, status: 500), Data())
        }

        await assertDiscardError(.contextMismatch) {
            _ = try await repository.discardRecoverableSteer(RecoverableSteerDiscardRequest(
                profileID: ServerProfileID(rawValue: "other-profile"),
                accountID: handle.accountID,
                conversationID: handle.conversationID,
                sourceHandle: handle,
                identity: identity
            ))
        }
        await assertDiscardError(.contextMismatch) {
            _ = try await repository.discardRecoverableSteer(RecoverableSteerDiscardRequest(
                profileID: handle.profileID,
                accountID: AccountID(rawValue: "other-account"),
                conversationID: handle.conversationID,
                sourceHandle: handle,
                identity: identity
            ))
        }
        let missingEpoch = GenerationHandle(
            profileID: handle.profileID,
            accountID: handle.accountID,
            clientRequestID: handle.clientRequestID,
            streamID: handle.streamID,
            conversationID: handle.conversationID,
            generationCreatedAt: nil,
            protocolVersion: 2
        )
        await assertDiscardError(.invalidGenerationEpoch) {
            _ = try await repository.discardRecoverableSteer(
                discardRequest(handle: missingEpoch, identity: identity)
            )
        }
        let legacy = GenerationHandle(
            profileID: handle.profileID,
            accountID: handle.accountID,
            clientRequestID: handle.clientRequestID,
            streamID: handle.streamID,
            conversationID: handle.conversationID,
            generationCreatedAt: 1000,
            protocolVersion: 1
        )
        await assertDiscardError(.protocolMismatch) {
            _ = try await repository.discardRecoverableSteer(
                discardRequest(handle: legacy, identity: identity)
            )
        }
        await assertDiscardError(.invalidSteerID) {
            _ = try await repository.discardRecoverableSteer(discardRequest(
                handle: handle,
                identity: RecoverableSteerIdentity(
                    id: "invalid server id",
                    clientSteerID: "client"
                )
            ))
        }
        await assertDiscardError(.invalidClientSteerID) {
            _ = try await repository.discardRecoverableSteer(discardRequest(
                handle: handle,
                identity: RecoverableSteerIdentity(id: "server:leftover_3")
            ))
        }
        await assertDiscardError(.sourceNotRecoverable) {
            _ = try await repository.discardRecoverableSteer(discardRequest(
                handle: handle,
                identity: RecoverableSteerIdentity(
                    id: "server:other",
                    clientSteerID: "client_other"
                )
            ))
        }
        let replacement = GenerationHandle(
            profileID: handle.profileID,
            accountID: handle.accountID,
            clientRequestID: UUID(),
            streamID: handle.streamID,
            conversationID: handle.conversationID,
            generationCreatedAt: 1001,
            protocolVersion: 2
        )
        await assertDiscardError(.sourceNotRecoverable) {
            _ = try await repository.discardRecoverableSteer(
                discardRequest(handle: replacement, identity: identity)
            )
        }
        XCTAssertEqual(capture.count, 0)
    }

    private func request(
        handle: GenerationHandle,
        clientID: String = "client",
        text: String = "Add this",
        preempt: Bool = false
    ) -> GenerationSteerRequest {
        GenerationSteerRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            handle: handle,
            clientSteerID: clientID,
            text: text,
            preempt: preempt
        )
    }

    private func discardRequest(
        handle: GenerationHandle,
        identity: RecoverableSteerIdentity
    ) -> RecoverableSteerDiscardRequest {
        RecoverableSteerDiscardRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            conversationID: handle.conversationID,
            sourceHandle: handle,
            identity: identity
        )
    }

    private func seedTerminalRecovery(
        dependencies: AppDependencies,
        handle: GenerationHandle,
        identity: RecoverableSteerIdentity
    ) async throws {
        try await dependencies.cache.save(GenerationSnapshot(
            handle: handle,
            state: .aborted,
            recoverableSteers: [PendingSteer(
                id: identity.id,
                clientSteerID: identity.clientSteerID,
                text: "Terminal leftover"
            )]
        ))
    }

    func testMessageFeedbackUsesExactWireAndReturnsOnlyExactAcknowledgement() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            return (
                Self.response(for: request, status: 200),
                Data(#"{"messageId":"response","conversationId":"conversation","feedback":{"rating":"thumbsUp","tag":"accurate_reliable","text":"Correct"}}"#.utf8)
            )
        }
        let feedback = MessageFeedback(tag: .accurateReliable, text: "Correct")

        let result = try await repository.updateMessageFeedback(MessageFeedbackRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            coordinate: MessageFeedbackCoordinate(
                conversationID: handle.conversationID,
                messageID: MessageID(rawValue: "response")
            ),
            feedback: feedback
        ))

        XCTAssertEqual(result.feedback, feedback)
        XCTAssertEqual(result.resolution, .confirmedAfterResponse)
        XCTAssertNil(result.authoritativeHistory)
        XCTAssertEqual(capture.paths, ["/api/messages/conversation/response/feedback"])
        XCTAssertEqual(capture.methods, ["PUT"])
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(Set(body.keys), ["feedback"])
        let sent = try XCTUnwrap(body["feedback"] as? [String: Any])
        XCTAssertEqual(sent["rating"] as? String, "thumbsUp")
        XCTAssertEqual(sent["tag"] as? String, "accurate_reliable")
        XCTAssertEqual(sent["text"] as? String, "Correct")
    }

    func testMalformedFeedbackAcknowledgementReconcilesHistoryWithoutRepeatingPUT() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        SteeringURLProtocolStub.handler = { request in
            capture.record(request: request, body: try Self.bodyData(for: request))
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/api/messages/conversation/response/feedback"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"messageId":"response","conversationId":"conversation","feedback":{"rating":"thumbsDown","tag":"future_reason"}}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"[{"messageId":"user","conversationId":"conversation","sender":"User","isCreatedByUser":true,"text":"Question"},{"messageId":"response","conversationId":"conversation","parentMessageId":"user","sender":"Assistant","isCreatedByUser":false,"text":"Answer","feedback":{"rating":"thumbsDown","tag":"not_helpful","text":"Missed it"}}]"#.utf8)
                )
            default:
                XCTFail("Unexpected feedback reconciliation request")
                return (Self.response(for: request, status: 404), Data())
            }
        }
        let feedback = MessageFeedback(tag: .notHelpful, text: "Missed it")

        let result = try await repository.updateMessageFeedback(MessageFeedbackRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            coordinate: MessageFeedbackCoordinate(
                conversationID: handle.conversationID,
                messageID: MessageID(rawValue: "response")
            ),
            feedback: feedback
        ))

        XCTAssertEqual(result.feedback, feedback)
        XCTAssertEqual(result.resolution, .reconciledAfterAmbiguousFailure)
        XCTAssertEqual(result.authoritativeHistory?.count, 2)
        XCTAssertEqual(capture.paths, [
            "/api/messages/conversation/response/feedback",
            "/api/messages/conversation"
        ])
        XCTAssertEqual(capture.methods, ["PUT", "GET"])
    }

    private func assertSteeringError(
        _ expected: GenerationSteeringError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected steering validation error \(expected)")
        } catch let error as GenerationSteeringError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected steering validation error, got \(error)")
        }
    }

    private func assertDiscardError(
        _ expected: RecoverableSteerDiscardError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected terminal discard validation error \(expected)")
        } catch let error as RecoverableSteerDiscardError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected terminal discard validation error, got \(error)")
        }
    }

    func testAccountSkillActivationUsesExactWholeMapWireAndInstallsConfirmedState() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let capture = SteeringRequestCapture()
        let changedID = "507f1f77bcf86cd799439011"
        let retainedID = "507f1f77bcf86cd799439012"
        SteeringURLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"capabilities":["skills"]}}"#.utf8))
            case ("GET", "/api/config"):
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"skills":{"defaultActiveOnShare":false}}}"#.utf8))
            case ("GET", "/api/roles/USER"):
                return (Self.response(for: request, status: 200), Data(#"{"permissions":{"SKILLS":{"USE":true}}}"#.utf8))
            case ("GET", "/api/user/settings/skills/active"):
                return (Self.response(for: request, status: 200), Data(#"{"507f1f77bcf86cd799439012":false}"#.utf8))
            case ("GET", "/api/skills"):
                return (
                    Self.response(for: request, status: 200),
                    // Non-owned skills default inactive, so the requested
                    // activation is a real state change.
                    Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","description":"Review code","author":"collaborator","userInvocable":true},{"_id":"507f1f77bcf86cd799439012","name":"make-chart","description":"Make a chart","author":"collaborator","userInvocable":true}],"has_more":false}"#.utf8)
                )
            case ("POST", "/api/user/settings/skills/active"):
                capture.record(request: request, body: try Self.bodyData(for: request))
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"507f1f77bcf86cd799439011":true,"507f1f77bcf86cd799439012":false}"#.utf8)
                )
            default:
                XCTFail("Unexpected Skill activation request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let outcome = try await repository.setSkillActivation(SkillActivationRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            skillID: SkillID(rawValue: changedID),
            isActive: true
        ))

        guard case let .confirmed(catalog) = outcome else {
            return XCTFail("Expected confirmed account Skill activation")
        }
        XCTAssertEqual(catalog.skill(id: SkillID(rawValue: changedID))?.isActive, true)
        XCTAssertEqual(catalog.explicitStates, [
            SkillID(rawValue: changedID): true,
            SkillID(rawValue: retainedID): false,
        ])
        XCTAssertEqual(capture.methods, ["POST"])
        XCTAssertEqual(capture.paths, ["/api/user/settings/skills/active"])
        let body = try XCTUnwrap(capture.bodies.first)
        XCTAssertEqual(Set(body.keys), ["skillStates"])
        XCTAssertEqual(body["skillStates"] as? [String: Bool], [
            changedID: true,
            retainedID: false,
        ])
    }

    func testLostSkillActivationResponseReconcilesOnceWithoutReposting() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let state = SkillActivationWireState(commitOnPost: true)
        let changedID = "507f1f77bcf86cd799439011"
        SteeringURLProtocolStub.handler = { request in
            state.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"capabilities":["skills"]}}"#.utf8))
            case ("GET", "/api/config"):
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"skills":{"defaultActiveOnShare":false}}}"#.utf8))
            case ("GET", "/api/roles/USER"):
                return (Self.response(for: request, status: 200), Data(#"{"permissions":{"SKILLS":{"USE":true}}}"#.utf8))
            case ("GET", "/api/user/settings/skills/active"):
                let body = state.didCommit
                    ? #"{"507f1f77bcf86cd799439011":true}"#
                    : #"{}"#
                return (Self.response(for: request, status: 200), Data(body.utf8))
            case ("GET", "/api/skills"):
                return (
                    Self.response(for: request, status: 200),
                    // Non-owned: defaults inactive, so the activation is real.
                    Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","description":"Review code","author":"collaborator","userInvocable":true}],"has_more":false}"#.utf8)
                )
            case ("POST", "/api/user/settings/skills/active"):
                state.commitIfConfigured()
                throw URLError(.networkConnectionLost)
            default:
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let outcome = try await repository.setSkillActivation(SkillActivationRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            skillID: SkillID(rawValue: changedID),
            isActive: true
        ))

        guard case let .confirmed(catalog) = outcome else {
            return XCTFail("Expected the one reconciliation read to prove delivery")
        }
        XCTAssertEqual(catalog.explicitStates[SkillID(rawValue: changedID)], true)
        XCTAssertEqual(state.postCount, 1)
        XCTAssertEqual(state.activeStateReadCount, 2)
    }

    func testUnconfirmedSkillActivationReturnsFreshStateAndNeverReposts() async throws {
        let (repository, handle) = try await makeActiveRepository()
        let state = SkillActivationWireState(commitOnPost: false)
        let changedID = "507f1f77bcf86cd799439011"
        SteeringURLProtocolStub.handler = { request in
            state.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/endpoints"):
                return (Self.response(for: request, status: 200), Data(#"{"agents":{"capabilities":["skills"]}}"#.utf8))
            case ("GET", "/api/config"):
                return (Self.response(for: request, status: 200), Data(#"{"interface":{"skills":{"defaultActiveOnShare":false}}}"#.utf8))
            case ("GET", "/api/roles/USER"):
                return (Self.response(for: request, status: 200), Data(#"{"permissions":{"SKILLS":{"USE":true}}}"#.utf8))
            case ("GET", "/api/user/settings/skills/active"):
                return (Self.response(for: request, status: 200), Data(#"{}"#.utf8))
            case ("GET", "/api/skills"):
                return (
                    Self.response(for: request, status: 200),
                    // Non-owned: defaults inactive, so the activation is real.
                    Data(#"{"skills":[{"_id":"507f1f77bcf86cd799439011","name":"review-code","description":"Review code","author":"collaborator","userInvocable":true}],"has_more":false}"#.utf8)
                )
            case ("POST", "/api/user/settings/skills/active"):
                state.commitIfConfigured()
                throw URLError(.networkConnectionLost)
            default:
                return (Self.response(for: request, status: 404), Data())
            }
        }

        let outcome = try await repository.setSkillActivation(SkillActivationRequest(
            profileID: handle.profileID,
            accountID: handle.accountID,
            skillID: SkillID(rawValue: changedID),
            isActive: true
        ))

        guard case let .notConfirmed(catalog) = outcome else {
            return XCTFail("Expected authoritative server state to reject the requested value")
        }
        XCTAssertEqual(catalog.skill(id: SkillID(rawValue: changedID))?.isActive, false)
        XCTAssertEqual(state.postCount, 1)
        XCTAssertEqual(state.activeStateReadCount, 2)
    }

    private func makeActiveRepository(
        dependencies suppliedDependencies: AppDependencies? = nil
    ) async throws -> (LibreChatRepository, GenerationHandle) {
        let dependencies = try suppliedDependencies ?? AppDependencies(inMemory: true)
        let baseURL = URL(string: "https://chat.example.com")!
        let account = UserAccount(id: AccountID(rawValue: "account"), role: "USER")
        let profile = ServerProfile(
            id: ServerProfileID(rawValue: "profile"),
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id,
            capabilities: ServerCapabilities(generation: .resumable(version: 2))
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: SteeringSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SteeringURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let authentication = LibreChatProtocol.AuthSession.isolated(transport: transport)
        await authentication.setAuthenticated(AuthenticatedSession(accessToken: "token", user: account))
        let repository = LibreChatRepository(
            profile: profile,
            runtime: LibreChatRuntime(
                cookieJar: jar,
                transport: transport,
                authSession: authentication,
                restClient: RESTClient(transport: transport, authSession: authentication)
            ),
            cache: dependencies.cache,
            generationStartSleep: { _ in }
        )
        await repository.activate(account: account)
        let handle = GenerationHandle(
            profileID: profile.id,
            accountID: account.id,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!,
            streamID: "conversation",
            conversationID: ConversationID(rawValue: "conversation"),
            generationCreatedAt: 1000,
            protocolVersion: 2
        )
        SteeringURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/agents/chat/status/conversation")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"active":true,"streamId":"conversation","status":"running","createdAt":1000,"generationProtocolVersion":2,"resumeState":{"pendingSteers":[]}}"#.utf8)
            )
        }
        _ = try await repository.reconcile(handle)
        return (repository, handle)
    }

    private func makeFollowUpAttempt(
        sourceHandle: GenerationHandle,
        attachments: [FollowUpQueuedAttachment] = []
    ) throws -> FollowUpAdmissionAttempt {
        let namespace = try FollowUpQueueNamespace(
            profileID: sourceHandle.profileID,
            accountID: sourceHandle.accountID,
            conversationID: sourceHandle.conversationID
        )
        let item = try FollowUpQueueItem(
            id: FollowUpQueueItemID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000210")!
            ),
            namespace: namespace,
            order: FollowUpQueueOrder(rawValue: 1),
            text: "Queued proof",
            attachments: attachments,
            target: FollowUpTargetFingerprint(
                target: ConversationTarget(endpoint: "agents", agentID: "agent")
            ),
            sourceAnchor: FollowUpSourceAnchor(
                handle: sourceHandle,
                sourceUserMessageID: MessageID(rawValue: "source-user")
            )
        )
        var reducer = FollowUpQueueReducer(
            snapshot: try FollowUpQueueSnapshot(namespace: namespace, items: [item])
        )
        return try XCTUnwrap(try reducer.reserveNext(
            after: .completed(
                handle: sourceHandle,
                responseMessageID: MessageID(rawValue: "assistant-source")
            ),
            attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
            clientRequestID: UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
            clientMessageID: MessageID(rawValue: "queued-user-proof")
        ))
    }

    nonisolated private static func response(
        for request: URLRequest,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            data.append(buffer, count: count)
        }
    }
}

private actor SteeringSecretStore: SecretStore {
    private var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class SteeringURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class SteeringRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(path: String, method: String, headers: [String: String], body: [String: Any])] = []

    var count: Int { lock.withLock { storage.count } }
    var paths: [String] { lock.withLock { storage.map(\.path) } }
    var methods: [String] { lock.withLock { storage.map(\.method) } }
    var headers: [[String: String]] { lock.withLock { storage.map(\.headers) } }
    var bodies: [[String: Any]] { lock.withLock { storage.map(\.body) } }

    func record(request: URLRequest, body: Data) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let headers = request.allHTTPHeaderFields ?? [:]
        lock.withLock {
            storage.append((
                request.url?.path ?? "",
                request.httpMethod ?? "",
                headers,
                object
            ))
        }
    }
}

private final class SteeringMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var recordedPaths: [String] = []

    var count: Int { lock.withLock { recordedPaths.count } }
    var paths: [String] { lock.withLock { recordedPaths } }

    func record(_ path: String) -> Int {
        lock.withLock {
            recordedPaths.append(path)
            return recordedPaths.count
        }
    }

    func waitUntilReleased() { release.wait() }
    func releaseFirst() { release.signal() }
}

private final class SkillActivationWireState: @unchecked Sendable {
    private let lock = NSLock()
    private let commitOnPost: Bool
    private var committed = false
    private var methodsAndPaths: [(String, String)] = []

    init(commitOnPost: Bool) {
        self.commitOnPost = commitOnPost
    }

    var didCommit: Bool { lock.withLock { committed } }
    var postCount: Int {
        lock.withLock {
            methodsAndPaths.filter {
                $0 == ("POST", "/api/user/settings/skills/active")
            }.count
        }
    }
    var activeStateReadCount: Int {
        lock.withLock {
            methodsAndPaths.filter {
                $0 == ("GET", "/api/user/settings/skills/active")
            }.count
        }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            methodsAndPaths.append((request.httpMethod ?? "", request.url?.path ?? ""))
        }
    }

    func commitIfConfigured() {
        lock.withLock {
            if commitOnPost { committed = true }
        }
    }
}
