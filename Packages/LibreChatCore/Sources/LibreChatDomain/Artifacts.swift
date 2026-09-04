import Foundation

/// The stable identity of an artifact in a persisted assistant message.
///
/// `identifier` is model-controlled and may be reused by the model when it
/// iterates on an artifact.  It is therefore not sufficient as a transport
/// identity: the server's edit endpoint addresses the artifact by its
/// document-order index, scoped to the message.
public struct ArtifactIdentity: Codable, Equatable, Hashable, Sendable {
    public let messageID: MessageID
    public let documentOrderIndex: Int

    public init(messageID: MessageID, documentOrderIndex: Int) {
        self.messageID = messageID
        self.documentOrderIndex = documentOrderIndex
    }
}

public struct ArtifactEditRequest: Codable, Equatable, Hashable, Sendable {
    public let identity: ArtifactIdentity
    public let conversationID: ConversationID
    public let originalContent: String
    public let updatedContent: String
    /// Omit unless temporary status is authoritative. Sending `false` can
    /// intentionally promote a temporary server message.
    public let isTemporary: Bool?

    public init(
        identity: ArtifactIdentity,
        conversationID: ConversationID,
        originalContent: String,
        updatedContent: String,
        isTemporary: Bool? = nil
    ) {
        self.identity = identity
        self.conversationID = conversationID
        self.originalContent = originalContent
        self.updatedContent = updatedContent
        self.isTemporary = isTemporary
    }
}

public enum ArtifactEditError: LocalizedError, Equatable, Sendable {
    case changedOnServer
    case messageNotFound
    case verificationRequired
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .changedOnServer:
            "This artifact changed on the server. Your edits are preserved; refresh and review them before saving again."
        case .messageNotFound:
            "The message containing this artifact is no longer available."
        case .verificationRequired:
            "LibreChat may have saved this edit, but the result could not be verified. Refresh before trying again."
        case .unavailable:
            "Artifact editing is unavailable in this context."
        }
    }
}

/// One parsed `:::artifact{...}` container.
///
/// The source body and complete container are retained exactly as parsed so a
/// later renderer or editor can preserve provider-specific syntax.  MIME is a
/// string rather than an enum because LibreChat advertises extensible viewer
/// types and adds internal preview MIME values over time.
public struct ParsedArtifact: Codable, Equatable, Hashable, Sendable {
    public let identity: ArtifactIdentity
    public let identifier: String
    public let mimeType: String
    public let title: String
    public let sourceContent: String
    public let rawContainer: String
    public let attributes: [String: String]

    public init(
        identity: ArtifactIdentity,
        identifier: String,
        mimeType: String,
        title: String,
        sourceContent: String,
        rawContainer: String,
        attributes: [String: String] = [:]
    ) {
        self.identity = identity
        self.identifier = identifier
        self.mimeType = mimeType
        self.title = title
        self.sourceContent = sourceContent
        self.rawContainer = rawContainer
        self.attributes = attributes
    }
}

/// Ordered message material after artifact extraction.  Keeping text and
/// artifacts in one ordered sequence prevents interleaved prose from being
/// flattened away when more than one artifact is present.
public enum ArtifactDocumentSegment: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case artifact(ParsedArtifact)

    private enum CodingKeys: String, CodingKey {
        case kind, text, artifact
    }

    private enum Kind: String, Codable {
        case text, artifact
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        case let .artifact(value):
            try container.encode(Kind.artifact, forKey: .kind)
            try container.encode(value, forKey: .artifact)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .artifact:
            self = .artifact(try container.decode(ParsedArtifact.self, forKey: .artifact))
        }
    }
}

public struct ParsedArtifactDocument: Codable, Equatable, Hashable, Sendable {
    public let messageID: MessageID
    public let rawText: String
    public let segments: [ArtifactDocumentSegment]
    /// The next server document-order coordinate after every raw artifact
    /// boundary encountered, including malformed and incomplete candidates.
    /// Callers use this value when continuing through another text content
    /// part so a renderability decision cannot change edit coordinates.
    public let nextDocumentOrderIndex: Int

    public init(
        messageID: MessageID,
        rawText: String,
        segments: [ArtifactDocumentSegment],
        nextDocumentOrderIndex: Int? = nil
    ) {
        self.messageID = messageID
        self.rawText = rawText
        self.segments = segments
        self.nextDocumentOrderIndex = nextDocumentOrderIndex
            ?? ((segments.compactMap {
                guard case let .artifact(artifact) = $0 else { return nil }
                return artifact.identity.documentOrderIndex
            }.max() ?? -1) + 1)
    }

