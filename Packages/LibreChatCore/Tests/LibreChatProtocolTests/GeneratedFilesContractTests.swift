import Foundation
import Testing
import LibreChatDomain
import LibreChatTestSupport
@testable import LibreChatProtocol

struct GeneratedFilesContractTests {
    @Test func historyAttachmentsMapToGeneratedFilesAndPreserveURLAliasAndProvenance() throws {
        let data = Data(
            """
            {
              "messageId":"message-1","conversationId":"conversation-1","sender":"Assistant",
              "attachments":[{
                "file_id":"file-1","filename":"report.html","type":"text/html",
                "url":"/api/files/code/download/session-1/file-1","toolCallId":"tool-1",
                "agentId":"agent-1","status":"ready","text":"<h1>Report</h1>","textFormat":"html",
                "future":{"keep":true}
              }]
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(LibreChatMessageDTO.self, from: data).domainModel()
        guard case let .generatedFile(file)? = message.content.first(where: {
            if case .generatedFile = $0 { return true }
            return false
        }) else {
            Issue.record("Expected a generated file attachment.")
            return
        }
        #expect(file.fileID == "file-1")
        #expect(file.filepath == "/api/files/code/download/session-1/file-1")
        #expect(file.urlAlias == "/api/files/code/download/session-1/file-1")
        #expect(file.identity == GeneratedFileIdentity(resourceID: "file-1", toolCallID: "tool-1", agentID: "agent-1"))
        #expect(file.lifecycle == .ready)
        #expect(file.textFormat == "html")
        #expect(file.provenance.messageID == MessageID(rawValue: "message-1"))
        #expect(file.provenance.conversationID == ConversationID(rawValue: "conversation-1"))
        #expect(file.provenance.sessionID == "session-1")
    }

    @Test func standardAndResponsesSSEAttachmentsReachOneLifecycleUpsertReducer() throws {
        let standard = ServerSentEvent(
            event: "attachment",
            data: """
            {"file_id":"file-1","filename":"budget.xlsx","type":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","filepath":"/api/files/code/download/session-1/file-1","toolCallId":"tool-1","agentId":"agent-1","status":"pending","text":null,"textFormat":null}
            """
        )
        let responses = ServerSentEvent(
            data: """
            {"type":"librechat:attachment","message_id":"message-1","conversation_id":"conversation-1","attachment":{"file_id":"file-1","filename":"budget.xlsx","type":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet","url":"/api/files/code/download/session-1/file-1","tool_call_id":"tool-1","agent_id":"agent-1","status":"ready","text":"<table><tr><td>42</td></tr></table>","textFormat":"html"}}
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

        let generatedFiles = reducer.snapshot.response?.content.compactMap { content -> GeneratedFile? in
            guard case let .generatedFile(file) = content else { return nil }
            return file
        } ?? []
        let generated = try #require(generatedFiles.count == 1 ? generatedFiles.first : nil)
        #expect(generated.lifecycle == .ready)
        #expect(generated.textFormat == "html")
        #expect(generated.text?.contains("42") == true)
        #expect(generated.provenance.messageID == MessageID(rawValue: "message-1"))
    }

    @Test func reducerKeepsDistinctNonNullToolOrAgentSlotsAndMergesAliasPromotion() {
        let path = "/api/files/code/download/session-1/file-1"
        let pending = GeneratedFile(
            filepath: path,
            filename: "report.html",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )
        let ready = GeneratedFile(
            fileID: "file-1",
            filepath: path,
            filename: "report.html",
            text: "<main>done</main>",
            textFormat: "html",
            lifecycle: .ready,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )
        let differentTool = GeneratedFile(
            fileID: "file-1",
            filename: "report.html",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-2", agentID: "agent-1")
        )
        let differentAgent = GeneratedFile(
            fileID: "file-1",
            filename: "report.html",
            previewError: "timeout",
            lifecycle: .failed,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-2")
        )
        var reducer = GeneratedFileReducer()
        _ = reducer.upsert(pending)
        _ = reducer.upsert(ready)
        _ = reducer.upsert(differentTool)
        _ = reducer.upsert(differentAgent)

        #expect(reducer.files.count == 3)
        #expect(reducer.files[0].fileID == "file-1")
        #expect(reducer.files[0].lifecycle == .ready)
        #expect(reducer.files[0].textFormat == "html")
        #expect(reducer.files[1].identity.toolCallID == "tool-2")
        #expect(reducer.files[2].identity.agentID == "agent-2")
    }

    @Test func previewFailureAndLegacyCacheDecodeRemainCompatible() throws {
        let legacy = Data(
            """
            {"fileID":"file-legacy","filepath":"/files/legacy.txt","filename":"legacy.txt","provenance":{"toolCallID":"tool-1"}}
            """.utf8
        )
        let file = try JSONDecoder().decode(GeneratedFile.self, from: legacy)
        #expect(file.lifecycle == .legacy)
        #expect(file.identity == GeneratedFileIdentity(resourceID: "file-legacy", toolCallID: "tool-1"))

        let preview = try JSONDecoder().decode(
            GeneratedFilePreviewDTO.self,
            from: Data(#"{"file_id":"file-legacy","status":"failed","previewError":"timeout"}"#.utf8)
        )
        let failed = try preview.applying(to: file)
        #expect(failed.lifecycle == .failed)
        #expect(failed.previewError == "timeout")
    }

    @Test func previewRequiresExactEchoedIdentityAndValidLifecycleShape() throws {
        let source = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )
        let valid = try JSONDecoder().decode(
            GeneratedFilePreviewDTO.self,
            from: Data(#"{"file_id":"file-1","status":"ready","text":"done","textFormat":"text"}"#.utf8)
        )
        let resolved = try valid.applying(to: source)
        #expect(resolved.identity == source.identity)
        #expect(resolved.lifecycle == .ready)

        let invalidPayloads = [
            #"{"status":"pending"}"#,
            #"{"file_id":"file-2","status":"pending"}"#,
            #"{"file_id":"file-1","status":"future"}"#,
            #"{"file_id":"file-1","status":"pending","text":"too early"}"#,
            #"{"file_id":"file-1","status":"ready","previewError":"timeout"}"#,
            #"{"file_id":"file-1","status":"failed","text":"unexpected"}"#
        ]
        for payload in invalidPayloads {
            let decoded = try JSONDecoder().decode(
                GeneratedFilePreviewDTO.self,
                from: Data(payload.utf8)
            )
            #expect(throws: LibreChatProtocolError.invalidResponse) {
                try decoded.applying(to: source)
            }
        }
    }

    @Test func terminalLifecycleCannotRegressAndPreviewTextIsBounded() throws {
        let oversized = String(repeating: "a", count: GeneratedFile.maximumPreviewCharacters + 25)
        let ready = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            text: oversized,
            textFormat: "text",
            lifecycle: .ready
        )
        #expect(ready.text?.count == GeneratedFile.maximumPreviewCharacters)
        #expect(ready.previewTruncated)

        let replay = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            lifecycle: .pending
        )
        var reducer = GeneratedFileReducer(files: [ready])
        _ = reducer.upsert(replay)
        #expect(reducer.files.first?.lifecycle == .ready)
        #expect(reducer.files.first?.text?.count == GeneratedFile.maximumPreviewCharacters)
        #expect(reducer.files.first?.previewTruncated == true)

        let pendingDTO = try JSONDecoder().decode(
            GeneratedFilePreviewDTO.self,
            from: Data(#"{"file_id":"file-1","status":"pending"}"#.utf8)
        )
        let protected = try pendingDTO.applying(to: ready)
        #expect(protected.lifecycle == .ready)
        #expect(protected.text == ready.text)
    }

    @Test func wildcardUpdatesMergeOneSlotButAmbiguousBareUpdatesFailClosed() {
        let barePending = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            lifecycle: .pending
        )
        let scopedReady = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            text: "done",
            lifecycle: .ready,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )
        var one = GeneratedFileReducer(files: [barePending])
        _ = one.upsert(scopedReady)
        #expect(one.files.count == 1)
        #expect(one.files.first?.identity.toolCallID == "tool-1")
        #expect(one.files.first?.identity.agentID == "agent-1")

        let first = GeneratedFile(
            fileID: "file-1",
            filename: "first.txt",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-1", agentID: "agent-1")
        )
        let second = GeneratedFile(
            fileID: "file-1",
            filename: "second.txt",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-2", agentID: "agent-2")
        )
        let bareReady = GeneratedFile(
            fileID: "file-1",
            filename: "Generated file",
            text: "resolved",
            lifecycle: .ready
        )
        var ambiguous = GeneratedFileReducer(files: [first, second])
        let unchanged = ambiguous.upsert(bareReady)
        #expect(unchanged == [first, second])

        // A legacy/bare card is not a tie-breaker for a bare SSE update. The
        // nil tool/agent coordinates could still describe either scoped card,
        // so routing must remain unchanged until authenticated preview poll.
        let legacyBare = GeneratedFile(
            fileID: "file-1",
            filename: "legacy.txt",
            lifecycle: .pending
        )
        var exactButStillAmbiguous = GeneratedFileReducer(files: [legacyBare, first])
        #expect(exactButStillAmbiguous.upsert(bareReady) == [legacyBare, first])

        let reconciled = ambiguous.applyPreview(bareReady)
        #expect(reconciled.count == 2)
        #expect(reconciled.allSatisfy { $0.lifecycle == .ready && $0.text == "resolved" })
        #expect(reconciled[0].identity == first.identity)
        #expect(reconciled[1].identity == second.identity)
        #expect(reconciled[0].filename == "first.txt")
        #expect(reconciled[1].filename == "second.txt")
    }

    @Test func requestFactoriesUseExactRoutesEncodedSegmentsAndNeverBlindRetry() throws {
        let preview = try LibreChatGeneratedFileAPI.preview(fileID: "file/a %")
        #expect(preview.method == .get)
        #expect(preview.path == "api/files/file/a %/preview")
        #expect(preview.pathComponents == ["api", "files", "file/a %", "preview"])
        #expect(preview.retryPolicy == .never)

        let signed = try LibreChatGeneratedFileAPI.downloadURL(userID: "user/a", fileID: "file/b")
        #expect(signed.method == .get)
        #expect(signed.path == "api/files/download-url/user/a/file/b")
        #expect(signed.pathComponents == ["api", "files", "download-url", "user/a", "file/b"])
        #expect(signed.retryPolicy == .never)

        let download = try LibreChatGeneratedFileAPI.download(userID: "user-1", fileID: "file-1")
        #expect(download.path == "api/files/download/user-1/file-1")
        #expect(download.pathComponents == ["api", "files", "download", "user-1", "file-1"])
        #expect(download.headers == ["Accept": "application/octet-stream"])
        #expect(download.retryPolicy == .never)

        let code = try LibreChatGeneratedFileAPI.codeFallbackDownload(sessionID: "session-1", fileID: "file-1")
        #expect(code.path == "api/files/code/download/session-1/file-1")
        #expect(code.pathComponents == ["api", "files", "code", "download", "session-1", "file-1"])
        #expect(code.retryPolicy == .never)
    }
}
