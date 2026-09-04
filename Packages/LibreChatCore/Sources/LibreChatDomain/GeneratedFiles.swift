import Foundation

/// The deferred-preview lifecycle is deliberately explicit. Older file
/// records predate `status`; they remain usable and are treated as ready
/// without pretending the server actually sent a lifecycle value.
public enum GeneratedFileLifecycle: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case ready
    case failed
    case legacy
}

public enum GeneratedFileError: LocalizedError, Equatable, Sendable {
    case unavailable
    case missingServerIdentifier
    case invalidDownload
    case failed(String?)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Generated-file actions are unavailable in this context."
        case .missingServerIdentifier:
            "This generated file does not include a usable server identifier."
        case .invalidDownload:
            "LibreChat returned an invalid generated-file download."
        case let .failed(reason):
            reason?.isEmpty == false ? reason : "LibreChat could not prepare this generated file."
        }
    }
}

/// The server scopes a generated file by the backing file identifier (or its
/// legacy path) *and* the producing tool/agent. Do not collapse two files
/// simply because their `file_id` matches: a non-null tool or agent identity
/// represents a separate output slot in an agent run.
public struct GeneratedFileIdentity: Codable, Equatable, Hashable, Sendable {
    public let resourceID: String
    public let toolCallID: String?
    public let agentID: String?

    public init(resourceID: String, toolCallID: String? = nil, agentID: String? = nil) {
        self.resourceID = resourceID
        self.toolCallID = toolCallID
        self.agentID = agentID
    }
}

/// Enough provenance to route a generated-file update to the response that
/// displayed it, while retaining code-environment fallback coordinates.
public struct GeneratedFileProvenance: Codable, Equatable, Hashable, Sendable {
    public var messageID: MessageID?
    public var conversationID: ConversationID?
    public var toolCallID: String?
    public var agentID: String?
    public var sessionID: String?
    /// A server-provided `/api/files/code/download/:session/:file` alias.
    /// This is a fallback descriptor only; it is not a trusted external URL.
    public var codeDownloadPath: String?

    public init(
        messageID: MessageID? = nil,
        conversationID: ConversationID? = nil,
        toolCallID: String? = nil,
        agentID: String? = nil,
        sessionID: String? = nil,
        codeDownloadPath: String? = nil
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.agentID = agentID
        self.sessionID = sessionID
        self.codeDownloadPath = codeDownloadPath
    }
}

