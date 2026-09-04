import Foundation
import LibreChatDomain

public enum DTOMapperError: Error, Equatable, Sendable {
    case missingRequiredField(String)
    case invalidField(String)
    case invalidURL(String)
}

public struct LibreChatUserDTO: Codable, Equatable, Sendable {
    public var id: String?
    public var mongoID: String?
    public var name: String?
    public var username: String?
    public var email: String?
    public var role: String?
    public var avatar: String?
    public var twoFactorEnabled: Bool?
    public var personalization: LibreChatPersonalizationDTO?

    private enum CodingKeys: String, CodingKey {
        case id
        case mongoID = "_id"
        case name, username, email, role, avatar, twoFactorEnabled, personalization
    }

    public func domainModel() throws -> UserAccount {
        guard let identifier = id?.nonEmpty ?? mongoID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("user.id")
        }
        return UserAccount(
            id: AccountID(rawValue: identifier),
            name: name,
            username: username,
            email: email,
            role: role,
            avatarURL: avatar.flatMap(URL.init(string:)),
            twoFactorEnabled: twoFactorEnabled,
            memoriesEnabled: personalization?.memories
        )
    }
}

public struct LibreChatPersonalizationDTO: Codable, Equatable, Sendable {
    public var memories: Bool?

    public init(memories: Bool? = nil) {
        self.memories = memories
    }
}

public struct LibreChatConversationDTO: Codable, Equatable, Sendable {
    public var conversationID: String?
    public var title: String?
    public var endpoint: String?
    public var endpointType: String?
    public var model: String?
    public var agentID: String?
    public var assistantID: String?
    public var parentMessageID: String?
    public var spec: String?
    public var promptPrefix: String?
    public var updatedAt: String?
    public var isArchived: Bool?
    /// Current LibreChat servers use `pinned`; accept `isPinned` from older
    /// response shapes while exposing one stable domain value.
    public var pinned: Bool?
    public var isPinned: Bool?
    /// The pinned conversation contract carries tag names, not tag-directory
    /// records. Optionality distinguishes an omitted field from `[]`.
    public var tags: [String]?
    public var chatProjectID: String?
    public var isTemporary: Bool?
    public var expiredAt: String?

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case title, endpoint, endpointType, model
        case agentID = "agent_id"
        case assistantID = "assistant_id"
        case parentMessageID = "parentMessageId"
        case chatProjectID = "chatProjectId"
        case spec, promptPrefix, updatedAt, isArchived, pinned, isPinned, tags
        case isTemporary, expiredAt
    }

    public func domainModel() throws -> Conversation {
        guard let conversationID = conversationID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("conversation.conversationId")
        }
        let target = endpoint?.nonEmpty.map {
            ConversationTarget(
                endpoint: $0,
                endpointType: endpointType,
                model: model,
                agentID: agentID,
                assistantID: assistantID,
                parentMessageID: parentMessageID.map { MessageID(rawValue: $0) },
                spec: spec,
                promptPrefix: promptPrefix
            )
        }
        return Conversation(
            id: ConversationID(rawValue: conversationID),
            title: title?.nonEmpty ?? "Untitled chat",
            model: model,
            updatedAt: updatedAt.flatMap(Self.date),
            target: target,
            isArchived: isArchived,
            pinned: pinned ?? isPinned,
            tags: tags,
            projectID: chatProjectID?.nonEmpty.map(ProjectID.init(rawValue:)),
            isTemporary: isTemporary,
            expiresAt: expiredAt.flatMap(Self.date)
        )
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct LibreChatConversationPageDTO: Decodable, Equatable, Sendable {
    public var conversations: [LibreChatConversationDTO]
    public var nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case conversations, nextCursor
    }

    public init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([LibreChatConversationDTO].self) {
            conversations = array
            nextCursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try container.decode([LibreChatConversationDTO].self, forKey: .conversations)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    public func domainModel(isFromCache: Bool = false) throws -> ConversationPage {
        ConversationPage(
            conversations: try conversations.map { try $0.domainModel() },
            nextCursor: nextCursor,
            isFromCache: isFromCache
        )
    }
}

