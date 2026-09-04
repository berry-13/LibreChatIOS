import Foundation
import LibreChatDomain

/// A deliberately permissive preset DTO. LibreChat's preset schema follows
/// the broad conversation parameter surface and evolves without a globally
/// versioned contract, so unknown fields must decode losslessly and then be
/// classified by the mapper.
public struct LibreChatPresetDTO: Decodable, Equatable, Sendable {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(fields) = value else {
            throw DTOMapperError.invalidField("preset")
        }
        self.fields = fields
    }

    public func domainModel() throws -> ChatPreset {
        guard let rawID = string("presetId")?.trimmedNonempty,
              rawID.utf8.count <= 512,
              !rawID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw DTOMapperError.missingRequiredField("preset.presetId")
        }

        var unsupported = Set<String>()
        let endpoint = typedOptionalString("endpoint", unsupported: &unsupported)
        let endpointType = typedOptionalString("endpointType", unsupported: &unsupported)
        let model = typedOptionalString("model", unsupported: &unsupported)
        let agentID = typedOptionalString("agent_id", unsupported: &unsupported)
        let assistantID = typedOptionalString("assistant_id", unsupported: &unsupported)
        let spec = typedOptionalString("spec", unsupported: &unsupported)
        let promptPrefix = typedOptionalString(
            "promptPrefix",
            preserveWhitespace: true,
            maximumUTF16Length: 32_000,
            unsupported: &unsupported
        )

        if endpoint == nil {
            unsupported.insert("endpoint")
        }

        for (key, value) in fields where !Self.nativelyHandledKeys.contains(key) {
            if Self.isExecutionMeaningful(value) {
                unsupported.insert(Self.safeSettingName(key))
            }
        }

        let title = boundedDisplayString("title") ?? "Untitled preset"
        let modelLabel = boundedDisplayString("modelLabel")
            ?? boundedDisplayString("chatGptLabel")
        let isDefault = fields["defaultPreset"]?.boolValue ?? false
        let order = fields["order"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
        let target = endpoint.map {
            ConversationTarget(
                endpoint: $0,
                endpointType: endpointType,
                model: model,
                agentID: agentID,
                assistantID: assistantID,
                spec: spec,
                promptPrefix: promptPrefix
            )
        }

        return ChatPreset(
            id: PresetID(rawValue: rawID),
            title: title,
            isDefault: isDefault,
            order: order,
            modelLabel: modelLabel,
            target: target,
            unsupportedSettings: unsupported.sorted()
        )
    }

    private func string(_ key: String) -> String? {
        fields[key]?.stringValue
    }

    private func typedOptionalString(
        _ key: String,
        preserveWhitespace: Bool = false,
        maximumUTF16Length: Int = 2_048,
        unsupported: inout Set<String>
    ) -> String? {
        guard let value = fields[key] else { return nil }
        if case .null = value { return nil }
        guard case let .string(raw) = value else {
            unsupported.insert(key)
            return nil
        }
        guard raw.utf16.count <= maximumUTF16Length else {
            unsupported.insert(key)
            return nil
        }
        if preserveWhitespace {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
        }
        return raw.trimmedNonempty
    }

    private func boundedDisplayString(_ key: String) -> String? {
        guard let value = string(key)?.trimmedNonempty else { return nil }
        return String(value.prefix(200))
    }

    /// Fields either executed exactly by `ConversationTarget` or known to be
    /// presentation/database metadata. Every other meaningful field blocks
    /// native application until its wire behavior is implemented.
    private static let nativelyHandledKeys: Set<String> = [
        "_id", "__v", "user", "tenantId", "createdAt", "updatedAt",
        "conversationId", "presetId", "title", "defaultPreset", "order",
        "endpoint", "endpointType", "model", "agent_id", "assistant_id",
        "spec", "promptPrefix", "modelLabel", "chatGptLabel", "iconURL",
        "tags", "isArchived"
    ]

    private static func isExecutionMeaningful(_ value: JSONValue) -> Bool {
        switch value {
        case .null:
            false
        case let .string(value):
            !value.isEmpty
        case let .array(values):
            !values.isEmpty
        case let .object(values):
            !values.isEmpty
        case .bool, .number:
            true
        }
    }

    private static func safeSettingName(_ value: String) -> String {
        guard (1...80).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122: true
                  case 45, 46, 95: true // - . _
                  default: false
                  }
              }) else {
            return "unknown setting"
        }
        return value
    }
}

public enum LibreChatPresetsAPI {
    public static func list() -> APIRequest<[LibreChatPresetDTO]> {
        APIRequest(
            path: "api/presets",
            pathComponents: ["api", "presets"],
            retryPolicy: .idempotent(maximumAttempts: 2)
        )
    }

    /// Builds the only native preset-create payload. The target catalog passed
    /// here must have just been fetched by the repository for this operation;
    /// it prevents a stale model/agent selection from being persisted.
    public static func create(
        _ request: PresetCreationRequest,
        validatingAgainst catalog: TargetCatalogSnapshot
    ) throws -> APIRequest<LibreChatPresetDTO> {
        let target = try validatedTarget(request, catalog: catalog)
        return try APIRequest(
            method: .post,
            path: "api/presets",
            pathComponents: ["api", "presets"],
            body: PresetCreationBodyDTO(
                presetID: request.presetID.rawValue,
                title: request.title,
                target: target
            ),
            retryPolicy: .never
        )
    }

