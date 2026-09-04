import Foundation
import LibreChatDomain

/// Descriptor for an authenticated byte transfer. Core deliberately keeps
/// byte downloads separate from JSON decoding so the live client can stream
/// directly to disk and avoid retaining large files in memory.
public struct FileByteRequest: Codable, Equatable, Sendable {
    public var method: HTTPMethod
    public var path: String
    public var pathComponents: [String]
    public var headers: [String: String]
    public var authorization: AuthorizationRequirement
    public var retryPolicy: RequestRetryPolicy

    public init(
        method: HTTPMethod = .get,
        path: String,
        pathComponents: [String],
        headers: [String: String] = [:],
        authorization: AuthorizationRequirement = .bearer,
        retryPolicy: RequestRetryPolicy = .never
    ) {
        self.method = method
        self.path = path
        self.pathComponents = pathComponents
        self.headers = headers
        self.authorization = authorization
        self.retryPolicy = retryPolicy
    }
}

public enum LibreChatFilesAPI {
    /// LibreChat returns the current user's complete owner-scoped catalog as a
    /// JSON array. The pinned contract has no paging or query parameters.
    public static func catalog() -> APIRequest<[LibreChatFileDTO]> {
        APIRequest(
            path: "api/files",
            pathComponents: ["api", "files"],
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    /// Owner/agent ACL is enforced by LibreChat's `fileAccess` middleware.
    /// The response is live and must not be persisted as an offline preview.
    public static func preview(fileID: String) throws -> APIRequest<LibreChatFilePreviewDTO> {
        let fileID = try validatedIdentity(fileID, field: "file")
        return APIRequest(
            path: "api/files/\(fileID)/preview",
            pathComponents: ["api", "files", fileID, "preview"],
            authorization: .bearer,
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    /// Uses LibreChat's authenticated proxied download path. The native app
    /// intentionally does not request/persist/present provider-signed URLs.
    public static func download(userID: String, fileID: String) throws -> FileByteRequest {
        let userID = try validatedIdentity(userID, field: "user")
        let fileID = try validatedIdentity(fileID, field: "file")
        return FileByteRequest(
            path: "api/files/download/\(userID)/\(fileID)",
            pathComponents: ["api", "files", "download", userID, fileID],
            headers: ["Accept": "application/octet-stream"],
            authorization: .bearer,
            // A user can retry explicitly. The client never duplicates a
            // potentially large transfer after a transport ambiguity.
            retryPolicy: .never
        )
    }

    /// Requests deletion of one exact owner-catalog record. LibreChat's
    /// response is only an attempt acknowledgement; callers must reconcile
    /// the raw owner catalog before reporting success.
    public static func delete(_ item: FileLibraryItem) throws -> APIRequest<EmptyResponse> {
        try APIRequest(
            method: .delete,
            path: "api/files",
            pathComponents: ["api", "files"],
            body: DeleteFilesRequestDTO(files: [try FileDeletionDTO(file: item.file)]),
            authorization: .bearer,
            retryPolicy: .never
        )
    }

    private static func validatedIdentity(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value.utf16.count <= 2_048,
              !value.contains("\0") else {
            throw LibreChatProtocolError.encoding("Invalid \(field) identity.")
        }
        return value
    }
}

public struct LibreChatFilePreviewDTO: Decodable, Equatable, Sendable {
    public var fileID: String?
    public var status: String?
    public var text: String?
    public var textFormat: String?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case status, text, textFormat
    }

    public func domainModel(
        expectedFileID: String,
        maximumCharacters: Int = 50_000
    ) throws -> FilePreviewSnapshot {
        guard fileID == expectedFileID,
              maximumCharacters > 0 else {
            throw LibreChatProtocolError.invalidResponse
        }

        switch status?.lowercased() {
        case "pending":
            guard text == nil, textFormat == nil else {
                throw LibreChatProtocolError.invalidResponse
            }
            return FilePreviewSnapshot(fileID: expectedFileID, lifecycle: .processing)
        case "failed":
            return FilePreviewSnapshot(fileID: expectedFileID, lifecycle: .unavailable)
        case "ready":
            guard let text else {
                return FilePreviewSnapshot(fileID: expectedFileID, lifecycle: .ready)
            }
            let isTruncated = text.count > maximumCharacters
            let visibleText = isTruncated ? String(text.prefix(maximumCharacters)) : text
            let format: FilePreviewSnapshot.Format = switch textFormat?.lowercased() {
            case "text", nil: .text
            case "html": .htmlSource
            default: .unsupportedSource
            }
            return FilePreviewSnapshot(
                fileID: expectedFileID,
                lifecycle: .ready,
                text: visibleText,
                format: format,
                isTruncated: isTruncated
            )
        default:
            throw LibreChatProtocolError.invalidResponse
        }
    }
}

public enum LibreChatFileCatalogMapper {
    public static func snapshot(
        from records: [LibreChatFileDTO],
        fetchedAt: Date = Date()
    ) -> FileLibrarySnapshot {
        var itemsByID: [String: FileLibraryItem] = [:]
        var order: [String] = []
        var conflictingIDs: Set<String> = []
        var omittedCount = 0

        for record in records {
            let item: FileLibraryItem
            do {
                item = try record.fileLibraryItem()
            } catch {
                omittedCount += 1
                continue
            }

            if conflictingIDs.contains(item.id) {
                omittedCount += 1
                continue
            }

            if let existing = itemsByID[item.id] {
                if existing == item {
                    // A replayed identical record does not create a second row.
                    omittedCount += 1
                } else {
                    // The same server identity cannot safely describe two
                    // different files. Hide both and keep the ID quarantined.
                    itemsByID.removeValue(forKey: item.id)
                    order.removeAll { $0 == item.id }
                    conflictingIDs.insert(item.id)
                    omittedCount += 2
                }
                continue
            }

            itemsByID[item.id] = item
            order.append(item.id)
        }

        return FileLibrarySnapshot(
            items: order.compactMap { itemsByID[$0] },
            omittedCount: omittedCount,
            fetchedAt: fetchedAt
        )
    }
}