public struct LibreChatFileDTO: Codable, Equatable, Sendable {
    public var fileID: String?
    public var temporaryFileID: String?
    public var filename: String?
    public var filepath: String?
    public var bytes: Int64?
    public var type: String?
    public var context: String?
    public var source: String?
    public var embedded: Bool?
    public var width: Int?
    public var height: Int?
    public var expiresAt: String?
    public var expiredAt: String?
    public var status: String?
    public var createdAt: String?
    public var updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case temporaryFileID = "temp_file_id"
        case filename, filepath, bytes, type, context, source, embedded, width, height
        case expiresAt, expiredAt, status, createdAt, updatedAt
    }

    public func domainModel(fallbackFilename: String? = nil) throws -> UploadedFile {
        guard let fileID = fileID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("file.file_id")
        }
        return UploadedFile(
            id: fileID,
            temporaryID: temporaryFileID,
            filename: filename?.nonEmpty ?? fallbackFilename?.nonEmpty ?? "Attachment",
            filepath: filepath,
            mimeType: type,
            bytes: bytes,
            context: context,
            source: source,
            embedded: embedded,
            width: width,
            height: height,
            expiresAt: expiresAt,
            previewStatus: status
        )
    }

    public func fileLibraryItem() throws -> FileLibraryItem {
        let file = try domainModel(fallbackFilename: "Unnamed file")
        return FileLibraryItem(
            file: file,
            createdAt: createdAt.flatMap(Self.date),
            updatedAt: updatedAt.flatMap(Self.date),
            expiresAt: (expiredAt ?? expiresAt).flatMap(Self.date)
        )
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public struct FilesUsageRequestDTO: Encodable, Equatable, Sendable {
    public var fileIDs: [String]

    public init(fileIDs: [String]) {
        self.fileIDs = fileIDs
    }

    private enum CodingKeys: String, CodingKey {
        case fileIDs = "file_ids"
    }
}

public struct FilesUsageResponseDTO: Decodable, Equatable, Sendable {
    public var held: Int

    public init(held: Int) {
        self.held = held
    }
}

public struct FileDeletionDTO: Encodable, Equatable, Sendable {
    public var fileID: String
    public var filepath: String
    public var embedded: Bool
    public var source: String
    public var temporaryFileID: String?

    public init(file: UploadedFile) throws {
        guard Self.isAcceptedFileID(file.id) else {
            throw DTOMapperError.invalidField("file.file_id")
        }
        guard let filepath = file.filepath?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("file.filepath")
        }
        fileID = file.id
        self.filepath = filepath
        embedded = file.embedded ?? false
        source = file.source?.nonEmpty ?? "local"
        temporaryFileID = file.temporaryID
    }

    /// Mirrors the pinned server's owner-delete filter. Unsupported catalog
    /// identities must fail before a mutation that the server would silently
    /// discard with a 204 response.
    public static func isAcceptedFileID(_ value: String) -> Bool {
        if value.hasPrefix("file-") || value.hasPrefix("assistant-") {
            return true
        }
        guard value.count == 36, let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case filepath, embedded, source
        case temporaryFileID = "temp_file_id"
    }
}

public struct DeleteFilesRequestDTO: Encodable, Equatable, Sendable {
    public var files: [FileDeletionDTO]

    public init(files: [FileDeletionDTO]) {
        self.files = files
    }
}

public struct DeleteFilesResponseDTO: Decodable, Equatable, Sendable {
    public var message: String?

    public init(message: String? = nil) {
        self.message = message
    }
}

public struct EndpointFileConfigurationDTO: Codable, Equatable, Sendable {
    public var disabled: Bool?
    public var fileLimit: Int?
    public var fileSizeLimit: Int64?
    public var totalSizeLimit: Int64?
    public var supportedMimeTypes: [String]?

    public init(
        disabled: Bool? = nil,
        fileLimit: Int? = nil,
        fileSizeLimit: Int64? = nil,
        totalSizeLimit: Int64? = nil,
        supportedMimeTypes: [String]? = nil
    ) {
        self.disabled = disabled
        self.fileLimit = fileLimit
        self.fileSizeLimit = fileSizeLimit
        self.totalSizeLimit = totalSizeLimit
        self.supportedMimeTypes = supportedMimeTypes
    }
}

public struct ClientImageResizeConfigurationDTO: Codable, Equatable, Sendable {
    public var enabled: Bool?
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var quality: Double?

    public init(
        enabled: Bool? = nil,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Double? = nil
    ) {
        self.enabled = enabled
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.quality = quality
    }
}

public struct FileConfigurationDTO: Codable, Equatable, Sendable {
    public var endpoints: [String: EndpointFileConfigurationDTO]?
    public var serverFileSizeLimit: Int64?
    public var avatarSizeLimit: Int64?
    public var clientImageResize: ClientImageResizeConfigurationDTO?

