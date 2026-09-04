import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class ConversationManagementRepositoryTests: XCTestCase {
    private let profileID = ServerProfileID(rawValue: "profile")
    private let accountID = AccountID(rawValue: "account")

    override func tearDown() {
        ConversationManagementURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testRenamePinAndArchiveUseExactRequestsAndApplyAuthoritativeResponsesToCache() async throws {
        let conversationID = ConversationID(rawValue: "conversation")
        let dependencies = try AppDependencies(inMemory: true)
        try await saveCachedConversation(conversationID, to: dependencies)

        ConversationManagementURLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let body = try Self.bodyObject(for: request)
            let arg = try XCTUnwrap(body["arg"] as? [String: Any])

            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/convos/update"):
                XCTAssertEqual(Set(arg.keys), Set(["conversationId", "title"]))
                XCTAssertEqual(arg["conversationId"] as? String, "conversation")
                XCTAssertEqual(arg["title"] as? String, "Renamed")
                return (
                    Self.response(for: request, status: 201),
                    Data(#"{"conversationId":"conversation","title":"Renamed","pinned":false,"isArchived":false,"tags":["server"]}"#.utf8)
                )
            case ("POST", "/api/convos/pin"):
                XCTAssertEqual(Set(arg.keys), Set(["conversationId", "pinned"]))
                XCTAssertEqual(arg["conversationId"] as? String, "conversation")
                XCTAssertEqual(arg["pinned"] as? Bool, true)
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Server pin title","pinned":true,"isArchived":false,"tags":["server","pinned"]}"#.utf8)
                )
            case ("POST", "/api/convos/archive"):
                XCTAssertEqual(Set(arg.keys), Set(["conversationId", "isArchived"]))
                XCTAssertEqual(arg["conversationId"] as? String, "conversation")
                XCTAssertEqual(arg["isArchived"] as? Bool, true)
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Archived by server","pinned":true,"isArchived":true}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }

        let repository = try await makeRepository(dependencies: dependencies)

        let renamed = try await repository.rename(id: conversationID, title: "Renamed")
        XCTAssertEqual(renamed.title, "Renamed")
        XCTAssertEqual(renamed.tags, ["server"])
        var cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Renamed"])
        XCTAssertEqual(cached.first?.pinned, false)
        XCTAssertEqual(cached.first?.tags, ["server"])

        let pinned = try await repository.pin(id: conversationID, pinned: true)
        XCTAssertEqual(pinned.title, "Server pin title")
        XCTAssertEqual(pinned.pinned, true)
        cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Server pin title"])
        XCTAssertEqual(cached.first?.pinned, true)
        XCTAssertEqual(cached.first?.tags, ["server", "pinned"])

        let archived = try await repository.archive(id: conversationID, isArchived: true)
        XCTAssertEqual(archived.title, "Archived by server")
        XCTAssertEqual(archived.isArchived, true)
        cached = try await cachedConversations(from: dependencies)
        XCTAssertTrue(cached.isEmpty)
    }

    func testAmbiguousRenameReconciliationMatchReturnsAuthoritativeConversationWithoutRetryingPost() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/convos/update"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Renamed","isArchived":false}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        let result = try await repository.rename(id: conversationID, title: "Renamed")

        XCTAssertEqual(result.title, "Renamed")
        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Renamed"])
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/convos/update"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
    }

    func testAmbiguousPinReconciliationMismatchPreservesAuthoritativeCacheAndThrowsOriginalError() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/convos/pin"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Still unpinned","pinned":false,"isArchived":false}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        do {
            _ = try await repository.pin(id: conversationID, pinned: true)
            XCTFail("Expected the original pin error")
        } catch let error as LibreChatProtocolError {
            guard case let .httpStatus(status, _, _) = error else {
                return XCTFail("Expected the original HTTP error, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Still unpinned"])
        XCTAssertEqual(cached.first?.pinned, false)
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/convos/pin"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
    }

    func testAmbiguousArchiveUnauthorizedReconciliationPropagatesUnauthorizedWithoutRetryingPost() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/convos/archive"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (Self.response(for: request, status: 401), Data(#"{"error":"session expired"}"#.utf8))
            case ("POST", "/api/auth/refresh"):
                return (Self.response(for: request, status: 401), Data(#"{"error":"session expired"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        do {
            _ = try await repository.archive(id: conversationID, isArchived: true)
            XCTFail("Expected unauthorized reconciliation")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Cached"])
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/convos/archive"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/auth/refresh"), 1)
    }

    func testAmbiguousCreateTagReconciliationReturnsAuthoritativeTagWithoutRetryingPost() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/tags"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/tags"):
                return (
                    Self.response(for: request, status: 200),
                    Self.tagListJSON(tags: ["Work"])
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.createConversationTag(.init(tag: "Work"))

        XCTAssertEqual(result.tag, "Work")
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/tags"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/tags"), 1)
    }

    func testAmbiguousDeleteTagReconciliationReturnsPriorRecordWithoutRetryingDelete() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/tags"):
                let list = requestCounter.count(method: "GET", path: "/api/tags") == 1
                    ? Self.tagListJSON(tags: ["Work"])
                    : Data("[]".utf8)
                return (Self.response(for: request, status: 200), list)
            case ("DELETE", "/api/tags/Work"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.deleteConversationTag(named: "Work")

        XCTAssertEqual(result.tag, "Work")
        XCTAssertEqual(requestCounter.count(method: "DELETE", path: "/api/tags/Work"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/tags"), 2)
    }

    func testAmbiguousReplaceTagsReconciliationUpdatesConversationCacheWithoutRetryingPut() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies, tags: ["Old"])
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/api/tags/convo/conversation"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Cached","tags":["Work","Reading"]}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        let result = try await repository.replaceConversationTags(
            conversationID: conversationID,
            tags: ["Work", "Work", "Reading"]
        )

        XCTAssertEqual(result, ["Work", "Reading"])
        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.first?.tags, ["Work", "Reading"])
        XCTAssertEqual(requestCounter.count(method: "PUT", path: "/api/tags/convo/conversation"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
    }

    func testAmbiguousCreateTagUnauthorizedReconciliationPropagatesWithoutRetryingPost() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/tags"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/tags"):
                return (Self.response(for: request, status: 401), Data(#"{"error":"session expired"}"#.utf8))
            case ("POST", "/api/auth/refresh"):
                return (Self.response(for: request, status: 401), Data(#"{"error":"session expired"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.createConversationTag(.init(tag: "Work"))
            XCTFail("Expected unauthorized reconciliation")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }

        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/tags"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/tags"), 1)
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/auth/refresh"), 1)
    }

    func testConversationPagingRequestsActiveConversations() async throws {
        ConversationManagementURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/convos")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query, [
                URLQueryItem(name: "limit", value: "12"),
                URLQueryItem(name: "isArchived", value: "false"),
                URLQueryItem(name: "sortBy", value: "updatedAt"),
                URLQueryItem(name: "sortDirection", value: "desc"),
                URLQueryItem(name: "cursor", value: "opaque-cursor")
            ])
            return (
                Self.response(for: request, status: 200),
                Data(#"{"conversations":[{"conversationId":"conversation","title":"Active","isArchived":false}],"nextCursor":null}"#.utf8)
            )
        }
        let repository = try await makeRepository()

        let page = try await repository.conversations(cursor: "opaque-cursor", limit: 12)

        XCTAssertEqual(page.conversations.map(\.id), [ConversationID(rawValue: "conversation")])
        XCTAssertEqual(page.conversations.first?.isArchived, false)
    }

    func testLocalDraftDeleteRemovesCacheWithoutNetworkRequest() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let draftID = ConversationID(localDraftID: UUID())
        try await saveCachedConversation(draftID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            XCTFail("Local draft deletion must not reach the network")
            return (Self.response(for: request, status: 500), Data())
        }
        let repository = try await makeRepository(dependencies: dependencies)

        try await repository.delete(id: draftID)

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertTrue(cached.isEmpty)
        XCTAssertEqual(requestCounter.count, 0)
    }

    func testInitialDelete404IsAuthoritativeAndRemovesCacheWithoutReconciliation() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/convos")
            return (Self.response(for: request, status: 404), Data(#"{"error":"missing"}"#.utf8))
        }
        let repository = try await makeRepository(dependencies: dependencies)

        try await repository.delete(id: conversationID)

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertTrue(cached.isEmpty)
        XCTAssertEqual(requestCounter.count(method: "DELETE", path: "/api/convos"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 0)
    }

    func testAmbiguousDelete404ReconciliationRemovesCacheWithoutRetryingDelete() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/convos"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"delete outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (Self.response(for: request, status: 404), Data(#"{"error":"missing"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        try await repository.delete(id: conversationID)

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertTrue(cached.isEmpty)
        XCTAssertEqual(requestCounter.count(method: "DELETE", path: "/api/convos"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
    }

    func testAmbiguousDeleteWithExistingConversationPreservesCacheAndSurfacesOriginalError() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/convos"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"delete outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Still exists"}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        do {
            try await repository.delete(id: conversationID)
            XCTFail("Expected the original delete error")
        } catch let error as LibreChatProtocolError {
            guard case let .httpStatus(status, _, _) = error else {
                return XCTFail("Expected the original HTTP error, got \(error)")
            }
            XCTAssertEqual(status, 500)
        }

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Cached"])
        XCTAssertEqual(requestCounter.count(method: "DELETE", path: "/api/convos"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
    }

    func testAmbiguousDeleteUnauthorizedReconciliationPropagatesUnauthorized() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let conversationID = ConversationID(rawValue: "conversation")
        try await saveCachedConversation(conversationID, to: dependencies)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/convos"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"delete outcome unknown"}"#.utf8))
            case ("GET", "/api/convos/conversation"):
                return (Self.response(for: request, status: 401), Data(#"{"error":"session expired"}"#.utf8))
            case ("POST", "/api/auth/refresh"):
                return (Self.response(for: request, status: 401), Data(#"{"error":"session expired"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)

        do {
            try await repository.delete(id: conversationID)
            XCTFail("Expected unauthorized reconciliation")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .unauthorized)
        }

        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(cached.map(\.title), ["Cached"])
        XCTAssertEqual(requestCounter.count(method: "DELETE", path: "/api/convos"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/convos/conversation"), 1)
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/auth/refresh"), 1)
    }

    func testArtifactEditUsesExactNonRetriableRouteAndRefreshesAuthoritativeMessage() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/messages/artifact/message"):
                let body = try Self.bodyObject(for: request)
                XCTAssertEqual(Set(body.keys), Set(["index", "original", "updated"]))
                XCTAssertEqual(body["index"] as? Int, 0)
                XCTAssertEqual(body["original"] as? String, "old\n")
                XCTAssertEqual(body["updated"] as? String, "new")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","content":[],"text":null}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Self.artifactMessageJSON(content: "new")
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let message = try await repository.updateArtifact(Self.artifactEdit(updated: "new"))

        let text = try XCTUnwrap(message.content.compactMap(\.textualValue).first)
        let artifact = try XCTUnwrap(ArtifactParser.parse(messageID: message.id, text: text).artifacts.first)
        XCTAssertEqual(artifact.sourceContent, "new\n")
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/messages/artifact/message"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation"), 1)
    }

    func testAmbiguousArtifactEditReconcilesAppliedContentWithoutRetryingPost() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/messages/artifact/message"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            case ("GET", "/api/messages/conversation"):
                return (Self.response(for: request, status: 200), Self.artifactMessageJSON(content: "new"))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let message = try await repository.updateArtifact(Self.artifactEdit(updated: "new"))

        XCTAssertEqual(message.id, MessageID(rawValue: "message"))
        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/messages/artifact/message"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation"), 1)
    }

    func testStaleArtifactEditPreservesServerContentAndReturnsTypedConflict() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/messages/artifact/message"):
                return (
                    Self.response(for: request, status: 400),
                    Data(#"{"error":"Original content not found in target artifact"}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (Self.response(for: request, status: 200), Self.artifactMessageJSON(content: "server change"))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.updateArtifact(Self.artifactEdit(updated: "my edit"))
            XCTFail("Expected a typed artifact conflict")
        } catch let error as ArtifactEditError {
            XCTAssertEqual(error, .changedOnServer)
        }

        XCTAssertEqual(requestCounter.count(method: "POST", path: "/api/messages/artifact/message"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation"), 1)
    }

    func testMessageEditsUseExactBodiesEncodedCoordinatesAndAuthoritativeHistory() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let requestCounter = ConversationManagementRequestCounter()
        let conversationID = ConversationID(rawValue: "conversation/a %")
        let primaryMessageID = MessageID(rawValue: "message/b %")
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            switch request.httpMethod {
            case "PUT":
                XCTAssertEqual(
                    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath },
                    "/api/messages/conversation%2Fa%20%25/message%2Fb%20%25"
                )
                let body = try Self.bodyObject(for: request)
                XCTAssertEqual(Set(body.keys), ["text"])
                XCTAssertEqual(body["text"] as? String, "Updated primary")
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"future":{"ignored":true},"version":9}"#.utf8)
                )
            case "GET":
                XCTAssertEqual(
                    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath },
                    "/api/messages/conversation%2Fa%20%25"
                )
                return (
                    Self.response(for: request, status: 200),
                    Self.messageHistoryJSON(
                        conversationID: conversationID.rawValue,
                        targetMessageID: primaryMessageID.rawValue,
                        primaryText: "Updated primary"
                    )
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)
        let coordinate = MessageTextCoordinate(
            conversationID: conversationID,
            messageID: primaryMessageID,
            location: .primaryText
        )

        let result = try await repository.saveMessageEdit(MessageEditRequest(
            profileID: profileID,
            accountID: accountID,
            coordinate: coordinate,
            text: "Updated primary"
        ))

        XCTAssertEqual(result.resolution, .confirmedAfterResponse)
        XCTAssertEqual(result.editedMessage?.id, primaryMessageID)
        XCTAssertEqual(result.authoritativeHistory.map(\.id), [
            primaryMessageID,
            MessageID(rawValue: "sibling")
        ])
        let cached = try await dependencies.cache.messages(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID
        )
        XCTAssertEqual(cached.map(\.id), result.authoritativeHistory.map(\.id))
        XCTAssertEqual(requestCounter.count(method: "PUT", path: "/api/messages/conversation/a %/message/b %"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation/a %"), 1)
    }

    func testIndexedMessageEditUsesServerArrayIndexAndReasoningCoordinate() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/api/messages/conversation/message"):
                let body = try Self.bodyObject(for: request)
                XCTAssertEqual(Set(body.keys), ["text", "index"])
                XCTAssertEqual(body["text"] as? String, "Updated reasoning")
                XCTAssertEqual(body["index"] as? Int, 1)
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"messageId":"message","newServerField":"ignored"}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Self.messageHistoryJSON(
                        conversationID: "conversation",
                        targetMessageID: "message",
                        primaryText: "Legacy",
                        indexedReasoning: "Updated reasoning"
                    )
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()
        let coordinate = MessageTextCoordinate(
            conversationID: ConversationID(rawValue: "conversation"),
            messageID: MessageID(rawValue: "message"),
            location: .contentPart(index: 1, kind: .reasoning)
        )

        let result = try await repository.saveMessageEdit(MessageEditRequest(
            profileID: profileID,
            accountID: accountID,
            coordinate: coordinate,
            text: "Updated reasoning"
        ))

        XCTAssertEqual(result.resolution, .confirmedAfterResponse)
        XCTAssertEqual(
            result.editedMessage?.editableTextCatalog.first(where: { $0.location == coordinate.location })?.text,
            "Updated reasoning"
        )
        XCTAssertEqual(requestCounter.count(method: "PUT", path: "/api/messages/conversation/message"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation"), 1)
    }

    func testMessageEdit400403And404AreNotRetriedOrReconciled() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            guard request.httpMethod == "PUT" else {
                XCTFail("A definitive client response must not trigger history reconciliation")
                return (Self.response(for: request, status: 500), Data())
            }
            let status: Int
            if request.url?.path.hasSuffix("/bad-400") == true {
                status = 400
            } else if request.url?.path.hasSuffix("/bad-403") == true {
                status = 403
            } else {
                status = 404
            }
            return (
                Self.response(for: request, status: status),
                Data("{\"error\":\"rejected\"}".utf8)
            )
        }
        let repository = try await makeRepository()

        for status in [400, 403, 404] {
            let request = messageEditRequest(messageID: "bad-\(status)", text: "Updated")
            do {
                _ = try await repository.saveMessageEdit(request)
                XCTFail("Expected HTTP \(status)")
            } catch let LibreChatProtocolError.httpStatus(actual, _, _) {
                XCTAssertEqual(actual, status)
            }
        }

        XCTAssertEqual(requestCounter.count, 3)
    }

    func testAmbiguousMessageEdit5xxMatchReturnsReconciledHistoryWithoutRepeatingPut() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/api/messages/conversation/message"):
                return (
                    Self.response(for: request, status: 500),
                    Data(#"{"error":"outcome unknown"}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Self.messageHistoryJSON(
                        conversationID: "conversation",
                        targetMessageID: "message",
                        primaryText: "Updated"
                    )
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.saveMessageEdit(messageEditRequest(text: "Updated"))

        XCTAssertEqual(result.resolution, .reconciledAfterAmbiguousFailure)
        XCTAssertEqual(result.authoritativeHistory.count, 2)
        XCTAssertEqual(requestCounter.count(method: "PUT", path: "/api/messages/conversation/message"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation"), 1)
    }

    func testAmbiguousMessageEditTransportMismatchReturnsRecoverableCoordinatesAndPreservesSiblings() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("PUT", "/api/messages/conversation/message"):
                throw URLError(.networkConnectionLost)
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Self.messageHistoryJSON(
                        conversationID: "conversation",
                        targetMessageID: "message",
                        primaryText: "Server value"
                    )
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository(dependencies: dependencies)
        let edit = messageEditRequest(text: "My value")

        do {
            _ = try await repository.saveMessageEdit(edit)
            XCTFail("Expected recoverable ambiguity")
        } catch let MessageEditError.ambiguous(ambiguity) {
            XCTAssertEqual(ambiguity.coordinate, edit.coordinate)
            XCTAssertEqual(ambiguity.submittedText, "My value")
            XCTAssertEqual(ambiguity.authoritativeText, "Server value")
            XCTAssertEqual(ambiguity.reason, .authoritativeMismatch)
        }

        let cached = try await dependencies.cache.messages(
            profileID: profileID,
            accountID: accountID,
            conversationID: edit.coordinate.conversationID
        )
        XCTAssertEqual(cached.map(\.id), [MessageID(rawValue: "message"), MessageID(rawValue: "sibling")])
        XCTAssertEqual(requestCounter.count(method: "PUT", path: "/api/messages/conversation/message"), 1)
        XCTAssertEqual(requestCounter.count(method: "GET", path: "/api/messages/conversation"), 1)
    }

    func testInvalidLocalBlankOversizedAndCrossSessionMessageEditsNeverReachNetwork() async throws {
        let requestCounter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            requestCounter.record(request)
            XCTFail("Rejected edits must not reach the network")
            return (Self.response(for: request, status: 500), Data())
        }
        let repository = try await makeRepository()
        let valid = messageEditRequest(text: "Updated")
        let requests: [(MessageEditRequest, MessageEditError)] = [
            (MessageEditRequest(
                profileID: ServerProfileID(rawValue: "other-profile"),
                accountID: accountID,
                coordinate: valid.coordinate,
                text: valid.text
            ), .profileMismatch),
            (MessageEditRequest(
                profileID: profileID,
                accountID: AccountID(rawValue: "other-account"),
                coordinate: valid.coordinate,
                text: valid.text
            ), .accountMismatch),
            (messageEditRequest(conversationID: ConversationID(localDraftID: UUID()), text: "Updated"), .localIdentifier),
            (messageEditRequest(messageID: "local-user-1", text: "Updated"), .localIdentifier),
            (messageEditRequest(messageID: "new", text: "Updated"), .localIdentifier),
            (messageEditRequest(messageID: "   ", text: "Updated"), .blankIdentifier),
            (messageEditRequest(text: " \n\t "), .blankText),
            (messageEditRequest(
                text: String(repeating: "a", count: MessageEditRequest.maximumTextUTF16Length + 1)
            ), .textTooLong(maximumUTF16Length: MessageEditRequest.maximumTextUTF16Length)),
            (messageEditRequest(location: .contentPart(index: -1, kind: .text), text: "Updated"), .negativeContentPartIndex)
        ]

        for (request, expected) in requests {
            do {
                _ = try await repository.saveMessageEdit(request)
                XCTFail("Expected \(expected)")
            } catch let error as MessageEditError {
                XCTAssertEqual(error, expected)
            }
        }
        XCTAssertEqual(requestCounter.count, 0)
    }

    func testGeneratedFilePreviewUsesExactRouteAndPreservesIdentity() async throws {
        ConversationManagementURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/files/file-1/preview")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"file_id":"file-1","status":"ready","text":"Prepared report","textFormat":"text"}"#.utf8)
            )
        }
        let repository = try await makeRepository()
        let original = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )

        let refreshed = try await repository.refreshGeneratedFile(original)

        XCTAssertEqual(refreshed.lifecycle, .ready)
        XCTAssertEqual(refreshed.text, "Prepared report")
        XCTAssertEqual(refreshed.textFormat, "text")
        XCTAssertEqual(refreshed.identity, original.identity)
    }

    func testGeneratedFilePreviewRejectsMismatchedEchoWithoutMutatingIdentity() async throws {
        ConversationManagementURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/files/file-1/preview")
            return (
                Self.response(for: request, status: 200),
                Data(#"{"file_id":"another-file","status":"ready","text":"wrong"}"#.utf8)
            )
        }
        let repository = try await makeRepository()
        let original = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )

        do {
            _ = try await repository.refreshGeneratedFile(original)
            XCTFail("Expected exact echoed file identity validation.")
        } catch let error as LibreChatProtocolError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testGeneratedFileDownloadUsesAuthenticatedAccountAndWritesNamespacedLocalCopy() async throws {
        ConversationManagementURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/files/download/account/file-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (Self.response(for: request, status: 200), Data("downloaded bytes".utf8))
        }
        let repository = try await makeRepository()
        let file = GeneratedFile(fileID: "file-1", filename: "../report.txt", lifecycle: .ready)

        let downloaded = try await repository.downloadGeneratedFile(file)
        defer { try? FileManager.default.removeItem(at: downloaded.localURL) }

        XCTAssertEqual(downloaded.profileID, profileID)
        XCTAssertEqual(downloaded.accountID, accountID)
        XCTAssertEqual(downloaded.sourceIdentity, file.identity)
        XCTAssertFalse(downloaded.filename.contains("/"))
        XCTAssertEqual(try Data(contentsOf: downloaded.localURL), Data("downloaded bytes".utf8))
        // Generated downloads share the DownloadedFiles cache policy with
        // owner-library downloads, namespaced by profile and account.
        let accountNamespace = Data(accountID.rawValue.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        XCTAssertTrue(downloaded.localURL.path.contains("DownloadedFiles/profile/\(accountNamespace)/"))
    }

    func testOwnerFileDeletionUsesExactBodyAndRequiresRawCatalogAbsence() async throws {
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/files"):
                let body = try Self.bodyObject(for: request)
                let files = try XCTUnwrap(body["files"] as? [[String: Any]])
                XCTAssertEqual(files.count, 1)
                XCTAssertEqual(Set(try XCTUnwrap(files.first).keys), Set([
                    "file_id", "filepath", "source", "embedded", "temp_file_id"
                ]))
                XCTAssertEqual(files.first?["file_id"] as? String, "file-1")
                XCTAssertEqual(files.first?["filepath"] as? String, "/private/file-1")
                XCTAssertEqual(files.first?["source"] as? String, "s3")
                XCTAssertEqual(files.first?["embedded"] as? Bool, true)
                XCTAssertEqual(files.first?["temp_file_id"] as? String, "temp-1")
                return (Self.response(for: request, status: 200), Data(#"{"message":"Files deleted successfully"}"#.utf8))
            case ("GET", "/api/files"):
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.deleteFile(ownerFileItem())

        XCTAssertEqual(result.disposition, .deleted)
        XCTAssertEqual(result.attempt, .accepted)
        XCTAssertTrue(result.snapshot.items.isEmpty)
        XCTAssertEqual(counter.count(method: "DELETE", path: "/api/files"), 1)
        XCTAssertEqual(counter.count(method: "GET", path: "/api/files"), 1)
    }

    func testOwnerFileDeletionNeverTrustsSuccessWhenRawCatalogStillCarriesIdentity() async throws {
        ConversationManagementURLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/files"):
                return (Self.response(for: request, status: 200), Data(#"{"message":"Files deleted successfully"}"#.utf8))
            case ("GET", "/api/files"):
                // Conflicting records are omitted from the renderable
                // snapshot, but their raw identity still proves retention.
                return (Self.response(for: request, status: 200), Data(#"[{"file_id":"file-1","filename":"First"},{"file_id":"file-1","filename":"Second"}]"#.utf8))
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.deleteFile(ownerFileItem())

        XCTAssertEqual(result.disposition, .retained)
        XCTAssertEqual(result.attempt, .accepted)
        XCTAssertTrue(result.snapshot.items.isEmpty)
        XCTAssertEqual(result.snapshot.omittedCount, 2)
    }

    func testAmbiguousOwnerFileDeletionReconcilesWithoutReposting() async throws {
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/files"):
                return (Self.response(for: request, status: 500), Data(#"{"message":"unknown"}"#.utf8))
            case ("GET", "/api/files"):
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        let result = try await repository.deleteFile(ownerFileItem())

        XCTAssertEqual(result.disposition, .deleted)
        XCTAssertEqual(result.attempt, .deliveryUncertain)
        XCTAssertEqual(counter.count(method: "DELETE", path: "/api/files"), 1)
        XCTAssertEqual(counter.count(method: "GET", path: "/api/files"), 1)
    }

    func testOwnerFileDeletionPermissionAndFailedVerificationRemainDistinct() async throws {
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (Self.response(for: request, status: 403), Data(#"{"message":"forbidden"}"#.utf8))
        }
        var repository = try await makeRepository()

        do {
            _ = try await repository.deleteFile(ownerFileItem())
            XCTFail("Expected permission denial")
        } catch let error as LibreChatProtocolError {
            guard case .httpStatus(403, _, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(counter.count(method: "GET", path: "/api/files"), 0)

        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("DELETE", "/api/files"):
                return (Self.response(for: request, status: 500), Data(#"{"message":"unknown"}"#.utf8))
            case ("GET", "/api/files"):
                return (Self.response(for: request, status: 503), Data(#"{"code":"SERVER_NOT_READY"}"#.utf8))
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        repository = try await makeRepository()
        do {
            _ = try await repository.deleteFile(ownerFileItem())
            XCTFail("Expected verification-required state")
        } catch let error as FileLibraryError {
            XCTAssertEqual(error, .deletionVerificationRequired)
        }
        XCTAssertEqual(counter.count(method: "DELETE", path: "/api/files"), 2)
        XCTAssertEqual(counter.count(method: "GET", path: "/api/files"), 2)
    }

    func testForkReadsAuthoritativeSourcePostsOnceAndCachesFreshNamespaceWithoutDeletingPartialPeers() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let sourceID = ConversationID(rawValue: "conversation")
        let unrelatedID = ConversationID(rawValue: "unrelated")
        try await saveCachedConversation(unrelatedID, to: dependencies)
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (Self.response(for: request, status: 200), Data(#"{"conversationId":"conversation","title":"Source"}"#.utf8))
            case ("GET", "/api/messages/conversation"):
                return (Self.response(for: request, status: 200), Data(#"[{"messageId":"source","conversationId":"conversation","parentMessageId":"00000000-0000-0000-0000-000000000000","isCreatedByUser":true,"text":"Hello"}]"#.utf8))
            case ("POST", "/api/convos/fork"):
                let body = try Self.bodyObject(for: request)
                XCTAssertEqual(Set(body.keys), Set(["conversationId", "messageId", "option", "splitAtTarget"]))
                XCTAssertEqual(body["conversationId"] as? String, "conversation")
                XCTAssertEqual(body["messageId"] as? String, "source")
                XCTAssertEqual(body["option"] as? String, "directPath")
                XCTAssertEqual(body["splitAtTarget"] as? Bool, false)
                return (Self.response(for: request, status: 201), Data(#"{"conversation":{"conversationId":"forked","title":"Source"},"messages":[{"messageId":"fresh","conversationId":"forked","parentMessageId":"00000000-0000-0000-0000-000000000000","isCreatedByUser":true,"text":"Hello"}]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }

        let repository = try await makeRepository(dependencies: dependencies)
        let result = try await repository.fork(.init(
            profileID: profileID,
            accountID: accountID,
            conversationID: sourceID,
            targetMessageID: MessageID(rawValue: "source")
        ))

        XCTAssertEqual(result.conversation.id, ConversationID(rawValue: "forked"))
        XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/fork"), 1)
        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(Set(cached.map(\.id)), Set([unrelatedID, result.conversation.id]))
        let cachedMessages = try await dependencies.cache.messages(
            profileID: profileID,
            accountID: accountID,
            conversationID: result.conversation.id
        )
        XCTAssertEqual(cachedMessages.map(\.id), [MessageID(rawValue: "fresh")])
    }

    func testForkPreflightFailureDoesNotDispatchMutationAndAmbiguousPostIsTyped() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (Self.response(for: request, status: 200), Data(#"{"conversationId":"conversation","title":"Source"}"#.utf8))
            case ("GET", "/api/messages/conversation"):
                return (Self.response(for: request, status: 200), Data(#"[{"messageId":"source","conversationId":"conversation","isCreatedByUser":true,"text":"Hello"}]"#.utf8))
            case ("POST", "/api/convos/fork"):
                return (Self.response(for: request, status: 500), Data(#"{"error":"outcome unknown"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }

        let repository = try await makeRepository(dependencies: dependencies)
        do {
            _ = try await repository.fork(.init(
                profileID: profileID,
                accountID: accountID,
                conversationID: ConversationID(rawValue: "conversation"),
                targetMessageID: MessageID(rawValue: "missing")
            ))
            XCTFail("Expected authoritative preflight failure")
        } catch let error as ConversationForkError {
            guard case .preflightValidation(.targetNotFound) = error else {
                return XCTFail("Unexpected preflight error: \(error)")
            }
        }
        XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/fork"), 0)

        do {
            _ = try await repository.fork(.init(
                profileID: profileID,
                accountID: accountID,
                conversationID: ConversationID(rawValue: "conversation"),
                targetMessageID: MessageID(rawValue: "source")
            ))
            XCTFail("Expected outcome-unknown failure")
        } catch let error as ConversationForkError {
            XCTAssertEqual(error, .ambiguous)
        }
        XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/fork"), 1)
    }

    func testDuplicateReadsAuthoritativeSourcePostsOnceAndCachesFreshConversationWithoutDeletingPeers() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let unrelatedID = ConversationID(rawValue: "unrelated")
        try await saveCachedConversation(unrelatedID, to: dependencies)
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Source","tags":["work"],"chatProjectId":"project-1"}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"[{"messageId":"source-user","conversationId":"conversation","parentMessageId":"00000000-0000-0000-0000-000000000000","isCreatedByUser":true,"text":"Hello"},{"messageId":"source-assistant","conversationId":"conversation","parentMessageId":"source-user","isCreatedByUser":false,"text":"Hi"}]"#.utf8)
                )
            case ("POST", "/api/convos/duplicate"):
                let body = try Self.bodyObject(for: request)
                XCTAssertEqual(Set(body.keys), Set(["conversationId"]))
                XCTAssertEqual(body["conversationId"] as? String, "conversation")
                return (
                    Self.response(for: request, status: 201),
                    Data(#"{"conversation":{"conversationId":"copy","title":"Source","tags":["work"],"chatProjectId":"project-1"},"messages":[{"messageId":"copy-user","conversationId":"copy","parentMessageId":"00000000-0000-0000-0000-000000000000","isCreatedByUser":true,"text":"Hello"},{"messageId":"copy-assistant","conversationId":"copy","parentMessageId":"copy-user","isCreatedByUser":false,"text":"Hi"}]}"#.utf8)
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return (Self.response(for: request, status: 500), Data())
            }
        }

        let repository = try await makeRepository(dependencies: dependencies)
        let result = try await repository.duplicate(.init(
            profileID: profileID,
            accountID: accountID,
            conversationID: ConversationID(rawValue: "conversation")
        ))

        XCTAssertEqual(result.conversation.id, ConversationID(rawValue: "copy"))
        XCTAssertEqual(result.conversation.tags, ["work"])
        XCTAssertEqual(result.conversation.projectID, ProjectID(rawValue: "project-1"))
        XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/duplicate"), 1)
        let cached = try await cachedConversations(from: dependencies)
        XCTAssertEqual(Set(cached.map(\.id)), Set([unrelatedID, result.conversation.id]))
        let cachedMessages = try await dependencies.cache.messages(
            profileID: profileID,
            accountID: accountID,
            conversationID: result.conversation.id
        )
        XCTAssertEqual(cachedMessages.map(\.id), [
            MessageID(rawValue: "copy-user"),
            MessageID(rawValue: "copy-assistant")
        ])
    }

    func testDuplicatePreflightRejectsEmptyHistoryWithoutPosting() async throws {
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Empty"}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (Self.response(for: request, status: 200), Data("[]".utf8))
            default:
                XCTFail("No mutation should be sent for empty history")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()

        do {
            _ = try await repository.duplicate(.init(
                profileID: profileID,
                accountID: accountID,
                conversationID: ConversationID(rawValue: "conversation")
            ))
            XCTFail("Expected an empty-history preflight rejection")
        } catch let error as ConversationDuplicationError {
            XCTAssertEqual(error, .preflightValidation(.emptyHistory))
        }
        XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/duplicate"), 0)
    }

    func testDuplicateRejectsForeignProfileAndAccountBeforeAnyNetworkRequest() async throws {
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            XCTFail("Cross-session duplication must fail before networking")
            return (Self.response(for: request, status: 500), Data())
        }
        let repository = try await makeRepository()
        let sourceID = ConversationID(rawValue: "conversation")

        do {
            _ = try await repository.duplicate(.init(
                profileID: ServerProfileID(rawValue: "other-profile"),
                accountID: accountID,
                conversationID: sourceID
            ))
            XCTFail("Expected profile mismatch")
        } catch let error as ConversationDuplicationError {
            XCTAssertEqual(error, .profileMismatch)
        }

        do {
            _ = try await repository.duplicate(.init(
                profileID: profileID,
                accountID: AccountID(rawValue: "other-account"),
                conversationID: sourceID
            ))
            XCTFail("Expected account mismatch")
        } catch let error as ConversationDuplicationError {
            XCTAssertEqual(error, .accountMismatch)
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testDuplicateTreats429AsDefiniteBut500AsAmbiguousAndNeverPostsTwice() async throws {
        for status in [429, 500] {
            let counter = ConversationManagementRequestCounter()
            ConversationManagementURLProtocolStub.handler = { request in
                counter.record(request)
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/convos/conversation"):
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"{"conversationId":"conversation","title":"Source"}"#.utf8)
                    )
                case ("GET", "/api/messages/conversation"):
                    return (
                        Self.response(for: request, status: 200),
                        Data(#"[{"messageId":"source","conversationId":"conversation","isCreatedByUser":true,"text":"Hello"}]"#.utf8)
                    )
                case ("POST", "/api/convos/duplicate"):
                    return (
                        Self.response(for: request, status: status),
                        Data(#"{"message":"not completed"}"#.utf8)
                    )
                default:
                    XCTFail("Unexpected request")
                    return (Self.response(for: request, status: 500), Data())
                }
            }
            let repository = try await makeRepository()
            do {
                _ = try await repository.duplicate(.init(
                    profileID: profileID,
                    accountID: accountID,
                    conversationID: ConversationID(rawValue: "conversation")
                ))
                XCTFail("Expected duplicate failure")
            } catch let error as ConversationDuplicationError {
                XCTAssertEqual(status, 500)
                XCTAssertEqual(error, .ambiguous)
            } catch let error as LibreChatProtocolError {
                guard case .httpStatus(429, _, _) = error else {
                    return XCTFail("Unexpected protocol error: \(error)")
                }
                XCTAssertEqual(status, 429)
            }
            XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/duplicate"), 1)
        }
    }

    func testMalformedDuplicateSuccessIsAmbiguousAndNeverReposted() async throws {
        let counter = ConversationManagementRequestCounter()
        ConversationManagementURLProtocolStub.handler = { request in
            counter.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/convos/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"{"conversationId":"conversation","title":"Source"}"#.utf8)
                )
            case ("GET", "/api/messages/conversation"):
                return (
                    Self.response(for: request, status: 200),
                    Data(#"[{"messageId":"source","conversationId":"conversation","isCreatedByUser":true,"text":"Hello"}]"#.utf8)
                )
            case ("POST", "/api/convos/duplicate"):
                return (
                    Self.response(for: request, status: 201),
                    Data(#"{"conversation":{"conversationId":"copy"},"messages":[{"messageId":"source","conversationId":"copy","isCreatedByUser":true}]}"#.utf8)
                )
            default:
                XCTFail("Unexpected request")
                return (Self.response(for: request, status: 500), Data())
            }
        }
        let repository = try await makeRepository()
        do {
            _ = try await repository.duplicate(.init(
                profileID: profileID,
                accountID: accountID,
                conversationID: ConversationID(rawValue: "conversation")
            ))
            XCTFail("Expected an ambiguous malformed acknowledgement")
        } catch let error as ConversationDuplicationError {
            XCTAssertEqual(error, .ambiguous)
        }
        XCTAssertEqual(counter.count(method: "POST", path: "/api/convos/duplicate"), 1)
    }

    private func makeRepository(dependencies: AppDependencies? = nil) async throws -> LibreChatRepository {
        let dependencies = try dependencies ?? AppDependencies(inMemory: true)
        let account = UserAccount(id: accountID)
        let baseURL = URL(string: "https://chat.example.com")!
        let profile = ServerProfile(
            id: profileID,
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id,
            capabilities: ServerCapabilities(generation: .resumable(version: 2))
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: ConversationManagementSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationManagementURLProtocolStub.self]
        configuration.httpShouldSetCookies = false
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let authentication = AuthSession.isolated(transport: transport)
        await authentication.setAuthenticated(AuthenticatedSession(accessToken: "token", user: account))
        let runtime = LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: authentication,
            restClient: RESTClient(transport: transport, authSession: authentication)
        )
        return LibreChatRepository(profile: profile, runtime: runtime, cache: dependencies.cache)
    }

    private func saveCachedConversation(
        _ id: ConversationID,
        to dependencies: AppDependencies,
        tags: [String]? = nil
    ) async throws {
        try await dependencies.cache.save(
            page: ConversationPage(conversations: [.init(id: id, title: "Cached", tags: tags)]),
            profileID: profileID,
            accountID: accountID,
            completeSynchronization: false
        )
    }

    private func cachedConversations(from dependencies: AppDependencies) async throws -> [Conversation] {
        try await dependencies.cache.conversations(
            profileID: profileID,
            accountID: accountID,
            limit: 25
        )?.conversations ?? []
    }

    nonisolated private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func tagRecordJSON(tag: String) -> Data {
        Data(
            """
            {"_id":"tag-1","user":"account","tag":"\(tag)","description":null,
            "createdAt":"2026-08-18T10:00:00Z","updatedAt":"2026-08-18T11:00:00Z",
            "count":0,"position":1}
            """.replacingOccurrences(of: "\n", with: "").utf8
        )
    }

    nonisolated private static func tagListJSON(tags: [String]) -> Data {
        let records = tags.map {
            String(decoding: tagRecordJSON(tag: $0), as: UTF8.self)
        }.joined(separator: ",")
        return Data("[\(records)]".utf8)
    }

    nonisolated private static func artifactEdit(updated: String) -> ArtifactEditRequest {
        ArtifactEditRequest(
            identity: ArtifactIdentity(
                messageID: MessageID(rawValue: "message"),
                documentOrderIndex: 0
            ),
            conversationID: ConversationID(rawValue: "conversation"),
            originalContent: "old\n",
            updatedContent: updated
        )
    }

    nonisolated private static func artifactMessageJSON(content: String) -> Data {
        let artifactText = """
        :::artifact{identifier="notes" type="text/plain" title="Notes"}
        \(content)
        :::
        """
        return try! JSONSerialization.data(withJSONObject: [[
            "messageId": "message",
            "conversationId": "conversation",
            "sender": "Assistant",
            "isCreatedByUser": false,
            "content": [["type": "text", "text": artifactText]]
        ]])
    }

    private func messageEditRequest(
        conversationID: ConversationID = ConversationID(rawValue: "conversation"),
        messageID: String = "message",
        location: MessageTextLocation = .primaryText,
        text: String
    ) -> MessageEditRequest {
        MessageEditRequest(
            profileID: profileID,
            accountID: accountID,
            coordinate: MessageTextCoordinate(
                conversationID: conversationID,
                messageID: MessageID(rawValue: messageID),
                location: location
            ),
            text: text
        )
    }

    private func ownerFileItem() -> FileLibraryItem {
        FileLibraryItem(file: UploadedFile(
            id: "file-1",
            temporaryID: "temp-1",
            filename: "Report.pdf",
            filepath: "/private/file-1",
            source: "s3",
            embedded: true
        ))
    }

    nonisolated private static func messageHistoryJSON(
        conversationID: String,
        targetMessageID: String,
        primaryText: String,
        indexedReasoning: String? = nil
    ) -> Data {
        var target: [String: Any] = [
            "messageId": targetMessageID,
            "conversationId": conversationID,
            "parentMessageId": "00000000-0000-0000-0000-000000000000",
            "sender": "User",
            "isCreatedByUser": true,
            "text": primaryText,
            "future": ["ignored": true]
        ]
        if let indexedReasoning {
            target["content"] = [
                ["type": "future_part", "value": "unknown"],
                ["type": "think", "think": indexedReasoning, "future": 1]
            ]
        }
        let sibling: [String: Any] = [
            "messageId": "sibling",
            "conversationId": conversationID,
            "parentMessageId": "00000000-0000-0000-0000-000000000000",
            "sender": "Assistant",
            "isCreatedByUser": false,
            "text": "Sibling remains"
        ]
        return try! JSONSerialization.data(withJSONObject: [target, sibling])
    }

    nonisolated private static func bodyObject(for request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            data = try read(XCTUnwrap(request.httpBodyStream))
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    nonisolated private static func read(_ stream: InputStream) throws -> Data {
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private actor ConversationManagementSecretStore: SecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class ConversationManagementRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(method: String?, path: String?)] = []

    func record(_ request: URLRequest) {
        lock.withLock {
            requests.append((request.httpMethod, request.url?.path))
        }
    }

    var count: Int {
        lock.withLock { requests.count }
    }

    func count(method: String, path: String) -> Int {
        lock.withLock {
            requests.count { $0.method == method && $0.path == path }
        }
    }
}

private final class ConversationManagementURLProtocolStub: URLProtocol {
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
