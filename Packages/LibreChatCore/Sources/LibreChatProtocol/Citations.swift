import Foundation
import LibreChatDomain

/// Permissive transport envelope for the two search attachment variants that
/// back LibreChat citations. It keeps unknown provider and server fields
/// lossless while the mapper projects only the stable native surface.
public struct LibreChatCitationAttachmentDTO: Codable, Equatable, Sendable {
    public var messageID: String?
    public var toolCallID: String?
    public var conversationID: String?
    public var name: String?
    public var type: String?
    public var webSearch: JSONValue?
    public var fileSearch: JSONValue?
    public var unknownFields: [String: JSONValue]

    public init(
        messageID: String? = nil,
        toolCallID: String? = nil,
        conversationID: String? = nil,
        name: String? = nil,
        type: String? = nil,
        webSearch: JSONValue? = nil,
        fileSearch: JSONValue? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.messageID = messageID
        self.toolCallID = toolCallID
        self.conversationID = conversationID
        self.name = name
        self.type = type
        self.webSearch = webSearch
        self.fileSearch = fileSearch
        self.unknownFields = unknownFields
    }

    /// Shared raw-envelope entry point for history attachments and `attachment`
    /// SSE event payloads. Both paths therefore map into the same identity
    /// and can use `CitationAttachmentReducer.upsert(_:)` without a special
    /// live-stream representation.
    public init(value: JSONValue) throws {
        guard var object = value.objectValue else {
            throw DTOMapperError.invalidField("citationAttachment")
        }
        messageID = object.removeValue(forKey: "messageId")?.stringValue
        toolCallID = object.removeValue(forKey: "toolCallId")?.stringValue
        conversationID = object.removeValue(forKey: "conversationId")?.stringValue
        name = object.removeValue(forKey: "name")?.stringValue
        type = object.removeValue(forKey: "type")?.stringValue
        webSearch = object.removeValue(forKey: "web_search")
        fileSearch = object.removeValue(forKey: "file_search")
        unknownFields = object
    }

    public init(from decoder: Decoder) throws {
        do {
            try self.init(value: JSONValue(from: decoder))
        } catch let error as DTOMapperError {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error))
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var object = unknownFields
        if let messageID { object["messageId"] = .string(messageID) }
        if let toolCallID { object["toolCallId"] = .string(toolCallID) }
        if let conversationID { object["conversationId"] = .string(conversationID) }
        if let name { object["name"] = .string(name) }
        if let type { object["type"] = .string(type) }
        if let webSearch { object["web_search"] = webSearch }
        if let fileSearch { object["file_search"] = fileSearch }
        try JSONValue.object(object).encode(to: encoder)
    }

    public func domainModel() throws -> CitationAttachment {
        guard let messageID = messageID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("citationAttachment.messageId")
        }
        guard let toolCallID = toolCallID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("citationAttachment.toolCallId")
        }
        guard let name = name?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("citationAttachment.name")
        }
        let payload: CitationAttachmentPayload
        switch type {
        case "web_search":
            guard let webSearch else {
                throw DTOMapperError.missingRequiredField("citationAttachment.web_search")
            }
            payload = .webSearch(try WebSearchCitationDataDTO(value: webSearch).domainModel())
        case "file_search":
            guard let fileSearch else {
                throw DTOMapperError.missingRequiredField("citationAttachment.file_search")
            }
            payload = .fileSearch(try FileSearchCitationDataDTO(value: fileSearch).domainModel())
        default:
            throw DTOMapperError.invalidField("citationAttachment.type")
        }

        return CitationAttachment(
            identity: CitationAttachmentIdentity(
                messageID: MessageID(rawValue: messageID),
                toolCallID: toolCallID,
                name: name
            ),
            conversationID: conversationID?.nonEmpty.map(ConversationID.init(rawValue:)),
            payload: payload,
            unknownFields: unknownFields.mapValues(CitationJSONValue.init)
        )
    }

    /// Maps either the standard attachment object or the Responses API's
    /// `librechat:attachment` wrapper into the exact same domain attachment.
    /// Wrapper metadata is injected only when its nested attachment omits it.
    public static func generationAttachment(from value: JSONValue) throws -> CitationAttachment {
        guard let outer = value.objectValue,
              outer["type"]?.stringValue == "librechat:attachment",
              var nested = outer["attachment"]?.objectValue else {
            return try LibreChatCitationAttachmentDTO(value: value).domainModel()
        }
        if nested["messageId"] == nil {
            nested["messageId"] = outer["message_id"] ?? outer["messageId"]
        }
        if nested["conversationId"] == nil {
            nested["conversationId"] = outer["conversation_id"] ?? outer["conversationId"]
        }
        if nested["name"] == nil,
           let type = nested["type"]?.stringValue,
           let toolCallID = nested["toolCallId"]?.stringValue {
            nested["name"] = .string("\(type):\(toolCallID)")
        }
        return try LibreChatCitationAttachmentDTO(value: .object(nested)).domainModel()
    }
}

