import LibreChatDomain
import SwiftUI
import UIKit

struct FileLibraryView: View {
    @State private var model: FileLibraryModel
    private let repository: any FileLibraryRepository
    private let isOffline: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () async -> Void

    init(appModel: AppModel, repository: any FileLibraryRepository) {
        let isOffline: @MainActor () -> Bool = { appModel.isOffline }
        let originatingProfileID = appModel.selectedServer?.id
        let originatingAccountID = appModel.user?.id
        let onUnauthorized: @MainActor () async -> Void = {
            await appModel.expireSession(
                for: originatingProfileID,
                originatingAccountID: originatingAccountID
            )
        }
        self.repository = repository
        self.isOffline = isOffline
        self.onUnauthorized = onUnauthorized
        _model = State(initialValue: FileLibraryModel(
            repository: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .navigationTitle("Files")
            .searchable(text: $model.query, prompt: "Search files")
            .refreshable { await model.reload() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort files", selection: $model.sort) {
                            ForEach(FileLibrarySort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    }
                    .disabled(model.snapshot == nil)
                    .accessibilityIdentifier("file-library-sort")
                }
            }
        }
        .task { await model.loadIfNeeded() }
        .accessibilityIdentifier("file-library")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonListView(count: 7, horizontalPadding: 0, accessibilityLabel: "Loading files…")
                .listRowSeparator(.hidden)
        case .offline:
            ContentUnavailableView(
                "Files need a connection",
                systemImage: "wifi.slash",
                description: Text("The account file catalog is live server state and is not saved for offline browsing.")
            )
            .listRowSeparator(.hidden)
        case .forbidden:
            ContentUnavailableView(
                "Files unavailable",
                systemImage: "lock.shield",
                description: Text("This LibreChat account cannot browse the server file catalog.")
            )
            .listRowSeparator(.hidden)
        case .unavailable:
            ContentUnavailableView(
                "File library unsupported",
                systemImage: "doc.badge.ellipsis",
                description: Text("This LibreChat deployment does not expose the owner file catalog used by the native library.")
            )
            .listRowSeparator(.hidden)
        case .unauthorized:
            ContentUnavailableView(
                "Session expired",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Sign in again to view files.")
            )
            .listRowSeparator(.hidden)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t load files", systemImage: "doc.badge.ellipsis")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.reload() } }
            }
            .listRowSeparator(.hidden)
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let refreshError = model.refreshError {
            Section {
                Label(refreshError, systemImage: "arrow.clockwise.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let omittedCount = model.snapshot?.omittedCount, omittedCount > 0 {
            Section {
                Label(
                    "\(omittedCount) server file \(omittedCount == 1 ? "record was" : "records were") hidden because its identity or metadata was invalid.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("file-library-omitted-warning")
            }
        }

        if model.visibleItems.isEmpty {
            ContentUnavailableView(
                model.normalizedQuery.isEmpty ? "No files yet" : "No matching files",
                systemImage: "doc",
                description: Text(
                    model.normalizedQuery.isEmpty
                        ? "Files uploaded to this LibreChat account will appear here."
                        : "Try a different filename or file type."
                )
            )
            .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        FileLibraryDetailView(
                            item: item,
                            repository: repository,
                            isOffline: isOffline,
                            onUnauthorized: onUnauthorized,
                            onDeleted: { snapshot in
                                model.installReconciledSnapshot(snapshot)
                            }
                        )
                    } label: {
                        FileLibraryRow(item: item, repository: repository)
                    }
                    .accessibilityIdentifier("file-library-item-\(index)")
                }
            } header: {
                Text("This account")
            } footer: {
                Text("This is live metadata from the selected LibreChat account. The native app does not keep a separate offline file catalog.")
            }
        }
    }
}

private struct FileLibraryRow: View {
    let item: FileLibraryItem
    let repository: any FileLibraryRepository
    @State private var thumbnail: UIImage?

