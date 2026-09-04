import Foundation

/// One owner-scoped file returned by LibreChat's authenticated file catalog.
///
/// The raw storage path is retained inside `UploadedFile` for future
/// authorized transfer operations, but presentation must never expose it as a
/// user-facing server path. Catalog entries are live server state and are not
/// an offline cache contract.
public struct FileLibraryItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var file: UploadedFile
    public var createdAt: Date?
    public var updatedAt: Date?
    public var expiresAt: Date?

    public var id: String { file.id }

    public init(
        file: UploadedFile,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.file = file
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
    }
}

/// A live, owner-filtered catalog response.
///
/// `omittedCount` lets the UI disclose that malformed or identity-conflicting
/// server records were hidden without leaking their payloads or failing the
/// rest of the account's catalog.
public struct FileLibrarySnapshot: Codable, Equatable, Sendable {
    public var items: [FileLibraryItem]
    public var omittedCount: Int
    public var fetchedAt: Date

    public init(
        items: [FileLibraryItem],
        omittedCount: Int = 0,
        fetchedAt: Date = Date()
    ) {
        self.items = items
        self.omittedCount = max(0, omittedCount)
        self.fetchedAt = fetchedAt
    }
}

/// A live, owner-authorized preview projection. HTML is always retained as
/// source text; the native client never treats server preview text as trusted
/// executable markup.
public struct FilePreviewSnapshot: Codable, Equatable, Sendable {
    public enum Lifecycle: String, Codable, Equatable, Sendable {
        case processing
        case ready
        case unavailable
    }

    public enum Format: String, Codable, Equatable, Sendable {
        case text
        case htmlSource
        case unsupportedSource
    }

    public var fileID: String
    public var lifecycle: Lifecycle
    public var text: String?
    public var format: Format?
    public var isTruncated: Bool

    public init(
        fileID: String,
        lifecycle: Lifecycle,
        text: String? = nil,
        format: Format? = nil,
        isTruncated: Bool = false
    ) {
        self.fileID = fileID
        self.lifecycle = lifecycle
        self.text = text
        self.format = format
        self.isTruncated = isTruncated
    }
}

/// A profile/account-scoped local copy created only after an explicit user
/// download. The server URL, storage path, cookies, and authorization headers
/// never enter this value or presentation state.
public struct DownloadedLibraryFile: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let localURL: URL
    public let filename: String
    public let mimeType: String?
    public let bytes: Int64

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        localURL: URL,
        filename: String,
        mimeType: String? = nil,
        bytes: Int64
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.localURL = localURL
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
    }
}

/// The finite result of an owner-file deletion attempt after LibreChat's live
/// owner catalog has been read again. A successful DELETE response alone is
/// deliberately never treated as proof that the storage object was removed.
public struct FileLibraryDeletionResult: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Equatable, Sendable {
        case deleted
        case retained
    }

    public enum Attempt: String, Codable, Equatable, Sendable {
        case accepted
        case rejected
        case deliveryUncertain
    }

    public let disposition: Disposition
    public let attempt: Attempt
    public let snapshot: FileLibrarySnapshot

    public init(
        disposition: Disposition,
        attempt: Attempt,
        snapshot: FileLibrarySnapshot
    ) {
        self.disposition = disposition
        self.attempt = attempt
        self.snapshot = snapshot
    }
}

public enum FileLibraryError: LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidDownload
    case deletionInProgress
    case deletionVerificationRequired

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "This file cannot be downloaded from this LibreChat deployment."
        case .invalidDownload:
            "LibreChat returned an empty or invalid file download."
        case .deletionInProgress:
            "This file is already being deleted."
        case .deletionVerificationRequired:
            "LibreChat could not verify whether the file was deleted. Refresh the file library before trying again."
        }
    }
}
