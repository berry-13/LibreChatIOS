import Foundation
import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class ReadAloudTests: XCTestCase {
    func testUnsupportedFreshCapabilityFailsBeforeSynthesisAndCannotRetry() async {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: false
            ))
        )
        let player = ReadAloudPlayerDouble()
        let model = makeModel(repository: repository, player: player)
        let selection = try! XCTUnwrap(model.selection(for: Self.assistantMessage()))

        await model.perform(selection)

        let synthesisCount = await repository.synthesisCount()
        XCTAssertEqual(synthesisCount, 0)
        guard case let .failed(failedSelection, message, canRetry) = model.phase else {
            return XCTFail("Expected an unavailable failure")
        }
        XCTAssertEqual(failedSelection, selection)
        XCTAssertEqual(message, "Read aloud is not enabled on this LibreChat server.")
        XCTAssertFalse(canRetry)
    }

    func testStartUsesPreferredVoiceAndRateThenPauseResumeAndStopDoNotResynthesize() async {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true,
                preferredSynthesisVoice: "nova",
                preferredPlaybackRate: 1.25
            )),
            synthesisOutcomes: [.success(Self.audio)]
        )
        let player = ReadAloudPlayerDouble()
        let model = makeModel(repository: repository, player: player)
        let selection = try! XCTUnwrap(model.selection(for: Self.assistantMessage()))

        await model.perform(selection)
        guard case .playing(selection, _, _) = model.phase else {
            return XCTFail("Expected playback")
        }
        let startedSynthesisCount = await repository.synthesisCount()
        let request = await repository.lastRequest()
        let rate = await player.lastRate()
        XCTAssertEqual(startedSynthesisCount, 1)
        XCTAssertEqual(request?.voice, "nova")
        XCTAssertEqual(rate, 1.25)

        await model.perform(selection)
        guard case .paused(selection, _, _, false) = model.phase else {
            return XCTFail("Expected an explicit pause")
        }
        await model.perform(selection)
        guard case .playing(selection, _, _) = model.phase else {
            return XCTFail("Expected resumed playback")
        }
        let finalSynthesisCount = await repository.synthesisCount()
        let pauseCount = await player.pauseCount()
        let resumeCount = await player.resumeCount()
        XCTAssertEqual(finalSynthesisCount, 1)
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 1)

        await model.applicationBecameInactive()
        XCTAssertEqual(model.phase, .idle)
        let inactiveStopCount = await player.stopCount()
        XCTAssertGreaterThanOrEqual(inactiveStopCount, 2)
    }

    func testStoredSpecificVoiceOverridesServerConfiguredPreference() async throws {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true,
                preferredSynthesisVoice: "nova"
            )),
            synthesisOutcomes: [.success(Self.audio)],
            preference: .success(.specific(SpeechSynthesisVoice(id: "echo")))
        )
        let model = makeModel(repository: repository, player: ReadAloudPlayerDouble())
        let selection = try XCTUnwrap(model.selection(for: Self.assistantMessage()))

        await model.perform(selection)

        let request = await repository.lastRequest()
        XCTAssertEqual(request?.voice, "echo")
        XCTAssertEqual(model.voicePreference, .specific(SpeechSynthesisVoice(id: "echo")))
    }

    func testVoiceCatalogFallsBackFromRemovedPreferenceWithoutSynthesizing() async {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true,
                preferredSynthesisVoice: "nova"
            )),
            voices: .success([
                SpeechSynthesisVoice(id: "nova"),
                SpeechSynthesisVoice(id: "alloy"),
            ]),
            preference: .success(.specific(SpeechSynthesisVoice(id: "retired")))
        )
        let model = makeModel(repository: repository, player: ReadAloudPlayerDouble())

        await model.loadVoiceChoices()

        XCTAssertEqual(
            model.voiceCatalogState,
            .loaded(
                voices: [
                    SpeechSynthesisVoice(id: "nova"),
                    SpeechSynthesisVoice(id: "alloy"),
                ],
                serverPreferredVoice: "nova"
            )
        )
        XCTAssertEqual(model.voicePreference, .serverDefault)
        XCTAssertTrue(model.voicePreferenceMessage?.contains("no longer advertised") == true)
        let writes = await repository.savedPreferences()
        let synthesisCount = await repository.synthesisCount()
        XCTAssertEqual(writes, [.serverDefault])
        XCTAssertEqual(synthesisCount, 0)
    }

    func testVoicePickerSavesOnlyAnExactlyAdvertisedOpaqueVoice() async {
        let advertised = SpeechSynthesisVoice(id: "voice/opaque:01")
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true
            )),
            voices: .success([advertised])
        )
        let model = makeModel(repository: repository, player: ReadAloudPlayerDouble())
        await model.loadVoiceChoices()

        let rejected = await model.saveVoicePreference(
            .specific(SpeechSynthesisVoice(id: "not-advertised"))
        )
        XCTAssertFalse(rejected)
        XCTAssertTrue(model.voicePreferenceMessage?.contains("no longer advertised") == true)
        let writesAfterRejection = await repository.savedPreferences()
        XCTAssertTrue(writesAfterRejection.isEmpty)

        let saved = await model.saveVoicePreference(.specific(advertised))
        XCTAssertTrue(saved)
        XCTAssertEqual(model.voicePreference, .specific(advertised))
        XCTAssertEqual(model.selectedVoiceLabel, advertised.id)
        let writes = await repository.savedPreferences()
        XCTAssertEqual(writes, [.specific(advertised)])
    }

    func testVoicePreferenceCacheIsProfileAccountIsolatedAndPurged() async throws {
        let dependencies = try AppDependencies(inMemory: true)
        let profileA = ServerProfileID(rawValue: "profile-a")
        let profileB = ServerProfileID(rawValue: "profile-b")
        let accountA = AccountID(rawValue: "account-a")
        let accountB = AccountID(rawValue: "account-b")
        let selected = SpeechSynthesisVoicePreference.specific(
            SpeechSynthesisVoice(id: "opaque-voice")
        )

        try await dependencies.cache.saveSpeechSynthesisVoicePreference(
            selected,
            profileID: profileA,
            accountID: accountA
        )
        let exact = try await dependencies.cache.speechSynthesisVoicePreference(
            profileID: profileA,
            accountID: accountA
        )
        let otherAccount = try await dependencies.cache.speechSynthesisVoicePreference(
            profileID: profileA,
            accountID: accountB
        )
        let otherProfile = try await dependencies.cache.speechSynthesisVoicePreference(
            profileID: profileB,
            accountID: accountA
        )
        XCTAssertEqual(exact, selected)
        XCTAssertNil(otherAccount)
        XCTAssertNil(otherProfile)

        do {
            try await dependencies.cache.saveSpeechSynthesisVoicePreference(
                .specific(SpeechSynthesisVoice(id: "ALL")),
                profileID: profileA,
                accountID: accountA
            )
            XCTFail("Expected the provider wildcard to be rejected")
        } catch let error as SpeechSynthesisVoicePreferencePersistenceError {
            XCTAssertEqual(error, .invalidVoiceID)
        }

        try await dependencies.cache.purge(profileID: profileA, accountID: accountA)
        let purged = try await dependencies.cache.speechSynthesisVoicePreference(
            profileID: profileA,
            accountID: accountA
        )
        XCTAssertNil(purged)
    }

    func testVoicePreferenceSurvivesPersistentReopenAndProfilePurge() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "LibreChatSpeechVoice-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "cache.store")
        let profileID = ServerProfileID(rawValue: "profile")
        let accountID = AccountID(rawValue: "account")
        let preference = SpeechSynthesisVoicePreference.specific(
            SpeechSynthesisVoice(id: "provider:voice/opaque")
        )

        var writer: AppDependencies? = try AppDependencies(storeURL: storeURL)
        try await writer?.cache.saveAccount(
            profileID: profileID,
            account: UserAccount(id: accountID)
        )
        try await writer?.cache.saveSpeechSynthesisVoicePreference(
            preference,
            profileID: profileID,
            accountID: accountID,
            selectedAt: Date(timeIntervalSince1970: 100)
        )
        writer = nil

        let reader = try AppDependencies(storeURL: storeURL)
        let reopened = try await reader.cache.speechSynthesisVoicePreference(
            profileID: profileID,
            accountID: accountID
        )
        XCTAssertEqual(reopened, preference)

        try await reader.cache.purge(profileID: profileID)
        let purged = try await reader.cache.speechSynthesisVoicePreference(
            profileID: profileID,
            accountID: accountID
        )
        XCTAssertNil(purged)
    }

    func testLostResponseIsNotAutomaticallyRepostedButExplicitRetryCanSynthesizeAgain() async throws {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true
            )),
            synthesisOutcomes: [
                .failure(LibreChatProtocolError.transport("lost")),
                .success(Self.audio),
            ]
        )
        let model = makeModel(repository: repository, player: ReadAloudPlayerDouble())
        let selection = try XCTUnwrap(model.selection(for: Self.assistantMessage()))

        await model.perform(selection)
        guard case let .failed(_, message, true) = model.phase else {
            return XCTFail("Expected a retryable delivery-uncertain failure")
        }
        XCTAssertTrue(message.contains("not requested again"))
        let firstCount = await repository.synthesisCount()
        XCTAssertEqual(firstCount, 1)
        try await Task.sleep(for: .milliseconds(75))
        let unchangedCount = await repository.synthesisCount()
        XCTAssertEqual(unchangedCount, 1)

        await model.retry()
        let retryCount = await repository.synthesisCount()
        XCTAssertEqual(retryCount, 2)
        guard case .playing(selection, _, _) = model.phase else {
            return XCTFail("Expected explicit retry to start playback")
        }
    }

    func testStartingAnotherResponseReplacesPlaybackAndRevisionRemovalStopsIt() async throws {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true
            )),
            synthesisOutcomes: [.success(Self.audio), .success(Self.audio)]
        )
        let player = ReadAloudPlayerDouble()
        let model = makeModel(repository: repository, player: player)
        let first = try XCTUnwrap(model.selection(for: Self.assistantMessage(
            id: "assistant-a",
            text: "First response"
        )))
        let second = try XCTUnwrap(model.selection(for: Self.assistantMessage(
            id: "assistant-b",
            text: "Second response"
        )))

        await model.perform(first)
        await model.perform(second)

        XCTAssertEqual(model.phase.selection, second)
        let playCount = await player.playCount()
        let synthesisCount = await repository.synthesisCount()
        XCTAssertEqual(playCount, 2)
        XCTAssertEqual(synthesisCount, 2)

        await model.reconcile(available: [first.identity])
        XCTAssertEqual(model.phase, .idle)
        let stopCount = await player.stopCount()
        XCTAssertGreaterThanOrEqual(stopCount, 3)
    }

    func testUnauthorizedCapabilityRefreshExpiresSessionWithoutSynthesizing() async throws {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .failure(LibreChatProtocolError.unauthorized)
        )
        let player = ReadAloudPlayerDouble()
        var unauthorizedCount = 0
        let model = makeModel(repository: repository, player: player) {
            unauthorizedCount += 1
        }
        let selection = try XCTUnwrap(model.selection(for: Self.assistantMessage()))

        await model.perform(selection)

        XCTAssertEqual(unauthorizedCount, 1)
        XCTAssertEqual(model.phase, .idle)
        let synthesisCount = await repository.synthesisCount()
        let playCount = await player.playCount()
        XCTAssertEqual(synthesisCount, 0)
        XCTAssertEqual(playCount, 0)
    }

    func testPlayerCompletionReturnsToIdleWithoutASecondRequest() async throws {
        let repository = ReadAloudRepositoryDouble(
            capabilities: .success(SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true
            )),
            synthesisOutcomes: [.success(Self.audio)]
        )
        let player = ReadAloudPlayerDouble(status: ResponseAudioPlaybackStatus(
            state: .completed,
            elapsed: 3,
            duration: 3
        ))
        let model = makeModel(repository: repository, player: player)
        let selection = try XCTUnwrap(model.selection(for: Self.assistantMessage()))

        await model.perform(selection)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(model.phase, .idle)
        let synthesisCount = await repository.synthesisCount()
        let statusCount = await player.statusCount()
        XCTAssertEqual(synthesisCount, 1)
        XCTAssertGreaterThanOrEqual(statusCount, 1)
    }

    private func makeModel(
        repository: ReadAloudRepositoryDouble,
        player: ReadAloudPlayerDouble,
        onUnauthorized: @escaping @MainActor () async -> Void = {}
    ) -> MessageReadAloudModel {
        MessageReadAloudModel(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: repository,
            player: player,
            onUnauthorized: onUnauthorized
        )
    }

    private static let audio = SynthesizedSpeechAudio(
        data: Data([0x49, 0x44, 0x33, 0x04]),
        mimeType: "audio/mpeg"
    )

    private static func assistantMessage(
        id: String = "assistant",
        text: String = "Visible assistant prose"
    ) -> ChatMessage {
        ChatMessage(
            id: MessageID(rawValue: id),
            conversationID: ConversationID(rawValue: "conversation"),
            content: [.text(text)],
            author: .assistant(name: "Assistant"),
            isUnfinished: false
        )
    }
}

