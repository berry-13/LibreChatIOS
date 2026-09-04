import LibreChatDomain
import LibreChatProtocol
import XCTest
@testable import LibreChat

@MainActor
final class VoiceDictationTests: XCTestCase {
    func testMicrophonePolicyMapsEveryAuthorizationState() {
        XCTAssertEqual(MicrophoneAccessPolicy.decision(for: .undetermined), .requestPermission)
        XCTAssertEqual(MicrophoneAccessPolicy.decision(for: .denied), .denied)
        XCTAssertEqual(MicrophoneAccessPolicy.decision(for: .granted), .record)
    }

    func testDraftMergePreservesExistingTextAndNeverInventsContent() {
        XCTAssertEqual(
            VoiceDictationDraft.merging(existing: "Existing prompt", transcript: "  dictated words \n"),
            "Existing prompt dictated words"
        )
        XCTAssertEqual(
            VoiceDictationDraft.merging(existing: "Existing prompt\n", transcript: "dictated words"),
            "Existing prompt\ndictated words"
        )
        XCTAssertEqual(
            VoiceDictationDraft.merging(existing: "", transcript: " dictated words "),
            "dictated words"
        )
        XCTAssertNil(VoiceDictationDraft.merging(existing: "Keep me", transcript: " \n "))
    }

    func testUnsupportedServerFailsBeforeMicrophoneStarts() async {
        let repository = VoiceSpeechRepositoryDouble(
            capabilities: SpeechCapabilities(
                supportsSpeechToText: false,
                supportsTextToSpeech: true
            )
        )
        let capture = VoiceCaptureDouble()
        let model = makeModel(repository: repository, capture: capture)

        await model.start()

        let startCount = await capture.startCount()
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(
            model.phase,
            .failed(
                message: "Speech-to-text is not enabled on this LibreChat server.",
                canRetryTranscription: false,
                offersSettings: false
            )
        )
    }

    func testRecordingTranscribesOnceAndReturnsEditableText() async {
        let repository = VoiceSpeechRepositoryDouble(
            capabilities: SpeechCapabilities(
                supportsSpeechToText: true,
                supportsTextToSpeech: false,
                preferredTranscriptionLanguage: "it"
            ),
            outcomes: [.success(SpeechTranscription(text: "Ciao dal server"))]
        )
        let capture = VoiceCaptureDouble()
        let model = makeModel(repository: repository, capture: capture)

        await model.start()
        let transcript = await model.stopAndTranscribe()

        XCTAssertEqual(transcript, "Ciao dal server")
        let transcriptionCount = await repository.transcriptionCount()
        XCTAssertEqual(transcriptionCount, 1)
        let request = await repository.lastRequest()
        XCTAssertEqual(request?.language, "it")
        XCTAssertEqual(request?.mimeType, "audio/mp4")
        XCTAssertEqual(request?.audio, Data([1, 2, 3]))
    }

    func testLostResponseNeverAutomaticallyRepostsButExplicitRetryCan() async throws {
        let repository = VoiceSpeechRepositoryDouble(
            capabilities: SpeechCapabilities(
                supportsSpeechToText: true,
                supportsTextToSpeech: false
            ),
            outcomes: [
                .failure(LibreChatProtocolError.transport("lost")),
                .success(SpeechTranscription(text: "Recovered transcript")),
            ]
        )
        let model = makeModel(repository: repository, capture: VoiceCaptureDouble())

        await model.start()
        let firstTranscript = await model.stopAndTranscribe()
        let firstCount = await repository.transcriptionCount()
        XCTAssertNil(firstTranscript)
        XCTAssertEqual(firstCount, 1)
        try await Task.sleep(for: .milliseconds(50))
        let unchangedCount = await repository.transcriptionCount()
        XCTAssertEqual(unchangedCount, 1)
        let retriedTranscript = await model.retryTranscription()
        let retriedCount = await repository.transcriptionCount()
        XCTAssertEqual(retriedTranscript, "Recovered transcript")
        XCTAssertEqual(retriedCount, 2)
    }

    func testBecomingInactiveDiscardsCaptureAndDoesNotTranscribe() async {
        let repository = VoiceSpeechRepositoryDouble(
            capabilities: SpeechCapabilities(
                supportsSpeechToText: true,
                supportsTextToSpeech: false
            )
        )
        let capture = VoiceCaptureDouble()
        let model = makeModel(repository: repository, capture: capture)

        await model.start()
        await model.applicationBecameInactive()

        let cancelCount = await capture.cancelCount()
        let transcriptionCount = await repository.transcriptionCount()
        XCTAssertEqual(cancelCount, 2) // reset-before-start plus inactivity
        XCTAssertEqual(transcriptionCount, 0)
        XCTAssertEqual(
            model.phase,
            .failed(
                message: "The temporary recording was discarded when LibreChat became inactive.",
                canRetryTranscription: false,
                offersSettings: false
            )
        )
    }