public struct WebSearchCitationDataDTO: Codable, Equatable, Sendable {
    public var raw: JSONValue

    public init(value: JSONValue) throws {
        guard value.objectValue != nil else {
            throw DTOMapperError.invalidField("citationAttachment.web_search")
        }
        raw = value
    }

    public init(from decoder: Decoder) throws {
        try self.init(value: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    public func domainModel() -> WebSearchCitationData {
        let object = raw.objectValue ?? [:]
        return WebSearchCitationData(
            turn: object["turn"]?.intValue,
            organic: references(in: object["organic"], type: .search),
            images: references(in: object["images"], type: .image),
            topStories: references(in: object["topStories"], type: .news),
            videos: references(in: object["videos"], type: .video),
            references: references(in: object["references"], type: .ref),
            error: object["error"]?.textValue(),
            raw: CitationJSONValue(raw)
        )
    }
}

public struct FileSearchCitationDataDTO: Codable, Equatable, Sendable {
    public var raw: JSONValue

    public init(value: JSONValue) throws {
        guard value.objectValue != nil else {
            throw DTOMapperError.invalidField("citationAttachment.file_search")
        }
        raw = value
    }

    public init(from decoder: Decoder) throws {
        try self.init(value: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try raw.encode(to: encoder)
    }

    public func domainModel() -> FileSearchCitationData {
        let object = raw.objectValue ?? [:]
        return FileSearchCitationData(
            sources: references(in: object["sources"], type: .file),
            raw: CitationJSONValue(raw)
        )
    }
}

private func references(in value: JSONValue?, type: CitationReferenceType) -> [CitationReference] {
    (value?.arrayValue ?? []).compactMap { source in
        guard let object = source.objectValue else { return nil }
        let pages = object["pages"]?.arrayValue?.compactMap(\.intValue)
        let pageRelevance = object["pageRelevance"]?.objectValue?.reduce(into: [String: Double]()) {
            if let value = $1.value.doubleValue { $0[$1.key] = value }
        }
        return CitationReference(
            type: type,
            title: object["title"]?.stringValue ?? object["fileName"]?.stringValue,
            link: validatedURL(object["link"]?.stringValue),
            attribution: object["attribution"]?.stringValue ?? object["source"]?.stringValue,
            snippet: object["snippet"]?.stringValue,
            imageURL: validatedURL(object["imageUrl"]?.stringValue),
            fileID: object["fileId"]?.stringValue,
            fileName: object["fileName"]?.stringValue,
            pages: pages,
            relevance: object["relevance"]?.doubleValue,
            pageRelevance: pageRelevance,
            raw: CitationJSONValue(source)
        )
    }
}

private func validatedURL(_ string: String?) -> URL? {
    guard let string,
          let url = URL(string: string),
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = url.host,
          !host.isEmpty else { return nil }
    return url
}

private extension CitationJSONValue {
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case let .bool(value): self = .bool(value)
        case let .number(value): self = .number(value)
        case let .string(value): self = .string(value)
        case let .array(value): self = .array(value.map(CitationJSONValue.init))
        case let .object(value): self = .object(value.mapValues(CitationJSONValue.init))
        }
    }
}
