import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI
import UIKit

struct ReadAloudSelection: Equatable, Hashable, Sendable {
    let profileID: ServerProfileID
    let accountID: AccountID
    let conversationID: ConversationID
    let messageID: MessageID
    let contentRevision: String
    let text: String

    var identity: ReadAloudSelectionIdentity {
        ReadAloudSelectionIdentity(
            profileID: profileID,
            accountID: accountID,
            conversationID: conversationID,
            messageID: messageID,
            contentRevision: contentRevision
        )
    }
}

struct ReadAloudSelectionIdentity: Equatable, Hashable, Sendable {
    let profileID: ServerProfileID
    let accountID: AccountID
    let conversationID: ConversationID
    let messageID: MessageID
    let contentRevision: String
}

enum ReadAloudPhase: Equatable {
    case idle
    case preparing(ReadAloudSelection)
    case playing(ReadAloudSelection, elapsed: TimeInterval, duration: TimeInterval)
    case paused(
        ReadAloudSelection,
        elapsed: TimeInterval,
        duration: TimeInterval,
        interrupted: Bool
    )
    case failed(ReadAloudSelection, message: String, canRetry: Bool)

    var selection: ReadAloudSelection? {
        switch self {
        case .idle: nil
        case let .preparing(selection),
             let .playing(selection, _, _),
             let .paused(selection, _, _, _),
             let .failed(selection, _, _): selection
        }
    }
}

struct ReadAloudActionPresentation: Equatable {
    let title: String
    let systemImage: String
    let accessibilityHint: String
}

struct ReadAloudVoicePickerPresentation: Identifiable, Equatable {
    let id = "read-aloud-voice-picker"
}

enum ReadAloudVoiceCatalogState: Equatable {
    case idle
    case loading
    case loaded(voices: [SpeechSynthesisVoice], serverPreferredVoice: String?)
    case failed(message: String)

    var voices: [SpeechSynthesisVoice] {
        guard case let .loaded(voices, _) = self else { return [] }
        return voices
    }
}

private struct PreparedReadAloudAudio: Sendable {
    let audio: SynthesizedSpeechAudio
    let playbackRate: Double
    let preference: SpeechSynthesisVoicePreference
}

@MainActor
@Observable
final class MessageReadAloudModel {
    private let profileID: ServerProfileID
    private let accountID: AccountID
    private let repository: any SpeechSynthesisRepository & SpeechTranscriptionRepository
    private let player: any ResponseAudioPlaybackServicing
    private let onUnauthorized: @MainActor () async -> Void
    private var synthesisTask: Task<PreparedReadAloudAudio, Error>?
    private var pollTask: Task<Void, Never>?
    private var playbackID: ResponseAudioPlaybackID?
    private var operationID = UUID()

    private(set) var phase: ReadAloudPhase = .idle
    private(set) var voiceCatalogState: ReadAloudVoiceCatalogState = .idle
    private(set) var voicePreference: SpeechSynthesisVoicePreference = .serverDefault
    private(set) var isSavingVoicePreference = false
    private(set) var voicePreferenceMessage: String?

    init(
        profileID: ServerProfileID,
        accountID: AccountID,
        repository: any SpeechSynthesisRepository & SpeechTranscriptionRepository,
        player: any ResponseAudioPlaybackServicing = ResponseAudioPlayer(),
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.repository = repository
        self.player = player
        self.onUnauthorized = onUnauthorized
    }

    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    var selectedVoiceLabel: String {
        switch voicePreference {
        case .serverDefault:
            "Server default"
        case let .specific(voice):
            voice.id
        }
    }

