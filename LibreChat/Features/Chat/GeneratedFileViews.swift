import LibreChatDomain
import LibreChatProtocol
import SwiftUI

enum GeneratedFilePreviewPollingFailureDisposition: Equatable, Sendable {
    case retry
    case stop
    case unauthorized

    static func classify(_ error: Error) -> Self {
        guard let protocolError = error as? LibreChatProtocolError else { return .stop }
        switch protocolError {
        case .unauthorized, .httpStatus(401, _, _):
            return .unauthorized
        case .transport, .serverNotReady:
            return .retry
        case let .httpStatus(status, _, _) where (500..<600).contains(status):
            return .retry
        case .invalidResponse, .decoding, .encoding, .generationConflict,
             .unsupported, .keychain, .responseTooLarge, .httpStatus:
            return .stop
        }
    }
}

/// One active-chat, in-memory poll coordinator. It intentionally owns no
/// persistence: preview text is compatibility UI state and the server file is
/// authoritative. Chat/profile lifetime controls this actor's lifetime.
actor GeneratedFilePreviewPollingCoordinator {
    struct Configuration: Equatable, Sendable {
        var interval: Duration = .milliseconds(2_500)
        var maximumConsecutiveFailures = 5
    }

    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias Update = @MainActor @Sendable (GeneratedFile) async -> Void
    typealias Unauthorized = @MainActor @Sendable () async -> Void

    private let repository: any GeneratedFileRepository
    private let configuration: Configuration
    private let sleep: Sleep
    private let onUpdate: Update
    private let onUnauthorized: Unauthorized
    private var latestFiles: [String: GeneratedFile] = [:]
    private var operationIDs: [String: UUID] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Prevent an unrelated message update from immediately restarting a file
    /// that hit its bounded error ceiling. Scene inactivity clears this set so
    /// foregrounding performs a fresh reconciliation pass.
    private var suppressedFileIDs: Set<String> = []

    init(
        repository: any GeneratedFileRepository,
        configuration: Configuration = .init(),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        onUpdate: @escaping Update,
        onUnauthorized: @escaping Unauthorized
    ) {
        self.repository = repository
        self.configuration = configuration
        self.sleep = sleep
        self.onUpdate = onUpdate
        self.onUnauthorized = onUnauthorized
    }

    func synchronize(files: [GeneratedFile], isActive: Bool) {
        guard isActive else {
            stop(resetSuppression: true)
            return
        }

        var desired: [String: GeneratedFile] = [:]
        for file in files where file.lifecycle == .pending {
            guard let fileID = file.fileID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fileID.isEmpty else { continue }
            if desired[fileID] == nil { desired[fileID] = file }
        }
        let previousFiles = latestFiles
        // The preview route is keyed by file ID, but a card's message/tool
        // provenance is still its ownership fence. If the visible owner for a
        // pending ID changes, stop the old poll before immediately starting a
        // fresh one from the replacement card.
        for (fileID, replacement) in desired
        where tasks[fileID] != nil
            && previousFiles[fileID].map({ !Self.hasSameOwnership($0, replacement) }) == true {
            cancel(fileID: fileID)
        }
        latestFiles = desired
        let desiredIDs = Set(desired.keys)
        suppressedFileIDs.formIntersection(desiredIDs)

        for fileID in Set(tasks.keys).subtracting(desiredIDs) {
            cancel(fileID: fileID)
        }
        for (fileID, file) in desired
        where tasks[fileID] == nil && !suppressedFileIDs.contains(fileID) {
            start(fileID: fileID, file: file)
        }
    }

    func stop(resetSuppression: Bool = true) {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        operationIDs.removeAll()
        latestFiles.removeAll()
        if resetSuppression { suppressedFileIDs.removeAll() }
    }

    private func start(fileID: String, file: GeneratedFile) {
        let operationID = UUID()
        latestFiles[fileID] = file
        operationIDs[fileID] = operationID
        tasks[fileID] = Task { [weak self] in
            await self?.poll(fileID: fileID, operationID: operationID)
        }
    }

    private func cancel(fileID: String) {
        tasks.removeValue(forKey: fileID)?.cancel()
        operationIDs.removeValue(forKey: fileID)
        latestFiles.removeValue(forKey: fileID)
    }

    private static func hasSameOwnership(_ lhs: GeneratedFile, _ rhs: GeneratedFile) -> Bool {
        lhs.identity == rhs.identity
            && lhs.provenance.messageID == rhs.provenance.messageID
            && lhs.provenance.conversationID == rhs.provenance.conversationID
            && lhs.provenance.toolCallID == rhs.provenance.toolCallID
            && lhs.provenance.agentID == rhs.provenance.agentID
    }

    private func poll(fileID: String, operationID: UUID) async {
        var consecutiveFailures = 0
        defer {
            if operationIDs[fileID] == operationID {
                operationIDs.removeValue(forKey: fileID)
                tasks.removeValue(forKey: fileID)
            }
        }

        // A terminally failed poller must not leave the file "Preparing"
        // forever: publishing the failed lifecycle exposes the sheet's
        // manual refresh action for recovery.
        func markTerminalFailure(_ failedFileID: String) {
            guard var failed = latestFiles[failedFileID],
                  failed.lifecycle == .pending else { return }
            failed.lifecycle = .failed
            latestFiles[failedFileID] = failed
            Task { await onUpdate(failed) }
        }

        while !Task.isCancelled,
              operationIDs[fileID] == operationID,
              let source = latestFiles[fileID],
              source.lifecycle == .pending {
            do {
                let updated = try await repository.refreshGeneratedFile(source)
                guard !Task.isCancelled, operationIDs[fileID] == operationID else { return }
                latestFiles[fileID] = updated
                consecutiveFailures = 0
                await onUpdate(updated)
                guard updated.lifecycle == .pending else { return }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, operationIDs[fileID] == operationID else { return }
                switch GeneratedFilePreviewPollingFailureDisposition.classify(error) {
                case .unauthorized:
                    suppressedFileIDs.insert(fileID)
                    await onUnauthorized()
                    return
                case .stop:
                    // 404/malformed previews never recover on their own:
                    // publishing a terminal failed lifecycle stops the
                    // "Preparing" limbo and exposes the sheet's refresh.
                    suppressedFileIDs.insert(fileID)
                    markTerminalFailure(fileID)
                    return
                case .retry:
                    consecutiveFailures += 1
                    guard consecutiveFailures < configuration.maximumConsecutiveFailures else {
                        // Transient transport flakiness keeps the
                        // foreground-resume recovery path.
                        suppressedFileIDs.insert(fileID)
                        return
                    }
                }
            }

            do {
                try await sleep(configuration.interval)
            } catch {
                return
            }
        }
    }
}

