import Foundation
import LibreChatDomain

/// Permissive DTO for assistant/tool output attachments. LibreChat has sent
/// this shape both as a historical message attachment and inside two SSE
/// envelopes, so decoding starts from raw JSON and retains unknown fields.
public struct LibreChatGeneratedFileDTO: Codable, Equatable, Sendable {
    public var fileID: String?
    public var filepath: String?
    public var url: String?
    public var filename: String?
    public var mimeType: String?
    public var bytes: Int64?
    public var text: String?
    public var textFormat: String?
    public var status: String?
    public var previewError: String?
    public var messageID: String?
    public var conversationID: String?
    public var toolCallID: String?
    public var agentID: String?
    public var sessionID: String?
    public var unknownFields: [String: JSONValue]

    public init(value: JSONValue) throws {
        guard var object = Self.normalizedAttachmentObject(value) else {
            throw DTOMapperError.invalidField("generatedFile")
        }
        fileID = Self.removeString(&object, "file_id", "fileId")
        filepath = Self.removeString(&object, "filepath")
        url = Self.removeString(&object, "url")
        filename = Self.removeString(&object, "filename", "name")
        let rawType = Self.removeString(&object, "type")
        mimeType = Self.removeString(&object, "mime_type", "mimeType", "content_type")
            ?? (rawType == "attachment" || rawType == "file" ? nil : rawType)
        bytes = Self.removeInt64(&object, "bytes", "size")
        text = Self.removeText(&object, "text")
        textFormat = Self.removeString(&object, "textFormat", "text_format")
        status = Self.removeString(&object, "status")
        previewError = Self.removeString(&object, "previewError", "preview_error")
        messageID = Self.removeString(&object, "messageId", "message_id")
        conversationID = Self.removeString(&object, "conversationId", "conversation_id")
        toolCallID = Self.removeString(&object, "toolCallId", "tool_call_id")
        agentID = Self.removeString(&object, "agentId", "agent_id")
        sessionID = Self.removeString(&object, "sessionId", "session_id", "storage_session_id")
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
        if let fileID { object["file_id"] = .string(fileID) }
        if let filepath { object["filepath"] = .string(filepath) }
        if let url { object["url"] = .string(url) }
        if let filename { object["filename"] = .string(filename) }
        if let mimeType { object["type"] = .string(mimeType) }
        if let bytes { object["bytes"] = .number(Double(bytes)) }
        if let text { object["text"] = .string(text) }
        if let textFormat { object["textFormat"] = .string(textFormat) }
        if let status { object["status"] = .string(status) }
        if let previewError { object["previewError"] = .string(previewError) }
        if let messageID { object["messageId"] = .string(messageID) }
        if let conversationID { object["conversationId"] = .string(conversationID) }
        if let toolCallID { object["toolCallId"] = .string(toolCallID) }
        if let agentID { object["agentId"] = .string(agentID) }
        if let sessionID { object["sessionId"] = .string(sessionID) }
        try JSONValue.object(object).encode(to: encoder)
    }