    func loadVoiceChoices(force: Bool = false) async {
        if !force, case .loaded = voiceCatalogState { return }
        guard !isSavingVoicePreference else { return }
        voiceCatalogState = .loading
        voicePreferenceMessage = nil

        do {
            async let capabilities = repository.speechCapabilities()
            async let voices = repository.speechSynthesisVoices()
            async let preference = repository.speechSynthesisVoicePreference()
            let (resolvedCapabilities, resolvedVoices, storedPreference) = try await (
                capabilities,
                voices,
                preference
            )
            try Task.checkCancellation()
            guard resolvedCapabilities.supportsTextToSpeech else {
                throw LibreChatProtocolError.unsupported(
                    "Read aloud is not enabled on this LibreChat server."
                )
            }

            var resolvedPreference = storedPreference ?? .serverDefault
            if let selectedVoice = resolvedPreference.selectedVoice,
               !resolvedVoices.contains(selectedVoice) {
                resolvedPreference = .serverDefault
                voicePreferenceMessage = "Your previous voice is no longer advertised. LibreChat’s server default will be used."
                try? await repository.setSpeechSynthesisVoicePreference(.serverDefault)
            }

            voicePreference = resolvedPreference
            voiceCatalogState = .loaded(
                voices: resolvedVoices,
                serverPreferredVoice: resolvedCapabilities.preferredSynthesisVoice
            )
        } catch is CancellationError {
            return
        } catch LibreChatProtocolError.unauthorized {
            voiceCatalogState = .idle
            await onUnauthorized()
        } catch {
            voiceCatalogState = .failed(message: Self.voiceCatalogMessage(for: error))
        }
    }

    @discardableResult
    func saveVoicePreference(_ preference: SpeechSynthesisVoicePreference) async -> Bool {
        guard !isSavingVoicePreference else { return false }
        guard case let .loaded(voices, _) = voiceCatalogState else {
            voicePreferenceMessage = "Load this server’s voices before choosing one."
            return false
        }
        if let selectedVoice = preference.selectedVoice,
           !voices.contains(selectedVoice) {
            voicePreferenceMessage = "That voice is no longer advertised by this LibreChat server."
            return false
        }

        isSavingVoicePreference = true
        voicePreferenceMessage = nil
        defer { isSavingVoicePreference = false }
        do {
            try await repository.setSpeechSynthesisVoicePreference(preference)
            try Task.checkCancellation()
            voicePreference = preference
            announce("Reading voice saved")
            return true
        } catch is CancellationError {
            return false
        } catch LibreChatProtocolError.unauthorized {
            await onUnauthorized()
            return false
        } catch {
            voicePreferenceMessage = "The reading voice could not be saved."
            return false
        }
    }

    func selection(for message: ChatMessage) -> ReadAloudSelection? {
        guard let projection = MessageSpeechProjector.project(message) else { return nil }
        return ReadAloudSelection(
            profileID: profileID,
            accountID: accountID,
            conversationID: message.conversationID,
            messageID: message.id,
            contentRevision: projection.revision,
            text: projection.text
        )
    }

    func action(for selection: ReadAloudSelection) -> ReadAloudActionPresentation {
        guard phase.selection == selection else {
            return ReadAloudActionPresentation(
                title: "Read response aloud",
                systemImage: "speaker.wave.2",
                accessibilityHint: "Asks this LibreChat server to synthesize the visible assistant prose."
            )
        }
        switch phase {
        case .preparing:
            return ReadAloudActionPresentation(
                title: "Stop preparing audio",
                systemImage: "stop.fill",
                accessibilityHint: "Cancels receiving response audio on this device."
            )
        case .playing:
            return ReadAloudActionPresentation(
                title: "Pause reading",
                systemImage: "pause.fill",
                accessibilityHint: "Pauses this response at the current position."
            )
        case .paused:
            return ReadAloudActionPresentation(
                title: "Resume reading",
                systemImage: "play.fill",
                accessibilityHint: "Continues reading this response aloud."
            )
        case .failed:
            return ReadAloudActionPresentation(
                title: "Try read aloud again",
                systemImage: "arrow.clockwise",
                accessibilityHint: "Makes a new synthesis request that may repeat provider work."
            )
        case .idle:
            return ReadAloudActionPresentation(
                title: "Read response aloud",
                systemImage: "speaker.wave.2",
                accessibilityHint: "Asks this LibreChat server to synthesize the visible assistant prose."
            )
        }
    }

    func perform(_ selection: ReadAloudSelection) async {
        guard selection.profileID == profileID,
              selection.accountID == accountID else { return }
        guard phase.selection == selection else {
            await start(selection)
            return
        }
        switch phase {
        case .preparing:
            await stop()
        case .playing:
            await pause()
        case .paused:
            await resume()
        case .failed:
            await start(selection)
        case .idle:
            await start(selection)
        }
    }