    public init(
        endpoints: [String: EndpointFileConfigurationDTO]? = nil,
        serverFileSizeLimit: Int64? = nil,
        avatarSizeLimit: Int64? = nil,
        clientImageResize: ClientImageResizeConfigurationDTO? = nil
    ) {
        self.endpoints = endpoints
        self.serverFileSizeLimit = serverFileSizeLimit
        self.avatarSizeLimit = avatarSizeLimit
        self.clientImageResize = clientImageResize
    }

    /// LibreChat's `/api/files/config` route serves the RAW admin
    /// configuration where every size value is expressed in MEGABYTES. The
    /// web client runs `mergeFileConfig` on the response — converting the MB
    /// values to BYTES and filling unset fields with the server's defaults —
    /// before validating. Size checks against the raw response compare a
    /// byte count to an MB-scaled number, which is how tiny files end up
    /// "exceeding the server limit". This merge reproduces the web's exact
    /// semantics.
    public func mergedWithByteUnitsAndDefaults() -> FileConfigurationDTO {
        let megabyte: Int64 = 1_048_576
        let defaultSizeLimit: Int64 = 512 * megabyte

        // Web's `fileConfig` baseline: the shared default plus the endpoints
        // that ship their own baseline in `mergeFileConfig`.
        let baselineEndpoint = EndpointFileConfigurationDTO(
            disabled: false,
            fileLimit: 10,
            fileSizeLimit: defaultSizeLimit,
            totalSizeLimit: defaultSizeLimit
        )
        var mergedEndpoints: [String: EndpointFileConfigurationDTO] = [:]
        for key in ["default", "assistants", "azureAssistants", "agents", "anthropic"] {
            mergedEndpoints[key] = baselineEndpoint
        }
        for (key, dynamic) in endpoints ?? [:] {
            var merged = mergedEndpoints[key] ?? baselineEndpoint
            if dynamic.disabled == true {
                merged.disabled = true
                merged.fileLimit = 0
                merged.fileSizeLimit = 0
                merged.totalSizeLimit = 0
                merged.supportedMimeTypes = []
            } else {
                merged.disabled = dynamic.disabled ?? merged.disabled
                merged.fileLimit = dynamic.fileLimit ?? merged.fileLimit
                if let fileSizeLimit = dynamic.fileSizeLimit {
                    merged.fileSizeLimit = fileSizeLimit * megabyte
                }
                if let totalSizeLimit = dynamic.totalSizeLimit {
                    merged.totalSizeLimit = totalSizeLimit * megabyte
                }
                merged.supportedMimeTypes = dynamic.supportedMimeTypes ?? merged.supportedMimeTypes
            }
            mergedEndpoints[key] = merged
        }

        let mergedResize: ClientImageResizeConfigurationDTO
        if let configured = clientImageResize {
            mergedResize = ClientImageResizeConfigurationDTO(
                enabled: configured.enabled ?? false,
                maxWidth: configured.maxWidth ?? 1_900,
                maxHeight: configured.maxHeight ?? 1_900,
                quality: configured.quality ?? 0.92
            )
        } else {
            mergedResize = ClientImageResizeConfigurationDTO(
                enabled: false,
                maxWidth: 1_900,
                maxHeight: 1_900,
                quality: 0.92
            )
        }

        return FileConfigurationDTO(
            endpoints: mergedEndpoints,
            serverFileSizeLimit: (serverFileSizeLimit ?? defaultSizeLimit / megabyte) * megabyte,
            avatarSizeLimit: (avatarSizeLimit ?? 2) * megabyte,
            clientImageResize: mergedResize
        )
    }
}

public struct SavedAgentAvatarDTO: Codable, Equatable, Sendable {
    public var filepath: String?
    public var source: String?

    public init(filepath: String? = nil, source: String? = nil) {
        self.filepath = filepath
        self.source = source
    }
}

public struct SavedAgentDTO: Codable, Equatable, Sendable {
    public var id: String?
    public var mongoID: String?
    public var name: String?
    public var description: String?
    public var avatar: SavedAgentAvatarDTO?
    public var category: String?
    public var isPublic: Bool?
    public var isEditable: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case mongoID = "_id"
        case name, description, avatar, category, isPublic, isEditable
    }

    public init(
        id: String? = nil,
        mongoID: String? = nil,
        name: String? = nil,
        description: String? = nil,
        avatar: SavedAgentAvatarDTO? = nil,
        category: String? = nil,
        isPublic: Bool? = nil,
        isEditable: Bool? = nil
    ) {
        self.id = id
        self.mongoID = mongoID
        self.name = name
        self.description = description
        self.avatar = avatar
        self.category = category
        self.isPublic = isPublic
        self.isEditable = isEditable
    }

    public func targetOption(baseURL: URL) throws -> ChatTargetOption {
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let identifier = normalized(id) ?? normalized(mongoID) else {
            throw DTOMapperError.missingRequiredField("agent.id")
        }
        let iconURL = TargetIconURLPolicy(
            allowsInsecureLoopback: baseURL.scheme?.lowercased() == "http"
        ).resolve(avatar?.filepath?.nonEmpty, relativeTo: baseURL)?.url
        return ChatTargetOption(
            id: "agent:\(identifier)",
            label: normalized(name) ?? identifier,
            subtitle: normalized(description),
            iconURL: iconURL,
            target: ConversationTarget(endpoint: "agents", agentID: identifier)
        )
    }
}

