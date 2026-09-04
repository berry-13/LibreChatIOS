import Foundation
import LibreChatDomain
import LibreChatProtocol
import Testing
@testable import LibreChat

struct GeneratedFilePresentationTests {
    @Test func previewPolicyNeverExecutesServerHTML() {
        let html = generatedFile(
            text: "<script>alert(1)</script>",
            textFormat: "html",
            lifecycle: .ready
        )
        let plain = generatedFile(
            text: "Quarterly result",
            textFormat: nil,
            lifecycle: .ready
        )

        #expect(GeneratedFileNativePreviewPolicy(file: html).supportsPreview == false)
        #expect(GeneratedFileNativePreviewPolicy(file: plain) == .plainText)
    }

    @Test func presentationUsesSemanticLifecycleLabels() {
        #expect(GeneratedFilePresentation(file: generatedFile(lifecycle: .pending)).statusLabel == "Preparing")
        #expect(GeneratedFilePresentation(file: generatedFile(lifecycle: .ready)).statusLabel == "Ready")
        #expect(GeneratedFilePresentation(file: generatedFile(lifecycle: .failed)).statusLabel == "Preview failed")
        #expect(GeneratedFilePresentation(file: generatedFile(lifecycle: .legacy)).statusLabel == "Available")
    }

    @Test func sheetSelectionKeepsExactToolAndAgentScopedIdentity() {
        let file = GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            provenance: GeneratedFileProvenance(
                toolCallID: "tool-1",
                agentID: "agent-1"
            )
        )
        let selection = GeneratedFileSheetSelection(file: file)