private actor ReadAloudRepositoryDouble:
    SpeechSynthesisRepository,
    SpeechTranscriptionRepository {
    private let capabilities: Result<SpeechCapabilities, Error>
    private let voices: Result<[SpeechSynthesisVoice], Error>
    private var synthesisOutcomes: [Result<SynthesizedSpeechAudio, Error>]
    private var synthesisRequests: [SpeechSynthesisRequest] = []
    private var preference: Result<SpeechSynthesisVoicePreference?, Error>
    private var preferenceWrites: [SpeechSynthesisVoicePreference] = []

    init(
        capabilities: Result<SpeechCapabilities, Error>,
        synthesisOutcomes: [Result<SynthesizedSpeechAudio, Error>] = [],
        voices: Result<[SpeechSynthesisVoice], Error> = .success([]),
        preference: Result<SpeechSynthesisVoicePreference?, Error> = .success(nil)
    ) {
        self.capabilities = capabilities
        self.synthesisOutcomes = synthesisOutcomes
        self.voices = voices
        self.preference = preference
    }

    func speechCapabilities() async throws -> SpeechCapabilities {
        try capabilities.get()
    }

    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscription {
        throw LibreChatProtocolError.unsupported("Not used by read-aloud tests.")
    }

    func speechSynthesisVoices() async throws -> [SpeechSynthesisVoice] {
        try voices.get()
    }

    func speechSynthesisVoicePreference() async throws -> SpeechSynthesisVoicePreference? {
        try preference.get()
    }

    func setSpeechSynthesisVoicePreference(
        _ preference: SpeechSynthesisVoicePreference
    ) async throws {
        preferenceWrites.append(preference)
        self.preference = .success(preference)
    }

    func synthesizeSpeech(
        _ request: SpeechSynthesisRequest
    ) async throws -> SynthesizedSpeechAudio {
        synthesisRequests.append(request)
        guard !synthesisOutcomes.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return try synthesisOutcomes.removeFirst().get()
    }

    func synthesisCount() -> Int { synthesisRequests.count }
    func lastRequest() -> SpeechSynthesisRequest? { synthesisRequests.last }
    func savedPreferences() -> [SpeechSynthesisVoicePreference] { preferenceWrites }
}