/// The key check endpoint intentionally returns expiry metadata only, never a
/// provider secret.
public struct UserKeyExpiryDTO: Codable, Equatable, Sendable {
    public var expiresAt: String?

    public init(expiresAt: String? = nil) {
        self.expiresAt = expiresAt
    }
}

public struct AgentListResponseDTO: Codable, Equatable, Sendable {
    public var object: String?
    public var data: [SavedAgentDTO]
    public var firstID: String?
    public var lastID: String?
    public var hasMore: Bool
    public var after: String?

    private enum CodingKeys: String, CodingKey {
        case object, data, after
        case firstID = "first_id"
        case lastID = "last_id"
        case hasMore = "has_more"
    }

    public init(
        object: String? = nil,
        data: [SavedAgentDTO] = [],
        firstID: String? = nil,
        lastID: String? = nil,
        hasMore: Bool = false,
        after: String? = nil
    ) {
        self.object = object
        self.data = data
        self.firstID = firstID
        self.lastID = lastID
        self.hasMore = hasMore
        self.after = after
    }
}

public struct LibreChatMessageDTO: Codable, Equatable, Sendable {
    public var messageID: String?
    public var conversationID: String?
    public var parentMessageID: String?
    public var text: String?
    public var sender: String?
    public var isCreatedByUser: Bool?
    public var model: String?
    public var endpoint: String?
    public var content: [JSONValue]?
    public var files: [LibreChatFileDTO]?
    public var attachments: [JSONValue]?
    public var error: JSONValue?
    public var unfinished: Bool?
    public var finishReason: String?
    public var feedback: LibreChatMessageFeedbackDTO?
    /// Kept permissive because older LibreChat history responses omit these
    /// optional replay fields.  A fresh response with a missing field is an
    /// omitted/empty value; legacy cache decoding remains nil rather than
    /// inventing metadata.
    public var manualSkills: [String]?
    public var quotes: [String]?
    public var createdAt: String?
    public var isTemporary: Bool?
    public var expiredAt: String?
    /// Injected by `GET /api/messages?search=...`; absent from ordinary
    /// conversation-history responses.
    public var title: String?
    /// Injected from the authoritative database message during search.
    public var iconURL: String?

