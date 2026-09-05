import Foundation
import LibreChatDomain
import LibreChatProtocol

/// Owns authenticated user-file and generated-output byte transfers. Bytes
/// travel through LibreChat's protected proxy directly into a disk staging
/// file, then into a profile/account-scoped cache. Signed URLs, cookies, and
/// server storage paths never enter presentation state.
actor FileTransferManager {
    private let restClient: RESTClient

    init(runtime: LibreChatRuntime) {
        restClient = runtime.restClient
    }

    func downloadLibraryFile(
        _ item: FileLibraryItem,
        profileID: ServerProfileID,
        accountID: AccountID
    ) async throws -> DownloadedLibraryFile {
        let descriptor = try LibreChatFilesAPI.download(
            userID: accountID.rawValue,
            fileID: item.id
        )
        let transfer = try await download(
            descriptor,
            filename: item.file.filename,
            fallbackMimeType: item.file.mimeType,
            profileID: profileID,
            accountID: accountID
        )
        return DownloadedLibraryFile(
            profileID: profileID,
            accountID: accountID,
            localURL: transfer.localURL,
            filename: transfer.filename,
            mimeType: transfer.mimeType,
            bytes: transfer.bytes
        )
    }

    func downloadGeneratedFile(
        _ file: GeneratedFile,
        profileID: ServerProfileID,
        accountID: AccountID
    ) async throws -> DownloadedGeneratedFile {
        let descriptor: GeneratedFileByteRequest
        if let fileID = file.fileID?.nonEmpty {
            descriptor = try LibreChatGeneratedFileAPI.download(
                userID: accountID.rawValue,
                fileID: fileID
            )
        } else if let sessionID = file.provenance.sessionID?.nonEmpty,
                  let fallbackFileID = Self.codeFallbackFileID(file)?.nonEmpty {
            descriptor = try LibreChatGeneratedFileAPI.codeFallbackDownload(
                sessionID: sessionID,
                fileID: fallbackFileID
            )
        } else {
            throw GeneratedFileError.missingServerIdentifier
        }

        let transfer: TransferResult
        do {
            transfer = try await download(
                descriptor,
                filename: file.filename,
                fallbackMimeType: file.mimeType,
                profileID: profileID,
                accountID: accountID
            )
        } catch FileLibraryError.invalidDownload {
            throw GeneratedFileError.invalidDownload
        }
        return DownloadedGeneratedFile(
            profileID: profileID,
            accountID: accountID,
            sourceIdentity: file.identity,
            localURL: transfer.localURL,
            filename: transfer.filename,
            mimeType: transfer.mimeType,
            bytes: transfer.bytes
        )
    }

    private func download(
        _ descriptor: FileByteRequest,
        filename: String,
        fallbackMimeType: String?,
        profileID: ServerProfileID,
        accountID: AccountID
    ) async throws -> TransferResult {
        let response = try await restClient.downloadResponse(
            method: descriptor.method,
            path: descriptor.path,
            pathComponents: descriptor.pathComponents,
            headers: descriptor.headers,
            authorized: descriptor.authorization == .bearer,
            retryPolicy: descriptor.retryPolicy
        )
        var ownsStagingFile = true
        defer {
            if ownsStagingFile {
                try? FileManager.default.removeItem(at: response.localURL)
            }
        }
        try Task.checkCancellation()
        let values = try response.localURL.resourceValues(forKeys: [.fileSizeKey])
        // A missing size means the file cannot be verified; a present
        // zero-byte size is a legitimate empty artifact.
        guard let fileSize = values.fileSize else {
            throw FileLibraryError.invalidDownload
        }

        let directory = try FileTransferCacheDirectory.directory(
            profileID: profileID,
            accountID: accountID,
            create: true
        )
        try FileTransferCacheDirectory.pruneExpiredFiles(in: directory)
        let filename = Self.sanitizedFilename(filename)
        let localURL = directory.appending(path: "\(UUID().uuidString)-\(filename)")
        do {
            try FileManager.default.moveItem(at: response.localURL, to: localURL)
            ownsStagingFile = false
#if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: localURL.path
            )
#endif
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }

        let contentType = response.headers.first {
            $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        let resolvedMimeType = contentType?.lowercased().hasPrefix("application/octet-stream") == true
            ? fallbackMimeType
            : contentType?.nonEmpty ?? fallbackMimeType
        return TransferResult(
            localURL: localURL,
            filename: filename,
            mimeType: resolvedMimeType,
            bytes: Int64(fileSize)
        )
    }

    private struct TransferResult: Sendable {
        let localURL: URL
        let filename: String
        let mimeType: String?
        let bytes: Int64
    }

    private static func codeFallbackFileID(_ file: GeneratedFile) -> String? {
        let raw = file.provenance.codeDownloadPath ?? file.filepath ?? file.urlAlias
        guard let raw else { return nil }
        let path = URLComponents(string: raw)?.path ?? raw
        return path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let candidate = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return "Downloaded file"
        }
        // APFS NAME_MAX is 255 bytes and the UUID prefix consumes 37; an
        // emoji-heavy name capped by character count can still overflow the
        // byte budget, so truncate by encoded length instead.
        var byteCount = 0
        var bounded = Substring()
        for character in candidate {
            let length = String(character).utf8.count
            if byteCount + length > 180 { break }
            byteCount += length
            bounded.append(character)
        }
        return String(bounded)
    }
}

/// Shared path policy for all explicitly downloaded bytes. Keeping this
/// separate from
/// the transfer actor lets a complete SwiftData namespace purge remove its
/// associated files even when no repository runtime is active.
enum FileTransferCacheDirectory {
    static func directory(
        profileID: ServerProfileID,
        accountID: AccountID,
        create: Bool = false
    ) throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let accountNamespace = Data(accountID.rawValue.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let directory = root
            .appending(path: "DownloadedFiles", directoryHint: .isDirectory)
            .appending(path: profileID.rawValue, directoryHint: .isDirectory)
            .appending(path: accountNamespace, directoryHint: .isDirectory)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func purge(
        profileID: ServerProfileID,
        accountID: AccountID?
    ) throws {
        let target: URL
        if let accountID {
            target = try directory(profileID: profileID, accountID: accountID)
        } else {
            let root = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            target = root
                .appending(path: "DownloadedFiles", directoryHint: .isDirectory)
                .appending(path: profileID.rawValue, directoryHint: .isDirectory)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    static func pruneExpiredFiles(
        in directory: URL,
        olderThan cutoff: Date = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        for file in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// Source-compatible internal name for tests and call sites created before
/// owner-library and generated downloads began sharing one cache policy.
typealias GeneratedFileCacheDirectory = FileTransferCacheDirectory

/// Compatibility cleanup for app versions that stored generated downloads in
/// the former cache directory. New transfers never write here.
enum LegacyGeneratedFileCacheDirectory {
    static func purge(profileID: ServerProfileID, accountID: AccountID?) throws {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var target = root
            .appending(path: "GeneratedFiles", directoryHint: .isDirectory)
            .appending(path: profileID.rawValue, directoryHint: .isDirectory)
        if let accountID {
            let accountNamespace = Data(accountID.rawValue.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
            target.append(path: accountNamespace, directoryHint: .isDirectory)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