    func retry() async {
        guard case let .failed(selection, _, canRetry) = phase, canRetry else { return }
        await start(selection)
    }

    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = .idle
    }

    func stop() async {
        invalidatePendingWork()
        await player.stop(playbackID)
        playbackID = nil
        phase = .idle
    }

    func applicationBecameInactive() async {
        guard isActive else { return }
        await stop()
    }

    func reconcile(available identities: Set<ReadAloudSelectionIdentity>) async {
        guard let current = phase.selection,
              !identities.contains(current.identity) else { return }
        await stop()
    }

    private func start(_ selection: ReadAloudSelection) async {
        await stop()
        let operationID = UUID()
        self.operationID = operationID
        phase = .preparing(selection)

        let repository = repository
        let requestProfileID = profileID
        let requestAccountID = accountID
        let task = Task<PreparedReadAloudAudio, Error> {
            let capabilities = try await repository.speechCapabilities()
            guard capabilities.supportsTextToSpeech else {
                throw LibreChatProtocolError.unsupported(
                    "Read aloud is not enabled on this LibreChat server."
                )
            }
            let preference = (try? await repository.speechSynthesisVoicePreference())
                ?? .serverDefault
            let audio = try await repository.synthesizeSpeech(SpeechSynthesisRequest(
                profileID: requestProfileID,
                accountID: requestAccountID,
                text: selection.text,
                voice: preference.requestVoice(
                    serverPreferredVoice: capabilities.preferredSynthesisVoice
                )
            ))
            return PreparedReadAloudAudio(
                audio: audio,
                playbackRate: capabilities.preferredPlaybackRate ?? 1,
                preference: preference
            )
        }
        synthesisTask = task

        do {
            let prepared = try await task.value
            try Task.checkCancellation()
            guard self.operationID == operationID,
                  phase.selection == selection else { return }
            synthesisTask = nil
            voicePreference = prepared.preference
            let id = try await player.play(
                prepared.audio,
                rate: prepared.playbackRate
            )
            guard self.operationID == operationID,
                  phase.selection == selection else {
                await player.stop(id)
                return
            }
            playbackID = id
            phase = .playing(selection, elapsed: 0, duration: 0)
            beginPolling(id: id, selection: selection, operationID: operationID)
            announce("Reading response aloud")
        } catch is CancellationError {
            return
        } catch LibreChatProtocolError.unauthorized {
            guard self.operationID == operationID else { return }
            invalidatePendingWork()
            await player.stop(playbackID)
            playbackID = nil
            phase = .idle
            await onUnauthorized()
        } catch let LibreChatProtocolError.unsupported(message) {
            guard self.operationID == operationID else { return }
            synthesisTask = nil
            await player.stop(playbackID)
            playbackID = nil
            phase = .failed(
                selection,
                message: message,
                canRetry: false
            )
            announce("Read aloud is unavailable")
        } catch {
            guard self.operationID == operationID else { return }
            synthesisTask = nil
            await player.stop(playbackID)
            playbackID = nil
            phase = .failed(
                selection,
                message: Self.userMessage(for: error),
                canRetry: true
            )
            announce("Read aloud failed")
        }
    }

    private func pause() async {
        guard case let .playing(selection, elapsed, duration) = phase,
              let playbackID else { return }
        do {
            try await player.pause(playbackID)
            pollTask?.cancel()
            pollTask = nil
            phase = .paused(
                selection,
                elapsed: elapsed,
                duration: duration,
                interrupted: false
            )
            announce("Reading paused")
        } catch {
            await failCurrent(error)
        }
    }

    private func resume() async {
        guard case let .paused(selection, elapsed, duration, _) = phase,
              let playbackID else { return }
        do {
            try await player.resume(playbackID)
            phase = .playing(selection, elapsed: elapsed, duration: duration)
            beginPolling(id: playbackID, selection: selection, operationID: operationID)
            announce("Reading resumed")
        } catch {
            await failCurrent(error)
        }
    }

    private func beginPolling(
        id: ResponseAudioPlaybackID,
        selection: ReadAloudSelection,
        operationID: UUID
    ) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self,
                          self.operationID == operationID,
                          self.phase.selection == selection else { return }
                    let status = try await self.player.status(for: id)
                    guard self.operationID == operationID,
                          self.phase.selection == selection else { return }
                    switch status.state {
                    case .playing:
                        self.phase = .playing(
                            selection,
                            elapsed: status.elapsed,
                            duration: status.duration
                        )
                    case .paused:
                        self.phase = .paused(
                            selection,
                            elapsed: status.elapsed,
                            duration: status.duration,
                            interrupted: false
                        )
                    case .interrupted:
                        self.pollTask = nil
                        self.phase = .paused(
                            selection,
                            elapsed: status.elapsed,
                            duration: status.duration,
                            interrupted: true
                        )
                        self.announce("Reading paused by an audio interruption")
                        return
                    case .completed:
                        self.pollTask = nil
                        self.playbackID = nil
                        self.phase = .idle
                        self.announce("Response reading complete")
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          self.operationID == operationID,
                          self.phase.selection == selection else { return }
                    await self.failCurrent(error)
                    return
                }
            }
        }
    }

    private func failCurrent(_ error: Error) async {
        guard let selection = phase.selection else { return }
        invalidatePendingWork()
        await player.stop(playbackID)
        playbackID = nil
        phase = .failed(
            selection,
            message: Self.userMessage(for: error),
            canRetry: true
        )
        announce("Read aloud failed")
    }

    private func invalidatePendingWork() {
        operationID = UUID()
        synthesisTask?.cancel()
        synthesisTask = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func announce(_ value: String) {
        UIAccessibility.post(notification: .announcement, argument: value)
    }

    private static func userMessage(for error: Error) -> String {
        if let protocolError = error as? LibreChatProtocolError {
            switch protocolError {
            case let .httpStatus(status, _, retryAfter) where status == 429:
                if let retryAfter {
                    return "LibreChat is rate limiting read aloud. Try again in about \(max(1, Int(retryAfter.rounded(.up)))) seconds."
                }
                return "LibreChat is rate limiting read aloud. Try again later."
            case .transport:
                return "The audio response was lost. It was not requested again; retry only if you want LibreChat to synthesize it again."
            case let .httpStatus(status, _, _) where status >= 500:
                return "LibreChat could not synthesize this response. Retrying may repeat provider work."
            default:
                return protocolError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? "This response could not be read aloud."
    }

    private static func voiceCatalogMessage(for error: Error) -> String {
        if let protocolError = error as? LibreChatProtocolError {
            switch protocolError {
            case let .httpStatus(status, _, retryAfter) where status == 429:
                if let retryAfter {
                    return "LibreChat is rate limiting voice discovery. Try again in about \(max(1, Int(retryAfter.rounded(.up)))) seconds."
                }
                return "LibreChat is rate limiting voice discovery. Try again later."
            case .transport:
                return "The voice list could not be reached. No synthesis request was made."
            default:
                return protocolError.localizedDescription
            }
        }
        return "The voice list could not be loaded."
    }
}

struct ReadAloudVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: MessageReadAloudModel
    @State private var draftPreference: SpeechSynthesisVoicePreference?

    init(model: MessageReadAloudModel) {
        self.model = model
        _draftPreference = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch model.voiceCatalogState {
                case .idle, .loading:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading voices from LibreChat…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Loading reading voices")
                    }
                case let .failed(message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task {
                                await model.loadVoiceChoices(force: true)
                                synchronizeDraft()
                            }
                        }
                        .accessibilityHint("Retries the read-only voice list request.")
                    }
                case let .loaded(voices, serverPreferredVoice):
                    Section {
                        voiceRow(
                            .serverDefault,
                            title: "Server default",
                            detail: serverDefaultDetail(serverPreferredVoice)
                        )
                        ForEach(voices) { voice in
                            voiceRow(.specific(voice), title: voice.id, detail: nil)
                        }
                    } header: {
                        Text("Reading voice")
                    } footer: {
                        Text(voices.isEmpty
                            ? "This server did not advertise named voices. LibreChat can still choose its configured default."
                            : "Voice names come directly from this LibreChat server. The choice affects new synthesis requests, not audio already playing.")
                    }
                }

                if let message = model.voicePreferenceMessage {
                    Section {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("read-aloud-voice-message")
                    }
                }
            }
            .navigationTitle("Reading Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isSavingVoicePreference ? "Saving…" : "Done") {
                        guard let draftPreference else { return }
                        Task {
                            if await model.saveVoicePreference(draftPreference) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        draftPreference == nil
                            || model.isSavingVoicePreference
                            || !isCatalogLoaded
                    )
                }
            }
            .task {
                await model.loadVoiceChoices()
                synchronizeDraft()
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("read-aloud-voice-sheet")
    }

    private var isCatalogLoaded: Bool {
        if case .loaded = model.voiceCatalogState { return true }
        return false
    }

    private func synchronizeDraft() {
        guard isCatalogLoaded else { return }
        draftPreference = model.voicePreference
    }

    @ViewBuilder
    private func voiceRow(
        _ preference: SpeechSynthesisVoicePreference,
        title: String,
        detail: String?
    ) -> some View {
        Button {
            draftPreference = preference
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if draftPreference == preference {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(draftPreference == preference ? "Selected" : "Not selected")
        .accessibilityHint("Selects this voice for future response audio after you choose Done.")
        .accessibilityIdentifier("read-aloud-voice-\(preferenceIdentifier(preference))")
    }

    private func serverDefaultDetail(_ preferredVoice: String?) -> String {
        guard let preferredVoice, !preferredVoice.isEmpty else {
            return "LibreChat chooses from the voices configured by this server."
        }
        return "Uses this server’s configured preference: \(preferredVoice)."
    }

    private func preferenceIdentifier(_ preference: SpeechSynthesisVoicePreference) -> String {
        switch preference {
        case .serverDefault:
            "server-default"
        case let .specific(voice):
            String(voice.id.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
            })
        }
    }
}

