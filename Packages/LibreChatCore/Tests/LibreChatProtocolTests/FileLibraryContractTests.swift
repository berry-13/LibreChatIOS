import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct FileLibraryContractTests {
    @Test func catalogFactoryUsesExactOwnerScopedBearerRead() {
        let request = LibreChatFilesAPI.catalog()

        #expect(request.method == .get)
        #expect(request.path == "api/files")
        #expect(request.pathComponents == ["api", "files"])
        #expect(request.authorization == .bearer)
        #expect(request.queryItems.isEmpty)
        #expect(request.body == nil)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func catalogMappingPreservesSafeMetadataAndIgnoresPrivateEvolvingPayloads() throws {
        let records = try JSONDecoder().decode(
            [LibreChatFileDTO].self,
            from: Data(
                #"[{"file_id":"file-1","filename":"Quarterly report.pdf","filepath":"/private/storage/object","bytes":2048,"type":"application/pdf","context":"message_attachment","source":"s3","embedded":true,"width":100,"height":200,"expiresAt":"2026-08-20T12:00:00.000Z","expiredAt":"2026-08-21T12:00:00.000Z","createdAt":"2026-08-18T10:00:00Z","updatedAt":"2026-08-19T11:30:00.123Z","text":"must not enter the domain","preview":"secret","metadata":{"token":"never"},"future":{"authorization":"never"}}]"#.utf8
            )
        )

        let snapshot = LibreChatFileCatalogMapper.snapshot(
            from: records,
            fetchedAt: Date(timeIntervalSince1970: 42)
        )
        let item = try #require(snapshot.items.first)

        #expect(snapshot.items.count == 1)
        #expect(snapshot.omittedCount == 0)
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 42))
        #expect(item.id == "file-1")
        #expect(item.file.filename == "Quarterly report.pdf")
        #expect(item.file.bytes == 2_048)
        #expect(item.file.mimeType == "application/pdf")
        #expect(item.file.source == "s3")
        #expect(item.file.context == "message_attachment")
        #expect(item.file.embedded == true)
        #expect(item.createdAt != nil)
        #expect(item.updatedAt != nil)
        #expect(item.expiresAt == ISO8601DateFormatter().date(from: "2026-08-21T12:00:00Z"))
    }

    @Test func missingIdentityIsOmittedWhileUnknownSourceRemainsLossless() throws {
        let records = try JSONDecoder().decode(
            [LibreChatFileDTO].self,
            from: Data(
                #"[{"filename":"No identity"},{"file_id":"future-1","filename":"Future.dat","source":"future-storage","context":"future-context","bytes":-1}]"#.utf8
            )
        )

        let snapshot = LibreChatFileCatalogMapper.snapshot(from: records)
        let item = try #require(snapshot.items.first)

        #expect(snapshot.items.count == 1)
        #expect(snapshot.omittedCount == 1)
        #expect(item.file.source == "future-storage")
        #expect(item.file.context == "future-context")
        #expect(item.file.bytes == -1)
    }

    @Test func duplicateIdentitiesFailClosedWithoutHidingIndependentFiles() throws {
        let records = try JSONDecoder().decode(
            [LibreChatFileDTO].self,
            from: Data(
                #"[{"file_id":"same","filename":"A.txt"},{"file_id":"same","filename":"A.txt"},{"file_id":"conflict","filename":"First.txt"},{"file_id":"other","filename":"Other.txt"},{"file_id":"conflict","filename":"Second.txt"},{"file_id":"conflict","filename":"Third.txt"}]"#.utf8
            )
        )

        let snapshot = LibreChatFileCatalogMapper.snapshot(from: records)

        #expect(snapshot.items.map(\.id) == ["same", "other"])
        #expect(snapshot.omittedCount == 4)
    }

    @Test func legacyCatalogItemUsesReadableFallbacksAndNonfractionalDates() throws {
        let record = try JSONDecoder().decode(
            LibreChatFileDTO.self,
            from: Data(
                #"{"file_id":"legacy","filename":"","createdAt":"2026-08-19T00:00:00Z","expiresAt":"invalid"}"#.utf8
            )
        )

        let item = try record.fileLibraryItem()

        #expect(item.file.filename == "Unnamed file")
        #expect(item.createdAt != nil)
        #expect(item.updatedAt == nil)
        #expect(item.expiresAt == nil)
    }

    @Test func previewFactoryUsesExactACLProtectedRouteAndEncodesOneFileSegment() throws {
        let request = try LibreChatFilesAPI.preview(fileID: "folder/file ?")

        #expect(request.method == .get)
        #expect(request.path == "api/files/folder/file ?/preview")
        #expect(request.pathComponents == ["api", "files", "folder/file ?", "preview"])
        #expect(request.authorization == .bearer)
        #expect(request.queryItems.isEmpty)
        #expect(request.body == nil)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func downloadFactoryUsesExactProtectedProxyAndNeverExposesSignedURLContract() throws {
        let request = try LibreChatFilesAPI.download(
            userID: "account/user %",
            fileID: "folder/file ?"
        )

        #expect(request.method == .get)
        #expect(request.path == "api/files/download/account/user %/folder/file ?")
        #expect(request.pathComponents == [
            "api", "files", "download", "account/user %", "folder/file ?"
        ])
        #expect(request.headers == ["Accept": "application/octet-stream"])
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        #expect(!request.path.contains("download-url"))
    }

    @Test func downloadFactoryRejectsEmptyNULAndOversizedIdentitiesBeforeTransport() {
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatFilesAPI.download(userID: "", fileID: "file")
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatFilesAPI.download(userID: "account", fileID: "file\0secret")
        }
        #expect(throws: LibreChatProtocolError.self) {
            try LibreChatFilesAPI.download(
                userID: "account",
                fileID: String(repeating: "x", count: 2_049)
            )
        }
    }

    @Test func ownerDeleteFactoryUsesExactSingleFileBodyAndNeverRetries() throws {
        let item = FileLibraryItem(file: UploadedFile(
            id: "file-budget",
            temporaryID: "temporary-budget",
            filename: "Budget.pdf",
            filepath: "/private/storage/budget.pdf",
            source: "s3",
            embedded: true
        ))

        let request = try LibreChatFilesAPI.delete(item)
        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let files = try #require(object["files"] as? [[String: Any]])
        let file = try #require(files.first)

        #expect(request.method == .delete)
        #expect(request.path == "api/files")
        #expect(request.pathComponents == ["api", "files"])
        #expect(request.authorization == .bearer)
        #expect(request.retryPolicy == .never)
        #expect(files.count == 1)
        #expect(file["file_id"] as? String == "file-budget")
        #expect(file["temp_file_id"] as? String == "temporary-budget")
        #expect(file["filepath"] as? String == "/private/storage/budget.pdf")
        #expect(file["source"] as? String == "s3")
        #expect(file["embedded"] as? Bool == true)
        #expect(Set(file.keys) == Set(["file_id", "temp_file_id", "filepath", "source", "embedded"]))
    }

    @Test func ownerDeleteRejectsServerFilteredIdentityAndMissingPathBeforeTransport() {
        #expect(throws: DTOMapperError.self) {
            try LibreChatFilesAPI.delete(FileLibraryItem(file: UploadedFile(
                id: "future-id",
                filename: "Future.dat",
                filepath: "/private/future"
            )))
        }
        #expect(throws: DTOMapperError.self) {
            try LibreChatFilesAPI.delete(FileLibraryItem(file: UploadedFile(
                id: "file-valid",
                filename: "Missing path.dat"
            )))
        }
        #expect(FileDeletionDTO.isAcceptedFileID("assistant-resource"))
        #expect(FileDeletionDTO.isAcceptedFileID("4C0A86B2-D64E-43DF-BFC3-29D48A14A005"))
        #expect(!FileDeletionDTO.isAcceptedFileID("future-id"))
        #expect(!FileDeletionDTO.isAcceptedFileID("{4C0A86B2-D64E-43DF-BFC3-29D48A14A005}"))
    }

    @Test func pendingAndFailedPreviewStatesNeverExposeServerFailureText() throws {
        let pending = try JSONDecoder().decode(
            LibreChatFilePreviewDTO.self,
            from: Data(#"{"file_id":"file","status":"pending","future":"ignored"}"#.utf8)
        )
        let failed = try JSONDecoder().decode(
            LibreChatFilePreviewDTO.self,
            from: Data(#"{"file_id":"file","status":"failed","previewError":"private/provider/path"}"#.utf8)
        )

        #expect(try pending.domainModel(expectedFileID: "file").lifecycle == .processing)
        let failedModel = try failed.domainModel(expectedFileID: "file")
        #expect(failedModel.lifecycle == .unavailable)
        #expect(failedModel.text == nil)
    }

    @Test func readyHTMLIsBoundedAndRemainsInertSourceText() throws {
        let response = LibreChatFilePreviewDTO(
            fileID: "file",
            status: "ready",
            text: "<script>never execute</script>",
            textFormat: "html"
        )

        let model = try response.domainModel(expectedFileID: "file", maximumCharacters: 8)

        #expect(model.lifecycle == .ready)
        #expect(model.format == .htmlSource)
        #expect(model.text == "<script>")
        #expect(model.isTruncated)
    }

    @Test func readyWithoutExtractedTextIsAValidMetadataOnlyPreview() throws {
        let response = LibreChatFilePreviewDTO(
            fileID: "file",
            status: "ready",
            text: nil,
            textFormat: nil
        )

        let model = try response.domainModel(expectedFileID: "file")

        #expect(model.lifecycle == .ready)
        #expect(model.text == nil)
        #expect(model.format == nil)
        #expect(!model.isTruncated)
    }

    @Test func previewIdentityStatusAndPendingPayloadMismatchFailClosed() throws {
        let wrongIdentity = LibreChatFilePreviewDTO(
            fileID: "other",
            status: "ready",
            text: "text",
            textFormat: "text"
        )
        let unknown = LibreChatFilePreviewDTO(
            fileID: "file",
            status: "future",
            text: nil,
            textFormat: nil
        )
        let leakingPending = LibreChatFilePreviewDTO(
            fileID: "file",
            status: "pending",
            text: "not terminal",
            textFormat: "text"
        )

        #expect(throws: LibreChatProtocolError.self) {
            try wrongIdentity.domainModel(expectedFileID: "file")
        }
        #expect(throws: LibreChatProtocolError.self) {
            try unknown.domainModel(expectedFileID: "file")
        }
        #expect(throws: LibreChatProtocolError.self) {
            try leakingPending.domainModel(expectedFileID: "file")
        }
    }
}