struct GeneratedFileSheetSelection: Identifiable, Equatable, Hashable, Sendable {
    let file: GeneratedFile

    var id: GeneratedFileIdentity { file.identity }
}

enum GeneratedFileNativePreviewPolicy: Equatable, Sendable {
    case plainText
    case downloadOnly(reason: String)

    init(file: GeneratedFile) {
        guard file.text != nil else {
            self = .downloadOnly(reason: "LibreChat has not provided preview text for this file.")
            return
        }
        switch file.textFormat?.lowercased() {
        case "html":
            self = .downloadOnly(reason: "HTML file previews are not executed in the native app.")
        case "text", nil, "":
            self = .plainText
        default:
            self = .downloadOnly(reason: "This preview format is not supported safely yet.")
        }
    }

    var supportsPreview: Bool {
        if case .plainText = self { return true }
        return false
    }
}

struct GeneratedFilePreviewFailurePresentation: Equatable, Sendable {
    let message: String

    init(code: String?) {
        switch code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "timeout":
            message = "LibreChat timed out while preparing this preview. The file may still be downloadable."
        case "parser-error":
            message = "LibreChat could not read this file for a preview. The original file may still be downloadable."
        case "orphaned":
            message = "Preview preparation did not finish. The original file may still be downloadable."
        case "unexpected":
            message = "LibreChat encountered an unexpected preview error. The file may still be downloadable."
        default:
            message = "LibreChat could not prepare a preview. The file may still be downloadable."
        }
    }
}

struct GeneratedFilePresentation: Equatable, Sendable {
    let typeLabel: String
    let statusLabel: String
    let systemImage: String

    init(file: GeneratedFile) {
        typeLabel = Self.typeLabel(file)
        switch file.lifecycle {
        case .pending:
            statusLabel = "Preparing"
            systemImage = "clock.badge"
        case .ready:
            statusLabel = "Ready"
            systemImage = "doc.badge.checkmark"
        case .failed:
            statusLabel = "Preview failed"
            systemImage = "doc.badge.ellipsis"
        case .legacy:
            statusLabel = "Available"
            systemImage = "doc.fill"
        }
    }

    private static func typeLabel(_ file: GeneratedFile) -> String {
        guard let mime = file.mimeType?.lowercased(), !mime.isEmpty else {
            return "Generated file"
        }
        if mime == "application/pdf" { return "PDF" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "Spreadsheet" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "Presentation" }
        if mime.contains("wordprocessing") || mime.contains("msword") { return "Document" }
        if mime.hasPrefix("image/") { return "Image" }
        if mime.hasPrefix("text/") { return "Text" }
        return "Generated file"
    }
}