struct ReadAloudBar: View {
    let model: MessageReadAloudModel
    let onChooseVoice: () -> Void

    var body: some View {
        if model.isActive {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let progress {
                        ProgressView(value: progress.value, total: progress.total)
                            .accessibilityLabel("Reading progress")
                            .accessibilityValue(progress.accessibilityValue)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onChooseVoice) {
                    Image(systemName: "waveform.and.person.filled")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose reading voice")
                .accessibilityValue(model.selectedVoiceLabel)
                .accessibilityHint("Changes the voice used by future read aloud requests.")
                .accessibilityIdentifier("read-aloud-voice-button")

                if canTogglePlayback {
                    Button {
                        guard let selection = model.phase.selection else { return }
                        Task { await model.perform(selection) }
                    } label: {
                        Image(systemName: toggleIcon)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(toggleLabel)
                    .accessibilityIdentifier("read-aloud-toggle")
                } else if canRetry {
                    Button("Retry") { Task { await model.retry() } }
                        .accessibilityHint("May repeat speech-provider work.")
                        .accessibilityIdentifier("read-aloud-retry")
                }

                Button {
                    Task { await model.stop() }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(canRetry ? "Dismiss read aloud error" : "Stop reading")
                .accessibilityIdentifier("read-aloud-stop")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .adaptiveGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("read-aloud-player")
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: "Read aloud"
        case .preparing: "Preparing response audio…"
        case .playing: "Reading response aloud"
        case let .paused(_, _, _, interrupted):
            interrupted ? "Reading interrupted" : "Reading paused"
        case .failed: "Couldn’t read this response"
        }
    }

    private var detail: String? {
        switch model.phase {
        case let .failed(_, message, _): message
        case .paused(_, _, _, true): "Resume when you’re ready."
        default: nil
        }
    }

    private var icon: String {
        switch model.phase {
        case .preparing: "speaker.wave.2"
        case .playing: "speaker.wave.3.fill"
        case .paused: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .idle: "speaker.wave.2"
        }
    }

    private var canTogglePlayback: Bool {
        switch model.phase {
        case .preparing, .playing, .paused: true
        case .idle, .failed: false
        }
    }

    private var canRetry: Bool {
        guard case let .failed(_, _, canRetry) = model.phase else { return false }
        return canRetry
    }

    private var toggleIcon: String {
        switch model.phase {
        case .playing: "pause.fill"
        case .paused: "play.fill"
        case .preparing: "stop.fill"
        default: "play.fill"
        }
    }

    private var toggleLabel: String {
        switch model.phase {
        case .playing: "Pause reading"
        case .paused: "Resume reading"
        case .preparing: "Stop preparing audio"
        default: "Read response aloud"
        }
    }

    private var progress: (value: Double, total: Double, accessibilityValue: String)? {
        let elapsed: TimeInterval
        let duration: TimeInterval
        switch model.phase {
        case let .playing(_, current, total), let .paused(_, current, total, _):
            elapsed = current
            duration = total
        default:
            return nil
        }
        guard duration > 0 else { return nil }
        return (
            elapsed,
            duration,
            "\(Self.duration(elapsed)) of \(Self.duration(duration))"
        )
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