        #expect(selection.id.resourceID == "file-1")
        #expect(selection.id.toolCallID == "tool-1")
        #expect(selection.id.agentID == "agent-1")
    }

    @Test func unknownPreviewFormatFailsClosed() {
        let file = generatedFile(
            text: "opaque",
            textFormat: "provider-specific-html-ish",
            lifecycle: .ready
        )

        #expect(GeneratedFileNativePreviewPolicy(file: file).supportsPreview == false)
    }

    @Test func previewFailurePresentationNeverDisplaysArbitraryServerText() {
        #expect(GeneratedFilePreviewFailurePresentation(code: "timeout").message.contains("timed out"))
        #expect(GeneratedFilePreviewFailurePresentation(code: "parser-error").message.contains("could not read"))
        #expect(GeneratedFilePreviewFailurePresentation(code: "orphaned").message.contains("did not finish"))
        let unknown = GeneratedFilePreviewFailurePresentation(
            code: "<script>private provider detail</script>"
        ).message
        #expect(!unknown.contains("private provider detail"))
        #expect(unknown.contains("could not prepare"))
    }

    @Test func pollingFailureClassificationIsFiniteAndFailClosed() {
        #expect(GeneratedFilePreviewPollingFailureDisposition.classify(
            LibreChatProtocolError.transport("offline")
        ) == .retry)
        #expect(GeneratedFilePreviewPollingFailureDisposition.classify(
            LibreChatProtocolError.httpStatus(503, message: nil, retryAfter: nil)
        ) == .retry)
        #expect(GeneratedFilePreviewPollingFailureDisposition.classify(
            LibreChatProtocolError.unauthorized
        ) == .unauthorized)
        #expect(GeneratedFilePreviewPollingFailureDisposition.classify(
            LibreChatProtocolError.httpStatus(403, message: "private", retryAfter: nil)
        ) == .stop)
        #expect(GeneratedFilePreviewPollingFailureDisposition.classify(
            LibreChatProtocolError.invalidResponse
        ) == .stop)
    }

    @Test func pollingCoordinatorStartsImmediatelyDeduplicatesAndStopsAtTerminal() async {
        let pendingFirst = generatedFile(lifecycle: .pending)
        let pendingSecond = GeneratedFile(
            fileID: "file-1",
            filename: "same-file-second-slot.txt",
            lifecycle: .pending,
            provenance: .init(toolCallID: "tool-2", agentID: "agent-2")
        )
        let ready = generatedFile(text: "done", textFormat: "text", lifecycle: .ready)
        let repository = GeneratedFilePollingRepositoryDouble(results: [.success(ready)])
        let collector = GeneratedFilePollingCollector()
        let coordinator = GeneratedFilePreviewPollingCoordinator(
            repository: repository,
            configuration: .init(interval: .seconds(60), maximumConsecutiveFailures: 5),
            onUpdate: { file in await collector.record(file) },
            onUnauthorized: { await collector.recordUnauthorized() }
        )

        await coordinator.synchronize(files: [pendingFirst, pendingSecond], isActive: true)
        await waitUntil {
            let refreshCount = await repository.refreshCount
            let updateCount = await collector.updateCount
            return refreshCount == 1 && updateCount == 1
        }

        #expect(await repository.refreshCount == 1)
        #expect(await collector.files.first?.lifecycle == .ready)
        #expect(await collector.unauthorizedCount == 0)
        await coordinator.stop()
    }

    @Test func pollingCoordinatorCapsTransientFailuresAndForegroundCanRetry() async {
        let pending = generatedFile(lifecycle: .pending)
        let ready = generatedFile(text: "done", textFormat: "text", lifecycle: .ready)
        let failures = Array(
            repeating: Result<GeneratedFile, LibreChatProtocolError>.failure(.transport("offline")),
            count: 5
        )
        let repository = GeneratedFilePollingRepositoryDouble(results: failures)
        let collector = GeneratedFilePollingCollector()
        let coordinator = GeneratedFilePreviewPollingCoordinator(
            repository: repository,
            configuration: .init(interval: .zero, maximumConsecutiveFailures: 5),
            sleep: { _ in await Task.yield() },
            onUpdate: { file in await collector.record(file) },
            onUnauthorized: { await collector.recordUnauthorized() }
        )

        await coordinator.synchronize(files: [pending], isActive: true)
        await waitUntil { await repository.refreshCount == 5 }
        await coordinator.synchronize(files: [pending], isActive: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(await repository.refreshCount == 5)

        await repository.append(.success(ready))
        await coordinator.synchronize(files: [pending], isActive: false)
        await coordinator.synchronize(files: [pending], isActive: true)
        await waitUntil {
            let refreshCount = await repository.refreshCount
            let updateCount = await collector.updateCount
            return refreshCount == 6 && updateCount == 1
        }
        #expect(await collector.files.last?.lifecycle == .ready)
        await coordinator.stop()
    }

    @Test func pollingCoordinatorRestartsWhenPendingFileOwnershipChanges() async {
        let firstOwner = GeneratedFile(
            fileID: "file-1",
            filename: "first.txt",
            lifecycle: .pending,
            provenance: .init(
                messageID: MessageID(rawValue: "message-1"),
                conversationID: ConversationID(rawValue: "conversation"),
                toolCallID: "tool-1"
            )
        )
        let secondOwner = GeneratedFile(
            fileID: "file-1",
            filename: "second.txt",
            lifecycle: .pending,
            provenance: .init(
                messageID: MessageID(rawValue: "message-2"),
                conversationID: ConversationID(rawValue: "conversation"),
                toolCallID: "tool-2"
            )
        )
        let stillPending = GeneratedFile(
            fileID: "file-1",
            filename: "first.txt",
            lifecycle: .pending,
            provenance: firstOwner.provenance
        )
        let ready = GeneratedFile(
            fileID: "file-1",
            filename: "second.txt",
            text: "ready",
            textFormat: "text",
            lifecycle: .ready,
            provenance: secondOwner.provenance
        )
        let repository = GeneratedFilePollingRepositoryDouble(
            results: [.success(stillPending), .success(ready)]
        )
        let collector = GeneratedFilePollingCollector()
        let coordinator = GeneratedFilePreviewPollingCoordinator(
            repository: repository,
            configuration: .init(interval: .seconds(60), maximumConsecutiveFailures: 5),
            onUpdate: { file in await collector.record(file) },
            onUnauthorized: { await collector.recordUnauthorized() }
        )

        await coordinator.synchronize(files: [firstOwner], isActive: true)
        await waitUntil { await repository.refreshCount == 1 }
        await coordinator.synchronize(files: [secondOwner], isActive: true)
        await waitUntil {
            let refreshCount = await repository.refreshCount
            let latest = await collector.files.last
            return refreshCount == 2 && latest?.lifecycle == .ready
        }

        #expect(await repository.refreshCount == 2)
        #expect(await collector.files.last?.provenance.messageID == secondOwner.provenance.messageID)
        await coordinator.stop()
    }

    @MainActor
    @Test func cachePurgeRemovesOnlyTheRequestedGeneratedFileNamespace() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: UUID().uuidString)
        let firstAccount = AccountID(rawValue: "first-account")
        let secondAccount = AccountID(rawValue: "second-account")
        let firstDirectory = try GeneratedFileCacheDirectory.directory(
            profileID: profileID,
            accountID: firstAccount,
            create: true
        )
        let secondDirectory = try GeneratedFileCacheDirectory.directory(
            profileID: profileID,
            accountID: secondAccount,
            create: true
        )
        try Data("first".utf8).write(to: firstDirectory.appending(path: "first.txt"))
        try Data("second".utf8).write(to: secondDirectory.appending(path: "second.txt"))

        try await dependencies.cache.purge(profileID: profileID, accountID: firstAccount)

        #expect(FileManager.default.fileExists(atPath: firstDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: secondDirectory.path))

        try await dependencies.cache.purge(profileID: profileID)

        #expect(FileManager.default.fileExists(atPath: secondDirectory.path) == false)
    }

    private func generatedFile(
        text: String? = nil,
        textFormat: String? = nil,
        lifecycle: GeneratedFileLifecycle
    ) -> GeneratedFile {
        GeneratedFile(
            fileID: "file-1",
            filename: "report.txt",
            mimeType: "text/plain",
            text: text,
            textFormat: textFormat,
            lifecycle: lifecycle
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        // Bare Task.yield()s can complete in milliseconds without the
        // coordinator's unstructured poll task ever being scheduled, so give
        // the cooperative pool real time between checks.
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The generated-file polling condition did not become true.")
    }
}

private actor GeneratedFilePollingRepositoryDouble: GeneratedFileRepository {
    private var results: [Result<GeneratedFile, LibreChatProtocolError>]
    private(set) var refreshCount = 0

    init(results: [Result<GeneratedFile, LibreChatProtocolError>]) {
        self.results = results
    }

    func append(_ result: Result<GeneratedFile, LibreChatProtocolError>) {
        results.append(result)
    }

    func refreshGeneratedFile(_ file: GeneratedFile) async throws -> GeneratedFile {
        refreshCount += 1
        guard !results.isEmpty else { return file }
        return try results.removeFirst().get()
    }

    func downloadGeneratedFile(_ file: GeneratedFile) async throws -> DownloadedGeneratedFile {
        throw GeneratedFileError.unavailable
    }
}

private actor GeneratedFilePollingCollector {
    private(set) var files: [GeneratedFile] = []
    private(set) var unauthorizedCount = 0

    var updateCount: Int { files.count }

    func record(_ file: GeneratedFile) { files.append(file) }
    func recordUnauthorized() { unauthorizedCount += 1 }
}