    private enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case conversationID = "conversationId"
        case parentMessageID = "parentMessageId"
        case text, sender, isCreatedByUser, model, endpoint, content, files, attachments, error, unfinished, feedback, createdAt, manualSkills, quotes
        case isTemporary, expiredAt
        case title, iconURL
        case finishReason = "finish_reason"
    }

    public func domainModel(defaultConversationID: ConversationID? = nil) throws -> ChatMessage {
        guard let messageID = messageID?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("message.messageId")
        }
        guard let resolvedConversationID = conversationID?.nonEmpty.map({ ConversationID(rawValue: $0) })
            ?? defaultConversationID else {
            throw DTOMapperError.missingRequiredField("message.conversationId")
        }

        var mappedContent = Self.domainContent(from: content ?? [])
        if mappedContent.isEmpty, let text, !text.isEmpty {
            mappedContent.append(.text(text))
        }
        mappedContent.append(contentsOf: try (files ?? []).map {
            .file(try $0.domainModel())
        })
        var citationReducer = CitationAttachmentReducer()
        var generatedFileReducer = GeneratedFileReducer()
        for attachment in attachments ?? [] {
            // Historical attachments and live SSE payloads enter the same
            // DTO/domain mapping and converge through the same upsert rule.
            if let citation = try? LibreChatCitationAttachmentDTO(value: attachment).domainModel() {
                _ = citationReducer.upsert(citation)
            } else if LibreChatGeneratedFileDTO.canDecode(attachment),
                      let generated = try? LibreChatGeneratedFileDTO(value: attachment).domainModel() {
                _ = generatedFileReducer.upsert(generated.applyingProvenanceFallback(
                    messageID: MessageID(rawValue: messageID),
                    conversationID: resolvedConversationID
                ))
            } else if let content = Self.domainAttachment(attachment) {
                mappedContent.append(content)
            }
        }
        mappedContent.append(contentsOf: generatedFileReducer.files.map(MessageContent.generatedFile))
        if let errorContent = Self.errorContent(from: error),
           !mappedContent.contains(where: {
               if case .error = $0 { return true }
               return false
           }) {
            mappedContent.append(.error(errorContent))
        }
        let author: MessageAuthor = if isCreatedByUser == true {
            .user
        } else {
            .assistant(name: sender?.nonEmpty ?? "Assistant")
        }

        return ChatMessage(
            id: MessageID(rawValue: messageID),
            conversationID: resolvedConversationID,
            parentMessageID: parentMessageID.map { MessageID(rawValue: $0) },
            content: mappedContent.isEmpty ? [.text("")] : mappedContent,
            author: author,
            model: model,
            endpoint: endpoint,
            createdAt: createdAt.flatMap { ISO8601DateFormatter().date(from: $0) },
            isUnfinished: unfinished,
            finishReason: finishReason,
            feedback: try? feedback?.domainModel(),
            manualSkills: manualSkills,
            quotes: quotes,
            citationAttachments: citationReducer.attachments,
            artifactCatalog: Self.artifactCatalog(
                messageID: MessageID(rawValue: messageID),
                content: content ?? [],
                legacyText: text
            ),
            editableTextCatalog: Self.editableTextCatalog(
                primaryText: text,
                content: content ?? []
            )
        )
    }

    /// Preserves the exact coordinates accepted by
    /// `PUT /api/messages/:conversationId/:messageId`. The pinned server only
    /// permits raw `text` and `think` content kinds; permissive render aliases
    /// must not be promoted into editable server coordinates.
    public static func editableTextCatalog(
        primaryText: String?,
        content: [JSONValue]
    ) -> [EditableMessageText] {
        var result: [EditableMessageText] = []
        if let primaryText {
            result.append(EditableMessageText(location: .primaryText, text: primaryText))
        }
        for (index, part) in content.enumerated() {
            guard let object = part.objectValue,
                  let type = object["type"]?.stringValue else { continue }
            switch type {
            case "text":
                guard let text = object["text"]?.stringValue else { continue }
                result.append(EditableMessageText(
                    location: .contentPart(index: index, kind: .text),
                    text: text
                ))
            case "think":
                guard let text = object["think"]?.stringValue else { continue }
                result.append(EditableMessageText(
                    location: .contentPart(index: index, kind: .reasoning),
                    text: text
                ))
            default:
                continue
            }
        }
        return result
    }

    /// Reproduces the artifact edit endpoint's source-selection and global
    /// indexing rules before permissive DTO mapping discards transport
    /// provenance. Only raw `type == "text"` parts with a string `text` are
    /// scanned. Legacy message text is considered only when content contains
    /// no raw artifact boundary at all, including malformed or incomplete
    /// candidates.
    public static func artifactCatalog(
        messageID: MessageID,
        content: [JSONValue],
        legacyText: String?
    ) -> [ParsedArtifact] {
        var artifacts: [ParsedArtifact] = []
        var nextDocumentOrderIndex = 0

        for part in content {
            guard let object = part.objectValue,
                  object["type"]?.stringValue == "text",
                  let partText = object["text"]?.stringValue else { continue }
            let document = ArtifactParser.parse(
                messageID: messageID,
                text: partText,
                startingDocumentOrderIndex: nextDocumentOrderIndex
            )
            artifacts.append(contentsOf: document.artifacts)
            nextDocumentOrderIndex = document.nextDocumentOrderIndex
        }

        if nextDocumentOrderIndex > 0 {
            return artifacts
        }
        guard let legacyText, !legacyText.isEmpty else { return [] }
        return ArtifactParser.parse(messageID: messageID, text: legacyText).artifacts
    }

    public func searchResult() throws -> MessageSearchResult {
        MessageSearchResult(
            message: try domainModel(),
            conversationTitle: title?.nonEmpty ?? "Untitled chat",
            model: model,
            endpoint: endpoint,
            iconURL: iconURL.flatMap(URL.init(string:))
        )
    }

    public static func domainContent(from content: [JSONValue]) -> [MessageContent] {
        return content.compactMap { part in
            guard let object = part.objectValue else {
                return .unsupported(kind: "non_object_content")
            }
            let type = object["type"]?.stringValue ?? "unknown"
            switch type {
            case "text", "text_delta", "output_text":
                return object["text"]?.textValue().map(MessageContent.text)
                    ?? object["content"]?.textValue().map(MessageContent.text)
            case "think", "reasoning", "reasoning_content":
                return object["think"]?.textValue().map(MessageContent.reasoning)
                    ?? object["text"]?.textValue().map(MessageContent.reasoning)
                    ?? object["content"]?.textValue().map(MessageContent.reasoning)
            case "summary":
                let text = object["content"]?.textValue()
                    ?? object["text"]?.textValue()
                    ?? object["summary"]?.textValue()
                    ?? "Summary"
                return .summary(MessageSummaryContent(
                    text: text,
                    tokenCount: object["token_count"]?.intValue ?? object["tokenCount"]?.intValue,
                    model: object["model"]?.stringValue,
                    provider: object["provider"]?.stringValue,
                    isInProgress: object["is_summarizing"]?.boolValue
                        ?? object["isSummarizing"]?.boolValue
                        ?? false
                ))
            case "code":
                guard let code = object["code"]?.stringValue ?? object["text"]?.stringValue else { return nil }
                return .code(CodeContent(language: object["language"]?.stringValue, code: code))
            case "image", "image_url":
                let image = object["image_url"]
                guard let rawURL = object["url"]?.stringValue
                    ?? image?.stringValue
                    ?? image?.objectValue?["url"]?.stringValue,
                      let url = URL(string: rawURL) else { return .unsupported(kind: type) }
                return .image(url, alternativeText: object["alt"]?.stringValue)
            case "image_file":
                let fileValue = object["image_file"] ?? part
                guard let data = try? JSONEncoder().encode(fileValue),
                      let file = try? JSONDecoder().decode(LibreChatFileDTO.self, from: data).domainModel(
                        fallbackFilename: "Image"
                      ) else { return .unsupported(kind: type) }
                return .file(file)
            case "video_url":
                guard let url = mediaURL(from: object, nestedKey: "video_url") else {
                    return .unsupported(kind: type)
                }
                return .video(url, alternativeText: object["alt"]?.stringValue)
            case "input_audio", "audio":
                guard let url = mediaURL(from: object, nestedKey: "input_audio") else {
                    return .unsupported(kind: type)
                }
                return .audio(url, transcript: object["transcript"]?.stringValue)
            case "tool_call", "tool_result":
                return .tool(toolCall(from: object, fallbackType: type))
            case "activity_label", "agent_update", "on_agent_update", "on_subagent_update", "steer":
                let label = object["label"]?.stringValue
                    ?? object["text"]?.textValue()
                    ?? object["name"]?.stringValue
                    ?? (type.contains("agent") ? "Agent activity" : "Activity")
                return .activity(MessageActivityContent(
                    id: object["id"]?.stringValue
                        ?? object["run_id"]?.stringValue
                        ?? object["agent_id"]?.stringValue
                        ?? "\(type):\(label)",
                    label: label,
                    status: object["status"]?.stringValue,
                    isPending: object["pending"]?.boolValue ?? false,
                    agentID: object["agent_id"]?.stringValue ?? object["agentId"]?.stringValue
                ))
            case "error":
                return .error(errorContent(from: part) ?? MessageErrorContent(
                    message: "LibreChat reported an error."
                ))
            default:
                return .unsupported(kind: type)
            }
        }
    }

    static func domainAttachment(_ value: JSONValue) -> MessageContent? {
        guard let object = value.objectValue else { return .unsupported(kind: "attachment") }
        if LibreChatGeneratedFileDTO.canDecode(value),
           let generated = try? LibreChatGeneratedFileDTO(value: value).domainModel() {
            return .generatedFile(generated)
        }
        if object["file_id"]?.stringValue != nil,
           let data = try? JSONEncoder().encode(value),
           let file = try? JSONDecoder().decode(LibreChatFileDTO.self, from: data).domainModel() {
            return .file(file)
        }
        if object["type"]?.stringValue != nil {
            return domainContent(from: [value]).first
        }
        return .unsupported(kind: "attachment")
    }

    private static func mediaURL(from object: [String: JSONValue], nestedKey: String) -> URL? {
        let nested = object[nestedKey]
        let raw = object["url"]?.stringValue
            ?? nested?.stringValue
            ?? nested?.objectValue?["url"]?.stringValue
            ?? object["data"]?.stringValue
        return raw.flatMap(URL.init(string:))
    }

    private static func toolCall(from object: [String: JSONValue], fallbackType: String) -> ToolCall {
        let nested = object["tool_call"]?.objectValue ?? object
        let rawStatus = nested["status"]?.stringValue ?? object["status"]?.stringValue ?? "running"
        let status: ToolCall.Status = switch rawStatus {
        case "pending": .pending
        case "requires_action", "awaiting_approval": .awaitingApproval
        case "completed", "complete", "success": .completed
        case "failed", "error": .failed
        default: .running
        }
        let output = serializedText(nested["output"] ?? object["output"])
        return ToolCall(
            id: nested["id"]?.stringValue
                ?? nested["tool_call_id"]?.stringValue
                ?? object["id"]?.stringValue
                ?? "\(fallbackType)-unknown",
            name: nested["name"]?.stringValue
                ?? nested["tool"]?.stringValue
                ?? object["name"]?.stringValue
                ?? "Tool",
            status: status,
            summary: nested["summary"]?.stringValue ?? output,
            duration: nested["duration"]?.doubleValue ?? object["duration"]?.doubleValue,
            input: serializedText(nested["args"] ?? nested["arguments"] ?? object["input"]),
            output: output,
            progress: nested["progress"]?.doubleValue ?? object["progress"]?.doubleValue,
            authorizationURL: (nested["auth_url"]?.stringValue
                ?? nested["authorization_url"]?.stringValue
                ?? object["auth_url"]?.stringValue).flatMap(URL.init(string:)),
            subagentTrace: subagentTrace(from: nested)
        )
    }

    static func subagentTrace(from object: [String: JSONValue]) -> SubagentTraceSummary? {
        guard let parts = object["subagent_content"]?.arrayValue, !parts.isEmpty else {
            return nil
        }
        var toolNames: [String] = []
        var seenToolNames: Set<String> = []
        var hasResponseText = false
        var hasReasoning = false

        for value in parts.prefix(512) {
            guard let part = value.objectValue else { continue }
            switch part["type"]?.stringValue {
            case "text", "text_delta", "output_text":
                hasResponseText = part["text"]?.textValue()?.isEmpty == false
                    || part["content"]?.textValue()?.isEmpty == false
                    || hasResponseText
            case "think", "reasoning", "reasoning_content":
                hasReasoning = part["think"]?.textValue()?.isEmpty == false
                    || part["text"]?.textValue()?.isEmpty == false
                    || part["content"]?.textValue()?.isEmpty == false
                    || hasReasoning
            case "tool_call", "tool_result":
                let call = part["tool_call"]?.objectValue ?? part
                guard toolNames.count < 64,
                      let rawName = call["name"]?.stringValue,
                      let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                      seenToolNames.insert(name).inserted else { continue }
                toolNames.append(name)
            default:
                continue
            }
        }

        guard hasResponseText || hasReasoning || !toolNames.isEmpty else { return nil }
        return SubagentTraceSummary(
            toolNames: toolNames,
            hasResponseText: hasResponseText,
            hasReasoning: hasReasoning
        )
    }

    private static func serializedText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.textValue(), !text.isEmpty { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func errorContent(from value: JSONValue?) -> MessageErrorContent? {
        guard let value else { return nil }
        if let message = value.stringValue, !message.isEmpty {
            return MessageErrorContent(message: message)
        }
        guard let object = value.objectValue else { return nil }
        let message = object["message"]?.textValue()
            ?? object["error"]?.textValue()
            ?? object["text"]?.textValue()
        guard let message, !message.isEmpty else { return nil }
        return MessageErrorContent(
            code: object["code"]?.stringValue,
            message: message,
            isRecoverable: object["recoverable"]?.boolValue ?? false
        )
    }
}

