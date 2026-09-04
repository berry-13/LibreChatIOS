import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class RecentChatTargetTests: XCTestCase {
    func testPreferenceReopensWithExactAccountIsolationAndProfilePurge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatRecentTarget-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "cache.store")
        let firstProfile = ServerProfileID(rawValue: "profile")
        let siblingProfile = ServerProfileID(rawValue: "profile-sibling")
        let firstAccount = AccountID(rawValue: "account")
        let siblingAccount = AccountID(rawValue: "account-sibling")

        var writer: AppDependencies? = try AppDependencies(storeURL: storeURL)
        try await writer?.cache.saveAccount(
            profileID: firstProfile,
            account: UserAccount(id: firstAccount)
        )
        try await writer?.cache.saveAccount(
            profileID: firstProfile,
            account: UserAccount(id: siblingAccount)
        )
        try await writer?.cache.saveAccount(
            profileID: siblingProfile,
            account: UserAccount(id: firstAccount)
        )
        try await writer?.cache.saveRecentChatTargetOptionID(
            "endpoint:openAI:first",
            profileID: firstProfile,
            accountID: firstAccount,
            selectedAt: Date(timeIntervalSince1970: 100)
        )
        try await writer?.cache.saveRecentChatTargetOptionID(
            "endpoint:openAI:sibling-account",
            profileID: firstProfile,
            accountID: siblingAccount,
            selectedAt: Date(timeIntervalSince1970: 101)
        )
        try await writer?.cache.saveRecentChatTargetOptionID(
            "endpoint:openAI:sibling-profile",
            profileID: siblingProfile,
            accountID: firstAccount,
            selectedAt: Date(timeIntervalSince1970: 102)
        )
        writer = nil

        let reader = try AppDependencies(storeURL: storeURL)
        let reopenedFirst = try await reader.cache.recentChatTargetOptionID(
            profileID: firstProfile,
            accountID: firstAccount
        )
        let reopenedSiblingAccount = try await reader.cache.recentChatTargetOptionID(
            profileID: firstProfile,
            accountID: siblingAccount
        )
        let reopenedSiblingProfile = try await reader.cache.recentChatTargetOptionID(
            profileID: siblingProfile,
            accountID: firstAccount
        )
        XCTAssertEqual(reopenedFirst, "endpoint:openAI:first")
        XCTAssertEqual(reopenedSiblingAccount, "endpoint:openAI:sibling-account")
        XCTAssertEqual(reopenedSiblingProfile, "endpoint:openAI:sibling-profile")

        try await reader.cache.purge(profileID: firstProfile)

        let purgedFirst = try await reader.cache.recentChatTargetOptionID(
            profileID: firstProfile,
            accountID: firstAccount
        )
        let purgedSiblingAccount = try await reader.cache.recentChatTargetOptionID(
            profileID: firstProfile,
            accountID: siblingAccount
        )
        let retainedSiblingProfile = try await reader.cache.recentChatTargetOptionID(
            profileID: siblingProfile,
            accountID: firstAccount
        )
        XCTAssertNil(purgedFirst)
        XCTAssertNil(purgedSiblingAccount)
        XCTAssertEqual(retainedSiblingProfile, "endpoint:openAI:sibling-profile")
    }

    func testPreferenceRejectsMalformedOptionWithoutReplacingPriorValue() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        try await dependencies.cache.saveRecentChatTargetOptionID(
            "spec:trusted",
            profileID: profileID,
            accountID: accountID
        )

        do {
            try await dependencies.cache.saveRecentChatTargetOptionID(
                "  ",
                profileID: profileID,
                accountID: accountID
            )
            XCTFail("A blank target option identifier must not be persisted")
        } catch let error as RecentChatTargetPreferenceError {
            XCTAssertEqual(error, .invalidOptionID)
        }
        do {
            try await dependencies.cache.saveRecentChatTargetOptionID(
                String(repeating: "x", count: 2_049),
                profileID: profileID,
                accountID: accountID
            )
            XCTFail("An over-limit target option identifier must not be persisted")
        } catch let error as RecentChatTargetPreferenceError {
            XCTAssertEqual(error, .invalidOptionID)
        }

        let retained = try await dependencies.cache.recentChatTargetOptionID(
            profileID: profileID,
            accountID: accountID
        )
        XCTAssertEqual(retained, "spec:trusted")
    }

    func testRepositoryFeedsStoredRecentTargetIntoFreshCatalogAndIgnoresRemovedOption() async throws {
        RecentTargetURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/config":
                return Self.response(
                    for: request,
                    data: #"{"interface":{"modelSelect":true},"modelSpecs":{"list":[{"name":"soft","softDefault":true,"preset":{"endpoint":"openAI","model":"gpt-4"}}]}}"#
                )
            case "/api/endpoints":
                return Self.response(for: request, data: #"{"openAI":{"order":0}}"#)
            case "/api/models":
                return Self.response(for: request, data: #"{"openAI":["gpt-4","gpt-5"]}"#)
            default:
                return Self.response(for: request, status: 404, data: #"{"message":"not found"}"#)
            }
        }
        defer { RecentTargetURLProtocol.handler = nil }

        let dependencies = try AppDependencies(inMemory: true)
        let (repository, profileID, accountID) = await Self.makeRepository(cache: dependencies.cache)
        try await dependencies.cache.saveRecentChatTargetOptionID(
            "endpoint:openAI:gpt-5",
            profileID: profileID,
            accountID: accountID
        )

        let recent = try await repository.newChatTargetCatalog()
        XCTAssertEqual(recent.effectiveDefaultOptionID, "endpoint:openAI:gpt-5")

        try await dependencies.cache.saveRecentChatTargetOptionID(
            "endpoint:openAI:removed",
            profileID: profileID,
            accountID: accountID
        )
        let removed = try await repository.newChatTargetCatalog()
        XCTAssertEqual(removed.effectiveDefaultOptionID, "spec:soft")
    }

    func testNewChatPersistsExactCurrentTargetOnlyAfterSuccessfulDraftCreation() async throws {
        let target = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let snapshot = TargetCatalogSnapshot(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: [target],
            effectiveDefaultOptionID: target.id,
            agentDiscoveryStatus: .notSupported
        )

        let successful = RecentTargetConversationRepository(catalog: snapshot)
        let successfulModel = ConversationListModel(
            repository: successful,
            isOffline: { false },
            onUnauthorized: {}
        )
        await successfulModel.loadTargets()
        let created = await successfulModel.createConversation(title: "Draft", target: target)
        let successfulEvents = await successful.recordedEvents()
        XCTAssertNotNil(created)
        XCTAssertEqual(successfulEvents, [
            .create("endpoint:openAI:gpt-5"),
            .remember(
                "endpoint:openAI:gpt-5",
                ServerProfileID(rawValue: "profile"),
                AccountID(rawValue: "account")
            )
        ])

        let failing = RecentTargetConversationRepository(catalog: snapshot, failCreation: true)
        let failingModel = ConversationListModel(
            repository: failing,
            isOffline: { false },
            onUnauthorized: {}
        )
        await failingModel.loadTargets()
        let failed = await failingModel.createConversation(title: "Failed", target: target)
        let failingEvents = await failing.recordedEvents()
        XCTAssertNil(failed)
        XCTAssertEqual(failingEvents, [.create("endpoint:openAI:gpt-5")])

        let stale = ChatTargetOption(
            id: "endpoint:openAI:removed",
            label: "Removed",
            target: ConversationTarget(endpoint: "openAI", model: "removed")
        )
        let staleCreation = await successfulModel.createConversation(title: "Stale", target: stale)
        let eventsAfterStaleChoice = await successful.recordedEvents()
        XCTAssertNil(staleCreation)
        XCTAssertEqual(eventsAfterStaleChoice, [
            .create("endpoint:openAI:gpt-5"),
            .remember(
                "endpoint:openAI:gpt-5",
                ServerProfileID(rawValue: "profile"),
                AccountID(rawValue: "account")
            )
        ])

        let serverCreated = RecentTargetConversationRepository(
            catalog: snapshot,
            returnsLocalDraft: false
        )
        let serverCreatedModel = ConversationListModel(
            repository: serverCreated,
            isOffline: { false },
            onUnauthorized: {}
        )
        await serverCreatedModel.loadTargets()
        let canonical = await serverCreatedModel.createConversation(title: "Canonical", target: target)
        let serverCreatedEvents = await serverCreated.recordedEvents()
        XCTAssertNotNil(canonical)
        XCTAssertEqual(serverCreatedEvents, [.create("endpoint:openAI:gpt-5")])
    }

    func testUnsentCanvasNeverInsertsASidebarRowUntilTheServerAssignsIdentity() async throws {
        let target = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let snapshot = TargetCatalogSnapshot(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: [target],
            effectiveDefaultOptionID: target.id,
            agentDiscoveryStatus: .notSupported
        )
        let repository = RecentTargetConversationRepository(catalog: snapshot)
        let model = ConversationListModel(
            repository: repository,
            isOffline: { false },
            onUnauthorized: {}
        )
        await model.loadTargets()

        // LibreChat's contract: the unsent canvas is ephemeral UI state. The
        // sidebar must not gain a row before the server assigns a real id.
        let canvas = await model.createConversation(title: "New Chat", target: target)
        let canvasID = try XCTUnwrap(canvas?.id)
        XCTAssertTrue(model.conversations.isEmpty)

        // The server-assigned conversation arrives through the identity
        // promotion path and becomes the one visible row.
        let assigned = LibreChatDomain.Conversation(
            id: ConversationID(rawValue: "server-assigned"),
            title: "New Chat",
            target: target.target
        )
        model.replaceConversation(id: canvasID, with: assigned)
        XCTAssertEqual(model.conversations.map(\.id), [assigned.id])
    }

    func testReviewedPresetAppliesExactAuthorizedTargetAndPromptOnlyToFreshDraft() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let catalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: [option],
            agentDiscoveryStatus: .notSupported
        )
        let preset = ChatPreset(
            id: PresetID(rawValue: "preset-research"),
            title: "Research",
            target: ConversationTarget(
                endpoint: "openAI",
                model: "gpt-5",
                promptPrefix: "Use primary sources."
            )
        )
        let conversationRepository = RecentTargetConversationRepository(catalog: catalog)
        let presetRepository = RecentPresetRepository(snapshot: PresetLibrarySnapshot(
            profileID: profileID,
            accountID: accountID,
            presets: [preset]
        ))
        let model = ConversationListModel(
            repository: conversationRepository,
            presetRepository: presetRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )

        await model.loadTargets()
        await model.loadPresets()
        XCTAssertEqual(model.presetResolution(preset), .ready(option))
        let created = await model.createConversation(title: "", preset: preset)
        let createdTarget = await conversationRepository.lastCreatedTarget()
        let events = await conversationRepository.recordedEvents()

        XCTAssertNotNil(created)
        XCTAssertEqual(createdTarget, ConversationTarget(
            endpoint: "openAI",
            model: "gpt-5",
            promptPrefix: "Use primary sources."
        ))
        XCTAssertEqual(events, [
            .create("endpoint:openAI:gpt-5"),
            .remember("endpoint:openAI:gpt-5", profileID, accountID)
        ])
    }

    func testPresetWithUnimplementedSettingsRemainsBrowsableButCannotCreate() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let preset = ChatPreset(
            id: PresetID(rawValue: "preset-tuned"),
            title: "Tuned",
            target: option.target,
            unsupportedSettings: ["temperature", "tools"]
        )
        let conversationRepository = RecentTargetConversationRepository(catalog: TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: [option],
            agentDiscoveryStatus: .notSupported
        ))
        let presetRepository = RecentPresetRepository(snapshot: PresetLibrarySnapshot(
            profileID: profileID,
            accountID: accountID,
            presets: [preset]
        ))
        let model = ConversationListModel(
            repository: conversationRepository,
            presetRepository: presetRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )

        await model.loadTargets()
        await model.loadPresets()
        XCTAssertEqual(
            model.presetResolution(preset),
            .unsupportedSettings(["temperature", "tools"])
        )
        let created = await model.createConversation(title: "Unsafe", preset: preset)
        let events = await conversationRepository.recordedEvents()

        XCTAssertNil(created)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNotNil(model.creationError)
    }

    func testPresetRequiresOneExactTargetAndMatchingLiveAccountSnapshot() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let options = [
            ChatTargetOption(
                id: "endpoint:openAI:gpt-4",
                label: "GPT-4",
                target: ConversationTarget(endpoint: "openAI", model: "gpt-4")
            ),
            ChatTargetOption(
                id: "endpoint:openAI:gpt-5",
                label: "GPT-5",
                target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
            )
        ]
        let preset = ChatPreset(
            id: PresetID(rawValue: "preset-ambiguous"),
            title: "Any OpenAI",
            target: ConversationTarget(endpoint: "openAI")
        )
        let conversationRepository = RecentTargetConversationRepository(catalog: TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: options,
            agentDiscoveryStatus: .notSupported
        ))
        let foreignPresetRepository = RecentPresetRepository(snapshot: PresetLibrarySnapshot(
            profileID: profileID,
            accountID: AccountID(rawValue: "foreign"),
            presets: [preset]
        ))
        let model = ConversationListModel(
            repository: conversationRepository,
            presetRepository: foreignPresetRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )

        await model.loadTargets()
        await model.loadPresets()
        XCTAssertEqual(model.presetResolution(preset), .staleOrForeign)

        let matchingPresetRepository = RecentPresetRepository(snapshot: PresetLibrarySnapshot(
            profileID: profileID,
            accountID: accountID,
            presets: [preset]
        ))
        let ambiguousModel = ConversationListModel(
            repository: conversationRepository,
            presetRepository: matchingPresetRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )
        await ambiguousModel.loadTargets()
        await ambiguousModel.loadPresets()
        XCTAssertEqual(ambiguousModel.presetResolution(preset), .ambiguousTarget)
    }

    func testPresetCreationDraftValidatesBoundariesWithoutNormalizingInstructions() {
        var draft = PresetCreationDraft()
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(draft.validationMessage, "Enter a preset name.")

        draft.title = "  Research  "
        draft.promptPrefix = "\nKeep this indentation.\n"
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.normalizedTitle, "Research")
        XCTAssertEqual(draft.normalizedPromptPrefix, "\nKeep this indentation.\n")

        draft.title = String(repeating: "a", count: 201)
        XCTAssertFalse(draft.canSave)
        draft.title = "Valid"
        draft.promptPrefix = String(repeating: "b", count: 32_001)
        XCTAssertFalse(draft.canSave)
        draft.title = "Invalid\nname"
        draft.promptPrefix = ""
        XCTAssertFalse(draft.canSave)
        draft.title = "Valid"
        draft.promptPrefix = "Unsafe\0instructions"
        XCTAssertFalse(draft.canSave)
    }

    func testModelCreatesPresetFromExactReviewedTargetAndInstallsConfirmedResult() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let catalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: [option],
            agentDiscoveryStatus: .notSupported
        )
        let created = ChatPreset(
            id: PresetID(rawValue: "00000000-0000-4000-8000-000000000001"),
            title: "Research",
            target: ConversationTarget(
                endpoint: "openAI",
                model: "gpt-5",
                promptPrefix: "Use primary sources."
            )
        )
        let conversationRepository = RecentTargetConversationRepository(catalog: catalog)
        let creationRepository = RecentPresetCreationRepository(
            catalog: catalog,
            outcomeBuilder: { request in
                .confirmed(ChatPreset(
                    id: request.presetID,
                    title: request.title,
                    target: request.reviewedTarget.fingerprint.target(
                        promptPrefix: request.promptPrefix
                    )
                ))
            }
        )
        let model = ConversationListModel(
            repository: conversationRepository,
            presetRepository: RecentPresetRepository(snapshot: PresetLibrarySnapshot(
                profileID: profileID,
                accountID: accountID,
                presets: []
            )),
            presetCreationRepository: creationRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )

        await model.loadTargets()
        await model.loadPresets()
        let outcome = try await model.createPreset(
            title: created.title,
            promptPrefix: created.target?.promptPrefix,
            reviewedTarget: option
        )
        guard case let .confirmed(saved) = outcome else {
            return XCTFail("Expected a confirmed preset")
        }
        let requests = await creationRepository.recordedRequests()

        XCTAssertEqual(saved.title, "Research")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.profileID, profileID)
        XCTAssertEqual(requests.first?.accountID, accountID)
        XCTAssertEqual(requests.first?.reviewedTarget.optionID, option.id)
        XCTAssertNotNil(UUID(uuidString: requests.first?.presetID.rawValue ?? ""))
        XCTAssertEqual(model.availablePresets, [saved])
        XCTAssertEqual(model.presetResolution(saved), .ready(option))
    }

    func testUnknownPresetCreationRequiresSuccessfulRefreshBeforeAnotherAttempt() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let catalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(),
            options: [option],
            agentDiscoveryStatus: .notSupported
        )
        let creationRepository = RecentPresetCreationRepository(
            catalog: catalog,
            outcomeBuilder: { _ in .outcomeUnknown(.reconciliationUnavailable) }
        )
        let model = ConversationListModel(
            repository: RecentTargetConversationRepository(catalog: catalog),
            presetRepository: RecentPresetRepository(snapshot: PresetLibrarySnapshot(
                profileID: profileID,
                accountID: accountID,
                presets: []
            )),
            presetCreationRepository: creationRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )
        await model.loadTargets()
        await model.loadPresets()

        let first = try await model.createPreset(
            title: "Research",
            promptPrefix: nil,
            reviewedTarget: option
        )
        XCTAssertEqual(first, .outcomeUnknown(.reconciliationUnavailable))
        XCTAssertTrue(model.presetCreationRequiresRefresh)

        do {
            _ = try await model.createPreset(
                title: "Research",
                promptPrefix: nil,
                reviewedTarget: option
            )
            XCTFail("An ambiguous creation must not be blindly resubmitted")
        } catch {
            let requestCount = await creationRepository.recordedRequests().count
            XCTAssertEqual(requestCount, 1)
        }

        await model.loadPresets(forceRefresh: true)
        XCTAssertFalse(model.presetCreationRequiresRefresh)
    }

    func testModelRejectsChangedReviewedPresetTargetBeforeRepositoryMutation() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let current = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let changed = ChatTargetOption(
            id: current.id,
            label: current.label,
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5-latest")
        )
        let catalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(),
            options: [current],
            agentDiscoveryStatus: .notSupported
        )
        let creationRepository = RecentPresetCreationRepository(
            catalog: catalog,
            outcomeBuilder: { _ in .outcomeUnknown(.reconciliationUnavailable) }
        )
        let model = ConversationListModel(
            repository: RecentTargetConversationRepository(catalog: catalog),
            presetRepository: RecentPresetRepository(snapshot: PresetLibrarySnapshot(
                profileID: profileID,
                accountID: accountID,
                presets: []
            )),
            presetCreationRepository: creationRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )
        await model.loadTargets()
        await model.loadPresets()

        do {
            _ = try await model.createPreset(
                title: "Changed",
                promptPrefix: nil,
                reviewedTarget: changed
            )
            XCTFail("A changed target must fail before mutation")
        } catch let error as PresetCreationError {
            XCTAssertEqual(error, .reviewedTargetChanged)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requestCount = await creationRepository.recordedRequests().count
        XCTAssertEqual(requestCount, 0)
    }

    func testDisabledPresetCapabilityHidesLibraryAndBlocksCreationWithoutNetwork() async {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let catalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(),
            options: [option],
            agentDiscoveryStatus: .notSupported
        )
        let library = CountingPresetRepository(snapshot: PresetLibrarySnapshot(
            profileID: profileID,
            accountID: accountID,
            presets: [ChatPreset(
                id: PresetID(rawValue: "hidden"),
                title: "Hidden",
                target: option.target
            )]
        ))
        let creation = RecentPresetCreationRepository(
            catalog: catalog,
            outcomeBuilder: { _ in .outcomeUnknown(.reconciliationUnavailable) }
        )
        let model = ConversationListModel(
            repository: RecentTargetConversationRepository(catalog: catalog),
            presetRepository: library,
            presetCreationRepository: creation,
            isOffline: { false },
            presetsEnabled: { false },
            onUnauthorized: {}
        )
        await model.loadTargets()
        await model.loadPresets()

        XCTAssertFalse(model.canUsePresets)
        XCTAssertTrue(model.availablePresets.isEmpty)
        let libraryLoadCount = await library.loadCount()
        XCTAssertEqual(libraryLoadCount, 0)
        do {
            _ = try await model.createPreset(
                title: "Blocked",
                promptPrefix: nil,
                reviewedTarget: option
            )
            XCTFail("Disabled preset policy must block creation")
        } catch {
            let createCount = await creation.recordedRequests().count
            XCTAssertEqual(createCount, 0)
        }
    }

    func testConfirmedPresetRemainsVisibleButCannotApplyAfterTargetAuthorizationChanges() async throws {
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let reviewedCatalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1),
            options: [option],
            agentDiscoveryStatus: .notSupported
        )
        let revokedCatalog = TargetCatalogSnapshot(
            profileID: profileID,
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 2),
            options: [],
            agentDiscoveryStatus: .notSupported
        )
        let conversationRepository = RecentTargetConversationRepository(
            catalog: reviewedCatalog,
            newChatCatalogSequence: [reviewedCatalog, revokedCatalog]
        )
        let creationRepository = RecentPresetCreationRepository(
            catalog: reviewedCatalog,
            outcomeBuilder: { request in
                .confirmed(ChatPreset(
                    id: request.presetID,
                    title: request.title,
                    target: request.reviewedTarget.fingerprint.target(
                        promptPrefix: request.promptPrefix
                    )
                ))
            }
        )
        let model = ConversationListModel(
            repository: conversationRepository,
            presetRepository: RecentPresetRepository(snapshot: PresetLibrarySnapshot(
                profileID: profileID,
                accountID: accountID,
                presets: []
            )),
            presetCreationRepository: creationRepository,
            isOffline: { false },
            presetsEnabled: { true },
            onUnauthorized: {}
        )
        await model.loadTargets()
        await model.loadPresets()

        let outcome = try await model.createPreset(
            title: "Revoked",
            promptPrefix: nil,
            reviewedTarget: option
        )
        guard case let .confirmed(preset) = outcome else {
            return XCTFail("The owner row itself was authoritatively created")
        }

        XCTAssertEqual(model.availablePresets, [preset])
        XCTAssertEqual(model.presetResolution(preset), .targetUnavailable)
        XCTAssertTrue(model.availableTargets.isEmpty)
    }

    func testLivePresetRepositoryUsesAuthenticatedAccountScopedSnapshot() async throws {
        RecentTargetURLProtocol.handler = { request in
            if request.url?.path == "/api/presets" {
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer token" else {
                    return Self.response(
                        for: request,
                        status: 401,
                        data: #"{"message":"missing bearer"}"#
                    )
                }
                return Self.response(
                    for: request,
                    data: #"[{"presetId":"preset-live","title":"Live","endpoint":"openAI","model":"gpt-5","future":null}]"#
                )
            }
            return Self.response(for: request, status: 404, data: #"{"message":"not found"}"#)
        }
        defer { RecentTargetURLProtocol.handler = nil }

        let dependencies = try AppDependencies(inMemory: true)
        let (repository, profileID, accountID) = await Self.makeRepository(cache: dependencies.cache)
        let snapshot = try await repository.presets()

        XCTAssertEqual(snapshot.profileID, profileID)
        XCTAssertEqual(snapshot.accountID, accountID)
        XCTAssertEqual(snapshot.presets.map(\.id.rawValue), ["preset-live"])
        XCTAssertTrue(snapshot.presets[0].isNativelyRepresentable)
    }

    func testLivePresetCreationPostsOnlyReviewedSafeFields() async throws {
        let presetID = PresetID(rawValue: "8C98C702-5360-4E47-B8A7-52D193837B03")
        let state = RecentPresetMutationState()
        RecentTargetURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/api/config"):
                return Self.response(for: request, data: #"{"interface":{"modelSelect":true}}"#)
            case (_, "/api/endpoints"):
                return Self.response(for: request, data: #"{"openAI":{"order":0}}"#)
            case (_, "/api/models"):
                return Self.response(for: request, data: #"{"openAI":["gpt-5"]}"#)
            case ("POST", "/api/presets"):
                state.recordPost(request)
                return Self.response(
                    for: request,
                    status: 201,
                    data: #"{"presetId":"8C98C702-5360-4E47-B8A7-52D193837B03","title":"Research","endpoint":"openAI","model":"gpt-5","promptPrefix":"Use primary sources."}"#
                )
            default:
                return Self.response(for: request, status: 404, data: #"{"message":"not found"}"#)
            }
        }
        defer { RecentTargetURLProtocol.handler = nil }

        let dependencies = try AppDependencies(inMemory: true)
        let (repository, profileID, accountID) = await Self.makeRepository(cache: dependencies.cache)
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let outcome = try await repository.createPreset(PresetCreationRequest(
            profileID: profileID,
            accountID: accountID,
            presetID: presetID,
            title: "Research",
            reviewedTarget: try PresetTargetReview(option: option),
            promptPrefix: "Use primary sources."
        ))
        guard case let .confirmed(preset) = outcome else {
            return XCTFail("Expected direct create confirmation")
        }
        let capture = state.capture()
        let body = try XCTUnwrap(capture.bodies.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(preset.id, presetID)
        XCTAssertEqual(capture.postCount, 1)
        XCTAssertTrue(capture.allAuthenticated)
        XCTAssertEqual(Set(json.keys), ["presetId", "title", "endpoint", "model", "promptPrefix"])
        XCTAssertNil(json["defaultPreset"])
        XCTAssertNil(json["order"])
        XCTAssertNil(json["user"])
        XCTAssertNil(json["tools"])
    }

    func testAmbiguousPresetCreationReconcilesByExactIDWithoutSecondPost() async throws {
        let presetID = PresetID(rawValue: "7E0E2E14-AEE1-4B61-83E3-EC5FD264DE09")
        let state = RecentPresetMutationState()
        RecentTargetURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/api/config"):
                return Self.response(for: request, data: #"{"interface":{"modelSelect":true}}"#)
            case (_, "/api/endpoints"):
                return Self.response(for: request, data: #"{"openAI":{"order":0}}"#)
            case (_, "/api/models"):
                return Self.response(for: request, data: #"{"openAI":["gpt-5"]}"#)
            case ("POST", "/api/presets"):
                state.recordPost(request)
                return Self.response(
                    for: request,
                    status: 503,
                    data: #"{"message":"response unavailable"}"#
                )
            case ("GET", "/api/presets"):
                state.recordGet(request)
                return Self.response(
                    for: request,
                    data: #"[{"presetId":"7E0E2E14-AEE1-4B61-83E3-EC5FD264DE09","title":"Research","endpoint":"openAI","model":"gpt-5"}]"#
                )
            default:
                return Self.response(for: request, status: 404, data: #"{"message":"not found"}"#)
            }
        }
        defer { RecentTargetURLProtocol.handler = nil }

        let dependencies = try AppDependencies(inMemory: true)
        let (repository, profileID, accountID) = await Self.makeRepository(cache: dependencies.cache)
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let outcome = try await repository.createPreset(PresetCreationRequest(
            profileID: profileID,
            accountID: accountID,
            presetID: presetID,
            title: "Research",
            reviewedTarget: try PresetTargetReview(option: option)
        ))
        let capture = state.capture()

        guard case let .confirmed(preset) = outcome else {
            return XCTFail("Expected owner-directory reconciliation")
        }
        XCTAssertEqual(preset.id, presetID)
        XCTAssertEqual(capture.postCount, 1)
        XCTAssertEqual(capture.getCount, 1)
        XCTAssertTrue(capture.allAuthenticated)
    }

    func testAmbiguousPresetCreationDoesNotConfirmAgainstRevokedTarget() async throws {
        let presetID = PresetID(rawValue: "1D8B57EF-E09B-4E38-9E60-6B1A4DD9E739")
        let state = RecentPresetMutationState()
        RecentTargetURLProtocol.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case (_, "/api/config"):
                return Self.response(for: request, data: #"{"interface":{"modelSelect":true}}"#)
            case (_, "/api/endpoints"):
                return Self.response(for: request, data: #"{"openAI":{"order":0}}"#)
            case (_, "/api/models"):
                let read = state.recordModelRead(request)
                return Self.response(
                    for: request,
                    data: read == 1 ? #"{"openAI":["gpt-5"]}"# : #"{"openAI":["gpt-4.1"]}"#
                )
            case ("POST", "/api/presets"):
                state.recordPost(request)
                return Self.response(
                    for: request,
                    status: 503,
                    data: #"{"message":"response unavailable"}"#
                )
            case ("GET", "/api/presets"):
                state.recordGet(request)
                return Self.response(
                    for: request,
                    data: #"[{"presetId":"1D8B57EF-E09B-4E38-9E60-6B1A4DD9E739","title":"Research","endpoint":"openAI","model":"gpt-5"}]"#
                )
            default:
                return Self.response(for: request, status: 404, data: #"{"message":"not found"}"#)
            }
        }
        defer { RecentTargetURLProtocol.handler = nil }

        let dependencies = try AppDependencies(inMemory: true)
        let (repository, profileID, accountID) = await Self.makeRepository(cache: dependencies.cache)
        let option = ChatTargetOption(
            id: "endpoint:openAI:gpt-5",
            label: "GPT-5",
            target: ConversationTarget(endpoint: "openAI", model: "gpt-5")
        )
        let outcome = try await repository.createPreset(PresetCreationRequest(
            profileID: profileID,
            accountID: accountID,
            presetID: presetID,
            title: "Research",
            reviewedTarget: try PresetTargetReview(option: option)
        ))
        let capture = state.capture()

        XCTAssertEqual(outcome, .outcomeUnknown(.responseLostAfterDispatch))
        XCTAssertEqual(capture.postCount, 1)
        XCTAssertEqual(capture.getCount, 1)
        XCTAssertEqual(capture.modelReadCount, 2)
        XCTAssertTrue(capture.allAuthenticated)
    }

    private static func makeRepository(
        cache: CacheCoordinator
    ) async -> (LibreChatRepository, ServerProfileID, AccountID) {
        let profileID = ServerProfileID(rawValue: "profile")
        let account = UserAccount(id: AccountID(rawValue: "account"))
        let baseURL = URL(string: "https://chat.example.com")!
        let profile = ServerProfile(
            id: profileID,
            baseURL: baseURL,
            displayName: "Test",
            accountIdentifier: account.id
        )
        let jar = ProfileCookieJar(
            profileID: profile.id,
            baseURL: baseURL,
            secretStore: RecentTargetSecretStore()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecentTargetURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let transport = HTTPTransport(
            baseURL: baseURL,
            session: URLSession(configuration: configuration),
            cookieJar: jar
        )
        let auth = AuthSession.isolated(transport: transport)
        await auth.setAuthenticated(AuthenticatedSession(accessToken: "token", user: account))
        let runtime = LibreChatRuntime(
            cookieJar: jar,
            transport: transport,
            authSession: auth,
            restClient: RESTClient(transport: transport, authSession: auth)
        )
        return (
            LibreChatRepository(profile: profile, runtime: runtime, cache: cache),
            profileID,
            account.id
        )
    }

    nonisolated private static func response(
        for request: URLRequest,
        status: Int = 200,
        data: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(data.utf8))
    }
}

private actor RecentTargetConversationRepository: ConversationListFeatureRepository {
    enum Event: Equatable {
        case create(String)
        case remember(String, ServerProfileID, AccountID)
    }

    private let catalog: TargetCatalogSnapshot
    private var newChatCatalogSequence: [TargetCatalogSnapshot]
    private let failCreation: Bool
    private let returnsLocalDraft: Bool
    private var events: [Event] = []
    private var createdTarget: ConversationTarget?

    init(
        catalog: TargetCatalogSnapshot,
        failCreation: Bool = false,
        returnsLocalDraft: Bool = true,
        newChatCatalogSequence: [TargetCatalogSnapshot]? = nil
    ) {
        self.catalog = catalog
        self.newChatCatalogSequence = newChatCatalogSequence ?? [catalog]
        self.failCreation = failCreation
        self.returnsLocalDraft = returnsLocalDraft
    }

    func recordedEvents() -> [Event] { events }
    func lastCreatedTarget() -> ConversationTarget? { createdTarget }
    func cachedConversations(limit: Int) -> ConversationPage? { nil }
    func conversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func archivedConversations(cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func conversation(id: ConversationID) throws -> Conversation {
        throw RecentTargetTestError.unused
    }
    func cachedMessages(conversationID: ConversationID) -> [ChatMessage] { [] }
    func messages(conversationID: ConversationID) -> [ChatMessage] { [] }
    func searchConversations(query: String, cursor: String?, limit: Int) -> ConversationPage {
        ConversationPage(conversations: [])
    }
    func searchMessages(query: String) -> MessageSearchPage { MessageSearchPage(results: []) }
    func availableChatTargets() -> [ChatTargetOption] { catalog.options }
    func targetCatalog(recentOptionID: String?) -> TargetCatalogSnapshot { catalog }
    func newChatTargetCatalog() -> TargetCatalogSnapshot {
        guard newChatCatalogSequence.count > 1 else {
            return newChatCatalogSequence.first ?? catalog
        }
        return newChatCatalogSequence.removeFirst()
    }
    func rememberRecentChatTargetOptionID(
        _ optionID: String,
        profileID: ServerProfileID,
        accountID: AccountID
    ) {
        events.append(.remember(optionID, profileID, accountID))
    }
    func createConversation(title: String, target: ConversationTarget) throws -> Conversation {
        createdTarget = target
        let optionID = catalog.options.first(where: {
            $0.target.endpoint == target.endpoint
                && $0.target.endpointType == target.endpointType
                && $0.target.model == target.model
                && $0.target.agentID == target.agentID
                && $0.target.assistantID == target.assistantID
                && $0.target.spec == target.spec
        })?.id ?? "unknown"
        events.append(.create(optionID))
        if failCreation { throw RecentTargetTestError.creationFailed }
        return Conversation(
            id: returnsLocalDraft
                ? ConversationID(localDraftID: UUID())
                : ConversationID(rawValue: "server-created"),
            title: title,
            target: target
        )
    }
    func delete(id: ConversationID) {}
    func rename(id: ConversationID, title: String) throws -> Conversation { throw RecentTargetTestError.unused }
    func archive(id: ConversationID, isArchived: Bool) throws -> Conversation { throw RecentTargetTestError.unused }
    func pin(id: ConversationID, pinned: Bool) throws -> Conversation { throw RecentTargetTestError.unused }
}

private actor RecentPresetRepository: PresetRepository {
    let snapshot: PresetLibrarySnapshot

    init(snapshot: PresetLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func presets() -> PresetLibrarySnapshot { snapshot }
}

private actor CountingPresetRepository: PresetRepository {
    let snapshot: PresetLibrarySnapshot
    private var reads = 0

    init(snapshot: PresetLibrarySnapshot) {
        self.snapshot = snapshot
    }

    func loadCount() -> Int { reads }

    func presets() -> PresetLibrarySnapshot {
        reads += 1
        return snapshot
    }
}

private actor RecentPresetCreationRepository: PresetCreationRepository {
    let catalog: TargetCatalogSnapshot
    let outcomeBuilder: @Sendable (PresetCreationRequest) -> PresetCreationOutcome
    private var requests: [PresetCreationRequest] = []

    init(
        catalog: TargetCatalogSnapshot,
        outcomeBuilder: @escaping @Sendable (PresetCreationRequest) -> PresetCreationOutcome
    ) {
        self.catalog = catalog
        self.outcomeBuilder = outcomeBuilder
    }

    func recordedRequests() -> [PresetCreationRequest] { requests }

    func targetCatalog(recentOptionID: String?) -> TargetCatalogSnapshot { catalog }

    func createPreset(_ request: PresetCreationRequest) -> PresetCreationOutcome {
        requests.append(request)
        return outcomeBuilder(request)
    }
}

private enum RecentTargetTestError: Error {
    case creationFailed
    case unused
}

private actor RecentTargetSecretStore: SecretStore {
    private var values: [String: Data] = [:]
    func data(for key: String) -> Data? { values[key] }
    func set(_ data: Data, for key: String) { values[key] = data }
    func remove(_ key: String) { values[key] = nil }
}

private final class RecentTargetURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// The loading system hands custom protocols a request whose `httpBody`
    /// was converted into a one-shot `httpBodyStream`; materialize it back so
    /// mutation-state captures can keep reading `httpBody`.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            request.httpBody = data
        }
        return request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RecentPresetMutationState: @unchecked Sendable {
    struct Capture {
        let postCount: Int
        let getCount: Int
        let modelReadCount: Int
        let bodies: [Data]
        let allAuthenticated: Bool
    }

    private let lock = NSLock()
    private var postCount = 0
    private var getCount = 0
    private var modelReadCount = 0
    private var bodies: [Data] = []
    private var allAuthenticated = true

    func recordPost(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        postCount += 1
        if let body = request.httpBody { bodies.append(body) }
        allAuthenticated = allAuthenticated
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer token"
    }

    func recordGet(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        getCount += 1
        allAuthenticated = allAuthenticated
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer token"
    }

    func recordModelRead(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        modelReadCount += 1
        allAuthenticated = allAuthenticated
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer token"
        return modelReadCount
    }

    func capture() -> Capture {
        lock.lock()
        defer { lock.unlock() }
        return Capture(
            postCount: postCount,
            getCount: getCount,
            modelReadCount: modelReadCount,
            bodies: bodies,
            allAuthenticated: allAuthenticated
        )
    }
}
