import LibreChatDomain
import LibreChatProtocol
import Observation
import SwiftUI
import UIKit

struct VoiceDictationPresentation: Identifiable, Hashable {
    let id = UUID()
}

enum VoiceDictationDraft {
    static func merging(existing: String, transcript: String) -> String? {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return normalized
        }
        let separator = existing.last?.isWhitespace == true ? "" : " "
        return existing + separator + normalized
    }
}

enum VoiceDictationPhase: Equatable {
    case preparing
    case recording
    case interrupted(reachedDurationLimit: Bool)
    case transcribing
    case failed(message: String, canRetryTranscription: Bool, offersSettings: Bool)
}

@MainActor
@Observable
final class VoiceDictationModel {
    private let profileID: ServerProfileID
    private let accountID: AccountID
    private let repository: any SpeechTranscriptionRepository
    private let capture: any VoiceCaptureServicing
    private let onUnauthorized: @MainActor () async -> Void
    private var captureID: VoiceCaptureID?
    private var capturedAudio: CapturedVoiceAudio?
    private var pollTask: Task<Void, Never>?
    private var transcriptionTask: Task<SpeechTranscription, Error>?
    private var operationID = UUID()

    var phase: VoiceDictationPhase = .preparing
    var elapsed: TimeInterval = 0

    init(
        profileID: ServerProfileID,
        accountID: AccountID,
        repository: any SpeechTranscriptionRepository,
        capture: any VoiceCaptureServicing,
        onUnauthorized: @escaping @MainActor () async -> Void
    ) {
        self.profileID = profileID
        self.accountID = accountID
        self.repository = repository
        self.capture = capture
        self.onUnauthorized = onUnauthorized
    }

    var canStop: Bool { phase == .recording && elapsed >= VoiceCaptureSession.minimumDuration }

    func start() async {
        await discardCapture()
        phase = .preparing
        elapsed = 0
        let operationID = UUID()
        self.operationID = operationID
        do {
            let capabilities = try await repository.speechCapabilities()
            try Task.checkCancellation()
            guard self.operationID == operationID else { return }
            guard capabilities.supportsSpeechToText else {
                phase = .failed(
                    message: "Speech-to-text is not enabled on this LibreChat server.",
                    canRetryTranscription: false,
                    offersSettings: false
                )
                return
            }
            let id = try await capture.start()
            try Task.checkCancellation()
            guard self.operationID == operationID else {
                await capture.cancel(id)
                return
            }
            captureID = id
            phase = .recording
            beginPolling(id: id, operationID: operationID)
        } catch is CancellationError {
            return
        } catch LibreChatProtocolError.unauthorized {
            guard self.operationID == operationID else { return }
            await onUnauthorized()
        } catch VoiceCaptureError.permissionDenied {
            guard self.operationID == operationID else { return }
            phase = .failed(
                message: "Allow microphone access in Settings to dictate a message.",
                canRetryTranscription: false,
                offersSettings: true
            )
        } catch {
            guard self.operationID == operationID else { return }
            phase = .failed(
                message: Self.userMessage(for: error),
                canRetryTranscription: false,
                offersSettings: false
            )
        }
    }

    func stopAndTranscribe() async -> String? {
        guard let captureID else { return nil }
        let operationID = self.operationID
        pollTask?.cancel()
        pollTask = nil
        do {
            let finishedAudio = try await capture.finish(captureID)
            guard self.operationID == operationID else { return nil }
            capturedAudio = finishedAudio
            self.captureID = nil
            return await submitCapturedAudio()
        } catch {
            guard self.operationID == operationID else { return nil }
            self.captureID = nil
            phase = .failed(
                message: Self.userMessage(for: error),
                canRetryTranscription: false,
                offersSettings: false
            )
            return nil
        }
    }

    func retryTranscription() async -> String? {
        guard capturedAudio != nil else { return nil }
        return await submitCapturedAudio()
    }