    func testDismissalWhileRecorderFinishIsSuspendedNeverStartsTranscription() async {
        let repository = VoiceSpeechRepositoryDouble(
            capabilities: SpeechCapabilities(
                supportsSpeechToText: true,
                supportsTextToSpeech: false
            ),
            outcomes: [.success(SpeechTranscription(text: "Must not be used"))]
        )
        let capture = SuspendedVoiceCaptureDouble()
        let model = VoiceDictationModel(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: repository,
            capture: capture,
            onUnauthorized: {}
        )

        await model.start()
        let stopTask = Task { await model.stopAndTranscribe() }
        await capture.waitUntilFinishIsSuspended()
        model.invalidatePendingWork()
        await model.cancel()
        await capture.resumeFinish()

        let transcript = await stopTask.value
        let transcriptionCount = await repository.transcriptionCount()
        XCTAssertNil(transcript)
        XCTAssertEqual(transcriptionCount, 0)
    }

    func testProcessWideAudioSessionLeaseRejectsCompetingCapture() async throws {
        let coordinator = AppAudioSessionCoordinator(
            managesSystemAudioSession: false
        )
        let first = AppAudioActivityID()
        let second = AppAudioActivityID()

        try await coordinator.activate(for: first, mode: .recording)
        do {
            try await coordinator.activate(for: second, mode: .spokenPlayback)
            XCTFail("A second scene must not take the process-wide microphone lease")
        } catch {
            XCTAssertEqual(error as? AppAudioSessionError, .activityInUse)
        }

        await coordinator.deactivate(for: second)
        do {
            try await coordinator.activate(for: second, mode: .spokenPlayback)
            XCTFail("A foreign release must not clear the current microphone owner")
        } catch {
            XCTAssertEqual(error as? AppAudioSessionError, .activityInUse)
        }

        await coordinator.deactivate(for: first)
        try await coordinator.activate(for: second, mode: .spokenPlayback)
        await coordinator.deactivate(for: second)
    }

    private func makeModel(
        repository: VoiceSpeechRepositoryDouble,
        capture: VoiceCaptureDouble
    ) -> VoiceDictationModel {
        VoiceDictationModel(
            profileID: ServerProfileID(rawValue: "profile"),
            accountID: AccountID(rawValue: "account"),
            repository: repository,
            capture: capture,
            onUnauthorized: {}
        )
    }
}

private actor VoiceSpeechRepositoryDouble: SpeechTranscriptionRepository {
    private let capabilities: SpeechCapabilities
    private var outcomes: [Result<SpeechTranscription, Error>]
    private var requests: [SpeechTranscriptionRequest] = []

    init(
        capabilities: SpeechCapabilities,
        outcomes: [Result<SpeechTranscription, Error>] = []
    ) {
        self.capabilities = capabilities
        self.outcomes = outcomes
    }

    func speechCapabilities() async throws -> SpeechCapabilities { capabilities }

    func transcribe(_ request: SpeechTranscriptionRequest) async throws -> SpeechTranscription {
        requests.append(request)
        guard !outcomes.isEmpty else {
            throw LibreChatProtocolError.invalidResponse
        }
        return try outcomes.removeFirst().get()
    }

    func transcriptionCount() -> Int { requests.count }
    func lastRequest() -> SpeechTranscriptionRequest? { requests.last }
}

private actor VoiceCaptureDouble: VoiceCaptureServicing {
    private let id = VoiceCaptureID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    )
    private var starts = 0
    private var cancels = 0

    func start() async throws -> VoiceCaptureID {
        starts += 1
        return id
    }

    func status(for id: VoiceCaptureID) async throws -> VoiceCaptureStatus {
        VoiceCaptureStatus(elapsed: 1, state: .recording)
    }

    func finish(_ id: VoiceCaptureID) async throws -> CapturedVoiceAudio {
        CapturedVoiceAudio(
            data: Data([1, 2, 3]),
            filename: "voice-test.m4a",
            mimeType: "audio/mp4",
            duration: 1
        )
    }

    func cancel(_ id: VoiceCaptureID?) async { cancels += 1 }
    func startCount() -> Int { starts }
    func cancelCount() -> Int { cancels }
}

private actor SuspendedVoiceCaptureDouble: VoiceCaptureServicing {
    private let id = VoiceCaptureID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000456")!
    )
    private var finishContinuation: CheckedContinuation<CapturedVoiceAudio, Never>?

    func start() async throws -> VoiceCaptureID { id }

    func status(for id: VoiceCaptureID) async throws -> VoiceCaptureStatus {
        VoiceCaptureStatus(elapsed: 1, state: .recording)
    }

    func finish(_ id: VoiceCaptureID) async throws -> CapturedVoiceAudio {
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel(_ id: VoiceCaptureID?) async {}

    func waitUntilFinishIsSuspended() async {
        while finishContinuation == nil {
            await Task.yield()
        }
    }

    func resumeFinish() {
        finishContinuation?.resume(returning: CapturedVoiceAudio(
            data: Data([4, 5, 6]),
            filename: "voice-race.m4a",
            mimeType: "audio/mp4",
            duration: 1
        ))
        finishContinuation = nil
    }
}
