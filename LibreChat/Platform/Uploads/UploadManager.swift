import Foundation
import ImageIO
import LibreChatDomain
import LibreChatProtocol
import UniformTypeIdentifiers

/// A size/limit rejection that survives the client-side compaction pass.
/// The chat surface presents this as a transient toast — never as a
/// persistent inline error with a dismiss control.
struct FileUploadRejection: Error, Equatable {
    let message: String
}

actor UploadManager: UploadRepository {
    private let profileID: ServerProfileID
    private let accountID: AccountID
    private let runtime: LibreChatRuntime
    private let cache: CacheCoordinator
    private var uploadsByID: [UUID: PendingUpload] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Advanced on every resetAfterCachePurge; a stage() call that began
    /// under a previous session must never enqueue against stale credentials.
    private(set) var sessionEpoch = UUID()
    private var usageRenewalTask: Task<Void, Never>?
    private var immediateUsageRenewalTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[PendingUpload]>.Continuation] = [:]
    private var fileConfiguration: FileConfigurationDTO?
    private var didLoadFileConfiguration = false

    init(profileID: ServerProfileID, accountID: AccountID, runtime: LibreChatRuntime, cache: CacheCoordinator) {
        self.profileID = profileID
        self.accountID = accountID
        self.runtime = runtime
        self.cache = cache
    }

    func restore() async {
        guard let saved = try? await cache.uploads(profileID: profileID, accountID: accountID) else { return }
        for var upload in saved {
            // Temporary Chat attachments are intentionally session-scoped on
            // device. If the process ended before delivery, discard the local
            // recovery copy rather than restoring private content on relaunch.
            if upload.isTemporary == true {
                try? FileManager.default.removeItem(at: upload.localURL)
                try? await cache.removeUpload(
                    id: upload.id,
                    profileID: profileID,
                    accountID: accountID
                )
                continue
            }
            if upload.state == .uploading {
                // The pre-launch dispatch may already have committed
                // server-side; only never-dispatched staged records may be
                // re-enqueued as-is.
                upload.state = .deliveryUncertain
            }
            uploadsByID[upload.id] = upload
            if upload.state == .staged {
                // Staging is persisted before dispatch, so a staged record
                // never reached the network and can be uploaded now instead
                // of blocking the composer as "Preparing…" forever.
                try? await enqueue(upload)
            }
        }
        publish()
        await scheduleUsageRenewal(immediate: true)
    }

    /// Full ownership teardown. Cancelling alone cannot stop a renewal that is
    /// already suspended inside its request dispatch, so the cancelled tasks
    /// are also drained before returning — after this call, no usage renewal
    /// can still dispatch under this manager's identity.
    func resetAfterCachePurge() async {
        sessionEpoch = UUID()
        let outstanding = Array(tasks.values)
        tasks.removeAll()
        outstanding.forEach { $0.cancel() }
        // Drain before clearing shared state: performUpload is actor-isolated,
        // so awaiting here lets each cancelled task finish; without this, a
        // late completion could recreate a purged upload record pointing at
        // deleted local data.
        for task in outstanding {
            _ = await task.value
        }
        usageRenewalTask?.cancel()
        immediateUsageRenewalTask?.cancel()
        await usageRenewalTask?.value
        usageRenewalTask = nil
        await immediateUsageRenewalTask?.value
        immediateUsageRenewalTask = nil
        uploadsByID.removeAll()
        publish()
    }

    func applicationBecameActive() async {
        await scheduleUsageRenewal(immediate: true)
    }

    func updates() -> AsyncStream<[PendingUpload]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(currentUploads())
            continuation.onTermination = { _ in Task { await self.removeContinuation(id) } }
        }
    }

    func stage(
        data: Data,
        filename: String,
        mimeType: String?,
        conversationID: ConversationID?,
        target: ConversationTarget,
        isTemporary: Bool = false
    ) async throws -> PendingUpload {
        let stageEpoch = sessionEpoch
        guard !data.isEmpty else {
            throw LibreChatProtocolError.unsupported("That file is empty.")
        }
        guard !target.endpoint.isEmpty else {
            throw LibreChatProtocolError.unsupported("Choose a model or agent before attaching a file.")
        }
        guard GenerationEndpointPolicy.route(for: target).supportsResumableV2 else {
            throw LibreChatProtocolError.unsupported(
                "This chat target cannot accept native attachments safely. Choose a supported target in New Chat."
            )
        }
        let sanitized = Self.sanitizedFilename(filename)
        let suppliedMimeType = Self.mimeType(for: sanitized, supplied: mimeType)
        let configuration = try await loadFileConfiguration()
        // A profile switch while preparation was suspended invalidates this
        // staging attempt: the retained runtime belongs to the old session.
        guard stageEpoch == sessionEpoch else {
            throw LibreChatProtocolError.unsupported("That attachment belonged to a previous session. Attach it again.")
        }
        var prepared = try Self.preparedUploadData(
            data: data,
            mimeType: suppliedMimeType,
            configuration: configuration
        )

        // Oversized images get one automatic compaction pass: the file is
        // re-encoded at progressively smaller scales/qualities until it fits
        // the server's limit. Unsupported or non-image types are never
        // altered; whatever still exceeds the limit becomes a typed
        // rejection the chat surface presents as a toast.
        if let sizeLimit = Self.effectiveSizeLimit(
            configuration: configuration,
            endpoint: target.endpoint,
            endpointType: target.endpointType
        ), Int64(prepared.data.count) > sizeLimit,
           let compacted = Self.compactedUploadData(
               data: prepared.data,
               mimeType: prepared.mimeType,
               byteLimit: sizeLimit
           ) {
            prepared = (data: compacted, mimeType: "image/jpeg")
        }
        // Dimensions must be read from the final bytes: compaction re-encodes
        // the image, and metadata sent with the upload has to match what the
        // server actually stores.
        let dimensions = Self.imageDimensions(data: prepared.data, mimeType: prepared.mimeType)
        try validate(
            byteCount: prepared.data.count,
            mimeType: prepared.mimeType,
            conversationID: conversationID,
            endpoint: target.endpoint,
            endpointType: target.endpointType,
            configuration: configuration
        )

        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appending(path: "Uploads", directoryHint: .isDirectory)
            .appending(path: profileID.rawValue, directoryHint: .isDirectory)
            .appending(path: Self.safePathComponent(accountID.rawValue), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let localURL = directory.appending(path: "\(id.uuidString)-\(sanitized)")
        try prepared.data.write(to: localURL, options: .atomic)
        let upload = PendingUpload(
            id: id,
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            localURL: localURL,
            filename: sanitized,
            mimeType: prepared.mimeType,
            endpoint: target.endpoint,
            endpointType: target.endpointType,
            isTemporary: isTemporary,
            width: dimensions?.width,
            height: dimensions?.height
        )
        uploadsByID[id] = upload
        do {
            try await cache.save(upload: upload)
        } catch {
            // Roll the staging back: without a cache record the upload is
            // invisible to the user yet still counts against limits, and its
            // file would never be discovered for cleanup after a relaunch.
            uploadsByID.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
        publish()
        try await enqueue(upload)
        return upload
    }

    func enqueue(_ upload: PendingUpload) async throws {
        uploadsByID[upload.id] = upload
        tasks[upload.id]?.cancel()
        tasks[upload.id] = Task { await self.performUpload(id: upload.id) }
    }

    /// Tears down every upload owned by a discarded draft canvas: cancels
    /// in-flight work, deletes confirmed remote temp files, and removes the
    /// local records and bytes, since no UI can reach them afterwards.
    func discardUploads(for conversationID: ConversationID) async {
        let ownedIDs = uploadsByID.values
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for id in ownedIDs {
            await cancel(id: id)
            uploadsByID.removeValue(forKey: id)
            try? await cache.removeUpload(id: id, profileID: profileID, accountID: accountID)
        }
        guard !ownedIDs.isEmpty else { return }
        publish()
        await scheduleUsageRenewal(immediate: false)
    }

    func cancel(id: UUID) async {
        tasks[id]?.cancel()
        tasks[id] = nil
        guard var upload = uploadsByID[id] else { return }
        if upload.state == .completed, let remoteFile = upload.remoteFile {
            do {
                try await deleteRemoteFile(remoteFile)
            } catch {
                // The server's upload TTL remains the final orphan cleanup path.
                AppLog.uploads.error("Remote attachment cleanup failed; local removal will continue.")
            }
        }
        upload.state = .cancelled
        uploadsByID[id] = upload
        try? FileManager.default.removeItem(at: upload.localURL)
        try? await cache.save(upload: upload)
        publish()
        await scheduleUsageRenewal(immediate: false)
    }

    func retry(id: UUID) async throws {
        guard var upload = uploadsByID[id], upload.state == .failed else { return }
        upload.state = .staged
        upload.progress = 0
        uploadsByID[id] = upload
        try await cache.save(upload: upload)
        try await enqueue(upload)
    }

    func reconcileDelivery(id: UUID) async throws {
        guard let upload = uploadsByID[id], upload.state == .deliveryUncertain else { return }
        guard let recovered = try await reconcileUpload(upload) else {
            throw LibreChatProtocolError.unsupported(
                "LibreChat has not confirmed this attachment yet. Check again later or remove it."
            )
        }
        try await update(recovered)
        await scheduleUsageRenewal(immediate: true)
    }

    func markAttached(ids: [UUID], conversationID: ConversationID) async {
        for id in ids {
            guard var upload = uploadsByID[id],
                  upload.state == .completed || upload.state == .queued else { continue }
            try? FileManager.default.removeItem(at: upload.localURL)
            if upload.isTemporary == true {
                uploadsByID[id] = nil
                try? await cache.removeUpload(
                    id: id,
                    profileID: profileID,
                    accountID: accountID
                )
            } else {
                upload.state = .attached
                upload.conversationID = conversationID
                uploadsByID[id] = upload
                try? await cache.save(upload: upload)
            }
        }
        publish()
        await scheduleUsageRenewal(immediate: false)
    }

    /// Transfers complete uploads from the live composer into durable queue
    /// ownership. The server file hold remains active until that queue item is
    /// delivered or explicitly removed before admission.
    func markQueued(ids: [UUID], conversationID: ConversationID) async throws {
        let unique = Array(Set(ids))
        guard unique.count == ids.count else {
            throw LibreChatProtocolError.invalidResponse
        }
        for id in unique {
            guard let upload = uploadsByID[id],
                  upload.profileID == profileID,
                  upload.accountID == accountID,
                  upload.conversationID == conversationID,
                  (upload.state == .completed || upload.state == .queued),
                  upload.remoteFile != nil else {
                throw LibreChatProtocolError.invalidResponse
            }
        }
        for id in unique {
            guard var upload = uploadsByID[id] else { continue }
            guard upload.state != .queued else { continue }
            upload.state = .queued
            try await update(upload)
        }
        await scheduleUsageRenewal(immediate: true)
    }

    /// Returns a never-admitted queued upload to the composer. Callers must
    /// first remove the durable queue reference and prove no sibling row owns
    /// the same upload coordinate.
    func markUnqueued(ids: [UUID], conversationID: ConversationID) async throws {
        for id in Set(ids) {
            guard var upload = uploadsByID[id],
                  upload.profileID == profileID,
                  upload.accountID == accountID,
                  upload.conversationID == conversationID,
                  upload.state == .queued else { continue }
            upload.state = .completed
            try await update(upload)
        }
        await scheduleUsageRenewal(immediate: true)
    }

    private func performUpload(id: UUID) async {
        guard var upload = uploadsByID[id] else { return }
        do {
            upload.state = .uploading
            upload.progress = 0
            try await update(upload)

            let boundary = "LibreChat-\(UUID().uuidString)"
            // The multipart body is streamed from disk: materializing both the
            // staged file and the complete request body in memory would let a
            // few concurrent near-ceiling uploads exhaust the process.
            let bodyFileURL = try Self.writeMultipartBodyFile(for: upload, boundary: boundary)
            // Every exit — success, throw, or cancellation — removes the
            // attachment-sized staging file.
            defer { try? FileManager.default.removeItem(at: bodyFileURL) }
            var request = APIRequest<LibreChatFileDTO>(
                method: .post,
                path: Self.uploadPath(for: upload),
                headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"],
                retryPolicy: .never
            )
            let response = try await runtime.restClient.sendUploadFile(
                request,
                bodyFileURL: bodyFileURL
            ) { [weak self] fraction in
                Task { await self?.reportProgress(id: id, fraction: fraction) }
            }
            try? FileManager.default.removeItem(at: bodyFileURL)
            let remoteFile = try response.domainModel(fallbackFilename: upload.filename)
            upload = try Self.completedUpload(upload, acknowledging: remoteFile)
            try await update(upload)
            await scheduleUsageRenewal(immediate: true)
        } catch is CancellationError {
            upload.state = .cancelled
            try? await update(upload)
        } catch {
            if Task.isCancelled {
                upload.state = .cancelled
                try? await update(upload)
            } else if Self.requiresReconciliation(error),
               let recovered = try? await reconcileUpload(upload) {
                upload = recovered
                try? await update(upload)
                await scheduleUsageRenewal(immediate: true)
                AppLog.uploads.notice("Ambiguous upload recovered by its client file coordinate.")
            } else if Self.requiresReconciliation(error) {
                upload.state = .deliveryUncertain
                try? await update(upload)
                AppLog.uploads.error("Upload delivery is uncertain; blind retry is disabled.")
            } else {
                upload.state = .failed
                try? await update(upload)
                AppLog.uploads.error("Upload failed before a usable acknowledgement; the staged file remains recoverable.")
            }
        }
        tasks[id] = nil
    }

    /// Publishes transport progress into the live upload list without a
    /// durable cache write per callback; the terminal states persist through
    /// `update`. Coarsened to 2% steps so long uploads don't spam renders.
    private func reportProgress(id: UUID, fraction: Double) {
        guard var upload = uploadsByID[id], upload.state == .uploading else { return }
        let clamped = min(0.99, max(0, fraction))
        guard abs(clamped - upload.progress) >= 0.02 else { return }
        upload.progress = clamped
        uploadsByID[id] = upload
        publish()
    }

    /// Uploads currently attached to one conversation, for surfaces (like the
    /// sidebar's unsent-draft rows) that only need a count/check.
    func pendingUploads(conversationID: ConversationID) -> [PendingUpload] {
        uploadsByID.values.filter {
            $0.conversationID == conversationID
                && $0.state != .cancelled
                && $0.state != .attached
        }
    }

    private func reconcileUpload(_ upload: PendingUpload) async throws -> PendingUpload? {
        let request = APIRequest<[LibreChatFileDTO]>(
            path: "api/files",
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
        let files = try await runtime.restClient.send(request)
        let matches = files.filter { $0.temporaryFileID == upload.id.uuidString }
        guard matches.count == 1 else { return nil }
        let remoteFile = try matches[0].domainModel(fallbackFilename: upload.filename)
        return try Self.completedUpload(upload, acknowledging: remoteFile)
    }

    static func uploadPath(for upload: PendingUpload) -> String {
        let endpoint = (upload.endpoint ?? "").lowercased()
        let endpointType = (upload.endpointType ?? "").lowercased()
        let isAssistantsV2 = endpoint.hasSuffix("assistants") || endpointType.hasSuffix("assistants")
        let isImage = upload.width.map { $0 > 0 } == true && upload.height.map { $0 > 0 } == true
        return isImage && !isAssistantsV2 ? "api/files/images" : "api/files"
    }

    static func completedUpload(
        _ upload: PendingUpload,
        acknowledging remoteFile: UploadedFile
    ) throws -> PendingUpload {
        guard remoteFile.temporaryID == upload.id.uuidString,
              !remoteFile.id.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        var completed = upload
        completed.remoteIdentifier = remoteFile.id
        completed.remoteFile = remoteFile
        completed.progress = 1
        completed.state = .completed
        return completed
    }

    private static func requiresReconciliation(_ error: Error) -> Bool {
        guard let protocolError = error as? LibreChatProtocolError else {
            return !(error is CancellationError)
        }
        switch protocolError {
        case .transport, .decoding, .invalidResponse, .serverNotReady:
            return true
        case let .httpStatus(status, _, _):
            return status >= 500
        case .unauthorized, .generationConflict, .unsupported, .encoding, .keychain:
            return false
        }
    }

    private func update(_ upload: PendingUpload) async throws {
        uploadsByID[upload.id] = upload
        try await cache.save(upload: upload)
        publish()
    }

    private func currentUploads() -> [PendingUpload] {
        uploadsByID.values.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    private func publish() {
        let value = currentUploads()
        continuations.values.forEach { $0.yield(value) }
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    /// Schedules the queued-upload hold renewal cadence. Every cancelled
    /// renewal is also drained before its reference is dropped: a cancelled
    /// task can still be suspended inside its request dispatch, and an
    /// undrained one could issue a usage POST after its owning state is gone.
    private func scheduleUsageRenewal(immediate: Bool) async {
        guard !queuedRemoteFileIDs().isEmpty else {
            let renewalTask = usageRenewalTask
            let immediateTask = immediateUsageRenewalTask
            renewalTask?.cancel()
            immediateTask?.cancel()
            usageRenewalTask = nil
            immediateUsageRenewalTask = nil
            await renewalTask?.value
            await immediateTask?.value
            return
        }

        if usageRenewalTask != nil {
            if immediate {
                let previous = immediateUsageRenewalTask
                previous?.cancel()
                await previous?.value
                immediateUsageRenewalTask = Task { await self.refreshFileUsageHold() }
            }
            return
        }

        usageRenewalTask = Task { [weak self] in
            guard let self else { return }
            if immediate { await self.refreshFileUsageHold() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30 * 60))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.refreshFileUsageHold()
            }
        }
    }

    private func refreshFileUsageHold() async {
        guard !Task.isCancelled else { return }
        let batches = Self.fileUsageBatches(queuedRemoteFileIDs())
        guard !batches.isEmpty else {
            usageRenewalTask?.cancel()
            usageRenewalTask = nil
            return
        }
        for fileIDs in batches {
            // Teardown may have landed while this renewal was suspended; do
            // not dispatch another hold request under a cancelled identity.
            guard !Task.isCancelled else { return }
            do {
                let request = try APIRequest<FilesUsageResponseDTO>(
                    path: "api/files/usage",
                    body: FilesUsageRequestDTO(fileIDs: fileIDs),
                    retryPolicy: .never
                )
                let response = try await runtime.restClient.send(request)
                if response.held < fileIDs.count {
                    AppLog.uploads.error("LibreChat did not renew every queued attachment hold.")
                }
            } catch LibreChatProtocolError.unauthorized {
                AppLog.uploads.error("Attachment hold renewal was unauthorized.")
                return
            } catch let LibreChatProtocolError.httpStatus(status, _, _) where status == 404 || status == 405 {
                // Older compatible instances do not expose queued-upload holds.
                usageRenewalTask?.cancel()
                usageRenewalTask = nil
                return
            } catch {
                AppLog.uploads.error("Attachment hold renewal failed; the next cadence can retry.")
            }
        }
    }

    private func queuedRemoteFileIDs() -> [String] {
        uploadsByID.values.compactMap { upload in
            guard upload.state == .completed || upload.state == .queued else { return nil }
            return upload.remoteFile?.id ?? upload.remoteIdentifier
        }
    }

    static func fileUsageBatches(_ fileIDs: [String]) -> [[String]] {
        var seen = Set<String>()
        let unique = fileIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: 10).map { offset in
            Array(unique[offset..<min(offset + 10, unique.count)])
        }
    }

    private func deleteRemoteFile(_ file: UploadedFile) async throws {
        let deletion = try FileDeletionDTO(file: file)
        let request = try APIRequest<DeleteFilesResponseDTO>(
            method: .delete,
            path: "api/files",
            body: DeleteFilesRequestDTO(files: [deletion]),
            retryPolicy: .never
        )
        _ = try await runtime.restClient.send(request)
    }

    /// Streams the multipart body to a staging file: small text fields are
    /// written directly, and the staged attachment bytes are copied through
    /// in bounded chunks.
    static func writeMultipartBodyFile(for upload: PendingUpload, boundary: String) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatUploadBodies", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bodyURL = staging.appending(path: "\(upload.id.uuidString).body")
        try Data().write(to: bodyURL)
        let handle = try FileHandle(forWritingTo: bodyURL)
        do {
            var fields = Data()
            appendField(name: "endpoint", value: upload.endpoint ?? "", boundary: boundary, to: &fields)
            appendField(name: "endpointType", value: upload.endpointType ?? "", boundary: boundary, to: &fields)
            appendField(name: "file_id", value: upload.id.uuidString, boundary: boundary, to: &fields)
            appendField(name: "message_file", value: "true", boundary: boundary, to: &fields)
            if let conversationID = upload.conversationID, !conversationID.isLocalDraft {
                appendField(name: "conversationId", value: conversationID.rawValue, boundary: boundary, to: &fields)
            }
            if upload.isTemporary == true {
                appendField(name: "isTemporary", value: "true", boundary: boundary, to: &fields)
            }
            if let width = upload.width {
                appendField(name: "width", value: String(width), boundary: boundary, to: &fields)
            }
            if let height = upload.height {
                appendField(name: "height", value: String(height), boundary: boundary, to: &fields)
            }
            try handle.write(contentsOf: fields)
            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            let encodedFilename = upload.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? upload.filename
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(encodedFilename)\"\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Type: \(upload.mimeType ?? "application/octet-stream")\r\n\r\n".utf8))

            let source = try FileHandle(forReadingFrom: upload.localURL)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        return bodyURL
    }

    static func multipartBody(fileData: Data, upload: PendingUpload, boundary: String) -> Data {
        var data = Data()
        appendField(name: "endpoint", value: upload.endpoint ?? "", boundary: boundary, to: &data)
        appendField(name: "endpointType", value: upload.endpointType ?? "", boundary: boundary, to: &data)
        appendField(name: "file_id", value: upload.id.uuidString, boundary: boundary, to: &data)
        appendField(name: "message_file", value: "true", boundary: boundary, to: &data)
        if let conversationID = upload.conversationID, !conversationID.isLocalDraft {
            appendField(name: "conversationId", value: conversationID.rawValue, boundary: boundary, to: &data)
        }
        if upload.isTemporary == true {
            appendField(name: "isTemporary", value: "true", boundary: boundary, to: &data)
        }
        if let width = upload.width {
            appendField(name: "width", value: String(width), boundary: boundary, to: &data)
        }
        if let height = upload.height {
            appendField(name: "height", value: String(height), boundary: boundary, to: &data)
        }
        data.append(Data("--\(boundary)\r\n".utf8))
        let encodedFilename = upload.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? upload.filename
        data.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(encodedFilename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(upload.mimeType ?? "application/octet-stream")\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }

    private static func appendField(name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    private func validate(
        byteCount: Int,
        mimeType: String,
        conversationID: ConversationID?,
        endpoint: String,
        endpointType: String?,
        configuration: FileConfigurationDTO?
    ) throws {
        guard let configuration else { return }
        let policy = Self.policy(
            from: configuration,
            endpoint: endpoint,
            endpointType: endpointType
        )
        if policy.disabled == true {
            throw LibreChatProtocolError.unsupported("File uploads are disabled for this model or agent.")
        }
        let sizeLimit = [policy.fileSizeLimit, configuration.serverFileSizeLimit]
            .compactMap { $0 }
            .min()
        if let sizeLimit, Int64(byteCount) > sizeLimit {
            // After the compaction pass this is final: reject with the
            // toast-worthy message naming the real server limit.
            throw FileUploadRejection(
                message: Self.sizeRejectionMessage(
                    byteCount: Int64(byteCount),
                    limit: sizeLimit
                )
            )
        }
        let pending = uploadsByID.values.filter {
            $0.conversationID == conversationID && $0.state != .cancelled && $0.state != .attached
        }
        if let fileLimit = policy.fileLimit, pending.count + 1 > fileLimit {
            throw FileUploadRejection(
                message: "This chat allows at most \(fileLimit) attached files."
            )
        }
        if let totalSizeLimit = policy.totalSizeLimit {
            let existingBytes = pending.reduce(Int64(0)) { partial, upload in
                partial + (Self.localFileSize(upload.localURL) ?? upload.remoteFile?.bytes ?? 0)
            }
            if existingBytes + Int64(byteCount) > totalSizeLimit {
                throw FileUploadRejection(
                    message: Self.sizeRejectionMessage(
                        byteCount: existingBytes + Int64(byteCount),
                        limit: totalSizeLimit,
                        isTotal: true
                    )
                )
            }
        }
        if let patterns = policy.supportedMimeTypes,
           !Self.matches(mimeType: mimeType, patterns: patterns) {
            throw LibreChatProtocolError.unsupported("This model or agent does not accept \(mimeType) files.")
        }
    }

    /// The per-upload byte limit the server enforces for this endpoint, in
    /// bytes (the raw config is converted by `mergedWithByteUnitsAndDefaults`).
    static func effectiveSizeLimit(
        configuration: FileConfigurationDTO?,
        endpoint: String,
        endpointType: String?
    ) -> Int64? {
        guard let configuration else { return nil }
        let policy = Self.policy(from: configuration, endpoint: endpoint, endpointType: endpointType)
        return [policy.fileSizeLimit, configuration.serverFileSizeLimit]
            .compactMap { $0 }
            .min()
    }

    static func sizeRejectionMessage(
        byteCount: Int64,
        limit: Int64,
        isTotal: Bool = false
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let prefix = isTotal ? "These attachments exceed this chat's total upload limit" : "This file is still larger than the server's upload limit"
        return "\(prefix) (\(formatter.string(fromByteCount: limit)))."
    }

    /// Re-encodes an oversized image at progressively smaller scales and
    /// qualities until it fits `byteLimit`. Returns nil when the data is not
    /// a decodable image or cannot realistically be compacted further —
    /// unsupported types are never altered.
    static func compactedUploadData(data: Data, mimeType: String, byteLimit: Int64) -> Data? {
        guard byteLimit > 0, data.count > byteLimit, mimeType.hasPrefix("image/") else { return nil }
        // Animated GIFs/HEIC sequences lose animation when re-encoded; leave
        // them untouched rather than silently changing what the user picked.
        guard mimeType != "image/gif", mimeType != "image/svg+xml",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let pixelSizes: [Int] = [0, 2_048, 1_600, 1_280, 1_024, 800, 640, 480]
        let qualities: [Double] = [0.85, 0.7, 0.55, 0.4, 0.3]
        for pixelSize in pixelSizes {
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if pixelSize > 0 {
                options[kCGImageSourceThumbnailMaxPixelSize] = pixelSize
            }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            for quality in qualities {
                guard let output = CFDataCreateMutable(nil, 0),
                      let destination = CGImageDestinationCreateWithData(
                          output,
                          UTType.jpeg.identifier as CFString,
                          1,
                          nil
                      ) else { return nil }
                CGImageDestinationAddImage(
                    destination,
                    image,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else { return nil }
                if Int64(CFDataGetLength(output)) <= byteLimit {
                    return output as Data
                }
            }
        }
        return nil
    }

    private func loadFileConfiguration() async throws -> FileConfigurationDTO? {
        if didLoadFileConfiguration { return fileConfiguration }
        do {
            let request = APIRequest<FileConfigurationDTO>(
                path: "api/files/config",
                retryPolicy: .idempotent(maximumAttempts: 2)
            )
            let rawConfiguration = try await runtime.restClient.send(request)
            // The route serves the raw admin config in MB units; every size
            // comparison below runs against the byte-unit merged form, exactly
            // like the web client's `mergeFileConfig` select pass.
            let merged = rawConfiguration.mergedWithByteUnitsAndDefaults()
            fileConfiguration = merged
            didLoadFileConfiguration = true
            return merged
        } catch LibreChatProtocolError.unauthorized {
            throw LibreChatProtocolError.unauthorized
        } catch let LibreChatProtocolError.httpStatus(status, _, _) where status == 404 || status == 405 {
            didLoadFileConfiguration = true
            return nil
        } catch {
            AppLog.uploads.error("Upload policy discovery failed; server validation remains authoritative.")
            return nil
        }
    }

    private static func policy(
        from configuration: FileConfigurationDTO,
        endpoint: String,
        endpointType: String?
    ) -> EndpointFileConfigurationDTO {
        let endpoints = configuration.endpoints ?? [:]
        let base = endpoints["default"] ?? EndpointFileConfigurationDTO()
        let selected: EndpointFileConfigurationDTO? = {
            if let endpointType, let value = endpoints[endpointType] { return value }
            if let value = endpoints[endpoint] { return value }
            if endpointType == "custom" {
                return endpoints["custom"] ?? endpoints["agents"]
            }
            if endpoint == "agents" { return endpoints["agents"] }
            return nil
        }()
        guard let selected else { return base }
        return EndpointFileConfigurationDTO(
            disabled: selected.disabled ?? base.disabled,
            fileLimit: selected.fileLimit ?? base.fileLimit,
            fileSizeLimit: selected.fileSizeLimit ?? base.fileSizeLimit,
            totalSizeLimit: selected.totalSizeLimit ?? base.totalSizeLimit,
            supportedMimeTypes: selected.supportedMimeTypes ?? base.supportedMimeTypes
        )
    }

    private static func matches(mimeType: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let range = NSRange(mimeType.startIndex..<mimeType.endIndex, in: mimeType)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            if expression.firstMatch(in: mimeType, range: range) != nil { return true }
        }
        return false
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Attachment" }
        // The staged destination is "UUID-filename" (37-byte prefix) and
        // APFS NAME_MAX is 255 bytes, so truncate by encoded byte length —
        // a grapheme cap lets multibyte names overflow the limit.
        var byteCount = 0
        var bounded = Substring()
        for character in cleaned {
            let length = String(character).utf8.count
            if byteCount + length > 180 { break }
            byteCount += length
            bounded.append(character)
        }
        return String(bounded)
    }

    private static func mimeType(for filename: String, supplied: String?) -> String {
        if let supplied, !supplied.isEmpty { return supplied }
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func localFileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func imageDimensions(data: Data, mimeType: String) -> (width: Int, height: Int)? {
        guard mimeType.hasPrefix("image/"),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Server-supplied account identifiers are opaque strings, never path
    /// structure: encoding keeps a hostile id like `../..` inside the account
    /// directory namespace instead of escaping it.
    private static func safePathComponent(_ raw: String) -> String {
        String(raw.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        })
    }

    static func preparedUploadData(
        data: Data,
        mimeType: String,
        configuration: FileConfigurationDTO?
    ) throws -> (data: Data, mimeType: String) {
        guard mimeType.hasPrefix("image/"),
              let resize = configuration?.clientImageResize,
              resize.enabled == true else {
            return (data, mimeType)
        }
        let maximumWidth = resize.maxWidth.flatMap { $0 > 0 ? $0 : nil } ?? 1_900
        let maximumHeight = resize.maxHeight.flatMap { $0 > 0 ? $0 : nil } ?? 1_900
        let quality = min(max(resize.quality ?? 0.92, 0), 1)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0 else {
            throw LibreChatProtocolError.unsupported("That image could not be prepared for upload.")
        }
        let ratio = min(1, min(Double(maximumWidth) / width, Double(maximumHeight) / height))
        guard ratio < 1 else { return (data, mimeType) }
        // Animated (multi-frame) sources pass through untouched: rendering
        // frame zero into a single-frame JPEG would silently strip the
        // animation before the compaction guard for animated formats runs.
        guard CGImageSourceGetCount(source) <= 1 else { return (data, mimeType) }
        let maximumPixelSize = max(1, Int(floor(max(width * ratio, height * ratio))))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            throw LibreChatProtocolError.unsupported("That image could not be prepared for upload.")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw LibreChatProtocolError.unsupported("That image could not be prepared for upload.")
        }
        return (output as Data, UTType.jpeg.preferredMIMEType ?? "image/jpeg")
    }
}
