import Foundation
import LibreChatDomain
import Testing
@testable import LibreChatProtocol

struct PresetContractTests {
    @Test func listFactoryUsesExactOwnerScopedRead() {
        let request = LibreChatPresetsAPI.list()

        #expect(request.method == .get)
        #expect(request.path == "api/presets")
        #expect(request.pathComponents == ["api", "presets"])
        #expect(request.authorization == .bearer)
        #expect(request.queryItems.isEmpty)
        #expect(request.body == nil)
        #expect(request.retryPolicy == .idempotent(maximumAttempts: 2))
    }

    @Test func compatiblePresetMapsOnlyExactlySupportedExecutionFields() throws {
        let dto = try JSONDecoder().decode(
            LibreChatPresetDTO.self,
            from: Data(#"{"presetId":"preset-1","title":"Research","defaultPreset":true,"order":2,"endpoint":"openAI","endpointType":"openAI","model":"gpt-5","modelLabel":"Deep research","promptPrefix":"Cite primary sources.","iconURL":"https://example.test/icon.png","tags":["private"],"isArchived":false,"_id":"mongo","__v":0,"future":null}"#.utf8)
        )

        let preset = try dto.domainModel()

        #expect(preset.id == PresetID(rawValue: "preset-1"))
        #expect(preset.title == "Research")
        #expect(preset.isDefault)
        #expect(preset.order == 2)
        #expect(preset.modelLabel == "Deep research")
        #expect(preset.target == ConversationTarget(
            endpoint: "openAI",
            endpointType: "openAI",
            model: "gpt-5",
            promptPrefix: "Cite primary sources."
        ))
        #expect(preset.unsupportedSettings.isEmpty)
        #expect(preset.isNativelyRepresentable)
    }

    @Test func meaningfulUnknownAndUnimplementedFieldsBlockApplicationWithoutBreakingDecode() throws {
        let dto = try JSONDecoder().decode(
            LibreChatPresetDTO.self,
            from: Data(#"{"presetId":"preset-2","title":"Provider tuning","endpoint":"anthropic","model":"claude","temperature":0.4,"web_search":false,"tools":["search"],"presetOverride":{"maxOutputTokens":8000},"emptyFuture":[],"nullFuture":null,"unknownFuture":{"mode":"private"}}"#.utf8)
        )

        let preset = try dto.domainModel()

        #expect(preset.unsupportedSettings == [
            "presetOverride", "temperature", "tools", "unknownFuture", "web_search"
        ])
        #expect(!preset.isNativelyRepresentable)
    }

    @Test func missingOrMistypedRoutingFailsClosedButPresetRemainsBrowsable() throws {
        let missing = LibreChatPresetDTO(fields: [
            "presetId": .string("missing-endpoint"),
            "title": .string("Legacy")
        ])
        let mistyped = LibreChatPresetDTO(fields: [
            "presetId": .string("bad-model"),
            "endpoint": .string("openAI"),
            "model": .number(7)
        ])

        let first = try missing.domainModel()
        let second = try mistyped.domainModel()

        #expect(first.target == nil)
        #expect(first.unsupportedSettings == ["endpoint"])
        #expect(second.target?.endpoint == "openAI")
        #expect(second.target?.model == nil)
        #expect(second.unsupportedSettings == ["model"])
    }

    @Test func mapperPreservesServerOrderAndQuarantinesInvalidAndDuplicateRows() {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let dtos = [
            LibreChatPresetDTO(fields: [
                "presetId": .string("first"), "title": .string("First"),
                "endpoint": .string("openAI")
            ]),
            LibreChatPresetDTO(fields: ["title": .string("Invalid")]),
            LibreChatPresetDTO(fields: [
                "presetId": .string("first"), "title": .string("Duplicate"),
                "endpoint": .string("openAI")
            ]),
            LibreChatPresetDTO(fields: [
                "presetId": .string("last"), "title": .string("Last"),
                "endpoint": .string("anthropic")
            ])
        ]

        let snapshot = PresetLibraryMapper().snapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 50),
            dtos: dtos
        )

        #expect(snapshot.profileID == profileID)
        #expect(snapshot.accountID == accountID)
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 50))
        #expect(snapshot.presets.map(\.id.rawValue) == ["first", "last"])
        #expect(snapshot.warnings == [
            .invalidPresetCount(1),
            .duplicatePresetID(PresetID(rawValue: "first"))
        ])
    }

    @Test func createFactoryUsesOnlyReviewedNativeExecutionKeysAndNeverRetries() throws {
        let request = try creationRequest(
            reviewedTarget: ConversationTarget(
                endpoint: "openAI",
                endpointType: "openAI",
                model: "gpt-5",
                agentID: "agent-1",
                assistantID: "assistant-1",
                spec: "research"
            ),
            promptPrefix: "Cite sources.\nUse primary material."
        )
        let catalog = catalog(for: request, target: request.reviewedTarget.fingerprint.target(promptPrefix: "server-only"))

        let apiRequest = try LibreChatPresetsAPI.create(request, validatingAgainst: catalog)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: try #require(apiRequest.body))

        #expect(apiRequest.method == .post)
        #expect(apiRequest.path == "api/presets")
        #expect(apiRequest.pathComponents == ["api", "presets"])
        #expect(apiRequest.authorization == .bearer)
        #expect(apiRequest.retryPolicy == .never)
        #expect(Set(fields.keys) == [
            "presetId", "title", "endpoint", "endpointType", "model", "agent_id", "assistant_id", "spec", "promptPrefix"
        ])
        #expect(fields["presetId"] == .string("DCE8F380-5A48-4B33-9F10-1F1692F09320"))
        #expect(fields["title"] == .string("Research"))
        #expect(fields["promptPrefix"] == .string("Cite sources.\nUse primary material."))
        #expect(fields["parentMessageId"] == nil)
        #expect(fields["ephemeralAgent"] == nil)
        #expect(fields["defaultPreset"] == nil)
        #expect(fields["order"] == nil)
        #expect(fields["user"] == nil)
        #expect(fields["tools"] == nil)
    }

    @Test func createFactoryOmitsAbsentOptionalFields() throws {
        let target = ConversationTarget(endpoint: "anthropic")
        let request = try creationRequest(reviewedTarget: target)
        let fields = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: try #require(LibreChatPresetsAPI.create(request, validatingAgainst: catalog(for: request, target: target)).body)
        )

        #expect(Set(fields.keys) == ["presetId", "title", "endpoint"])
    }

    @Test func createFactoryRejectsInvalidInputAndTargetDrift() throws {
        let target = ConversationTarget(endpoint: "openAI", model: "gpt-5")
        let request = try creationRequest(reviewedTarget: target)
        let currentCatalog = catalog(for: request, target: target)

        #expect(throws: PresetCreationError.invalidPresetID) {
            let invalid = PresetCreationRequest(
                profileID: request.profileID,
                accountID: request.accountID,
                presetID: PresetID(rawValue: "preset-1"),
                title: request.title,
                reviewedTarget: request.reviewedTarget
            )
            _ = try LibreChatPresetsAPI.create(invalid, validatingAgainst: currentCatalog)
        }
        #expect(throws: PresetCreationError.invalidTitle) {
            let invalid = PresetCreationRequest(
                profileID: request.profileID,
                accountID: request.accountID,
                presetID: request.presetID,
                title: "  ",
                reviewedTarget: request.reviewedTarget
            )
            _ = try LibreChatPresetsAPI.create(invalid, validatingAgainst: currentCatalog)
        }
        #expect(throws: PresetCreationError.reviewedTargetChanged) {
            _ = try LibreChatPresetsAPI.create(
                request,
                validatingAgainst: catalog(for: request, target: ConversationTarget(endpoint: "openAI", model: "other"))
            )
        }
        #expect(throws: PresetCreationError.unsupportedTargetState) {
            _ = try PresetTargetFingerprint(target: ConversationTarget(
                endpoint: "openAI",
                parentMessageID: MessageID(rawValue: "previous")
            ))
        }
    }

    @Test func createResponseRequiresExactSavedPresetAndRejectsMessageOnly201Envelope() throws {
        let target = ConversationTarget(endpoint: "openAI", endpointType: "openAI", model: "gpt-5")
        let request = try creationRequest(reviewedTarget: target, promptPrefix: "Be concise.")
        let catalog = catalog(for: request, target: target)
        let success = try JSONDecoder().decode(
            LibreChatPresetDTO.self,
            from: Data(#"{"presetId":"DCE8F380-5A48-4B33-9F10-1F1692F09320","title":"Research","endpoint":"openAI","endpointType":"openAI","model":"gpt-5","promptPrefix":"Be concise.","defaultPreset":false,"tags":[],"isArchived":false}"#.utf8)
        )

        #expect(try LibreChatPresetsAPI.confirmedCreation(
            from: success,
            for: request,
            validatingAgainst: catalog
        ) == .confirmed(try success.domainModel()))

        let messageOnly = try JSONDecoder().decode(
            LibreChatPresetDTO.self,
            from: Data(#"{"message":"Error saving preset"}"#.utf8)
        )
        #expect(throws: PresetCreationError.invalidResponse) {
            _ = try LibreChatPresetsAPI.confirmedCreation(
                from: messageOnly,
                for: request,
                validatingAgainst: catalog
            )
        }
        let mismatched = try JSONDecoder().decode(
            LibreChatPresetDTO.self,
            from: Data(#"{"presetId":"another","title":"Research","endpoint":"openAI","endpointType":"openAI","model":"gpt-5","promptPrefix":"Be concise."}"#.utf8)
        )
        #expect(throws: PresetCreationError.invalidResponse) {
            _ = try LibreChatPresetsAPI.confirmedCreation(
                from: mismatched,
                for: request,
                validatingAgainst: catalog
            )
        }
    }

    private func creationRequest(
        reviewedTarget: ConversationTarget,
        promptPrefix: String? = nil
    ) throws -> PresetCreationRequest {
        PresetCreationRequest(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            presetID: PresetID(rawValue: "DCE8F380-5A48-4B33-9F10-1F1692F09320"),
            title: "Research",
            reviewedTarget: try PresetTargetReview(option: ChatTargetOption(
                id: "openai-gpt-5",
                label: "GPT-5",
                target: reviewedTarget
            )),
            promptPrefix: promptPrefix
        )
    }

    private func catalog(
        for request: PresetCreationRequest,
        target: ConversationTarget
    ) -> TargetCatalogSnapshot {
        TargetCatalogSnapshot(
            profileID: request.profileID,
            accountID: request.accountID,
            fetchedAt: Date(timeIntervalSince1970: 100),
            options: [ChatTargetOption(
                id: request.reviewedTarget.optionID,
                label: "Reviewed target",
                target: target
            )],
            agentDiscoveryStatus: .notSupported
        )
    }
}