    public func domainModel() throws -> GeneratedFile {
        guard let resource = fileID?.nonEmpty ?? filepath?.nonEmpty ?? url?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("generatedFile.file_id|filepath|url")
        }
        let lifecycle: GeneratedFileLifecycle = switch status?.lowercased() {
        case "pending": .pending
        case "ready": .ready
        case "failed": .failed
        default: .legacy
        }
        // Responses calls the same path `url`; normalize the alias into the
        // identity-bearing filepath while retaining `urlAlias` verbatim.
        let path = filepath ?? url
        let codePath = [filepath, url].compactMap { $0 }.first(where: {
            $0.contains("/api/files/code/download/")
        })
        let derivedSessionID = sessionID ?? Self.codeSessionID(from: codePath)
        return GeneratedFile(
            fileID: fileID,
            filepath: path,
            urlAlias: url,
            filename: filename?.nonEmpty ?? Self.filename(from: resource),
            mimeType: mimeType,
            bytes: bytes,
            text: text,
            textFormat: textFormat,
            previewError: previewError,
            lifecycle: lifecycle,
            provenance: GeneratedFileProvenance(
                messageID: messageID?.nonEmpty.map(MessageID.init(rawValue:)),
                conversationID: conversationID?.nonEmpty.map(ConversationID.init(rawValue:)),
                toolCallID: toolCallID?.nonEmpty,
                agentID: agentID?.nonEmpty,
                sessionID: derivedSessionID,
                codeDownloadPath: codePath
            )
        )
    }

    /// Standard attachment data and `librechat:attachment` Responses events
    /// normalize into this exact same DTO. Wrapper metadata fills only absent
    /// nested fields, never overwriting file-level provenance.
    public static func generationAttachment(from value: JSONValue) throws -> GeneratedFile {
        try LibreChatGeneratedFileDTO(value: value).domainModel()
    }

    public static func canDecode(_ value: JSONValue) -> Bool {
        guard let object = Self.normalizedAttachmentObject(value) else { return false }
        let hasResource = object["file_id"]?.stringValue?.isEmpty == false
            || object["fileId"]?.stringValue?.isEmpty == false
            || object["filepath"]?.stringValue?.isEmpty == false
            || object["url"]?.stringValue?.isEmpty == false
        guard hasResource else { return false }
        // Ordinary user/file attachments still map to UploadedFile. A
        // generated output advertises a lifecycle, run coordinate, or the
        // dedicated code-download route.
        return object["status"] != nil
            || object["textFormat"] != nil
            || object["text_format"] != nil
            || object["previewError"] != nil
            || object["preview_error"] != nil
            || object["toolCallId"] != nil
            || object["tool_call_id"] != nil
            || object["agentId"] != nil
            || object["agent_id"] != nil
            || object["filepath"]?.stringValue?.contains("/api/files/code/download/") == true
            || object["url"]?.stringValue?.contains("/api/files/code/download/") == true
    }

    private static func normalizedAttachmentObject(_ value: JSONValue) -> [String: JSONValue]? {
        guard let outer = value.objectValue else { return nil }
        guard outer["type"]?.stringValue == "librechat:attachment",
              var nested = outer["attachment"]?.objectValue else {
            return outer
        }
        for (nestedKey, outerKeys) in [
            ("messageId", ["message_id", "messageId"]),
            ("conversationId", ["conversation_id", "conversationId"]),
            ("toolCallId", ["tool_call_id", "toolCallId"]),
            ("agentId", ["agent_id", "agentId"]),
            ("sessionId", ["session_id", "sessionId"])
        ] {
            if nested[nestedKey] == nil {
                nested[nestedKey] = outerKeys.compactMap { outer[$0] }.first
            }
        }
        return nested
    }

    private static func removeString(_ object: inout [String: JSONValue], _ keys: String...) -> String? {
        for key in keys {
            if let value = object.removeValue(forKey: key)?.stringValue { return value }
        }
        return nil
    }

    private static func removeText(_ object: inout [String: JSONValue], _ keys: String...) -> String? {
        for key in keys {
            if let value = object.removeValue(forKey: key)?.textValue() { return value }
        }
        return nil
    }

    private static func removeInt64(_ object: inout [String: JSONValue], _ keys: String...) -> Int64? {
        for key in keys {
            if let value = object.removeValue(forKey: key)?.intValue { return Int64(value) }
        }
        return nil
    }

    private static func filename(from resource: String) -> String {
        let name = URL(fileURLWithPath: resource).lastPathComponent
        return name.isEmpty ? "Generated file" : name
    }

    private static func codeSessionID(from path: String?) -> String? {
        guard let path,
              let range = path.range(of: "/api/files/code/download/") else { return nil }
        let suffix = path[range.upperBound...]
        return suffix.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
    }
}

