import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class FileLibraryModelTests: XCTestCase {
    func testLoadedCatalogSearchesAndSortsWithoutExposingUnknownStorageSource() async throws {
        let older = FileLibraryItem(
            file: UploadedFile(
                id: "older",
                filename: "Alpha.pdf",
                mimeType: "application/pdf",
                bytes: 1_024,
                context: "message_attachment",
                source: "private-future-backend"
            ),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = FileLibraryItem(
            file: UploadedFile(
                id: "newer",
                filename: "Beta.png",
                mimeType: "image/png",
                bytes: 2_048,
                context: "image_generation",
                source: "s3"
            ),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let repository = FileLibraryRepositoryDouble(results: [
            .success(FileLibrarySnapshot(items: [older, newer], fetchedAt: Date()))
        ])
        let model = FileLibraryModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.visibleItems.map(\.id), ["newer", "older"])

        model.query = "pdf"
        XCTAssertEqual(model.visibleItems.map(\.id), ["older"])
        model.query = ""
        model.sort = .name
        XCTAssertEqual(model.visibleItems.map(\.id), ["older", "newer"])
        model.sort = .size
        XCTAssertEqual(model.visibleItems.map(\.id), ["newer", "older"])
        XCTAssertEqual(
            FileLibraryPresentation.sourceLabel(for: older),
            "Server-managed storage"
        )
        XCTAssertFalse(
            FileLibraryPresentation.sourceLabel(for: older).contains("private-future-backend")
        )
    }

    func testTransientRefreshKeepsOnlyTheInMemoryLiveSnapshot() async throws {
        let item = FileLibraryItem(
            file: UploadedFile(id: "file", filename: "One.txt", mimeType: "text/plain")
        )
        let repository = FileLibraryRepositoryDouble(results: [
            .success(FileLibrarySnapshot(items: [item], fetchedAt: Date())),
            .failure(LibreChatProtocolError.transport("offline"))
        ])
        let model = FileLibraryModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded()
        await model.reload()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.snapshot?.items, [item])
        XCTAssertNotNil(model.refreshError)
        let requestCount = await repository.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testOfflineNeverRequestsAndUnauthorizedClearsCatalogAndExpiresSession() async throws {
        let offlineRepository = FileLibraryRepositoryDouble(results: [])
        let offlineModel = FileLibraryModel(
            repository: offlineRepository,
            isOffline: { true },
            onUnauthorized: {}
        )
        await offlineModel.loadIfNeeded()
        XCTAssertEqual(offlineModel.state, .offline)
        let offlineRequestCount = await offlineRepository.requestCount()
        XCTAssertEqual(offlineRequestCount, 0)

        var expired = false
        let unauthorizedRepository = FileLibraryRepositoryDouble(results: [
            .failure(LibreChatProtocolError.unauthorized)
        ])
        let unauthorizedModel = FileLibraryModel(
            repository: unauthorizedRepository,
            isOffline: { false },
            onUnauthorized: { expired = true }
        )
        await unauthorizedModel.loadIfNeeded()
        XCTAssertEqual(unauthorizedModel.state, .unauthorized)
        XCTAssertNil(unauthorizedModel.snapshot)
        XCTAssertTrue(expired)
    }

    func testForbiddenAndMissingCatalogHaveDistinctFailClosedStates() async {
        let forbidden = FileLibraryModel(
            repository: FileLibraryRepositoryDouble(results: [
                .failure(LibreChatProtocolError.httpStatus(403, message: nil, retryAfter: nil))
            ]),
            isOffline: { false },
            onUnauthorized: {}
        )
        await forbidden.loadIfNeeded()
        XCTAssertEqual(forbidden.state, .forbidden)

        let unavailable = FileLibraryModel(
            repository: FileLibraryRepositoryDouble(results: [
                .failure(LibreChatProtocolError.httpStatus(404, message: nil, retryAfter: nil))
            ]),
            isOffline: { false },
            onUnauthorized: {}
        )
        await unavailable.loadIfNeeded()
        XCTAssertEqual(unavailable.state, .unavailable)
    }

    func testPreviewProcessingCanRefreshIntoInertBoundedText() async throws {
        let repository = FileLibraryRepositoryDouble(
            results: [],
            previewResults: [
                .success(FilePreviewSnapshot(fileID: "file", lifecycle: .processing)),
                .success(FilePreviewSnapshot(
                    fileID: "file",
                    lifecycle: .ready,
                    text: "<script>inert</script>",
                    format: .htmlSource,
                    isTruncated: true
                ))
            ]
        )
        let model = FilePreviewModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.loadIfNeeded(fileID: "file")
        XCTAssertEqual(model.state, .processing)

        await model.reload(fileID: "file")
        XCTAssertEqual(
            model.state,
            .ready(FilePreviewSnapshot(
                fileID: "file",
                lifecycle: .ready,
                text: "<script>inert</script>",
                format: .htmlSource,
                isTruncated: true
            ))
        )
        let previewRequestCount = await repository.previewRequestCount()
        XCTAssertEqual(previewRequestCount, 2)
    }

    func testPreviewOfflineAndUnauthorizedNeverRetainText() async {
        let offlineRepository = FileLibraryRepositoryDouble(results: [])
        let offline = FilePreviewModel(
            repository: offlineRepository,
            isOffline: { true },
            onUnauthorized: {}
        )
        await offline.loadIfNeeded(fileID: "file")
        XCTAssertEqual(offline.state, .offline)
        let offlineRequests = await offlineRepository.previewRequestCount()
        XCTAssertEqual(offlineRequests, 0)

        var expired = false
        let unauthorizedRepository = FileLibraryRepositoryDouble(
            results: [],
            previewResults: [.failure(.unauthorized)]
        )
        let unauthorized = FilePreviewModel(
            repository: unauthorizedRepository,
            isOffline: { false },
            onUnauthorized: { expired = true }
        )
        await unauthorized.loadIfNeeded(fileID: "file")
        XCTAssertEqual(unauthorized.state, .unauthorized)
        XCTAssertTrue(expired)
    }

    func testPreviewPermissionMissingAndUnsupportedStatesStayDistinct() async {
        let cases: [(LibreChatProtocolError, FilePreviewModel.State)] = [
            (.httpStatus(403, message: nil, retryAfter: nil), .forbidden),
            (.httpStatus(404, message: nil, retryAfter: nil), .unavailable),
            (.httpStatus(405, message: nil, retryAfter: nil), .unsupported),
            (.httpStatus(501, message: nil, retryAfter: nil), .unsupported)
        ]

        for (error, expected) in cases {
            let model = FilePreviewModel(
                repository: FileLibraryRepositoryDouble(
                    results: [],
                    previewResults: [.failure(error)]
                ),
                isOffline: { false },
                onUnauthorized: {}
            )
            await model.loadIfNeeded(fileID: "file")
            XCTAssertEqual(model.state, expected)
        }
    }

    func testDownloadSucceedsOnlyForTheExactCatalogIdentity() async throws {
        let item = FileLibraryItem(
            file: UploadedFile(id: "file", filename: "Report.pdf", mimeType: "application/pdf")
        )
        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "file-library-model-\(UUID().uuidString).pdf")
        try Data("bytes".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let downloaded = DownloadedLibraryFile(
            profileID: .init(rawValue: "profile"),
            accountID: .init(rawValue: "account"),
            localURL: localURL,
            filename: "Report.pdf",
            mimeType: "application/pdf",
            bytes: 5
        )
        let repository = FileLibraryRepositoryDouble(
            results: [],
            downloadResults: [.success(downloaded)]
        )
        let model = FileDownloadModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        await model.download(item)

        XCTAssertEqual(model.state, .ready(downloaded))
        let count = await repository.downloadRequestCount()
        XCTAssertEqual(count, 1)

        model.discardLocalCopy()
        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testCancelledPresentationDiscardsALateCompletedLocalCopy() async throws {
        let item = FileLibraryItem(file: UploadedFile(id: "file", filename: "Report.pdf"))
        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "file-library-late-\(UUID().uuidString)")
        try Data("bytes".utf8).write(to: localURL)
        let downloaded = DownloadedLibraryFile(
            profileID: .init(rawValue: "profile"),
            accountID: .init(rawValue: "account"),
            localURL: localURL,
            filename: "Report.pdf",
            bytes: 5
        )
        let model = FileDownloadModel(
            repository: FileLibraryRepositoryDouble(
                results: [],
                downloadResults: [.success(downloaded)],
                downloadDelay: .milliseconds(30)
            ),
            isOffline: { false },
            onUnauthorized: {}
        )

        let download = Task { @MainActor in await model.download(item) }
        try await Task.sleep(for: .milliseconds(5))
        XCTAssertEqual(model.state, .downloading)
        model.cancel()
        await download.value

        XCTAssertEqual(model.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
    }

    func testOfflineDownloadNeverRequestsAndUnauthorizedExpiresSession() async {
        let item = FileLibraryItem(file: UploadedFile(id: "file", filename: "File.txt"))
        let offlineRepository = FileLibraryRepositoryDouble(results: [])
        let offlineModel = FileDownloadModel(
            repository: offlineRepository,
            isOffline: { true },
            onUnauthorized: {}
        )
        await offlineModel.download(item)
        XCTAssertEqual(offlineModel.state, .offline)
        let offlineCount = await offlineRepository.downloadRequestCount()
        XCTAssertEqual(offlineCount, 0)

        var expired = false
        let unauthorizedRepository = FileLibraryRepositoryDouble(
            results: [],
            downloadResults: [.failure(.unauthorized)]
        )
        let unauthorizedModel = FileDownloadModel(
            repository: unauthorizedRepository,
            isOffline: { false },
            onUnauthorized: { expired = true }
        )
        await unauthorizedModel.download(item)
        XCTAssertEqual(unauthorizedModel.state, .unauthorized)
        XCTAssertTrue(expired)
    }

    func testDownloadPermissionAndDeploymentFailuresStayDistinct() async {
        let item = FileLibraryItem(file: UploadedFile(id: "file", filename: "File.txt"))
        let cases: [(LibreChatProtocolError, FileDownloadModel.State)] = [
            (.httpStatus(403, message: nil, retryAfter: nil), .forbidden),
            (.httpStatus(404, message: nil, retryAfter: nil), .unavailable),
            (.httpStatus(405, message: nil, retryAfter: nil), .unavailable),
            (.httpStatus(501, message: nil, retryAfter: nil), .unavailable)
        ]

        for (error, expected) in cases {
            let model = FileDownloadModel(
                repository: FileLibraryRepositoryDouble(
                    results: [],
                    downloadResults: [.failure(error)]
                ),
                isOffline: { false },
                onUnauthorized: {}
            )
            await model.download(item)
            XCTAssertEqual(model.state, expected)
        }
    }

    func testDeletionReportsSuccessOnlyAfterRepositoryReturnsAuthoritativeAbsence() async {
        let item = deletableItem()
        let snapshot = FileLibrarySnapshot(items: [], fetchedAt: Date(timeIntervalSince1970: 42))
        let result = FileLibraryDeletionResult(
            disposition: .deleted,
            attempt: .accepted,
            snapshot: snapshot
        )
        let repository = FileLibraryRepositoryDouble(
            results: [],
            deletionResults: [.success(result)]
        )
        let model = FileDeletionModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )

        let received = await model.delete(item)

        XCTAssertEqual(received, result)
        XCTAssertEqual(model.state, .deleted)
        let count = await repository.deletionRequestCount()
        XCTAssertEqual(count, 1)
    }

    func testDeletionRetainsTheDetailWhenFreshCatalogStillContainsFile() async {
        let item = deletableItem()
        let result = FileLibraryDeletionResult(
            disposition: .retained,
            attempt: .accepted,
            snapshot: FileLibrarySnapshot(items: [item])
        )
        let model = FileDeletionModel(
            repository: FileLibraryRepositoryDouble(
                results: [],
                deletionResults: [.success(result)]
            ),
            isOffline: { false },
            onUnauthorized: {}
        )

        let received = await model.delete(item)

        XCTAssertNil(received)
        XCTAssertEqual(model.state, .retained(.accepted))
    }

    func testDeletionFailsBeforeNetworkForOfflineOrServerFilteredMetadata() async {
        let offlineRepository = FileLibraryRepositoryDouble(results: [])
        let offline = FileDeletionModel(
            repository: offlineRepository,
            isOffline: { true },
            onUnauthorized: {}
        )
        let offlineResult = await offline.delete(deletableItem())
        XCTAssertNil(offlineResult)
        XCTAssertEqual(offline.state, .offline)
        var count = await offlineRepository.deletionRequestCount()
        XCTAssertEqual(count, 0)

        let invalidRepository = FileLibraryRepositoryDouble(results: [])
        let invalid = FileDeletionModel(
            repository: invalidRepository,
            isOffline: { false },
            onUnauthorized: {}
        )
        let invalidItem = FileLibraryItem(file: UploadedFile(
            id: "future-identity",
            filename: "Unsafe.dat",
            filepath: "/private/unsafe"
        ))
        XCTAssertFalse(FileLibraryPresentation.canDelete(invalidItem))
        let invalidResult = await invalid.delete(invalidItem)
        XCTAssertNil(invalidResult)
        XCTAssertEqual(invalid.state, .unavailable)
        count = await invalidRepository.deletionRequestCount()
        XCTAssertEqual(count, 0)
    }

    func testDeletionSecurityAndAmbiguityStatesRemainFinite() async {
        let item = deletableItem()
        let cases: [(FileDeletionDoubleResult, FileDeletionModel.State)] = [
            (.protocolFailure(.httpStatus(403, message: nil, retryAfter: nil)), .forbidden),
            (.libraryFailure(.deletionVerificationRequired), .verificationRequired)
        ]

        for (result, expected) in cases {
            let model = FileDeletionModel(
                repository: FileLibraryRepositoryDouble(
                    results: [],
                    deletionResults: [result]
                ),
                isOffline: { false },
                onUnauthorized: {}
            )
            let received = await model.delete(item)
            XCTAssertNil(received)
            XCTAssertEqual(model.state, expected)
        }

        var expired = false
        let unauthorized = FileDeletionModel(
            repository: FileLibraryRepositoryDouble(
                results: [],
                deletionResults: [.protocolFailure(.unauthorized)]
            ),
            isOffline: { false },
            onUnauthorized: { expired = true }
        )
        let unauthorizedResult = await unauthorized.delete(item)
        XCTAssertNil(unauthorizedResult)
        XCTAssertEqual(unauthorized.state, .unauthorized)
        XCTAssertTrue(expired)
    }

    private func deletableItem() -> FileLibraryItem {
        FileLibraryItem(file: UploadedFile(
            id: "file-budget",
            filename: "Budget.pdf",
            filepath: "/private/budget.pdf",
            source: "s3",
            embedded: true
        ))
    }
}

private enum FileDeletionDoubleResult: Sendable {
    case success(FileLibraryDeletionResult)
    case protocolFailure(LibreChatProtocolError)
    case libraryFailure(FileLibraryError)

    func value() throws -> FileLibraryDeletionResult {
        switch self {
        case let .success(result): result
        case let .protocolFailure(error): throw error
        case let .libraryFailure(error): throw error
        }
    }
}

private actor FileLibraryRepositoryDouble: FileLibraryRepository {
    private var results: [Result<FileLibrarySnapshot, LibreChatProtocolError>]
    private var previewResults: [Result<FilePreviewSnapshot, LibreChatProtocolError>]
    private var downloadResults: [Result<DownloadedLibraryFile, LibreChatProtocolError>]
    private var deletionResults: [FileDeletionDoubleResult]
    private let downloadDelay: Duration?
    private var requests = 0
    private var previewRequests = 0
    private var downloadRequests = 0
    private var deletionRequests = 0

    init(
        results: [Result<FileLibrarySnapshot, LibreChatProtocolError>],
        previewResults: [Result<FilePreviewSnapshot, LibreChatProtocolError>] = [],
        downloadResults: [Result<DownloadedLibraryFile, LibreChatProtocolError>] = [],
        deletionResults: [FileDeletionDoubleResult] = [],
        downloadDelay: Duration? = nil
    ) {
        self.results = results
        self.previewResults = previewResults
        self.downloadResults = downloadResults
        self.deletionResults = deletionResults
        self.downloadDelay = downloadDelay
    }

    func fileLibrary() async throws -> FileLibrarySnapshot {
        requests += 1
        guard !results.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return try results.removeFirst().get()
    }

    func filePreview(fileID _: String) async throws -> FilePreviewSnapshot {
        previewRequests += 1
        guard !previewResults.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return try previewResults.removeFirst().get()
    }

    func downloadFile(_: FileLibraryItem) async throws -> DownloadedLibraryFile {
        downloadRequests += 1
        if let downloadDelay { try await Task.sleep(for: downloadDelay) }
        guard !downloadResults.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return try downloadResults.removeFirst().get()
    }

    func deleteFile(_: FileLibraryItem) async throws -> FileLibraryDeletionResult {
        deletionRequests += 1
        guard !deletionResults.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return try deletionResults.removeFirst().value()
    }

    func requestCount() -> Int { requests }
    func previewRequestCount() -> Int { previewRequests }
    func downloadRequestCount() -> Int { downloadRequests }
    func deletionRequestCount() -> Int { deletionRequests }
}