    /// Maps only a complete, exact echo of the native-safe fields. In
    /// particular, LibreChat's current `savePreset` route can return a 201
    /// `{ message: ... }` error envelope; that is never treated as success.
    public static func confirmedCreation(
        from response: LibreChatPresetDTO,
        for request: PresetCreationRequest,
        validatingAgainst catalog: TargetCatalogSnapshot
    ) throws -> PresetCreationOutcome {
        let expectedTarget = try validatedTarget(request, catalog: catalog)
        let preset: ChatPreset
        do {
            preset = try response.domainModel()
        } catch {
            throw PresetCreationError.invalidResponse
        }

        guard preset.id == request.presetID,
              preset.title == request.title,
              preset.target == expectedTarget,
              !preset.isDefault,
              preset.unsupportedSettings.isEmpty else {
            throw PresetCreationError.invalidResponse
        }
        return .confirmed(preset)
    }

    private static func validatedTarget(
        _ request: PresetCreationRequest,
        catalog: TargetCatalogSnapshot
    ) throws -> ConversationTarget {
        try validate(request)
        let target = try request.validatedTarget(in: catalog)
        try validate(target: target)
        return target
    }

    private static func validate(_ request: PresetCreationRequest) throws {
        guard isBoundedIdentifier(request.profileID.rawValue) else {
            throw PresetCreationError.invalidProfileID
        }
        guard isBoundedIdentifier(request.accountID.rawValue) else {
            throw PresetCreationError.invalidAccountID
        }
        guard UUID(uuidString: request.presetID.rawValue) != nil else {
            throw PresetCreationError.invalidPresetID
        }
        guard isSingleLineValue(request.title, maximumUTF16Length: 200) else {
            throw PresetCreationError.invalidTitle
        }
        guard isBoundedIdentifier(request.reviewedTarget.optionID) else {
            throw PresetCreationError.invalidTarget
        }
        if let promptPrefix = request.promptPrefix,
           (!isPromptPrefix(promptPrefix)) {
            throw PresetCreationError.invalidPromptPrefix
        }
    }

    private static func validate(target: ConversationTarget) throws {
        guard target.parentMessageID == nil,
              target.ephemeralAgent == nil,
              isSingleLineValue(target.endpoint, maximumUTF16Length: 2_048),
              [target.endpointType, target.model, target.agentID, target.assistantID, target.spec]
                .allSatisfy({ $0.map { isSingleLineValue($0, maximumUTF16Length: 2_048) } ?? true }),
              target.promptPrefix.map(isPromptPrefix) ?? true else {
            throw PresetCreationError.invalidTarget
        }
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        (1...512).contains(value.utf8.count)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isSingleLineValue(_ value: String, maximumUTF16Length: Int) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && value.utf16.count <= maximumUTF16Length
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isPromptPrefix(_ value: String) -> Bool {
        value.utf16.count <= 32_000
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

/// The payload is intentionally private to this adapter. Adding a new server
/// field requires an explicit domain decision and a matching wire-contract
/// test; broad `ConversationTarget` encoding would accidentally persist
/// parent message IDs or ephemeral agent configuration.
private struct PresetCreationBodyDTO: Encodable, Sendable {
    let presetID: String
    let title: String
    let endpoint: String
    let endpointType: String?
    let model: String?
    let agentID: String?
    let assistantID: String?
    let spec: String?
    let promptPrefix: String?

    init(presetID: String, title: String, target: ConversationTarget) {
        self.presetID = presetID
        self.title = title
        endpoint = target.endpoint
        endpointType = target.endpointType
        model = target.model
        agentID = target.agentID
        assistantID = target.assistantID
        spec = target.spec
        promptPrefix = target.promptPrefix
    }

    private enum CodingKeys: String, CodingKey {
        case presetID = "presetId"
        case title, endpoint, endpointType, model
        case agentID = "agent_id"
        case assistantID = "assistant_id"
        case spec, promptPrefix
    }
}

public struct PresetLibraryMapper: Sendable {
    public init() {}

    public func snapshot(
        profileID: ServerProfileID,
        accountID: AccountID,
        fetchedAt: Date = Date(),
        dtos: [LibreChatPresetDTO]
    ) -> PresetLibrarySnapshot {
        var presets: [ChatPreset] = []
        var seen = Set<PresetID>()
        var invalidCount = 0
        var warnings: [PresetLibraryWarning] = []

        for dto in dtos {
            guard let preset = try? dto.domainModel() else {
                invalidCount += 1
                continue
            }
            guard seen.insert(preset.id).inserted else {
                let warning = PresetLibraryWarning.duplicatePresetID(preset.id)
                if !warnings.contains(warning) { warnings.append(warning) }
                continue
            }
            presets.append(preset)
        }
        if invalidCount > 0 {
            warnings.insert(.invalidPresetCount(invalidCount), at: 0)
        }
        return PresetLibrarySnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: fetchedAt,
            presets: presets,
            warnings: warnings
        )
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