/// Cursor envelope returned by the current `/api/messages` route. Message
/// search currently returns a null cursor to explicitly mark a terminal page,
/// while the optional representation remains compatible with future paging.
public struct LibreChatMessagePageDTO: Codable, Equatable, Sendable {
    public var messages: [LibreChatMessageDTO]
    public var nextCursor: String?

    public init(messages: [LibreChatMessageDTO], nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = nextCursor
    }

    public func domainSearchPage() throws -> MessageSearchPage {
        MessageSearchPage(
            results: try messages.map { try $0.searchResult() },
            nextCursor: nextCursor,
            fetchedAt: Date()
        )
    }
}

public struct GenerationStartResponseDTO: Codable, Equatable, Sendable {
    public var streamID: String?
    public var conversationID: String?
    public var generationCreatedAt: Int64?
    public var generationProtocolVersion: Int?
    public var status: String?
    public var code: String?
    public var predecessorVerified: Bool?
    public var active: Bool?

    private enum CodingKeys: String, CodingKey {
        case streamID = "streamId"
        case conversationID = "conversationId"
        case generationCreatedAt, generationProtocolVersion, status, code, predecessorVerified, active
    }

    public init(
        streamID: String? = nil,
        conversationID: String? = nil,
        generationCreatedAt: Int64? = nil,
        generationProtocolVersion: Int? = nil,
        status: String? = nil,
        code: String? = nil,
        predecessorVerified: Bool? = nil,
        active: Bool? = nil
    ) {
        self.streamID = streamID
        self.conversationID = conversationID
        self.generationCreatedAt = generationCreatedAt
        self.generationProtocolVersion = generationProtocolVersion
        self.status = status
        self.code = code
        self.predecessorVerified = predecessorVerified
        self.active = active
    }
}

