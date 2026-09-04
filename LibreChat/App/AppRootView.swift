import DesignKit
import LibreChatDomain
import SwiftUI

/// De-duplicates accessibility announcements while still allowing the same
/// message to be announced again after the UI has cleared it. Keeping this as
/// a value type makes error-announcement behavior deterministic in tests.
struct AccessibilityAnnouncementState: Equatable {
    private(set) var lastMessage: String?

    mutating func announcement(for message: String?) -> String? {
        guard let message else {
            lastMessage = nil
            return nil
        }
        guard message != lastMessage else { return nil }
        lastMessage = message
        return message
    }
}

struct AppRootView: View {
    let model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The degraded-storage notice is informational; once read, it stays out
    /// of the way for the rest of the session instead of occupying the top
    /// inset permanently.
    @State private var isCacheNoticeDismissed = false

    var body: some View {
        ZStack {
            AppBackground()

            switch model.phase {
            case .restoring:
                LaunchLoadingView()
            case .needsServer:
                ServerSetupView(model: model)
            case .signedOut:
                LoginView(model: model)
            case .signedIn:
                if model.isAppLocked {
                    AppLockView(appModel: model)
                } else {
                    SignedInRootView(appModel: model)
                        .id(
                            "\(model.selectedServer?.id.rawValue ?? "")|"
                                + "\(model.selectedServer?.accountIdentifier?.rawValue ?? "")|"
                                + model.cacheEpoch.uuidString
                        )
                        // Entity images (agent avatars, spec icons) sit behind
                        // the server's secure image links and must ride the
                        // session's authenticated transport.
                        .environment(
                            \.fetchServerImage,
                            ServerImageFetchAction { url in
                                try? await model.imageData(at: url)
                            }
                        )
                }
            }
        }
        .task {
            await model.restoreIfNeeded()
        }
        .sheet(item: pendingTermsBinding) { terms in
            TermsAcceptanceView(model: model, terms: terms)
                .interactiveDismissDisabled()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let repairNotice = model.cacheRepairNotice, !isCacheNoticeDismissed {
                CacheRepairNoticeView(message: repairNotice) {
                    withAnimation(.easeIn(duration: 0.16)) {
                        isCacheNoticeDismissed = true
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: model.phase)
        .animation(reduceMotion ? nil : .smooth, value: isCacheNoticeDismissed)
    }

    private var pendingTermsBinding: Binding<PublicTermsOfService?> {
        Binding(
            get: { model.pendingTerms },
            set: { _ in }
        )
    }
}

private struct CacheRepairNoticeView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(.fill.tertiary, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline storage unavailable")
        .accessibilityValue(message)
        .accessibilityHint("Dismissible for this session.")
        .accessibilityIdentifier("cache-repair-notice")
    }
}

private struct TermsAcceptanceView: View {
    let model: AppModel
    let terms: PublicTermsOfService

    @State private var isAccepting = false
    @State private var isDeclining = false
    @State private var errorMessage: String?
    @State private var actionTask: Task<Void, Never>?
    @State private var errorAnnouncementState = AccessibilityAnnouncementState()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if terms.content.isEmpty {
                            Text("Review this server’s terms before continuing.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(terms.content)
                                .textSelection(.enabled)
                        }

                        if let externalURL = terms.externalURL {
                            Link("Open full terms", destination: externalURL)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 720, alignment: .leading)
                }

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        declineButton
                        acceptButton
                    }
                    VStack(spacing: 12) {
                        acceptButton
                        declineButton
                    }
                }
                .padding(18)
            }
            .navigationTitle(termsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                actionTask?.cancel()
                actionTask = nil
                isAccepting = false
                isDeclining = false
            }
        }
        .presentationDetents([.large])
        .onChange(of: errorMessage) { _, message in
            if let announcement = errorAnnouncementState.announcement(for: message) {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    private var declineButton: some View {
        Button("Decline", role: .destructive) {
            decline()
        }
        .frame(maxWidth: .infinity)
        .disabled(isAccepting || isDeclining)
    }

    private var acceptButton: some View {
        Button {
            accept()
        } label: {
            HStack {
                if isAccepting { ProgressView() }
                Text(isAccepting ? "Accepting…" : "Accept")
            }
            .frame(maxWidth: .infinity)
        }
        .adaptiveProminentButtonStyle()
        .disabled(isAccepting || isDeclining)
    }

    private var termsTitle: String {
        guard let title = terms.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return "Terms and conditions" }
        return title
    }

    private func accept() {
        guard actionTask == nil else { return }
        isAccepting = true
        errorMessage = nil
        actionTask = Task {
            defer {
                isAccepting = false
                actionTask = nil
            }
            do {
                try await model.acceptPendingTerms()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.userFacingMessage
            }
        }
    }

    private func decline() {
        guard actionTask == nil else { return }
        isDeclining = true
        errorMessage = nil
        actionTask = Task {
            defer {
                isDeclining = false
                actionTask = nil
            }
            await model.declinePendingTerms()
        }
    }
}

/// The app's launch/restore screen: the LibreChat mark with a single
/// breathing dot underneath — quiet, theme-monochrome, no skeleton chrome.
/// Static under Reduce Motion.
struct LaunchLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 22) {
            Image("LogoMark")
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)

            Circle()
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
                .scaleEffect(isPulsing ? 0.6 : 1)
                .opacity(isPulsing ? 0.35 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
