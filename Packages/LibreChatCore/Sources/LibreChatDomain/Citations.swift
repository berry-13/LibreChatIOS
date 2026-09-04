import Foundation

/// A lossless JSON value used by citation domain records. Citation providers
/// intentionally evolve their result shapes, so callers must not need to
/// flatten unknown provenance into strings merely to cache or replay it.
public enum CitationJSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CitationJSONValue])
    case object([String: CitationJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CitationJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CitationJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public enum CitationReferenceType: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case search
    case image
    case news
    case video
    case ref
    case file
}

/// A single source record as supplied by LibreChat's search/file-search
/// attachment. `raw` is the server provenance and is deliberately retained
/// alongside the small, renderer-safe projection.
public struct CitationReference: Codable, Equatable, Hashable, Sendable {
    public var type: CitationReferenceType
    public var title: String?
    public var link: URL?
    public var attribution: String?
    public var snippet: String?
    public var imageURL: URL?
    public var fileID: String?
    public var fileName: String?
    public var pages: [Int]?
    public var relevance: Double?
    public var pageRelevance: [String: Double]?
    public var raw: CitationJSONValue

    public init(
        type: CitationReferenceType,
        title: String? = nil,
        link: URL? = nil,
        attribution: String? = nil,
        snippet: String? = nil,
        imageURL: URL? = nil,
        fileID: String? = nil,
        fileName: String? = nil,
        pages: [Int]? = nil,
        relevance: Double? = nil,
        pageRelevance: [String: Double]? = nil,
        raw: CitationJSONValue
    ) {
        self.type = type
        self.title = title
        self.link = link
        self.attribution = attribution
        self.snippet = snippet
        self.imageURL = imageURL
        self.fileID = fileID
        self.fileName = fileName
        self.pages = pages
        self.relevance = relevance
        self.pageRelevance = pageRelevance
        self.raw = raw
    }
}

public struct WebSearchCitationData: Codable, Equatable, Hashable, Sendable {
    public var turn: Int?
    public var organic: [CitationReference]
    public var images: [CitationReference]
    /// LibreChat's citation `news` anchors resolve against `topStories`, not
    /// the provider's separate `news` category (which remains in `raw`).
    public var topStories: [CitationReference]
    public var videos: [CitationReference]
    public var references: [CitationReference]
    public var error: String?
    /// Includes unprojected provider categories and future fields.
    public var raw: CitationJSONValue

    public init(
        turn: Int? = nil,
        organic: [CitationReference] = [],
        images: [CitationReference] = [],
        topStories: [CitationReference] = [],
        videos: [CitationReference] = [],
        references: [CitationReference] = [],
        error: String? = nil,
        raw: CitationJSONValue
    ) {
        self.turn = turn
        self.organic = organic
        self.images = images
        self.topStories = topStories
        self.videos = videos
        self.references = references
        self.error = error
        self.raw = raw
    }

    public func references(for type: CitationReferenceType) -> [CitationReference] {
        switch type {
        case .search: organic
        case .image: images
        case .news: topStories
        case .video: videos
        case .ref: references
        case .file: []
        }
    }
}

public struct FileSearchCitationData: Codable, Equatable, Hashable, Sendable {
    public var sources: [CitationReference]
    public var raw: CitationJSONValue

    public init(sources: [CitationReference] = [], raw: CitationJSONValue) {
        self.sources = sources
        self.raw = raw
    }

    /// The raw source array remains lossless in `sources`. This projection
    /// mirrors LibreChat's display behavior: one card per file, pages merged
    /// and sorted, page relevance merged, and the greatest relevance kept.
    public func displaySources() -> [CitationReference] {
        var result: [CitationReference] = []
        var indices: [String: Int] = [:]
        for source in sources {
            guard let fileID = source.fileID, !fileID.isEmpty else {
                result.append(source)
                continue
            }
            guard let existingIndex = indices[fileID] else {
                indices[fileID] = result.count
                result.append(source)
                continue
            }
            var existing = result[existingIndex]
            let mergedPages = Set((existing.pages ?? []) + (source.pages ?? []))
            existing.pages = mergedPages.isEmpty ? nil : mergedPages.sorted()
            var mergedRelevance = existing.pageRelevance ?? [:]
            for (page, score) in source.pageRelevance ?? [:] {
                mergedRelevance[page] = score
            }
            existing.pageRelevance = mergedRelevance.isEmpty ? nil : mergedRelevance
            switch (existing.relevance, source.relevance) {
            case let (.some(left), .some(right)): existing.relevance = max(left, right)
            case (.none, .some): existing.relevance = source.relevance
            default: break
            }
            result[existingIndex] = existing
        }
        return result
    }
}

public struct CitationAttachmentIdentity: Codable, Equatable, Hashable, Sendable {
    public let messageID: MessageID
    public let toolCallID: String
    public let name: String

    public init(messageID: MessageID, toolCallID: String, name: String) {
        self.messageID = messageID
        self.toolCallID = toolCallID
        self.name = name
    }
}

public enum CitationAttachmentPayload: Codable, Equatable, Hashable, Sendable {
    case webSearch(WebSearchCitationData)
    case fileSearch(FileSearchCitationData)
}

/// A retained citation attachment. This is intentionally separate from the
/// generic message-content enum: history/replay needs source provenance even
/// when the current renderer cannot display a particular provider field.
public struct CitationAttachment: Codable, Equatable, Hashable, Sendable {
    public var identity: CitationAttachmentIdentity
    public var conversationID: ConversationID?
    public var payload: CitationAttachmentPayload
    public var unknownFields: [String: CitationJSONValue]

    public init(
        identity: CitationAttachmentIdentity,
        conversationID: ConversationID? = nil,
        payload: CitationAttachmentPayload,
        unknownFields: [String: CitationJSONValue] = [:]
    ) {
        self.identity = identity
        self.conversationID = conversationID
        self.payload = payload
        self.unknownFields = unknownFields
    }
}

/// Re-emitted search attachments are updates, not additional source sets.
/// The current LibreChat server uses message/tool/name as the stable identity.
public struct CitationAttachmentReducer: Sendable {
    public private(set) var attachments: [CitationAttachment]

    public init(attachments: [CitationAttachment] = []) {
        self.attachments = attachments
    }

    @discardableResult
    public mutating func upsert(_ attachment: CitationAttachment) -> [CitationAttachment] {
        if let index = attachments.firstIndex(where: { $0.identity == attachment.identity }) {
            attachments[index] = attachment
        } else {
            attachments.append(attachment)
        }
        return attachments
    }
}

public struct CitationAnchor: Codable, Equatable, Hashable, Sendable {
    public var turn: Int
    public var referenceType: CitationReferenceType
    public var index: Int
    /// Present when an anchor occurred inside one U+E200...U+E201 group.
    public var compositeGroupID: Int?
    /// Present when an anchor immediately follows a U+E203...U+E204 span.
    public var highlightID: Int?

    public init(
        turn: Int,
        referenceType: CitationReferenceType,
        index: Int,
        compositeGroupID: Int? = nil,
        highlightID: Int? = nil
    ) {
        self.turn = turn
        self.referenceType = referenceType
        self.index = index
        self.compositeGroupID = compositeGroupID
        self.highlightID = highlightID
    }
}

public struct CitationHighlight: Codable, Equatable, Hashable, Sendable {
    public var id: Int
    public var text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

public struct ResolvedCitationAnchor: Codable, Equatable, Hashable, Sendable {
    public var anchor: CitationAnchor
    public var reference: CitationReference

    public init(anchor: CitationAnchor, reference: CitationReference) {
        self.anchor = anchor
        self.reference = reference
    }
}

/// A selectable inline citation token. Composite markers deliberately become
/// one token even though they contain multiple anchors.
public struct CitationRenderToken: Codable, Equatable, Hashable, Sendable {
    public var anchors: [ResolvedCitationAnchor]
    public var compositeGroupID: Int?
    public var highlightID: Int?

    public init(
        anchors: [ResolvedCitationAnchor],
        compositeGroupID: Int? = nil,
        highlightID: Int? = nil
    ) {
        self.anchors = anchors
        self.compositeGroupID = compositeGroupID
        self.highlightID = highlightID
    }
}

/// Renderer-ready, ordered content. A native message renderer can put a
/// compact control at every `.citation` position without retaining any PUA
/// markers in its text nodes.
public enum CitationRenderSegment: Codable, Equatable, Hashable, Sendable {
    case text(String)
    case citation(CitationRenderToken)
}

public struct CitationResolution: Codable, Equatable, Hashable, Sendable {
    public var cleanedText: String
    public var citations: [ResolvedCitationAnchor]
    public var highlights: [CitationHighlight]
    public var renderSegments: [CitationRenderSegment]
    public var discardedAnchorCount: Int

    public init(
        cleanedText: String,
        citations: [ResolvedCitationAnchor] = [],
        highlights: [CitationHighlight] = [],
        renderSegments: [CitationRenderSegment] = [],
        discardedAnchorCount: Int = 0
    ) {
        self.cleanedText = cleanedText
        self.citations = citations
        self.highlights = highlights
        self.renderSegments = renderSegments
        self.discardedAnchorCount = discardedAnchorCount
    }
}

/// A lookup catalog with the same turn behavior as LibreChat's current web
/// client: web-search uses its server-provided turn; file-search gets a
/// stable encounter-order turn because its runtime payload does not carry one.
public struct CitationSourceCatalog: Codable, Equatable, Hashable, Sendable {
    public var webSearchByTurn: [Int: WebSearchCitationData]
    public var fileSearchByTurn: [Int: FileSearchCitationData]

    public init(attachments: [CitationAttachment]) {
        var webSearchByTurn: [Int: WebSearchCitationData] = [:]
        var fileSearchByTurn: [Int: FileSearchCitationData] = [:]
        var nextFileSearchTurn = 0
        for attachment in attachments {
            switch attachment.payload {
            case let .webSearch(data):
                if let turn = data.turn {
                    webSearchByTurn[turn] = data
                }
            case let .fileSearch(data):
                fileSearchByTurn[nextFileSearchTurn] = data
                nextFileSearchTurn += 1
            }
        }
        self.webSearchByTurn = webSearchByTurn
        self.fileSearchByTurn = fileSearchByTurn
    }

    public init(
        webSearchByTurn: [Int: WebSearchCitationData] = [:],
        fileSearchByTurn: [Int: FileSearchCitationData] = [:]
    ) {
        self.webSearchByTurn = webSearchByTurn
        self.fileSearchByTurn = fileSearchByTurn
    }

    public func reference(for anchor: CitationAnchor) -> CitationReference? {
        guard anchor.index >= 0 else { return nil }
        switch anchor.referenceType {
        case .file:
            // At this pinned LibreChat revision file anchors are numbered
            // before permission filtering/reordering/limits and the web UI
            // later deduplicates them. The number is therefore not a safe
            // public index into either raw or display file sources.
            return nil
        default:
            guard let sources = webSearchByTurn[anchor.turn]?.references(for: anchor.referenceType),
                  sources.indices.contains(anchor.index) else { return nil }
            return sources[anchor.index]
        }
    }

    /// File-search provenance remains available for a dedicated source list;
    /// it is intentionally not used to resolve inline `turn…file…` anchors.
    public func displayFileSources(forTurn turn: Int) -> [CitationReference] {
        fileSearchByTurn[turn]?.displaySources() ?? []
    }
}

/// Parses LibreChat's private-use citation markers without allowing malformed
/// or unresolved markers to become links. The parser accepts both literal
/// `\\ue20x` escapes and the actual U+E200...U+E204 characters.
public enum CitationMarkerResolver {
    public static func resolve(_ text: String, sources: CitationSourceCatalog) -> CitationResolution {
        let normalized = normalizeMarkers(in: text)
        var index = normalized.startIndex
        var cleaned = ""
        var citations: [ResolvedCitationAnchor] = []
        var highlights: [CitationHighlight] = []
        var renderSegments: [CitationRenderSegment] = []
        var textBuffer = ""
        var discarded = 0
        var groupStack: [(id: Int, citations: [ResolvedCitationAnchor])] = []
        var nextGroupID = 0
        var activeHighlight: (id: Int, start: String.Index)?
        var pendingHighlightID: Int?

        func flushText() {
            guard !textBuffer.isEmpty else { return }
            renderSegments.append(.text(textBuffer))
            textBuffer = ""
        }

        func appendToken(_ token: CitationRenderToken) {
            flushText()
            renderSegments.append(.citation(token))
        }

        while index < normalized.endIndex {
            let scalar = normalized[index].unicodeScalars.first
            switch scalar?.value {
            case 0xE200:
                nextGroupID += 1
                groupStack.append((id: nextGroupID, citations: []))
                pendingHighlightID = nil
                index = normalized.index(after: index)
            case 0xE201:
                if let group = groupStack.popLast() {
                    if !group.citations.isEmpty {
                        citations.append(contentsOf: group.citations)
                        appendToken(CitationRenderToken(
                            anchors: group.citations,
                            compositeGroupID: group.id,
                            highlightID: group.citations.compactMap(\.anchor.highlightID).first
                        ))
                    }
                } else {
                    discarded += 1
                }
                pendingHighlightID = nil
                index = normalized.index(after: index)
            case 0xE203:
                if activeHighlight != nil { discarded += 1 }
                let id = highlights.count
                activeHighlight = (id, normalized.index(after: index))
                pendingHighlightID = nil
                index = normalized.index(after: index)
            case 0xE204:
                if let highlight = activeHighlight {
                    highlights.append(CitationHighlight(
                        id: highlight.id,
                        text: String(normalized[highlight.start..<index])
                    ))
                    pendingHighlightID = highlight.id
                    activeHighlight = nil
                } else {
                    discarded += 1
                }
                index = normalized.index(after: index)
            case 0xE202:
                let start = normalized.index(after: index)
                let parsed = parseAnchor(in: normalized, from: start)
                if let parsed {
                    let anchor = CitationAnchor(
                        turn: parsed.turn,
                        referenceType: parsed.type,
                        index: parsed.index,
                        compositeGroupID: groupStack.last?.id,
                        highlightID: pendingHighlightID
                    )
                    if let reference = sources.reference(for: anchor) {
                        let resolved = ResolvedCitationAnchor(anchor: anchor, reference: reference)
                        if groupStack.isEmpty {
                            citations.append(resolved)
                            appendToken(CitationRenderToken(
                                anchors: [resolved],
                                highlightID: pendingHighlightID
                            ))
                        } else {
                            groupStack[groupStack.count - 1].citations.append(resolved)
                        }
                    } else {
                        discarded += 1
                    }
                    index = parsed.end
                } else {
                    discarded += 1
                    index = consumeCitationLikeToken(in: normalized, from: start)
                }
                pendingHighlightID = nil
            case 0xE206:
                // The web client strips this marker as well even though it is
                // not part of a resolvable citation anchor.
                index = normalized.index(after: index)
                pendingHighlightID = nil
            default:
                cleaned.append(normalized[index])
                textBuffer.append(normalized[index])
                if !normalized[index].isWhitespace {
                    pendingHighlightID = nil
                }
                index = normalized.index(after: index)
            }
        }

        if !groupStack.isEmpty {
            discarded += groupStack.reduce(0) { $0 + max(1, $1.citations.count) }
        }
        if activeHighlight != nil { discarded += 1 }
        flushText()
        return CitationResolution(
            cleanedText: cleaned,
            citations: citations,
            highlights: highlights,
            renderSegments: renderSegments,
            discardedAnchorCount: discarded
        )
    }

    private static func normalizeMarkers(in text: String) -> String {
        var result = text
        for codePoint in 0xE200...0xE206 {
            result = result.replacingOccurrences(
                of: "\\u" + String(codePoint, radix: 16),
                with: String(UnicodeScalar(UInt32(codePoint))!)
            )
        }
        return result
    }

    private static func parseAnchor(
        in text: String,
        from start: String.Index
    ) -> (turn: Int, type: CitationReferenceType, index: Int, end: String.Index)? {
        var cursor = start
        guard consume("turn", in: text, cursor: &cursor),
              let turn = consumeDigits(in: text, cursor: &cursor) else { return nil }
        let type = CitationReferenceType.allCases.first { consume($0.rawValue, in: text, cursor: &cursor) }
        guard let type, let sourceIndex = consumeDigits(in: text, cursor: &cursor) else { return nil }
        return (turn, type, sourceIndex, cursor)
    }

    private static func consume(_ string: String, in text: String, cursor: inout String.Index) -> Bool {
        guard text[cursor...].hasPrefix(string) else { return false }
        cursor = text.index(cursor, offsetBy: string.count)
        return true
    }

    private static func consumeDigits(in text: String, cursor: inout String.Index) -> Int? {
        let start = cursor
        while cursor < text.endIndex, text[cursor].isNumber, text[cursor].unicodeScalars.allSatisfy({ $0.isASCII }) {
            cursor = text.index(after: cursor)
        }
        guard start != cursor else { return nil }
        return Int(text[start..<cursor])
    }

    private static func consumeCitationLikeToken(in text: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex,
              text[cursor].unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122: true
                  default: false
                  }
              }) {
            cursor = text.index(after: cursor)
        }
        return cursor
    }
}