    private var isImageFile: Bool {
        item.file.mimeType?.lowercased().hasPrefix("image/") == true
    }

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.file.filename)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let date = item.updatedAt ?? item.createdAt {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.file.filename)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Opens file details.")
        .task(id: item.id) {
            guard isImageFile, thumbnail == nil else { return }
            thumbnail = await FileImagePreviewStore.thumbnail(
                item: item,
                repository: repository
            )
        }
    }

    private var metadata: String {
        let kind = FileLibraryPresentation.kindLabel(for: item)
        guard let bytes = FileLibraryPresentation.validBytes(item.file.bytes) else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var accessibilityValue: String {
        var values = [metadata, FileLibraryPresentation.contextLabel(for: item)]
        if let date = item.updatedAt ?? item.createdAt {
            values.append("Updated \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        return values.joined(separator: ", ")
    }

    private var symbol: String {
        switch FileLibraryPresentation.kindLabel(for: item) {
        case "Image": "photo"
        case "Audio": "waveform"
        case "Video": "film"
        case "PDF document": "doc.richtext"
        case "Spreadsheet": "tablecells"
        case "Presentation": "rectangle.on.rectangle"
        case "Archive": "archivebox"
        default: "doc"
        }
    }
}

private struct FileLibraryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let item: FileLibraryItem
    private let repository: any FileLibraryRepository
    private let onDeleted: @MainActor (FileLibrarySnapshot) -> Void
    @State private var previewModel: FilePreviewModel
    @State private var downloadModel: FileDownloadModel
    @State private var deletionModel: FileDeletionModel
    @State private var downloadTask: Task<Void, Never>?
    @State private var deletionTask: Task<Void, Never>?
    @State private var isConfirmingDeletion = false
    @State private var imagePreviewModel = FileImagePreviewModel()
    @State private var detailIsVisible = false

    init(
        item: FileLibraryItem,
        repository: any FileLibraryRepository,
        isOffline: @escaping @MainActor () -> Bool,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onDeleted: @escaping @MainActor (FileLibrarySnapshot) -> Void
    ) {
        self.item = item
        self.repository = repository
        self.onDeleted = onDeleted
        _previewModel = State(initialValue: FilePreviewModel(
            repository: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
        _downloadModel = State(initialValue: FileDownloadModel(
            repository: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
        _deletionModel = State(initialValue: FileDeletionModel(
            repository: repository,
            isOffline: isOffline,
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        List {
            Section {
                Label(item.file.filename, systemImage: "doc")
                    .font(.title3.bold())
                    .textSelection(.enabled)
            }

            Section("Details") {
                LabeledContent("Kind", value: FileLibraryPresentation.kindLabel(for: item))
                if let bytes = FileLibraryPresentation.validBytes(item.file.bytes) {
                    LabeledContent(
                        "Size",
                        value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    )
                }
                LabeledContent("Used as", value: FileLibraryPresentation.contextLabel(for: item))
                LabeledContent("Stored by", value: FileLibraryPresentation.sourceLabel(for: item))
                if let lifecycle = FileLibraryPresentation.lifecycleLabel(for: item) {
                    LabeledContent("Preview", value: lifecycle)
                }
                if let width = item.file.width, let height = item.file.height,
                   width > 0, height > 0 {
                    LabeledContent("Dimensions", value: "\(width) × \(height)")
                }
            }

            if item.createdAt != nil || item.updatedAt != nil || item.expiresAt != nil {
                Section("Dates") {
                    if let createdAt = item.createdAt {
                        LabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let updatedAt = item.updatedAt {
                        LabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let expiresAt = item.expiresAt {
                        LabeledContent("Server expiry", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section("Preview") {
                if isImageFile {
                    imagePreviewContent
                } else {
                    previewContent
                }
            }

            Section("Actions") {
                VStack(spacing: 14) {
                    if downloadShowsButton || deleteShowsButton {
                        HStack(spacing: 12) {
                            if downloadShowsButton {
                                Button {
                                    startDownload()
                                } label: {
                                    Label("Download", systemImage: "arrow.down")
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 30)
                                }
                                .adaptiveGlassButtonStyle()
                                .foregroundStyle(.primary)
                                .accessibilityHint("Downloads a local copy through your LibreChat account.")
                                .accessibilityIdentifier("file-download-action")
                            }
                            if deleteShowsButton {
                                Button {
                                    isConfirmingDeletion = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .foregroundStyle(.red)
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 30)
                                }
                                .adaptiveGlassButtonStyle()
                                .accessibilityHint("Asks for confirmation, then removes the file from your LibreChat account.")
                                .accessibilityIdentifier("file-delete-action")
                            }
                        }
                    }
                    downloadStatusContent
                    deleteStatusContent
                }
            }
        }
        .navigationTitle("File details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("file-library-detail")
        .task {
            // Images never consume the text preview; loading the two
            // sequentially would delay the actual image download behind an
            // unrelated (and potentially slow) text endpoint.
            if isImageFile {
                await imagePreviewModel.load(item: item, repository: repository)
            } else {
                await previewModel.loadIfNeeded(fileID: item.id)
            }
        }
        .confirmationDialog(
            "Delete “\(item.file.filename)”?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete file", role: .destructive) {
                startDeletion()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently requests removal from the selected LibreChat account. The app verifies the live server catalog before reporting success.")
        }
        .onAppear { detailIsVisible = true }
        .onDisappear {
            detailIsVisible = false
            downloadTask?.cancel()
            downloadModel.cancel()
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch previewModel.state {
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("Loading text preview…")
            }
            .accessibilityIdentifier("file-preview-loading")
        case .offline:
            Label("Reconnect to load this live preview.", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("file-preview-offline")
        case .processing:
            VStack(alignment: .leading, spacing: 10) {
                Label("LibreChat is still preparing this preview.", systemImage: "clock")
                    .foregroundStyle(.secondary)
                Button("Check again") {
                    Task { await previewModel.reload(fileID: item.id) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("file-preview-processing")
        case let .ready(preview):
            if let text = preview.text, !text.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if preview.format == .htmlSource {
                        Label("HTML source shown as inert text", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if preview.format == .unsupportedSource {
                        Label("Server preview shown as inert text", systemImage: "doc.plaintext")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("file-preview-text")
                    if preview.isTruncated {
                        Label("Preview shortened on this device", systemImage: "text.badge.minus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("file-preview-truncated")
                    }
                }
            } else {
                Label("No text preview is available for this file.", systemImage: "doc")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("file-preview-empty")
            }
        case .unavailable:
            Label("LibreChat could not provide a text preview for this file.", systemImage: "doc.badge.ellipsis")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("file-preview-unavailable")
        case .forbidden:
            Label("This account cannot open the file preview.", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("file-preview-forbidden")
        case .unsupported:
            Label("This LibreChat deployment does not support file previews.", systemImage: "doc.badge.ellipsis")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("file-preview-unsupported")
        case .unauthorized:
            Label("Your session expired. Sign in again to preview files.", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("file-preview-unauthorized")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await previewModel.reload(fileID: item.id) }
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("file-preview-failed")
        }
    }

    private var isImageFile: Bool {
        item.file.mimeType?.lowercased().hasPrefix("image/") == true
    }

    @ViewBuilder
    private var imagePreviewContent: some View {
        switch imagePreviewModel.state {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading preview…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("file-image-loading")
        case .ready(let image):
            ZoomableImagePreview(image: image)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("file-image-preview")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await imagePreviewModel.load(item: item, repository: repository) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var downloadShowsButton: Bool {
        if case .idle = downloadModel.state { return true }
        return false
    }

    private var deleteShowsButton: Bool {
        if case .idle = deletionModel.state { return true }
        return false
    }

    @ViewBuilder
    private var downloadStatusContent: some View {
        switch downloadModel.state {
        case .idle:
            EmptyView()
        case .downloading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Downloading securely…")
                Spacer()
                Button("Cancel", role: .cancel) {
                    downloadTask?.cancel()
                    downloadTask = nil
                    downloadModel.cancel()
                }
                .frame(minHeight: 44)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("file-download-progress")
        case let .ready(downloaded):
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    "Downloaded \(ByteCountFormatter.string(fromByteCount: downloaded.bytes, countStyle: .file))",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
                ShareLink(item: downloaded.localURL) {
                    Label("Share or save file", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens the system share sheet, including Save to Files when available.")
                .accessibilityIdentifier("file-download-share")
            }
        case .offline:
            downloadUnavailable(
                "Reconnect to download this file.",
                systemImage: "wifi.slash",
                canRetry: true
            )
        case .forbidden:
            downloadUnavailable(
                "This account no longer has permission to download this file.",
                systemImage: "lock.shield"
            )
        case .unavailable:
            downloadUnavailable(
                "This file cannot be downloaded from this LibreChat deployment.",
                systemImage: "doc.badge.ellipsis"
            )
        case .unauthorized:
            downloadUnavailable(
                "Your session expired. Sign in again to download files.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case let .failed(message):
            downloadUnavailable(message, systemImage: "exclamationmark.triangle", canRetry: true)
        }
    }

    @ViewBuilder
    private var deleteStatusContent: some View {
        switch deletionModel.state {
        case .idle:
            EmptyView()
        case .deleting:
            HStack(spacing: 12) {
                ProgressView()
                Text("Deleting and verifying…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("file-delete-progress")
        case .deleted:
            Label("File deleted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("file-delete-success")
        case let .retained(attempt):
            deletionFailure(
                attempt == .accepted
                    ? "LibreChat accepted the request but still lists this file. It may still be referenced or its storage deletion may have failed."
                    : "LibreChat still lists this file, so it was not deleted.",
                systemImage: "exclamationmark.triangle",
                canRetry: true
            )
        case .offline:
            deletionFailure(
                "Reconnect before deleting this server file.",
                systemImage: "wifi.slash",
                canRetry: true
            )
        case .forbidden:
            deletionFailure(
                "This account is not allowed to delete this file.",
                systemImage: "lock.shield"
            )
        case .unavailable:
            deletionFailure(
                "This file does not have the server metadata required for safe deletion.",
                systemImage: "doc.badge.ellipsis"
            )
        case .unauthorized:
            deletionFailure(
                "Your session expired. Sign in again before deleting files.",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        case .verificationRequired:
            deletionFailure(
                "The request may have reached LibreChat, but the app could not verify the result. Return to Files and refresh before making another deletion request.",
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
            )
        case let .failed(message):
            deletionFailure(message, systemImage: "exclamationmark.triangle", canRetry: true)
        }
    }

    private func deletionFailure(
        _ message: String,
        systemImage: String,
        canRetry: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button("Try deletion again") {
                    isConfirmingDeletion = true
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("Asks for confirmation before sending another deletion request.")
            }
        }
        .accessibilityIdentifier("file-delete-state")
    }

    private func downloadUnavailable(
        _ message: String,
        systemImage: String,
        canRetry: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canRetry {
                Button("Try again") { startDownload() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("file-download-unavailable")
    }

    private func startDownload() {
        downloadTask?.cancel()
        downloadTask = Task { @MainActor in
            await downloadModel.download(item)
            downloadTask = nil
        }
    }

    private func startDeletion() {
        guard deletionTask == nil else { return }
        let task = Task { @MainActor in
            defer { deletionTask = nil }
            guard let result = await deletionModel.delete(item) else {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "File deletion was not confirmed"
                )
                return
            }
            downloadModel.discardLocalCopy()
            onDeleted(result.snapshot)
            UIAccessibility.post(notification: .announcement, argument: "File deleted")
            if detailIsVisible { dismiss() }
        }
        deletionTask = task
    }
}


/// Authenticated image loading with a per-session memory cache. Full-size
/// images power the detail preview; thumbnails are downsampled for the list.
enum FileImagePreviewStore {
    private nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()
    private nonisolated(unsafe) static var generation = 0

    static func cachedImage(itemID: String) -> UIImage? {
        cache.object(forKey: itemID as NSString)
    }

    /// Writes are rejected when a session transition flushed the cache while
    /// this fetch was in flight.
    private static func cacheIfCurrent(_ image: UIImage, forKey key: NSString, fetchGeneration: Int) {
        guard fetchGeneration == generation else { return }
        cache.setObject(image, forKey: key)
    }

    /// Previews are authenticated downloads, so the cache is session-scoped:
    /// account and profile transitions flush it and invalidate in-flight
    /// writes, keeping one session from rendering another session's files.
    static func removeAllCachedImages() {
        generation &+= 1
        cache.removeAllObjects()
    }

    static func loadFull(
        item: FileLibraryItem,
        repository: any FileLibraryRepository
    ) async throws -> UIImage {
        if let cached = cache.object(forKey: item.id as NSString) { return cached }
        let fetchGeneration = generation
        let downloaded = try await repository.downloadFile(item)
        defer { try? FileManager.default.removeItem(at: downloaded.localURL) }
        // Highly compressed sources can decompress to hundreds of megabytes
        // at full resolution; cap the preview decode by pixel size.
        guard let source = CGImageSourceCreateWithURL(downloaded.localURL as CFURL, nil) else {
            throw LibrayImagePreviewError.unrenderable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LibrayImagePreviewError.unrenderable
        }
        let image = UIImage(cgImage: cgImage)
        cacheIfCurrent(image, forKey: item.id as NSString, fetchGeneration: fetchGeneration)
        return image
    }

    /// Automatic row previews never download large originals: a metadata
    /// size above this bound renders the generic icon instead, and the
    /// detail view stays the only explicit full download.
    static let maximumAutomaticThumbnailBytes = 25 * 1_048_576

    static func thumbnail(
        item: FileLibraryItem,
        repository: any FileLibraryRepository,
        maxPixel: CGFloat = 240
    ) async -> UIImage? {
        let thumbKey = "thumb:\(item.id)" as NSString
        if let cached = cache.object(forKey: thumbKey) { return cached }
        // Metadata-based guard: a large declared size skips the automatic
        // download entirely instead of transferring the original.
        if let declared = item.file.bytes, declared > maximumAutomaticThumbnailBytes {
            return nil
        }
        let fetchGeneration = generation
        let downloaded = try? await repository.downloadFile(item)
        guard let downloaded else { return nil }
        defer { try? FileManager.default.removeItem(at: downloaded.localURL) }
        // Downsample straight from the file with CGImageSource: decoding the
        // full-resolution source first can exhaust memory on huge images
        // while merely scrolling the list.
        guard let source = CGImageSourceCreateWithURL(downloaded.localURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: cgThumbnail)
        cacheIfCurrent(thumbnail, forKey: thumbKey, fetchGeneration: fetchGeneration)
        return thumbnail
    }
}

enum LibrayImagePreviewError: LocalizedError {
    case unrenderable
    var errorDescription: String? {
        switch self {
        case .unrenderable:
            return "LibreChat downloaded the file, but it could not be rendered as an image."
        }
    }
}

@MainActor
@Observable
final class FileImagePreviewModel {
    enum State {
        case idle
        case loading
        case ready(UIImage)
        case failed(String)
    }

    private(set) var state: State = .idle

    func load(item: FileLibraryItem, repository: any FileLibraryRepository) async {
        if case .ready = state { return }
        if case .loading = state { return }
        state = .loading
        do {
            state = .ready(try await FileImagePreviewStore.loadFull(item: item, repository: repository))
        } catch {
            state = .failed(error.userFacingMessage)
        }
    }
}

/// Pinch-to-zoom (1x-8x), pan while zoomed, double-tap to reset.
struct ZoomableImagePreview: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value.magnification, 1), 8)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            clampOffset(in: geometry.size)
                            if scale <= 1.01 { reset() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1.01 else { return }
                            offset = CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastOffset = offset
                            clampOffset(in: geometry.size)
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.snappy(duration: 0.2)) { reset() }
                }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("File preview")
        .accessibilityHint("Pinch to zoom, drag to pan, double-tap to reset.")
    }

    private func clampOffset(in size: CGSize) {
        let maxX = (size.width * (scale - 1)) / 2
        let maxY = (size.height * (scale - 1)) / 2
        offset = CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
        lastOffset = offset
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