    func applicationBecameInactive() async {
        guard phase == .recording || {
            if case .interrupted = phase { return true }
            return false
        }() || phase == .transcribing else { return }
        invalidatePendingWork()
        await capture.cancel(captureID)
        captureID = nil
        phase = .failed(
            message: "The temporary recording was discarded when LibreChat became inactive.",
            canRetryTranscription: false,
            offersSettings: false
        )
    }

    func cancel() async {
        invalidatePendingWork()
        await capture.cancel(captureID)
        captureID = nil
    }

    /// Invalidates work synchronously on the MainActor before SwiftUI begins
    /// an asynchronous scene or dismissal cleanup task. This prevents a
    /// suspended recorder finish from reinstating audio and dispatching STT.
    func invalidatePendingWork() {
        operationID = UUID()
        pollTask?.cancel()
        pollTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        capturedAudio = nil
    }

    private func submitCapturedAudio() async -> String? {
        guard let capturedAudio else { return nil }
        phase = .transcribing
        let operationID = UUID()
        self.operationID = operationID
        transcriptionTask?.cancel()
        let request = SpeechTranscriptionRequest(
            profileID: profileID,
            accountID: accountID,
            audio: capturedAudio.data,
            filename: capturedAudio.filename,
            mimeType: capturedAudio.mimeType
        )
        let repository = repository
        let task = Task<SpeechTranscription, Error> {
            let capabilities = try await repository.speechCapabilities()
            guard capabilities.supportsSpeechToText else {
                throw LibreChatProtocolError.unsupported(
                    "Speech-to-text is no longer enabled on this LibreChat server."
                )
            }
            return try await repository.transcribe(SpeechTranscriptionRequest(
                profileID: request.profileID,
                accountID: request.accountID,
                audio: request.audio,
                filename: request.filename,
                mimeType: request.mimeType,
                language: capabilities.preferredTranscriptionLanguage
            ))
        }
        transcriptionTask = task
        do {
            let result = try await task.value
            try Task.checkCancellation()
            guard self.operationID == operationID else { return nil }
            transcriptionTask = nil
            self.capturedAudio = nil
            return result.text
        } catch is CancellationError {
            if self.operationID == operationID { transcriptionTask = nil }
            return nil
        } catch LibreChatProtocolError.unauthorized {
            guard self.operationID == operationID else { return nil }
            transcriptionTask = nil
            self.capturedAudio = nil
            await onUnauthorized()
            return nil
        } catch {
            guard self.operationID == operationID else { return nil }
            transcriptionTask = nil
            phase = .failed(
                message: Self.userMessage(for: error),
                canRetryTranscription: true,
                offersSettings: false
            )
            return nil
        }
    }

    private func beginPolling(id: VoiceCaptureID, operationID: UUID) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    guard let self, self.operationID == operationID else { return }
                    let status = try await self.capture.status(for: id)
                    guard self.operationID == operationID else { return }
                    self.elapsed = status.elapsed
                    if case let .stoppedUnexpectedly(reachedDurationLimit) = status.state {
                        self.pollTask = nil
                        self.phase = .interrupted(reachedDurationLimit: reachedDurationLimit)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, self.operationID == operationID else { return }
                    self.pollTask = nil
                    self.phase = .failed(
                        message: Self.userMessage(for: error),
                        canRetryTranscription: false,
                        offersSettings: false
                    )
                    return
                }
            }
        }
    }

    private func discardCapture() async {
        operationID = UUID()
        pollTask?.cancel()
        pollTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        await capture.cancel(captureID)
        captureID = nil
        capturedAudio = nil
    }

    private static func userMessage(for error: Error) -> String {
        if let protocolError = error as? LibreChatProtocolError {
            switch protocolError {
            case let .httpStatus(status, _, retryAfter) where status == 429:
                if let retryAfter {
                    return "LibreChat is rate limiting transcription. Try again in about \(max(1, Int(retryAfter.rounded(.up)))) seconds."
                }
                return "LibreChat is rate limiting transcription. Try again later."
            case .transport:
                return "The transcription response was lost. The recording was not sent again; retry only if you want LibreChat to process it again."
            case let .httpStatus(status, _, _) where status >= 500:
                return "LibreChat could not transcribe that recording. Retry may repeat provider work."
            default:
                return protocolError.localizedDescription
            }
        }
        return (error as? LocalizedError)?.errorDescription
            ?? "The recording could not be transcribed."
    }
}