struct GeneratedFileCardView: View {
    let file: GeneratedFile
    let action: () -> Void

    private var presentation: GeneratedFilePresentation {
        GeneratedFilePresentation(file: file)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: presentation.systemImage)
                    .font(.title3)
                    .foregroundStyle(file.lifecycle == .failed ? Color.orange : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if file.lifecycle == .pending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(12)
            .frame(minHeight: 56)
            .background(
                Color(uiColor: .tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Generated file \(file.filename), \(presentation.statusLabel), \(presentation.typeLabel)")
        .accessibilityHint("Opens generated file details")
        .accessibilityIdentifier("generated-file-\(file.identity.resourceID)")
    }

    private var metadata: String {
        var parts = [presentation.typeLabel, presentation.statusLabel]
        if let bytes = file.bytes {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}

struct GeneratedFileSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let selection: GeneratedFileSheetSelection
    let currentFile: GeneratedFile
    let refresh: (GeneratedFile) async throws -> GeneratedFile
    let download: (GeneratedFile) async throws -> DownloadedGeneratedFile

    @State private var file: GeneratedFile
    @State private var downloaded: DownloadedGeneratedFile?
    @State private var isRefreshing = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var operationTask: Task<Void, Never>?

    init(
        selection: GeneratedFileSheetSelection,
        currentFile: GeneratedFile,
        refresh: @escaping (GeneratedFile) async throws -> GeneratedFile,
        download: @escaping (GeneratedFile) async throws -> DownloadedGeneratedFile
    ) {
        self.selection = selection
        self.currentFile = currentFile
        self.refresh = refresh
        self.download = download
        _file = State(initialValue: selection.file)
    }

    private var policy: GeneratedFileNativePreviewPolicy {
        GeneratedFileNativePreviewPolicy(file: file)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    preview
                    actions
                }
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(file.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let downloaded {
                        ShareLink(item: downloaded.localURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share downloaded file")
                    }
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: currentFile) { _, updated in file = updated }
        .onDisappear { operationTask?.cancel() }
        .alert("Generated file", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The generated-file action failed.")
        }
    }

    private var header: some View {
        let presentation = GeneratedFilePresentation(file: file)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.filename).font(.headline)
                Text([presentation.typeLabel, presentation.statusLabel]
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let bytes = file.bytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preview: some View {
        switch file.lifecycle {
        case .pending:
            Label("LibreChat is still preparing this file.", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .failed:
            Label(
                GeneratedFilePreviewFailurePresentation(code: file.previewError).message,
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
        case .ready, .legacy:
            switch policy {
            case .plainText:
                Text(file.text ?? "")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .accessibilityLabel("Generated file preview")
                if file.previewTruncated {
                    Label(
                        "Preview shortened to \(GeneratedFile.maximumPreviewCharacters.formatted()) characters. Download the file to inspect the complete content.",
                        systemImage: "text.badge.ellipsis"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case let .downloadOnly(reason):
                Label(reason, systemImage: "shield.lefthalf.filled")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Pending files are already owned by the active-chat coordinator.
            // Keeping a second manual request path here could overlap its
            // single in-flight poll. A terminal failure is no longer polled,
            // so an explicit user retry remains safe.
            if file.fileID != nil, file.lifecycle == .failed {
                Button { refreshPreview() } label: {
                    Label(isRefreshing ? "Checking…" : "Check preview again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing || isDownloading)
            }

            Button { downloadFile() } label: {
                Label(isDownloading ? "Downloading…" : "Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDownloading || isRefreshing || !canDownload)

            if let downloaded {
                Label("Downloaded \(ByteCountFormatter.string(fromByteCount: downloaded.bytes, countStyle: .file))", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canDownload: Bool {
        file.fileID?.isEmpty == false
            || (file.provenance.sessionID?.isEmpty == false
                && file.provenance.codeDownloadPath?.isEmpty == false)
    }

    private func refreshPreview() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            defer { isRefreshing = false }
            do { file = try await refresh(file) }
            catch is CancellationError { return }
            catch { errorMessage = error.userFacingMessage }
        }
    }

    private func downloadFile() {
        guard !isDownloading, canDownload else { return }
        isDownloading = true
        errorMessage = nil
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            defer { isDownloading = false }
            do { downloaded = try await download(file) }
            catch is CancellationError { return }
            catch { errorMessage = error.userFacingMessage }
        }
    }
}