public struct GenerationStatusDTO: Codable, Equatable, Sendable {
    public var active: Bool
    public var streamID: String?
    public var status: String?
    public var createdAt: Int64?
    public var generationProtocolVersion: Int?
    public var aggregatedContent: [JSONValue]?
    public var resumeState: JSONValue?
    public var pendingAction: JSONValue?
    public var unrecoveredSteers: [JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case active, status
        case streamID = "streamId"
        case createdAt, generationProtocolVersion, aggregatedContent, resumeState, pendingAction, unrecoveredSteers
    }

    public init(
        active: Bool,
        streamID: String? = nil,
        status: String? = nil,
        createdAt: Int64? = nil,
        generationProtocolVersion: Int? = nil,
        aggregatedContent: [JSONValue]? = nil,
        resumeState: JSONValue? = nil,
        pendingAction: JSONValue? = nil,
        unrecoveredSteers: [JSONValue]? = nil
    ) {
        self.active = active
        self.streamID = streamID
        self.status = status
        self.createdAt = createdAt
        self.generationProtocolVersion = generationProtocolVersion
        self.aggregatedContent = aggregatedContent
        self.resumeState = resumeState
        self.pendingAction = pendingAction
        self.unrecoveredSteers = unrecoveredSteers
    }
}

public struct ActiveGenerationJobsDTO: Codable, Equatable, Sendable {
    public var activeJobIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case activeJobIDs = "activeJobIds"
    }

    public init(activeJobIDs: [String]) {
        self.activeJobIDs = activeJobIDs
    }
}