/// A server-generated output attachment. This intentionally differs from an
/// input `UploadedFile`: it can be updated in-place as background preview
/// extraction progresses from pending to ready or failed.
public struct GeneratedFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Preview text is display-only compatibility data, not an authoritative
    /// copy of the generated file. Bound it before the value can enter app
    /// state so an unexpectedly large provider payload cannot expand every
    /// message snapshot that carries the attachment.
    public static let maximumPreviewCharacters = 50_000

    public let identity: GeneratedFileIdentity
    public var fileID: String?
    public var filepath: String?
    /// Some Responses events call the filepath `url`; retain the alias as a
    /// path rather than treating it as a universally safe, external URL.
    public var urlAlias: String?
    public var filename: String
    public var mimeType: String?
    public var bytes: Int64?
    public var text: String?
    public var textFormat: String?
    public var previewTruncated: Bool
    public var previewError: String?
    public var lifecycle: GeneratedFileLifecycle
    public var provenance: GeneratedFileProvenance

    public var id: GeneratedFileIdentity { identity }

    public init(
        fileID: String? = nil,
        filepath: String? = nil,
        urlAlias: String? = nil,
        filename: String = "Generated file",
        mimeType: String? = nil,
        bytes: Int64? = nil,
        text: String? = nil,
        textFormat: String? = nil,
        previewTruncated: Bool = false,
        previewError: String? = nil,
        lifecycle: GeneratedFileLifecycle = .legacy,
        provenance: GeneratedFileProvenance = .init()
    ) {
        // The compatibility contract keys a generated output by
        // `(file_id ?? filepath)`. `urlAlias` is display/transport metadata;
        // callers normalize the server's `url` alias into `filepath` first.
        let resourceID = fileID?.nonEmptyGeneratedFileID
            ?? filepath?.nonEmptyGeneratedFileID
            ?? "unknown-generated-file"
        self.identity = GeneratedFileIdentity(
            resourceID: resourceID,
            toolCallID: provenance.toolCallID,
            agentID: provenance.agentID
        )
        self.fileID = fileID
        self.filepath = filepath
        self.urlAlias = urlAlias
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
        let boundedText = text.map { String($0.prefix(Self.maximumPreviewCharacters)) }
        self.text = boundedText
        self.textFormat = textFormat
        self.previewTruncated = previewTruncated
            || text.map { $0.count > Self.maximumPreviewCharacters } == true
        self.previewError = previewError
        self.lifecycle = lifecycle
        self.provenance = provenance
    }

    /// Adds coordinates supplied by an enclosing historical message without
    /// replacing attachment-level provenance. The reconstructed identity is
    /// unchanged because message/conversation coordinates are not identity
    /// dimensions for generated output slots.
    public func applyingProvenanceFallback(
        messageID: MessageID?,
        conversationID: ConversationID?
    ) -> GeneratedFile {
        return GeneratedFile(
            fileID: fileID,
            filepath: filepath,
            urlAlias: urlAlias,
            filename: filename,
            mimeType: mimeType,
            bytes: bytes,
            text: text,
            textFormat: textFormat,
            previewTruncated: previewTruncated,
            previewError: previewError,
            lifecycle: lifecycle,
            provenance: GeneratedFileProvenance(
                messageID: provenance.messageID ?? messageID,
                conversationID: provenance.conversationID ?? conversationID,
                toolCallID: provenance.toolCallID,
                agentID: provenance.agentID,
                sessionID: provenance.sessionID,
                codeDownloadPath: provenance.codeDownloadPath
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case identity, fileID, filepath, urlAlias, filename, mimeType, bytes, text, textFormat, previewTruncated, previewError, lifecycle, provenance
    }

    /// Explicit decoding preserves caches written before this type introduced
    /// a lifecycle field. Missing lifecycle means legacy/ready-compatible.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try container.decodeIfPresent(String.self, forKey: .fileID)
        filepath = try container.decodeIfPresent(String.self, forKey: .filepath)
        urlAlias = try container.decodeIfPresent(String.self, forKey: .urlAlias)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "Generated file"
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes)
        let decodedText = try container.decodeIfPresent(String.self, forKey: .text)
        text = decodedText.map { String($0.prefix(Self.maximumPreviewCharacters)) }
        textFormat = try container.decodeIfPresent(String.self, forKey: .textFormat)
        previewTruncated = (try container.decodeIfPresent(Bool.self, forKey: .previewTruncated) ?? false)
            || decodedText.map { $0.count > Self.maximumPreviewCharacters } == true
        previewError = try container.decodeIfPresent(String.self, forKey: .previewError)
        lifecycle = try container.decodeIfPresent(GeneratedFileLifecycle.self, forKey: .lifecycle) ?? .legacy
        provenance = try container.decodeIfPresent(GeneratedFileProvenance.self, forKey: .provenance) ?? .init()
        identity = try container.decodeIfPresent(GeneratedFileIdentity.self, forKey: .identity)
            ?? GeneratedFileIdentity(
                resourceID: fileID?.nonEmptyGeneratedFileID
                    ?? filepath?.nonEmptyGeneratedFileID
                    ?? "unknown-generated-file",
                toolCallID: provenance.toolCallID,
                agentID: provenance.agentID
            )
    }
}

/// A profile/account-scoped local copy created only after an explicit user
/// download. Conversation caches retain metadata, never the downloaded bytes.
public struct DownloadedGeneratedFile: Codable, Equatable, Hashable, Sendable {
    public let profileID: ServerProfileID
    public let accountID: AccountID
    public let sourceIdentity: GeneratedFileIdentity
    public let localURL: URL
    public let filename: String
    public let mimeType: String?
    public let bytes: Int64

    public init(
        profileID: ServerProfileID,
        accountID: AccountID,
        sourceIdentity: GeneratedFileIdentity,
        localURL: URL,
        filename: String,
        mimeType: String? = nil,
        bytes: Int64
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.sourceIdentity = sourceIdentity
        self.localURL = localURL
        self.filename = filename
        self.mimeType = mimeType
        self.bytes = bytes
    }
}

/// Applies history, stream, and preview-poll updates through one identity
/// policy. A matching file/legacy path may be promoted to `file_id`, but only
/// within the same tool/agent slot.
public struct GeneratedFileReducer: Sendable {
    public private(set) var files: [GeneratedFile]

    public init(files: [GeneratedFile] = []) {
        self.files = files
    }

    @discardableResult
    public mutating func upsert(_ incoming: GeneratedFile) -> [GeneratedFile] {
        let exactMatches = files.indices.filter { files[$0].identity == incoming.identity }
        let compatibleMatches = files.indices.filter { sameSlot(files[$0], incoming) }
        // Nil tool/agent coordinates are wildcards in the legacy SSE wire
        // shape. Even if one bare card happens to be an exact identity match,
        // do not choose it when the same update could target another scoped
        // slot. Only authenticated preview reconciliation may fan a lifecycle
        // update out across a shared file ID.
        guard compatibleMatches.count <= 1 else { return files }
        if let index = exactMatches.count == 1
            ? exactMatches.first
            : compatibleMatches.first {
            files[index] = merged(existing: files[index], incoming: incoming)
        } else {
            files.append(incoming)
        }
        return files
    }

