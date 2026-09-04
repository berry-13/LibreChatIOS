import AVFoundation
import Foundation
import LibreChatDomain

struct ResponseAudioPlaybackID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum ResponseAudioPlaybackState: Equatable, Sendable {
    case playing
    case paused
    case interrupted
    case completed
}

struct ResponseAudioPlaybackStatus: Equatable, Sendable {
    let state: ResponseAudioPlaybackState
    let elapsed: TimeInterval
    let duration: TimeInterval
}

enum ResponseAudioPlayerError: LocalizedError, Equatable, Sendable {
    case audioInUse
    case couldNotPlay
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .audioInUse:
            "Another LibreChat window is already recording or reading aloud."
        case .couldNotPlay:
            "LibreChat returned audio this device could not play."
        case .invalidSession:
            "That read-aloud session is no longer available."
        }
    }
}

protocol ResponseAudioPlaybackServicing: Sendable {
    func play(_ audio: SynthesizedSpeechAudio, rate: Double) async throws -> ResponseAudioPlaybackID
    func status(for id: ResponseAudioPlaybackID) async throws -> ResponseAudioPlaybackStatus
    func pause(_ id: ResponseAudioPlaybackID) async throws
    func resume(_ id: ResponseAudioPlaybackID) async throws
    func stop(_ id: ResponseAudioPlaybackID?) async
}

/// Owns one foreground-only response playback session. The shared audio
/// coordinator prevents another scene's recorder or player from silently
/// reconfiguring the process-global AVAudioSession.
actor ResponseAudioPlayer: ResponseAudioPlaybackServicing {
    private struct ActivePlayback {
        let id: ResponseAudioPlaybackID
        let audioActivityID: AppAudioActivityID
        let player: AVAudioPlayer
        var isPausedByUser: Bool
    }

    private let audioSessionCoordinator: AppAudioSessionCoordinator
    private var active: ActivePlayback?

    init(audioSessionCoordinator: AppAudioSessionCoordinator = .shared) {
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    func play(
        _ audio: SynthesizedSpeechAudio,
        rate: Double
    ) async throws -> ResponseAudioPlaybackID {
        if let active { await stop(active.id) }
        let id = ResponseAudioPlaybackID()
        let audioActivityID = AppAudioActivityID(rawValue: id.rawValue)
        do {
            try await audioSessionCoordinator.activate(
                for: audioActivityID,
                mode: .spokenPlayback
            )
        } catch AppAudioSessionError.activityInUse {
            throw ResponseAudioPlayerError.audioInUse
        } catch {
            throw ResponseAudioPlayerError.couldNotPlay
        }

        do {
            let player = try AVAudioPlayer(data: audio.data)
            player.enableRate = true
            player.rate = Float(min(max(rate, 0.25), 4))
            guard player.prepareToPlay(),
                  player.duration.isFinite,
                  player.duration > 0,
                  player.play() else {
                throw ResponseAudioPlayerError.couldNotPlay
            }
            active = ActivePlayback(
                id: id,
                audioActivityID: audioActivityID,
                player: player,
                isPausedByUser: false
            )
            return id
        } catch {
            await audioSessionCoordinator.deactivate(for: audioActivityID)
            if let playerError = error as? ResponseAudioPlayerError { throw playerError }
            throw ResponseAudioPlayerError.couldNotPlay
        }
    }

    func status(for id: ResponseAudioPlaybackID) async throws -> ResponseAudioPlaybackStatus {
        guard let active, active.id == id else {
            throw ResponseAudioPlayerError.invalidSession
        }
        let elapsed = max(0, active.player.currentTime)
        let duration = max(0, active.player.duration)
        if active.player.isPlaying {
            return ResponseAudioPlaybackStatus(
                state: .playing,
                elapsed: elapsed,
                duration: duration
            )
        }
        if active.isPausedByUser {
            return ResponseAudioPlaybackStatus(
                state: .paused,
                elapsed: elapsed,
                duration: duration
            )
        }
        if duration > 0, elapsed >= duration - 0.05 {
            await stop(id)
            return ResponseAudioPlaybackStatus(
                state: .completed,
                elapsed: duration,
                duration: duration
            )
        }
        return ResponseAudioPlaybackStatus(
            state: .interrupted,
            elapsed: elapsed,
            duration: duration
        )
    }

    func pause(_ id: ResponseAudioPlaybackID) throws {
        guard var active, active.id == id else {
            throw ResponseAudioPlayerError.invalidSession
        }
        active.player.pause()
        active.isPausedByUser = true
        self.active = active
    }

    func resume(_ id: ResponseAudioPlaybackID) throws {
        guard var active, active.id == id else {
            throw ResponseAudioPlayerError.invalidSession
        }
        active.isPausedByUser = false
        guard active.player.play() else {
            throw ResponseAudioPlayerError.couldNotPlay
        }
        self.active = active
    }

    func stop(_ id: ResponseAudioPlaybackID?) async {
        guard let active, id == nil || active.id == id else { return }
        active.player.stop()
        self.active = nil
        await audioSessionCoordinator.deactivate(for: active.audioActivityID)
    }
}