private actor ReadAloudPlayerDouble: ResponseAudioPlaybackServicing {
    private let id = ResponseAudioPlaybackID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000789")!
    )
    private var currentStatus: ResponseAudioPlaybackStatus
    private var plays = 0
    private var pauses = 0
    private var resumes = 0
    private var stops = 0
    private var statuses = 0
    private var rate: Double?

    init(status: ResponseAudioPlaybackStatus = ResponseAudioPlaybackStatus(
        state: .playing,
        elapsed: 0,
        duration: 10
    )) {
        currentStatus = status
    }

    func play(
        _ audio: SynthesizedSpeechAudio,
        rate: Double
    ) async throws -> ResponseAudioPlaybackID {
        plays += 1
        self.rate = rate
        return id
    }

    func status(for id: ResponseAudioPlaybackID) async throws -> ResponseAudioPlaybackStatus {
        statuses += 1
        return currentStatus
    }

    func pause(_ id: ResponseAudioPlaybackID) async throws { pauses += 1 }
    func resume(_ id: ResponseAudioPlaybackID) async throws { resumes += 1 }
    func stop(_ id: ResponseAudioPlaybackID?) async { stops += 1 }

    func playCount() -> Int { plays }
    func pauseCount() -> Int { pauses }
    func resumeCount() -> Int { resumes }
    func stopCount() -> Int { stops }
    func statusCount() -> Int { statuses }
    func lastRate() -> Double? { rate }
}
