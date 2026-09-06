import AVFoundation
import Foundation
import LibreChatDomain

enum MicrophoneAuthorization: Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

enum MicrophoneAccessDecision: Equatable, Sendable {
    case requestPermission
    case denied
    case record
}

enum MicrophoneAccessPolicy {
    static func decision(for authorization: MicrophoneAuthorization) -> MicrophoneAccessDecision {
        switch authorization {
        case .undetermined: .requestPermission
        case .denied: .denied
        case .granted: .record
        }
    }
}

struct VoiceCaptureID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct VoiceCaptureStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case recording
        case stoppedUnexpectedly(reachedDurationLimit: Bool)
    }

    let elapsed: TimeInterval
    let state: State
}

struct CapturedVoiceAudio: Equatable, Sendable {
    let data: Data
    let filename: String
    let mimeType: String
    let duration: TimeInterval
}

enum VoiceCaptureError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case microphoneInUse
    case couldNotStart
    case invalidSession
    case tooShort
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is off for LibreChat."
        case .microphoneInUse:
            "The microphone is already being used by another LibreChat window."
        case .couldNotStart:
            "The microphone could not start. Check that another app is not using it."
        case .invalidSession:
            "That recording session is no longer available."
        case .tooShort:
            "The recording was too short to transcribe."
        case .tooLarge:
            "The recording is too large to transcribe."
        }
    }
}

/// Serializes the process-global AVAudioSession across every app scene. A
/// per-sheet recorder actor is not sufficient because activating or
/// deactivating one AVAudioSession affects every window in the process.
struct AppAudioActivityID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum AppAudioSessionMode: Equatable, Sendable {
    case recording
    case spokenPlayback
}

enum AppAudioSessionError: Error, Equatable, Sendable {
    case activityInUse
    case activationFailed
}

actor AppAudioSessionCoordinator {
    static let shared = AppAudioSessionCoordinator()

    private var owner: AppAudioActivityID?
    private let managesSystemAudioSession: Bool

    init(managesSystemAudioSession: Bool = true) {
        self.managesSystemAudioSession = managesSystemAudioSession
    }

    func activate(for id: AppAudioActivityID, mode: AppAudioSessionMode) throws {
        guard owner == nil else { throw AppAudioSessionError.activityInUse }
        owner = id
        guard managesSystemAudioSession else { return }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            switch mode {
            case .recording:
                try audioSession.setCategory(.record, mode: .measurement)
            case .spokenPlayback:
                try audioSession.setCategory(.playback, mode: .spokenAudio)
            }
            try audioSession.setActive(true)
        } catch {
            owner = nil
            throw AppAudioSessionError.activationFailed
        }
    }

    func deactivate(for id: AppAudioActivityID) {
        guard owner == id else { return }
        if managesSystemAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        owner = nil
    }
}

protocol VoiceCaptureServicing: Sendable {
    func start() async throws -> VoiceCaptureID
    func status(for id: VoiceCaptureID) async throws -> VoiceCaptureStatus
    func finish(_ id: VoiceCaptureID) async throws -> CapturedVoiceAudio
    func cancel(_ id: VoiceCaptureID?) async
}

actor VoiceCaptureSession: VoiceCaptureServicing {
    static let maximumDuration: TimeInterval = 300
    static let minimumDuration: TimeInterval = 0.35
    static let maximumBytes = 25 * 1_024 * 1_024

    private struct ActiveCapture {
        let id: VoiceCaptureID
        let audioActivityID: AppAudioActivityID
        let url: URL
        let recorder: AVAudioRecorder
        var lastElapsed: TimeInterval
    }

    private let profileID: ServerProfileID
    private let accountID: AccountID
    private let audioSessionCoordinator: AppAudioSessionCoordinator
    private var active: ActiveCapture?

    init(
        profileID: ServerProfileID,
        accountID: AccountID,
        audioSessionCoordinator: AppAudioSessionCoordinator = .shared
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    func start() async throws -> VoiceCaptureID {
        if let active { await cancel(active.id) }
        guard try await permissionGranted() else {
            throw VoiceCaptureError.permissionDenied
        }

        let id = VoiceCaptureID()
        let audioActivityID = AppAudioActivityID(rawValue: id.rawValue)
        do {
            try await audioSessionCoordinator.activate(for: audioActivityID, mode: .recording)
        } catch AppAudioSessionError.activityInUse {
            throw VoiceCaptureError.microphoneInUse
        } catch {
            throw VoiceCaptureError.couldNotStart
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LibreChatVoice", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "voice-\(id.rawValue.uuidString).m4a")
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 48_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                ]
            )
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record(forDuration: Self.maximumDuration) else {
                // The destination file exists the moment the recorder is
                // constructed; a failed start must not leave it behind.
                try? FileManager.default.removeItem(at: url)
                throw VoiceCaptureError.couldNotStart
            }
            active = ActiveCapture(
                id: id,
                audioActivityID: audioActivityID,
                url: url,
                recorder: recorder,
                lastElapsed: 0
            )
            return id
        } catch {
            await audioSessionCoordinator.deactivate(for: audioActivityID)
            if let captureError = error as? VoiceCaptureError { throw captureError }
            throw VoiceCaptureError.couldNotStart
        }
    }

    func status(for id: VoiceCaptureID) throws -> VoiceCaptureStatus {
        guard var active, active.id == id else { throw VoiceCaptureError.invalidSession }
        active.lastElapsed = max(active.lastElapsed, active.recorder.currentTime)
        self.active = active
        if active.recorder.isRecording {
            return VoiceCaptureStatus(elapsed: active.lastElapsed, state: .recording)
        }
        return VoiceCaptureStatus(
            elapsed: active.lastElapsed,
            state: .stoppedUnexpectedly(
                reachedDurationLimit: active.lastElapsed >= Self.maximumDuration - 0.5
            )
        )
    }

    func finish(_ id: VoiceCaptureID) async throws -> CapturedVoiceAudio {
        guard var active, active.id == id else { throw VoiceCaptureError.invalidSession }
        active.lastElapsed = max(active.lastElapsed, active.recorder.currentTime)
        active.recorder.stop()
        self.active = nil
        await audioSessionCoordinator.deactivate(for: active.audioActivityID)
        defer { try? FileManager.default.removeItem(at: active.url) }

        guard active.lastElapsed >= Self.minimumDuration else {
            throw VoiceCaptureError.tooShort
        }
        let data = try Data(contentsOf: active.url)
        guard !data.isEmpty else { throw VoiceCaptureError.tooShort }
        guard data.count <= Self.maximumBytes else { throw VoiceCaptureError.tooLarge }
        return CapturedVoiceAudio(
            data: data,
            filename: active.url.lastPathComponent,
            mimeType: "audio/mp4",
            duration: active.lastElapsed
        )
    }

    func cancel(_ id: VoiceCaptureID?) async {
        guard let active, id == nil || active.id == id else { return }
        active.recorder.stop()
        self.active = nil
        await audioSessionCoordinator.deactivate(for: active.audioActivityID)
        try? FileManager.default.removeItem(at: active.url)
    }

    private func permissionGranted() async throws -> Bool {
        switch MicrophoneAccessPolicy.decision(for: Self.authorization) {
        case .record:
            return true
        case .denied:
            return false
        case .requestPermission:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static var authorization: MicrophoneAuthorization {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .denied
        }
    }
}