    /// Applies a response from the authenticated per-file preview endpoint to
    /// every card backed by that exact file record. Preview lifecycle is a
    /// property of `file_id`, while filename/path/tool/agent provenance remains
    /// a property of each rendered card.
    @discardableResult
    public mutating func applyPreview(_ incoming: GeneratedFile) -> [GeneratedFile] {
        guard let fileID = incoming.fileID?.nonEmptyGeneratedFileID else { return files }
        for index in files.indices where files[index].fileID == fileID {
            files[index] = merged(
                existing: files[index],
                incoming: incoming,
                preserveExistingProvenance: true
            )
        }
        return files
    }

    private func sameSlot(_ lhs: GeneratedFile, _ rhs: GeneratedFile) -> Bool {
        let lhsAliases = Set([lhs.fileID, lhs.filepath, lhs.urlAlias].compactMap { $0 })
        let rhsAliases = Set([rhs.fileID, rhs.filepath, rhs.urlAlias].compactMap { $0 })
        guard !lhsAliases.isDisjoint(with: rhsAliases) else { return false }
        let toolMatches = lhs.provenance.toolCallID == nil
            || rhs.provenance.toolCallID == nil
            || lhs.provenance.toolCallID == rhs.provenance.toolCallID
        let agentMatches = lhs.provenance.agentID == nil
            || rhs.provenance.agentID == nil
            || lhs.provenance.agentID == rhs.provenance.agentID
        return toolMatches && agentMatches
    }

    private func merged(
        existing: GeneratedFile,
        incoming: GeneratedFile,
        preserveExistingProvenance: Bool = false
    ) -> GeneratedFile {
        // A terminal server update is authoritative. Preserve useful fields
        // omitted by the minimal preview endpoint (name/provenance/path).
        let wouldRegressTerminal = (existing.lifecycle == .ready || existing.lifecycle == .failed)
            && incoming.lifecycle == .pending
        let lifecycle = wouldRegressTerminal
            ? existing.lifecycle
            : (incoming.lifecycle == .legacy ? existing.lifecycle : incoming.lifecycle)
        let mergedText = wouldRegressTerminal ? existing.text : (incoming.text ?? existing.text)
        let mergedTextFormat = wouldRegressTerminal
            ? existing.textFormat
            : (incoming.textFormat ?? existing.textFormat)
        let mergedPreviewError = wouldRegressTerminal
            ? existing.previewError
            : (incoming.previewError ?? existing.previewError)
        let mergedPreviewTruncated = wouldRegressTerminal || incoming.text == nil
            ? existing.previewTruncated
            : incoming.previewTruncated
        return GeneratedFile(
            fileID: incoming.fileID ?? existing.fileID,
            filepath: incoming.filepath ?? existing.filepath,
            urlAlias: incoming.urlAlias ?? existing.urlAlias,
            filename: incoming.filename == "Generated file" ? existing.filename : incoming.filename,
            mimeType: incoming.mimeType ?? existing.mimeType,
            bytes: incoming.bytes ?? existing.bytes,
            text: mergedText,
            textFormat: mergedTextFormat,
            previewTruncated: mergedPreviewTruncated,
            previewError: mergedPreviewError,
            lifecycle: lifecycle,
            provenance: GeneratedFileProvenance(
                messageID: preserveExistingProvenance
                    ? existing.provenance.messageID
                    : (incoming.provenance.messageID ?? existing.provenance.messageID),
                conversationID: preserveExistingProvenance
                    ? existing.provenance.conversationID
                    : (incoming.provenance.conversationID ?? existing.provenance.conversationID),
                toolCallID: preserveExistingProvenance
                    ? existing.provenance.toolCallID
                    : (incoming.provenance.toolCallID ?? existing.provenance.toolCallID),
                agentID: preserveExistingProvenance
                    ? existing.provenance.agentID
                    : (incoming.provenance.agentID ?? existing.provenance.agentID),
                sessionID: preserveExistingProvenance
                    ? existing.provenance.sessionID
                    : (incoming.provenance.sessionID ?? existing.provenance.sessionID),
                codeDownloadPath: preserveExistingProvenance
                    ? existing.provenance.codeDownloadPath
                    : (incoming.provenance.codeDownloadPath ?? existing.provenance.codeDownloadPath)
            )
        )
    }
}

private extension String {
    var nonEmptyGeneratedFileID: String? { isEmpty ? nil : self }
}