    public var artifacts: [ParsedArtifact] {
        segments.compactMap {
            guard case let .artifact(artifact) = $0 else { return nil }
            return artifact
        }
    }
}

/// Pure parser for LibreChat's artifact directive containers.
///
/// A candidate is committed only after both the outer `:::` and any opening
/// code fence have been closed.  This is important for streaming: an
/// incomplete artifact remains ordinary text and cannot produce a partial or
/// unsafe viewer model.  Backtick and tilde fences are tracked independently
/// by marker and length, so a short nested fence cannot terminate a longer
/// artifact fence.
public enum ArtifactParser {
    /// Parses one message text/content part. Callers walking multiple text
    /// content parts must pass the running `startingDocumentOrderIndex`; the
    /// server numbers artifacts across the whole message, not independently
    /// inside each part.
    public static func parse(
        messageID: MessageID,
        text: String,
        startingDocumentOrderIndex: Int = 0
    ) -> ParsedArtifactDocument {
        var segments: [ArtifactDocumentSegment] = []
        var textCursor = text.startIndex
        var scanCursor = text.startIndex
        var documentOrderIndex = max(0, startingDocumentOrderIndex)

        while scanCursor < text.endIndex,
              let markerRange = text.range(of: ":::artifact", range: scanCursor..<text.endIndex) {
            let marker = markerRange.lowerBound
            let lineEnd = text[marker...].firstIndex(of: "\n") ?? text.endIndex
            let header = String(text[marker..<lineEnd])

            guard let close = findContainerClose(in: text, after: lineEnd) else {
                // Fail closed for a live/incomplete stream.  Keep all bytes
                // from this candidate as text and stop: a later marker could
                // be inside the unfinished artifact body.
                // The server still reserves one boundary through EOF, so the
                // next content part must start after this coordinate.
                documentOrderIndex += 1
                break
            }

            let artifactIndex = documentOrderIndex
            // The server's document-order index counts every closed artifact
            // boundary, even if a malformed directive cannot be rendered.
            // Keeping that coordinate prevents a later valid leaf from being
            // edited at the wrong server index.
            documentOrderIndex += 1
            guard let attributes = parseAttributes(header) else {
                scanCursor = close.end
                continue
            }
            guard let identifier = attributes["identifier"], !identifier.isEmpty,
                  let mimeType = attributes["type"], !mimeType.isEmpty,
                  let title = attributes["title"], !title.isEmpty else {
                scanCursor = close.end
                continue
            }

            appendText(from: textCursor, to: marker, in: text, into: &segments)
            let rawContainer = String(text[marker..<close.end])
            let bodyStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            let body = String(text[bodyStart..<close.start])
            let sourceContent = extractSourceContent(from: body)
            let artifact = ParsedArtifact(
                identity: ArtifactIdentity(
                    messageID: messageID,
                    documentOrderIndex: artifactIndex
                ),
                identifier: identifier,
                mimeType: mimeType,
                title: title,
                sourceContent: sourceContent,
                rawContainer: rawContainer,
                attributes: attributes
            )
            segments.append(.artifact(artifact))
            textCursor = close.end
            scanCursor = close.end
        }

        appendText(from: textCursor, to: text.endIndex, in: text, into: &segments)
        return ParsedArtifactDocument(
            messageID: messageID,
            rawText: text,
            segments: segments,
            nextDocumentOrderIndex: documentOrderIndex
        )
    }

    private struct RangePair {
        let start: String.Index
        let end: String.Index
    }

    private struct CodeFence {
        let marker: Character
        let length: Int
    }

    private static func findContainerClose(in text: String, after openingLineEnd: String.Index) -> RangePair? {
        var cursor = openingLineEnd < text.endIndex ? text.index(after: openingLineEnd) : text.endIndex
        var fence: CodeFence?
        var fallbackClose: RangePair?

        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[cursor..<lineEnd])
            let trimmed = line.drop { $0 == " " || $0 == "\t" || $0 == "\r" }

            if trimmed.hasPrefix(":::") {
                let candidate = String(trimmed)
                if !candidate.hasPrefix(":::artifact") {
                    let leading = line.distance(
                        from: line.startIndex,
                        to: line.firstIndex { $0 != " " && $0 != "\t" && $0 != "\r" } ?? line.endIndex
                    )
                    let markerStart = text.index(cursor, offsetBy: leading)
                    let close = RangePair(start: markerStart, end: text.index(markerStart, offsetBy: 3))
                    if fence == nil { return close }
                    fallbackClose = fallbackClose ?? close
                }
            }