struct VoiceDictationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: VoiceDictationModel
    private let serverHost: String
    private let onTranscript: @MainActor (String) -> Void

    init(
        profileID: ServerProfileID,
        accountID: AccountID,
        serverHost: String,
        repository: any SpeechTranscriptionRepository,
        onUnauthorized: @escaping @MainActor () async -> Void,
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        self.serverHost = serverHost
        self.onTranscript = onTranscript
        _model = State(initialValue: VoiceDictationModel(
            profileID: profileID,
            accountID: accountID,
            repository: repository,
            capture: VoiceCaptureSession(profileID: profileID, accountID: accountID),
            onUnauthorized: onUnauthorized
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                phaseIcon
                phaseContent
                Spacer(minLength: 8)
                controls
            }
            .padding(24)
            .navigationTitle("Dictate message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        model.invalidatePendingWork()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.phase == .transcribing)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            model.invalidatePendingWork()
            Task { await model.applicationBecameInactive() }
        }
        .onDisappear {
            model.invalidatePendingWork()
            Task { await model.cancel() }
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch model.phase {
        case .preparing, .transcribing:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(model.phase == .preparing ? "Preparing microphone" : "Transcribing recording")
        case .recording:
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        case let .interrupted(reachedDurationLimit):
            Image(systemName: reachedDurationLimit ? "timer.circle" : "exclamationmark.circle")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case let .failed(_, _, offersSettings):
            Image(systemName: offersSettings ? "mic.slash.circle" : "exclamationmark.circle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .preparing:
            Text("Checking speech support and microphone access…")
                .multilineTextAlignment(.center)
        case .recording:
            Text(Self.duration(model.elapsed))
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .accessibilityLabel("Recording time \(Self.duration(model.elapsed))")
            Text("Audio stays temporary on this device until you ask \(serverHost) to transcribe it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case let .interrupted(reachedDurationLimit):
            Text(reachedDurationLimit ? "Five-minute recording limit reached" : "Recording interrupted")
                .font(.title3.bold())
            Text("You can transcribe the captured audio or discard it. It has not been sent yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .transcribing:
            Text("Transcribing with \(serverHost)…")
                .font(.headline)
            Text("The transcript will return to the composer for review. It will not be sent automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case let .failed(message, _, _):
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("voice-dictation-error")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .preparing, .transcribing:
            EmptyView()
        case .recording:
            Button {
                transcribeCapturedAudio(retry: false)
            } label: {
                Label("Stop and transcribe", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canStop)
            .accessibilityHint("Stops local recording and uploads it to \(serverHost) for transcription.")
            .accessibilityIdentifier("voice-stop-transcribe")
        case .interrupted:
            Button {
                transcribeCapturedAudio(retry: false)
            } label: {
                Label("Transcribe captured audio", systemImage: "text.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Discard recording", role: .destructive) { dismiss() }
        case let .failed(_, canRetryTranscription, offersSettings):
            if canRetryTranscription {
                Button {
                    transcribeCapturedAudio(retry: true)
                } label: {
                    Text("Retry transcription")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("May ask the speech provider to process the same recording again.")
            } else if offersSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try recording again") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func transcribeCapturedAudio(retry: Bool) {
        Task {
            let transcript = retry
                ? await model.retryTranscription()
                : await model.stopAndTranscribe()
            guard let transcript else { return }
            onTranscript(transcript)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Transcript added to message draft"
            )
            dismiss()
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// In-composer dictation surface: replaces the text area with a live
/// waveform, elapsed time, and stop/cancel controls until the recording is
/// transcribed back into the editable draft. The composer itself never
/// unmounts.
struct InlineDictationBar: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: VoiceDictationModel
    let serverHost: String
    let onTranscript: @MainActor (String) -> Void
    let onFinished: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            phaseLeading

            phaseCenter
                .frame(maxWidth: .infinity)

            phaseTrailing
        }
        .frame(minHeight: 40)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            model.invalidatePendingWork()
            Task { await model.applicationBecameInactive() }
        }
        .onDisappear {
            model.invalidatePendingWork()
        }
        .accessibilityIdentifier("inline-dictation-bar")
    }

    @ViewBuilder
    private var phaseLeading: some View {
        switch model.phase {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 9, height: 9)
                .opacity(model.elapsed.truncatingRemainder(dividingBy: 1) < 0.6 ? 1 : 0.25)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        default:
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var phaseCenter: some View {
        switch model.phase {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing microphone…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .recording:
            HStack(spacing: 10) {
                DictationWaveform()
                    .frame(height: 24)
                Text(Self.duration(model.elapsed))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
            }
        case let .interrupted(reachedDurationLimit):
            Text(reachedDurationLimit ? "Recording limit reached" : "Recording interrupted")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing with \(serverHost)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case let .failed(message, _, _):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .lineLimit(2)
                .accessibilityIdentifier("voice-dictation-error")
        }
    }

    @ViewBuilder
    private var phaseTrailing: some View {
        switch model.phase {
        case .preparing, .transcribing:
            Button {
                onFinished()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.phase == .transcribing)
            .accessibilityLabel("Close dictation")
            .accessibilityIdentifier("inline-dictation-cancel")
        case .recording:
            trailingButton(
                systemImage: "xmark",
                label: "Discard recording",
                identifier: "inline-dictation-cancel",
                tint: .secondary
            ) {
                Task {
                    await model.cancel()
                    onFinished()
                }
            }
            trailingButton(
                systemImage: "checkmark",
                label: model.canStop ? "Stop and transcribe" : "Keep recording",
                identifier: "inline-dictation-stop",
                tint: .primary,
                filled: true
            ) {
                Task {
                    if let transcript = await model.stopAndTranscribe() {
                        onTranscript(transcript)
                    }
                }
            }
            .disabled(!model.canStop)
        case .interrupted:
            trailingButton(
                systemImage: "trash",
                label: "Discard recording",
                identifier: "inline-dictation-cancel",
                tint: .secondary
            ) {
                Task {
                    await model.cancel()
                    onFinished()
                }
            }
            trailingButton(
                systemImage: "arrow.up.circle.fill",
                label: "Transcribe captured audio",
                identifier: "inline-dictation-stop",
                tint: .primary
            ) {
                Task {
                    if let transcript = await model.retryTranscription() {
                        onTranscript(transcript)
                    }
                }
            }
        case .failed:
            trailingButton(
                systemImage: "xmark",
                label: "Close dictation",
                identifier: "inline-dictation-cancel",
                tint: .secondary
            ) {
                onFinished()
            }
        }
    }

    private func trailingButton(
        systemImage: String,
        label: String,
        identifier: String,
        tint: Color,
        filled: Bool = false,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? Color(uiColor: .systemBackground) : tint)
                .frame(width: 32, height: 32)
                .background(filled ? tint : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Live pseudo-waveform for in-composer recording. The capture session does
/// not expose audio metering, so the bars follow a smooth composite signal
/// driven by the animation clock.
struct DictationWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let barCount = 22

    var body: some View {
        if reduceMotion {
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2.5, height: staticHeight(index))
                }
            }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule()
                            .fill(Color.primary.opacity(0.75))
                            .frame(width: 2.5, height: animatedHeight(index, at: time))
                    }
                }
            }
        }
    }

    private func animatedHeight(_ index: Int, at time: TimeInterval) -> CGFloat {
        let position = Double(index) / Double(barCount - 1)
        let envelope = sin(position * .pi)
        let fast = sin(time * 6.1 + Double(index) * 0.9)
        let slow = sin(time * 2.3 + Double(index) * 0.35)
        let value = (0.55 + 0.45 * fast * slow) * (0.35 + 0.65 * envelope)
        return CGFloat(4 + value * 18)
    }

    private func staticHeight(_ index: Int) -> CGFloat {
        let position = Double(index) / Double(barCount - 1)
        return CGFloat(6 + sin(position * .pi) * 12)
    }
}