public struct StartupConfigDTO: Codable, Equatable, Sendable {
    public var appTitle: String?
    public var emailLoginEnabled: Bool?
    public var registrationEnabled: Bool?
    public var passwordResetEnabled: Bool?
    public var emailEnabled: Bool?
    public var minPasswordLength: Int?
    public var discordLoginEnabled: Bool?
    public var facebookLoginEnabled: Bool?
    public var githubLoginEnabled: Bool?
    public var googleLoginEnabled: Bool?
    public var appleLoginEnabled: Bool?
    public var openidLoginEnabled: Bool?
    public var samlLoginEnabled: Bool?
    public var socialLoginEnabled: Bool?
    public var ldap: JSONValue?
    public var turnstile: JSONValue?
    public var endpoints: JSONValue?
    public var interface: JSONValue?
    public var modelSpecs: JSONValue?
    public var buildInfo: JSONValue?
    public var speech: JSONValue?
    public var mcpServers: JSONValue?
    public var memories: JSONValue?
    public var projects: JSONValue?
    public var sharedLinksEnabled: Bool?
    public var publicSharedLinksEnabled: Bool?
    public var sharedLinksSnapshotFilesEnabled: Bool?
    /// Post-login only. The server may elevate this to true for administrators
    /// even when self-service deletion is globally disabled.
    public var allowAccountDeletion: Bool?
}

public struct MobileAuthenticationConfigDTO: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var authorizationEndpoint: String?
    public var tokenEndpoint: String?
    public var providers: [String]

    public init(
        protocolVersion: Int,
        authorizationEndpoint: String? = nil,
        tokenEndpoint: String? = nil,
        providers: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.providers = providers
    }
}

public struct MobileTokenExchangeRequestDTO: Codable, Equatable, Sendable {
    public var code: String
    public var codeVerifier: String
    public var redirectURI: String

    public init(code: String, codeVerifier: String, redirectURI: String) {
        self.code = code
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
        case redirectURI = "redirect_uri"
    }
}

public struct MobileTokenResponseDTO: Codable, Equatable, Sendable {
    public var token: String?
    public var accessToken: String?
    public var user: LibreChatUserDTO

    public func domainModel() throws -> AuthenticatedSession {
        guard let token = token?.nonEmpty ?? accessToken?.nonEmpty else {
            throw DTOMapperError.missingRequiredField("mobileToken.accessToken")
        }
        return AuthenticatedSession(accessToken: token, user: try user.domainModel())
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