/// Response from the deferred-preview lifecycle endpoint. Its intentionally
/// small shape is merged onto the attachment already present in a message.
public struct GeneratedFilePreviewDTO: Codable, Equatable, Sendable {
    public var fileID: String?
    public var status: String?
    public var text: String?
    public var textFormat: String?
    public var previewError: String?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case status, text, textFormat, previewError
    }

    public func applying(to file: GeneratedFile) throws -> GeneratedFile {
        guard let expectedFileID = file.fileID?.nonEmpty,
              let echoedFileID = fileID?.nonEmpty,
              echoedFileID == expectedFileID else {
            throw LibreChatProtocolError.invalidResponse
        }
        let lifecycle: GeneratedFileLifecycle
        switch status?.lowercased() {
        case "pending":
            guard text == nil, textFormat == nil, previewError == nil else {
                throw LibreChatProtocolError.invalidResponse
            }
            lifecycle = .pending
        case "ready":
            guard previewError == nil,
                  text != nil || textFormat == nil else {
                throw LibreChatProtocolError.invalidResponse
            }
            lifecycle = .ready
        case "failed":
            guard text == nil, textFormat == nil else {
                throw LibreChatProtocolError.invalidResponse
            }
            lifecycle = .failed
        default:
            throw LibreChatProtocolError.invalidResponse
        }
        let response = GeneratedFile(
            fileID: echoedFileID,
            filepath: file.filepath,
            urlAlias: file.urlAlias,
            filename: file.filename,
            mimeType: file.mimeType,
            bytes: file.bytes,
            text: text ?? file.text,
            textFormat: textFormat ?? file.textFormat,
            previewTruncated: text == nil ? file.previewTruncated : false,
            previewError: previewError ?? file.previewError,
            lifecycle: lifecycle,
            provenance: file.provenance
        )
        var reducer = GeneratedFileReducer(files: [file])
        return reducer.applyPreview(response).first ?? file
    }
}

public struct GeneratedFileDownloadURLDTO: Codable, Equatable, Sendable {
    public var url: URL?
    public var filename: String?
    public var mimeType: String?

    private enum CodingKeys: String, CodingKey {
        case url, filename
        case mimeType = "type"
    }
}

/// Compatibility name retained for generated-output call sites. All regular
/// and generated file transfers now share one disk-backed request descriptor.
public typealias GeneratedFileByteRequest = FileByteRequest

public enum LibreChatGeneratedFileAPI {
    public static func preview(fileID: String) throws -> APIRequest<GeneratedFilePreviewDTO> {
        let fileID = try required(fileID, field: "file_id")
        return APIRequest(
            path: "api/files/\(fileID)/preview",
            pathComponents: ["api", "files", fileID, "preview"],
            // The app controls pending-preview polling and bounded retries;
            // one transport request is predictable and does not multiply it.
            retryPolicy: .never
        )
    }

    public static func downloadURL(
        userID: String,
        fileID: String
    ) throws -> APIRequest<GeneratedFileDownloadURLDTO> {
        let userID = try required(userID, field: "userId")
        let fileID = try required(fileID, field: "file_id")
        return APIRequest(
            path: "api/files/download-url/\(userID)/\(fileID)",
            pathComponents: ["api", "files", "download-url", userID, fileID],
            retryPolicy: .never
        )
    }

    public static func download(userID: String, fileID: String) throws -> GeneratedFileByteRequest {
        try LibreChatFilesAPI.download(userID: userID, fileID: fileID)
    }

    public static func codeFallbackDownload(
        sessionID: String,
        fileID: String
    ) throws -> GeneratedFileByteRequest {
        let sessionID = try required(sessionID, field: "session_id")
        let fileID = try required(fileID, field: "fileId")
        return GeneratedFileByteRequest(
            path: "api/files/code/download/\(sessionID)/\(fileID)",
            pathComponents: ["api", "files", "code", "download", sessionID, fileID],
            headers: ["Accept": "application/octet-stream"],
            retryPolicy: .never
        )
    }

    private static func required(_ value: String, field: String) throws -> String {
        guard let nonEmpty = value.nonEmpty else {
            throw LibreChatProtocolError.encoding("The generated-file \(field) cannot be empty.")
        }
        return nonEmpty
    }
}