            if let nextFence = parseFence(line), fence == nil {
                fence = nextFence
            } else if let activeFence = fence, isClosingFence(line, fence: activeFence) {
                fence = nil
                fallbackClose = nil
            }

            cursor = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return fence == nil ? fallbackClose : fallbackClose
    }

    private static func extractSourceContent(from body: String) -> String {
        guard let opening = firstFence(in: body) else { return body }
        guard let closing = closingFenceRange(in: body, after: opening) else { return body }
        let trailing = body[closing.upperBound...]
        guard trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return body }

        var end = closing.lowerBound
        if end > body.startIndex, body[body.index(before: end)] == "\n" {
            end = body.index(before: end)
        }
        return String(body[opening.contentStart..<end])
    }

    private struct FenceRange {
        let marker: Character
        let length: Int
        let contentStart: String.Index
    }

    private static func firstFence(in body: String) -> FenceRange? {
        var cursor = body.startIndex
        while cursor < body.endIndex {
            let lineEnd = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
            let line = String(body[cursor..<lineEnd])
            let firstNonWhitespace = line.firstIndex {
                $0 != " " && $0 != "\t" && $0 != "\r"
            }
            if firstNonWhitespace != nil,
               let fence = parseFence(line) {
                let contentStart = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
                return FenceRange(marker: fence.marker, length: fence.length, contentStart: contentStart)
            }
            // LibreChat only treats a fence on the first non-whitespace line
            // as the artifact wrapper. A later fence is ordinary source text.
            if firstNonWhitespace != nil { return nil }
            cursor = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return nil
    }

    private static func closingFenceRange(in body: String, after opening: FenceRange) -> Range<String.Index>? {
        var cursor = opening.contentStart
        while cursor < body.endIndex {
            let lineEnd = body[cursor...].firstIndex(of: "\n") ?? body.endIndex
            let line = String(body[cursor..<lineEnd])
            if isClosingFence(line, fence: CodeFence(marker: opening.marker, length: opening.length)) {
                return cursor..<lineEnd
            }
            cursor = lineEnd < body.endIndex ? body.index(after: lineEnd) : body.endIndex
        }
        return nil
    }

    private static func parseFence(_ line: String) -> CodeFence? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" || $0 == "\r" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        return CodeFence(marker: first, length: length)
    }

    private static func isClosingFence(_ line: String, fence: CodeFence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0 == fence.marker }),
              trimmed.count >= fence.length else { return false }
        return true
    }

    private static func parseAttributes(_ header: String) -> [String: String]? {
        let prefix = ":::artifact"
        guard header.hasPrefix(prefix) else { return nil }
        var index = header.index(header.startIndex, offsetBy: prefix.count)
        var end = header.endIndex
        while index < end, header[index].isWhitespace { index = header.index(after: index) }
        if index < end, header[index] == "{" {
            guard let closing = header.lastIndex(of: "}"), closing > index,
                  header[header.index(after: closing)...].allSatisfy({ $0.isWhitespace }) else {
                return nil
            }
            index = header.index(after: index)
            end = closing
        }
        var attributes: [String: String] = [:]

        while index < end {
            while index < end, header[index].isWhitespace { index = header.index(after: index) }
            guard index < end else { break }
            let keyStart = index
            while index < end, !header[index].isWhitespace, header[index] != "=" {
                index = header.index(after: index)
            }
            guard keyStart < index else { return nil }
            let key = String(header[keyStart..<index])
            while index < end, header[index].isWhitespace { index = header.index(after: index) }
            guard index < end, header[index] == "=" else { return nil }
            index = header.index(after: index)
            while index < end, header[index].isWhitespace { index = header.index(after: index) }
            guard index < end, header[index] == "\"" else { return nil }
            index = header.index(after: index)
            var value = ""
            var closed = false
            while index < end {
                let character = header[index]
                index = header.index(after: index)
                if character == "\"" {
                    closed = true
                    break
                }
                if character == "\\", index < end {
                    let escaped = header[index]
                    index = header.index(after: index)
                    value.append(escaped)
                } else {
                    value.append(character)
                }
            }
            guard closed else { return nil }
            attributes[key] = value
        }
        return attributes
    }

    private static func appendText(
        from start: String.Index,
        to end: String.Index,
        in text: String,
        into segments: inout [ArtifactDocumentSegment]
    ) {
        guard start < end else { return }
        let value = String(text[start..<end])
        guard !value.isEmpty else { return }
        if case let .text(existing) = segments.last {
            segments[segments.count - 1] = .text(existing + value)
        } else {
            segments.append(.text(value))
        }
    }
}
